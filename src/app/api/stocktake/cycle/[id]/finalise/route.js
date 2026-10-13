// POST /api/stocktake/cycle/[id]/finalise -> the rpc_stocktake_finalise result
//
// A refusal (blank lines or unconfirmed flagged lines) is a normal answer: 200 with ok:false and
// the lists, which the page turns into its blocking message. It is not an HTTP error.
import { cycleIdParam, json, requireUser, route } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const { data } = await rpc('rpc_stocktake_finalise', { p_cycle: id })
  return json(data)
})
