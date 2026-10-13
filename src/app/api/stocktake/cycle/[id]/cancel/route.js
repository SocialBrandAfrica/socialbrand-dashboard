// POST /api/stocktake/cycle/[id]/cancel  { reason? } -> { ok: true, status: 'CANCELLED' }
import { MAX_CANCEL_REASON, cycleIdParam, json, requireUser, route, StocktakeError } from '@/lib/stocktake/server'

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
      if (reason !== null && reason.length > MAX_CANCEL_REASON) {
        throw new StocktakeError('bad_request', 400, `Keep the reason to ${MAX_CANCEL_REASON} characters or fewer.`)
      }
    }
  }

  const { data } = await rpc('rpc_stocktake_cancel', { p_cycle: id, p_reason: reason })
  return json(data)
})
