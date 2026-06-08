// src/app/api/dev-corner/consignment/route.js
// SB-CC-AUDIT-002 — consignment flags endpoint (no-sales + price mismatches).
//
// Business figures (business_sales, commission, owed) are no longer computed here.
// The mini app gets those from sigma-lines (DBUMBA). This endpoint is flags-only.
//
// no_sales: articles in sigma_articles (merch_group_nr=610) that do NOT appear in
//   rpc_consignment_lines for the month → zero sales from exact Sigma ledger.
//   (Old approach read daily_snapshots which could miss EOD-missing days.)
//
// price_flags: still reads sell_price from daily_snapshots as the "DB price" to
//   compare against sigma_articles — this catches Sigma price changes not yet
//   reflected in our pipeline. daily_snapshots is acceptable here because this
//   is a price-consistency check, not a sales figure.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE  = '10116'
const CLIENT = 'socialbrand'
const GROUP  = 610

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
    // ── 1. Parallel: sigma_articles catalog + rpc_consignment_lines sales ────
    const [artRes, linesRes] = await Promise.all([
      supabase
        .from('sigma_articles')
        .select('description, product_code, sell_price_incl_vat')
        .eq('store_code', STORE)
        .eq('client_id', CLIENT)
        .eq('merch_group_nr', GROUP),
      supabase.rpc('rpc_consignment_lines', { p_month: monthLabel, p_store: STORE }),
    ])

    const articles = artRes.data ?? []
    const lines    = linesRes.data ?? []

    // ── 2. no_sales: articles not appearing in any sales row this month ──────
    const descsSold = new Set(lines.map(r => r.description))
    const noSales   = articles
      .filter(a => !descsSold.has(a.description))
      .map(a => ({ desc: a.description }))

    // ── 3. price_flags: sigma_articles price vs daily_snapshots sell_price ───
    // daily_snapshots is acceptable here — this is a price-pipeline consistency
    // check, not the sales figure. Mismatches flag Sigma price changes not yet
    // pushed through to our snapshot table.
    const productCodes = articles.map(a => a.product_code)
    const sigmaByPCode = {}
    for (const a of articles) sigmaByPCode[a.product_code] = parseFloat(a.sell_price_incl_vat)

    // Get EANs for the product codes so we can look up daily_snapshots (which uses EAN)
    const { data: eanRows } = await supabase
      .from('sigma_ean_master')
      .select('product_code, barcode')
      .eq('store_code', STORE)
      .eq('client_id', CLIENT)
      .in('product_code', productCodes)

    const eanByPCode = {}
    for (const e of (eanRows ?? [])) eanByPCode[e.product_code] = e.barcode

    // Build synthetic EANs (same format as daily_snapshots)
    // Synthetic EAN = store_code (5) + '002' (3) + barcode zero-padded (5)
    const syntheticEans = []
    const eanToPCode    = {}
    for (const a of articles) {
      const barcode = eanByPCode[a.product_code]
      if (barcode != null) {
        const synEan = STORE + '002' + String(barcode).padStart(5, '0')
        syntheticEans.push(synEan)
        eanToPCode[synEan] = a.product_code
      }
    }

    const priceFlags = []
    if (syntheticEans.length) {
      const monthEnd = lastDayOfMonth(year, month)
      // Get most recent sell_price from daily_snapshots for these EANs
      const { data: snapRows } = await supabase
        .from('daily_snapshots')
        .select('ean, description, sell_price')
        .eq('store_code', STORE)
        .in('ean', syntheticEans)
        .lte('snapshot_date', monthEnd)
        .order('snapshot_date', { ascending: false })
        .limit(syntheticEans.length)   // one row per EAN (latest)

      const seenEan = new Set()
      for (const row of (snapRows ?? [])) {
        if (seenEan.has(row.ean)) continue
        seenEan.add(row.ean)
        const pcode      = eanToPCode[row.ean]
        const sigmaPrice = pcode != null ? sigmaByPCode[pcode] : null
        if (sigmaPrice == null) continue
        const dbPrice = parseFloat(row.sell_price ?? 0)
        const diff    = Math.round((sigmaPrice - dbPrice) * 100) / 100
        if (Math.abs(diff) > 0.01) {
          priceFlags.push({
            ean:         row.ean,
            desc:        row.description,
            db_price:    Math.round(dbPrice    * 100) / 100,
            sigma_price: Math.round(sigmaPrice * 100) / 100,
            diff,
          })
        }
      }
    }

    return NextResponse.json({ no_sales: noSales, price_flags: priceFlags })

  } catch (err) {
    console.error('[dev-corner/consignment]', err?.message ?? err)
    return new NextResponse(JSON.stringify({ error: 'unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
}
