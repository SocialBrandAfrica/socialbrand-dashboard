// src/app/api/dev-corner/sigma-lines/route.js
// SB-CC-AUDIT-002 — per-line per-day consignment sales.
// SB-CC-PMINI-WIRE-001 (2026-06-17) — RPC-ONLY. This route now reads ONLY two
//   SECURITY DEFINER RPCs (rpc_consignment_lines + rpc_feed_health_daily) and
//   touches NO base table. item_type (sushi 's' / Chinese 'c') comes straight off
//   rpc_consignment_lines, where it is engine-stamped from the Sigma-native scan
//   refs (v_consignment_catalog). The old sigma_articles + sigma_ean_master reads
//   are gone — that is what lets the restricted partner key serve this page.
//
// Why DBUMBA: daily_snapshots (PRSSALE) misses any day where the store EOD/Catman
// export did not run (e.g. 10116 2026-05-29 = R383,388 absent, never recoverable).
// sigma_sales (behind the rpc) is the exact Sigma ledger and is always complete.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE = '10116'

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
  const now         = new Date()
  const year        = rawY && rawY > 2020 && rawY < 2100 ? rawY : now.getUTCFullYear()
  const month       = rawM && rawM >= 1 && rawM <= 12 ? rawM : now.getUTCMonth() + 1
  const mm          = String(month).padStart(2, '0')
  const monthLabel  = `${year}-${mm}`
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getDate()

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    // ── 1. Two RPCs only — consignment lines (with item_type) + feed health ──
    const [linesRes, healthRes] = await Promise.all([
      supabase.rpc('rpc_consignment_lines', { p_month: monthLabel, p_store: STORE }),
      supabase.rpc('rpc_feed_health_daily', { p_store: STORE, p_month: monthLabel }),
    ])

    if (linesRes.error) throw linesRes.error
    if (healthRes.error) throw healthRes.error

    const rows   = linesRes.data ?? []
    const health = healthRes.data ?? []

    // ── 2. Classification map straight off the rpc (engine-stamped, no base tables) ──
    const descToType = {}
    for (const r of rows) {
      if (r.item_type && descToType[r.description] == null) descToType[r.description] = r.item_type
    }

    // ── 3. as_at: DISPLAY only — last confirmed non-FUTURE day, or last sushi-sales day.
    // Do NOT use asAt to bound the dates array — health coverage can lag the calendar.
    const tradingDays  = health.filter(h => h.status !== 'FUTURE')
    const salesDateMax = rows.length
      ? [...new Set(rows.map(r => r.sale_date).filter(Boolean))].sort().pop()
      : null
    const asAt = tradingDays.length
      ? tradingDays[tradingDays.length - 1].sale_date
      : salesDateMax

    // ── 4. Date range for charts: ALL elapsed calendar days, month start to today
    // (or last day of month for a past month). Zero-fill keeps every bar present.
    const todayISO     = new Date().toISOString().slice(0, 10)
    const monthLastISO = `${year}-${mm}-${String(daysInMonth).padStart(2, '0')}`
    const dateCeiling  = todayISO <= monthLastISO ? todayISO : monthLastISO

    const dates = []
    if (dateCeiling >= `${year}-${mm}-01`) {
      const dStart = new Date(`${year}-${mm}-01T12:00:00Z`)
      const dEnd   = new Date(dateCeiling + 'T12:00:00Z')
      for (let d = new Date(dStart); d <= dEnd; d = new Date(d.getTime() + 86400000)) {
        dates.push(d.toISOString().slice(0, 10))
      }
    }

    // ── 5. Pivot rpc rows by description (sold rows only; default rpc call omits catalog) ──
    const byDesc = {}
    for (const r of rows) {
      if (!r.sale_date) continue   // skip any catalog/no-sale marker rows defensively
      if (!byDesc[r.description]) {
        byDesc[r.description] = {
          n:      r.description,
          t:      r.item_type ?? descToType[r.description] ?? 'c',
          byDate: {},
        }
      }
      byDesc[r.description].byDate[r.sale_date] = {
        s: Math.round(Number(r.sales) * 100) / 100,
        q: Math.round(Number(r.qty)   * 10)  / 10,
      }
    }

    // dates.map fills 0 for any day the line had no sale — correct for all-day charts
    const lines = Object.values(byDesc).map(l => ({
      n: l.n,
      t: l.t,
      s: dates.map(d => l.byDate[d]?.s ?? 0),
      q: dates.map(d => l.byDate[d]?.q ?? 0),
    }))

    return NextResponse.json({
      month:         monthLabel,
      loaded_days:   dates.length,
      days_in_month: daysInMonth,
      as_at:         asAt,
      source:        'sigma_sales',   // DBUMBA — exact Sigma ledger, via rpc
      dates,                          // actual ISO date strings (use for labels, not i+1)
      health,                         // per-day feed health for completeness strip
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
