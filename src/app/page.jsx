'use client'

import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { createPortal } from 'react-dom'
import { supabase } from '@/lib/supabase'
import * as XLSX from 'xlsx'
import { FocusAreaPanel }    from '@/components/FocusAreaPanel'
import { SalesTrendPanel }   from '@/components/SalesTrendPanel'
import { CalendarPopover } from '@/components/CalendarPopover'
import PushStatusStrip from '@/components/PushStatusStrip'
import ConsignmentPanel from '@/components/ConsignmentPanel'
import KpiStrip from '@/components/KpiStrip'
import './dashboard.css'

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────
const MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December']

// Business rule constants — will move to DB client_config once portability phase begins
const SLOW_MOVER_DAYS          = 14    // fixed slow-mover window, independent of date picker
const ACTIVE_LINE_LOOKBACK     = 364   // active-line filter — must have sold in last 364 days
const LY_SHIFT_DAYS            = 364   // LY date shift — 52 weeks preserves day-of-week
const TREND_WINDOW_DAYS        = 91    // Sales Trend span — 13 weeks back from the most recent push date
const SIGNAL_C_THRESHOLD       = 1.0   // phantom stock: flag when days_since_sale x daily_ros >= this
const TOP_TIER_RANK_CUTOFF     = 100   // ranging tier: top tier value + volume rank cutoff
const MID_TIER_RANK_CUTOFF     = 1000  // ranging tier: mid tier rank cutoff
const TARGET_DAYS_COVER_TOP    = 15    // days cover target for Top 100 / Top 1000 lines
const TARGET_DAYS_COVER_STANDARD = 30  // days cover target: 12 turns/year standard

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
  { key: 'diwaais',         title: 'DIWAAIS',           desc: 'Sigma-style ordering report' },
  { key: 'period_sales',    title: 'Period Sales',       desc: 'Items sold in selected period — GP% and ROS included' },
  { key: 'velocity',        title: 'Velocity Report',    desc: 'ROS vs 13-week baseline — accelerators and decelerators' },
  { key: 'lostsales',       title: 'Lost Sales',         desc: 'True OOS — SOH <= 0, no period sales, active line' },
  { key: 'ledger_discrepancy', title: 'Stock Ledger Discrepancy', desc: 'Selling despite SOH <= 0 — receiving errors or unrecorded waste' },
  { key: 'deptsummary',     title: 'Dept Summary',       desc: 'Sales, cost and GP% per department' },
  { key: 'dept_margin',     title: 'Dept Margin Trend',  desc: 'GP% by dept vs same period LY' },
  { key: 'slowmovers',      title: 'Slow Movers',        desc: 'In stock, no sales in last 14 days — capital tied' },
  { key: 'stock_integrity', title: 'Stock Integrity',    desc: 'Negative SOH — Type A (production) / Type B (receiving)' },
  { key: 'focus_export',    title: 'Focus Area Export',  desc: 'Download current basket with all columns' },
  { key: 'ghost_stock',     title: 'Ghost Stock',         desc: 'Production items removed from Capital Tied — fix at source in Sigma' },
  { key: 'full',            title: 'Data Export',        desc: 'All fields — for analysts and system integrations' },
  { key: 'consignment',     title: 'Sushi Consignment',  desc: 'HMR SUSHI — exact ledger source, feed health and supplier liability' },
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
  // Tier 1: raw unit_cost from daily_snapshots (Sigma PRSSALE source)
  if (row.unit_cost != null && row.unit_cost > 0) return row.unit_cost
  // Tier 2: derive from period_cost / period_qty — backed by actual data for this item
  if (row.period_qty && row.period_qty !== 0) return (row.period_cost ?? 0) / Math.abs(row.period_qty)
  // No data available — return 0. Do NOT assume a margin percentage (Rule Book: no assumed rates).
  // Capital tied for these rows will be 0 (understated but not invented).
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
// CC-BRIEF-DASH-FINAL-001 item 1: rpc_report_rows (SECURITY DEFINER, own 15s
// statement_timeout) returns the FULL drawer dataset as one jsonb array —
// one row per (store, product) with activity in the selection (sold on the
// selected dates, sold MTD at the last selected date, or SOH ≠ 0 at the
// store's latest snapshot). Replaces the paged rpc_all_rows loop (27.8s per
// 1 000-row page, died at the 8s authenticator timeout on every call) and its
// 10 000-row truncation cap — the returned totals now reconcile to
// sigma_sales (R22). Rows arrive already date-merged: today_* summed over the
// selected dates, period_* = MTD at the max selected date, soh at the store's
// latest snapshot ≤ the selection end. Each row also carries daily_ros /
// days_cover / tier / class from the engine (l2_stock_position).
// ─────────────────────────────────────────────────────────────────────────────
async function fetchAllRows({ storeCodes, dates }) {
  if (!storeCodes.length || !dates.length) return []
  const { data, error } = await supabase.rpc('rpc_report_rows', {
    p_store_codes: storeCodes,
    p_dates:       dates,
  })
  if (error) { console.error('rpc_report_rows:', error.message); return [] }
  return Array.isArray(data) ? data : []
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
      // today_* fields are additive across dates (each row is that day's sales only)
      m.today_qty    = (m.today_qty    ?? 0) + (r.today_qty    ?? 0)
      m.today_cost   = (m.today_cost   ?? 0) + (r.today_cost   ?? 0)
      m.today_sales  = (m.today_sales  ?? 0) + (r.today_sales  ?? 0)
      if (r.snapshot_date >= m.snapshot_date) {
        // period_* are Sigma cumulative MTD counters — summing them across dates
        // double-counts. Take the latest snapshot date's value only.
        m.period_qty   = r.period_qty   ?? 0
        m.period_cost  = r.period_cost  ?? 0
        m.period_sales = r.period_sales ?? 0
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
      // today_* fields are additive across both dates and stores
      m.today_qty    = (m.today_qty    ?? 0) + (r.today_qty    ?? 0)
      m.today_cost   = (m.today_cost   ?? 0) + (r.today_cost   ?? 0)
      m.today_sales  = (m.today_sales  ?? 0) + (r.today_sales  ?? 0)
      // soh is always summed across stores (each store holds independent stock)
      m.soh          = (m.soh          ?? 0) + (r.soh          ?? 0)
      // period_* are Sigma cumulative MTD counters — they must NOT be summed across dates.
      // Same date + different store: sum (each store's MTD is independent and additive).
      // Newer date: replace (the new date's value supersedes the old date's accumulated total).
      if (r.snapshot_date > m.snapshot_date) {
        // Newer date: reset period accumulators to this row's value only
        m.period_qty   = r.period_qty   ?? 0
        m.period_cost  = r.period_cost  ?? 0
        m.period_sales = r.period_sales ?? 0
        m.snapshot_date = r.snapshot_date
      } else {
        // Same date (different store) or older date: sum period_* across stores
        m.period_qty   = (m.period_qty   ?? 0) + (r.period_qty   ?? 0)
        m.period_cost  = (m.period_cost  ?? 0) + (r.period_cost  ?? 0)
        m.period_sales = (m.period_sales ?? 0) + (r.period_sales ?? 0)
      }
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
function buildReport(report, rows, moverMode, refDate, rosMap = new Map(), supplierMap = new Map(), nDates = 1, focusEans = null) {
  // Helper: active line check — must have sold in last ACTIVE_LINE_LOOKBACK days
  const activeLineCutoff = refDate ? shiftDate(refDate, -ACTIVE_LINE_LOOKBACK) : null
  const isActiveLine = r => !activeLineCutoff || ((r.last_sales_date_iso ?? '') >= activeLineCutoff)

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

    case 'period_sales': {
      return rows
        .filter(r => (r.period_qty ?? 0) !== 0 && isActiveLine(r))
        .sort((a, b) => (b.period_sales ?? 0) - (a.period_sales ?? 0))
        .map(r => {
          const vat = (r.vat_pct ?? 15) / 100
          const exVatSell = (r.period_sales ?? 0) / (1 + vat)
          const gp = exVatSell > 0
            ? Math.round(((exVatSell - (r.period_cost ?? 0)) / exVatSell) * 1000) / 10
            : null
          const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
          return {
            'EAN':         r.ean,
            'Description': r.description,
            'Dept':        r.dept_name,
            'Sub-Dept':    r.sub_dept_name ?? '',
            'Qty Sold':    r.period_qty ?? 0,
            'Sales Value': Math.round((r.period_sales ?? 0) * 100) / 100,
            'GP%':         gp != null ? gp + '%' : '—',
            'SOH':         r.soh ?? 0,
            'Daily ROS':   ros.daily_ros != null ? Number(ros.daily_ros).toFixed(2) : '—',
            'Last Sale':   r.last_sales_date_iso ?? '',
          }
        })
    }

    case 'velocity': {
      const n = nDates > 0 ? nDates : 1
      // Ranging tier is the ENGINE verdict (l2_ranging_tier via l2_stock_position,
      // carried on every rpc_report_rows row) — 13-week value AND volume ranking
      // per RULE-BOOK §4, not a client-side ROS-only approximation.
      const ENGINE_TIER = { TOP_100: 'Top', TOP_1000: 'Mid', BOR: 'BOR' }
      return rows
        .filter(r => {
          const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
          return (ros.daily_ros ?? 0) > 0 && isActiveLine(r)
        })
        .map(r => {
          const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
          const baselineRos  = ros.daily_ros  ?? 0
          const currentRos   = (r.period_qty ?? 0) / n
          const rosVsBase    = baselineRos > 0 ? currentRos / baselineRos : null
          const vat          = (r.vat_pct ?? 15) / 100
          const exVatSell    = (r.period_sales ?? 0) / (1 + vat)
          const gp           = exVatSell > 0
            ? Math.round(((exVatSell - (r.period_cost ?? 0)) / exVatSell) * 1000) / 10
            : null
          return {
            'EAN':              r.ean,
            'Description':      r.description,
            'Dept':             r.dept_name,
            'Sub-Dept':         r.sub_dept_name ?? '',
            'Sigma Code':       r.internal_ref ?? '',
            'Supplier':         supplierMap.get(r.ean) ?? '',
            'Qty Sold':         r.period_qty ?? 0,
            'Sales Value':      Math.round((r.period_sales ?? 0) * 100) / 100,
            'GP%':              gp != null ? gp + '%' : '—',
            'SOH':              r.soh ?? 0,
            'Stock Turn':       (r.soh ?? 0) > 0
              ? ((r.period_qty ?? 0) / (r.soh ?? 0) * (365 / n)).toFixed(1)
              : '—',
            'Days Cover':       ros.days_cover != null ? Number(ros.days_cover).toFixed(1) : '—',
            'Daily ROS (13w)':  baselineRos.toFixed(3),
            'Current ROS':      currentRos.toFixed(3),
            'ROS vs Baseline':  rosVsBase != null ? rosVsBase.toFixed(2) + 'x' : '—',
            'Ranging Tier':     ENGINE_TIER[r.tier] ?? 'BOR',
            'Last Sale':        r.last_sales_date_iso ?? '',
          }
        })
        .sort((a, b) => {
          const aX = parseFloat(String(a['ROS vs Baseline'])) || 0
          const bX = parseFloat(String(b['ROS vs Baseline'])) || 0
          return bX - aX
        })
    }

    case 'lostsales': {
      // True OOS (Signal A) + Phantom Stock (Signal C). Signal B moved to ledger_discrepancy report.
      const today = refDate ?? new Date().toISOString().slice(0, 10)
      const result = []
      for (const r of rows) {
        if (!isActiveLine(r)) continue
        const soh       = r.soh ?? 0
        const ros       = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
        const dailyRos  = ros.daily_ros ?? 0
        const lastSale  = r.last_sales_date_iso ?? ''
        const daysSince = lastSale
          ? Math.max(0, Math.floor((new Date(today) - new Date(lastSale)) / 86400000))
          : null

        let signal = null, estLostValue = null

        if (soh <= 0 && (r.period_qty ?? 0) === 0) {
          signal = 'A'  // True OOS — no sales despite SOH<=0
          if (dailyRos > 0 && daysSince != null)
            estLostValue = Math.round(dailyRos * (r.sell_price ?? 0) * Math.max(1, daysSince) * 100) / 100
        } else if (soh > 0 && dailyRos > 0 && daysSince != null) {
          if (daysSince * dailyRos >= SIGNAL_C_THRESHOLD) {
            signal = 'C'  // phantom stock — expected unit missed
            estLostValue = Math.round(daysSince * dailyRos * (r.sell_price ?? 0) * 100) / 100
          }
        }

        if (!signal) continue
        result.push({
          'EAN':              r.ean,
          'Description':      r.description,
          'Dept':             r.dept_name,
          'SOH':              soh,
          'Signal':           signal,
          'Daily ROS':        dailyRos > 0 ? dailyRos.toFixed(3) : '—',
          'Days OOS/Stalled': daysSince ?? '—',
          'Est. Lost Value':  estLostValue != null ? estLostValue : '—',
          'Sell Price':       r.sell_price ?? 0,
          'Last Sale':        lastSale,
          'Store':            r.store_name ?? r.store_code ?? '',
        })
      }
      return result.sort((a, b) => {
        const aV = typeof a['Est. Lost Value'] === 'number' ? a['Est. Lost Value'] : -1
        const bV = typeof b['Est. Lost Value'] === 'number' ? b['Est. Lost Value'] : -1
        return bV - aV
      })
    }

    case 'ledger_discrepancy': {
      // SOH <= 0 AND period_qty > 0 — selling despite negative/zero stock (SB-CC-003 item 11)
      return rows
        .filter(r => (r.soh ?? 0) <= 0 && (r.period_qty ?? 0) > 0)
        .sort((a, b) => (a.soh ?? 0) - (b.soh ?? 0))  // most negative SOH first
        .map(r => ({
          'EAN':                  r.ean,
          'Description':          r.description,
          'Store':                r.store_name ?? r.store_code ?? '',
          'SOH':                  r.soh ?? 0,
          'Period Sales (qty)':   r.period_qty ?? 0,
          'Period Sales (R)':     r.period_sales ?? 0,
          'Last Sales Date':      r.last_sales_date_iso ?? '',
          'Supplier':             supplierMap?.get(r.ean) ?? '',
        }))
    }

    case 'deptsummary': {
      // Use today_* fields: these are the day's sales only, additive across both dates and stores.
      // period_* are Sigma MTD accumulators and double-count across multi-date selections.
      // today_* also aligns with what rpc_dept_summary returns for the KPI cards.
      // Accumulate salesExVat per item using each row's own vat_pct — no flat assumption.
      const dmap = new Map()
      for (const r of rows) {
        const k = r.dept_name ?? 'Unknown'
        if (!dmap.has(k)) dmap.set(k, { dept: k, items: 0, qty: 0, cost: 0, sales: 0, salesExVat: 0 })
        const d   = dmap.get(k)
        const vat = (r.vat_pct ?? 15) / 100
        if ((r.today_qty ?? 0) !== 0) d.items++
        d.qty        += r.today_qty   ?? 0
        d.cost       += r.today_cost  ?? 0
        d.sales      += r.today_sales ?? 0
        d.salesExVat += (r.today_sales ?? 0) / (1 + vat)
      }
      const result = [...dmap.values()]
        .sort((a, b) => b.sales - a.sales)
        .map(d => {
          const gp = d.salesExVat > 0 ? Math.round(((d.salesExVat - d.cost) / d.salesExVat) * 1000) / 10 : null
          return {
            'Department':   d.dept,
            'Items Sold':   d.items,
            'Qty Sold':     Math.round(d.qty  * 1000) / 1000,
            'Cost Value':   Math.round(d.cost * 100)  / 100,
            'Sales (VAT)':  Math.round(d.sales * 100) / 100,
            'GP%':          gp != null ? gp + '%' : '—',
            '_exv':         d.salesExVat,
          }
        })
      const tot = result.reduce(
        (a, d) => ({ ...a, 'Items Sold': a['Items Sold'] + d['Items Sold'], 'Qty Sold': a['Qty Sold'] + d['Qty Sold'], 'Cost Value': a['Cost Value'] + d['Cost Value'], 'Sales (VAT)': a['Sales (VAT)'] + d['Sales (VAT)'], '_exv': a['_exv'] + d['_exv'] }),
        { Department: 'TOTAL', 'Items Sold': 0, 'Qty Sold': 0, 'Cost Value': 0, 'Sales (VAT)': 0, 'GP%': '', '_exv': 0 }
      )
      tot['GP%'] = tot['_exv'] > 0 ? Math.round(((tot['_exv'] - tot['Cost Value']) / tot['_exv']) * 1000) / 10 + '%' : '—'
      return [...result, tot].map(({ _exv, ...rest }) => rest)
    }

    case 'slowmovers': {
      const slowCutoff = refDate ? shiftDate(refDate, -SLOW_MOVER_DAYS) : null
      return rows
        .filter(r => {
          const soh = r.soh ?? 0
          const lastSale = r.last_sales_date_iso ?? ''
          return soh > 0
            && isActiveLine(r)
            && (slowCutoff == null || lastSale < slowCutoff)
        })
        .map(r => {
          const uc = unitCost(r)
          const capTied = Math.round((r.soh ?? 0) * uc * 100) / 100
          const daysSince = r.last_sales_date_iso && refDate
            ? Math.max(0, Math.floor((new Date(refDate) - new Date(r.last_sales_date_iso)) / 86400000))
            : null
          return {
            'EAN':             r.ean,
            'Description':     r.description,
            'Dept':            r.dept_name,
            'Sub-Dept':        r.sub_dept_name ?? '',
            'SOH':             r.soh ?? 0,
            'Unit Cost':       Math.round(uc * 100) / 100,
            'Capital Tied':    capTied,
            'Days Since Sale': daysSince ?? '—',
            'Sell Price':      r.sell_price ?? 0,
            'Supplier':        supplierMap.get(r.ean) ?? '',
            'Last Sale':       r.last_sales_date_iso ?? '',
            'Status':          r.status ?? '',
          }
        })
        .sort((a, b) => {
          const capA = typeof a['Capital Tied'] === 'number' ? a['Capital Tied'] : 0
          const capB = typeof b['Capital Tied'] === 'number' ? b['Capital Tied'] : 0
          return capB - capA
        })
    }

    case 'stock_integrity': {
      const PROD_DEPTS = ['BUTCHERY', 'BAKERY', 'DELI', 'HMR']
      return rows
        .filter(r => (r.soh ?? 0) < 0)
        .sort((a, b) => (a.soh ?? 0) - (b.soh ?? 0))
        .map(r => {
          const deptUp  = (r.dept_name ?? '').toUpperCase()
          const isProd  = PROD_DEPTS.some(d => deptUp.includes(d))
          const mag     = Math.abs(r.soh ?? 0)
          const type    = isProd && mag > 50 ? 'A' : 'B'
          return {
            'EAN':             r.ean,
            'Description':     r.description,
            'Dept':            r.dept_name,
            'SOH':             r.soh ?? 0,
            'Probable Type':   type,
            'Sell Price':      r.sell_price ?? 0,
            'Status':          r.status ?? '',
            'Store':           r.store_name ?? r.store_code ?? '',
          }
        })
    }

    case 'focus_export': {
      const eanFilter = focusEans ? new Set(focusEans) : null
      return rows
        .filter(r => !eanFilter || eanFilter.has(r.ean))
        .map(r => {
          const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
          const uc  = unitCost(r)
          return {
            'EAN':           r.ean,
            'Description':   r.description,
            'Dept':          r.dept_name,
            'Sub-Dept':      r.sub_dept_name ?? '',
            'Sell Price':    r.sell_price ?? 0,
            'Unit Cost':     Math.round(uc * 100) / 100,
            'VAT%':          r.vat_pct ?? 0,
            'Period Qty':    r.period_qty ?? 0,
            'Period Sales':  Math.round((r.period_sales ?? 0) * 100) / 100,
            'Period Cost':   Math.round((r.period_cost  ?? 0) * 100) / 100,
            'SOH':           r.soh ?? 0,
            'Daily ROS':     ros.daily_ros  != null ? Number(ros.daily_ros).toFixed(3)  : '—',
            'Days Cover':    ros.days_cover != null ? Number(ros.days_cover).toFixed(1) : '—',
            'Supplier':      supplierMap.get(r.ean) ?? '',
            'Internal Ref':  r.internal_ref ?? '',
            'Status':        r.status ?? '',
            'Last Sale':     r.last_sales_date_iso ?? '',
            'Store':         r.store_name ?? '',
            'Date':          r.snapshot_date ?? '',
          }
        })
    }

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
// DEPT MARGIN TREND REPORT
// ─────────────────────────────────────────────────────────────────────────────
function buildDeptMarginReport(deptSummary, lyDeptSummary) {
  const lyMap = new Map()
  for (const r of (lyDeptSummary ?? [])) lyMap.set(r.dept_name, r)

  return (deptSummary ?? []).map(r => {
    // Use total_sales_ex_vat from rpc_dept_summary (per-item vat_pct, no flat assumption)
    const exVat = r.total_sales_ex_vat ?? 0
    const gp    = exVat > 0 ? Math.round(((exVat - (r.total_cost ?? 0)) / exVat) * 1000) / 10 : null

    const ly      = lyMap.get(r.dept_name)
    const lyExVat = ly?.total_sales_ex_vat ?? 0
    const lyGp    = lyExVat > 0 ? Math.round(((lyExVat - (ly.total_cost ?? 0)) / lyExVat) * 1000) / 10 : null

    const gpChange     = gp != null && lyGp != null ? Math.round((gp - lyGp) * 10) / 10 : null
    const salesChangePct = ly && ly.total_sales > 0
      ? Math.round(((r.total_sales - ly.total_sales) / ly.total_sales) * 1000) / 10
      : null

    return {
      'Department':      r.dept_name ?? 'Unknown',
      'GP% This Period': gp   != null ? gp   + '%' : '—',
      'GP% LY':          lyGp != null ? lyGp + '%' : '—',
      'Change (pp)':     gpChange != null ? (gpChange >= 0 ? '+' : '') + gpChange + 'pp' : '—',
      'Sales Value':     Math.round((r.total_sales ?? 0) * 100) / 100,
      'Sales LY':        Math.round((ly?.total_sales ?? 0) * 100) / 100,
      'Sales Change %':  salesChangePct != null ? (salesChangePct >= 0 ? '+' : '') + salesChangePct + '%' : '—',
    }
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// EXCEL DOWNLOAD
// ─────────────────────────────────────────────────────────────────────────────
// Engine-backed Slow Movers table (SB-CC-DASH-SOURCE-003 Phase A).
// Input = rpc_stock_report_engine(...,'slowmovers') rows (l2_stock_position bridged
// to EAN). Excludes unbridged lines (ean=null -- footnoted in the drawer), then applies
// the same dept / sub-dept / focus filters as the L1 path. Sorted by capital tied desc.
// No 'Status' column: l2_stock_position does not carry the PRSSALE status field.
function buildSlowMoversEngine(rows, { deptFilter, subDeptFilter, focusEans, refDate, supplierMap }) {
  return rows
    .filter(r => r.ean != null)
    .filter(r => deptFilter === 'all'    || normalizeDept(r.dept_name) === deptFilter)
    .filter(r => subDeptFilter === 'all' || r.subdept_name === subDeptFilter)
    .filter(r => !focusEans || focusEans.includes(r.ean))
    .map(r => {
      const daysSince = r.last_sale_date && refDate
        ? Math.max(0, Math.floor((new Date(refDate) - new Date(r.last_sale_date)) / 86400000))
        : null
      return {
        'EAN':             r.ean,
        'Description':     r.description,
        'Dept':            r.dept_name,
        'Sub-Dept':        r.subdept_name ?? '',
        'SOH':             Number(r.soh ?? 0),
        'Unit Cost':       r.unit_cost != null ? Math.round(Number(r.unit_cost) * 100) / 100 : null,
        'Capital Tied':    Math.round(Number(r.capital_value ?? 0) * 100) / 100,
        'Days Since Sale': daysSince ?? '—',
        'Sell Price':      Number(r.sell_price ?? 0),
        'Supplier':        supplierMap.get(r.ean) ?? '',
        'Last Sale':       r.last_sale_date ?? '',
      }
    })
    .sort((a, b) => (b['Capital Tied'] ?? 0) - (a['Capital Tied'] ?? 0))
}

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
// LAYER FRESHNESS STRIP (SB-CC-DASH-TRUTH-001 P1.3)
// "L1 current to X · L2 refreshed Y · per-store red chips when a feed lags."
// Source: rpc_layer_freshness (L1/L2 max dates + latest feed_check verdict).
// Staleness is visible, never silent.
// ─────────────────────────────────────────────────────────────────────────────
function LayerFreshnessStrip({ rows }) {
  if (!rows || rows.length === 0) return null
  const l1Min   = rows.map(r => r.l1_max).filter(Boolean).sort()[0] ?? '—'
  const l2Ref   = rows.map(r => r.l2_refreshed).filter(Boolean).sort().reverse()[0] ?? '—'
  const lagging = rows.filter(r => r.feed_status === 'FAILED')
  return (
    <div className="sb-fresh-strip">
      <span className="sb-fresh-chip" title="Oldest per-store sigma_sales trading date (L1 mirror currency, nightly extractor) — rpc_layer_freshness">
        L1 → {l1Min}
      </span>
      <span className="sb-fresh-chip" title="l2_kpi_daily.positioned_at — last L2 engine refresh (refresh_l2_pipeline, nightly 22:15 SAST)">
        L2 engine → {l2Ref}
      </span>
      {lagging.length > 0
        ? lagging.map(r => (
            <span key={r.store_code} className="sb-fresh-chip lag" title={r.feed_detail ?? 'feed lagging'}>
              ⚠ {r.store_code}
            </span>
          ))
        : <span className="sb-fresh-chip" style={{ color: '#4ade80' }}>all feeds fresh</span>
      }
    </div>
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
const SEARCH_IDX_KEY = 'sb_pulse_search_index_v2'
const SEARCH_IDX_TTL = 6 * 60 * 60 * 1000  // 6h — optimistic cache only, always revalidated

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
  // ENG-069 — R22 §3: a failed KPI request must SURFACE, never render as R0.
  // Holds the reason the sales figure could not be established, or null.
  const [kpiError,       setKpiError]       = useState(null)
  // Set when the sales figure resolved but the stock facts (neg SOH, slow movers,
  // capital tied) did not — the cards stay truthful about which half is missing.
  const [kpiStockError,  setKpiStockError]  = useState(null)
  const [deptSummary,    setDeptSummary]    = useState([])   // rpc_dept_summary — one aggregated row per dept
  const [deptSohCounts,  setDeptSohCounts]  = useState([])   // rpc_kpi_dept_counts — neg/slow per dept (Bug 3)
  const [top20Data,      setTop20Data]      = useState([])   // rpc_top20 — up to 40 pre-aggregated rows
  const [deptNormMap,    setDeptNormMap]    = useState(new Map())
  const [viewsLoading,   setViewsLoading]   = useState(false)
  const [top20Loading,   setTop20Loading]   = useState(false)
  const [top20Error,     setTop20Error]     = useState(null)  // ENG-141 — a failed read is NOT an empty list
  const [refreshKey,     setRefreshKey]     = useState(0)

  function handleReload() {
    viewsCache.current.clear()
    deptCache.current.clear()
    top20Cache.current.clear()
    setViewsLoading(true)
    setTop20Loading(true)
    setRefreshKey(k => k + 1)
  }

  // ── historical comparison data (Phase 3.2) ──────────────────────────────────
  const [sparklineData,    setSparklineData]    = useState([])   // mv_sparkline_14d — fetched once on mount
  const [rhythmProfiles,   setRhythmProfiles]   = useState([])   // community_rhythm — active profiles, fetched once
  const [lyKpiData,      setLyKpiData]      = useState([])   // v_kpi_by_date for LY equivalent dates
  const [wowKpiData,     setWowKpiData]     = useState([])   // v_kpi_by_date for WoW equivalent dates
  const [lyDeptSummary,  setLyDeptSummary]  = useState([])   // rpc_dept_summary for LY dates (all depts — dept margin report)
  // Dept/sub-dept/EAN-aware LY + WoW summaries for the KPI cards. Fetched in the
  // dept effect with the same p_subdept/p_eans as deptSummary so the LY and WoW
  // comparison values respect the active selection (SB-CC-DEPT-KPI-001).
  const [lyKpiDeptSummary,  setLyKpiDeptSummary]  = useState([])
  const [wowKpiDeptSummary, setWowKpiDeptSummary] = useState([])
  const [lyDeptSohCounts,   setLyDeptSohCounts]   = useState([])   // rpc_kpi_dept_counts for LY latest date — dept-aware NegSOH/SlowMove (SEL-001 P2)
  const [deptTrendData,     setDeptTrendData]     = useState([])   // v_dept_by_date for trend when dept filter active
  const [lyDeptTrendData,   setLyDeptTrendData]   = useState([])   // v_dept_by_date LY for trend
  const [trendData,      setTrendData]      = useState([])   // v_kpi_by_date for trend chart (90 days)
  const [lyTrendData,    setLyTrendData]    = useState([])   // v_kpi_by_date for LY trend window
  const [productTrendData,   setProductTrendData]   = useState([])  // FEAT-1: trend filtered to active EANs
  const [productLyTrendData, setProductLyTrendData] = useState([])  // FEAT-1: LY trend filtered to active EANs

  // ── dept/sub-dept chips ─────────────────────────────────────────────────────
  const [depts,       setDepts]       = useState([])
  const [subDepts,    setSubDepts]    = useState([])   // filtered by selected dept
  const [allSubDepts, setAllSubDepts] = useState([])   // all sub-depts for current store+date

  // ── report data (on-demand) ──────────────────────────────────────────────────
  const [reportRows,    setReportRows]    = useState([])
  // SB-CC-DASH-SOURCE-003 Phase A: engine-backed stock-report rows (l2_stock_position
  // via rpc_stock_report_engine, bridged to EAN). Slow Movers reads this; unbridged
  // lines (ean=null) are excluded from the table and footnoted.
  const [engineSlowRows, setEngineSlowRows] = useState([])
  // ENG-101: a failed or short Slow Movers read must SAY SO. It used to be
  // swallowed into an empty array by `.catch(() => [])`, which renders as
  // "no slow movers" -- a blank standing in for a failure (R22 §3).
  const [engineSlowError, setEngineSlowError] = useState(null)
  const [reportLoaded,  setReportLoaded]  = useState(false)
  const [reportLoading, setReportLoading] = useState(false)
  const [ghostStockRows,     setGhostStockRows]     = useState([])   // SB-AP-004 C -- ghost_stock report
  const [stockIntegrityRows, setStockIntegrityRows] = useState([])   // SB-AP-004 C -- stock_integrity report
  const [storeRosData,  setStoreRosData]  = useState([])
  const [top20RosData,  setTop20RosData]  = useState([])  // ROS/days-cover scoped to the Top 20 EANs (loads before any report)
  const [supplierMap,   setSupplierMap]   = useState(new Map())  // ean → supplier_name from product_catalog
  const [lostSalesItems,    setLostSalesItems]    = useState([])  // True OOS items: SOH<=0, period_qty=0, active line
  const [lostSalesTimeline, setLostSalesTimeline] = useState(new Map()) // ean → [{store_code, store_name, days:[{snap_date,sold_bool,oos_bool,soh}]}]
  const [timelineLoading,   setTimelineLoading]   = useState(false)
  const [capTiedModalOpen,  setCapTiedModalOpen]  = useState(false) // Capital Tied drill-down modal

  // ── L2 engine KPI + layer freshness (SB-CC-DASH-TRUTH-001 P1) ──────────────
  // l2_kpi_daily: one row per store — the engine verdict for the latest sigma day.
  // rpc_layer_freshness: per-store L1/L2 max dates + latest feed_check verdict.
  const [l2Kpi, setL2Kpi]           = useState([])
  const [layerFresh, setLayerFresh] = useState([])
  // v_l2_capital_by_store: per-store purified Capital Tied from l2_classification
  // (bucket IN HEALTHY/COUNT/AMBIGUOUS/LEAVE_COUNTED, latest snapshot per store) —
  // the engine's cleanup verdict. SB-CC-DASH-WIRE-001 ticket 1.
  const [l2CapStore, setL2CapStore] = useState([])
  useEffect(() => {
    if (!storeCodes.length) return
    let cancelled = false
    Promise.all([
      supabase.from('l2_kpi_daily')
        .select('store_code,sales_date,sales_incl_vat,sales_cost,sales_qty,gp_pct,capital_normal,capital_production,capital_non_stock,capital_receipting_break,capital_total,days_cover_normal_wtd,neg_soh_count,neg_soh_count_all,slow_mover_count,ghost_stock_value,positioned_at')
        .in('store_code', storeCodes),
      supabase.rpc('rpc_layer_freshness'),
      supabase.from('v_l2_capital_by_store')
        .select('store_code,snapshot_date,capital_purified,capital_in_scope_total,rows,capital_deposits,deposit_lines')
        .in('store_code', storeCodes),
    ]).then(([l2Res, frRes, capRes]) => {
      if (cancelled) return
      if (l2Res.error) console.error('[l2_kpi_daily]', l2Res.error.message)
      if (frRes.error) console.error('[rpc_layer_freshness]', frRes.error.message)
      if (capRes.error) console.error('[v_l2_capital_by_store]', capRes.error.message)
      setL2Kpi(l2Res.data ?? [])
      setLayerFresh(frRes.data ?? [])
      setL2CapStore(capRes.data ?? [])
    })
    return () => { cancelled = true }
  }, [storeCodes])
  const [tooltipCard,       setTooltipCard]       = useState(null)
  const [tooltipPos,        setTooltipPos]        = useState({ left: 0, top: 0 })
  const [tooltipContent,    setTooltipContent]    = useState(null)

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
  // True only while the default top-5 fetch is in flight, so FocusAreaPanel can
  // show an honest empty-state instead of spinning forever (SB-CC-DASH-WIRE-001 t4).
  const [focusDefaultLoading, setFocusDefaultLoading] = useState(false)

  // ── FEAT-1: trend date windows — promoted from loadViews so the product-trend
  //    useEffect can depend on them without re-deriving on every render.
  // Trend always shows the 13-week window ending at the most recent push date
  // (availableDates[0]), independent of which KPI date range is selected.
  const trendDates = useMemo(() => {
    if (!availableDates.length) return []
    return availableDates.slice(0, TREND_WINDOW_DAYS)
  }, [availableDates])
  const lyTrendDates = useMemo(() => trendDates.map(d => shiftDate(d, -LY_SHIFT_DAYS)), [trendDates])

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
    setFocusDefaultLoading(true)

    supabase.rpc('rpc_focus_top5', {
      p_store_codes: storeCodes,
      p_dates:       selectedDates,
      p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
      p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
    }).then(({ data, error }) => {
      if (cancelled) return
      if (error) { console.error('rpc_focus_top5 error', error.message); setFocusDefaultLoading(false); return }
      const top5 = (data ?? []).slice(0, 5).map(r => ({
        ean:           String(r.ean),
        description:   r.description,
        store_code:    r.store_code,
        dept_name:     r.dept_name,
        sub_dept_name: r.sub_dept_name,
      }))
      setFocusBasket(top5)
      setFocusDefaultLoading(false)
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
  // Single source since RETIRE-003 (2026-07-02): rpc_push_available_dates
  // (SECURITY DEFINER) returns the FULL date set — mv_kpi_by_date history
  // UNION any fresher sigma_sales dates — so the old direct mv_kpi_by_date
  // leg (whose error was silently ignored) is retired. A picker failure now
  // logs loudly instead of half-loading.
  useEffect(() => {
    async function init() {
      const { data, error } = await supabase.rpc('rpc_push_available_dates')
      if (error) { console.error('[rpc_push_available_dates]', error.message); return }
      const allDates = new Set((data ?? []).map(r => r.snapshot_date).filter(Boolean))
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
      .select('store_code,snapshot_date,total_sales,total_sales_ex_vat,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied')
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
      .select('id,event_name,start_day,end_day,multiplier_configured,is_active')
      .eq('is_active', true)
      .order('start_day', { ascending: true })
      .then(({ data, error }) => {
        if (error) { console.error('[community_rhythm]', error.message); return }
        setRhythmProfiles(data ?? [])
      })
  }, [])

  // ── Lost Sales: PARKED (Pieter ruling, RULE-BOOK §6, 2026-06-16) ─────────────
  // The rpc_lost_sales_oos call fired on EVERY page load, measured 94.5s, and
  // died at the 8s authenticator timeout on every load (CC-BRIEF-DASH-FINAL-001
  // item 2, removed 2026-07-05). The RPCs stay live in the DB (R28: retired
  // with a successor path, never deleted) — reinstate engine-side (DF-3
  // lost_sales_est) when Lost Sales is properly re-opened. lostSalesItems stays
  // [] so the widget below never renders.

  // ── Lost Sales Timeline: PARKED with the widget above (item 2, 2026-07-05) ──
  // rpc_lost_sales_timeline call removed with rpc_lost_sales_oos; the RPC stays
  // live in the DB. lostSalesTimeline stays an empty Map.

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
        // ENG-069: only clean reads are cached (see below), so a cache hit clears
        // any error left on screen from a previous selection.
        setKpiError(null)
        setKpiStockError(null)
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

      // trendDates / lyTrendDates are computed at component level as useMemo
      // (see FEAT-1 note) — they are available in this closure via the outer scope.

      // Rule (PM decision 2026-05-25):
      //   single date  → v_kpi_by_date  (live view — catches today's push immediately)
      //   multi date   → mv_kpi_by_date (pre-aggregated MV — no timeout risk on MTD/25+ dates)
      // LY / WoW / trend are always historical so always use the MV.
      const isSingleDate = selectedDates.length === 1
      const kpiTable = isSingleDate ? 'v_kpi_by_date' : 'mv_kpi_by_date'

      // ENG-069 (2026-08-05) — THE SAME-DAY SALES FIGURE NO LONGER DEPENDS ON
      // `v_kpi_by_date`. Measured at source: the single-date live view CANCELS on a
      // statement timeout for a recent date (80175 / 2026-08-04 reproduced), while
      // `rpc_dept_summary` returns the identical figure in about a second
      // (R127,599.98 incl / R114,166.24 ex-VAT, verified against the ledger ×5 stores).
      //
      // Why the view times out and the RPC does not: PostgREST connects as
      // `authenticator`, which carries statement_timeout=8s, and its mid-session
      // `SET ROLE` does NOT re-apply the target role's rolconfig — so a plain VIEW is
      // governed by 8s no matter what anon/authenticated are set to. A SECURITY
      // DEFINER function can hold its own `SET LOCAL`; a view cannot.
      //
      // ENG-074 (2026-08-07) — THE STOCK HALF NOW MOVES TOO, and the view is no
      // longer called at all on a single date.
      //
      // ENG-069 deliberately left neg SOH / slow movers / capital tied / ghost
      // value on the view, so they inherited the same 8s ceiling and rendered
      // UNAVAILABLE on a recent date. `rpc_kpi_stock_by_date` is the same repoint
      // applied to them: same four expressions, same column names, SECURITY
      // DEFINER so it holds its own SET LOCAL.
      //
      // WHY THE VIEW IS DROPPED HERE RATHER THAN KEPT AS A FALLBACK: on a single
      // date it cannot answer at all. Measured at source 2026-08-07, ONE store on
      // 2026-08-06 was still running past 25s — the join carries no `client_id`,
      // so the (client_id, store_code, product_code) unique index cannot seek and
      // every one of ~90,000 probes costs ~4,665 (canon §17's standing note), on
      // top of a rows=1 estimate against a real 89,999 that picks a nested loop.
      // A source that can never return inside the deadline is not a fallback; it
      // is 25s+ of database work competing with every other panel on the page,
      // which is exactly ENG-070's root cause. store_name comes from STORE_MAP.
      // The matview path (multi-date) is untouched — it is pre-aggregated and fast.

      // TWO-WAVE FETCH (dash-timeout-001, applied to main 2026-07-05 — item 3):
      // the authenticator role connects PostgREST to Postgres and carries
      // statement_timeout=8s (tighter than anon/authenticated's 30s — PostgREST's
      // SET ROLE mid-session does NOT re-apply the target role's rolconfig, so the
      // connecting role's 8s ceiling governs every request). The old single
      // Promise.all fired 7 queries at once here, plus 5 more from the sibling
      // dept-summary effect on the same render — ~12 concurrent DB hits including
      // a 90-day trend scan. Under that burst on free-tier compute the cards-
      // critical KPI query sometimes missed the 8s window even though it completes
      // sub-second in isolation. Fix: fetch the cards-critical pair first and
      // render immediately, then the comparison/trend data as a second wave, so
      // peak concurrency drops and the cards stop being held hostage by the
      // heaviest, least time-critical query.
      // ENG-069 — THE HANG GUARD, and it is not defensive padding.
      // Observed live on 2026-08-05 in a signed-in session, SPAR Roosville /
      // 2026-08-04: the cards never rendered at all. They sat as empty skeletons
      // through a full reload and 15+ seconds. That is NOT the error path — an
      // errored supabase-js call still RESOLVES (it never rejects), which would have
      // set viewsLoading(false) and drawn the cards. A promise that never settles
      // means `await Promise.all` never returns, so the loading state is permanent.
      //
      // This matters for the repoint below: Promise.all waits for EVERY entry, so a
      // hanging v_kpi_by_date would hold the rendered sales figure hostage even
      // though rpc_dept_summary answered in about a second. Sourcing the number
      // correctly is not enough if one dead request can stop it reaching the screen.
      //
      // So every entry is bounded. A request that outlives the budget resolves as a
      // named error and the cards draw with whatever DID answer (R22 §3 — surface it,
      // never hide it, and never let it block the figures that are healthy).
      // 🔴 THE MESSAGE MUST NOT ASSERT WHAT THE CLIENT CANNOT KNOW (2026-08-24).
      // This used to read "<label> did not respond within 12s", which blames the
      // thing being asked. A client-side deadline knows exactly ONE fact: no
      // response reached the browser in time. It does NOT know the database was
      // slow, and often it wasn't — mv_kpi_by_date was measured at 0ms for the
      // exact page shape that produced this banner, while the page was starving
      // it of a connection behind five other in-flight requests.
      //
      // Naming the object it never reached, instead of the request that was never
      // served, sends the next person to debug the wrong thing. That is worse
      // than a blank error, because it is confidently wrong.
      //
      // Fixed at the TEMPLATE, not at one call site: every caller of withDeadline
      // inherited the same false assertion, so patching the one message anyone
      // happened to notice would have left the class alive (R21 §3).
      const withDeadline = (p, label, ms = 12000) => Promise.race([
        Promise.resolve(p),
        new Promise(resolve => setTimeout(
          () => resolve({ data: null, error: { message:
            `${label}: no response reached the browser within ${ms / 1000}s (client deadline — the request was abandoned here). This does not by itself mean the query was slow; it can also be a request starved of a connection behind others in flight.` } }),
          ms)),
      ])

      const [kpiRes, subDeptRes, sameDayRes, stockRes] = await Promise.all([
        // Current KPI — includes total_sales_ex_vat (per-item vat_pct, no flat assumption)
        // ENG-074: single date no longer touches v_kpi_by_date (see the note above).
        // Multi-date still reads mv_kpi_by_date, which is pre-aggregated and fast.
        isSingleDate
          ? Promise.resolve({ data: [], error: null })
          : withDeadline(
              supabase.from(kpiTable)
                .select('store_code,store_name,snapshot_date,total_sales,total_sales_ex_vat,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied,ghost_stock_value')
                .in('store_code', storeCodes)
                .in('snapshot_date', selectedDates),
              // Name the REQUEST, not the object. Every other caller here passes
              // an RPC name; this one passed a bare table name, so its failure
              // read as "mv_kpi_by_date is broken" rather than "this select never
              // came back".
              `select ${kpiTable}`),

        // Sub-dept names for the current store+date
        withDeadline(
          supabase.rpc('rpc_subdepts', {
            p_store_codes: storeCodes,
            p_dates:       selectedDates,
            p_dept_names:  null,
          }),
          'rpc_subdepts'),

        // ENG-069: the authoritative same-day sales source. Called per store because
        // rpc_dept_summary returns no store_code — a multi-store call would collapse
        // the stores into one total and silently mis-attribute every figure.
        // Measured 2026-08-05: about a second per store, all five verified against
        // the ledger. Bounded anyway — one slow store must not stop the other four.
        isSingleDate
          ? Promise.all(storeCodes.map(sc =>
              withDeadline(
                supabase.rpc('rpc_dept_summary', { p_store_codes: [sc], p_dates: selectedDates }),
                `rpc_dept_summary(${sc})`)
                .then(r => ({ storeCode: sc, data: r.data, error: r.error }))))
          : Promise.resolve([]),

        // ENG-074: the authoritative same-day STOCK source. One call for every
        // store — unlike rpc_dept_summary this one returns store_code, so a
        // multi-store call cannot collapse or mis-attribute. Measured at source
        // 2026-08-07: 5 stores / 1 date = 4.3s planned, 5.4s wall, against a view
        // that was still running past 25s for ONE store. Bounded anyway.
        isSingleDate
          ? withDeadline(
              supabase.rpc('rpc_kpi_stock_by_date', {
                p_store_codes: storeCodes,
                p_dates:       selectedDates,
              }),
              'rpc_kpi_stock_by_date')
          : Promise.resolve({ data: [], error: null }),
      ])

      if (cancelled) return
      if (kpiRes.error) console.error(`[${kpiTable}]`, kpiRes.error.message)

      const viewRows = kpiRes.data ?? []
      let kpiData    = viewRows
      let salesFail  = null
      let stockFail  = kpiRes.error ? `${kpiTable}: ${kpiRes.error.message}` : null

      if (isSingleDate) {
        const day          = selectedDates[0]
        const stockRows    = stockRes?.data ?? []
        const stockByStore = new Map(stockRows.map(r => [r.store_code, r]))
        const merged       = []
        const failed       = []

        if (stockRes?.error) console.error('[rpc_kpi_stock_by_date]', stockRes.error.message)

        for (const r of sameDayRes) {
          const sc  = r.storeCode
          // ENG-074: the view is not called on this path, so the row is built from
          // its two authoritative sources. store_name comes from STORE_MAP.
          let row   = { store_code: sc, snapshot_date: day, store_name: STORE_MAP[sc] ?? sc }

          // ── SALES (ENG-069) ────────────────────────────────────────────────
          if (r.error) {
            console.error('[rpc_dept_summary]', sc, r.error.message)
            failed.push(sc)
            // Leave the sales fields ABSENT rather than zero. An absent field
            // reads as "no figure"; a zero reads as "the store sold nothing",
            // and a wrong number is worse than no number (R22 §3).
          } else {
            const rows = r.data ?? []
            row = {
              ...row,
              total_sales:        rows.reduce((s, x) => s + Number(x.total_sales ?? 0), 0),
              total_sales_ex_vat: rows.reduce((s, x) => s + Number(x.total_sales_ex_vat ?? 0), 0),
              total_cost:         rows.reduce((s, x) => s + Number(x.total_cost ?? 0), 0),
              total_qty:          rows.reduce((s, x) => s + Number(x.total_qty ?? 0), 0),
            }
          }

          // ── STOCK (ENG-074) ───────────────────────────────────────────────
          // Applied independently of the sales outcome: one failing source must
          // never delete the other's figures. A store with no row here has no
          // l2_soh_daily snapshot for that date (the L2 batch runs 22:15 SAST and
          // is a day behind BY DESIGN) — that is a legitimate absence, so the
          // fields stay absent and nothing is invented.
          // 🔴 ENG-100 RIDER: NULL here means NOT YET COMPUTED, never zero.
          // The comment above was already right in principle and the code
          // contradicted it: `?? 0` coerced a NULL straight to 0, so an absent
          // figure rendered as "R0 capital tied" / "0 negative SOH" -- a false
          // statement about the owner's stock position, presented with the same
          // confidence as a real reading.
          // It became reachable on 2026-08-23: ENG-100 repointed these four
          // columns onto mv_kpi_by_date, which refreshes 20:30 SAST, so for any
          // date newer than that matview's max (the ~19:30-20:30 window) they
          // come back NULL every night. Before the repoint they were computed
          // inline and were never NULL for a fresh date, only slow.
          // NULL is now PRESERVED and the card renders an em-dash (R22 §3,
          // missing data surfaces and never hides; R30 §2, silent degradation
          // is the worst outcome). A zero is only ever shown when zero is what
          // the engine actually measured.
          const st = stockByStore.get(sc)
          if (st) {
            const numOrNull = (v) => (v === null || v === undefined ? null : Number(v))
            row = {
              ...row,
              neg_soh_count:     numOrNull(st.neg_soh_count),
              slow_mover_count:  numOrNull(st.slow_mover_count),
              capital_tied:      numOrNull(st.capital_tied),
              ghost_stock_value: numOrNull(st.ghost_stock_value),
            }
          }

          merged.push(row)
        }

        kpiData = merged
        if (failed.length) {
          salesFail = `Sales could not be read for ${failed.join(', ')} — rpc_dept_summary failed.`
        }
        // Stock is unreportable only when the RPC itself failed. No rows on a
        // clean call means the snapshot does not exist yet, which is not a fault.
        stockFail = stockRes?.error
          ? `Stock figures unavailable — rpc_kpi_stock_by_date: ${stockRes.error.message}`
          : null
      } else if (kpiRes.error) {
        // Multi-date reads the matview; if that fails there is no second source.
        salesFail = `Sales could not be read — ${kpiTable}: ${kpiRes.error.message}`
      }

      const allSubDepts = [...new Set((subDeptRes.data ?? []).map(r => r.sub_dept_name))].filter(Boolean).sort()

      setKpiError(salesFail)
      setKpiStockError(stockFail)
      // Only cache a clean read — caching a failed one would replay the failure as
      // though it were data, which is the silent-empty defect wearing a cache.
      if (!salesFail && !stockFail) viewsCache.current.set(vKey, { kpiData, allSubDepts })
      setKpiData(kpiData)
      setAllSubDepts(allSubDepts)
      setViewsLoading(false)

      // Wave 2 — comparison + trend data, fired after the cards already have what
      // they need. Each promise resolves with { data, error } (supabase-js never
      // rejects on a query error), so one slow/timed-out call here can't block the
      // others or wave 1.
      const [lyKpiRes, wowKpiRes, lyDeptRes, trendRes, lyTrendRes] = await Promise.all([
        // LY KPI — always historical, use MV
        lyDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales,total_sales_ex_vat,total_cost,total_qty,neg_soh_count,slow_mover_count,capital_tied')
              .in('store_code', storeCodes)
              .in('snapshot_date', lyDates)
          : Promise.resolve({ data: [], error: null }),

        // WoW KPI — always historical, use MV
        wowDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales,total_sales_ex_vat,total_cost,total_qty')
              .in('store_code', storeCodes)
              .in('snapshot_date', wowDates)
          : Promise.resolve({ data: [], error: null }),

        // LY dept summary
        lyDates.length > 0
          ? supabase.rpc('rpc_dept_summary', { p_store_codes: storeCodes, p_dates: lyDates })
          : Promise.resolve({ data: [], error: null }),

        // Trend data (90-day window) — use MV (pre-aggregated, 2s for 90 dates).
        // v_kpi_by_date times out at >25 dates (live 18M-row aggregation). MV is
        // refreshed at the end of every store's nightly push so it stays current.
        supabase.from('mv_kpi_by_date')
          .select('store_code,snapshot_date,total_sales,total_sales_ex_vat,total_cost,total_qty')
          .in('store_code', storeCodes)
          .in('snapshot_date', trendDates)
          .order('snapshot_date', { ascending: true }),

        // LY trend data — always historical, use MV
        lyTrendDates.length > 0
          ? supabase.from('mv_kpi_by_date')
              .select('store_code,snapshot_date,total_sales,total_sales_ex_vat')
              .in('store_code', storeCodes)
              .in('snapshot_date', lyTrendDates)
              .order('snapshot_date', { ascending: true })
          : Promise.resolve({ data: [], error: null }),
      ])

      if (cancelled) return
      if (trendRes.error) console.error('[mv_kpi_by_date trend]', trendRes.error.message)
      setLyKpiData(lyKpiRes.data   ?? [])
      setWowKpiData(wowKpiRes.data ?? [])
      setLyDeptSummary(lyDeptRes.data ?? [])
      setTrendData(trendRes.data   ?? [])
      setLyTrendData(lyTrendRes.data ?? [])

      // Top 20 days-cover now loads in its own effect, scoped to the Top 20
      // EANs (the old whole-store mv_rate_of_sale fetch was silently capped at
      // 1 000 rows by PostgREST — CC-BRIEF-DASH-FINAL-001 item 5).
    }

    loadViews()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates, refreshKey])

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
      setLyKpiDeptSummary(dHit.lyKpiDeptSummary)
      setWowKpiDeptSummary(dHit.wowKpiDeptSummary)
      setLyDeptSohCounts(dHit.lyDeptSohCounts)
      return
    }

    // LY / WoW equivalents of the selected dates, fetched with the same
    // dept/sub-dept/EAN scope so the KPI cards' comparisons match the headline.
    const lyDeptDates  = selectedDates.map(d => shiftDate(d, -LY_SHIFT_DAYS))
    const wowDeptDates = selectedDates.map(d => shiftDate(d, -7))

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
      supabase.rpc('rpc_dept_summary', {
        p_store_codes: storeCodes,
        p_dates:       lyDeptDates,
        p_subdept:     subdeptParam,
        p_eans:        focusEans,
      }),
      supabase.rpc('rpc_dept_summary', {
        p_store_codes: storeCodes,
        p_dates:       wowDeptDates,
        p_subdept:     subdeptParam,
        p_eans:        focusEans,
      }),
      // LY NegSOH / SlowMove — point-in-time: single latest LY date only, matching
      // lyLatestKpiByStore semantics. Must NOT sum across all LY dates or a product
      // negative on every day of a multi-day selection would be counted N times.
      supabase.rpc('rpc_kpi_dept_counts', {
        p_store_codes: storeCodes,
        p_dates:       [[...lyDeptDates].sort().reverse()[0]],
        p_subdept:     subdeptParam,
        p_eans:        focusEans,
      }),
    ]).then(([deptRes, deptSohRes, lyDeptRes, wowDeptRes, lyDeptSohRes]) => {
      if (cancelled) return
      if (deptRes.error)      console.error('[rpc_dept_summary]',    deptRes.error.message)
      if (deptSohRes.error)   console.error('[rpc_kpi_dept_counts]', deptSohRes.error.message)
      // ENG-141, second instance. These two errors were not logged at all, so an
      // LY or WoW failure was invisible AND cached -- the comparison silently
      // read as "no sales last year" rather than "we could not find out".
      if (lyDeptRes.error)    console.error('[rpc_dept_summary LY]',  lyDeptRes.error.message)
      if (wowDeptRes.error)   console.error('[rpc_dept_summary WoW]', wowDeptRes.error.message)
      if (lyDeptSohRes.error) console.error('[rpc_kpi_dept_counts LY]', lyDeptSohRes.error.message)
      const ds   = deptRes.data       ?? []
      const dsc  = deptSohRes.data    ?? []
      const lyds = lyDeptRes.data     ?? []
      const wds  = wowDeptRes.data    ?? []
      const lysc = lyDeptSohRes.data  ?? []
      // ENG-141. Same rule as top20Cache and viewsCache: only a clean read is
      // cacheable. This one matters more than Top 20 -- rpc_dept_summary feeds
      // TOTAL SALES whenever a dept filter is active, so a cached failure pins a
      // wrong money number under that selection key for the whole session.
      const deptFail = deptRes.error || deptSohRes.error || lyDeptRes.error || wowDeptRes.error || lyDeptSohRes.error
      if (!deptFail) deptCache.current.set(dKey, { deptSummary: ds, deptSohCounts: dsc, lyKpiDeptSummary: lyds, wowKpiDeptSummary: wds, lyDeptSohCounts: lysc })
      setDeptSummary(ds)
      setDeptSohCounts(dsc)
      setLyKpiDeptSummary(lyds)
      setWowKpiDeptSummary(wds)
      setLyDeptSohCounts(lysc)
    }).catch(err => {
      if (cancelled) return
      console.error('[dept effect]', err)
      setDeptSummary([])
      setDeptSohCounts([])
      setLyKpiDeptSummary([])
      setWowKpiDeptSummary([])
      setLyDeptSohCounts([])
    })

    return () => { cancelled = true }
  }, [storeCodes, selectedDates, subDeptFilter, focusEans, refreshKey])

  // ── dept-level Sales Trend — re-runs when dept filter or trend window changes ─
  useEffect(() => {
    if (!storeCodes.length || !trendDates.length || deptFilter === 'all') {
      setDeptTrendData([])
      setLyDeptTrendData([])
      return
    }
    let cancelled = false
    const rawNames = [...(deptNormMap.get(deptFilter) ?? new Set([deptFilter]))]
    const toTrend = r => ({ store_code: r.store_code, snapshot_date: r.snapshot_date, total_sales: r.dept_sales })
    Promise.all([
      supabase.from('v_dept_by_date')
        .select('store_code,snapshot_date,dept_sales')
        .in('store_code', storeCodes)
        .in('snapshot_date', trendDates)
        .in('dept_name', rawNames),
      lyTrendDates.length > 0
        ? supabase.from('v_dept_by_date')
            .select('store_code,snapshot_date,dept_sales')
            .in('store_code', storeCodes)
            .in('snapshot_date', lyTrendDates)
            .in('dept_name', rawNames)
        : Promise.resolve({ data: [] }),
    ]).then(([cur, ly]) => {
      if (cancelled) return
      setDeptTrendData((cur.data ?? []).map(toTrend))
      setLyDeptTrendData((ly.data ?? []).map(toTrend))
    })
    return () => { cancelled = true }
  }, [storeCodes, deptFilter, deptNormMap, trendDates, lyTrendDates])

  // ── fetch Top 20 via RPC — re-runs when dept or sub-dept filter changes ──────
  // rpc_top20 accepts p_dept / p_subdept and returns at most 40 pre-aggregated rows
  // (union of top-20-by-value ∪ top-20-by-qty). No client-side row-cap issues.
  useEffect(() => {
    if (!storeCodes.length || !selectedDates.length) {
      setTop20Data([])
      setTop20Loading(false)
      return
    }
    // Set loading=true SYNCHRONOUSLY before the async function runs.
    // Without this, there is a window between effect trigger and loadTop20()
    // executing where top20Loading=false and top20Data=[] → empty state flashes.
    setTop20Loading(true)
    let cancelled = false

    async function loadTop20() {
      const datesForTop20 = selectedDates

      const t20Key = [...storeCodes].sort().join(',') + '|' + [...datesForTop20].sort().join(',') + '|' +
                     (deptFilter !== 'all' ? deptFilter : '') + '|' +
                     (subDeptFilter !== 'all' ? subDeptFilter : '') + '|' +
                     top20Activity + '|' + String(includeParents) + '|' +
                     (focusEans ? focusEans.slice().sort().join(',') : '')
      const t20Hit = top20Cache.current.get(t20Key)
      if (t20Hit) {
        if (!cancelled) { setTop20Data(t20Hit); setTop20Loading(false) }
        return
      }

      const { data, error } = await supabase.rpc('rpc_top20', {
        p_store_codes: storeCodes,
        p_dates:       datesForTop20,
        p_dept:        deptFilter    !== 'all' ? deptFilter    : null,
        p_subdept:     subDeptFilter !== 'all' ? subDeptFilter : null,
        p_activity:    top20Activity,
        p_parents:     includeParents,
        p_eans:        focusEans,
      })
      if (cancelled) return
      if (error) console.error('[rpc_top20]', error.message)
      const t20 = data ?? []
      // ENG-141. Only cache a clean read, and leave the key UNSET on failure so
      // the next render retries. Caching a failure replays it as though it were
      // data -- and because [] is truthy, the `if (t20Hit)` above then short-
      // circuits every later identical selection, so ONE transient failure
      // pinned an empty panel to that key for the life of the session while the
      // RPC stayed healthy throughout. Proven 2026-08-24: the RPC returns 29
      // rows for 80175/August as `anon`, and the panel renders on a fresh
      // session -- the fault was never in the database. Same rule the KPI cache
      // already applies at viewsCache above; this site and deptCache missed it.
      setTop20Error(error ? `Top 20 could not be read — rpc_top20: ${error.message}` : null)
      if (!error) top20Cache.current.set(t20Key, t20)
      setTop20Data(t20)
      setTop20Loading(false)
    }

    loadTop20()
    return () => { cancelled = true }
  }, [storeCodes, selectedDates, deptFilter, subDeptFilter, top20Activity, includeParents, focusEans, refreshKey])

  // ── Top 20 days-cover: mv_rate_of_sale scoped to the Top 20 EANs ────────────
  // Replaces the whole-store background fetch (PostgREST capped it at 1 000 of
  // ~345k rows — CC-BRIEF-DASH-FINAL-001 item 5). ≤40 EANs × stores stays far
  // under the cap and hits the (ean, store_code) index.
  useEffect(() => {
    const eans = [...new Set(top20Data.map(r => r.ean).filter(Boolean))]
    if (!eans.length || !storeCodes.length) { setTop20RosData([]); return }
    let cancelled = false
    supabase
      .from('mv_rate_of_sale')
      .select('ean,store_code,daily_ros,days_cover')
      .in('store_code', storeCodes)
      .in('ean', eans)
      .then(({ data }) => { if (!cancelled) setTop20RosData(data ?? []) })
    return () => { cancelled = true }
  }, [top20Data, storeCodes])

  // ── ENG-073: the family-resolved cover, overlaid on the scan-keyed one ──────
  // `mv_rate_of_sale` is keyed on the TILL SCAN CODE, so for a pack-and-single
  // family the loose code that holds the stock shows only its OWN scans and the
  // screen reports a cover the line does not have. Measured 2026-09-06: 706 lines
  // group-wide where the display understates the true draw, average 39x, worst
  // 2,649x -- TROPIKA EAZY PINEAPPLE at 10116 read 2,730 days against a true 6.3.
  //
  // OVERLAY, NOT REPLACE, and that is the whole design. `v_family_days_cover`
  // holds family MEMBERS only (6,715 rows / ~3,040 families), so a standalone
  // product has no row there. mv_rate_of_sale stays the base and supplies every
  // line; the family figure corrects the ones it covers. Replacing the source
  // outright would silently blank the cover on every non-family line.
  //
  // The recipe was family-resolved long ago (ENG-005) -- this is DISPLAY only,
  // and no order quantity moves.
  const [top20FamilyData, setTop20FamilyData] = useState([])
  useEffect(() => {
    const eans = [...new Set(top20Data.map(r => r.ean).filter(Boolean))]
    if (!eans.length || !storeCodes.length) { setTop20FamilyData([]); return }
    let cancelled = false
    supabase
      .from('v_family_days_cover')
      .select('ean,store_code,family_days_cover,scan_days_cover,family_ratio,display_understates,story')
      .in('store_code', storeCodes)
      .in('ean', eans)
      .then(({ data, error }) => {
        // Read the error. A failed overlay must fall back to the scan figure,
        // never render as "no cover" -- the ENG-179 false-zero class.
        if (cancelled) return
        if (error) { console.warn('ENG-073 family cover overlay unavailable:', error.message); setTop20FamilyData([]); return }
        setTop20FamilyData(data ?? [])
      })
    return () => { cancelled = true }
  }, [top20Data, storeCodes])

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

    // Show cached data immediately (optimistic UX) while the fresh fetch runs.
    // The cache is never authoritative — a live fetch always follows to pick up
    // new lines added by overnight pushes. product_search_index is the source of
    // truth; rpc_search_products is the per-keystroke fallback.
    const cached = loadCachedSearchIndex(scopeKey)
    if (cached) setSearchIndex(cached)

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
  }, [deptFilter, storeCodes, selectedDates, deptNormMap])

  // ─────────────────────────────────────────────────────────────────────────────
  // REPORT — on-demand fetch
  // ─────────────────────────────────────────────────────────────────────────────
  const loadReport = useCallback(async () => {
    if (!storeCodes.length || !selectedDates.length || reportLoading) return
    setReportLoading(true)

    const [rows, catalogRes, engineSlowRes] = await Promise.all([
      fetchAllRows({ storeCodes, dates: selectedDates }),
      // product_catalog carries supplier_name per EAN (loaded from DIWAAIS2 / PLU reference)
      // SB-CC-SEC-001: routed through rpc_supplier_by_ean (SECURITY DEFINER).
      supabase
        .rpc('rpc_supplier_by_ean', { p_stores: storeCodes })
        .then(r => r.data ?? [])
        .catch(() => []),
      // Engine-backed Slow Movers (l2_stock_position.slow_mover_signal, §5 KPI4).
      // Bridged to EAN; unbridged rows return ean=null (excluded + footnoted).
      //
      // 🔴 ENG-101: reads the JSONB wrapper, NOT the SETOF function.
      // The SETOF form was served through the live 1,000-row PostgREST cap with
      // no .range(), so this drawer has been showing 1,000 of 4,836 slow-moving
      // lines and presenting them as the whole population. Measured 2026-08-24:
      // R350,966 of dead capital shown against R1,952,636 real -- R1,601,670
      // invisible. Not slowness: a report that lies by omission (R22 §3).
      // One jsonb row cannot be truncated by a row cap (the rpc_report_rows
      // pattern), and `served` vs the array length is the tripwire.
      supabase
        .rpc('rpc_stock_report_engine_json', { p_store_codes: storeCodes, p_signal: 'slowmovers' })
        .then(r => {
          if (r.error) return { rows: [], err: r.error.message }
          const p = r.data
          const rows = Array.isArray(p?.rows) ? p.rows : []
          // R22 tripwire: if the payload disagrees with its own count, say so
          // rather than rendering a short report as though it were complete.
          if (p && typeof p.served === 'number' && p.served !== rows.length) {
            return { rows: [], err: `Slow Movers incomplete: served ${p.served} of ${rows.length} rows. Not safe to read — reload.` }
          }
          return { rows, err: null }
        })
        .catch(e => ({ rows: [], err: e?.message ?? 'Slow Movers read failed' })),
    ])

    // ROS / days-cover per (ean, store) comes off the report rows themselves —
    // rpc_report_rows carries the engine's daily_ros/days_cover on every row.
    // Replaces the unpaged mv_rate_of_sale table fetch that PostgREST silently
    // capped at 1 000 rows (~345k in the matview), which left Velocity tiers
    // and Signal C computing on <1% of the range (CC-BRIEF-DASH-FINAL-001 item 5).
    const rosRes = rows
      .filter(r => r.daily_ros != null || r.days_cover != null)
      .map(r => ({ ean: r.ean, store_code: r.store_code, daily_ros: r.daily_ros, days_cover: r.days_cover }))

    // Build ean → supplier_name lookup (last-write wins across stores — supplier is the same)
    const suppMap = new Map()
    for (const row of catalogRes) {
      if (row.supplier_name) suppMap.set(row.ean, row.supplier_name)
    }

    setReportRows(rows)
    setStoreRosData(rosRes)
    setSupplierMap(suppMap)
    setEngineSlowRows(engineSlowRes.rows)
    setEngineSlowError(engineSlowRes.err)
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
  // Sources: the Top-20-scoped fetch (available before any report is loaded)
  // plus the report rows' engine values once a report has been fetched.
  const eanDaysCoverMap = useMemo(() => {
    // Two maps, then merge. The scan figure is the BASE and covers every line;
    // the family figure is the CORRECTION and covers only family members.
    // Kept separate so "family wins" is a single obvious statement rather than
    // a condition buried in a loop.
    const tightest = (map, key, val) => {
      if (val == null) return
      const e = map.get(key)
      const v = Number(val)
      if (e == null || v < e) map.set(key, v)
    }
    const scan = new Map()
    for (const r of [...top20RosData, ...storeRosData]) tightest(scan, r.ean, r.days_cover)

    // ENG-073: where a family figure exists it IS the truth for that line, so it
    // REPLACES the scan figure rather than competing with it on min().
    // It moves in BOTH directions and that is correct: measured group-wide,
    // 406 lines fall (the screen was overstating cover) and 342 rise (a pack
    // code whose family sells through the single). 472 do not move.
    const fam = new Map()
    for (const r of top20FamilyData) tightest(fam, r.ean, r.family_days_cover)

    const m = new Map(scan)
    for (const [ean, v] of fam) m.set(ean, v)
    return m
  }, [top20RosData, storeRosData, top20FamilyData])

  // ENG-073: the reason travels with the number (R29), and it must be the reason
  // for THE NUMBER ACTUALLY SHOWN. Caught live on the first deploy: this map took
  // the FIRST row per ean while eanDaysCoverMap takes the TIGHTEST across the
  // selected stores, so the milk family displayed 0.7d and explained 2.0d -- a
  // story from a different store than the figure beside it. Same selection rule
  // as the map, or the explanation is for someone else's number.
  // Also no longer filtered on display_understates: a line whose cover ROSE moved
  // too, and a number that changed without a reason is the thing R29 forbids.
  const eanFamilyStoryMap = useMemo(() => {
    const m = new Map()
    for (const r of top20FamilyData) {
      if (r.family_days_cover == null) continue
      const cur = m.get(r.ean)
      if (cur == null || Number(r.family_days_cover) < Number(cur.family_days_cover)) m.set(r.ean, r)
    }
    return m
  }, [top20FamilyData])

  // Signal C — phantom stock: SOH > 0, active line, days_since_sale x daily_ros >= threshold
  const signalCCount = useMemo(() => {
    if (!reportLoaded || !rosMap.size || !availableDates.length) return 0
    const today  = availableDates[0]
    const cutoff = shiftDate(today, -ACTIVE_LINE_LOOKBACK)
    const seen   = new Set()
    let count    = 0
    for (const r of reportRows) {
      if ((r.soh ?? 0) <= 0 || r.is_placeholder) continue
      if (!r.last_sales_date_iso || r.last_sales_date_iso < cutoff) continue
      const ros      = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
      const dailyRos = ros.daily_ros ?? 0
      if (dailyRos <= 0) continue
      const daysSince = Math.floor((new Date(today) - new Date(r.last_sales_date_iso)) / 86400000)
      if (daysSince * dailyRos >= SIGNAL_C_THRESHOLD) {
        const key = `${r.ean}__${r.store_code}`
        if (!seen.has(key)) { seen.add(key); count++ }
      }
    }
    return count
  }, [reportRows, rosMap, reportLoaded, availableDates])

  // Stalled lines — active (has 13w ROS), in stock, no sale in >= 14 days — sorted by days stalled desc
  const stalledLines = useMemo(() => {
    if (!reportLoaded || !rosMap.size || !availableDates.length) return []
    const today  = availableDates[0]
    const cutoff = shiftDate(today, -ACTIVE_LINE_LOOKBACK)
    const seen   = new Set()
    const result = []
    for (const r of reportRows) {
      if ((r.soh ?? 0) <= 0 || r.is_placeholder) continue
      if (!r.last_sales_date_iso || r.last_sales_date_iso < cutoff) continue
      const daysSince = Math.floor((new Date(today) - new Date(r.last_sales_date_iso)) / 86400000)
      if (daysSince < SLOW_MOVER_DAYS) continue
      const ros = rosMap.get(`${r.ean}__${r.store_code}`) ?? {}
      if ((ros.daily_ros ?? 0) <= 0) continue
      const key = `${r.ean}__${r.store_code}`
      if (seen.has(key)) continue
      seen.add(key)
      const cost = unitCost(r)
      result.push({ ...r, daysSince, dailyRos: ros.daily_ros, capitalTied: (r.soh ?? 0) * cost })
    }
    return result.sort((a, b) => b.daysSince - a.daysSince)
  }, [reportRows, rosMap, reportLoaded, availableDates])

  // Capital Tied breakdown by dept — for drill-down modal (all SOH > 0 lines)
  const capTiedByDept = useMemo(() => {
    const m = new Map()
    for (const r of mergedReportRows) {
      if ((r.soh ?? 0) <= 0) continue
      const cost = unitCost(r)
      const tied = (r.soh ?? 0) * cost
      if (tied <= 0) continue
      const d = r.dept_name ?? 'Unknown'
      m.set(d, (m.get(d) ?? 0) + tied)
    }
    return [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)
  }, [mergedReportRows])

  // daysInPeriod: calendar days from earliest to latest selected date (min 1).
  // Replaces selectedDates.length wherever a real period length is needed — a click count
  // is not a count of trading days. For a single selected date the value is 1.
  const daysInPeriod = (() => {
    if (selectedDates.length <= 1) return 1
    const sorted = [...selectedDates].sort()
    return Math.round((new Date(sorted[sorted.length - 1]) - new Date(sorted[0])) / 86400000) + 1
  })()

  const reportData = useMemo(() => {
    if (!reportLoaded) return []
    const refDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
    if (currentReport === 'dept_margin') return buildDeptMarginReport(deptSummary, lyDeptSummary)
    if (currentReport === 'ghost_stock')     return ghostStockRows       // SB-AP-004 C
    if (currentReport === 'stock_integrity') return stockIntegrityRows  // SB-AP-004 C
    // Slow Movers reads the engine (l2_stock_position.slow_mover_signal, §5 KPI4),
    // not the L1 daily_snapshots path. SB-CC-DASH-SOURCE-003 Phase A.
    if (currentReport === 'slowmovers')
      return buildSlowMoversEngine(engineSlowRows, { deptFilter, subDeptFilter, focusEans, refDate, supplierMap })
    return buildReport(currentReport, filteredReportRows, moverMode, refDate, rosMap, supplierMap, daysInPeriod, focusEans)
  }, [currentReport, filteredReportRows, moverMode, selectedDates, reportLoaded, rosMap, supplierMap, deptSummary, lyDeptSummary, focusEans, daysInPeriod, ghostStockRows, stockIntegrityRows, engineSlowRows, deptFilter, subDeptFilter])

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

  // GP on ex-VAT basis — reads total_sales_ex_vat from the DB (per-item vat_pct, no flat assumption).
  // Dept/subdept path reads from rpc_dept_summary which also returns total_sales_ex_vat.
  const kpiSalesExVat = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSummary.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.total_sales_ex_vat ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSummary.reduce((s, r) => s + (r.total_sales_ex_vat ?? 0), 0)
    return kpiData.reduce((s, r) => s + (r.total_sales_ex_vat ?? 0), 0)
  }, [kpiData, deptSummary, deptFilter, subDeptFilter])

  const kpiGPRand = kpiSalesExVat - kpiCost
  const kpiGP     = kpiSalesExVat > 0 ? (kpiGPRand / kpiSalesExVat) * 100 : 0

  // ── Dual-source aggregates (SB-CC-DASH-TRUTH-001 §3) ───────────────────────
  // Headline = L2 engine, raw chip = L1, delta badge surfaced.
  // Pairing rules (DASH-SOURCE-MATRIX): sales/GP pair only on a single-date,
  // whole-store selection matching every store's engine sales day; stock
  // figures pair whenever the latest available date is in the selection.
  const l2Agg = useMemo(() => {
    if (!l2Kpi.length) return null
    const rows = l2Kpi.filter(r => storeCodes.includes(r.store_code))
    if (!rows.length) return null
    const sales   = rows.reduce((s, r) => s + Number(r.sales_incl_vat ?? 0), 0)
    const cost    = rows.reduce((s, r) => s + Number(r.sales_cost ?? 0), 0)
    const exVat   = sales / 1.15
    const gp      = exVat > 0 ? ((exVat - cost) / exVat) * 100 : null
    const capital = rows.reduce((s, r) => s + Number(r.capital_normal ?? 0), 0)
    const capProd = rows.reduce((s, r) => s + Number(r.capital_production ?? 0), 0)
    const capNonStock = rows.reduce((s, r) => s + Number(r.capital_non_stock ?? 0), 0)
    const negSoh    = rows.reduce((s, r) => s + Number(r.neg_soh_count ?? 0), 0)       // NORMAL-scope (Family 3B)
    const negSohAll = rows.reduce((s, r) => s + Number(r.neg_soh_count_all ?? 0), 0)   // canon §5 KPI5 all-class
    const dcDen   = rows.reduce((s, r) => s + (r.days_cover_normal_wtd != null ? Number(r.capital_normal ?? 0) : 0), 0)
    const dcNum   = rows.reduce((s, r) => s + (r.days_cover_normal_wtd != null ? Number(r.capital_normal ?? 0) * Number(r.days_cover_normal_wtd) : 0), 0)
    const daysCover = dcDen > 0 ? dcNum / dcDen : null
    return { rows, sales, exVat, gp, capital, capProd, capNonStock, negSoh, negSohAll, daysCover }
  }, [l2Kpi, storeCodes])

  // Engine purified Capital Tied (SB-CC-DASH-WIRE-001 ticket 1): sum the
  // l2_classification bucket-in-4 capital over the SELECTED stores. Point-in-time
  // (latest snapshot per store), store-selection aware. null until the view loads.
  const enginePurifiedCap = useMemo(() => {
    const rows = l2CapStore.filter(r => storeCodes.includes(r.store_code))
    if (!rows.length) return null
    return rows.reduce((s, r) => s + Number(r.capital_purified ?? 0), 0)
  }, [l2CapStore, storeCodes])

  // Engine in-scope capital BEFORE purification (NORMAL + soh<>0, incl. the
  // COST_ERROR pack ghosts + dead/phantom). This is the genuine ~R21M pre-engine
  // figure -- the Capital Tied raw comparator, so the delta shows the ghost the
  // engine strips (purified ~R10M). NOT the L1 daily_snapshots SOH*cost (which is
  // ~R9.8M with negative-cost lines -- not the ghost number).
  const engineInScopeCap = useMemo(() => {
    const rows = l2CapStore.filter(r => storeCodes.includes(r.store_code))
    if (!rows.length) return null
    return rows.reduce((s, r) => s + Number(r.capital_in_scope_total ?? 0), 0)
  }, [l2CapStore, storeCodes])

  // Deposit/returnable float carved out of the headline Capital Tied (SB-CC-DEPOSIT-001),
  // surfaced as its own line: pass-through liability (quart deposits, empties, crates),
  // not velocity-movable stock investment. Point-in-time, store-selection aware.
  const engineDeposits = useMemo(() => {
    const rows = l2CapStore.filter(r => storeCodes.includes(r.store_code))
    if (!rows.length) return null
    return rows.reduce((s, r) => s + Number(r.capital_deposits ?? 0), 0)
  }, [l2CapStore, storeCodes])

  const wholeStoreScope = deptFilter === 'all' && subDeptFilter === 'all' && !focusEans

  // Capital Tied reads the engine only at whole-store / store-selection scope
  // (the engine view is not dept-scoped yet); a dept/subdept/focus filter falls
  // back to rpc_dept_summary capital. Point-in-time, so not date-gated.
  const engineCapPairable = enginePurifiedCap != null && wholeStoreScope

  const dualSalesPairable = useMemo(() => (
    l2Agg != null && wholeStoreScope && selectedDates.length === 1 &&
    l2Agg.rows.every(r => r.sales_date === selectedDates[0])
  ), [l2Agg, wholeStoreScope, selectedDates])

  const dualStockPairable = useMemo(() => (
    l2Agg != null && wholeStoreScope &&
    availableDates.length > 0 && selectedDates.includes(availableDates[0])
  ), [l2Agg, wholeStoreScope, selectedDates, availableDates])

  // Delta badge per brief: <=0.5 silent grey, 0.5-2 amber, >2 red.
  // kind 'pct' = relative %, kind 'pp' = percentage-point difference (GP).
  function dualDelta(l2v, rawv, kind = 'pct') {
    if (l2v == null || rawv == null) return null
    const diff = kind === 'pp'
      ? Math.abs(l2v - rawv)
      : (rawv !== 0 ? Math.abs(l2v - rawv) / Math.abs(rawv) * 100 : null)
    if (diff == null) return null
    return {
      text: kind === 'pp' ? diff.toFixed(1) + 'pp' : diff.toFixed(1) + '%',
      cls: diff <= 0.5 ? 'sb-delta-ok' : diff <= 2 ? 'sb-delta-amber' : 'sb-delta-red',
    }
  }

  // BUG-3: normalize dept_name before comparing — dots stripped in deptFilter but
  // rpc_kpi_dept_counts may return the raw name (e.g. "GROCERIES.FOODS").
  // BUG-4: also respond to subDeptFilter (deptSohCounts already pre-filtered by RPC).
  const kpiNegSOH = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSohCounts.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.neg_soh_count ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSohCounts.reduce((s, r) => s + (r.neg_soh_count ?? 0), 0)
    // ENG-100 rider: whole-store path only. A NULL means the stock figure is not
    // yet computed for that date, so the TOTAL is unknown -- never a smaller
    // number presented as measured. Dept paths above are unaffected (they come
    // from rpc_kpi_dept_counts, which does not read the matview).
    if (latestKpiByStore.some(r => r.neg_soh_count === null || r.neg_soh_count === undefined)) return null
    return latestKpiByStore.reduce((s, r) => s + Number(r.neg_soh_count), 0)
  }, [deptFilter, subDeptFilter, deptSohCounts, latestKpiByStore])

  const kpiSlowMove = useMemo(() => {
    if (deptFilter !== 'all')
      return deptSohCounts.filter(r => normalizeDept(r.dept_name) === deptFilter).reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
    if (subDeptFilter !== 'all')
      return deptSohCounts.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
    return latestKpiByStore.reduce((s, r) => s + (r.slow_mover_count ?? 0), 0)
  }, [deptFilter, subDeptFilter, deptSohCounts, latestKpiByStore])
  // Lost Sales Value: OOS days × daily ROS × sell price per confirmed-OOS item.
  // OOS days = days since last_sales_date_iso to the most recent available date.
  // Matches the formula used in the Lost Sales download report (Signal A, line ~357)
  // so the KPI card and the download report agree on the same product.
  // Falls back to |SOH| × sell_price when ROS not available.
  // Respect the active dept/sub-dept selection so the KPI card matches the
  // headline (SB-CC-DEPT-KPI-001). dept_name + sub_dept_name are on each OOS row.
  const lostSalesItemsFiltered = useMemo(() => lostSalesItems.filter(r => {
    if (deptFilter    !== 'all' && normalizeDept(r.dept_name) !== deptFilter) return false
    if (subDeptFilter !== 'all' && r.sub_dept_name !== subDeptFilter)         return false
    return true
  }), [lostSalesItems, deptFilter, subDeptFilter])

  const lostSalesValue = useMemo(() => {
    if (!lostSalesItemsFiltered.length) return 0
    const refDate = availableDates[0] ?? new Date().toISOString().slice(0, 10)
    return lostSalesItemsFiltered.reduce((sum, r) => {
      const key      = `${r.ean}__${r.store_code}`
      const ros      = rosMap.get(key)
      const dailyRos = ros?.daily_ros ?? 0
      const price    = r.sell_price ?? 0
      const lastSale = r.last_sales_date_iso ?? ''
      const daysSince = lastSale
        ? Math.max(1, Math.floor((new Date(refDate) - new Date(lastSale)) / 86400000))
        : 1
      if (dailyRos > 0 && price > 0) {
        return sum + (daysSince * dailyRos * price)
      }
      return sum + Math.abs(r.soh ?? 0) * price
    }, 0)
  }, [lostSalesItemsFiltered, rosMap, availableDates])

  // Sell-Through Rate: % of ranged lines that sold >= 1 unit in period, by tier (SB-CC-003 item 5)
  const sellThroughRate = useMemo(() => {
    if (!reportLoaded || !mergedReportRows.length) return null
    // Active-line check — same definition as buildReport (CRASH-001 fix: was out-of-scope here)
    const refDate = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
    const activeLineCutoff = refDate ? shiftDate(refDate, -ACTIVE_LINE_LOOKBACK) : null
    const isActiveLine = r => !activeLineCutoff || ((r.last_sales_date_iso ?? '') >= activeLineCutoff)
    // Tier is the ENGINE verdict carried on every rpc_report_rows row
    // (l2_ranging_tier, RULE-BOOK §4) — replaces the client ROS-rank approximation.
    const counts = { top100: { total: 0, sold: 0 }, top1000: { total: 0, sold: 0 }, bor: { total: 0, sold: 0 } }
    for (const r of mergedReportRows) {
      if (!isActiveLine(r)) continue
      const tier = r.tier === 'TOP_100' ? 'top100' : r.tier === 'TOP_1000' ? 'top1000' : 'bor'
      counts[tier].total++
      if ((r.period_qty ?? 0) > 0) counts[tier].sold++
    }
    return ['top100', 'top1000', 'bor'].map(tier => ({
      label:   tier === 'top100' ? 'Top 100' : tier === 'top1000' ? 'Top 1000' : 'BOR',
      pct:     counts[tier].total > 0 ? Math.round(counts[tier].sold / counts[tier].total * 100) : 0,
      sold:    counts[tier].sold,
      total:   counts[tier].total,
    }))
  }, [reportLoaded, mergedReportRows, selectedDates])

  // ── dept chart (top 10) — deptSummary is already one row per dept, sorted by sales ──
  const deptChart = useMemo(() => {
    const map = new Map()
    for (const r of deptSummary) {
      const k = normalizeDept(r.dept_name)
      map.set(k, (map.get(k) ?? 0) + (r.total_sales_ex_vat ?? 0))
    }
    const sorted = [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
    const max = sorted[0]?.[1] ?? 1
    return sorted.map(([name, val]) => ({ name, val, pct: (val / max) * 100 }))
  }, [deptSummary])

  // ── Phase 3.2 derived values ─────────────────────────────────────────────────
  //
  // LY METRIC RULES — mirrors the current-period split:
  //   PERIOD metrics  (Sales, GP%, Qty)  → reduce over ALL lyKpiData rows (same N dates as selection)
  //   POINT-IN-TIME   (NegSOH, SlowMove, CapTied) → latest LY snapshot per store only
  //     (current uses latestKpiByStore; LY uses lyLatestKpiByStore)
  //
  // lyLatestKpiByStore: for each store, take the row with the highest snapshot_date
  // within lyKpiData. This is the LY equivalent of "today" even if the exact -364 date
  // was a non-trading day.
  const lyLatestKpiByStore = (() => {
    const m = {}
    for (const r of lyKpiData) {
      if (!m[r.store_code] || r.snapshot_date > m[r.store_code].snapshot_date) m[r.store_code] = r
    }
    return Object.values(m)
  })()

  // Dept/sub-dept/EAN-aware comparison values (SB-CC-DEPT-KPI-001). When a filter
  // is active, sum the dept summaries (subdept/ean-filtered server-side, dept
  // filtered here) so LY/WoW match the dept-aware headline; otherwise use the
  // whole-store mv rows exactly as before.
  const filterActive = deptFilter !== 'all' || subDeptFilter !== 'all'
  const byDept   = (rows) => deptFilter !== 'all' ? rows.filter(r => normalizeDept(r.dept_name) === deptFilter) : rows
  const sumField = (rows, f) => rows.reduce((s, r) => s + (r[f] ?? 0), 0)

  const lyDeptRows = byDept(lyKpiDeptSummary)
  const lyKpiSales = filterActive ? sumField(lyDeptRows, 'total_sales') : sumField(lyKpiData, 'total_sales')
  const lyKpiCost  = filterActive ? sumField(lyDeptRows, 'total_cost')  : sumField(lyKpiData, 'total_cost')
  const lyKpiQty   = filterActive ? sumField(lyDeptRows, 'total_qty')   : sumField(lyKpiData, 'total_qty')
  // LY ex-VAT: reads total_sales_ex_vat from DB — same source logic as kpiSalesExVat
  const lyKpiSalesExVat = filterActive
    ? sumField(lyDeptRows, 'total_sales_ex_vat')
    : lyKpiData.reduce((s, r) => s + (r.total_sales_ex_vat ?? 0), 0)
  const lyKpiGPRand = lyKpiSalesExVat - lyKpiCost
  const lyKpiGP     = lyKpiSalesExVat > 0 ? (lyKpiGPRand / lyKpiSalesExVat) * 100 : null
  // Point-in-time: Neg SOH / Slow Move use lyDeptSohCounts (single latest LY date,
  // dept/subdept-scoped) when a filter is active; fall back to whole-store mv rows.
  // lyDeptSohCounts is pre-filtered by subdept at the RPC; dept filter applied here.
  // 🔴 ENG-100 RIDER, PROPAGATED TO THE LY LEG (R30 addendum 3). The TY leg below
  // has used sumOrNull since ENG-100; these three LY legs kept `?? 0` and were
  // never swept, so a NULL contributor read as a measured ZERO. Live consequence
  // on 2026-09-06: mv_kpi_by_date carried 25 LY rows for the selection with the
  // stock facts NULL on ALL 25, and the cards rendered "LY 0" / "LY R 0" and drove
  // a delta off it -- Capital Tied showed a confident +58.8% against a baseline
  // that does not exist. Canon suppresses this comparison outright until the
  // 364-day sigma history lands (PROJECT-LEXICON §D, KPI 5 and KPI 6: DBAUms
  // covered 21% of lines), and NULL means "not computed", never zero.
  // The pattern was present, correct and documented one screen below, and was
  // read past -- the exact half of R30 addendum 3 that costs most.
  const sumOrNull = (rows, field) => {
    if (rows.some(r => r[field] === null || r[field] === undefined)) return null
    return rows.reduce((s, r) => s + Number(r[field]), 0)
  }
  const lyDeptSohRows = deptFilter !== 'all'
    ? lyDeptSohCounts.filter(r => normalizeDept(r.dept_name) === deptFilter)
    : lyDeptSohCounts
  const lyKpiNegSOH   = filterActive && lyDeptSohCounts.length > 0
    ? sumOrNull(lyDeptSohRows,      'neg_soh_count')
    : sumOrNull(lyLatestKpiByStore, 'neg_soh_count')
  const lyKpiSlowMove = filterActive && lyDeptSohCounts.length > 0
    ? sumOrNull(lyDeptSohRows,      'slow_mover_count')
    : sumOrNull(lyLatestKpiByStore, 'slow_mover_count')
  const lyDeptCapPresent = lyKpiDeptSummary.some(r => r.capital_tied != null)
  const lyKpiCapTied  = (filterActive && lyDeptCapPresent)
    ? sumOrNull(lyDeptRows,         'capital_tied')
    : sumOrNull(lyLatestKpiByStore, 'capital_tied')
  const hasLY         = filterActive ? lyDeptRows.length > 0 : lyKpiData.length > 0

  const wowDeptRows = byDept(wowKpiDeptSummary)
  const wowKpiSales = filterActive ? sumField(wowDeptRows, 'total_sales') : sumField(wowKpiData, 'total_sales')
  const wowKpiSalesExVat = filterActive ? sumField(wowDeptRows, 'total_sales_ex_vat') : sumField(wowKpiData, 'total_sales_ex_vat')
  const hasWoW      = filterActive ? wowDeptRows.length > 0 : wowKpiData.length > 0

  // Capital Tied: prefer dept-level capital_tied from rpc_dept_summary when a
  // filter is active and the RPC supplies it; else whole-store latest position.
  //
  // 🔴 ENG-100 RIDER: a NULL contributor makes the TOTAL unknowable, not smaller.
  // `reduce((s,r) => s + (r.x ?? 0), 0)` silently treats "not yet computed" as
  // zero, so one store missing its stock row would quietly under-report group
  // capital and the card would show the shortfall as though it were measured.
  // sumOrNull returns null the moment any contributor is null, so the card
  // renders an em-dash instead of a confident wrong number (R22 §3).
  // The helper is now DEFINED WITH THE LY LEG ABOVE, because that leg needs it
  // first; one definition serves both. Moved, never duplicated.
  const deptCapPresent = deptSummary.some(r => r.capital_tied != null)
  const kpiCapTied  = (filterActive && deptCapPresent)
    ? sumField(byDept(deptSummary), 'capital_tied')
    : sumOrNull(latestKpiByStore, 'capital_tied')

  // Ghost stock: rand value removed from Capital Tied (SB-AP-003). Point-in-time from latest snapshot per store.
  // ghost_stock_value is 0 / null for stores without product_classification rows yet.
  const kpiGhostStock = latestKpiByStore.reduce((s, r) => s + (r.ghost_stock_value ?? 0), 0)

  // Stock Turn (annualised): (Period COGS / daysInPeriod * 365) / Capital Tied. Target = 12/yr.
  // daysInPeriod = calendar days between earliest and latest selected date (not a click count).
  const kpiStockTurn = (kpiCapTied > 0 && daysInPeriod > 0)
    ? (kpiCost / daysInPeriod * 365) / kpiCapTied
    : null
  const kpiDaysCover = kpiStockTurn > 0 ? Math.round(365 / kpiStockTurn) : null
  const lyKpiStockTurn = (lyKpiCapTied > 0 && daysInPeriod > 0)
    ? (lyKpiCost / daysInPeriod * 365) / lyKpiCapTied
    : null

  // SB-CC-DASH-WIRE-001 ticket 2: Stock Turn / Day's Cover off the PURIFIED base.
  // The old period-COGS-over-ghost-capital method annualised a single day's COGS
  // over the ghost-inflated capital -> the implausible "49 turns / 7d". The engine's
  // capital-weighted Day's Cover (l2Agg.daysCover, SOH/ROS over NORMAL capital) is
  // the ROS-based truth; turns = 365 / cover. Used whenever the engine pairs.
  const engineDaysCover = engineCapPairable && l2Agg != null ? l2Agg.daysCover : null
  const engineStockTurn = engineDaysCover != null && engineDaysCover > 0 ? 365 / engineDaysCover : null

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
      if (!byDate[r.snapshot_date]) byDate[r.snapshot_date] = { sales: 0, salesExVat: 0, cost: 0, neg_soh: 0, slow_movers: 0, capital_tied: 0 }
      byDate[r.snapshot_date].sales        += r.total_sales        ?? 0
      byDate[r.snapshot_date].salesExVat   += r.total_sales_ex_vat ?? 0
      byDate[r.snapshot_date].cost         += r.total_cost         ?? 0
      byDate[r.snapshot_date].neg_soh      += r.neg_soh_count      ?? 0
      byDate[r.snapshot_date].slow_movers  += r.slow_mover_count   ?? 0
      byDate[r.snapshot_date].capital_tied += r.capital_tied       ?? 0
    }
    const sorted = Object.entries(byDate).sort(([a], [b]) => a.localeCompare(b))
    return {
      sales:       sorted.map(([, v]) => v.salesExVat),
      gpPct:       sorted.map(([, v]) => v.salesExVat > 0 ? gpPct(v.salesExVat, v.cost) : 0),
      negSoh:      sorted.map(([, v]) => v.neg_soh),
      slowMovers:  sorted.map(([, v]) => v.slow_movers),
      capitalTied: sorted.map(([, v]) => v.capital_tied),
    }
  }, [sparklineData, storeCodes])

  const lyDeptMap = useMemo(() => {
    const m = new Map()
    for (const r of lyDeptSummary) {
      const k = normalizeDept(r.dept_name)
      m.set(k, (m.get(k) ?? 0) + (r.total_sales_ex_vat ?? 0))
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
    // Ghost stock and Stock Integrity reports are fetched from their own RPCs.
    if (key === 'ghost_stock' || key === 'stock_integrity') {
      setReportLoading(true)
      const date = selectedDates.length ? [...selectedDates].sort().reverse()[0] : null
      if (!date) { setReportLoading(false); return }

      if (key === 'ghost_stock') {
        supabase.rpc('rpc_ghost_stock_report', { p_store_codes: storeCodes, p_date: date })
          .then(({ data, error }) => {
            if (error) console.error('[ghost_stock_report]', error.message)
            setGhostStockRows((data ?? []).map(r => ({
              'Store':       r.store_name ?? r.store_code,
              'EAN':         r.ean,
              'Description': r.description,
              'Dept':        r.dept_name,
              'Sub-Dept':    r.sub_dept_name,
              'SOH':         r.soh,
              'Unit Cost':   r.unit_cost,
              'Ghost Value': r.ghost_value,
              'Class':       r.exclusion_class,
              'Reason':      r.why_flagged,
            })))
            setReportLoaded(true)
            setReportLoading(false)
          })
      } else {
        supabase.rpc('rpc_stock_integrity_report', { p_store_codes: storeCodes, p_date: date })
          .then(({ data, error }) => {
            if (error) {
              console.error('[stock_integrity_report]', error.message)
              setStockIntegrityRows([{ 'Error': `RPC error: ${error.message}` }])
              setReportLoaded(true)
              setReportLoading(false)
              return
            }
            setStockIntegrityRows((data ?? []).map(r => ({
              'Store':        r.store_name ?? r.store_code,
              'EAN':          r.ean,
              'Description':  r.description,
              'Dept':         r.dept_name,
              'Sub-Dept':     r.sub_dept_name,
              'SOH':          r.soh,
              'Sell Price':   r.sell_price,
              'Issue Type':   r.integrity_type,
              'Days No Sale': r.days_no_sale ?? '—',
              'Value At Risk':r.value_at_risk,
            })))
            setReportLoaded(true)
            setReportLoading(false)
          })
      }
      return
    }
    // Consignment panel self-fetches — just mark loaded so the drawer renders it immediately
    if (key === 'consignment') { setReportLoaded(true); return }
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

  // ── FEAT-1: stable EAN list for product trend fetch ──────────────────────────
  // Derive from the underlying state values, NOT from activeProducts (which is a new
  // array reference every render, which would cause useMemo to recompute every render
  // and trigger the useEffect on every re-render — an infinite loop when idle).
  const activeEans = useMemo(() => {
    const prods = selectedProduct
      ? [selectedProduct]
      : (focusBasket.length > 0 && !isDefaultBasket) ? focusBasket : []
    return prods.map(p => String(p['EAN'] ?? p.ean ?? '')).filter(Boolean)
  }, [selectedProduct, focusBasket, isDefaultBasket])

  // ── FEAT-1: fetch rpc_focus_chart for the 90-day window when a product is selected ──
  // Rows are normalised to { store_code, snapshot_date, total_sales } so SalesTrendPanel
  // can consume them without modification.
  useEffect(() => {
    if (!activeEans.length || !storeCodes.length || !trendDates.length) {
      setProductTrendData([])
      setProductLyTrendData([])
      return
    }
    let cancelled = false
    const lyDates = trendDates.map(d => shiftDate(d, -364))
    Promise.all([
      supabase.rpc('rpc_focus_chart', {
        p_eans:        activeEans,
        p_store_codes: storeCodes,
        p_dates:       trendDates,
      }),
      lyDates.length > 0
        ? supabase.rpc('rpc_focus_chart', {
            p_eans:        activeEans,
            p_store_codes: storeCodes,
            p_dates:       lyDates,
          })
        : Promise.resolve({ data: [] }),
    ]).then(([tRes, lyRes]) => {
      if (cancelled) return
      // rpc_focus_chart returns today_sales_ex_vat (post-GAP1 fix) with today_sales fallback
      const norm = rows => (rows ?? []).map(r => ({
        store_code:    r.store_code,
        snapshot_date: r.snapshot_date,
        total_sales:   r.today_sales_ex_vat ?? r.today_sales ?? 0,
      }))
      setProductTrendData(norm(tRes.data))
      setProductLyTrendData(norm(lyRes.data ?? []))
    })
    return () => { cancelled = true }
  }, [activeEans, storeCodes, trendDates])

  // Effective trend data — priority: product selection > dept filter > whole-store
  const effectiveTrendData   = isSelectionActive ? productTrendData   : deptFilter !== 'all' ? deptTrendData   : trendData
  const effectiveLyTrendData = isSelectionActive ? productLyTrendData : deptFilter !== 'all' ? lyDeptTrendData : lyTrendData
  const trendContextLabel    = isSelectionActive
    ? `${activeProducts.length} product${activeProducts.length === 1 ? '' : 's'} selected`
    : null

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
      <div style={{ minHeight: '100vh', background: '#0C100C', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: "'Geist', sans-serif" }}>
        <div style={{ textAlign: 'center' }}>
          <div style={{ width: 36, height: 36, border: '3px solid rgba(74,107,83,0.30)', borderTopColor: '#FFD100', borderRadius: '50%', animation: 'spin 0.8s linear infinite', margin: '0 auto 16px' }} />
          <p style={{ color: 'rgba(245,245,244,0.35)', fontSize: 13 }}>Loading…</p>
        </div>
      </div>
    )
  }

  if (userProfile === null) {
    return (
      <div style={{ minHeight: '100vh', background: '#0C100C', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: "'Geist', sans-serif", padding: 24 }}>
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
    <div style={{ minHeight: '100vh', background: 'var(--sb-bg-grad, #0C100C)', backgroundAttachment: 'fixed', color: '#f5f5f4', fontFamily: "'Geist', -apple-system, sans-serif", position: 'relative', overflowX: 'hidden' }}>

      {/* ── STICKY FILTER BAR ────────────────────────────────────────────────── */}
      <div style={{
        position: 'sticky', top: 0, zIndex: 100,
        background: 'rgba(12,16,12,0.94)',
        borderBottom: '1px solid rgba(255,255,255,0.09)',
        backdropFilter: 'blur(32px)',
      }}>
        <div style={{ width: 'min(100%, 1800px)', margin: '0 auto' }} className="sb-filter-pad">

          {/* Row 1 — store chips (horizontal scroll) + date/reports (own row on mobile) */}
          <div className="sb-store-row" style={{ marginBottom: isMobile ? 4 : 8 }}>

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
                {!isMobile && <div style={{ width: 1, height: 22, background: 'rgba(255,255,255,0.1)', flexShrink: 0, margin: '0 2px' }} />}
              </>
            )}

            {/* Date picker — desktop: in the store row. Mobile: rendered below in its own row. */}
            {!isMobile && (
              <>
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
                {/* Reload data — primary CTA (CD-SPEC-001 sb-btn-daisy) */}
                <button className="sb-btn-daisy" onClick={handleReload}>
                  Reload data
                </button>
                <button
                  onClick={() => setDrawerOpen(true)}
                  style={{
                    padding: '6px 14px', fontSize: 12, fontWeight: 600,
                    background: 'rgba(74,107,83,0.18)',
                    border: '1px solid rgba(74,107,83,0.55)',
                    borderRadius: 8, cursor: 'pointer', color: '#F9FBF7',
                    fontFamily: 'Geist, sans-serif', whiteSpace: 'nowrap', flexShrink: 0,
                    transition: 'all 0.15s',
                  }}
                >
                  Reports & Downloads ›
                </button>
              </>
            )}
          </div>

          {/* Mobile row 1b — date picker + Reload CTA always visible, not buried in the chip scroll */}
          {isMobile && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
              <div style={{ position: 'relative' }}>
                <div style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', marginBottom: 2, fontFamily: 'Geist Mono, monospace', textTransform: 'uppercase', letterSpacing: '0.08em' }}>{displayDate}</div>
                <button
                  ref={calAnchorRef}
                  onClick={() => setCalOpen(o => !o)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 6,
                    padding: '7px 14px',
                    background: calOpen ? 'rgba(74,222,128,0.12)' : 'rgba(255,255,255,0.05)',
                    border: `1px solid ${calOpen ? 'rgba(74,222,128,0.35)' : 'rgba(255,255,255,0.1)'}`,
                    borderRadius: 8, cursor: 'pointer',
                    color: calOpen ? '#4ade80' : 'rgba(245,245,244,0.6)',
                    fontFamily: 'Geist, sans-serif', fontSize: 12,
                    transition: 'all 0.15s', minHeight: 44,
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
              {/* Reload data — primary CTA (CD-SPEC-001 sb-btn-daisy) */}
              <button className="sb-btn-daisy" onClick={handleReload}>
                Reload data
              </button>
            </div>
          )}

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
                    background: 'rgba(74,107,83,0.18)',
                    border: '1px solid rgba(74,107,83,0.55)',
                    borderRadius: 8, cursor: 'pointer', color: '#F9FBF7',
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
        <LayerFreshnessStrip rows={layerFresh} />

        <div style={{ display: 'grid', gap: 14 }}>

          {/* ── ENG-069: THE FAILURE STATE. R22 §3 — missing data surfaces, never hides.
                 Before this, a failed KPI request became `?? []` and rendered as R0 with a
                 manufactured −100% beside it, which is worse than a visible failure because
                 it reads as a real catastrophic number. A number that could not be read now
                 says so, and names the cause. ───────────────────────────────────────────── */}
          {!viewsLoading && (kpiError || kpiStockError) && (
            <div style={{
              border: '1px solid var(--data-neg)', borderRadius: 'var(--radius-md)',
              padding: '10px 14px', background: 'rgba(220,60,60,0.08)',
              color: 'var(--daisy-white)', fontSize: 13, lineHeight: 1.5,
            }}>
              {kpiError && (
                <div><strong>Sales figure unavailable — this is not a zero.</strong> {kpiError}</div>
              )}
              {kpiStockError && (
                <div style={{ marginTop: kpiError ? 6 : 0 }}>
                  <strong>Stock figures unavailable</strong> (negative SOH, slow movers, capital tied).
                  {' '}Sales above are unaffected and were read from <code>rpc_dept_summary</code>. {kpiStockError}
                </div>
              )}
            </div>
          )}

          {/* ── KPI STRIP ─────────────────────────────────────────────────────── */}
          <KpiStrip
            loading={viewsLoading}
            onTooltip={(key, content, rect) => {
              setTooltipPos({ left: rect.left, top: rect.bottom + 8 })
              setTooltipContent(content)
              setTooltipCard(key)
            }}
            onTooltipClear={() => { setTooltipCard(null); setTooltipContent(null) }}
            cards={(() => {
              if (viewsLoading) return []
              const kpiCards = [
                    {
                      key:           'sales',
                      label:         selectedDates.length > 1 ? `Total Sales · ${selectedDates.length} dates` : `Sales · ${selectedDates[0] ?? ''}`,
                      value:         dualSalesPairable ? zarShort(l2Agg.exVat) : zarShort(kpiSalesExVat),
                      sparkline:     sparklineArrays.sales,
                      lyRef:         hasLY ? zarShort(lyKpiSalesExVat) : null,
                      lyDelta:       hasLY ? deltaInfo(kpiSalesExVat, lyKpiSalesExVat) : null,
                      wowDelta:      hasWoW ? deltaInfo(kpiSalesExVat, wowKpiSalesExVat) : null,
                      bench:         sameWeekdayBenchmark ? `avg ${sameWeekdayBenchmark.dow}: ${zarShort(sameWeekdayBenchmark.avgSales)}` : null,
                      benchN:        sameWeekdayBenchmark?.n,
                      sub:           kpiQty > 0 ? `${num(kpiQty, 0)} units` : null,
                      accent:        true,
                      tone:          (() => {
                        if (!hasLY || !lyKpiSalesExVat) return 'neutral'
                        const cur = dualSalesPairable ? l2Agg.exVat : kpiSalesExVat
                        const d   = (cur - lyKpiSalesExVat) / lyKpiSalesExVat * 100
                        if (d >  2) return 'pos'
                        if (d >= -2) return 'neutral'
                        if (d >= -8) return 'warn'
                        return 'neg'
                      })(),
                      edge:          'green',
                      basisNote:     'ex-VAT',
                      dual:          dualSalesPairable ? {
                        rawLabel: zarShort(kpiSalesExVat),
                        delta:    dualDelta(l2Agg.exVat, kpiSalesExVat, 'pct'),
                        explain:  'One Sigma sales ledger, two VAT treatments. Headline = engine daily KPI, ex-VAT at a flat 15%. Raw chip = the same ledger with each line\'s native VAT. The delta is the VAT basis (plus any intraday timing), not two sources.',
                      } : null,
                      tooltip: {
                        heading: 'Total Sales',
                        what:    'Rand value of everything sold across selected stores and period, ex-VAT.',
                        source:  'Sigma sales ledger -- every till transaction, captured nightly.',
                        compare: 'Same period last year, shifted back exactly 52 weeks to preserve the day of week.',
                        signal:  'Green = up on LY. The raw chip is the same Sigma ledger on a native per-line VAT basis -- a small delta is normal; a large one is unusual.',
                      },
                    },
                    {
                      key:           'gp',
                      label:         'Gross Profit',
                      value:         dualSalesPairable && l2Agg.gp != null ? pct(l2Agg.gp) : pct(kpiGP),
                      sparkline:     sparklineArrays.gpPct,
                      lyRef:         hasLY && lyKpiGP != null ? pct(lyKpiGP) : null,
                      lyDelta:       hasLY && lyKpiGP != null ? ppDeltaInfo(kpiGP, lyKpiGP) : null,
                      wowDelta:      null,
                      bench:         null,
                      sub:           `Cost ${zarShort(kpiCost)}`,
                      warn:          (dualSalesPairable && l2Agg.gp != null ? l2Agg.gp : kpiGP) < 20,
                      danger:        (dualSalesPairable && l2Agg.gp != null ? l2Agg.gp : kpiGP) < 10,
                      tone:          (() => {
                        if (!hasLY || lyKpiGP == null) return 'neutral'
                        const cur = dualSalesPairable && l2Agg.gp != null ? l2Agg.gp : kpiGP
                        const pp  = cur - lyKpiGP
                        if (pp >  0.5) return 'pos'
                        if (pp >= -0.5) return 'neutral'
                        if (pp >= -1.5) return 'warn'
                        return 'neg'
                      })(),
                      edge:          'blue',
                      basisNote:     dualSalesPairable && l2Agg.gp != null ? 'engine (dEKUmsatz cost) · ex-VAT' : `${zarShort(kpiGPRand)} · ex-VAT`,
                      dual:          dualSalesPairable && l2Agg.gp != null ? {
                        rawLabel: pct(kpiGP),
                        delta:    dualDelta(l2Agg.gp, kpiGP, 'pp'),
                        explain:  'One Sigma ledger, two VAT treatments. Headline = engine GP on Sigma recorded cost (dEKUmsatz), ex-VAT at a flat 15%. Raw chip = the same ledger and cost with each line\'s native VAT. The delta is the VAT basis, not a data source. Pack-size cost corruption surfaces in the Cost Error worklist, not here.',
                      } : null,
                      tooltip: {
                        heading: 'Gross Profit',
                        what:    "What's left after cost of goods, as a percentage of ex-VAT sales.",
                        source:  "Engine uses Sigma's own recorded cost (dEKUmsatz), ex-VAT. The raw chip is the same figure on a native per-line VAT basis, shown for comparison.",
                        compare: 'Same period last year. The raw-chip delta is a VAT-basis difference, not a display bug.',
                        signal:  'Below 18% -- watch it. Pack-size cost errors that dent GP are surfaced in the Cost Error worklist, to fix at source.',
                      },
                    },
                    {
                      key:           'stockturn',
                      label:         'Stock Turn',
                      value:         (engineStockTurn != null
                        ? `${engineStockTurn.toFixed(1)} turns · ${Math.round(engineDaysCover)}d cover`
                        : (kpiStockTurn != null ? `${kpiStockTurn.toFixed(1)} turns · ${kpiDaysCover}d cover` : '—')),
                      sparkline:     null,
                      lyRef:         hasLY && lyKpiStockTurn != null ? `${lyKpiStockTurn.toFixed(1)} turns` : null,
                      lyDelta:       null,
                      wowDelta:      null,
                      bench:         (engineStockTurn ?? kpiStockTurn) != null ? (() => { const t = engineStockTurn ?? kpiStockTurn; return `target: 12 turns · ${t < 12 ? `↓ ${(12 - t).toFixed(1)} vs target` : `↑ ${(t - 12).toFixed(1)} above target`}` })() : null,
                      sub:           engineStockTurn != null
                        ? `engine ROS-based · purified ${zarShort(enginePurifiedCap)}`
                        : (kpiCapTied > 0 ? `Capital tied ${zarShort(kpiCapTied)}` : 'Insufficient data'),
                      warn:          (engineStockTurn ?? kpiStockTurn) != null && (engineStockTurn ?? kpiStockTurn) < 12,
                      tone:          (() => {
                        const t = engineStockTurn ?? kpiStockTurn
                        if (t == null) return 'neutral'
                        if (t >= 12.5)  return 'pos'
                        if (t >= 11.25) return 'neutral'
                        if (t >= 9)     return 'warn'
                        return 'neg'
                      })(),
                      tooltip: {
                        heading: 'Stock Turn',
                        what:    'How many times the sellable stock investment cycles through in a year.',
                        source:  'Engine -- capital-weighted 91-day rate of sale on buy-and-sell lines only. Production lines and ghost stock excluded.',
                        compare: 'LY turns shown as reference. Target is 12 turns per year (30 days cover).',
                        signal:  'Above 12 = capital moving well. Below 12 = stock is sitting too long. Fresh lines should turn much faster than the store average.',
                      },
                    },
                    {
                      key:           'negsoh',
                      label:         'Negative SOH',
                      value:         (dualStockPairable && l2Agg != null) ? num(l2Agg.negSohAll) : num(kpiNegSOH),
                      sparkline:     sparklineArrays.negSoh,
                      // ENG-100 rider: hasLY only says LY ROWS exist, not that the
                      // stock fact was computed. Measured 2026-09-06: 25 LY rows,
                      // neg_soh_count NULL on all 25. Gate on the VALUE.
                      lyRef:         (hasLY && lyKpiNegSOH != null) ? num(lyKpiNegSOH) : null,
                      lyDelta:       (hasLY && lyKpiNegSOH != null) ? deltaInfo(kpiNegSOH, lyKpiNegSOH) : null,
                      lyDeltaInvert: true,
                      wowDelta:      null,
                      bench:         null,
                      sub:           (dualStockPairable && l2Agg != null) ? 'engine (sigma ledger) · all classes' : 'Stock errors / shrinkage',
                      danger:        ((dualStockPairable && l2Agg != null) ? l2Agg.negSohAll : kpiNegSOH) > 0,
                      tone:          (() => {
                        if (!hasLY || !lyKpiNegSOH) return 'neutral'
                        const cur = (dualStockPairable && l2Agg != null) ? l2Agg.negSohAll : kpiNegSOH
                        const d   = (cur - lyKpiNegSOH) / lyKpiNegSOH * 100
                        if (d <= -20) return 'pos'
                        if (d <=  20) return 'neutral'
                        if (d <=  50) return 'warn'
                        return 'neg'
                      })(),
                      edge:          'red',
                      onClick:       () => { setDrawerOpen(true); handleReportCardClick('stock_integrity') },
                      dual:          (dualStockPairable && l2Agg != null) ? {
                        rawLabel: `${num(kpiNegSOH)}`,
                        delta:    dualDelta(l2Agg.negSohAll, kpiNegSOH, 'pct'),
                        explain:  'Headline = L2 engine all-class Negative SOH (l2_kpi_daily.neg_soh_count_all, always-latest sigma position, canon RULE-BOOK §5 KPI 5 incl. Type-A production negatives). Raw chip = the selected-date sigma-ledger snapshot (v_kpi_by_date, sourced from l2_soh_daily). Delta = always-latest position vs the day\'s ledger snapshot and scope; the ledger is the truth (R26). 14-day sparkline is the l2_soh_daily series.',
                      } : null,
                      tooltip: {
                        heading: 'Negative SOH',
                        what:    'Count of products where the Sigma ledger shows less than zero on shelf.',
                        source:  'Engine reads the always-latest Sigma stock position directly. The raw chip counts the selected date\'s ledger snapshot, so the two differ by timing and scope, not by data source.',
                        compare: 'Same date last year -- a falling count means the team is fixing receiving gaps and count errors.',
                        signal:  'Any negative is a stock integrity issue. Click to open the full list. Production lines (bread, scale items) carry structural negatives -- those need a floor fix, not a stocktake.',
                      },
                    },
                    {
                      key:           'captied',
                      label:         'Capital Tied',
                      value:         engineCapPairable ? zarShort(enginePurifiedCap) : zarShort(kpiCapTied),
                      sparkline:     sparklineArrays.capitalTied,
                      // ENG-100 rider, same as Negative SOH above: gate on the VALUE,
                      // not on hasLY. This card was showing "LY R 0" and a confident
                      // +58.8% delta against a baseline that does not exist.
                      lyRef:         (hasLY && lyKpiCapTied != null) ? zarShort(lyKpiCapTied) : null,
                      lyDelta:       (hasLY && lyKpiCapTied != null) ? deltaInfo(engineCapPairable ? enginePurifiedCap : kpiCapTied, lyKpiCapTied) : null,
                      lyDeltaInvert: true,
                      wowDelta:      null,
                      // bench renders unconditionally (sub is suppressed when LY data is
                      // present). Surface the carved deposit float here so it's never hidden.
                      bench:         (engineCapPairable && engineDeposits)
                        ? `+ deposits ${zarShort(engineDeposits)} · returnable float (carved)`
                        : null,
                      sub:           engineCapPairable
                        ? `engine purified · cover ${engineDaysCover != null ? engineDaysCover.toFixed(0) + 'd' : '--'}`
                        : 'SOH x unit cost (latest snapshot)',
                      warn:          true,
                      tone:          (() => {
                        if (!hasLY || !lyKpiCapTied) return 'neutral'
                        const cur = engineCapPairable ? enginePurifiedCap : kpiCapTied
                        const d   = (cur - lyKpiCapTied) / lyKpiCapTied * 100
                        if (d <= 20) return 'neutral'
                        if (d <= 50) return 'warn'
                        return 'neg'
                      })(),
                      edge:          'amber',
                      dual:          engineCapPairable ? {
                        rawLabel: zarShort(engineInScopeCap),
                        delta:    dualDelta(enginePurifiedCap, engineInScopeCap, 'pct'),
                        explain:  `Headline = L2 engine purified Capital Tied (l2_classification, bucket IN HEALTHY/COUNT/AMBIGUOUS/LEAVE_COUNTED; canon §8.8, ~R10M). Raw = engine in-scope capital BEFORE purification (NORMAL + SOH, incl. COST_ERROR pack ghosts + dead/phantom; ~R21M). The gap is the exact ghost capital the engine strips (R21 -- earned exclusions, surfaced not hidden).`,
                      } : null,
                      tooltip: {
                        heading: 'Capital Tied',
                        what:    'The rand value of sellable, buyable stock on shelf at cost -- your real stock investment.',
                        source:  'Engine-purified: ghost stock, production lines, deposits and cost errors stripped out. The raw chip shows the unfiltered figure before that cleanup.',
                        compare: 'LY reference shown as direction only -- the LY figure is a historical snapshot on an older basis, so treat the percentage as a trend signal, not a precise comparison.',
                        signal:  'The gap between purified and raw is capital locked in lines the engine has flagged. 30 days cover or less is the target for standard lines.',
                        note:    'Deposits (quart bottles, crates, empties) are carved out separately -- returnable float, not stock investment.',
                      },
                      onClick:       kpiCapTied > 0 ? () => setCapTiedModalOpen(true) : undefined,
                    },
                  ]
                  return kpiCards.map(k => {
                    const lyUp   = k.lyDelta?.positive
                    const lyGood = k.lyDeltaInvert ? !lyUp : lyUp
                    const wowUp  = k.wowDelta?.positive
                    const chips = [
                      ...(k.lyDelta  ? [{ t: k.lyDelta.label,           k: lyGood ? 'pos' : 'neg' }] : []),
                      ...(k.lyRef    ? [{ t: `LY ${k.lyRef}`,           k: 'mute' }] : []),
                      ...(k.wowDelta ? [{ t: `WoW ${k.wowDelta.label}`, k: wowUp ? 'pos' : 'neg' }] : []),
                      ...(k.dual     ? [{ t: `raw ${k.dual.rawLabel}`,  k: 'mute' }] : []),
                      ...(k.dual?.delta ? [{ t: `Δ ${k.dual.delta.text}`, k: k.dual.delta.cls === 'sb-delta-amber' ? 'warn' : k.dual.delta.cls === 'sb-delta-red' ? 'neg' : 'mute' }] : []),
                    ]
                    return {
                      key:      k.key,
                      label:    k.label,
                      value:    k.value,
                      tone:     k.tone,
                      sparkline: k.sparkline,
                      edge:     k.edge,
                      onClick:  k.onClick,
                      tooltip:  k.tooltip,
                      chips,
                      meta: k.bench ? k.bench + (k.benchN != null ? ` (${k.benchN}w avg)` : '') : null,
                      sub:  k.sub ? (k.basisNote ? `${k.sub} · ${k.basisNote}` : k.sub) : k.basisNote ?? null,
                    }
                  })
                })()}
          />

          {/* ── SELL-THROUGH RATE PANEL ──────────────────────────────────────── */}
          {sellThroughRate && (
            <div className="sb-glass" style={{ padding: '16px 20px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
                <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 14, fontWeight: 600 }}>Sell-Through Rate</span>
                <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.35)', background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 5, padding: '1px 7px' }}>
                  % of ranged lines that sold in period
                </span>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
                {sellThroughRate.map(({ label, pct, sold, total }) => {
                  const barColor = pct >= 80 ? '#4ade80' : pct >= 60 ? '#fbbf24' : '#ef4444'
                  const trackColor = pct >= 80 ? 'rgba(74,222,128,0.12)' : pct >= 60 ? 'rgba(251,191,36,0.12)' : 'rgba(239,68,68,0.12)'
                  return (
                    <div key={label} style={{ display: 'grid', gridTemplateColumns: '72px 1fr 44px 80px', alignItems: 'center', gap: 10 }}>
                      <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.5)' }}>{label}</span>
                      <div style={{ height: 7, borderRadius: 4, background: trackColor, overflow: 'hidden' }}>
                        <div style={{ height: '100%', width: `${pct}%`, borderRadius: 4, background: barColor }} />
                      </div>
                      <span style={{ fontSize: 11, fontFamily: "'Geist Mono', monospace", fontWeight: 700, color: barColor, textAlign: 'right' }}>{pct}%</span>
                      <span style={{ fontSize: 9, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.3)', textAlign: 'right' }}>{sold} / {total}</span>
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {/* ── SALES TREND ──────────────────────────────────────────────────── */}
          {/* Guard: show frosted placeholder during pre-init (no stores yet) and during data load */}
          {(viewsLoading || !storeCodes.length)
            ? <div className="sb-glass sb-frost-veil" data-loading="true" style={{ minHeight: 160, borderRadius: 'var(--radius-card)' }} />
            : <SalesTrendPanel
                trendData={effectiveTrendData}
                lyTrendData={effectiveLyTrendData}
                storeCodes={storeCodes}
                rhythmProfiles={rhythmProfiles}
                contextLabel={trendContextLabel}
                selectionEndDate={selectedDates.length ? [...selectedDates].sort().reverse()[0] : null}
              />
          }

          {/* ── TOP 20 + DEPT CHART — hidden while a product selection is active ─── */}
          {!isSelectionActive && (
            <div className="sb-two-col">

              {/* Top 20 Movers / Non-Movers */}
              <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                    <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>
                      {top20Activity === 'movers' ? 'Top 20 Movers' : 'Top 20 Non-Movers'}
                    </span>
                    {top20Activity === 'movers' && moverMode === 'value' && (
                      <span style={{ fontSize: 10, color: 'rgba(74,222,128,0.6)', fontFamily: "'Geist Mono', monospace" }}>ex-VAT</span>
                    )}
                    {top20Activity === 'non_movers' && moverMode === 'value' && (
                      <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.3)', fontFamily: "'Geist Mono', monospace" }}>stock value</span>
                    )}
                  </div>
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
                {(viewsLoading || top20Loading || !storeCodes.length)
                  ? <div className="sb-frost-veil" data-loading="true" style={{ minHeight: 320, borderRadius: 8 }} />
                  : (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 360, overflowY: 'auto' }}>
                      {top20.length > 0 && (
                        <div style={{ display: 'grid', gridTemplateColumns: '20px 1fr 58px 40px 68px', gap: 6, padding: '0 10px 4px', borderBottom: '1px solid rgba(255,255,255,0.06)', marginBottom: 2 }}>
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
                      {/* ENG-141 — a failed read and an empty list are DIFFERENT
                          statements about the store, and only one of them is a
                          fact. Never render a failure as "nothing found". Same
                          discipline as the KPI cards' "this is not a zero". */}
                      {top20.length === 0 && top20Error && (
                        <p style={{ color: 'rgba(251,191,36,0.85)', fontSize: 13, padding: '20px 0', textAlign: 'center' }}>
                          Top 20 unavailable — this is not an empty list. {top20Error}
                        </p>
                      )}
                      {top20.length === 0 && !top20Error && (
                        <p style={{ color: 'rgba(245,245,244,0.3)', fontSize: 13, padding: '20px 0', textAlign: 'center', fontStyle: 'italic' }}>
                          {top20Activity === 'non_movers'
                            ? `No non-moving stock · ${selectedDates.length} date${selectedDates.length !== 1 ? 's' : ''} · ${deptFilter !== 'all' ? deptFilter : 'all depts'}`
                            : `No movers found · ${selectedDates.length} date${selectedDates.length !== 1 ? 's' : ''} · ${deptFilter !== 'all' ? deptFilter : 'all depts'}`
                          }
                        </p>
                      )}
                      {top20.map((r, i) => {
                        const ros = selectedDates.length > 0 ? r.total_qty / selectedDates.length : 0
                        // Days cover: mv_rate_of_sale (91-day rolling) as the base,
                        // corrected to the FAMILY-resolved figure where one exists (ENG-073).
                        const dc  = eanDaysCoverMap.get(r.ean) ?? null
                        const fam = eanFamilyStoryMap.get(r.ean) || null
                        const dcColour = dc == null  ? 'rgba(245,245,244,0.25)'
                                       : dc <= 2     ? '#ef4444'   // red — reorder now
                                       : dc <= 5     ? '#f97316'   // amber — reorder soon
                                       :               'rgba(245,245,244,0.4)'  // normal
                        return (
                          <div key={r.ean} onClick={() => handleProductClick(r)} style={{ display: 'grid', gridTemplateColumns: '20px 1fr 58px 40px 68px', gap: 6, alignItems: 'center', padding: '8px 10px', background: 'rgba(255,255,255,0.025)', borderRadius: 8, cursor: 'pointer' }}>
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
                            {/* Days cover. Family-resolved where the line is part of a
                                pack-and-single family (ENG-073); the reason travels on
                                hover rather than the number changing silently (R29). */}
                            <span
                              title={fam
                                ? `Family-resolved cover. The scan code alone reads ${Number(fam.scan_days_cover).toFixed(1)}d, `
                                  + `but this line is part of a pack-and-single family and its true draw gives ${Number(fam.family_days_cover).toFixed(1)}d`
                                  + (fam.story ? `. ${fam.story}` : '.')
                                : undefined}
                              style={{ fontFamily: "'Geist Mono', monospace", fontSize: 10, color: dcColour, whiteSpace: 'nowrap', textAlign: 'right', cursor: fam ? 'help' : undefined }}>
                              {dc != null
                                ? <>{dc.toFixed(1)}<span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(245,245,244,0.25)' }}>d</span>
                                    {fam && <span style={{ fontSize: 9, marginLeft: 2, color: 'rgba(74,222,128,0.55)' }}>ƒ</span>}
                                  </>
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
                  <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Sales by Department<span style={{ marginLeft: 8, fontSize: 9, color: 'rgba(74,222,128,0.6)', fontFamily: "'Geist Mono', monospace", fontWeight: 400, textTransform: 'uppercase', letterSpacing: '0.08em', verticalAlign: 'middle' }}>ex-VAT</span></p>
                  {showLYDept && (
                    <span style={{ fontSize: 10, color: 'rgba(74,222,128,0.5)', fontFamily: "'Geist Mono', monospace" }}>vs LY shown</span>
                  )}
                </div>
                {viewsLoading
                  ? <div className="sb-frost-veil" data-loading="true" style={{ minHeight: 280, borderRadius: 8 }} />
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
                              <div style={{ height: '100%', width: `${d.pct}%`, background: '#4A6B53', borderRadius: 999, transition: 'width 0.5s ease' }} />
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

          {/* ── PRODUCT DETAIL + LOST SALES — CSS order flips when selection active ── */}
          {/* Product detail jumps above lost sales when isSelectionActive = true.       */}
          <div style={{ display: 'flex', flexDirection: 'column' }}>

          {/* ── LOST SALES TRACKER ──────────────────────────────────────────────── */}
          {/* True OOS: SOH<=0, period_qty=0, active line (sold in 364 days). Ledger Discrepancies excluded. */}
          <div style={{ order: isSelectionActive ? 1 : 0 }}>
          {lostSalesItems.length > 0 && (
            <div className="sb-glass" style={{ padding: '20px 22px', marginBottom: 16 }}>
              {(() => {
                // Aggregate by dept for summary row (uses |SOH|×sell_price for proportional breakdown)
                const deptMap = new Map()
                for (const r of lostSalesItems) {
                  const lostVal = Math.abs(r.soh ?? 0) * (r.sell_price ?? 0)
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
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                        <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Lost Sales</span>
                        <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.25)', borderRadius: 6, padding: '2px 8px' }}>
                          Signal A · True OOS
                        </span>
                        {signalCCount > 0 && (
                          <span title="Signal C: in-stock items where days since last sale x daily ROS >= 1 (phantom stock)" style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(251,191,36,0.7)', background: 'rgba(251,191,36,0.08)', border: '1px solid rgba(251,191,36,0.2)', borderRadius: 6, padding: '2px 8px', cursor: 'help' }}>
                            C: {signalCCount} phantom
                          </span>
                        )}
                      </div>
                      <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 16, fontWeight: 700, color: '#ef4444' }}>
                        {zarShort(lostSalesValue)}
                        <span style={{ fontSize: 10, marginLeft: 6, color: 'rgba(239,68,68,0.6)', fontWeight: 400 }}>est. lost</span>
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
                          const storeRows = lostSalesTimeline.get(r.ean) ?? []
                          return (
                            <div key={r.ean} style={{ padding: '8px 10px', background: 'rgba(239,68,68,0.05)', borderRadius: 8, borderLeft: '2px solid rgba(239,68,68,0.3)' }}>

                              {/* Top row: name + numbers */}
                              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto auto auto', gap: 10, alignItems: 'center', marginBottom: storeRows.length ? 8 : 0 }}>
                                <div style={{ overflow: 'hidden' }}>
                                  <p style={{ fontSize: 12, color: '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.description}</p>
                                  <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 1 }}>
                                    {r.dept_name}
                                    <span style={{ margin: '0 5px', opacity: 0.3 }}>·</span>
                                    <span style={{ color: 'rgba(245,245,244,0.45)' }}>{r.ean}</span>
                                    <span style={{ margin: '0 5px', opacity: 0.3 }}>·</span>
                                    <span style={{ color: 'rgba(245,245,244,0.35)' }}>{r.store_name}</span>
                                  </p>
                                </div>
                                <span style={{ fontSize: 9, fontFamily: "'Geist Mono', monospace", fontWeight: 700,
                                  color: 'rgba(239,68,68,0.7)', background: 'rgba(239,68,68,0.1)',
                                  border: '1px solid rgba(239,68,68,0.2)',
                                  borderRadius: 4, padding: '1px 5px', whiteSpace: 'nowrap' }}>
                                  OOS
                                </span>
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

                              {/* Timeline — 56-day availability strip, fixed-width cells like Stock Availability */}
                              {timelineLoading && !storeRows.length ? (
                                <div style={{ height: 20, background: 'rgba(255,255,255,0.04)', borderRadius: 3, animation: 'pulse 1.5s infinite' }} />
                              ) : storeRows.length > 0 ? (
                                <div style={{ overflowX: 'auto' }}>
                                  {storeRows.map(sr => (
                                    <div key={sr.store_code} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 3 }}>
                                      <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.4)', minWidth: 90, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{sr.store_name}</span>
                                      <div style={{ display: 'flex', gap: 2 }}>
                                        {sr.days.map(day => {
                                          const bg = day.oos_bool
                                            ? 'rgba(239,68,68,0.75)'
                                            : day.sold_bool
                                              ? '#4ade80'
                                              : 'rgba(255,255,255,0.06)'
                                          return (
                                            <div
                                              key={day.snap_date}
                                              title={`${day.snap_date}: ${day.sold_bool ? 'sold' : day.oos_bool ? 'OOS' : 'in stock · no sale'} · SOH ${day.soh}`}
                                              style={{ flexShrink: 0, width: 6, height: 20, borderRadius: 2, background: bg }}
                                            />
                                          )
                                        })}
                                      </div>
                                    </div>
                                  ))}
                                  {storeRows[0]?.days.length > 0 && (
                                    <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 2, paddingLeft: 98 }}>
                                      <span style={{ fontSize: 8, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.2)' }}>{storeRows[0].days[0]?.snap_date?.slice(5)}</span>
                                      <span style={{ fontSize: 8, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.2)' }}>{storeRows[0].days[storeRows[0].days.length - 1]?.snap_date?.slice(5)}</span>
                                    </div>
                                  )}
                                </div>
                              ) : null}
                            </div>
                          )
                        })
                      }
                    </div>

                    {lostSalesItems.length > 10 && (
                      <button
                        onClick={() => { setCurrentReport('lostsales'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport() }}
                        style={{ marginTop: 10, width: '100%', background: 'none', border: 'none', cursor: 'pointer', fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', textAlign: 'center', padding: '4px 0', textDecoration: 'underline', textDecorationColor: 'rgba(245,245,244,0.15)', textUnderlineOffset: 3 }}
                      >
                        + {lostSalesItems.length - 10} more lines · open Lost Sales report for full list
                      </button>
                    )}
                  </>
                )
              })()}
            </div>
          )}

          </div>{/* end lost-sales order div */}

          {/* ── STALLED LINES ────────────────────────────────────────────────── */}
          {/* Active lines (have 13w ROS) that have stock but no sale in >= 14 days */}
          {reportLoaded && stalledLines.length > 0 && (
            <div className="sb-glass" style={{ padding: '20px 22px', marginBottom: 16 }}>
              {(() => {
                const totalCapTied = stalledLines.reduce((s, r) => s + (r.capitalTied ?? 0), 0)
                const top5 = stalledLines.slice(0, 5)
                return (
                  <>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                        <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Stalled Lines</span>
                        <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', background: 'rgba(245,158,11,0.1)', border: '1px solid rgba(245,158,11,0.2)', borderRadius: 6, padding: '2px 8px' }}>
                          {stalledLines.length} lines · {num(stalledLines.filter(r => (r.daysSince ?? 0) * (r.dailyRos ?? 0) >= SIGNAL_C_THRESHOLD).length)} phantom (C)
                        </span>
                      </div>
                      <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 16, fontWeight: 700, color: '#f59e0b' }}>
                        {zarShort(totalCapTied)}
                        <span style={{ fontSize: 10, marginLeft: 6, color: 'rgba(245,158,11,0.6)', fontWeight: 400 }}>tied</span>
                      </span>
                    </div>

                    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                      {top5.map(r => {
                        const isPhantom = (r.daysSince ?? 0) * (r.dailyRos ?? 0) >= SIGNAL_C_THRESHOLD
                        return (
                          <div key={`${r.ean}__${r.store_code}`} style={{ display: 'grid', gridTemplateColumns: '1fr auto auto auto', gap: 10, alignItems: 'center', padding: '7px 10px', background: isPhantom ? 'rgba(251,191,36,0.05)' : 'rgba(245,158,11,0.04)', borderRadius: 7, borderLeft: `2px solid ${isPhantom ? 'rgba(251,191,36,0.35)' : 'rgba(245,158,11,0.25)'}` }}>
                            <div style={{ overflow: 'hidden' }}>
                              <p style={{ fontSize: 12, color: '#f5f5f4', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.description}</p>
                              <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 1 }}>{r.dept_name}</p>
                            </div>
                            <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: isPhantom ? 'rgba(251,191,36,0.8)' : 'rgba(245,158,11,0.7)', whiteSpace: 'nowrap' }}>
                              {r.daysSince}d
                            </span>
                            <span style={{ fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', whiteSpace: 'nowrap' }}>
                              {num(r.soh ?? 0)} SOH
                            </span>
                            <span style={{ fontSize: 11, fontFamily: "'Geist Mono', monospace", color: '#f59e0b', fontWeight: 600, whiteSpace: 'nowrap' }}>
                              {zarShort(r.capitalTied)}
                            </span>
                          </div>
                        )
                      })}
                    </div>

                    {stalledLines.length > 5 && (
                      <button
                        onClick={() => { setCurrentReport('slowmovers'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport() }}
                        style={{ marginTop: 10, width: '100%', background: 'none', border: 'none', cursor: 'pointer', fontSize: 10, fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.4)', textAlign: 'center', padding: '4px 0', textDecoration: 'underline', textDecorationColor: 'rgba(245,245,244,0.15)', textUnderlineOffset: 3 }}
                      >
                        + {stalledLines.length - 5} more lines · open Slow Movers report for full list
                      </button>
                    )}
                  </>
                )
              })()}
            </div>
          )}

          </div>{/* end reorder flex wrapper */}

          {/* ── FOCUS AREA PANEL ──────────────────────────────────────────────── */}
          {/* Always visible at the bottom whenever dates are loaded.              */}
          {selectedDates.length > 0 && (
            <FocusAreaPanel
              basket={focusBasket}
              onRemove={removeFromFocus}
              onClear={clearFocus}
              selectedDates={selectedDates}
              availableDates={availableDates}
              allStoreCodes={storeCodes}
              isDefault={isDefaultBasket}
              defaultLoading={focusDefaultLoading}
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

      {/* ── CAPITAL TIED DRILL-DOWN MODAL ───────────────────────────────────── */}
      {capTiedModalOpen && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 600, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)' }} onClick={() => setCapTiedModalOpen(false)} />
          <div className="sb-glass" style={{ position: 'relative', zIndex: 1, width: '90%', maxWidth: 480, maxHeight: '80vh', overflow: 'auto', padding: '24px 28px', borderRadius: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
              <div>
                <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 20, fontWeight: 600 }}>Capital Tied</p>
                <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.4)', fontFamily: "'Geist Mono', monospace", marginTop: 2 }}>by department · {zarShort(kpiCapTied)} total</p>
              </div>
              <button onClick={() => setCapTiedModalOpen(false)} style={{ background: 'none', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 6, color: 'rgba(245,245,244,0.5)', cursor: 'pointer', padding: '4px 10px', fontSize: 12 }}>✕</button>
            </div>

            {capTiedByDept.length === 0 ? (
              <p style={{ color: 'rgba(245,245,244,0.4)', fontSize: 12, textAlign: 'center', padding: '20px 0' }}>Load report data to see breakdown</p>
            ) : (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {capTiedByDept.map(([dept, val]) => {
                  const total = capTiedByDept.reduce((s, [, v]) => s + v, 0)
                  const share = total > 0 ? (val / total) * 100 : 0
                  return (
                    <div key={dept}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 4 }}>
                        <span style={{ fontSize: 12, color: '#f5f5f4' }}>{dept}</span>
                        <span style={{ fontFamily: "'Geist Mono', monospace", fontSize: 12, color: '#f59e0b', fontWeight: 600 }}>{zarShort(val)} <span style={{ fontSize: 10, color: 'rgba(245,158,11,0.5)', fontWeight: 400 }}>{share.toFixed(1)}%</span></span>
                      </div>
                      <div style={{ height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.06)' }}>
                        <div style={{ height: '100%', borderRadius: 2, background: 'rgba(245,158,11,0.5)', width: `${share}%`, transition: 'width 0.3s' }} />
                      </div>
                    </div>
                  )
                })}
              </div>
            )}

            <p style={{ marginTop: 16, fontSize: 10, color: 'rgba(245,245,244,0.25)', fontFamily: "'Geist Mono', monospace", fontStyle: 'italic' }}>
              SOH × unit cost · slow-mover lines · ghost stock excluded
              {kpiGhostStock > 0 && (
                <span style={{ color: 'rgba(251,191,36,0.6)', marginLeft: 6 }}>
                  ({zarShort(kpiGhostStock)} production stock removed — fix at source in Sigma)
                </span>
              )}
            </p>
          </div>
        </div>
      )}

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
                style={{ width: '100%', padding: '10px 22px', fontFamily: 'Geist, sans-serif', fontSize: 13, fontWeight: 600, background: reportData.length === 0 ? 'rgba(255,255,255,0.06)' : '#FFD100', color: reportData.length === 0 ? 'rgba(245,245,244,0.25)' : '#121612', border: 'none', borderRadius: 10, cursor: reportData.length === 0 ? 'not-allowed' : 'pointer', transition: 'all 0.2s', boxShadow: reportData.length === 0 ? 'none' : '0 8px 24px rgba(255,209,0,0.25)' }}
              >
                ↓ Download {activeReportDef?.title} as Excel
              </button>
            </div>

            {/* Preview table */}
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', borderTop: '1px solid rgba(255,255,255,0.07)', overflow: 'hidden' }}>
              {currentReport === 'consignment' ? (
                <div style={{ flex: 1, overflow: 'auto' }}>
                  <ConsignmentPanel store={storeCodes[0] ?? '10116'} />
                </div>
              ) : !reportLoaded ? (
                reportLoading ? (
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 32, gap: 12 }}>
                    <div style={{ width: 36, height: 36, border: '3px solid rgba(74,107,83,0.30)', borderTopColor: '#FFD100', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
                    <p style={{ fontFamily: "'Geist Mono', monospace", fontSize: 12, color: 'rgba(245,245,244,0.4)' }}>Fetching report data…</p>
                  </div>
                ) : (
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 32, gap: 16 }}>
                    <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 15, fontStyle: 'italic', color: 'rgba(245,245,244,0.3)', textAlign: 'center' }}>
                      Select a report above to load data
                    </p>
                    <button onClick={loadReport}
                      style={{ padding: '10px 24px', fontFamily: 'Geist, sans-serif', fontSize: 13, fontWeight: 600, background: '#FFD100', color: '#121612', border: 'none', borderRadius: 10, cursor: 'pointer', boxShadow: '0 8px 24px rgba(255,209,0,0.25)' }}>
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
                    {currentReport === 'slowmovers' && engineSlowRows.filter(r => r.ean == null).length > 0 &&
                      ` · ${num(engineSlowRows.filter(r => r.ean == null).length)} lines hidden (no EAN bridge)`}
                  </div>
                  {/* ENG-101: a failed or short read is stated, never rendered as
                      an empty report. A blank here would read as "no slow movers",
                      which is the exact lie the 1,000-row cap was already telling. */}
                  {currentReport === 'slowmovers' && engineSlowError && (
                    <div style={{ padding: '10px 18px', borderTop: '1px solid rgba(239,68,68,0.35)', background: 'rgba(239,68,68,0.10)', fontFamily: "'Geist Mono', monospace", fontSize: 11, color: '#fca5a5', flexShrink: 0 }}>
                      Slow Movers could not be read: {engineSlowError}
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        </div>
      )}

      {/* KPI tooltip portal -- renders to document.body, escapes all stacking contexts */}
      {typeof document !== 'undefined' && tooltipContent && tooltipCard && createPortal(
        <div style={{
          position: 'fixed',
          top: tooltipPos.top,
          left: tooltipPos.left,
          maxWidth: 320,
          width: 'max-content',
          zIndex: 99999,
          background: 'rgba(12,16,12,0.97)',
          border: '1px solid rgba(255,255,255,0.10)',
          borderLeft: `2px solid ${{ green: '#4ade80', blue: '#60a5fa', amber: '#fbbf24', red: '#f87171' }[tooltipContent.edgeColor] ?? 'rgba(168,181,168,0.4)'}`,
          borderRadius: 10,
          padding: '14px 16px',
          boxShadow: '0 12px 40px rgba(0,0,0,0.7)',
          pointerEvents: 'none',
          animation: 'tooltipFadeIn 120ms ease both',
        }}>
          <p style={{ fontSize: 10, fontFamily: 'var(--font-head)', color: '#f5f5f4', fontWeight: 700, letterSpacing: '0.12em', textTransform: 'uppercase', marginBottom: 10 }}>
            {tooltipContent.heading}
          </p>
          {[
            ['WHAT',    tooltipContent.what],
            ['SOURCE',  tooltipContent.source],
            ['COMPARE', tooltipContent.compare],
            ['SIGNAL',  tooltipContent.signal],
            tooltipContent.note ? ['NOTE', tooltipContent.note] : null,
          ].filter(Boolean).map(([label, text]) => (
            <div key={label} style={{ marginBottom: 9 }}>
              <p style={{ fontSize: 9, fontFamily: 'var(--font-head)', color: 'var(--veld-mist)', textTransform: 'uppercase', letterSpacing: '0.1em', marginBottom: 3 }}>{label}</p>
              <p style={{ fontSize: 10.5, fontFamily: 'var(--font-head)', color: 'rgba(245,245,244,0.75)', lineHeight: 1.55, margin: 0 }}>{text}</p>
            </div>
          ))}
        </div>,
        document.body
      )}
    </div>
  )
}
