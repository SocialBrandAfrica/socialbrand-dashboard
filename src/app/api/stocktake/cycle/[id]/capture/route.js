// POST /api/stocktake/cycle/[id]/capture  { lines: [{ line_id, front, back, clear }] } -> capture result
//
// Source TYPED. A null or missing front or back leaves that box alone, clear:true empties both
// (the database defines this, see rpc_stocktake_capture). A line that cannot be read is not
// sent. It comes back in `rejected` beside the database's own, so the page handles one shape.
// The request holds MAX_CAPTURE_LINES lines or fewer.
import {
  MAX_CAPTURE_LINES, cycleIdParam, json, readJsonObject, requireUser, route, StocktakeError,
} from '@/lib/stocktake/server'
import { parseLineId, parseQty } from '@/lib/stocktake/qty'
import { dbRefusalSentence } from '@/lib/stocktake/reasons'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const body = await readJsonObject(request)
  if (!Array.isArray(body.lines)) {
    throw new StocktakeError('bad_request', 400, 'Send the counts as a list of lines.')
  }
  if (body.lines.length > MAX_CAPTURE_LINES) {
    throw new StocktakeError('bad_request', 400, `Send ${MAX_CAPTURE_LINES} lines or fewer in one request.`)
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
      const refused = front.bad ? front : back
      // A refusal with its own whole sentence (the thousands comma) is used as it is.
      rejected.push({ line_id: lineId.id, reason: refused.refusal || `The ${which} count ${refused.bad}.` })
      continue
    }
    const out = { line_id: lineId.id }
    if (item.clear === true) out.clear = true
    if (front.value !== undefined) out.front = front.value
    if (back.value !== undefined) out.back = back.value
    send.push(out)
  }

  const { data } = await rpc('rpc_stocktake_capture', { p_cycle: id, p_lines: send, p_source: 'TYPED' })
  // The database's refusals leave as bare sentences too, never as its own text.
  const fromDb = (Array.isArray(data && data.rejected) ? data.rejected : [])
    .map((r) => ({ ...r, reason: dbRefusalSentence(r.reason) }))
  return json({ ...data, rejected: [...rejected, ...fromDb] })
})
