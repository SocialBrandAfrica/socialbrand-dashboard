// src/app/api/forge/weekly-report/route.js
// SB-CC-TOOLKIT-002 item 7: the weekly Chairman / VP report, downloadable from
// the toolkit live page (Pieter, 2026-08-13). Generated from the SAME platform
// facts as the dashboard, never hand-built -- Pieter writes his own words on top.
//
// Two halves (brief §4.7): COMPLIANCE (his branch downward -- counts issued vs
// counted) and PROGRESS (the unit -- capital purified with its date, below-zero
// lines trend, count coverage, key lines out of stock). Where a fact is not yet
// captured (waste/write-off, adjustments authorised vs processed, exceptions,
// breaches, sales vs LY, GP%), it is NAMED as a pending gap, never shown as a
// zero (R22 / no-false-statement -- the same discipline as the count measure).
//
// Sources: v_forge_count_compliance (compliance) + rpc_forge_integrity_trend
// (progress, now vs a week ago, each with its own as-of date). Auth: same
// same-origin session pattern as ../run; getUser() is belt behind middleware.

import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'
import * as XLSX from 'xlsx'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

function client() {
  const cookieStore = cookies()
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { cookies: { getAll() { return cookieStore.getAll() }, setAll() {} } }
  )
}

const STORE_NAMES = {
  '10116': 'SPAR Delareyville', '21355': 'TOPS Delareyville',
  '80175': 'SPAR Roosville', '80176': 'TOPS Roosville', '80579': 'TOPS Dice',
}
const iso = d => d.toISOString().slice(0, 10)
const R = n => n == null ? '' : Math.round(Number(n))

export async function GET() {
  const sb = client()
  const { data: { user } } = await sb.auth.getUser()
  if (!user) return NextResponse.json({ error: 'not authenticated' }, { status: 401 })

  const { data: stores } = await sb.from('stores').select('store_code').eq('is_active', true).order('store_code')
  const codes = (stores || []).map(s => s.store_code)

  const today = new Date()
  const weekAgo = new Date(today); weekAgo.setDate(today.getDate() - 6)

  const { data: comp } = await sb
    .from('v_forge_count_compliance')
    .select('store_code, issued_date, lines_issued, lines_posted')
    .gte('issued_date', iso(weekAgo))
  const { data: trend, error: tErr } = await sb.rpc('rpc_forge_integrity_trend', { p_stores: codes })
  if (tErr) return NextResponse.json({ error: tErr.message }, { status: 500 })

  // ---- Compliance half: per store over the last 7 days ----
  const cByStore = {}
  for (const r of (comp || [])) {
    const s = (cByStore[r.store_code] = cByStore[r.store_code] || { days: {}, })
    const d = (s.days[r.issued_date] = s.days[r.issued_date] || { issued: 0, posted: 0 })
    d.issued += Number(r.lines_issued); d.posted += Number(r.lines_posted)
  }
  const compRows = codes.map(code => {
    const s = cByStore[code] || { days: {} }
    const dates = Object.keys(s.days)
    const pcts = dates.map(d => s.days[d].issued ? 100 * s.days[d].posted / s.days[d].issued : 0)
    const avg = pcts.length ? pcts.reduce((a, b) => a + b, 0) / pcts.length : null
    return {
      store: `${STORE_NAMES[code] || code} ${code}`,
      lists_issued_7d: dates.length,
      days_with_a_count: pcts.filter(p => p > 0).length,
      avg_pct_counted: avg == null ? 'no lists issued' : Math.round(avg),
      best_day_pct: pcts.length ? Math.round(Math.max(...pcts)) : '',
      worst_day_pct: pcts.length ? Math.round(Math.min(...pcts)) : '',
    }
  })

  // ---- Progress half: per store from the integrity trend ----
  const pick = (code, inst) => (trend || []).find(t => t.store_code === code && t.instrument === inst) || {}
  const delta = (n, w) => (n == null || w == null) ? '' : Math.round(Number(n) - Number(w))
  const progRows = codes.map(code => {
    const cap = pick(code, 'purified_capital_share')
    const neg = pick(code, 'negative_book')
    const cov = pick(code, 'count_coverage_91d')
    const kvi = pick(code, 'kvi_lines_oos')
    return {
      store: `${STORE_NAMES[code] || code} ${code}`,
      trusted_capital_R: R(cap.now_value),
      capital_as_of: cap.now_date || '',
      capital_wk_delta_R: delta(cap.now_value, cap.week_value),
      below_zero_lines: R(neg.now_value),
      below_zero_wk_delta: delta(neg.now_value, neg.week_value),
      counted_91d_pct: cov.now_pool ? Math.round(100 * Number(cov.now_value) / Number(cov.now_pool)) : '',
      key_lines_OOS: R(kvi.now_value),
      key_lines_OOS_wk_delta: delta(kvi.now_value, kvi.week_value),
    }
  })

  const gaps = [
    ['Waste / write-off discipline (value by store and reason)', 'Not captured yet', 'Forge waste/write-off capture (item 6 terminology + a capture screen)'],
    ['Adjustments authorised vs processed', 'Not captured yet', 'Forge adjustment-pack capture'],
    ['Exceptions granted and still open; breaches found', 'Not captured yet', 'Forge exceptions register'],
    ['Sales vs LY per store; GP% vs target', 'On the Pulse dashboard', 'Wire mv_kpi_by_date into this report next'],
    ['Availability on ordering influencers (tier-1 OOS)', 'Shown as Key lines OOS on the Progress sheet', 'Refine to the tier-1 set specifically'],
  ]

  const wb = XLSX.utils.book_new()
  const wsC = XLSX.utils.json_to_sheet(compRows)
  wsC['!cols'] = [{ wch: 26 }, { wch: 15 }, { wch: 17 }, { wch: 16 }, { wch: 13 }, { wch: 14 }]
  XLSX.utils.book_append_sheet(wb, wsC, 'Compliance (7 days)')
  const wsP = XLSX.utils.json_to_sheet(progRows)
  wsP['!cols'] = [{ wch: 26 }, { wch: 17 }, { wch: 13 }, { wch: 18 }, { wch: 16 }, { wch: 18 }, { wch: 15 }, { wch: 14 }, { wch: 20 }]
  XLSX.utils.book_append_sheet(wb, wsP, 'Unit progress')
  const wsG = XLSX.utils.aoa_to_sheet([['Measure', 'Status', 'Where it comes from'], ...gaps])
  wsG['!cols'] = [{ wch: 52 }, { wch: 24 }, { wch: 48 }]
  XLSX.utils.book_append_sheet(wb, wsG, 'Not yet captured')

  const buf = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' })
  return new NextResponse(buf, {
    status: 200,
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="SB-WEEKLY-REPORT_${iso(today)}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
