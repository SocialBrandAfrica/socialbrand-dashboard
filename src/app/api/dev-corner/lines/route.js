// src/app/api/dev-corner/lines/route.js
// SB-AP-007 — Pulse Mini data endpoint.
//
// Security contract (brief §6a):
//   - Fixed output: returns exactly the 11 lines below. No query parameter
//     can change what is returned. EAN list is locked server-side.
//   - No schema leak: response uses curated field names only — no table or
//     column names, no internal IDs beyond the product code.
//   - CORS: same-origin (no Access-Control-Allow-Origin: *).
//   - Keys never in response, page, or URL. Uses NEXT_PUBLIC env vars only
//     because those keys are already published for client-side use.
//
// R30 repair (2026-07-06): this route used to read daily_snapshots and
// push_log directly. daily_snapshots is frozen at 2026-06-28 (RETIRE-002/003)
// and neither table has an anon SELECT policy, so every figure here was
// stale by construction. Now reads only published interfaces: rpc_push_status
// (freshness), rpc_pmini_snapshot (current SOH/price), rpc_pmini_sales_history
// (the 42-day + last-year windows) — all sigma-native, always current.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE = '10116'

// EANs locked server-side. Identified by description matching against
// daily_snapshots for store 10116 (bridge gap: dArtNr is not used).
// Each entry: real GS1 barcode (or synthetic where no barcode exists)
// verified against daily_snapshots sell_price and SOH.
const LINES_META = [
  { code: '13034',  ean: '6001008750052', desc: 'SPAR CARRIER BAG VT1'   },
  { code: '99420',  ean: '6001008753800', desc: 'SPAR BAG 50LT'           },
  { code: '106961', ean: '6001008779497', desc: 'SPAR C/BAG VT2 8CAL'     },
  { code: '93613',  ean: '6001008750069', desc: 'SPAR CARRIER BAG VT.2'   },
  { code: '1674',   ean: '6001008155543', desc: 'SPAR MILK L/L F/CREAM'   },
  { code: '1322',   ean: '5449000000439', desc: 'COCA COLA PET'            }, // 2L, sell 21.99
  { code: '137585', ean: '6009522310363', desc: 'KOO BAKED BEANS TOM SCE'  },
  { code: '44069',  ean: '6009629181064', desc: 'B/RIBBON CLASSIC WHT SLC' },
  { code: '118064', ean: '6009692190055', desc: 'SUNBAKE BREAD WHITE SLC'  },
  { code: '54983',  ean: '1011600240103', desc: 'SPAR WHITE BREAD 600G'    }, // synthetic PLU
  { code: '5847',   ean: '60069795',      desc: 'LION MATCHES (10 X 200)'  }, // EAN-8
]

const FIXED_EANS   = LINES_META.map(m => m.ean)
const META_BY_EAN  = Object.fromEntries(LINES_META.map(m => [m.ean, m]))

function isoDate(d) {
  if (!d) return null
  const dt = new Date(d)
  return isNaN(dt.getTime()) ? null : dt.toISOString().slice(0, 10)
}

function subtractDays(isoStr, n) {
  const d = new Date(isoStr + 'T12:00:00Z')
  d.setUTCDate(d.getUTCDate() - n)
  return d.toISOString().slice(0, 10)
}

