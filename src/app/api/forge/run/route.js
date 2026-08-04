// src/app/api/forge/run/route.js
// Forge compliance run-log endpoint (CLEANUP-ENGINE-CANON §15 compliance loop).
//
// WHY THIS ROUTE EXISTS AT ALL — it is the thing the repo fold unlocked.
// toolkit.html is a standalone page that talks to PostgREST with the publishable
// key, so every call it makes runs as `anon`. The run-log write function is
// SECURITY DEFINER granted to `authenticated` only (R30 addendum 2: app-born
// workflow events are written ONLY through published write-functions), and
// `anon` is explicitly revoked (R30 addendum extension — the default-privilege
// trap that has now fired three times). So the page cannot call it directly,
// and it must not be granted to anon to make it reach.
//
// Instead the page posts same-origin to this route, which carries the signed-in
// user's session cookie and therefore calls the RPC as `authenticated`. The
// grant stays correct and the write stays audited.
//
// Auth: src/middleware.js already gates every path except its small public list,
// so an unauthenticated request never arrives here. The explicit getUser() check
// below is belt, not control — the same discipline as the Clients/ .gitignore
// (FILE-GOVERNANCE §0c: "the folder is the control, the ignore line is the belt").

import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

function client() {
  const cookieStore = cookies()
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() { return cookieStore.getAll() },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options)
          )
        },
      },
    }
  )
}

// POST — log one issued count list.
export async function POST(request) {
  const supabase = client()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    return NextResponse.json({ error: 'not authenticated' }, { status: 401 })
  }

  let body
  try {
    body = await request.json()
  } catch {
    return NextResponse.json({ error: 'body must be JSON' }, { status: 400 })
  }

  const { store_code, mode, lines, params, seed, source, pool_size, daily_budget } = body || {}

  // Fail loudly, never silently log an empty run (canon §8.6 guard 4).
  if (!store_code) return NextResponse.json({ error: 'store_code is required' }, { status: 400 })
  if (!mode)       return NextResponse.json({ error: 'mode is required' }, { status: 400 })
  if (!Array.isArray(lines)) {
    return NextResponse.json({ error: 'lines must be an array' }, { status: 400 })
  }

  const { data, error } = await supabase.rpc('rpc_forge_log_count_run', {
    p_store_code:   store_code,
    p_mode:         mode,
    p_lines:        lines,
    p_params:       params ?? {},
    p_seed:         seed ?? null,
    p_source:       source ?? 'forge',
    // Provenance stamp only — who issued it, never who approved it
    // (canon §17, the item-12 ruling). No branch may read this as a permission.
    p_issued_by:    user.email ?? user.id,
    p_pool_size:    pool_size ?? null,
    p_daily_budget: daily_budget ?? null,
  })

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
  return NextResponse.json(data)
}

// GET — compliance summary per store per issue-date.
//   /api/forge/run?stores=10116,80175&from=2026-08-01&to=2026-08-04
//   /api/forge/run?run_id=<uuid>   -> per-line detail for one run
export async function GET(request) {
  const supabase = client()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    return NextResponse.json({ error: 'not authenticated' }, { status: 401 })
  }

  const sp = new URL(request.url).searchParams
  const runId = sp.get('run_id')

  if (runId) {
    const { data, error } = await supabase.rpc('rpc_forge_run_compliance', { p_run_id: runId })
    if (error) return NextResponse.json({ error: error.message }, { status: 500 })
    return NextResponse.json(data)
  }

  const stores = sp.get('stores')
  const { data, error } = await supabase.rpc('rpc_forge_compliance_summary', {
    p_stores: stores ? stores.split(',').map(s => s.trim()).filter(Boolean) : null,
    p_from:   sp.get('from') || null,
    p_to:     sp.get('to')   || null,
  })
  if (error) return NextResponse.json({ error: error.message }, { status: 500 })
  return NextResponse.json(data)
}
