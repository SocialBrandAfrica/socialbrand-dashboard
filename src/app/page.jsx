'use client'

import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import * as XLSX from 'xlsx'
import { ProductDetailPanelConnected } from '@/components/ProductDetailPanel'
import { FocusAreaPanel }    from '@/components/FocusAreaPanel'
import { SalesTrendPanel }   from '@/components/SalesTrendPanel'
import { CalendarPopover } from '@/components/CalendarPopover'
import PushStatusStrip from '@/components/PushStatusStrip'
import './dashboard.css'

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────
const MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December']

const STORES = [
  { code: '10116', name: 'SPAR Delareyville' },
  { code: '21355', name: 'TOPS Delareyville' },
  { code: '80175', name: 'SPAR Roosville'    },
  { code: '80176', name: 'TOPS Roosville'    },
  { code: '80579', name: 'TOPS Dice'         },
]

const STORE_MAP = Object.fromEntries(STORES.map(s => [s.code, s.name]))
const ALL_STORE_CODES = STORES.map(s => s.code)

const ACTIVITY_OPTIONS = [
  { key: 'all',        label: 'All Items'   },
  { key: 'ordering',   label: 'Ordering'    },
  { key: 'active',     label: 'Active Only' },
  { key: 'locked',     label: 'Locked Only' },
  { key: 'sold_today', label: 'Sold Today'  },
]

const REPORTS = [
  { key: 'diwaais',     title: 'DIWAAIS',        desc: 'Sigma-style ordering report' },
  { key: 'sales',       title: "Today's Sales",   desc: 'Items that sold today' },
  { key: 'topmovers',   title: 'Top 20 Movers',   desc: 'Ranked by qty or value' },
  { key: 'lostsales',   title: 'Lost Sales',      desc: 'Out of stock, sold in last 3 days' },
  { key: 'deptsummary', title: 'Dept Summary',    desc: 'Sales totals per department' },
  { key: 'reorder',     title: 'Reorder List',    desc: 'SOH ≤ 0, has ROS — includes Days Cover' },
  { key: 'slowmovers',  title: 'Slow Movers',     desc: 'In stock, no period sales' },
  { key: 'negative',    title: 'Negative SOH',    desc: 'Stock errors and shrinkage' },
  { key: 'full',        title: 'Full Export',     desc: 'Every field, no extra filter' },
]

const PAGE_SIZE = 200
const COLS = 'ean,description,size,unit,sell_price,vat_pct,today_qty,today_cost,today_sales,period_qty,period_cost,period_sales,soh,dept_code,dept_name,sub_dept_code,sub_dept_name,internal_ref,status,last_sales_date_iso,is_placeholder,snapshot_date,store_code,store_name,unit_cost'

// ─────────────────────────────────────────────────────────────────────────────
// FORMATTERS
// ─────────────────────────────────────────────────────────────────────────────
const zarShort = v => {
  if (v == null || isNaN(v)) return '—'
  const n = Math.abs(v)
  if (n >= 1e6) return 'R ' + (v / 1e6).toFixed(2) + 'M'
  if (n >= 1e3) return 'R ' + (v / 1e3).toFixed(1) + 'k'
  return 'R ' + v.toFixed(0)
}
const num = (v, dp = 0) => v == null || isNaN(v) ? '—' : Number(v).toLocaleString('en-ZA', { minimumFractionDigits: dp, maximumFractionDigits: dp })
const pct = (v, dp = 1) => v == null || isNaN(v) ? '—' : Number(v).toFixed(dp) + '%'

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────
function unitCost(row) {
  if (row.unit_cost != null && row.unit_cost > 0) return row.unit_cost
  if (row.period_qty && row.period_qty !== 0) return (row.period_cost ?? 0) / Math.abs(row.period_qty)
  if (row.sell_price > 0) {
    const vat = (row.vat_pct ?? 15) / 100
    return (row.sell_price / (1 + vat)) * 0.8
  }
  return 0
}

// Normalise department names — strips periods so "H.M.R." and "HMR" merge into one chip
const normalizeDept = name => (name ?? '').replace(/\./g, '').trim()

function gpPct(sales, cost) {
  if (!sales || sales === 0) return 0
  return ((sales - cost) / sales) * 100
}

