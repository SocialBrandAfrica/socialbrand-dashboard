// src/app/api/dev-corner/sigma-lines/route.js
// SB-CC-PMINI-002 — per-line per-day consignment sales from sigma_sales (Layer 1).
// RPC: rpc_consignment_lines(p_month, p_store, p_group, p_client)
// Returns lines[] with per-day arrays ready for the Pulse Mini consignment panel.

import { createClient } from '@supabase/supabase-js'
import { NextResponse }  from 'next/server'

const STORE  = '10116'
const GROUP  = 610          // merch_group_nr for HMR Sushi counter
const CLIENT = 'socialbrand'

// Type classification from description — sushi ('s') vs Chinese/other ('c').
// Brief defines: sushi = COMBO*, SASHIMI, MIKI ROLL, AVALANCHE, FASHION SANDWICHES,
//                         ROSES, FUTOMAKI, CALIFORNIA, RAINBOW, HAND ROLL, BEAN CURD,
//                         NIGIRI, POKE BOWL, CRAB SALAD, EXTRA*
// Chinese = CHOW MEIN, DUMPLING, SWEET & SOUR, FRIED RICE, SORING ROLLS
function classifyLine(desc) {
  const u = (desc ?? '').toUpperCase()
  if (u.startsWith('COMBO')              ||
      u.startsWith('SASHIMI')            ||
      u.startsWith('MIKI ROLL')          ||
      u.startsWith('AVALANCHE')          ||
      u.startsWith('FASHION SANDWICH')   ||
      u.startsWith('ROSES')              ||
      u.startsWith('FUTOMAKI')           ||
      u.startsWith('CALIFORNIA ROLL')    ||
      u.startsWith('RAINBOW ROLL')       ||
      u.startsWith('HAND ROLL')          ||
      u.startsWith('BEAN CURD')          ||
      u.startsWith('NIGIRI')             ||
      u.startsWith('POKE BOWL')          ||
      u.startsWith('CRAB SALAD')         ||
      u.startsWith('EXTRA')) {
    return 's'
  }
  return 'c'
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
  const monthLabel   = `${year}-${mm}`
  const daysInMonth  = new Date(Date.UTC(year, month, 0)).getDate()

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false } }
  )

  try {
    const { data: rows, error } = await supabase
      .rpc('rpc_consignment_lines', {
        p_month:  monthLabel,
        p_store:  STORE,
        p_group:  GROUP,
        p_client: CLIENT,
      })

    if (error) throw error

    // Determine which dates have data (sorted)
    const dateSet  = new Set((rows ?? []).map(r => r.sale_date))
    const dates    = [...dateSet].sort()
    const loadedDays = dates.length

    // Pivot: group rows by description → build per-date arrays
    const byDesc = {}
    for (const r of (rows ?? [])) {
      if (!byDesc[r.description]) {
        byDesc[r.description] = { byDate: {} }
      }
      byDesc[r.description].byDate[r.sale_date] = {
        s: Math.round(parseFloat(r.sales || 0) * 100) / 100,
        q: Math.round(parseFloat(r.qty   || 0) * 10)  / 10,
      }
    }

    // Build output lines in the same shape as PM's reference L[] array
    const lines = Object.entries(byDesc).map(([desc, d]) => {
      const s = dates.map(dt => d.byDate[dt]?.s ?? 0)
      const q = dates.map(dt => d.byDate[dt]?.q ?? 0)
      return { n: desc, t: classifyLine(desc), s, q }
    })

    return NextResponse.json({
      month:        monthLabel,
      loaded_days:  loadedDays,
      days_in_month: daysInMonth,
      as_at:        dates.length ? dates[dates.length - 1] : null,
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
