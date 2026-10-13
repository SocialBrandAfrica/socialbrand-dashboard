// GET /api/stocktake/cycle/[id] -> the rpc_stocktake_cycle_get document
//
// One jsonb document, never a SETOF (the 1,000-row PostgREST cap). The tripwire: the lines
// served must equal the lines the cycle holds, or the answer is 502 { error: 'tripwire' }.
import { assertWholeCycle, cycleIdParam, json, requireUser, route } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const { data } = await rpc('rpc_stocktake_cycle_get', { p_cycle: id })
  return json(assertWholeCycle(data))
})
