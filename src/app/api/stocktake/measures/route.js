// GET /api/stocktake/measures?from=YYYY-MM-DD&to=YYYY-MM-DD
//   -> { normalised: [...rpc_stocktake_normalised], overview: [...rpc_stocktake_overview],
//        compliance: [...rpc_stocktake_compliance(from, to)] }
//
// The toolkit (public/toolkit.html) is a standalone page that talks to PostgREST with the
// publishable key, so every call it makes runs as `anon`. The stocktake functions are granted to
// `authenticated` only (R30 addendum 2 and its extension), so the page asks THIS route, which
// carries the signed-in session. One definition each, read from the app's own stocked facts, so the
// toolkit and the count app can never describe a store two ways (SB-CC-STOCKTAKE-001 section 7, R33).
import { json, requireUser, route, StocktakeError } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const DAY = /^\d{4}-\d{2}-\d{2}$/

function dateParam(value, name) {
  const v = String(value || '')
  if (!DAY.test(v) || Number.isNaN(Date.parse(v + 'T00:00:00Z'))) {
    throw new StocktakeError('bad_request', 400, 'Give ' + name + ' as a date, year-month-day.')
  }
  return v
}

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const params = new URL(request.url).searchParams
  const from = dateParam(params.get('from'), 'from')
  const to = dateParam(params.get('to'), 'to')

  const [normalised, overview, compliance] = await Promise.all([
    rpc('rpc_stocktake_normalised', { p_store: null }),
    rpc('rpc_stocktake_overview'),
    rpc('rpc_stocktake_compliance', { p_from: from, p_to: to }),
  ])
  return json({ normalised: normalised.data, overview: overview.data, compliance: compliance.data })
})
