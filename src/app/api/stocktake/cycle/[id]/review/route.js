// POST /api/stocktake/cycle/[id]/review  { actions: [{ line_id, action: 'CONFIRM' | 'RECOUNT' }] } -> review result
import {
  MAX_REVIEW_ACTIONS, cycleIdParam, json, readJsonObject, requireUser, route, StocktakeError,
} from '@/lib/stocktake/server'
import { parseLineId } from '@/lib/stocktake/qty'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const ACTIONS = ['CONFIRM', 'RECOUNT']

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const body = await readJsonObject(request)
  if (!Array.isArray(body.actions) || body.actions.length === 0) {
    throw new StocktakeError('bad_request', 400, 'Send at least one line to confirm or recount.')
  }
  if (body.actions.length > MAX_REVIEW_ACTIONS) {
    throw new StocktakeError('bad_request', 400, `Send ${MAX_REVIEW_ACTIONS} lines or fewer in one request.`)
  }

  const actions = body.actions.map((item) => {
    const lineId = item && typeof item === 'object' ? parseLineId(item.line_id) : { none: true }
    const action = item && typeof item.action === 'string' ? item.action.trim().toUpperCase() : ''
    if (lineId.id === undefined || !ACTIONS.includes(action)) {
      throw new StocktakeError('bad_request', 400, 'Each line needs a line number and the action Confirm or Recount.')
    }
    return { line_id: lineId.id, action }
  })

  const { data } = await rpc('rpc_stocktake_review', { p_cycle: id, p_actions: actions })
  return json(data)
})
