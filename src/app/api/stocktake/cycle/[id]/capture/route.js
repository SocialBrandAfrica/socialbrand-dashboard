// POST /api/stocktake/cycle/[id]/capture  { lines: [{ line_id, front, back, clear }] } -> capture result
//
// Source TYPED. A null or missing front or back leaves that box alone, clear:true empties both
// (the database defines this, see rpc_stocktake_capture). A line that cannot be read is not
// sent. It comes back in `rejected` beside the database's own, so the page handles one shape.
import { cycleIdParam, json, readJsonObject, requireUser, route, StocktakeError } from '@/lib/stocktake/server'
import { parseLineId, parseQty } from '@/lib/stocktake/qty'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const body = await readJsonObject(request)
  if (!Array.isArray(body.lines)) {
    throw new StocktakeError('bad_request', 400, 'Send the counts as a list of lines.')
  }

  const send = []
  const rejected = []

  for (const item of body.lines) {
    if (!item || typeof item !== 'object') {
      rejected.push({ reason: 'A line in the request was not readable.' })
      continue
    }
    const lineId = parseLineId(item.line_id)
    if (lineId.id === undefined) {
      rejected.push({ reason: 'A line in the request had no valid line number.' })
      continue
    }
    const front = parseQty(item.front)
    const back = parseQty(item.back)
    if (front.bad || back.bad) {
      const which = front.bad ? 'Front' : 'Back'
      const why = front.bad || back.bad
      rejected.push({ line_id: lineId.id, reason: `The ${which} count ${why}.` })
      continue
    }
    const out = { line_id: lineId.id }
    if (item.clear === true) out.clear = true
    if (front.value !== undefined) out.front = front.value
    if (back.value !== undefined) out.back = back.value
    send.push(out)
  }

  const { data } = await rpc('rpc_stocktake_capture', { p_cycle: id, p_lines: send, p_source: 'TYPED' })
  const fromDb = Array.isArray(data && data.rejected) ? data.rejected : []
  return json({ ...data, rejected: [...rejected, ...fromDb] })
})