export async function GET(request) {
  // ---- CORS: reject cross-origin requests from unknown origins ------------
  const origin = request.headers.get('origin') ?? ''
  const allowed = !origin ||
    origin.includes('localhost') ||
    origin.includes('vercel.app') ||
    origin.includes('socialbrand') ||
    origin.includes('stockflow')
  if (!allowed) {
    return new NextResponse('Forbidden', { status: 403 })
  }

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    // ---- 1. Latest push timestamp (asAt) + true latest trading date -------
    // rpc_push_status: snapshot_date = MAX(sigma_sales.sale_date) per store
    // (true data freshness, sigma-native); completed_at = latest SUCCESS push.
    const { data: pushRows, error: pushErr } = await supabase.rpc('rpc_push_status')
    if (pushErr) throw pushErr
    const pushRow = (pushRows ?? []).find(r => r.store_code === STORE)

    const latestDate = pushRow?.snapshot_date ?? isoDate(new Date())
    const asAt = pushRow?.completed_at
      ? new Date(pushRow.completed_at).toLocaleString('en-ZA', {
          timeZone: 'Africa/Johannesburg',
          day: 'numeric', month: 'short', year: 'numeric',
          hour: '2-digit', minute: '2-digit',
        })
      : 'Unknown'

    // ---- 2. Current snapshot per EAN (SOH, price, last_sale) --------------
    const { data: snapRows, error: snapErr } = await supabase
      .rpc('rpc_pmini_snapshot', { p_store_code: STORE, p_eans: FIXED_EANS })

    if (snapErr) throw snapErr
    const snapByEan = Object.fromEntries((snapRows ?? []).map(r => [r.ean, r]))

    // ---- 3. Daily history for 6 weekly buckets (last 42 days) -------------
    const histFrom = subtractDays(latestDate, 42)
    const { data: histRows, error: histErr } = await supabase
      .rpc('rpc_pmini_sales_history', { p_store_code: STORE, p_eans: FIXED_EANS, p_from: histFrom, p_to: latestDate })

    if (histErr) throw histErr
    const histByEan = {}
    for (const r of histRows ?? []) {
      if (!histByEan[r.ean]) histByEan[r.ean] = []
      histByEan[r.ean].push(r)
    }

    // ---- 4. Last-year history for syf (seasonal factor) -------------------
    // syf = same 4-week window last year / preceding 4-week window last year.
    // Window: [latestDate-364-28, latestDate-364].  Prev: 28 days before that.
    const lyWindowEnd   = subtractDays(latestDate, 364)
    const lyWindowStart = subtractDays(lyWindowEnd, 27)
    const lyPrevEnd     = subtractDays(lyWindowStart, 1)
    const lyPrevStart   = subtractDays(lyPrevEnd, 27)

    const { data: lyRows, error: lyErr } = await supabase
      .rpc('rpc_pmini_sales_history', { p_store_code: STORE, p_eans: FIXED_EANS, p_from: lyPrevStart, p_to: lyWindowEnd })
    if (lyErr) throw lyErr

    const lyByEan = {}
    for (const r of lyRows ?? []) {
      if (!lyByEan[r.ean]) lyByEan[r.ean] = { same: 0, prev: 0 }
      if (r.sale_date >= lyWindowStart && r.sale_date <= lyWindowEnd) {
        lyByEan[r.ean].same += Math.max(0, r.qty ?? 0)
      } else {
        lyByEan[r.ean].prev += Math.max(0, r.qty ?? 0)
      }
    }

    // ---- 5. Compute weekly buckets ----------------------------------------
    // wk[0] = most recent completed week, wk[5] = 6 weeks ago.
    function weeklyBuckets(rows, latest) {
      const buckets = [0, 0, 0, 0, 0, 0]
      const t0 = new Date(latest + 'T12:00:00Z').getTime()
      for (const r of rows) {
        const t1 = new Date(r.sale_date + 'T12:00:00Z').getTime()
        const daysDiff = Math.round((t0 - t1) / 86400000)
        const b = Math.floor(daysDiff / 7)
        if (b >= 0 && b < 6) {
          buckets[b] += Math.max(0, r.qty ?? 0)
        }
      }
      return buckets.map(v => Math.round(v))
    }

    // ---- 6. Assemble lines ------------------------------------------------
    const lines = LINES_META.map(meta => {
      const snap = snapByEan[meta.ean]
      const hist = histByEan[meta.ean] ?? []
      const ly   = lyByEan[meta.ean]

      const wk = weeklyBuckets(hist, latestDate)

      // Seasonal factor
      let syf = 1.0
      if (ly && ly.prev > 0 && ly.same > 0) {
        syf = Math.round((ly.same / ly.prev) * 100) / 100
      }

      const soh = snap?.soh ?? null
      const totalWk = wk.reduce((a, b) => a + b, 0)
      const avgDaily = totalWk / 42
      const stockDays = soh != null && avgDaily > 0
        ? Math.round((soh / avgDaily) * 10) / 10
        : null

      const lastSales = snap?.last_sale_date
        ? isoDate(snap.last_sale_date)
        : null

      return {
        code:      meta.code,
        desc:      snap?.description ?? meta.desc,
        dept:      snap?.dept_name     ?? '',
        sub:       snap?.sub_dept_name ?? '',
        soh:       soh,
        wk,
        lastSales,
        lastRecv:  null,    // not carried by rpc_pmini_snapshot (SQL pipeline will add)
        stockDays: stockDays,
        cost:      snap?.unit_cost  ?? null,
        sell:      snap?.sell_price ?? null,
        syf,
        // band and onOrder omitted — engine doesn't carry them yet, page uses snapshot fallback
      }
    })

    return NextResponse.json({ asAt, nextRefresh: '20:10 SAST', lines })

  } catch (err) {
    console.error('[dev-corner/lines]', err?.message ?? err)
    return new NextResponse(JSON.stringify({ error: 'unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
}
