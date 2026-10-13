// POST /api/stocktake/cycle/[id]/cancel  { reason? } -> { ok: true, status: 'CANCELLED' }
import { cycleIdParam, json, requireUser, route, StocktakeError } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)

  // The body is optional: a bare POST cancels without a reason.
  let reason = null
  const text = await request.text()
  if (text.trim()) {
    let body
    try {
      body = JSON.parse(text)
    } catch {
      throw new StocktakeError('bad_request', 400, 'Send the request as JSON.')
    }
    if (body && body.reason !== undefined && body.reason !== null) {
      if (typeof body.reason !== 'string') throw new StocktakeError('bad_request', 400, 'The reason must be text.')
      reason = body.reason.trim() || null
    }
  }

  const { data } = await rpc('rpc_stocktake_cancel', { p_cycle: id, p_reason: reason })
  return json(data)
})
