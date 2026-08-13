// src/app/api/forge/export-stocktake/route.js
// SB-CC-TOOLKIT-002 item 4 (interim): download TODAY's daily count lists as ONE
// workbook with a tab per store, for manual load into StockFlow while the
// automatic feed is not on yet (Pieter, 2026-08-13). Column A = product_code
// (the StockFlow ad-hoc stocktake upload column); B-G are eyeball detail the
// buyer deletes before upload and keeps for the floor sheet.
//
// Same auth pattern as ../run: the page posts same-origin, the route carries the
// signed-in session, middleware gates it, getUser() is belt. Reads the count
// lists via rpc_forge_count_list (anon+authenticated grant), deterministic seed,
// so a download equals the morning's issued list.

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
const HEADER = ['product_code', 'description', 'sub_dept', 'SOH', 'capital_R', 'priority', 'reason']

export async function GET() {
  const sb = client()
  const { data: { user } } = await sb.auth.getUser()
  if (!user) return NextResponse.json({ error: 'not authenticated' }, { status: 401 })

  const { data: stores } = await sb.from('stores').select('store_code').eq('is_active', true).order('store_code')
  const codes = (stores || []).map(s => s.store_code)
  if (!codes.length) return NextResponse.json({ error: 'no active stores' }, { status: 500 })

  const { data, error } = await sb.rpc('rpc_forge_count_list', { p_stores: codes, p_mode: 'daily' })
  if (error) return NextResponse.json({ error: error.message }, { status: 500 })

  const wb = XLSX.utils.book_new()
  for (const code of codes) {
    const rows = (data || []).filter(r => r.store_code === code).map(r => ({
      product_code: r.product_code,
      description: r.description,
      sub_dept: r.subdept_name,
      SOH: r.soh == null ? null : Number(r.soh),
      capital_R: r.capital_value == null ? null : Math.round(Number(r.capital_value)),
      priority: r.stratum_label,
      reason: r.story,
    }))
    const ws = XLSX.utils.json_to_sheet(rows, { header: HEADER })
    ws['!cols'] = [{ wch: 14 }, { wch: 34 }, { wch: 22 }, { wch: 9 }, { wch: 11 }, { wch: 20 }, { wch: 60 }]
    XLSX.utils.book_append_sheet(wb, ws, `${STORE_NAMES[code] || code} ${code}`.slice(0, 31))
  }

  const buf = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' })
  const today = new Date().toISOString().slice(0, 10)
  return new NextResponse(buf, {
    status: 200,
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="SB-STOCKTAKE_daily-count-lists_${today}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
