// src/app/api/dev-corner/sigma-lines/route.js
// SB-CC-AUDIT-002 — per-line per-day consignment sales.
// Source switched to sigma_sales (DBUMBA) via rpc_consignment_lines.
// Adds rpc_feed_health_daily output so the mini app can show the completeness strip.
//
// Why DBUMBA: daily_snapshots (PRSSALE) misses any day where the store EOD/Catman
// export did not run (e.g. 10116 2026-05-29 = R383,388 absent, never recoverable).
// sigma_sales is the exact Sigma ledger and is always complete.
//
// Classification (sushi vs chinese) derives from sigma_articles.product_code
// → sigma_ean_master.barcode → PLU = barcode-200000 → SUSHI_PLUS set.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE  = '10116'
const CLIENT = 'socialbrand'
const GROUP  = 610   // merch_group_nr — HMR SUSHI counter

// PLU codes from the 64-line sushi menu — split sushi vs Chinese/other.
// PLU = sigma_ean_master.barcode - 200000.
const SUSHI_PLUS = new Set([
  653,650,895,888,863,851,846,844,843,841,835,533,831,824,818,810,792,790,
  785,778,773,767,766,749,747,832,762,737,722,744,718,715,9677,710,700,736,
  632,638,597,307,308,309,889,924,930,599,699,694,693,696,695,697,698,840,
  836,897,834,809,806,803,784,771,748,753,
])

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
    // ── 1. Parallel: consignment lines + feed health + article classification ──
    const [linesRes, healthRes, artRes] = await Promise.all([
      supabase.rpc('rpc_consignment_lines', { p_month: monthLabel, p_store: STORE }),
      supabase.rpc('rpc_feed_health_daily', { p_store: STORE, p_month: monthLabel }),
      supabase
        .from('sigma_articles')
        .select('description, product_code')
        .eq('store_code', STORE)
        .eq('client_id', CLIENT)
        .eq('merch_group_nr', GROUP),
    ])

    if (linesRes.error) throw linesRes.error
    if (healthRes.error) throw healthRes.error

    // ── 2. Build description→type map via sigma_ean_master ───────────────────
    const productCodes = (artRes.data ?? []).map(r => r.product_code)
    const descToType   = {}

    if (productCodes.length) {
      const { data: eanRows } = await supabase
        .from('sigma_ean_master')
        .select('product_code, barcode')
        .eq('store_code', STORE)
        .eq('client_id', CLIENT)
        .in('product_code', productCodes)

      const eanByPCode = {}
      for (const e of (eanRows ?? [])) eanByPCode[e.product_code] = e.barcode

      for (const a of (artRes.data ?? [])) {
        const barcode = eanByPCode[a.product_code]
        if (barcode != null) {
          descToType[a.description] = SUSHI_PLUS.has(barcode - 200000) ? 's' : 'c'
        }
      }
    }

    // ── 3. Pivot rpc_consignment_lines rows by description ───────────────────
    const rows   = linesRes.data ?? []
    const health = healthRes.data ?? []

    // as_at: latest non-FUTURE date from feed health; fall back to latest sales date.
    // Computed first so we can generate the full calendar range below.
    const tradingDays  = health.filter(h => h.status !== 'FUTURE')
    const salesDateMax = rows.length
      ? [...new Set(rows.map(r => r.sale_date))].sort().pop()
      : null
    const asAt = tradingDays.length
      ? tradingDays[tradingDays.length - 1].sale_date
      : salesDateMax

    // Generate every calendar day from month start to as_at so all elapsed days
    // appear in the charts — including days with zero sushi sales (shown as flat bars).
    const dates = []
    if (asAt) {
      const start = new Date(`${year}-${mm}-01T12:00:00Z`)
      const end   = new Date(asAt + 'T12:00:00Z')
      for (let d = new Date(start); d <= end; d = new Date(d.getTime() + 86400000)) {
        dates.push(d.toISOString().slice(0, 10))
      }
    }

    const byDesc = {}
    for (const r of rows) {
      if (!byDesc[r.description]) {
        byDesc[r.description] = {
          n:      r.description,
          t:      descToType[r.description] ?? 'c',
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
      source:        'sigma_sales',   // DBUMBA — exact Sigma ledger
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
