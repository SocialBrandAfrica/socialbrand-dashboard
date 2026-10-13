// POST /api/stocktake/cycle/[id]/upload  (multipart, field `file`, an .xlsx up to 5 MB)
//   -> { set, unchanged, blank, rejected: [{ line_id?, row?, reason }], unmatched_rows, saved_at }
//
// The filled count sheet is read here (matched on LineId, see parseCountUpload) and ALL its readable
// rows go to rpc_stocktake_capture in ONE call with source UPLOAD. Rows that cannot be read never
// leave this route. They come back in `rejected` with the tab and row, beside the database's own.
import { MAX_UPLOAD_BYTES, MULTIPART_SLACK_BYTES, StocktakeError, cycleIdParam, json, requireUser, route } from '@/lib/stocktake/server'
import { parseCountUpload } from '@/lib/stocktake/sheet'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

// What rpc_stocktake_capture says when a LineId is not on the cycle. It is the one reason
// counted as an unmatched row.
const NOT_ON_CYCLE = 'line is not on this cycle'

const DB_REASON = {
  [NOT_ON_CYCLE]: 'this line is not on this list',
  'a count cannot be negative': 'a count cannot be below zero',
}

const tooLarge = () => new StocktakeError('file_too_large', 413, 'That file is too large. A count sheet is far smaller than 5 MB.')

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)

  // Refuse an oversized request before reading it. The check after reading is the real one.
  const declared = Number(request.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > MAX_UPLOAD_BYTES + MULTIPART_SLACK_BYTES) throw tooLarge()

  let form
  try {
    form = await request.formData()
  } catch {
    throw new StocktakeError('bad_request', 400, 'Send the sheet as a file upload.')
  }
  const file = form.get('file')
  if (!file || typeof file === 'string' || typeof file.arrayBuffer !== 'function') {
    throw new StocktakeError('no_file', 400, 'Choose the filled count sheet to upload.')
  }
  if (file.size > MAX_UPLOAD_BYTES) throw tooLarge()
  if (!/\.xlsx$/i.test(String(file.name || ''))) {
    throw new StocktakeError('not_xlsx', 415, 'Upload an Excel file that ends in .xlsx. Save the sheet as .xlsx and try again.')
  }

  const buffer = Buffer.from(await file.arrayBuffer())
  // An .xlsx is a zip file and starts with the letters PK.
  const unreadable = new StocktakeError('bad_file', 422,
    'This file could not be read as an Excel sheet. Download the sheet again and fill that one.')
  if (buffer.length < 4 || buffer[0] !== 0x50 || buffer[1] !== 0x4b) throw unreadable

  let parsed
  try {
    parsed = await parseCountUpload(buffer)
  } catch {
    throw unreadable
  }
  if (parsed.tabs_read === 0) {
    throw new StocktakeError('not_a_count_sheet', 422,
      'This file is not a count sheet from this page. Download the sheet again and fill that one.')
  }

  const { data } = await rpc('rpc_stocktake_capture', { p_cycle: id, p_lines: parsed.lines, p_source: 'UPLOAD' })

  // Where each sent line sat in the file, so the database's refusals can name the tab and row.
  const where = new Map()
  parsed.lines.forEach((line, i) => {
    const key = String(line.line_id)
    if (!where.has(key)) where.set(key, parsed.sources[i])
  })

  const rejected = parsed.rejected.map((r) => {
    const out = { row: r.row, reason: r.reason }
    if (r.line_id !== undefined) out.line_id = r.line_id
    return out
  })

  let unmatched = 0
  const fromDb = Array.isArray(data && data.rejected) ? data.rejected : []
  for (const r of fromDb) {
    if (r.reason === NOT_ON_CYCLE) unmatched += 1
    const src = where.get(String(r.line_id))
    const why = DB_REASON[r.reason] || 'the database did not accept this line'
    const out = { line_id: r.line_id, reason: src ? `${src.tab} row ${src.row}: ${why}.` : `Line ${r.line_id}: ${why}.` }
    if (src) out.row = src.row
    rejected.push(out)
  }

  return json({
    set: data.set,
    unchanged: data.unchanged,
    blank: data.blank,
    rejected,
    unmatched_rows: unmatched,
    saved_at: data.saved_at,
  })
})
