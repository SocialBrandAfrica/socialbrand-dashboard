// src/app/api/dev-corner/consignment/route.js
// SB-CC-PMINI-001 -- HMR SUSHI consignment panel data endpoint.
//
// Security contract (matches brief section 6a):
//   - SELECT-only: anon key has no write rights.
//   - No schema leak: response uses curated field names only.
//   - CORS: same-origin (no Access-Control-Allow-Origin: *).
//   - Keys never in response, page, or URL.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE     = '10116'
const SUBDEPT   = 'HMR SUSHI'
const CLIENT_ID = 'socialbrand'

// Items excluded from consignment business figures -- silently dropped, not shown.
// BREAKFAST / MABELA: misfiled, recoded in Sigma 2026-06-05.
// Generic dept-key EANs: HMR SUSHI 14% and 0% open keys -- unattributed sales
// that cannot be itemised and are not paid to the supplier.
const EXCLUDED_EANS = new Set([
  '1011600209210',   // BREAKFAST -- recoded to HMR GRAB & GO
  '1011600200923',   // MABELA PORRIDGE -- recoded to HMR HOT MEALS
  '2106100000006',   // HMR SUSHI 14% generic dept key
  '2206100000003',   // HMR SUSHI 0% generic dept key
])
function isExcluded(row) {
  if (EXCLUDED_EANS.has(String(row.ean))) return true
  const d = (row.description ?? '').toUpperCase()
  return d.startsWith('MABELA')
}

function lastDayOfMonth(year, month) {
  // month is 1-based
  return new Date(Date.UTC(year, month, 0)).toISOString().slice(0, 10)
}

