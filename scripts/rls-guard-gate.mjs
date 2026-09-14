// rls-guard-gate.mjs -- the pre-deploy gate of SB-CC-RLSGUARD-001 (G4). Runs as the npm "prebuild" step.
//
// A table with row level security on and no policy a client role can use answers that role with an empty set and
// no error. The platform read that as "no data" for months (ENG-163, 46 million rows). rpc_forge_rls_guard lists
// every such site and marks each one KNOWN, NEW, CHANGED or CLEARED against the register forge_rls_guard_site.
//
// The build FAILS when a SILENT site (class A or B) is NEW or CHANGED: a defect the day it appears, never a month
// later. Loud sites (class C, the grant is absent, the read fails 42501) and cleared sites are printed, not fatal.
// A guard that cannot run stops the build too: silence is the defect this gate exists to catch.
//
// Reads with the same public key the dashboard ships, NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY.
// Exits by setting process.exitCode, never process.exit(), so fetch's keep-alive socket closes cleanly first
// (process.exit() under an open socket trips a libuv assertion on Windows and exits 127, measured 2026-09-14).

const url = process.env.NEXT_PUBLIC_SUPABASE_URL
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

async function callGuard() {
  const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/rpc_forge_rls_guard`, {
    method: 'POST',
    headers: { apikey: key, 'Content-Type': 'application/json' },
    body: '{}',
  })
  const body = await res.text()
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${body.slice(0, 300)}`)
  const rows = JSON.parse(body)
  if (!Array.isArray(rows)) throw new Error('the guard did not return a list')
  return rows
}

async function main() {
  if (!url || !key) {
    console.error('[rls-guard] NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY is missing, so the guard cannot run. The build stops.')
    return 1
  }

  let rows = null
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      rows = await callGuard()
      break
    } catch (err) {
      console.error(`[rls-guard] attempt ${attempt} of 3 failed: ${err.message}`)
      if (attempt === 3) {
        console.error('[rls-guard] The guard could not be read, so the build stops.')
        return 1
      }
      await new Promise((resolve) => setTimeout(resolve, 2000 * attempt))
    }
  }

  const live = rows.filter((r) => r.verdict !== 'CLEARED')
  const silent = live.filter((r) => r.silent)
  const failing = silent.filter((r) => r.verdict === 'NEW' || r.verdict === 'CHANGED')
  const newLoud = live.filter((r) => !r.silent && r.verdict === 'NEW')
  const cleared = rows.filter((r) => r.verdict === 'CLEARED')

  console.log(`[rls-guard] ${silent.length} silent read sites, ${live.length - silent.length} loud, ${cleared.length} cleared. ` +
    `${failing.length} new or changed silent.`)
  for (const r of newLoud) console.log(`[rls-guard] new loud site (not fatal): ${r.object_name} as ${r.reader_role}. ${r.story}`)
  for (const r of cleared) console.log(`[rls-guard] cleared (not fatal): ${r.object_name} as ${r.reader_role}. ${r.story}`)

  if (failing.length > 0) {
    console.error('[rls-guard] BUILD STOPPED. A client role can be granted these tables and reads them empty with no error:')
    for (const r of failing) {
      console.error(`[rls-guard]   ${r.verdict} class ${r.site_class}: ${r.object_name} as ${r.reader_role}. ${r.story}`)
    }
    console.error('[rls-guard] Fix: give the role a policy, or move the read onto a granted SECURITY DEFINER function (R30 section 1), ' +
      'or register the site in forge_rls_guard_site with the defect id that owns it.')
    return 1
  }
  console.log('[rls-guard] PASS.')
  return 0
}

process.exitCode = await main()
