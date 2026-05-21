'use client'

import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import * as XLSX from 'xlsx'
import { ProductDetailPanelConnected } from '@/components/ProductDetailPanel'
import { FocusAreaPanel }    from '@/components/FocusAreaPanel'
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
function buildReport(report, rows, moverMode, refDate, rosMap = new Map()) {
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
      <button onClick={() => setOpen(o => !o)} style={{
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
function ProductSearchBar({ storeCodes, selectedDates, onSelect, onAddToFocus, focusBasket, deptFilter, subDeptFilter, deptNormMap }) {
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
  useEffect(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    if (query.trim().length < 2) { setResults([]); setOpen(false); return }
    timerRef.current = setTimeout(async () => {
      setLoading(true)
      const q = query.trim()
      // Search uses rpc_search_products (SECURITY DEFINER) — direct daily_snapshots
      // reads are blocked by RLS for the anon key.
      const latestDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
      if (!latestDate) { setResults([]); setOpen(false); setLoading(false); return }

      const hasContext = (deptFilter && deptFilter !== 'all') || (subDeptFilter && subDeptFilter !== 'all')
      const fetchLimit = hasContext ? 100 : Math.min(50 * (storeCodes.length || 1), 1000)

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
      setResults(unique)
      setOpen(true)
      setLoading(false)
    }, 300)
  }, [query, storeCodes, selectedDates])

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
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────────────────────
export default function Home() {
  // ── dates & stores ──────────────────────────────────────────────────────────
  const [availableDates, setAvailableDates] = useState([])
  const [selectedDates,  setSelectedDates]  = useState([])
  const [storeCodes,     setStoreCodes]     = useState([...ALL_STORE_CODES])
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
  const [currentReport, setCurrentReport] = useState('diwaais')
  const [moverMode,     setMoverMode]     = useState('qty')

  // ── aggregation view data ────────────────────────────────────────────────────
  const [kpiData,      setKpiData]      = useState([])
  const [deptSummary,  setDeptSummary]  = useState([])   // rpc_dept_summary — one aggregated row per dept
  const [top20Data,    setTop20Data]    = useState([])   // rpc_top20 — up to 40 pre-aggregated rows
  const [deptNormMap,  setDeptNormMap]  = useState(new Map())
  const [viewsLoading, setViewsLoading] = useState(false)
  const [top20Loading, setTop20Loading] = useState(false)

  // ── dept/sub-dept chips ─────────────────────────────────────────────────────
  const [depts,       setDepts]       = useState([])
  const [subDepts,    setSubDepts]    = useState([])   // filtered by selected dept
  const [allSubDepts, setAllSubDepts] = useState([])   // all sub-depts for current store+date

  // ── report data (on-demand) ──────────────────────────────────────────────────
  const [reportRows,    setReportRows]    = useState([])
  const [reportLoaded,  setReportLoaded]  = useState(false)
  const [reportLoading, setReportLoading] = useState(false)
  const [storeRosData,  setStoreRosData]  = useState([])

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

  // Auto-populate Focus Area with the top 5 products by period sales value.
  // Uses rpc_focus_top5 (SECURITY DEFINER) — direct daily_snapshots reads are
  // blocked by RLS for the anon key.  Clear the basket immediately so stale
  // chips don't linger when the store / date selection changes.
  useEffect(() => {
    if (!isDefaultBasket) return
    if (!storeCodes.length || !selectedDates.length) return

    setFocusBasket([])   // clear immediately so old data never lingers

    supabase.rpc('rpc_focus_top5', {
      p_store_codes: storeCodes,
      p_dates:       selectedDates,
      p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
      p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
    }).then(({ data, error }) => {
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

  // ── on mount: load ALL available dates ──────────────────────────────────────
  // v_kpi_by_date has one row per store per date (5 rows/date), so we paginate
  // in 1 000-row batches to capture every date in the database — past and future.
  useEffect(() => {
    async function init() {
      const allDates = new Set()
      let from = 0
      const batchSize = 1000
      while (true) {
        const { data, error } = await supabase
          .from('mv_kpi_by_date')
          .select('snapshot_date')
          .order('snapshot_date', { ascending: false })
          .range(from, from + batchSize - 1)
        if (error || !data?.length) break
        data.forEach(r => allDates.add(r.snapshot_date))
        if (data.length < batchSize) break
        from += batchSize
      }
      if (!allDates.size) return
      const unique = [...allDates].sort((a, b) => b.localeCompare(a))
      setAvailableDates(unique)
      setSelectedDates([unique[0]])
      setStoreCodes([...ALL_STORE_CODES])
    }
    init()
  }, [])

  // ── fetch KPI + dept summary on store / date change (server-side aggregation via RPC) ──
  useEffect(() => {
    if (!storeCodes.length || !selectedDates.length) return
    let cancelled = false

    async function loadViews() {
      setViewsLoading(true)
      setReportRows([])
      setReportLoaded(false)
      setStoreRosData([])
      setSelectedProduct(null)

      const [kpiRes, deptRes, subDeptRes] = await Promise.all([
        supabase.from('mv_kpi_by_date')
          .select('store_code,store_name,snapshot_date,total_sales,total_cost,total_qty,neg_soh_count,slow_mover_count')
          .in('store_code', storeCodes)
          .in('snapshot_date', selectedDates),
        // rpc_dept_summary: Postgres aggregates across ALL stores+dates before returning.
        // Returns one row per dept — no row-cap risk, accurate multi-date sums.
        // No is_placeholder filter — matches v_kpi_by_date which also includes all rows,
        // and ensures service depts (HMR, Deli, Butchery) appear in dept chips.
        supabase.rpc('rpc_dept_summary', {
          p_store_codes: storeCodes,
          p_dates:       selectedDates,
        }),
        // All unique sub-dept names for the current store+date — powers the
        // sub-dept dropdown when no dept filter is selected.
        // rpc_subdepts is SECURITY DEFINER — direct daily_snapshots reads are blocked by RLS.
        supabase.rpc('rpc_subdepts', {
          p_store_codes: storeCodes,
          p_dates:       selectedDates,
          p_dept_names:  null,
        }),
      ])

      if (cancelled) return
      if (kpiRes.error)  console.error('[v_kpi_by_date]',    kpiRes.error.message)
      if (deptRes.error) console.error('[rpc_dept_summary]', deptRes.error.message)
      setKpiData(kpiRes.data    ?? [])
      setDeptSummary(deptRes.data ?? [])
      const allSubs = [...new Set((subDeptRes.data ?? []).map(r => r.sub_dept_name))].filter(Boolean).sort()
      setAllSubDepts(allSubs)
      setViewsLoading(false)
    }

    loadViews()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates])

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
      setTop20Loading(true)
      const { data, error } = await supabase.rpc('rpc_top20', {
        p_store_codes: storeCodes,
        p_dates:       selectedDates,
        p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
        p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
      })
      if (cancelled) return
      if (error) console.error('[rpc_top20]', error.message)
      setTop20Data(data ?? [])
      setTop20Loading(false)
    }

    loadTop20()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates, deptFilter, subDeptFilter])

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

    const [rows, rosRes] = await Promise.all([
      fetchAllRows({ storeCodes, dates: selectedDates }),
      supabase
        .from('v_rate_of_sale')
        .select('ean,store_code,daily_ros,days_cover')
        .in('store_code', storeCodes)
        .then(r => r.data ?? [])
        .catch(() => []),
    ])

    setReportRows(rows)
    setStoreRosData(rosRes)
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

  const reportData = useMemo(() => {
    if (!reportLoaded) return []
    const refDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
    return buildReport(currentReport, filteredReportRows, moverMode, refDate, rosMap)
  }, [currentReport, filteredReportRows, moverMode, selectedDates, reportLoaded, rosMap])

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

  // deptSummary already has one pre-summed row per dept (from rpc_dept_summary)
  const kpiSales = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_sales ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_sales ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter])

  const kpiCost = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_cost ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_cost ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter])

  const kpiQty = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_qty ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_qty ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter])

  const kpiGP       = kpiSales > 0 ? gpPct(kpiSales, kpiCost) : 0
  const kpiNegSOH   = latestKpiByStore.reduce((s, r) => s + (r.neg_soh_count   ?? 0), 0)
  const kpiSlowMove = latestKpiByStore.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
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

  // ── top 20 — RPC already aggregated + filtered; just sort and slice ──────────
  const top20 = useMemo(() => {
    return moverMode === 'qty'
      ? [...top20Data].filter(r => (r.total_qty   ?? 0) > 0).sort((a, b) => (b.total_qty   ?? 0) - (a.total_qty   ?? 0)).slice(0, 20)
      : [...top20Data].filter(r => (r.total_sales ?? 0) > 0).sort((a, b) => (b.total_sales ?? 0) - (a.total_sales ?? 0)).slice(0, 20)
  }, [top20Data, moverMode])

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
    setStoreCodes([...ALL_STORE_CODES])
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
  const activeProducts = (focusBasket.length > 0 && !isDefaultBasket)
    ? focusBasket
    : selectedProduct
      ? [selectedProduct]
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
        <div style={{ width: 'min(100%, 1800px)', margin: '0 auto', padding: '10px 32px' }}>

          {/* Row 1 — stores + date + reports button */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center', marginBottom: 8 }}>

            {/* Store shortcuts */}
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

            {/* Reports drawer toggle */}
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
          </div>

          {/* Row 2 — compact filter dropdowns */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center' }}>

            {/* Activity dropdown */}
            <FilterDropdown
              label="Activity"
              value={activityFilter}
              options={ACTIVITY_OPTIONS}
              onChange={setActivityFilter}
            />

            {/* Parents toggle */}
            <button onClick={() => setIncludeParents(v => !v)} style={{
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
            />
          </div>

        </div>
      </div>

      {/* ── MAIN CONTENT ─────────────────────────────────────────────────────── */}
      <div style={{ width: 'min(100%, 1800px)', margin: '0 auto', padding: '0 32px 80px', position: 'relative', zIndex: 1 }}>

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
          <div style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: 'rgba(245,245,244,0.5)', textAlign: 'right', lineHeight: 1.6 }}>
            <span style={{ display: 'inline-block', width: 6, height: 6, background: '#4ade80', borderRadius: '50%', marginRight: 6, animation: 'pulse 2s infinite', boxShadow: '0 0 8px #4ade80' }} />
            {activeStoreName || '…'}
            {' · '}{displayDate}
            {' · '}{ACTIVITY_OPTIONS.find(o => o.key === activityFilter)?.label ?? activityFilter}
            {' · '}{includeParents ? 'Inc. Parents' : 'Excl. Parents'}
            {deptFilter    !== 'all' ? ` · ${deptFilter}`    : ''}
            {subDeptFilter !== 'all' ? ` › ${subDeptFilter}` : ''}
          </div>
        </header>

        <PushStatusStrip />

        <div style={{ display: 'grid', gap: 14 }}>

          {/* ── KPI STRIP ─────────────────────────────────────────────────────── */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12 }}>
            {viewsLoading
              ? Array.from({ length: 5 }, (_, i) => (
                  <div key={i} className="sb-glass" style={{ padding: '18px 20px' }}>
                    <Skeleton h={10} w={80} r={4} mb={12} />
                    <Skeleton h={30} w={120} r={6} mb={10} />
                    <Skeleton h={10} w={100} r={4} />
                  </div>
                ))
              : [
                  { label: selectedDates.length > 1
                      ? `Total Sales · ${selectedDates.length} dates`
                      : selectedDates[0] === availableDates[0]
                        ? "Yesterday's Sales"
                        : `Sales · ${selectedDates[0] ?? ''}`,
                    value: zarShort(kpiSales), sub: `${num(kpiQty, 0)} units`, accent: true },
                  { label: 'Gross Profit',  value: pct(kpiGP),          sub: `Cost ${zarShort(kpiCost)}`, warn: kpiGP < 15 },
                  { label: 'Reorder Items', value: kpiReorder != null ? num(kpiReorder) : '—', sub: kpiReorder != null ? 'SOH ≤ 0 with period sales' : 'Open report drawer', onSub: kpiReorder == null ? () => setDrawerOpen(true) : undefined, danger: kpiReorder != null && kpiReorder > 100 },
                  { label: 'Slow Movers',   value: num(kpiSlowMove), sub: 'In stock, no period sales', warn: true },
                  { label: 'Negative SOH',  value: num(kpiNegSOH),   sub: 'Stock errors / shrinkage', danger: kpiNegSOH > 0 },
                ].map(k => (
                  <div key={k.label} className="sb-glass" style={{
                    padding: '18px 20px',
                    background: k.accent ? 'linear-gradient(135deg,rgba(74,222,128,0.1),rgba(74,222,128,0.03))' :
                      k.danger && k.value !== '0' ? 'linear-gradient(135deg,rgba(239,68,68,0.09),rgba(239,68,68,0.02))' :
                      k.warn ? 'linear-gradient(135deg,rgba(245,158,11,0.08),rgba(245,158,11,0.02))' : undefined,
                    borderColor: k.accent ? 'rgba(74,222,128,0.22)' :
                      k.danger && k.value !== '0' ? 'rgba(239,68,68,0.18)' : undefined,
                  }}>
                    <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', textTransform: 'uppercase', letterSpacing: '0.12em', marginBottom: 10 }}>{k.label}</p>
                    <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 28, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1, color: k.accent ? '#4ade80' : k.danger && k.value !== '0' ? '#fca5a5' : k.warn ? '#f59e0b' : '#f5f5f4' }}>{k.value}</p>
                    <p onClick={k.onSub} style={{ fontSize: 11, color: k.onSub ? 'rgba(34,211,238,0.7)' : 'rgba(245,245,244,0.35)', marginTop: 8, fontFamily: "'Geist Mono', monospace", cursor: k.onSub ? 'pointer' : 'default', textDecoration: k.onSub ? 'underline' : 'none' }}>{k.sub}</p>
                  </div>
                ))
            }
          </div>

          {/* ── TOP 20 + DEPT CHART — hidden while a product selection is active ─── */}
          {!isSelectionActive && (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>

              {/* Top 20 Movers */}
              <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 14 }}>
                  <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Top 20 Movers</span>
                  <div style={{ display: 'flex', gap: 3, background: 'rgba(255,255,255,0.04)', padding: 3, borderRadius: 8 }}>
                    {['qty', 'value'].map(m => (
                      <button key={m} onClick={() => setMoverMode(m)} style={{ padding: '4px 12px', fontSize: 11, background: moverMode === m ? 'rgba(255,255,255,0.1)' : 'transparent', color: moverMode === m ? '#f5f5f4' : 'rgba(245,245,244,0.4)', border: 'none', borderRadius: 6, cursor: 'pointer', fontFamily: 'Geist, sans-serif', fontWeight: 500, transition: 'all 0.15s' }}>
                        {m === 'qty' ? 'By Qty' : 'By Value'}
                      </button>
                    ))}
                  </div>
                </div>
                {(viewsLoading || top20Loading)
                  ? <div>{Array.from({ length: 8 }, (_, i) => <Skeleton key={i} h={40} r={8} mb={6} />)}</div>
                  : (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 360, overflowY: 'auto' }}>
                      {top20.length === 0 && <p style={{ color: 'rgba(245,245,244,0.3)', fontSize: 13, padding: '20px 0', textAlign: 'center', fontStyle: 'italic' }}>No sales data for current filter</p>}
                      {top20.map((r, i) => {
                        const ros = selectedDates.length > 0 ? r.total_qty / selectedDates.length : 0
                        return (
                          <div key={r.ean} onClick={() => handleProductClick(r)} style={{ display: 'grid', gridTemplateColumns: '22px 1fr auto auto', gap: 10, alignItems: 'center', padding: '8px 10px', background: 'rgba(255,255,255,0.025)', borderRadius: 8, cursor: 'pointer' }}>
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
                            <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 10, color: 'rgba(245,245,244,0.4)', whiteSpace: 'nowrap', textAlign: 'right' }}>
                              {ros.toFixed(2)}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(245,245,244,0.25)' }}>u/d</span>
                            </span>
                          </div>
                        )
                      })}
                    </div>
                  )
                }
              </div>

              {/* Sales by Dept */}
              <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
                <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600, marginBottom: 14 }}>Sales by Department</p>
                {viewsLoading
                  ? <div>{Array.from({ length: 8 }, (_, i) => <Skeleton key={i} h={28} r={4} mb={5} />)}</div>
                  : (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 0, maxHeight: 360, overflowY: 'auto' }}>
                      {deptChart.length === 0 && <p style={{ color: 'rgba(245,245,244,0.3)', fontSize: 13, padding: '20px 0', textAlign: 'center', fontStyle: 'italic' }}>No sales data</p>}
                      {deptChart.map(d => (
                        <div key={d.name}
                          onClick={() => clickDept(d.name)}
                          style={{ display: 'grid', gridTemplateColumns: '1fr 72px 1fr', gap: 12, alignItems: 'center', padding: '7px 0', borderBottom: '1px dashed rgba(255,255,255,0.04)', opacity: deptFilter !== 'all' && deptFilter !== d.name ? 0.35 : 1, transition: 'opacity 0.2s', cursor: 'pointer' }}>
                          <span style={{ fontSize: 12, color: deptFilter === d.name ? '#4ade80' : '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontWeight: deptFilter === d.name ? 600 : 400 }}>{d.name}</span>
                          <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: '#4ade80', textAlign: 'right' }}>{zarShort(d.val)}</span>
                          <div style={{ height: 5, background: 'rgba(255,255,255,0.06)', borderRadius: 999, overflow: 'hidden' }}>
                            <div style={{ height: '100%', width: `${d.pct}%`, background: 'linear-gradient(90deg, #4ade80, #22d3ee)', borderRadius: 999, transition: 'width 0.5s ease' }} />
                          </div>
                        </div>
                      ))}
                    </div>
                  )
                }
              </div>
            </div>
          )}

          {/* ── PRODUCT DETAIL PANELS ─────────────────────────────────────────── */}
          {/* One card per active product, stacked vertically.                     */}
          {/* isSelectionActive hides Top 20 + Sales by Dept above.                */}
          <div ref={panelRef}>
            {activeProducts.map(p => {
              const pEan = String(p['EAN'] ?? p.ean ?? '')
              const pKey = `${pEan}|${p.description ?? p['Description'] ?? ''}`
              const handleClose = (focusBasket.length > 0 && !isDefaultBasket)
                ? () => removeFromFocus(p)
                : () => setSelectedProduct(null)
              return (
                <ProductDetailPanelConnected
                  key={pKey}
                  product={p}
                  storeCodes={storeCodes}
                  storeMap={STORE_MAP}
                  availableDates={availableDates}
                  onClose={handleClose}
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
          <div style={{
            position: 'absolute', top: 0, right: 0, bottom: 0, width: 460,
            background: 'rgba(10,14,26,0.98)',
            borderLeft: '1px solid rgba(255,255,255,0.1)',
            backdropFilter: 'blur(32px)',
            display: 'flex', flexDirection: 'column',
            zIndex: 1,
          }}>
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
            <div style={{ padding: '14px 18px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, flexShrink: 0 }}>
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