export async function GET(request) {
  const origin = request.headers.get('origin') ?? ''
  const allowed = !origin ||
    origin.includes('localhost') ||
    origin.includes('vercel.app') ||
    origin.includes('socialbrand') ||
    origin.includes('stockflow')
  if (!allowed) return new NextResponse('Forbidden', { status: 403 })

  const { searchParams } = new URL(request.url)

  // Commission rate: clamp to [0, 1], default 0.10
  const rate = Math.max(0, Math.min(1, parseFloat(searchParams.get('rate') ?? '0.1')))

  // Month: YYYY-MM, default current month
  const rawMonth = searchParams.get('month') ?? ''
  const [rawY, rawM] = rawMonth.split('-').map(Number)
  const now   = new Date()
  const year  = rawY && rawY > 2020 && rawY < 2100 ? rawY : now.getUTCFullYear()
  const month = rawM && rawM >= 1 && rawM <= 12 ? rawM : now.getUTCMonth() + 1
  const mm    = String(month).padStart(2, '0')
  const monthStart = `${year}-${mm}-01`
  const monthEnd   = lastDayOfMonth(year, month)
  const monthLabel = `${year}-${mm}`

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    const { data: rows, error } = await supabase
      .from('daily_snapshots')
      .select('ean, description, snapshot_date, today_sales, today_qty, sell_price')
      .eq('store_code', STORE)
      .eq('sub_dept_name', SUBDEPT)
      .gte('snapshot_date', monthStart)
      .lte('snapshot_date', monthEnd)

    if (error) throw error

    const allRows = rows ?? []

    // Silently drop all excluded items -- misfiled lines + generic dept keys.
    const goodRows = allRows.filter(r => !isExcluded(r))
    const wrongItems = [] // reserved for future misfiled items; currently none

    // Aggregate by EAN for business lines
    const byEan = {}
    for (const r of goodRows) {
      const k = r.ean
      if (!byEan[k]) byEan[k] = { ean: r.ean, desc: r.description, sales: 0, qty: 0, sell: r.sell_price }
      byEan[k].sales += Math.max(0, r.today_sales ?? 0)
      byEan[k].qty   += Math.max(0, r.today_qty   ?? 0)
    }
    const lines = Object.values(byEan)

    // Sigma price check — detect any price changed in Sigma since last push.
    // Join path (R20): ean → SUBSTRING(ean,6)::bigint = sigma_ean_master.barcode
    //                        → product_code = sigma_articles.product_code
    const barcodes = [...new Set(lines.map(l => parseInt(String(l.ean).slice(5))))]
      .filter(b => b > 0 && isFinite(b))

    const { data: eanRows } = await supabase
      .from('sigma_ean_master')
      .select('barcode, product_code')
      .eq('store_code', STORE)
      .eq('client_id', CLIENT_ID)
      .in('barcode', barcodes)

    const barcodeToPCode = {}
    for (const r of (eanRows ?? [])) barcodeToPCode[r.barcode] = r.product_code
    const productCodes = Object.values(barcodeToPCode)

    let sigmaByPCode = {}
    if (productCodes.length) {
      const { data: sigmaRows } = await supabase
        .from('sigma_articles')
        .select('product_code, sell_price_incl_vat')
        .eq('store_code', STORE)
        .eq('client_id', CLIENT_ID)
        .in('product_code', productCodes)
      for (const r of (sigmaRows ?? [])) sigmaByPCode[r.product_code] = parseFloat(r.sell_price_incl_vat)
    }

    const priceFlags = []
    for (const l of lines) {
      const barcode = parseInt(String(l.ean).slice(5))
      const pcode   = barcodeToPCode[barcode]
      if (!pcode) continue
      const sigmaPrice = sigmaByPCode[pcode]
      if (sigmaPrice == null) continue
      const dbPrice = parseFloat(l.sell ?? 0)
      const diff    = Math.round((sigmaPrice - dbPrice) * 100) / 100
      if (Math.abs(diff) > 0.01) {
        priceFlags.push({
          ean:         l.ean,
          desc:        l.desc,
          db_price:    Math.round(dbPrice    * 100) / 100,
          sigma_price: Math.round(sigmaPrice * 100) / 100,
          diff,
        })
      }
    }

    // Business totals
    const businessSales = lines.reduce((s, l) => s + l.sales, 0)
    const commission    = Math.round(businessSales * rate       * 100) / 100
    const owed          = Math.round(businessSales * (1 - rate) * 100) / 100

    // Top 5 sellers (by sales value)
    const top5 = lines
      .filter(l => l.sales > 0)
      .sort((a, b) => b.sales - a.sales)
      .slice(0, 5)
      .map(l => ({ desc: l.desc, ean: l.ean, sales: Math.round(l.sales * 100) / 100, qty: l.qty }))

    // No-sales lines (present in sub-dept but zero sales this month)
    const noSales = lines
      .filter(l => l.sales === 0)
      .map(l => ({ desc: l.desc, ean: l.ean, sell: l.sell }))

    // Daily cashflow (sum today_sales across all business lines per date)
    const dailyMap = {}
    for (const r of goodRows) {
      const d = r.snapshot_date
      if (!dailyMap[d]) dailyMap[d] = 0
      dailyMap[d] += Math.max(0, r.today_sales ?? 0)
    }
    let cumulative = 0
    const daily = Object.keys(dailyMap).sort().map(d => {
      cumulative += dailyMap[d]
      return {
        date:       d,
        sales:      Math.round(dailyMap[d] * 100) / 100,
        cumulative: Math.round(cumulative  * 100) / 100,
      }
    })

    return NextResponse.json({
      month:          monthLabel,
      rate,
      business_sales: Math.round(businessSales * 100) / 100,
      commission,
      owed,
      float:          Math.round(businessSales * 100) / 100,
      daily,
      top5,
      no_sales:       noSales,
      wrong_items:    wrongItems,
      price_flags:    priceFlags,
    })

  } catch (err) {
    console.error('[dev-corner/consignment]', err?.message ?? err)
    return new NextResponse(JSON.stringify({ error: 'unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
}