function shiftDate(isoDate, days) {
  const d = new Date(isoDate)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

function deltaInfo(current, prior) {
  if (!prior || prior === 0 || current == null) return null
  const pct = ((current - prior) / Math.abs(prior)) * 100
  return { pct, positive: pct >= 0, label: (pct >= 0 ? '+' : '') + pct.toFixed(1) + '%' }
}

function ppDeltaInfo(currentPP, priorPP) {
  if (priorPP == null || currentPP == null) return null
  const diff = currentPP - priorPP
  return { diff, positive: diff >= 0, label: (diff >= 0 ? '+' : '') + diff.toFixed(1) + 'pp' }
}

function dateSummaryLabel(selectedDates, availableDates) {
  if (!selectedDates.length) return 'No dates'
  if (selectedDates.length === 1) return selectedDates[0]
  const months = [...new Set(selectedDates.map(d => d.slice(0, 7)))]
  if (months.length === 1) {
    const [yr, mo] = months[0].split('-')
    const monthSnaps = availableDates.filter(d => d.startsWith(months[0]))
    if (monthSnaps.length > 0 && monthSnaps.length === selectedDates.length &&
        monthSnaps.every(d => selectedDates.includes(d)))
      return `${MONTH_NAMES[+mo - 1]} ${yr} (${selectedDates.length} snapshots)`
  }
  return `${selectedDates.length} dates selected`
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA FETCH — on-demand when a report is explicitly loaded.
// Uses rpc_all_rows (SECURITY DEFINER) — direct daily_snapshots reads are
// blocked by RLS for the anon key.  Pages through results in 1 000-row batches.
// ─────────────────────────────────────────────────────────────────────────────
async function fetchAllRows({ storeCodes, dates }) {
  if (!storeCodes.length || !dates.length) return []
  const allRows = []
  const batchSize = 1000
  const maxRows   = 10000
  let from = 0
  while (true) {
    const { data, error } = await supabase.rpc('rpc_all_rows', {
      p_store_codes: storeCodes,
      p_dates:       dates,
      p_from:        from,
      p_limit:       batchSize,
    })
    if (error) { console.error('rpc_all_rows:', error.message); break }
    if (!data || data.length === 0) break
    allRows.push(...data)
    if (allRows.length >= maxRows) { console.warn('[fetchAllRows] row cap reached — truncated at', maxRows); break }
    if (data.length < batchSize) break
    from += batchSize
  }
  return allRows
}

// ─────────────────────────────────────────────────────────────────────────────
// MERGE — accumulate sales across dates; latest date wins for SOH/price
// ─────────────────────────────────────────────────────────────────────────────
function mergeByEan(rows) {
  const map = new Map()
  const sorted = [...rows].sort((a, b) => (a.snapshot_date < b.snapshot_date ? -1 : 1))
  for (const r of sorted) {
    // Key on EAN + description: PLU codes are store-specific so the same EAN can mean
    // different products across stores (e.g. 200149 = VEGGIE SOUP at one store,
    // PORK SHOULDER CHOPS at another). Description disambiguates them.
    const key = `${r.ean}|${r.description}`
    if (!map.has(key)) {
      map.set(key, { ...r })
    } else {
      const m = map.get(key)
      m.today_qty    = (m.today_qty    ?? 0) + (r.today_qty    ?? 0)
      m.today_cost   = (m.today_cost   ?? 0) + (r.today_cost   ?? 0)
      m.today_sales  = (m.today_sales  ?? 0) + (r.today_sales  ?? 0)
      m.period_qty   = (m.period_qty   ?? 0) + (r.period_qty   ?? 0)
      m.period_cost  = (m.period_cost  ?? 0) + (r.period_cost  ?? 0)
      m.period_sales = (m.period_sales ?? 0) + (r.period_sales ?? 0)
      if (r.snapshot_date >= m.snapshot_date) {
        m.soh = r.soh; m.sell_price = r.sell_price; m.snapshot_date = r.snapshot_date
        if (r.last_sales_date_iso && r.last_sales_date_iso > (m.last_sales_date_iso ?? ''))
          m.last_sales_date_iso = r.last_sales_date_iso
      }
    }
  }
  return Array.from(map.values())
}

function mergeGroupRows(rows) {
  const map = new Map()
  const sorted = [...rows].sort((a, b) => (a.snapshot_date < b.snapshot_date ? -1 : 1))
  for (const r of sorted) {
    // Same as mergeByEan — use EAN + description to avoid PLU collision across stores
    const key = `${r.ean}|${r.description}`
    if (!map.has(key)) {
      map.set(key, { ...r })
    } else {
      const m = map.get(key)
      m.today_qty    = (m.today_qty    ?? 0) + (r.today_qty    ?? 0)
      m.today_cost   = (m.today_cost   ?? 0) + (r.today_cost   ?? 0)
      m.today_sales  = (m.today_sales  ?? 0) + (r.today_sales  ?? 0)
      m.period_qty   = (m.period_qty   ?? 0) + (r.period_qty   ?? 0)
      m.period_cost  = (m.period_cost  ?? 0) + (r.period_cost  ?? 0)
      m.period_sales = (m.period_sales ?? 0) + (r.period_sales ?? 0)
      m.soh          = (m.soh          ?? 0) + (r.soh          ?? 0)
      if (r.last_sales_date_iso && r.last_sales_date_iso > (m.last_sales_date_iso ?? ''))
        m.last_sales_date_iso = r.last_sales_date_iso
    }
  }
  return Array.from(map.values())
}

// ─────────────────────────────────────────────────────────────────────────────
// CLIENT-SIDE FILTER
// ─────────────────────────────────────────────────────────────────────────────
function applyFilters(rows, { activityFilter, deptFilter, subDeptFilter, includeParents }) {
  let r = rows
  if (!includeParents) r = r.filter(x => !x.is_placeholder)
  if (deptFilter    !== 'all') r = r.filter(x => x.dept_name    === deptFilter)
  if (subDeptFilter !== 'all') r = r.filter(x => x.sub_dept_name === subDeptFilter)
  switch (activityFilter) {
    case 'ordering':   return r.filter(x => x.soh !== 0 || (x.period_qty ?? 0) !== 0)
    case 'active':     return r.filter(x => x.status === 'Active')
    case 'locked':     return r.filter(x => x.status === 'Locked')
    case 'sold_today': return r.filter(x => (x.today_qty ?? 0) !== 0)
    default:           return r
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BUILD REPORT
// ─────────────────────────────────────────────────────────────────────────────
function buildReport(report, rows, moverMode, refDate, rosMap = new Map(), supplierMap = new Map()) {
  switch (report) {
    case 'diwaais':
      return rows
        .filter(r => r.soh !== 0 || (r.period_qty ?? 0) !== 0)
        .map(r => ({
          'Sub':         parseInt(r.sub_dept_code) || 0,
          'Code':        parseInt((r.internal_ref ?? '').replace(/^0+/, '')) || 0,
          'EAN':         r.ean,
          'Description': r.description,
          'Size':        `${r.size ?? ''} ${r.unit ?? ''}`.trim(),
          'Dept':        parseInt(r.dept_code) || 0,
          'SOH':         r.soh ?? 0,
          'Cost':        r.period_qty ? Math.round((r.period_cost / Math.abs(r.period_qty)) * 10000) / 10000 : 0,
          'Last Sale':   r.last_sales_date_iso ?? '',
          'Status':      r.status ?? '',
        }))

    case 'sales':
      return rows
        .filter(r => (r.today_qty ?? 0) !== 0)
        .sort((a, b) => (b.today_sales ?? 0) - (a.today_sales ?? 0))
        .map(r => ({
          'EAN':         r.ean,
          'Description': r.description,
          'Dept':        r.dept_name,
          'Qty Sold':    r.today_qty ?? 0,
          'Cost Value':  Math.round((r.today_cost  ?? 0) * 100) / 100,
          'Sales (VAT)': Math.round((r.today_sales ?? 0) * 100) / 100,
          'SOH After':   r.soh ?? 0,
        }))

    case 'topmovers': {
      const byQty = [...rows]
        .filter(r => (r.today_qty ?? 0) > 0)
        .sort((a, b) => (b.today_qty ?? 0) - (a.today_qty ?? 0))
        .slice(0, 20)
        .map((r, i) => ({ '#': i + 1, EAN: r.ean, Description: r.description, Dept: r.dept_name, 'Qty': r.today_qty ?? 0, 'Sales': Math.round((r.today_sales ?? 0) * 100) / 100 }))
      const byVal = [...rows]
        .filter(r => (r.today_sales ?? 0) > 0)
        .sort((a, b) => (b.today_sales ?? 0) - (a.today_sales ?? 0))
        .slice(0, 20)
        .map((r, i) => ({ '#': i + 1, EAN: r.ean, Description: r.description, Dept: r.dept_name, 'Qty': r.today_qty ?? 0, 'Sales': Math.round((r.today_sales ?? 0) * 100) / 100 }))
      return moverMode === 'qty' ? byQty : byVal
    }

    case 'lostsales': {
      const ref = refDate ? new Date(refDate) : new Date()
      return rows
        .filter(r => {
          if ((r.soh ?? 0) > 0 || !r.last_sales_date_iso) return false
          const diffDays = (ref - new Date(r.last_sales_date_iso)) / 86400000
          return diffDays >= 0 && diffDays <= 3
        })
        .sort((a, b) => new Date(a.last_sales_date_iso) - new Date(b.last_sales_date_iso))
        .map(r => ({
          'EAN':         r.ean,
          'Description': r.description,
          'Dept':        r.dept_name,
          'SOH':         r.soh ?? 0,
          'Last Sale':   r.last_sales_date_iso,
          'Days':        Math.floor((ref - new Date(r.last_sales_date_iso)) / 86400000),
          'Per Qty':     r.period_qty ?? 0,
          'Price':       r.sell_price ?? 0,
        }))
    }

    case 'deptsummary': {
      const dmap = new Map()
      for (const r of rows) {
        const k = r.dept_name ?? 'Unknown'
        if (!dmap.has(k)) dmap.set(k, { dept: k, items: 0, qty: 0, cost: 0, sales: 0 })
        const d = dmap.get(k)
        if ((r.today_qty ?? 0) !== 0) d.items++
        d.qty   += r.today_qty   ?? 0
        d.cost  += r.today_cost  ?? 0
        d.sales += r.today_sales ?? 0
      }
      const result = [...dmap.values()]
        .sort((a, b) => b.sales - a.sales)
        .map(d => ({
          'Department':  d.dept,
          'Items Sold':  d.items,
          'Qty Sold':    Math.round(d.qty  * 1000) / 1000,
          'Cost Value':  Math.round(d.cost * 100)  / 100,
          'Sales (VAT)': Math.round(d.sales * 100) / 100,
          'GP%':         d.sales > 0 ? Math.round(gpPct(d.sales, d.cost) * 10) / 10 + '%' : '—',
        }))
      const tot = result.reduce(
        (a, d) => ({ ...a, 'Items Sold': a['Items Sold'] + d['Items Sold'], 'Qty Sold': a['Qty Sold'] + d['Qty Sold'], 'Cost Value': a['Cost Value'] + d['Cost Value'], 'Sales (VAT)': a['Sales (VAT)'] + d['Sales (VAT)'] }),
        { Department: 'TOTAL', 'Items Sold': 0, 'Qty Sold': 0, 'Cost Value': 0, 'Sales (VAT)': 0, 'GP%': '' }
      )
      tot['GP%'] = tot['Sales (VAT)'] > 0 ? Math.round(gpPct(tot['Sales (VAT)'], tot['Cost Value']) * 10) / 10 + '%' : '—'
      return [...result, tot]
    }

    case 'reorder':
      return rows
        .filter(r => (r.soh ?? 0) <= 0 && (r.period_qty ?? 0) > 0)
        .sort((a, b) => (a.soh ?? 0) - (b.soh ?? 0))
        .map(r => {
          const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
          return {
            'EAN':         r.ean,
            'Description': r.description,
            'Dept':        r.dept_name,
            'Supplier':    supplierMap.get(r.ean) ?? '',
            'SOH':         r.soh ?? 0,
            'ROS':         ros.daily_ros  != null ? Number(ros.daily_ros)  : null,
            'Days':        ros.days_cover != null ? Number(ros.days_cover) : null,
            'Per Qty':     r.period_qty ?? 0,
            'Price':       r.sell_price ?? 0,
            'Cost':        Math.round(unitCost(r) * 100) / 100,
            'Last Sale':   r.last_sales_date_iso ?? '',
            'Status':      r.status ?? '',
          }
        })

    case 'slowmovers':
      return rows
        .filter(r => (r.soh ?? 0) > 0 && (r.period_qty ?? 0) === 0)
        .sort((a, b) => {
          const capA = (a.soh ?? 0) * unitCost(a)
          const capB = (b.soh ?? 0) * unitCost(b)
          return capB - capA
        })
        .map(r => {
          const uc = unitCost(r)
          return {
            'EAN':         r.ean,
            'Description': r.description,
            'Dept':        r.dept_name,
            'Supplier':    supplierMap.get(r.ean) ?? '',
            'SOH':         r.soh ?? 0,
            'Price':       r.sell_price ?? 0,
            'Cost':        Math.round(uc * 100) / 100,
            'Cap Tied':    Math.round((r.soh ?? 0) * uc * 100) / 100,
            'Last Sale':   r.last_sales_date_iso ?? '',
            'Status':      r.status ?? '',
          }
        })

    case 'negative':
      return rows
        .filter(r => (r.soh ?? 0) < 0)
        .sort((a, b) => (a.soh ?? 0) - (b.soh ?? 0))
        .map(r => ({
          'EAN':         r.ean,
          'Description': r.description,
          'Dept':        r.dept_name,
          'SOH':         r.soh ?? 0,
          'Per Qty':     r.period_qty ?? 0,
          'Price':       r.sell_price ?? 0,
          'Status':      r.status ?? '',
        }))

    case 'full':
      return rows.map(r => ({
        'EAN':            r.ean,
        'Description':    r.description,
        'Size':           r.size ?? '',
        'Unit':           r.unit ?? '',
        'Sell Price':     r.sell_price ?? 0,
        'VAT%':           r.vat_pct ?? 0,
        'Today Qty':      r.today_qty    ?? 0,
        'Today Cost':     r.today_cost   ?? 0,
        'Today Sales':    r.today_sales  ?? 0,
        'Period Qty':     r.period_qty   ?? 0,
        'Period Cost':    r.period_cost  ?? 0,
        'Period Sales':   r.period_sales ?? 0,
        'SOH':            r.soh ?? 0,
        'Dept Code':      r.dept_code ?? '',
        'Dept':           r.dept_name ?? '',
        'Sub-Dept Code':  r.sub_dept_code ?? '',
        'Sub-Dept':       r.sub_dept_name ?? '',
        'Internal Ref':   r.internal_ref ?? '',
        'Status':         r.status ?? '',
        'Last Sale Date': r.last_sales_date_iso ?? '',
        'Date':           r.snapshot_date ?? '',
        'Store':          r.store_name ?? '',
      }))

    default:
      return rows
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EXCEL DOWNLOAD
// ─────────────────────────────────────────────────────────────────────────────
function downloadExcel(reportData, reportKey, storeName, date) {
  if (!reportData.length) return
  const ws = XLSX.utils.json_to_sheet(reportData)
  const wb = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(wb, ws, 'Report')
  const safeStore = storeName.replace(/\s+/g, '_')
  const safeDate  = (date ?? 'multi').replace(/-/g, '')
  XLSX.writeFile(wb, `${reportKey}_${safeStore}_${safeDate}.xlsx`)
}

// ─────────────────────────────────────────────────────────────────────────────
// DAISY LOGO — SVG approximation; swap for <img src="/logo.png"> once the
// real file is dropped into socialbrand-dashboard/public/logo.png
// ─────────────────────────────────────────────────────────────────────────────
function DaisyLogo({ size = 44 }) {
  const n = 18
  const petals = Array.from({ length: n }, (_, i) => (i * 360) / n)
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ flexShrink: 0, borderRadius: '50%' }}>
      <circle cx="50" cy="50" r="50" fill="#000" />
      {petals.map(deg => {
        const rad = ((deg - 90) * Math.PI) / 180
        const cx = 50 + 26 * Math.cos(rad)
        const cy = 50 + 26 * Math.sin(rad)
        return (
          <ellipse key={deg} cx={cx} cy={cy} rx="5" ry="13.5"
            fill="white" opacity="0.93"
            transform={`rotate(${deg}, ${cx}, ${cy})`} />
        )
      })}
      <circle cx="50" cy="50" r="12" fill="#f59e0b" />
      <circle cx="50" cy="50" r="7.5" fill="#d97706" />
    </svg>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// FILTER DROPDOWN — compact pill that shows current selection; opens a menu
// ─────────────────────────────────────────────────────────────────────────────
function FilterDropdown({ label, value, options, onChange, emptyMsg }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const handler = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false) }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])
  const currentLabel = options.find(o => o.key === value)?.label ?? value
  const isActive = options.length > 0 && value !== options[0].key
  return (
    <div ref={ref} style={{ position: 'relative', flexShrink: 0 }}>
      <button onClick={() => setOpen(o => !o)} className="sb-filter-btn" style={{
        display: 'flex', alignItems: 'center', gap: 5,
        padding: '5px 11px',
        background: open ? 'rgba(74,222,128,0.12)' : isActive ? 'rgba(74,222,128,0.07)' : 'rgba(255,255,255,0.05)',
        border: `1px solid ${open || isActive ? 'rgba(74,222,128,0.3)' : 'rgba(255,255,255,0.1)'}`,
        borderRadius: 8, cursor: 'pointer', fontFamily: 'Geist, sans-serif',
        transition: 'all 0.15s', whiteSpace: 'nowrap',
      }}>
        <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', textTransform: 'uppercase', letterSpacing: '0.08em' }}>{label}</span>
        <span style={{ fontSize: 11, color: isActive ? '#4ade80' : 'rgba(245,245,244,0.8)', fontWeight: isActive ? 600 : 400 }}>{currentLabel}</span>
        <span style={{ fontSize: 8, color: 'rgba(245,245,244,0.25)', marginLeft: 1 }}>▾</span>
      </button>
      {open && (
        <div style={{
          position: 'absolute', top: 'calc(100% + 6px)', left: 0, zIndex: 400,
          background: '#0d1426', border: '1px solid rgba(255,255,255,0.12)',
          borderRadius: 10, overflow: 'hidden', minWidth: 170,
          boxShadow: '0 16px 48px rgba(0,0,0,0.65)',
        }}>
          {options.length === 0
            ? <div style={{ padding: '10px 14px', fontSize: 11, color: 'rgba(245,245,244,0.3)', fontStyle: 'italic' }}>{emptyMsg ?? 'No options'}</div>
            : options.map(o => (
                <button key={o.key} onClick={() => { onChange(o.key); setOpen(false) }} style={{
                  display: 'block', width: '100%', textAlign: 'left',
                  padding: '8px 14px', fontSize: 11,
                  background: o.key === value ? 'rgba(74,222,128,0.1)' : 'transparent',
                  color: o.key === value ? '#4ade80' : 'rgba(245,245,244,0.78)',
                  border: 'none', cursor: 'pointer', fontFamily: 'Geist, sans-serif',
                  transition: 'background 0.1s',
                }}>{o.label}</button>
              ))
          }
        </div>
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// PRODUCT SEARCH BAR — typeahead against daily_snapshots
// ─────────────────────────────────────────────────────────────────────────────
function ProductSearchBar({ storeCodes, selectedDates, onSelect, onAddToFocus, focusBasket, deptFilter, subDeptFilter, deptNormMap, searchIndex }) {
  const [query,   setQuery]   = useState('')
  const [results, setResults] = useState([])
  const [loading, setLoading] = useState(false)
  const [open,    setOpen]    = useState(false)
  const ref      = useRef(null)
  const timerRef = useRef(null)

  // close on click-outside
  useEffect(() => {
    if (!open) return
    const h = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false) }
    document.addEventListener('mousedown', h)
    return () => document.removeEventListener('mousedown', h)
  }, [open])

  // debounced search — fires 300 ms after last keystroke, min 2 chars
  // When searchIndex is loaded (dept or store-scoped): filter in memory, zero RPC.
  // Fallback to rpc_search_products when: index empty (All Depts + All Stores),
  // or no local results found with 3+ chars (product not yet in the index).
  useEffect(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    if (query.trim().length < 2) { setResults([]); setOpen(false); return }
    timerRef.current = setTimeout(async () => {
      setLoading(true)
      const q = query.trim().toLowerCase()

      // ── Local index path (fast, zero RPC per keystroke) ──────────────────
      let localResultCount = 0
      if (searchIndex && searchIndex.length > 0) {
        const local = searchIndex.filter(p =>
          p.description.toLowerCase().includes(q) ||
          String(p.ean).includes(q)
        ).filter(p =>
          subDeptFilter === 'all' || !subDeptFilter || p.subdept === subDeptFilter
        )

        if (local.length > 0) {
          // Show local results immediately — user gets instant feedback.
          // If q is long enough we still fall through to RPC for more results.
          const mapped = local.slice(0, 25).map(p => ({
            ean:           p.ean,
            description:   p.description,
            dept_name:     p.dept,
            sub_dept_name: p.subdept ?? null,
            store_code:    null,
            is_placeholder: false,
            internal_ref:  null,
          }))
          setResults(mapped)
          setOpen(true)
          setLoading(false)
          localResultCount = mapped.length
          if (q.length < 4) return   // short query — local is enough
          // q.length >= 4: continue to RPC so additional matches can update results
        } else if (q.length < 4) {
          // No local results and query too short to bother the RPC
          setResults([])
          setOpen(false)
          setLoading(false)
          return
        }
        // If local returned 0 results with 4+ chars: fall through to RPC
      }

      // ── RPC fallback ─────────────────────────────────────────────────────
      // Used when: (a) index is empty (All Depts + All Stores), or
      //            (b) index returned 0 results for a 3+ char query.
      // Search uses rpc_search_products (SECURITY DEFINER) — direct daily_snapshots
      // reads are blocked by RLS for the anon key.
      const latestDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
      if (!latestDate) { setResults([]); setOpen(false); setLoading(false); return }

      const hasContext = (deptFilter && deptFilter !== 'all') || (subDeptFilter && subDeptFilter !== 'all')
      const fetchLimit = hasContext ? 50 : Math.min(30 * (storeCodes.length || 1), 150)

      // Pass all raw dept name variants (e.g. "HMR" and "H.M.R.") so the RPC
      // can match regardless of how the dept_name was stored in the database.
      // Note: do NOT filter is_placeholder — HMR PLU items like VEGGIE SOUP are
      // incorrectly flagged as placeholders. Search must include them.
      const deptNames = (deptFilter && deptFilter !== 'all')
        ? [...(deptNormMap?.get(deptFilter) ?? new Set([deptFilter]))]
        : null

      const { data, error } = await supabase.rpc('rpc_search_products', {
        p_store_codes: storeCodes,
        p_date:        latestDate,
        p_query:       q,
        p_dept_names:  deptNames,
        p_subdept:     (subDeptFilter && subDeptFilter !== 'all') ? subDeptFilter : null,
        p_limit:       fetchLimit,
      })
      if (error) console.error('rpc_search_products error', error)
      // Deduplicate by EAN + description — PLU codes like 200149 mean different products
      // in different stores (VEGGIE SOUP at Delareyville, PORK SHOULDER CHOPS at Roosville),
      // so keying on EAN alone would hide one of them.
      const seen = new Set()
      const unique = (data ?? []).filter(r => {
        const key = `${r.ean}|${r.description}`
        if (seen.has(key)) return false
        seen.add(key)
        return true
      }).slice(0, 25)
      // Only replace local results if RPC found more — local is already visible
      if (unique.length > localResultCount) {
        setResults(unique)
        setOpen(true)
      }
      setLoading(false)
    }, 300)
    return () => { if (timerRef.current) clearTimeout(timerRef.current) }
  }, [query, storeCodes, selectedDates, searchIndex, deptFilter, subDeptFilter, deptNormMap])

  function handleSelect(row) {
    onSelect(row)
    setQuery('')
    setResults([])
    setOpen(false)
  }

  return (
    <div ref={ref} style={{ position: 'relative', flex: '1 1 220px', minWidth: 200, maxWidth: 420 }}>
      {/* Input */}
      <div style={{ position: 'relative' }}>
        <span style={{ position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)', fontSize: 11, color: 'rgba(245,245,244,0.25)', pointerEvents: 'none' }}>🔍</span>
        <input
          type="text"
          placeholder={
            subDeptFilter && subDeptFilter !== 'all'
              ? `Search in ${subDeptFilter}…`
              : deptFilter && deptFilter !== 'all'
                ? `Search in ${deptFilter}…`
                : 'Search product — EAN, code, or name…'
          }
          value={query}
          onChange={e => setQuery(e.target.value)}
          onFocus={() => results.length > 0 && setOpen(true)}
          style={{
            width: '100%', boxSizing: 'border-box',
            padding: '5px 30px 5px 28px',
            background: 'rgba(255,255,255,0.05)',
            border: '1px solid rgba(255,255,255,0.1)',
            borderRadius: 8, fontFamily: 'Geist, sans-serif',
            fontSize: 11, color: '#f5f5f4', outline: 'none',
            transition: 'border-color 0.15s',
          }}
          onMouseEnter={e => e.target.style.borderColor = 'rgba(255,255,255,0.2)'}
          onMouseLeave={e => e.target.style.borderColor = open ? 'rgba(74,222,128,0.3)' : 'rgba(255,255,255,0.1)'}
        />
        {loading && (
          <span style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', fontSize: 7, color: 'rgba(74,222,128,0.7)', animation: 'pulse 1.5s infinite' }}>●●●</span>
        )}
        {query.length > 0 && !loading && (
          <button onClick={() => { setQuery(''); setResults([]); setOpen(false) }} style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)', background: 'none', border: 'none', color: 'rgba(245,245,244,0.25)', cursor: 'pointer', fontSize: 12, lineHeight: 1, padding: '0 2px' }}>✕</button>
        )}
      </div>

      {/* Dropdown */}
      {open && (
        <div style={{
          position: 'absolute', top: 'calc(100% + 6px)', left: 0, right: 0, zIndex: 500,
          background: '#0d1426', border: '1px solid rgba(255,255,255,0.12)',
          borderRadius: 10, overflow: 'hidden',
          boxShadow: '0 16px 48px rgba(0,0,0,0.7)',
          maxHeight: 280, overflowY: 'auto',
        }}>
          {results.length === 0 && !loading && (
            <div style={{ padding: '12px 14px', fontSize: 11, color: 'rgba(245,245,244,0.3)', fontStyle: 'italic' }}>No products found for "{query}"</div>
          )}
          {/* Group results by normalised dept name so HMR, GROCERIES etc are clearly separated */}
          {(() => {
            const groupOrder = []
            const groupMap = new Map()
            for (const r of results) {
              const key = normalizeDept(r.dept_name) || r.dept_name || '—'
              if (!groupMap.has(key)) { groupMap.set(key, []); groupOrder.push(key) }
              groupMap.get(key).push(r)
            }
            return groupOrder.map(dept => (
              <div key={dept}>
                <div style={{
                  padding: '5px 14px 3px',
                  fontSize: 9, fontWeight: 700, letterSpacing: '0.08em',
                  color: 'rgba(74,222,128,0.55)', textTransform: 'uppercase',
                  background: 'rgba(74,222,128,0.04)',
                  borderBottom: '1px solid rgba(255,255,255,0.05)',
                  borderTop: groupOrder.indexOf(dept) > 0 ? '1px solid rgba(255,255,255,0.07)' : 'none',
                }}>{dept}</div>
                {groupMap.get(dept).map((r, i) => {
                  const inBasket = focusBasket?.some(
                    b => b.ean === r.ean && b.description === r.description && b.store_code === r.store_code
                  )
                  return (
                    <div key={`${r.ean}-${i}`} style={{
                      display: 'flex', alignItems: 'center',
                      borderBottom: '1px solid rgba(255,255,255,0.04)',
                      background: 'transparent', transition: 'background 0.1s',
                    }}
                      onMouseEnter={e => e.currentTarget.style.background = 'rgba(74,222,128,0.06)'}
                      onMouseLeave={e => e.currentTarget.style.background = 'transparent'}
                    >
                      {/* Main click area — opens product detail */}
                      <button
                        onClick={() => handleSelect(r)}
                        style={{
                          flex: 1, textAlign: 'left',
                          padding: '8px 8px 8px 18px',
                          background: 'transparent', border: 'none',
                          cursor: 'pointer', fontFamily: 'Geist, sans-serif', minWidth: 0,
                        }}
                      >
                        <p style={{ fontSize: 12, color: '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', margin: 0 }}>
                          {r.description}
                          {r.is_placeholder && <span title="PLU code — real product" style={{ marginLeft: 5, fontSize: 8, background: 'rgba(251,191,36,0.15)', color: 'rgba(251,191,36,0.8)', border: '1px solid rgba(251,191,36,0.3)', borderRadius: 3, padding: '1px 4px', fontFamily: 'Geist, sans-serif', verticalAlign: 'middle' }}>PLU</span>}
                        </p>
                        <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", margin: '2px 0 0' }}>
                          {r.ean}{r.internal_ref ? ` · ${r.internal_ref}` : ''}{r.sub_dept_name ? ` · ${r.sub_dept_name}` : ''}
                          {(r.size || r.unit) && <span style={{ color: 'rgba(245,245,244,0.2)' }}>{' · '}{[r.size, r.unit].filter(Boolean).join(' ')}</span>}
                        </p>
                      </button>
                      {/* "+" button — adds to Focus Area basket */}
                      {onAddToFocus && (
                        <button
                          onClick={e => { e.stopPropagation(); onAddToFocus(r) }}
                          title={inBasket ? 'Already in Focus Area' : 'Add to Focus Area'}
                          style={{
                            flexShrink: 0, width: 28, height: 28, margin: '0 6px',
                            background: inBasket ? 'rgba(74,222,128,0.15)' : 'rgba(255,255,255,0.05)',
                            border: `1px solid ${inBasket ? 'rgba(74,222,128,0.4)' : 'rgba(255,255,255,0.12)'}`,
                            borderRadius: 6, cursor: inBasket ? 'default' : 'pointer',
                            color: inBasket ? '#4ade80' : 'rgba(245,245,244,0.5)',
                            fontSize: inBasket ? 13 : 16, lineHeight: 1,
                            display: 'flex', alignItems: 'center', justifyContent: 'center',
                            fontFamily: 'Geist, sans-serif', transition: 'all 0.15s',
                          }}
                        >
                          {inBasket ? '✓' : '+'}
                        </button>
                      )}
                    </div>
                  )
                })}
              </div>
            ))
          })()}
          {results.length === 25 && (
            <div style={{ padding: '8px 14px', fontSize: 10, color: 'rgba(245,245,244,0.25)', fontStyle: 'italic', borderTop: '1px solid rgba(255,255,255,0.06)', textAlign: 'center' }}>
              Showing 25 matches — type more to narrow down
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// SKELETON BLOCK
// ─────────────────────────────────────────────────────────────────────────────
function Skeleton({ h = 32, w = '100%', r = 6, mb = 0 }) {
  return (
    <div style={{ height: h, width: w, background: 'rgba(255,255,255,0.06)', borderRadius: r, marginBottom: mb, animation: 'pulse 1.5s infinite' }} />
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// SPARKLINE — 14-point inline trend line for KPI cards
// ─────────────────────────────────────────────────────────────────────────────
function Sparkline({ values, color = '#4ade80', height = 28 }) {
  if (!values || values.length < 2) return null
  const min   = Math.min(...values)
  const max   = Math.max(...values)
  const range = max - min || 1
  const pad   = 2
  const pts   = values.map((v, i) => {
    const x = (i / (values.length - 1)) * 100
    const y = height - pad - ((v - min) / range) * (height - pad * 2)
    return `${x},${y}`
  }).join(' ')
  return (
    <svg
      width="100%"
      height={height}
      viewBox={`0 0 100 ${height}`}
      preserveAspectRatio="none"
      style={{ display: 'block', overflow: 'visible' }}
    >
      <polyline
        points={pts}
        fill="none"
        stroke={color}
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// MOBILE BREAKPOINT HOOK
// ─────────────────────────────────────────────────────────────────────────────
function useIsMobile() {
  const [isMobile, setIsMobile] = useState(false)
  useEffect(() => {
    const check = () => setIsMobile(window.innerWidth < 768)
    check()
    window.addEventListener('resize', check)
    return () => window.removeEventListener('resize', check)
  }, [])
  return isMobile
}

// ─────────────────────────────────────────────────────────────────────────────
// SEARCH INDEX LOCAL STORAGE CACHE (Layer 1)
// Persists between sessions. Key is scoped to dept+stores so different
// filter combos don't overwrite each other.
// ─────────────────────────────────────────────────────────────────────────────
const SEARCH_IDX_KEY = 'sb_pulse_search_index_v1'
const SEARCH_IDX_TTL = 24 * 60 * 60 * 1000

function loadCachedSearchIndex(scopeKey) {
  try {
    const raw = localStorage.getItem(SEARCH_IDX_KEY + '|' + scopeKey)
    if (!raw) return null
    const { data, ts } = JSON.parse(raw)
    return Date.now() - ts < SEARCH_IDX_TTL ? data : null
  } catch { return null }
}
function saveCachedSearchIndex(scopeKey, data) {
  try {
    localStorage.setItem(
      SEARCH_IDX_KEY + '|' + scopeKey,
      JSON.stringify({ data, ts: Date.now() })
    )
  } catch { /* quota — ignore */ }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────────────────────
export default function Home() {
  const isMobile = useIsMobile()

  // ── session-level RPC caches (Layer 2) ──────────────────────────────────────
  // Maps keyed by sorted store+date (+ filter) strings. Cleared on page reload.
  const viewsCache  = useRef(new Map())   // kpiData + allSubDepts
  const deptCache   = useRef(new Map())   // deptSummary + deptSohCounts
  const top20Cache  = useRef(new Map())   // top20Data

  // ── dates & stores ──────────────────────────────────────────────────────────
  const [availableDates, setAvailableDates] = useState([])
  const [selectedDates,  setSelectedDates]  = useState([])
  const [storeCodes,     setStoreCodes]     = useState([])   // populated after profile load
  const [userProfile,    setUserProfile]    = useState(undefined) // undefined=loading, null=pending
  const [authUser,       setAuthUser]       = useState(null)
  const [calOpen,        setCalOpen]        = useState(false)
  const calAnchorRef = useRef(null)
  const panelRef     = useRef(null)

  // ── drawer ──────────────────────────────────────────────────────────────────
  const [drawerOpen, setDrawerOpen] = useState(false)

  // ── filters ─────────────────────────────────────────────────────────────────
  const [activityFilter, setActivityFilter] = useState('all')
  const [deptFilter,     setDeptFilter]     = useState('all')
  const [subDeptFilter,  setSubDeptFilter]  = useState('all')
  const [includeParents, setIncludeParents] = useState(true)

  // ── report ───────────────────────────────────────────────────────────────────
  const [currentReport,  setCurrentReport]  = useState('diwaais')
  const [moverMode,      setMoverMode]      = useState('qty')
  const [top20Activity,  setTop20Activity]  = useState('movers')

  // ── aggregation view data ────────────────────────────────────────────────────
  const [kpiData,        setKpiData]        = useState([])
  const [deptSummary,    setDeptSummary]    = useState([])   // rpc_dept_summary — one aggregated row per dept
  const [deptSohCounts,  setDeptSohCounts]  = useState([])   // rpc_kpi_dept_counts — neg/slow per dept (Bug 3)
  const [top20Data,      setTop20Data]      = useState([])   // rpc_top20 — up to 40 pre-aggregated rows
  const [deptNormMap,    setDeptNormMap]    = useState(new Map())
  const [viewsLoading,   setViewsLoading]   = useState(false)
  const [top20Loading,   setTop20Loading]   = useState(false)

  // ── historical comparison data (Phase 3.2) ──────────────────────────────────
  const [sparklineData,    setSparklineData]    = useState([])   // mv_sparkline_14d — fetched once on mount
  const [rhythmProfiles,   setRhythmProfiles]   = useState([])   // community_rhythm — active profiles, fetched once
  const [lyKpiData,      setLyKpiData]      = useState([])   // v_kpi_by_date for LY equivalent dates
  const [wowKpiData,     setWowKpiData]     = useState([])   // v_kpi_by_date for WoW equivalent dates
  const [lyDeptSummary,  setLyDeptSummary]  = useState([])   // rpc_dept_summary for LY dates
  const [trendData,      setTrendData]      = useState([])   // v_kpi_by_date for trend chart (90 days)
  const [lyTrendData,    setLyTrendData]    = useState([])   // v_kpi_by_date for LY trend window

  // ── dept/sub-dept chips ─────────────────────────────────────────────────────
  const [depts,       setDepts]       = useState([])
  const [subDepts,    setSubDepts]    = useState([])   // filtered by selected dept
  const [allSubDepts, setAllSubDepts] = useState([])   // all sub-depts for current store+date

  // ── report data (on-demand) ──────────────────────────────────────────────────
  const [reportRows,    setReportRows]    = useState([])
  const [reportLoaded,  setReportLoaded]  = useState(false)
  const [reportLoading, setReportLoading] = useState(false)
  const [storeRosData,  setStoreRosData]  = useState([])
  const [supplierMap,   setSupplierMap]   = useState(new Map())  // ean → supplier_name from product_catalog
  const [lostSalesItems,    setLostSalesItems]    = useState([])  // negative SOH lines sold in last 3 days
  const [lostSalesTimeline, setLostSalesTimeline] = useState(new Map()) // ean → [{snap_date,sold_bool,oos_bool,soh}] (merged across stores)
  const [timelineLoading,   setTimelineLoading]   = useState(false)

  // ── product detail panel ────────────────────────────────────────────────────
  const [selectedProduct, setSelectedProduct] = useState(null)

  // ── focus area basket ────────────────────────────────────────────────────
  // Each entry: { ean, description, store_code, dept_name, sub_dept_name, ... }
  //
  // isDefaultBasket = true  → basket is auto-populated (top 5 by value).
  //   Re-fetches when stores or dates change.
  // isDefaultBasket = false → user has manually added items; auto-fetch is suppressed.
  //   "Clear all" resets back to isDefaultBasket = true and re-fetches the top 5.
  const [focusBasket,      setFocusBasket]      = useState([])
  const [isDefaultBasket,  setIsDefaultBasket]  = useState(true)

  // ── auth: load user + profile on mount ───────────────────────────────────────
  // PHASE 1 (current): all authenticated users are treated as owner (super-admin).
  // user_profiles row is optional — if missing, full access is granted anyway.
  // Store isolation by role will be wired up when access tiers are introduced.
  useEffect(() => {
    async function loadProfile() {
      const { data: { user } } = await supabase.auth.getUser()
      setAuthUser(user)
      if (!user) {
        window.location.href = '/login'
        return
      }
      const { data } = await supabase
        .from('user_profiles')
        .select('store_code, full_name, role')
        .eq('id', user.id)
        .maybeSingle()
      // Until tiers are live: all signed-in users get owner (full) access.
      // If a user_profiles row exists use it for display name; role is ignored.
      const effectiveProfile = data ?? { role: 'owner', full_name: null, store_code: null }
      setUserProfile(effectiveProfile)
      setStoreCodes([...ALL_STORE_CODES])
    }
    loadProfile()
  }, [])

  const handleSignOut = useCallback(async () => {
    await supabase.auth.signOut()
    window.location.href = '/login'
  }, [])

  // Phase 1: always false — store selector visible for all users.
  // Set to true for role==='manager' when access tiers are introduced.
  const isManagerLocked = false

  // Auto-populate Focus Area with the top 5 products by period sales value.
  // Uses rpc_focus_top5 (SECURITY DEFINER) — direct daily_snapshots reads are
  // blocked by RLS for the anon key.  Clear the basket immediately so stale
  // chips don't linger when the store / date selection changes.
  useEffect(() => {
    if (!isDefaultBasket) return
    if (!storeCodes.length || !selectedDates.length) return

    let cancelled = false
    setFocusBasket([])   // clear immediately so old data never lingers

    supabase.rpc('rpc_focus_top5', {
      p_store_codes: storeCodes,
      p_dates:       selectedDates,
      p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
      p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
    }).then(({ data, error }) => {
      if (cancelled) return
      if (error) { console.error('rpc_focus_top5 error', error); return }
      if (!data?.length) return
      const top5 = data.slice(0, 5).map(r => ({
        ean:           String(r.ean),
        description:   r.description,
        store_code:    r.store_code,
        dept_name:     r.dept_name,
        sub_dept_name: r.sub_dept_name,
      }))
      setFocusBasket(top5)
    })
    return () => { cancelled = true }
  }, [isDefaultBasket, storeCodes, selectedDates, deptFilter, subDeptFilter])

  const addToFocus = useCallback((row) => {
    // BUG-2: clear the auto-populated default basket before the first manual add
    setIsDefaultBasket(false)
    setFocusBasket(prev => {
      const wasDefault = isDefaultBasket           // capture before setState flushes
      const base       = wasDefault ? [] : prev    // wipe defaults on first manual add
      const key = `${row.ean}|${row.description}|${row.store_code}`
      if (base.some(b => `${b.ean}|${b.description}|${b.store_code}` === key)) return base
      return [...base, row]
    })
  }, [isDefaultBasket])

  const removeFromFocus = useCallback((item) => {
    setIsDefaultBasket(false)
    setFocusBasket(prev =>
      prev.filter(b => !(b.ean === item.ean && b.description === item.description && b.store_code === item.store_code))
    )
  }, [])

  // Clear all → resets to top-5 default
  const clearFocus = useCallback(() => {
    setFocusBasket([])
    setIsDefaultBasket(true)
  }, [])

  // EANs from manually-curated basket — null when auto-populated (default)
  const focusEans = useMemo(() => {
    if (isDefaultBasket || !focusBasket.length) return null
    return [...new Set(focusBasket.map(b => b.ean))]
  }, [focusBasket, isDefaultBasket])

  // ── on mount: load ALL available dates ──────────────────────────────────────
  // Two sources merged so the full date history is always available:
  //   push_log  — snapshot_date set since v3.10 (2026-05-24); shows new dates
  //               immediately after a push without waiting for mv refresh.
  //   mv_kpi_by_date — pre-aggregated history; covers all dates before v3.10
  //                    where push_log.snapshot_date was NULL.
  useEffect(() => {
    async function init() {
      const [pushRes, histRes] = await Promise.all([
        supabase
          .from('push_log')
          .select('snapshot_date')
          .eq('status', 'SUCCESS')
          .not('snapshot_date', 'is', null),
        // Fetch up to 5000 rows — 5 stores × 16 months × ~31 days = ~2,480 max.
        // Using range(0,4999) ensures we never clip older dates off the picker,
        // even if row count grows after new stores are added.
        supabase
          .from('mv_kpi_by_date')
          .select('snapshot_date')
          .order('snapshot_date', { ascending: false })
          .range(0, 4999)
      ])
      const allDates = new Set([
        ...(pushRes.data ?? []).map(r => r.snapshot_date),
        ...(histRes.data ?? []).map(r => r.snapshot_date)
      ].filter(Boolean))
      if (!allDates.size) return
      const unique = [...allDates].sort((a, b) => b.localeCompare(a))
      setAvailableDates(unique)
      // Default to all available dates in the current calendar month (MTD).
      // Falls back to latest single date only if no current-month snapshots exist.
      const todayPrefix = new Date().toISOString().slice(0, 7)  // e.g. "2026-05"
      const mtdDates = unique.filter(d => d.startsWith(todayPrefix))
      setSelectedDates(mtdDates.length > 0 ? mtdDates : [unique[0]])
      setStoreCodes([...ALL_STORE_CODES])
    }
    init()
  }, [])

  // ── on mount: fetch sparkline data (most recent 14 days, all stores) ──────────
  useEffect(() => {
    supabase
      .from('mv_sparkline_14d')
      .select('store_code,snapshot_date,total_sales,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied')
      .order('snapshot_date', { ascending: true })
      .then(({ data, error }) => {
        if (error) { console.error('mv_sparkline_14d:', error.message); return }
        setSparklineData(data ?? [])
      })
  }, [])

  // ── Community Rhythm: fetch active profiles once on mount ───────────────────
  useEffect(() => {
    supabase
      .from('community_rhythm')
      .select('id,profile_name,start_day,end_day,multiplier,is_active')
      .eq('is_active', true)
      .order('start_day', { ascending: true })
      .then(({ data, error }) => {
        if (error) { console.error('[community_rhythm]', error.message); return }
        setRhythmProfiles(data ?? [])
      })
  }, [])

  // ── Lost Sales: negative SOH items that sold in the last 3 days ─────────────
  // Small targeted query — runs on the latest snapshot date per store.
  // Does not depend on the full reportRows load.
  useEffect(() => {
    if (!storeCodes.length || !availableDates.length) return
    let cancelled = false
    const latestDate = availableDates[0]  // sorted newest-first
    const threeDaysAgo = new Date()
    threeDaysAgo.setDate(threeDaysAgo.getDate() - 3)
    const cutoff = threeDaysAgo.toISOString().slice(0, 10)  // YYYY-MM-DD

    supabase
      .from('daily_snapshots')
      .select('ean,description,dept_name,soh,sell_price,last_sales_date_iso,store_name,store_code')
      .in('store_code', storeCodes)
      .eq('snapshot_date', latestDate)
      .lt('soh', 0)
      .gte('last_sales_date_iso', cutoff)
      .eq('is_placeholder', false)
      .order('soh', { ascending: true })
      .limit(100)
      .then(({ data, error }) => {
        if (cancelled) return
        if (error) { console.error('[lostSales]', error.message); return }
        setLostSalesItems(data ?? [])
      })

    return () => { cancelled = true }
  }, [storeCodes, availableDates])

  // ── Lost Sales Timeline: fetch 28-day sold/OOS bars once items are known ────
  useEffect(() => {
    if (!lostSalesItems.length || !availableDates.length || !storeCodes.length) {
      setLostSalesTimeline(new Map())
      return
    }
    let cancelled = false

    async function loadTimeline() {
      setTimelineLoading(true)
      // Top 10 by lost value — same ordering as the widget rows
      const top10 = [...lostSalesItems]
        .sort((a, b) => (Math.abs(b.soh ?? 0) * (b.sell_price ?? 0)) - (Math.abs(a.soh ?? 0) * (a.sell_price ?? 0)))
        .slice(0, 10)
        .map(r => r.ean)

      const endDate = availableDates[0] // newest date, same as lostSales query

      const { data, error } = await supabase.rpc('rpc_lost_sales_timeline', {
        p_eans:     top10,
        p_stores:   storeCodes,
        p_end_date: endDate,
        p_days:     28,
      })

      if (cancelled) return
      if (error) { console.error('[lostSalesTimeline]', error.message); setTimelineLoading(false); return }

      // Merge rows across stores per EAN per date: sold > oos > neither
      const byEan = new Map()
      for (const row of (data ?? [])) {
        if (!byEan.has(row.ean)) byEan.set(row.ean, new Map())
        const byDate = byEan.get(row.ean)
        const existing = byDate.get(row.snap_date)
        if (!existing) {
          byDate.set(row.snap_date, { snap_date: row.snap_date, sold_bool: row.sold_bool, oos_bool: row.oos_bool, soh: row.soh })
        } else {
          // sold wins; if any store sold that day, mark sold
          byDate.set(row.snap_date, {
            snap_date: row.snap_date,
            sold_bool: existing.sold_bool || row.sold_bool,
            oos_bool:  existing.oos_bool  || row.oos_bool,
            soh:       Math.min(existing.soh ?? 0, row.soh ?? 0), // worst SOH across stores
          })
        }
      }

      // Convert inner Maps to sorted arrays
      const merged = new Map()
      for (const [ean, dateMap] of byEan) {
        merged.set(ean, [...dateMap.values()].sort((a, b) => a.snap_date < b.snap_date ? -1 : 1))
      }

      setLostSalesTimeline(merged)
      setTimelineLoading(false)
    }

    loadTimeline()
    return () => { cancelled = true }
  }, [lostSalesItems, storeCodes, availableDates])

  // ── fetch KPI + dept summary on store / date change (server-side aggregation via RPC) ──
  useEffect(() => {
    if (!storeCodes.length || !selectedDates.length) return
    let cancelled = false

    async function loadViews() {
      setReportRows([])
      setReportLoaded(false)
      setStoreRosData([])
      setSelectedProduct(null)

      const vKey = [...storeCodes].sort().join(',') + '|' + [...selectedDates].sort().join(',')
      const hit  = viewsCache.current.get(vKey)
      if (hit) {
        setKpiData(hit.kpiData)
        setAllSubDepts(hit.allSubDepts)
        setViewsLoading(false)
        return
      }

      setViewsLoading(true)

      // LY dates: each selected date shifted back 364 days (52 weeks — preserves day-of-week)
      // No availableDates filter — let Supabase return what exists. Filtering here caused LY
      // to silently drop when mv_kpi_by_date lagged behind push_log as the sole date source.
      const lyDates = selectedDates.map(d => shiftDate(d, -364))

      // WoW dates: each selected date shifted back 7 days
      // Same rationale — don't gate on availableDates; query and get real results or empty.
      const wowDates = selectedDates.map(d => shiftDate(d, -7))

      // Trend window: last 90 available dates (time-series for trend chart)
      const trendDates = availableDates.slice(0, 90)

      // LY trend window: map trendDates back 364 days (no availableDates filter — same rationale)
      const lyTrendDates = trendDates.map(d => shiftDate(d, -364))

      // Rule (PM decision 2026-05-25):
      //   single date  → v_kpi_by_date  (live view — catches today's push immediately)
      //   multi date   → mv_kpi_by_date (pre-aggregated MV — no timeout risk on MTD/25+ dates)
      // LY / WoW / trend are always historical so always use the MV.
      const kpiTable = selectedDates.length === 1 ? 'v_kpi_by_date' : 'mv_kpi_by_date'

      const [kpiRes, subDeptRes, lyKpiRes, wowKpiRes, lyDeptRes, trendRes, lyTrendRes] = await Promise.all([
        // Current KPI
        supabase.from(kpiTable)
          .select('store_code,store_name,snapshot_date,total_sales,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied')
          .in('store_code', storeCodes)
          .in('snapshot_date', selectedDates),

        // Sub-dept names for the current store+date
        supabase.rpc('rpc_subdepts', {
          p_store_codes: storeCodes,
          p_dates:       selectedDates,
          p_dept_names:  null,
        }),

        // LY KPI — always historical, use MV
        lyDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied')
              .in('store_code', storeCodes)
              .in('snapshot_date', lyDates)
          : Promise.resolve({ data: [], error: null }),

        // WoW KPI — always historical, use MV
        wowDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales,total_cost,total_qty')
              .in('store_code', storeCodes)
              .in('snapshot_date', wowDates)
          : Promise.resolve({ data: [], error: null }),

        // LY dept summary
        lyDates.length > 0
          ? supabase.rpc('rpc_dept_summary', { p_store_codes: storeCodes, p_dates: lyDates })
          : Promise.resolve({ data: [], error: null }),

        // Trend data (90-day window) — always historical, use MV
        supabase.from('mv_kpi_by_date')
          .select('store_code,snapshot_date,total_sales,total_cost,total_qty')
          .in('store_code', storeCodes)
          .in('snapshot_date', trendDates)
          .order('snapshot_date', { ascending: true }),

        // LY trend data — always historical, use MV
        lyTrendDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales')
              .in('store_code', storeCodes)
              .in('snapshot_date', lyTrendDates)
              .order('snapshot_date', { ascending: true })
          : Promise.resolve({ data: [], error: null }),
      ])

      if (cancelled) return
      if (kpiRes.error) console.error('[mv_kpi_by_date]', kpiRes.error.message)
      const kpiData    = kpiRes.data ?? []
      const allSubDepts = [...new Set((subDeptRes.data ?? []).map(r => r.sub_dept_name))].filter(Boolean).sort()
      viewsCache.current.set(vKey, { kpiData, allSubDepts })
      setKpiData(kpiData)
      setAllSubDepts(allSubDepts)
      setLyKpiData(lyKpiRes.data   ?? [])
      setWowKpiData(wowKpiRes.data ?? [])
      setLyDeptSummary(lyDeptRes.data ?? [])
      setTrendData(trendRes.data   ?? [])
      setLyTrendData(lyTrendRes.data ?? [])
      setViewsLoading(false)

      // Load ROS/days-cover in background so Top 20 can show days cover without
      // requiring the user to open the Reports tab first.
      supabase
        .from('mv_rate_of_sale')
        .select('ean,store_code,daily_ros,days_cover')
        .in('store_code', storeCodes)
        .then(({ data }) => { if (!cancelled) setStoreRosData(data ?? []) })
    }

    loadViews()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates])

  // ── re-fetch KPI aggregates when sub-dept filter changes (Bug 4) ──────────────
  // Lighter than loadViews — only updates deptSummary and deptSohCounts.
  // Does NOT clear selectedProduct or reportRows so UX state is preserved.
  useEffect(() => {
    if (!storeCodes.length || !selectedDates.length) return
    let cancelled = false

    const subdeptParam = subDeptFilter !== 'all' ? subDeptFilter : null
    const dKey = [...storeCodes].sort().join(',') + '|' + [...selectedDates].sort().join(',') + '|' + (subdeptParam ?? '') + '|' + (focusEans ? focusEans.slice().sort().join(',') : '')
    const dHit = deptCache.current.get(dKey)
    if (dHit) {
      setDeptSummary(dHit.deptSummary)
      setDeptSohCounts(dHit.deptSohCounts)
      return
    }

    Promise.all([
      supabase.rpc('rpc_dept_summary', {
        p_store_codes: storeCodes,
        p_dates:       selectedDates,
        p_subdept:     subdeptParam,
        p_eans:        focusEans,
      }),
      supabase.rpc('rpc_kpi_dept_counts', {
        p_store_codes: storeCodes,
        p_dates:       selectedDates,
        p_subdept:     subdeptParam,
        p_eans:        focusEans,
      }),
    ]).then(([deptRes, deptSohRes]) => {
      if (cancelled) return
      if (deptRes.error)    console.error('[rpc_dept_summary]',    deptRes.error.message)
      if (deptSohRes.error) console.error('[rpc_kpi_dept_counts]', deptSohRes.error.message)
      const ds  = deptRes.data    ?? []
      const dsc = deptSohRes.data ?? []
      deptCache.current.set(dKey, { deptSummary: ds, deptSohCounts: dsc })
      setDeptSummary(ds)
      setDeptSohCounts(dsc)
    }).catch(err => {
      if (cancelled) return
      console.error('[dept effect]', err)
      setDeptSummary([])
      setDeptSohCounts([])
    })

    return () => { cancelled = true }
  }, [storeCodes, selectedDates, subDeptFilter, focusEans])

  // ── fetch Top 20 via RPC — re-runs when dept or sub-dept filter changes ──────
  // rpc_top20 accepts p_dept / p_subdept and returns at most 40 pre-aggregated rows
  // (union of top-20-by-value ∪ top-20-by-qty). No client-side row-cap issues.
  useEffect(() => {
    if (!storeCodes.length || !selectedDates.length) {
      setTop20Data([])
      return
    }
    let cancelled = false

    async function loadTop20() {
      const t20Key = [...storeCodes].sort().join(',') + '|' + [...selectedDates].sort().join(',') + '|' +
                     (deptFilter !== 'all' ? deptFilter : '') + '|' +
                     (subDeptFilter !== 'all' ? subDeptFilter : '') + '|' +
                     top20Activity + '|' + String(includeParents) + '|' +
                     (focusEans ? focusEans.slice().sort().join(',') : '')
      const t20Hit = top20Cache.current.get(t20Key)
      if (t20Hit) {
        setTop20Data(t20Hit)
        setTop20Loading(false)
        return
      }

      setTop20Loading(true)
      const { data, error } = await supabase.rpc('rpc_top20', {
        p_store_codes: storeCodes,
        p_dates:       selectedDates,
        p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
        p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
        p_activity:    top20Activity,
        p_parents:     includeParents,
        p_eans:        focusEans,
      })
      if (cancelled) return
      if (error) console.error('[rpc_top20]', error.message)
      const t20 = data ?? []
      top20Cache.current.set(t20Key, t20)
      setTop20Data(t20)
      setTop20Loading(false)
    }

    loadTop20()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates, deptFilter, subDeptFilter, top20Activity, includeParents, focusEans])

  // ── search index — one row per EAN; loaded per dept/store combo ───────────
  // When any dept is selected, OR when a subset of stores is selected,
  // we pre-load matching rows from product_search_index into state so
  // ProductSearchBar can filter locally (zero RPC per keystroke).
  // All Depts + All Stores: skip — catalog too large; falls back to RPC.
  const [searchIndex, setSearchIndex] = useState([])

  useEffect(() => {
    const allDepts  = deptFilter  === 'all'
    const allStores = storeCodes.length === ALL_STORE_CODES.length

    if (allDepts && allStores) {
      setSearchIndex([])   // bypass — ProductSearchBar will use RPC directly
      return
    }

    const scopeKey = (deptFilter === 'all' ? 'ALL' : deptFilter) + '|' + [...storeCodes].sort().join(',')
    const cached   = loadCachedSearchIndex(scopeKey)
    if (cached) {
      setSearchIndex(cached)
      return
    }

    let cancelled = false
    let query = supabase
      .from('product_search_index')
      .select('ean,description,dept,subdept,stores')

    if (!allDepts)  query = query.eq('dept', deptFilter)
    if (!allStores) query = query.overlaps('stores', storeCodes)

    query.then(({ data, error }) => {
      if (cancelled) return
      if (error) { console.error('[search_index]', error.message); return }
      const rows = data ?? []
      saveCachedSearchIndex(scopeKey, rows)
      setSearchIndex(rows)
    })

    return () => { cancelled = true }
  }, [deptFilter, storeCodes])

  // ── derive dept chips from deptSummary ─────────────────────────────────────
  // deptSummary has no is_placeholder filter so service depts (HMR, Butchery,
  // Deli) appear as chip options whenever they had sales in the selected window.
  useEffect(() => {
    const normMap = new Map()
    for (const r of deptSummary) {
      const norm = normalizeDept(r.dept_name)
      if (!norm) continue
      if (!normMap.has(norm)) normMap.set(norm, new Set())
      normMap.get(norm).add(r.dept_name)
    }
    setDeptNormMap(normMap)
    const names = [...normMap.keys()].sort()
    setDepts(names)
    if (deptFilter !== 'all' && !names.includes(deptFilter)) {
      setDeptFilter('all')
      setSubDeptFilter('all')
    }
  }, [deptSummary])

  // ── fetch sub-dept chips when dept filter changes ────────────────────────────
  useEffect(() => {
    if (deptFilter === 'all' || !storeCodes.length || !selectedDates.length) {
      setSubDepts([])
      return
    }
    let cancelled = false
    async function loadSubDepts() {
      // rpc_subdepts is SECURITY DEFINER — direct daily_snapshots reads are blocked by RLS.
      // Pass all raw dept name variants so HMR / H.M.R. both match.
      const { data } = await supabase.rpc('rpc_subdepts', {
        p_store_codes: storeCodes,
        p_dates:       selectedDates,
        p_dept_names:  [...(deptNormMap.get(deptFilter) ?? new Set([deptFilter]))],
      })
      if (cancelled) return
      const names = (data ?? []).map(r => r.sub_dept_name).filter(Boolean)
      setSubDepts(names)
    }
    loadSubDepts()
    return () => { cancelled = true }
  }, [deptFilter, storeCodes, selectedDates])

  // ─────────────────────────────────────────────────────────────────────────────
  // REPORT — on-demand fetch
  // ─────────────────────────────────────────────────────────────────────────────
  const loadReport = useCallback(async () => {
    if (!storeCodes.length || !selectedDates.length || reportLoading) return
    setReportLoading(true)

    const [rows, rosRes, catalogRes] = await Promise.all([
      fetchAllRows({ storeCodes, dates: selectedDates }),
      supabase
        .from('mv_rate_of_sale')
        .select('ean,store_code,daily_ros,days_cover')
        .in('store_code', storeCodes)
        .then(r => r.data ?? [])
        .catch(() => []),
      // product_catalog carries supplier_name per EAN (loaded from DIWAAIS2 / PLU reference)
      supabase
        .from('product_catalog')
        .select('ean,supplier_name')
        .in('store_code', storeCodes)
        .not('supplier_name', 'is', null)
        .then(r => r.data ?? [])
        .catch(() => []),
    ])

    // Build ean → supplier_name lookup (last-write wins across stores — supplier is the same)
    const suppMap = new Map()
    for (const row of catalogRes) {
      if (row.supplier_name) suppMap.set(row.ean, row.supplier_name)
    }

    setReportRows(rows)
    setStoreRosData(rosRes)
    setSupplierMap(suppMap)
    setReportLoaded(true)
    setReportLoading(false)
  }, [storeCodes, selectedDates])

  // ─────────────────────────────────────────────────────────────────────────────
  // PRODUCT DETAIL — sync; data fetch moved into ProductDetailPanelConnected
  // ─────────────────────────────────────────────────────────────────────────────
  const handleProductClick = useCallback((row) => {
    const ean = String(row['EAN'] ?? row.ean ?? '')
    if (!ean) return
    setSelectedProduct(row)
    setTimeout(() => panelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 100)
  }, [])

  // ─────────────────────────────────────────────────────────────────────────────
  // DERIVED — report rows
  // ─────────────────────────────────────────────────────────────────────────────
  const mergedReportRows = useMemo(() => {
    if (!reportRows.length) return []
    return storeCodes.length > 1 ? mergeGroupRows(reportRows) : mergeByEan(reportRows)
  }, [reportRows, storeCodes.length])

  const filteredReportRows = useMemo(() =>
    applyFilters(mergedReportRows, { activityFilter, deptFilter, subDeptFilter, includeParents }),
    [mergedReportRows, activityFilter, deptFilter, subDeptFilter, includeParents]
  )

  const rosMap = useMemo(() => {
    const m = new Map()
    for (const r of storeRosData) m.set(`${r.ean}__${r.store_code}`, r)
    return m
  }, [storeRosData])

  // EAN-level days cover for Top 20 display. When multiple stores are selected,
  // takes the lowest (most urgent) days cover across stores for each EAN.
  const eanDaysCoverMap = useMemo(() => {
    const m = new Map()
    for (const r of storeRosData) {
      if (r.days_cover == null) continue
      const existing = m.get(r.ean)
      if (existing == null || r.days_cover < existing) m.set(r.ean, Number(r.days_cover))
    }
    return m
  }, [storeRosData])

  const reportData = useMemo(() => {
    if (!reportLoaded) return []
    const refDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
    return buildReport(currentReport, filteredReportRows, moverMode, refDate, rosMap, supplierMap)
  }, [currentReport, filteredReportRows, moverMode, selectedDates, reportLoaded, rosMap, supplierMap])

  // ─────────────────────────────────────────────────────────────────────────────
  // DERIVED — KPIs
  // ─────────────────────────────────────────────────────────────────────────────
  const latestKpiByStore = useMemo(() => {
    const m = {}
    for (const r of kpiData) {
      if (!m[r.store_code] || r.snapshot_date > m[r.store_code].snapshot_date) m[r.store_code] = r
    }
    return Object.values(m)
  }, [kpiData])

  // deptSummary is pre-filtered by the RPC (p_subdept, p_eans). Use it whenever
  // any dept or sub-dept filter is active (BUG-4: sub-dept was ignored before).
  const kpiSales = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_sales ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSummary.reduce((s, r) => s + (r.total_sales ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_sales ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter, subDeptFilter])

  const kpiCost = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_cost ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSummary.reduce((s, r) => s + (r.total_cost ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_cost ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter, subDeptFilter])

  const kpiQty = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_qty ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSummary.reduce((s, r) => s + (r.total_qty ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_qty ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter, subDeptFilter])

  const kpiGP = kpiSales > 0 ? gpPct(kpiSales, kpiCost) : 0

  // BUG-3: normalize dept_name before comparing — dots stripped in deptFilter but
  // rpc_kpi_dept_counts may return the raw name (e.g. "GROCERIES.FOODS").
  // BUG-4: also respond to subDeptFilter (deptSohCounts already pre-filtered by RPC).
  const kpiNegSOH = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSohCounts.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.neg_soh_count ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSohCounts.reduce((s, r) => s + (r.neg_soh_count ?? 0), 0)
    return latestKpiByStore.reduce((s, r) => s + (r.neg_soh_count ?? 0), 0)
  }, [deptFilter, subDeptFilter, deptSohCounts, latestKpiByStore])

  const kpiSlowMove = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSohCounts.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSohCounts.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
    return latestKpiByStore.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
  }, [deptFilter, subDeptFilter, deptSohCounts, latestKpiByStore])
  const kpiReorder  = reportLoaded
    ? mergedReportRows.filter(r => !r.is_placeholder && (r.soh ?? 0) <= 0 && (r.period_qty ?? 0) > 0).length
    : null

  // ── dept chart (top 10) — deptSummary is already one row per dept, sorted by sales ──
  const deptChart = useMemo(() => {
    const map = new Map()
    for (const r of deptSummary) {
      const k = normalizeDept(r.dept_name)
      map.set(k, (map.get(k) ?? 0) + (r.total_sales ?? 0))
    }
    const sorted = [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
    const max = sorted[0]?.[1] ?? 1
    return sorted.map(([name, val]) => ({ name, val, pct: (val / max) * 100 }))
  }, [deptSummary])

  // ── Phase 3.2 derived values ─────────────────────────────────────────────────
  const lyKpiSales    = lyKpiData.reduce((s, r) => s + (r.total_sales ?? 0), 0)
  const lyKpiCost     = lyKpiData.reduce((s, r) => s + (r.total_cost  ?? 0), 0)
  const lyKpiQty      = lyKpiData.reduce((s, r) => s + (r.total_qty   ?? 0), 0)
  const lyKpiGP       = lyKpiSales > 0 ? gpPct(lyKpiSales, lyKpiCost) : null
  const lyKpiNegSOH   = lyKpiData.reduce((s, r) => s + (r.neg_soh_count   ?? 0), 0)
  const lyKpiSlowMove = lyKpiData.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
  const lyKpiCapTied  = lyKpiData.reduce((s, r) => s + (r.capital_tied ?? 0), 0)
  const hasLY         = lyKpiData.length > 0

  const wowKpiSales = wowKpiData.reduce((s, r) => s + (r.total_sales ?? 0), 0)
  const hasWoW      = wowKpiData.length > 0

  const kpiCapTied  = latestKpiByStore.reduce((s, r) => s + (r.capital_tied ?? 0), 0)

  const sameWeekdayBenchmark = useMemo(() => {
    if (selectedDates.length !== 1) return null
    const dow = new Date(selectedDates[0]).getDay()
    const compareDates = availableDates.filter(d =>
      d !== selectedDates[0] && new Date(d).getDay() === dow
    )
    const totals = compareDates
      .map(d => kpiData.filter(r => storeCodes.includes(r.store_code) && r.snapshot_date === d)
        .reduce((s, r) => s + (r.total_sales ?? 0), 0))
      .filter(v => v > 0)
    if (totals.length < 4) return null
    const avg = totals.reduce((a, b) => a + b, 0) / totals.length
    return { avgSales: avg, n: totals.length, dow: ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][dow] }
  }, [kpiData, selectedDates, storeCodes, availableDates])

  const sparklineArrays = useMemo(() => {
    const byDate = {}
    for (const r of sparklineData) {
      if (!storeCodes.includes(r.store_code)) continue
      if (!byDate[r.snapshot_date]) byDate[r.snapshot_date] = { sales: 0, cost: 0, neg_soh: 0, slow_movers: 0, capital_tied: 0 }
      byDate[r.snapshot_date].sales        += r.total_sales      ?? 0
      byDate[r.snapshot_date].cost         += r.total_cost       ?? 0
      byDate[r.snapshot_date].neg_soh      += r.neg_soh_count    ?? 0
      byDate[r.snapshot_date].slow_movers  += r.slow_mover_count ?? 0
      byDate[r.snapshot_date].capital_tied += r.capital_tied     ?? 0
    }
    const sorted = Object.entries(byDate).sort(([a], [b]) => a.localeCompare(b))
    return {
      sales:       sorted.map(([, v]) => v.sales),
      gpPct:       sorted.map(([, v]) => v.sales > 0 ? gpPct(v.sales, v.cost) : 0),
      negSoh:      sorted.map(([, v]) => v.neg_soh),
      slowMovers:  sorted.map(([, v]) => v.slow_movers),
      capitalTied: sorted.map(([, v]) => v.capital_tied),
    }
  }, [sparklineData, storeCodes])

  const lyDeptMap = useMemo(() => {
    const m = new Map()
    for (const r of lyDeptSummary) {
      const k = normalizeDept(r.dept_name)
      m.set(k, (m.get(k) ?? 0) + (r.total_sales ?? 0))
    }
    return m
  }, [lyDeptSummary])

  const showLYDept = lyDeptSummary.length > 0

  // ── top 20 — RPC already aggregated + filtered; just sort and slice ──────────
  const top20 = useMemo(() => {
    if (top20Activity === 'non_movers') return [...top20Data].slice(0, 20)
    return moverMode === 'qty'
      ? [...top20Data].filter(r => (r.total_qty   ?? 0) > 0).sort((a, b) => (b.total_qty   ?? 0) - (a.total_qty   ?? 0)).slice(0, 20)
      : [...top20Data].filter(r => (r.total_sales ?? 0) > 0).sort((a, b) => (b.total_sales ?? 0) - (a.total_sales ?? 0)).slice(0, 20)
  }, [top20Data, moverMode, top20Activity])

  // ─────────────────────────────────────────────────────────────────────────────
  // STORE HANDLERS
  // ─────────────────────────────────────────────────────────────────────────────
  function toggleStore(code) {
    setStoreCodes(prev => {
      if (prev.includes(code)) {
        const next = prev.filter(c => c !== code)
        return next.length ? next : prev
      }
      return [...prev, code]
    })
    // dept/subdept are NOT reset here — the useEffect on deptSummary handles the
    // case where the selected dept no longer exists in the new store selection.
  }

  function selectAllStores() {
    setStoreCodes([...ALL_STORE_CODES])
  }

  function clearStoreSelection() {
    setStoreCodes([])
  }

  function clickDept(name) {
    if (deptFilter === name) { setDeptFilter('all'); setSubDeptFilter('all') }
    else                     { setDeptFilter(name);  setSubDeptFilter('all') }
  }

  function clickSubDept(name) {
    setSubDeptFilter(prev => prev === name ? 'all' : name)
  }

  function handleReportCardClick(key) {
    setCurrentReport(key)
    if (!reportLoaded && !reportLoading) loadReport()
  }

  // ── active products — drives the layout switch ────────────────────────────
  // When focusBasket has manual items, all show as stacked ProductDetailPanels.
  // When only a single product is clicked, just that one shows.
  // isSelectionActive hides Top 20 + Sales by Dept and fills that space instead.
  const activeProducts = selectedProduct
    ? [selectedProduct]
    : (focusBasket.length > 0 && !isDefaultBasket)
      ? focusBasket
      : []
  const isSelectionActive = activeProducts.length > 0

  // ─────────────────────────────────────────────────────────────────────────────
  // DISPLAY VALUES
  // ─────────────────────────────────────────────────────────────────────────────
  const isAllStores     = storeCodes.length === ALL_STORE_CODES.length
  const activeStoreName = isAllStores
    ? 'All Stores'
    : storeCodes.map(c => STORE_MAP[c]).filter(Boolean).join(' + ')
  const displayDate     = dateSummaryLabel(selectedDates, availableDates)
  const activeReportDef = REPORTS.find(r => r.key === currentReport)

  // ─────────────────────────────────────────────────────────────────────────────
  // TABLE ROW RENDERER (shared between drawer and any future inline use)
  // ─────────────────────────────────────────────────────────────────────────────
  function renderTableRow(row, i, onRowClick) {
    const hasEan = row['EAN'] != null
    return (
      <tr key={i}
        style={{ cursor: hasEan ? 'pointer' : 'default' }}
        onClick={() => hasEan && onRowClick && onRowClick(row)}
      >
        {Object.entries(row).map(([col, val]) => {
          const isNum  = typeof val === 'number'
          const isSoh  = col === 'SOH'
          const isDesc = col === 'Description'
          const isCode = col === 'Sub' || col === 'Code' || col === 'Dept' || col === '#'
          const sohCls = isSoh ? (val > 0 ? 'soh-pos' : val < 0 ? 'soh-neg' : 'soh-zero') : ''
          let display
          if (isNum && !isSoh) {
            if (isCode) {
              display = val === 0 ? '—' : String(val)
            } else if (Number.isInteger(val)) {
              display = val.toLocaleString('en-ZA')
            } else {
              display = val.toLocaleString('en-ZA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
            }
          } else {
            display = val ?? '—'
          }
          return (
            <td key={col} className={`${isNum && !isCode ? 'r' : ''} ${sohCls} ${isDesc ? 'desc' : ''} ${isCode ? 'mono' : ''}`}>
              {display}
            </td>
          )
        })}
      </tr>
    )
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // AUTH GUARDS — rendered before main dashboard when session state is known
  // ─────────────────────────────────────────────────────────────────────────────
  if (userProfile === undefined) {
    return (
      <div style={{ minHeight: '100vh', background: '#0a0e1a', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: "'Geist', sans-serif" }}>
        <div style={{ textAlign: 'center' }}>
          <div style={{ width: 36, height: 36, border: '3px solid rgba(74,222,128,0.2)', borderTopColor: '#4ade80', borderRadius: '50%', animation: 'spin 0.8s linear infinite', margin: '0 auto 16px' }} />
          <p style={{ color: 'rgba(245,245,244,0.35)', fontSize: 13 }}>Loading…</p>
        </div>
      </div>
    )
  }

  if (userProfile === null) {
    return (
      <div style={{ minHeight: '100vh', background: '#0a0e1a', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: "'Geist', sans-serif", padding: 24 }}>
        <div style={{ maxWidth: 380, textAlign: 'center' }}>
          <h2 style={{ fontFamily: 'Fraunces, Georgia, serif', color: '#f5f5f4', marginBottom: 12, fontSize: 24 }}>Access Pending</h2>
          <p style={{ color: 'rgba(245,245,244,0.5)', marginBottom: 28, lineHeight: 1.7, fontSize: 14 }}>
            Your account ({authUser?.email}) is not yet assigned to a store.<br />
            Contact Pieter van der Westhuizen to get access.
          </p>
          <button onClick={handleSignOut} style={{ padding: '10px 24px', background: 'rgba(255,255,255,0.08)', border: '1px solid rgba(255,255,255,0.15)', borderRadius: 8, color: '#f5f5f4', cursor: 'pointer', fontFamily: "'Geist', sans-serif", fontSize: 13 }}>
            Sign out
          </button>
        </div>
      </div>
    )
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────────────────────
  return (
    <div style={{ minHeight: '100vh', background: '#0a0e1a', color: '#f5f5f4', fontFamily: "'Geist', -apple-system, sans-serif", position: 'relative', overflowX: 'hidden' }}>

      {/* Aurora */}
      <div style={{ position: 'fixed', inset: 0, zIndex: 0, pointerEvents: 'none',
        background: 'radial-gradient(ellipse 70% 50% at 15% 0%, rgba(74,222,128,0.18), transparent 60%), radial-gradient(ellipse 50% 40% at 90% 30%, rgba(34,211,238,0.12), transparent 55%), radial-gradient(ellipse 60% 50% at 50% 100%, rgba(168,85,247,0.1), transparent 60%)'
      }} />

      {/* ── STICKY FILTER BAR ────────────────────────────────────────────────── */}
      <div style={{
        position: 'sticky', top: 0, zIndex: 100,
        background: 'rgba(10,14,26,0.94)',
        borderBottom: '1px solid rgba(255,255,255,0.09)',
        backdropFilter: 'blur(32px)',
      }}>
        <div style={{ width: 'min(100%, 1800px)', margin: '0 auto' }} className="sb-filter-pad">

          {/* Row 1 — stores + date + reports button */}
          <div className="sb-store-row" style={{ marginBottom: 8 }}>

            {/* Store selector — hidden for managers (locked to their one store) */}
            {!isManagerLocked && (
              <>
                <button onClick={selectAllStores} style={{ padding: '4px 10px', fontSize: 10, background: isAllStores ? 'rgba(74,222,128,0.15)' : 'rgba(255,255,255,0.05)', border: `1px solid ${isAllStores ? 'rgba(74,222,128,0.3)' : 'rgba(255,255,255,0.12)'}`, borderRadius: 999, color: isAllStores ? '#4ade80' : 'rgba(245,245,244,0.45)', cursor: 'pointer', fontFamily: 'Geist, sans-serif', letterSpacing: '0.05em', transition: 'all 0.15s' }}>All</button>
                <button onClick={clearStoreSelection} style={{ padding: '4px 10px', fontSize: 10, background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 999, color: 'rgba(245,245,244,0.35)', cursor: 'pointer', fontFamily: 'Geist, sans-serif', letterSpacing: '0.05em' }}>Clear</button>
                {STORES.map(s => (
                  <button key={s.code}
                    className={`sb-chip${storeCodes.includes(s.code) ? ' on' : ''}`}
                    style={{ padding: '5px 12px', fontSize: 11 }}
                    onClick={() => toggleStore(s.code)}
                  >
                    {s.name}
                  </button>
                ))}
                <div style={{ width: 1, height: 22, background: 'rgba(255,255,255,0.1)', flexShrink: 0, margin: '0 2px' }} />
              </>
            )}

            {/* Date picker trigger */}
            <div style={{ position: 'relative' }}>
              <div style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', marginBottom: 2, fontFamily: 'Geist Mono, monospace', textTransform: 'uppercase', letterSpacing: '0.08em' }}>{displayDate}</div>
              <button
                ref={calAnchorRef}
                onClick={() => setCalOpen(o => !o)}
                style={{
                  display: 'flex', alignItems: 'center', gap: 6,
                  padding: '5px 12px',
                  background: calOpen ? 'rgba(74,222,128,0.12)' : 'rgba(255,255,255,0.05)',
                  border: `1px solid ${calOpen ? 'rgba(74,222,128,0.35)' : 'rgba(255,255,255,0.1)'}`,
                  borderRadius: 8, cursor: 'pointer',
                  color: calOpen ? '#4ade80' : 'rgba(245,245,244,0.6)',
                  fontFamily: 'Geist, sans-serif', fontSize: 11,
                  transition: 'all 0.15s',
                }}
              >
                📅 Change dates
              </button>
              {calOpen && (
                <CalendarPopover
                  availableDates={availableDates}
                  selectedDates={selectedDates}
                  onChange={setSelectedDates}
                  onClose={() => setCalOpen(false)}
                  anchorRef={calAnchorRef}
                />
              )}
            </div>

            <div style={{ flex: 1 }} />

            {/* Reports drawer toggle — desktop only */}
            {!isMobile && (
              <button
                onClick={() => setDrawerOpen(true)}
                style={{
                  padding: '6px 14px', fontSize: 12, fontWeight: 600,
                  background: 'rgba(34,211,238,0.08)',
                  border: '1px solid rgba(34,211,238,0.22)',
                  borderRadius: 8, cursor: 'pointer', color: '#22d3ee',
                  fontFamily: 'Geist, sans-serif', whiteSpace: 'nowrap', flexShrink: 0,
                  transition: 'all 0.15s',
                }}
              >
                Reports & Downloads ›
              </button>
            )}
          </div>

          {/* Row 2 — compact filter dropdowns */}
          <div className="sb-filter-row2">

            {/* Activity dropdown */}
            <FilterDropdown
              label="Activity"
              value={activityFilter}
              options={ACTIVITY_OPTIONS}
              onChange={setActivityFilter}
            />

            {/* Parents toggle */}
            <button onClick={() => setIncludeParents(v => !v)} className="sb-filter-btn" style={{
              display: 'flex', alignItems: 'center', gap: 5,
              padding: '5px 11px',
              background: !includeParents ? 'rgba(74,222,128,0.07)' : 'rgba(255,255,255,0.05)',
              border: `1px solid ${!includeParents ? 'rgba(74,222,128,0.3)' : 'rgba(255,255,255,0.1)'}`,
              borderRadius: 8, cursor: 'pointer', fontFamily: 'Geist, sans-serif',
              transition: 'all 0.15s', whiteSpace: 'nowrap',
            }}>
              <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', textTransform: 'uppercase', letterSpacing: '0.08em' }}>Parents</span>
              <span style={{ fontSize: 11, color: !includeParents ? '#4ade80' : 'rgba(245,245,244,0.8)', fontWeight: !includeParents ? 600 : 400 }}>
                {includeParents ? 'Include' : 'Exclude'}
              </span>
            </button>

            {/* Dept dropdown */}
            <FilterDropdown
              label="Dept"
              value={deptFilter}
              options={[{ key: 'all', label: 'All Depts' }, ...depts.map(d => ({ key: d, label: d }))]}
              onChange={key => clickDept(key)}
            />

            {/* Sub-dept dropdown — always visible; shows all sub-depts when no dept selected */}
            <FilterDropdown
              label="Sub-dept"
              value={subDeptFilter}
              options={deptFilter === 'all'
                ? [{ key: 'all', label: 'All Sub-depts' }, ...allSubDepts.map(d => ({ key: d, label: d }))]
                : [{ key: 'all', label: 'All Sub-depts' }, ...subDepts.map(d => ({ key: d, label: d }))]
              }
              onChange={key => clickSubDept(key)}
              emptyMsg="No sub-depts available"
            />

            {(viewsLoading || top20Loading) && (
              <span style={{ fontSize: 10, color: 'rgba(74,222,128,0.6)', fontFamily: 'Geist Mono, monospace', marginLeft: 4, animation: 'pulse 1.5s infinite' }}>loading…</span>
            )}

            {/* Product search — Rule D: below dept/sub-dept chips */}
            <div style={{ width: 1, height: 20, background: 'rgba(255,255,255,0.08)', flexShrink: 0, margin: '0 2px' }} />
            <ProductSearchBar
              storeCodes={storeCodes}
              selectedDates={selectedDates}
              onSelect={handleProductClick}
              onAddToFocus={addToFocus}
              focusBasket={focusBasket}
              deptFilter={deptFilter}
              subDeptFilter={subDeptFilter}
              deptNormMap={deptNormMap}
              searchIndex={searchIndex}
            />

            {/* Mobile Reports button — sits at end of Row 2 */}
            {isMobile && (
              <>
                <div style={{ flex: 1 }} />
                <button
                  onClick={() => setDrawerOpen(true)}
                  style={{
                    padding: '6px 12px', fontSize: 11, fontWeight: 600,
                    background: 'rgba(34,211,238,0.08)',
                    border: '1px solid rgba(34,211,238,0.22)',
                    borderRadius: 8, cursor: 'pointer', color: '#22d3ee',
                    fontFamily: 'Geist, sans-serif', whiteSpace: 'nowrap', flexShrink: 0,
                  }}
                >
                  Reports ›
                </button>
              </>
            )}
          </div>

        </div>
      </div>

      {/* ── MAIN CONTENT ─────────────────────────────────────────────────────── */}
      <div className="sb-page-pad" style={{ width: 'min(100%, 1800px)', margin: '0 auto', paddingBottom: 80, position: 'relative', zIndex: 1 }}>

        {/* ── HEADER ─────────────────────────────────────────────────────────── */}
        <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '20px 0 18px', marginBottom: 20, borderBottom: '1px solid rgba(255,255,255,0.07)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            {/* Logo — replace DaisyLogo with <img src="/logo.png" style={{width:44,height:44,borderRadius:'50%'}} />
                once the real file is saved to socialbrand-dashboard/public/logo.png */}
            <DaisyLogo size={44} />
            <div>
              <h1 style={{ fontFamily: 'Fraunces, Georgia, serif', fontWeight: 600, fontSize: 26, letterSpacing: '-0.02em', lineHeight: 1, margin: 0 }}>
                Social<em style={{ fontStyle: 'italic', fontWeight: 300, color: '#4ade80' }}>Brand</em>
              </h1>
              <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.35)', textTransform: 'uppercase', letterSpacing: '0.14em', marginTop: 4 }}>SocialBrand Pulse</p>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div className="sb-header-context">
              <span style={{ display: 'inline-block', width: 6, height: 6, background: '#4ade80', borderRadius: '50%', marginRight: 6, animation: 'pulse 2s infinite', boxShadow: '0 0 8px #4ade80' }} />
              {activeStoreName || '…'}
              {' · '}{displayDate}
              {' · '}{ACTIVITY_OPTIONS.find(o => o.key === activityFilter)?.label ?? activityFilter}
              {' · '}{includeParents ? 'Inc. Parents' : 'Excl. Parents'}
              {deptFilter    !== 'all' ? ` · ${deptFilter}`    : ''}
              {subDeptFilter !== 'all' ? ` › ${subDeptFilter}` : ''}
            </div>
            <button
              onClick={handleSignOut}
              title="Sign out"
              className="sb-signout-btn"
              style={{
                display: 'flex', alignItems: 'center', gap: 6,
                padding: '5px 10px',
                background: 'rgba(255,255,255,0.04)',
                border: '1px solid rgba(255,255,255,0.1)',
                borderRadius: 8, cursor: 'pointer',
                color: 'rgba(245,245,244,0.45)',
                fontFamily: "'Geist', sans-serif", fontSize: 11,
                whiteSpace: 'nowrap', transition: 'all 0.15s', flexShrink: 0,
              }}
              onMouseOver={e => { e.currentTarget.style.background = 'rgba(255,255,255,0.08)'; e.currentTarget.style.color = '#f5f5f4' }}
              onMouseOut={e => { e.currentTarget.style.background = 'rgba(255,255,255,0.04)'; e.currentTarget.style.color = 'rgba(245,245,244,0.45)' }}
            >
              {userProfile?.full_name?.split(' ')[0] ?? authUser?.email?.split('@')[0] ?? 'Account'}
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>
              </svg>
            </button>
          </div>
        </header>

        <PushStatusStrip />

        <div style={{ display: 'grid', gap: 14 }}>

          {/* ── KPI STRIP ─────────────────────────────────────────────────────── */}
          <div className="sb-kpi-strip">
            {viewsLoading
              ? Array.from({ length: 6 }, (_, i) => (
                  <div key={i} className="sb-glass" style={{ padding: '18px 20px' }}>
                    <Skeleton h={10} w={80} r={4} mb={12} />
                    <Skeleton h={30} w={120} r={6} mb={8} />
                    <Skeleton h={28} w="100%" r={4} mb={8} />
                    <Skeleton h={10} w={140} r={4} />
                  </div>
                ))
              : (() => {
                  const kpiCards = [
                    {
                      key:           'sales',
                      label:         selectedDates.length > 1 ? `Total Sales · ${selectedDates.length} dates` : `Sales · ${selectedDates[0] ?? ''}`,
                      value:         zarShort(kpiSales),
                      sparkline:     sparklineArrays.sales,
                      lyRef:         hasLY ? zarShort(lyKpiSales) : null,
                      lyDelta:       hasLY ? deltaInfo(kpiSales, lyKpiSales) : null,
                      wowDelta:      hasWoW ? deltaInfo(kpiSales, wowKpiSales) : null,
                      bench:         sameWeekdayBenchmark ? `avg ${sameWeekdayBenchmark.dow}: ${zarShort(sameWeekdayBenchmark.avgSales)}` : null,
                      benchN:        sameWeekdayBenchmark?.n,
                      sub:           `${num(kpiQty, 0)} units`,
                      accent:        true,
                    },
                    {
                      key:           'gp',
                      label:         'Gross Profit',
                      value:         pct(kpiGP),
                      sparkline:     sparklineArrays.gpPct,
                      lyRef:         hasLY && lyKpiGP != null ? pct(lyKpiGP) : null,
                      lyDelta:       hasLY && lyKpiGP != null ? ppDeltaInfo(kpiGP, lyKpiGP) : null,
                      wowDelta:      null,
                      bench:         null,
                      sub:           `Cost ${zarShort(kpiCost)}`,
                      warn:          kpiGP < 15,
                    },
                    {
                      key:           'reorder',
                      label:         'Reorder Items',
                      value:         kpiReorder != null ? num(kpiReorder) : '—',
                      sparkline:     null,
                      lyRef:         null,
                      lyDelta:       null,
                      wowDelta:      null,
                      bench:         null,
                      sub:           kpiReorder != null ? 'SOH <= 0 with period sales' : 'Open report drawer',
                      onClick:       () => { setCurrentReport('reorder'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport() },
                      danger:        kpiReorder != null && kpiReorder > 100,
                    },
                    {
                      key:           'slowmovers',
                      label:         'Slow Movers',
                      value:         num(kpiSlowMove),
                      sparkline:     sparklineArrays.slowMovers,
                      lyRef:         hasLY ? num(lyKpiSlowMove) : null,
                      lyDelta:       hasLY ? deltaInfo(kpiSlowMove, lyKpiSlowMove) : null,
                      lyDeltaInvert: true,
                      wowDelta:      null,
                      bench:         null,
                      sub:           'In stock, no period sales',
                      warn:          true,
                      onClick:       () => { setCurrentReport('slowmovers'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport() },
                    },
                    {
                      key:           'negsoh',
                      label:         'Negative SOH',
                      value:         num(kpiNegSOH),
                      sparkline:     sparklineArrays.negSoh,
                      lyRef:         hasLY ? num(lyKpiNegSOH) : null,
                      lyDelta:       hasLY ? deltaInfo(kpiNegSOH, lyKpiNegSOH) : null,
                      lyDeltaInvert: true,
                      wowDelta:      null,
                      bench:         null,
                      sub:           'Stock errors / shrinkage',
                      danger:        kpiNegSOH > 0,
                      onClick:       () => { setCurrentReport('negative'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport() },
                    },
                    {
                      key:           'captied',
                      label:         'Capital Tied',
                      value:         zarShort(kpiCapTied),
                      sparkline:     sparklineArrays.capitalTied,
                      lyRef:         hasLY ? zarShort(lyKpiCapTied) : null,
                      lyDelta:       hasLY ? deltaInfo(kpiCapTied, lyKpiCapTied) : null,
                      lyDeltaInvert: true,
                      wowDelta:      null,
                      bench:         null,
                      sub:           'Slow-mover stock value',
                      warn:          true,
                    },
                  ]
                  return kpiCards.map(k => {
                    const lyUp   = k.lyDelta?.positive
                    const lyGood = k.lyDeltaInvert ? !lyUp : lyUp
                    const wowUp  = k.wowDelta?.positive
                    return (
                      <div key={k.key} className="sb-glass" onClick={k.onClick} style={{
                        padding: '18px 20px',
                        cursor: k.onClick ? 'pointer' : 'default',
                        background: k.accent
                          ? 'linear-gradient(135deg,rgba(74,222,128,0.1),rgba(74,222,128,0.03))'
                          : k.danger && k.value !== '0'
                          ? 'linear-gradient(135deg,rgba(239,68,68,0.09),rgba(239,68,68,0.02))'
                          : k.warn
                          ? 'linear-gradient(135deg,rgba(245,158,11,0.08),rgba(245,158,11,0.02))'
                          : undefined,
                        borderColor: k.accent
                          ? 'rgba(74,222,128,0.22)'
                          : k.danger && k.value !== '0'
                          ? 'rgba(239,68,68,0.18)'
                          : undefined,
                      }}>
                        <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', textTransform: 'uppercase', letterSpacing: '0.12em', marginBottom: 8 }}>{k.label}</p>
                        <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 28, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1,
                          color: k.accent ? '#4ade80' : k.danger && k.value !== '0' ? '#fca5a5' : k.warn ? '#f59e0b' : '#f5f5f4' }}>
                          {k.value}
                        </p>

                        {k.sparkline && (
                          <div style={{ margin: '8px 0 6px', height: 28 }}>
                            <Sparkline
                              values={k.sparkline}
                              color={k.accent ? '#4ade80' : k.warn || k.danger ? '#f59e0b' : 'rgba(245,245,244,0.4)'}
                              height={28}
                            />
                          </div>
                        )}

                        {(k.lyDelta || k.lyRef || k.wowDelta) && (
                          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap', marginTop: k.sparkline ? 4 : 10 }}>
                            {k.lyDelta && (
                              <span style={{
                                fontSize: 10, padding: '2px 6px', borderRadius: 4, fontFamily: "'Geist Mono', monospace",
                                background: lyGood ? 'rgba(74,222,128,0.12)' : 'rgba(239,68,68,0.12)',
                                color:      lyGood ? '#4ade80'               : '#fca5a5',
                              }}>{k.lyDelta.label}</span>
                            )}
                            {k.lyRef && (
                              <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.3)', fontFamily: "'Geist Mono', monospace" }}>
                                LY {k.lyRef}
                              </span>
                            )}
                            {k.wowDelta && (
                              <span style={{
                                fontSize: 10, padding: '2px 5px', borderRadius: 4, fontFamily: "'Geist Mono', monospace",
                                borderLeft: '1px solid rgba(255,255,255,0.1)', paddingLeft: 8, marginLeft: 2,
                                color: wowUp ? 'rgba(74,222,128,0.7)' : 'rgba(239,68,68,0.7)',
                              }}>WoW {k.wowDelta.label}</span>
                            )}
                          </div>
                        )}

                        {k.bench && (
                          <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.2)', fontFamily: "'Geist Mono', monospace", marginTop: 4 }}>
                            {k.bench} ({k.benchN}w avg)
                          </p>
                        )}

                        {!k.lyDelta && !k.lyRef && !k.wowDelta && !k.bench && (
                          <p style={{ fontSize: 11, color: k.onClick ? 'rgba(34,211,238,0.7)' : 'rgba(245,245,244,0.35)', marginTop: 8, fontFamily: "'Geist Mono', monospace", textDecoration: k.onClick ? 'underline' : 'none' }}>
                            {k.sub}
                          </p>
                        )}
                      </div>
                    )
                  })
                })()
            }
          </div>

          {/* ── SALES TREND ──────────────────────────────────────────────────── */}
          <SalesTrendPanel
            trendData={trendData}
            lyTrendData={lyTrendData}
            storeCodes={storeCodes}
            rhythmProfiles={rhythmProfiles}
          />

          {/* ── TOP 20 + DEPT CHART — hidden while a product selection is active ─── */}
          {!isSelectionActive && (
            <div className="sb-two-col">

              {/* Top 20 Movers / Non-Movers */}
              <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
                  <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>
                    {top20Activity === 'movers' ? 'Top 20 Movers' : 'Top 20 Non-Movers'}
                  </span>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <div style={{ display: 'flex', gap: 3, background: 'rgba(255,255,255,0.04)', padding: 3, borderRadius: 8 }}>
                      {['qty', 'value'].map(m => (
                        <button key={m} onClick={() => setMoverMode(m)} style={{ padding: '4px 12px', fontSize: 11, background: moverMode === m ? 'rgba(255,255,255,0.1)' : 'transparent', color: moverMode === m ? '#f5f5f4' : 'rgba(245,245,244,0.4)', border: 'none', borderRadius: 6, cursor: 'pointer', fontFamily: 'Geist, sans-serif', fontWeight: 500, transition: 'all 0.15s' }}>
                          {m === 'qty' ? 'By Qty' : 'By Value'}
                        </button>
                      ))}
                    </div>
                    <div style={{ width: 1, height: 14, background: 'rgba(255,255,255,0.12)', flexShrink: 0 }} />
                    <div style={{ display: 'flex', gap: 3, background: 'rgba(255,255,255,0.04)', padding: 3, borderRadius: 8 }}>
                      {[['movers', 'Movers'], ['non_movers', 'Non-Movers']].map(([act, label]) => (
                        <button key={act} onClick={() => setTop20Activity(act)} style={{ padding: '4px 12px', fontSize: 11, background: top20Activity === act ? 'rgba(255,255,255,0.1)' : 'transparent', color: top20Activity === act ? '#f5f5f4' : 'rgba(245,245,244,0.4)', border: 'none', borderRadius: 6, cursor: 'pointer', fontFamily: 'Geist, sans-serif', fontWeight: 500, transition: 'all 0.15s' }}>
                          {label}
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
                {(viewsLoading || top20Loading)
                  ? <div>{Array.from({ length: 8 }, (_, i) => <Skeleton key={i} h={40} r={8} mb={6} />)}</div>
                  : (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 360, overflowY: 'auto' }}>
                      {top20.length > 0 && (
                        <div style={{ display: 'grid', gridTemplateColumns: '22px 1fr auto auto auto', gap: 8, padding: '0 10px 4px', borderBottom: '1px solid rgba(255,255,255,0.06)', marginBottom: 2 }}>
                          <span />
                          <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.25)', textTransform: 'uppercase', letterSpacing: '0.06em', fontFamily: "'Geist Mono', monospace" }}>Product</span>
                          <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.25)', textTransform: 'uppercase', letterSpacing: '0.06em', fontFamily: "'Geist Mono', monospace", textAlign: 'right' }}>
                            {moverMode === 'qty' ? 'Units' : 'Sales'}
                          </span>
                          <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.25)', textTransform: 'uppercase', letterSpacing: '0.06em', fontFamily: "'Geist Mono', monospace", textAlign: 'right' }}>Cover</span>
                          <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.25)', textTransform: 'uppercase', letterSpacing: '0.06em', fontFamily: "'Geist Mono', monospace", textAlign: 'right' }}>
                            {top20Activity === 'non_movers' ? 'SOH' : 'Avg/day'}
                          </span>
                        </div>
                      )}
                      {top20.length === 0 && (
                        <p style={{ color: 'rgba(245,245,244,0.3)', fontSize: 13, padding: '20px 0', textAlign: 'center', fontStyle: 'italic' }}>
                          {top20Activity === 'non_movers' ? 'No non-moving stock for current filter' : 'No sales data for current filter'}
                        </p>
                      )}
                      {top20.map((r, i) => {
                        const ros = selectedDates.length > 0 ? r.total_qty / selectedDates.length : 0
                        // Days cover from mv_rate_of_sale (pre-computed 91-day rolling window)
                        const dc = eanDaysCoverMap.get(r.ean) ?? null
                        const dcColour = dc == null  ? 'rgba(245,245,244,0.25)'
                                       : dc <= 2     ? '#ef4444'   // red — reorder now
                                       : dc <= 5     ? '#f97316'   // amber — reorder soon
                                       :               'rgba(245,245,244,0.4)'  // normal
                        return (
                          <div key={r.ean} onClick={() => handleProductClick(r)} style={{ display: 'grid', gridTemplateColumns: '22px 1fr auto auto auto', gap: 8, alignItems: 'center', padding: '8px 10px', background: 'rgba(255,255,255,0.025)', borderRadius: 8, cursor: 'pointer' }}>
                            <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 12, fontWeight: 600, color: i < 3 ? '#4ade80' : 'rgba(245,245,244,0.3)', textAlign: 'center' }}>{i + 1}</span>
                            <div style={{ overflow: 'hidden' }}>
                              <p style={{ fontSize: 12, color: '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.description}</p>
                              <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 2 }}>
                                {r.dept_name}
                                {(r.size || r.unit) && (
                                  <span style={{ marginLeft: 6, color: 'rgba(245,245,244,0.25)' }}>
                                    · {[r.size, r.unit].filter(Boolean).join(' ')}
                                  </span>
                                )}
                              </p>
                            </div>
                            <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 12, color: '#4ade80', fontWeight: 500, whiteSpace: 'nowrap' }}>
                              {moverMode === 'qty' ? num(r.total_qty, 0) : zarShort(r.total_sales)}
                            </span>
                            {/* Days cover (91-day rolling ROS from mv_rate_of_sale) */}
                            <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 10, color: dcColour, whiteSpace: 'nowrap', textAlign: 'right' }}>
                              {dc != null
                                ? <>{dc.toFixed(1)}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(245,245,244,0.25)' }}>d</span></>
                                : <span style={{ color: 'rgba(245,245,244,0.15)' }}>—</span>
                              }
                            </span>
                            {top20Activity === 'non_movers'
                              ? <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 10, color: 'rgba(245,245,244,0.4)', whiteSpace: 'nowrap', textAlign: 'right' }}>
                                  {num(r.total_qty, 0)}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(245,245,244,0.25)' }}>u</span>
                                </span>
                              : <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 10, color: 'rgba(245,245,244,0.4)', whiteSpace: 'nowrap', textAlign: 'right' }}>
                                  {ros.toFixed(2)}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(245,245,244,0.25)' }}>u/d</span>
                                </span>
                            }
                          </div>
                        )
                      })}
                    </div>
                  )
                }
              </div>

              {/* Sales by Dept */}
              <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 14 }}>
                  <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Sales by Department</p>
                  {showLYDept && (
                    <span style={{ fontSize: 10, color: 'rgba(74,222,128,0.5)', fontFamily: "'Geist Mono', monospace" }}>vs LY shown</span>
                  )}
                </div>
                {viewsLoading
                  ? <div>{Array.from({ length: 8 }, (_, i) => <Skeleton key={i} h={28} r={4} mb={5} />)}</div>
                  : (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 0, maxHeight: 360, overflowY: 'auto' }}>
                      {deptChart.length === 0 && <p style={{ color: 'rgba(245,245,244,0.3)', fontSize: 13, padding: '20px 0', textAlign: 'center', fontStyle: 'italic' }}>No sales data</p>}
                      {deptChart.map(d => {
                        const lyVal   = lyDeptMap.get(d.name) ?? 0
                        const lyDelta = showLYDept && lyVal > 0 ? ((d.val - lyVal) / lyVal) * 100 : null
                        return (
                          <div key={d.name}
                            onClick={() => clickDept(d.name)}
                            style={{ display: 'grid', gridTemplateColumns: showLYDept ? '1fr 72px 46px 1fr' : '1fr 72px 1fr', gap: 10, alignItems: 'center', padding: '7px 0', borderBottom: '1px dashed rgba(255,255,255,0.04)', opacity: deptFilter !== 'all' && deptFilter !== d.name ? 0.35 : 1, transition: 'opacity 0.2s', cursor: 'pointer' }}>
                            <span style={{ fontSize: 12, color: deptFilter === d.name ? '#4ade80' : '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontWeight: deptFilter === d.name ? 600 : 400 }}>{d.name}</span>
                            <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: '#4ade80', textAlign: 'right' }}>{zarShort(d.val)}</span>
                            {showLYDept && (
                              <span style={{
                                fontFamily: "'Geist Mono', monospace", fontSize: 10, textAlign: 'right',
                                color: lyDelta == null ? 'transparent'
                                     : lyDelta >= 0   ? 'rgba(74,222,128,0.8)'
                                                      : 'rgba(239,68,68,0.8)',
                              }}>
                                {lyDelta == null ? '' : (lyDelta >= 0 ? '+' : '') + lyDelta.toFixed(1) + '%'}
                              </span>
                            )}
                            <div style={{ height: 5, background: 'rgba(255,255,255,0.06)', borderRadius: 999, overflow: 'hidden' }}>
                              <div style={{ height: '100%', width: `${d.pct}%`, background: 'linear-gradient(90deg, #4ade80, #22d3ee)', borderRadius: 999, transition: 'width 0.5s ease' }} />
                            </div>
                          </div>
                        )
                      })}
                    </div>
                  )
                }
              </div>
            </div>
          )}

          {/* ── LOST SALES TRACKER ──────────────────────────────────────────────── */}
          {/* Negative SOH items that sold in the last 3 days — estimated lost revenue */}
          {lostSalesItems.length > 0 && (
            <div className="sb-glass" style={{ padding: '20px 22px', marginBottom: 16 }}>
              {(() => {
                // Aggregate by dept for summary row
                const deptMap = new Map()
                let totalLost = 0
                for (const r of lostSalesItems) {
                  const lostVal = Math.abs(r.soh ?? 0) * (r.sell_price ?? 0)
                  totalLost += lostVal
                  const d = r.dept_name ?? 'Unknown'
                  if (!deptMap.has(d)) deptMap.set(d, { count: 0, lostVal: 0 })
                  const entry = deptMap.get(d)
                  entry.count += 1
                  entry.lostVal += lostVal
                }
                const deptSummary = [...deptMap.entries()]
                  .sort((a, b) => b[1].lostVal - a[1].lostVal)
                  .slice(0, 5)

                return (
                  <>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                        <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Lost Sales</span>
                        <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.25)', borderRadius: 6, padding: '2px 8px' }}>
                          Negative SOH · sold last 3 days
                        </span>
                      </div>
                      <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 16, fontWeight: 700, color: '#ef4444' }}>
                        {zarShort(totalLost)}
                        <span style={{ fontSize: 10, marginLeft: 6, color: 'rgba(239,68,68,0.6)', fontWeight: 400 }}>estimated</span>
                      </span>
                    </div>

                    {/* Dept summary pills */}
                    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
                      {deptSummary.map(([dept, info]) => (
                        <span key={dept} style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.55)', background: 'rgba(239,68,68,0.08)', border: '1px solid rgba(239,68,68,0.2)', borderRadius: 6, padding: '3px 9px' }}>
                          {dept} · {zarShort(info.lostVal)} ({info.count})
                        </span>
                      ))}
                    </div>

                    {/* Product rows — top 10 by lost value */}
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {lostSalesItems
                        .slice()
                        .sort((a, b) => (Math.abs(b.soh ?? 0) * (b.sell_price ?? 0)) - (Math.abs(a.soh ?? 0) * (a.sell_price ?? 0)))
                        .slice(0, 10)
                        .map(r => {
                          const lostVal  = Math.abs(r.soh ?? 0) * (r.sell_price ?? 0)
                          const timeline = lostSalesTimeline.get(r.ean) ?? []
                          return (
                            <div key={r.ean} style={{ padding: '8px 10px', background: 'rgba(239,68,68,0.05)', borderRadius: 8, borderLeft: '2px solid rgba(239,68,68,0.3)' }}>

                              {/* Top row: name + numbers */}
                              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto auto', gap: 10, alignItems: 'center', marginBottom: timeline.length ? 8 : 0 }}>
                                <div style={{ overflow: 'hidden' }}>
                                  <p style={{ fontSize: 12, color: '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.description}</p>
                                  <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 1 }}>{r.dept_name}</p>
                                </div>
                                <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: '#ef4444', whiteSpace: 'nowrap' }}>
                                  {r.soh}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(239,68,68,0.5)' }}>SOH</span>
                                </span>
                                <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: 'rgba(245,245,244,0.4)', whiteSpace: 'nowrap' }}>
                                  {zarShort(r.sell_price)}
                                </span>
                                <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 12, color: '#ef4444', fontWeight: 600, whiteSpace: 'nowrap' }}>
                                  {zarShort(lostVal)}
                                </span>
                              </div>

                              {/* Timeline bar — 28-day availability strip */}
                              {timelineLoading && !timeline.length ? (
                                <div style={{ height: 10, background: 'rgba(255,255,255,0.04)', borderRadius: 4, animation: 'pulse 1.5s infinite' }} />
                              ) : timeline.length > 0 ? (
                                <div style={{ display: 'flex', gap: 2, alignItems: 'center' }}>
                                  {/* Date label left */}
                                  <span style={{ fontSize: 8, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.2)', flexShrink: 0, marginRight: 2 }}>
                                    {timeline[0]?.snap_date?.slice(5)}
                                  </span>
                                  {/* Bars */}
                                  <div style={{ display: 'flex', gap: 1.5, flex: 1, alignItems: 'center' }}>
                                    {timeline.map(day => {
                                      const bg = day.sold_bool
                                        ? '#4ade80'                        // green — sold
                                        : day.oos_bool
                                          ? 'rgba(239,68,68,0.75)'        // red — OOS
                                          : 'rgba(255,255,255,0.07)'      // grey — no movement, in stock
                                      const title = `${day.snap_date}: ${day.sold_bool ? 'sold' : day.oos_bool ? 'OOS' : 'no movement'} · SOH ${day.soh}`
                                      return (
                                        <div
                                          key={day.snap_date}
                                          title={title}
                                          style={{
                                            flex: 1,
                                            height: 10,
                                            background: bg,
                                            borderRadius: 2,
                                            transition: 'background 0.15s',
                                          }}
                                        />
                                      )
                                    })}
                                  </div>
                                  {/* Date label right */}
                                  <span style={{ fontSize: 8, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.2)', flexShrink: 0, marginLeft: 2 }}>
                                    {timeline[timeline.length - 1]?.snap_date?.slice(5)}
                                  </span>
                                </div>
                              ) : null}
                            </div>
                          )
                        })
                      }
                    </div>

                    {lostSalesItems.length > 10 && (
                      <p style={{ marginTop: 10, fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.3)', textAlign: 'center' }}>
                        + {lostSalesItems.length - 10} more lines · open Lost Sales report for full list
                      </p>
                    )}
                  </>
                )
              })()}
            </div>
          )}

          {/* ── PRODUCT DETAIL PANELS ─────────────────────────────────────────── */}
          {/* One card per active product, stacked vertically.                     */}
          {/* isSelectionActive hides Top 20 + Sales by Dept above.                */}
          <div ref={panelRef}>
            {activeProducts.map(p => {
              const pEan = String(p['EAN'] ?? p.ean ?? '')
              const pKey = `${pEan}|${p.description ?? p['Description'] ?? ''}`
              const handleClose = selectedProduct != null
                ? () => setSelectedProduct(null)
                : () => removeFromFocus(p)
              return (
                <ProductDetailPanelConnected
                  key={pKey}
                  product={p}
                  storeCodes={storeCodes}
                  storeMap={STORE_MAP}
                  availableDates={availableDates}
                  onClose={handleClose}
                  compact={activeProducts.length > 1}
                />
              )
            })}
          </div>

          {/* ── FOCUS AREA PANEL ──────────────────────────────────────────────── */}
          {/* Always visible at the bottom whenever dates are loaded.              */}
          {selectedDates.length > 0 && (
            <FocusAreaPanel
              basket={focusBasket}
              onRemove={removeFromFocus}
              onClear={clearFocus}
              selectedDates={selectedDates}
              allStoreCodes={storeCodes}
              isDefault={isDefaultBasket}
            />
          )}

          {/* ── FOOTER ───────────────────────────────────────────────────────── */}
          <div style={{ padding: '28px 0 12px', textAlign: 'center' }}>
            <a
              href="/diagnostics.html"
              target="_blank"
              rel="noreferrer"
              style={{ fontSize: 11, color: 'rgba(245,245,244,0.18)', fontFamily: "'Geist Mono', monospace", textDecoration: 'none', letterSpacing: '0.06em' }}
            >
              Data Quality
            </a>
          </div>

        </div>
      </div>

      {/* ── REPORTS DRAWER ───────────────────────────────────────────────────── */}
      {drawerOpen && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 500 }}>
          {/* Backdrop */}
          <div
            style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.5)' }}
            onClick={() => setDrawerOpen(false)}
          />
          {/* Panel */}
          <div className="sb-drawer-panel">
            {/* Drawer header */}
            <div style={{ padding: '18px 22px 14px', borderBottom: '1px solid rgba(255,255,255,0.08)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexShrink: 0 }}>
              <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 18, fontWeight: 600 }}>Reports & Downloads</p>
              <button onClick={() => setDrawerOpen(false)} style={{ background: 'none', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 6, color: 'rgba(245,245,244,0.5)', cursor: 'pointer', padding: '4px 10px', fontSize: 12, fontFamily: 'Geist, sans-serif' }}>✕ Close</button>
            </div>

            {/* Context line */}
            <div style={{ padding: '8px 22px', borderBottom: '1px solid rgba(255,255,255,0.05)', flexShrink: 0 }}>
              <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace" }}>
                {activeStoreName} · {displayDate}
                {deptFilter !== 'all' ? ` · ${deptFilter}` : ''}
                {reportLoaded ? ` · ${num(filteredReportRows.length)} rows` : ' · no report loaded'}
              </p>
            </div>

            {/* Report cards */}
            <div className="sb-report-grid" style={{ padding: '14px 18px', flexShrink: 0 }}>
              {REPORTS.map(r => (
                <button key={r.key} className={`sb-report-card${currentReport === r.key ? ' on' : ''}`}
                  onClick={() => handleReportCardClick(r.key)}>
                  <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 12, fontWeight: 600, marginBottom: 2 }}>{r.title}</p>
                  <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.45)', lineHeight: 1.4 }}>{r.desc}</p>
                  {currentReport === r.key && reportLoaded && (
                    <p style={{ position: 'absolute', top: 10, right: 12, fontFamily: "'Geist Mono', monospace", fontSize: 8, color: '#4ade80', letterSpacing: '0.08em', textTransform: 'uppercase' }}>Active</p>
                  )}
                </button>
              ))}
            </div>

            {/* Download button */}
            <div style={{ padding: '0 18px 14px', flexShrink: 0 }}>
              {reportLoading && (
                <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.4)', fontFamily: "'Geist Mono', monospace", textAlign: 'center', marginBottom: 8, animation: 'pulse 1.5s infinite' }}>Fetching report data…</p>
              )}
              <button
                onClick={() => downloadExcel(reportData, currentReport, activeStoreName, selectedDates.length === 1 ? selectedDates[0] : null)}
                disabled={reportData.length === 0}
                style={{ width: '100%', padding: '10px 22px', fontFamily: 'Geist, sans-serif', fontSize: 13, fontWeight: 600, background: reportData.length === 0 ? 'rgba(255,255,255,0.06)' : 'linear-gradient(135deg, #4ade80, #22d3ee)', color: reportData.length === 0 ? 'rgba(245,245,244,0.25)' : '#0a0e1a', border: 'none', borderRadius: 10, cursor: reportData.length === 0 ? 'not-allowed' : 'pointer', transition: 'all 0.2s', boxShadow: reportData.length === 0 ? 'none' : '0 8px 24px rgba(74,222,128,0.25)' }}
              >
                ↓ Download {activeReportDef?.title} as Excel
              </button>
            </div>

            {/* Preview table */}
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', borderTop: '1px solid rgba(255,255,255,0.07)', overflow: 'hidden' }}>
              {!reportLoaded ? (
                reportLoading ? (
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 32, gap: 12 }}>
                    <div style={{ width: 36, height: 36, border: '3px solid rgba(74,222,128,0.2)', borderTopColor: '#4ade80', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
                    <p style={{ fontFamily: "'Geist Mono', monospace", fontSize: 12, color: 'rgba(245,245,244,0.4)' }}>Fetching report data…</p>
                  </div>
                ) : (
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 32, gap: 16 }}>
                    <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 15, fontStyle: 'italic', color: 'rgba(245,245,244,0.3)', textAlign: 'center' }}>
                      Select a report above to load data
                    </p>
                    <button onClick={loadReport}
                      style={{ padding: '10px 24px', fontFamily: 'Geist, sans-serif', fontSize: 13, fontWeight: 600, background: 'linear-gradient(135deg, #4ade80, #22d3ee)', color: '#0a0e1a', border: 'none', borderRadius: 10, cursor: 'pointer', boxShadow: '0 8px 24px rgba(74,222,128,0.25)' }}>
                      Load Report Data
                    </button>
                  </div>
                )
              ) : reportData.length === 0 ? (
                <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 32 }}>
                  <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 15, fontStyle: 'italic', color: 'rgba(245,245,244,0.3)', textAlign: 'center' }}>No rows match current filters</p>
                </div>
              ) : (
                <>
                  <div style={{ flex: 1, overflow: 'auto' }}>
                    <table className="sb-table" style={{ tableLayout: 'auto', width: '100%' }}>
                      <thead>
                        <tr>
                          {Object.keys(reportData[0]).map(col => {
                            const isNum = typeof reportData[0][col] === 'number'
                            return <th key={col} className={isNum ? 'r' : ''}>{col}</th>
                          })}
                        </tr>
                      </thead>
                      <tbody>
                        {reportData.slice(0, PAGE_SIZE).map((row, i) =>
                          renderTableRow(row, i, r => { handleProductClick(r); setDrawerOpen(false) })
                        )}
                      </tbody>
                    </table>
                  </div>
                  <div style={{ padding: '10px 18px', borderTop: '1px solid rgba(255,255,255,0.06)', fontFamily: "'Geist Mono', monospace", fontSize: 10, color: 'rgba(245,245,244,0.3)', textAlign: 'center', textTransform: 'uppercase', letterSpacing: '0.08em', flexShrink: 0 }}>
                    {reportData.length <= PAGE_SIZE
                      ? `${num(reportData.length)} rows`
                      : `Showing ${PAGE_SIZE} of ${num(reportData.length)} — download for full data`
                    }
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
