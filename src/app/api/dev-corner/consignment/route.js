// src/app/api/dev-corner/consignment/route.js
// SB-CC-AUDIT-002 — consignment flags endpoint (no-sales lines).
// SB-CC-PMINI-WIRE-001 (2026-06-17) — RPC-ONLY. Reads ONLY rpc_consignment_lines
//   (with p_include_catalog=true) and touches NO base table — that is what lets the
//   restricted partner key serve this page.
//
//   no_sales: in-scope group-610 articles that did NOT sell this month. The rpc, in
//     catalog mode, emits those as zero rows (sale_date NULL) alongside the sold
//     rows, so we derive the list without reading sigma_articles.
//
//   price_flags: REMOVED from the partner build (brief §3b). It compared
//     sigma_articles.sell_price_incl_vat against daily_snapshots.sell_price — an
//     internal pipeline price-lag check, not consignment business data, and it
//     required base-table SELECT the partner key must not have. Returned as an
//     empty array for response-shape compatibility with the existing HTML.

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
  const now   = new Date()
  const year  = rawY && rawY > 2020 && rawY < 2100 ? rawY : now.getUTCFullYear()
  const month = rawM && rawM >= 1 && rawM <= 12 ? rawM : now.getUTCMonth() + 1
  const mm    = String(month).padStart(2, '0')
  const monthLabel = `${year}-${mm}`

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    // Single rpc, catalog mode — sold rows + zero rows for no-sale articles.
    const { data, error } = await supabase.rpc('rpc_consignment_lines', {
      p_month: monthLabel, p_store: STORE, p_include_catalog: true,
    })
    if (error) throw error

    const rows = data ?? []

    // A description "sold" if it has any row with a real sale_date.
    const soldDescs = new Set(rows.filter(r => r.sale_date).map(r => r.description))
    const noSales = []
    const seen = new Set()
    for (const r of rows) {
      if (r.sale_date) continue          // sold row, skip
      if (soldDescs.has(r.description)) continue
      if (seen.has(r.description)) continue
      seen.add(r.description)
      noSales.push({ desc: r.description, t: r.item_type ?? 'c' })
    }

    return NextResponse.json({ no_sales: noSales, price_flags: [] })

  } catch (err) {
    console.error('[dev-corner/consignment]', err?.message ?? err)
    return new NextResponse(JSON.stringify({ error: 'unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
}
