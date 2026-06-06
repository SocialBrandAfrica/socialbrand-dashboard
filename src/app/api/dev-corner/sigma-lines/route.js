// src/app/api/dev-corner/sigma-lines/route.js
// SB-CC-PMINI-002 — per-line per-day consignment sales from daily_snapshots.
// Source: daily_snapshots (same table as the consignment totals endpoint).
// Updates automatically with every nightly push — always current.
// Returns lines[] with per-day arrays in the format the PM design expects.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE   = '10116'
const SUBDEPT = 'HMR SUSHI'

// EANs silently excluded — misfiled lines and generic dept keys
const EXCLUDED = new Set([
  '1011600209210',  // BREAKFAST — recoded to GRAB & GO 2026-06-05
  '1011600200923',  // MABELA PORRIDGE — recoded to HMR HOT MEALS
  '2106100000006',  // HMR SUSHI 14% open dept key
  '2206100000003',  // HMR SUSHI 0% open dept key
])

// PLU codes from the 64-line sushi menu — used to split sushi vs Chinese/other.
// EAN format: 10116 (5) + 002 (3) + PLU zero-padded (5) = 13 digits.
// PLU = parseInt(ean.slice(5)) - 200000.
const SUSHI_PLUS = new Set([
  653,650,895,888,863,851,846,844,843,841,835,533,831,824,818,810,792,790,
  785,778,773,767,766,749,747,832,762,737,722,744,718,715,9677,710,700,736,
  632,638,597,307,308,309,889,924,930,599,699,694,693,696,695,697,698,840,
  836,897,834,809,806,803,784,771,748,753,
])

function classifyEan(ean) {
  const plu = parseInt(String(ean).slice(5)) - 200000
  return SUSHI_PLUS.has(plu) ? 's' : 'c'
}

function lastDayOfMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).toISOString().slice(0, 10)
}

export async function GET(request) {
  const origin = request.headers.get('origin') ?? ''
  const allowed = !origin ||
    origin.includes('localhost') ||
    origin.includes('vercel.app') ||
    origin.includes('socialbrand') ||
    origin.includes('stockflow') ||
    origin.includes('replit')
  if (!allowed) return new NextResponse('Forbidden', { status: 403 })

  const { searchParams } = new URL(request.url)
  const rawMonth = searchParams.get('month') ?? ''
  const [rawY, rawM] = rawMonth.split('-').map(Number)
  const now        = new Date()
  const year       = rawY && rawY > 2020 && rawY < 2100 ? rawY : now.getUTCFullYear()
  const month      = rawM && rawM >= 1 && rawM <= 12 ? rawM : now.getUTCMonth() + 1
  const mm         = String(month).padStart(2, '0')
  const monthStart = `${year}-${mm}-01`
  const monthEnd   = lastDayOfMonth(year, month)
  const monthLabel = `${year}-${mm}`
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getDate()

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    // One row per (ean, snapshot_date) — already the natural grain of daily_snapshots
    const { data: rows, error } = await supabase
      .from('daily_snapshots')
      .select('description, ean, snapshot_date, today_sales, today_qty')
      .eq('store_code', STORE)
      .eq('sub_dept_name', SUBDEPT)
      .gte('snapshot_date', monthStart)
      .lte('snapshot_date', monthEnd)

    if (error) throw error

    // Strip excluded EANs
    const goodRows = (rows ?? []).filter(r => !EXCLUDED.has(String(r.ean)))

    // Determine which dates have data (sorted)
    const dateSet    = new Set(goodRows.map(r => r.snapshot_date))
    const dates      = [...dateSet].sort()
    const loadedDays = dates.length

    // Pivot: group by EAN → per-date arrays
    const byEan = {}
    for (const r of goodRows) {
      const key = r.ean
      if (!byEan[key]) {
        byEan[key] = {
          n:      r.description,
          t:      classifyEan(r.ean),
          byDate: {},
        }
      }
      byEan[key].byDate[r.snapshot_date] = {
        s: Math.round(Math.max(0, r.today_sales ?? 0) * 100) / 100,
        q: Math.round(Math.max(0, r.today_qty   ?? 0) * 10)  / 10,
      }
    }

    // Build output lines — same shape as PM reference L[] array
    const lines = Object.values(byEan).map(l => {
      const s = dates.map(d => l.byDate[d]?.s ?? 0)
      const q = dates.map(d => l.byDate[d]?.q ?? 0)
      return { n: l.n, t: l.t, s, q }
    })

    return NextResponse.json({
      month,
      loaded_days:   loadedDays,
      days_in_month: daysInMonth,
      as_at:         dates.length ? dates[dates.length - 1] : null,
      lines,
    })

  } catch (err) {
    console.error('[sigma-lines]', err?.message ?? err)
    return new NextResponse(JSON.stringify({ error: 'unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
}
