// POST /api/stocktake/cycle/[id]/upload  (multipart, field `file`, an .xlsx up to 5 MB)
//   -> { set, unchanged, blank, rejected: [{ line_id?, row, tab, reason }], unmatched_rows, saved_at }
//
// The filled count sheet is read here (matched on LineId, see parseCountUpload) and ALL its readable
// rows go to rpc_stocktake_capture in ONE call with source UPLOAD. Rows that cannot be read never
// leave this route. They come back in `rejected` beside the database's own.
//
// Every rejected item carries `reason` (a bare sentence), `row` and `tab`. The page writes
// "BAKERY row 3: <reason>" itself, so the reason never repeats the location.
//
// The file is checked in this order, and each step stops the request before the next one runs:
//   1. the declared size, then the body itself read with a running byte count (5 MB)
//   2. the zip, counted by what it unpacks to (50 MB in all, 20 MB for one worksheet)
//   3. the cycle's own line count, read from the database
//   4. the sheet read by exceljs, then the number of lines it would send against that line count
import {
  MAX_UPLOAD_BYTES, MULTIPART_SLACK_BYTES, StocktakeError, cycleIdParam, json, readBoundedBody, requireUser, route,
} from '@/lib/stocktake/server'
import { parseCountUpload } from '@/lib/stocktake/sheet'
import { NOT_ON_CYCLE, dbRefusalSentence } from '@/lib/stocktake/reasons'
import { UploadTooLarge, assertXlsxWithinLimits } from '@/lib/stocktake/zipguard'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const tooLarge = () => new StocktakeError('file_too_large', 413, 'That file is too large. A count sheet is far smaller than 5 MB.')
const unpackedTooLarge = () => new StocktakeError('file_too_large', 413,
  'That file is far larger than a count sheet once it is opened. Download the sheet again and fill that one.')
const sheetTooLarge = () => new StocktakeError('file_too_large', 413,
  'A tab in that file is far larger than a count sheet. Download the sheet again and fill that one.')

export const POST = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)

  // Refuse an oversized request before reading it. The bounded read below is the real check,
  // because a chunked request declares no size.
  const declared = Number(request.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > MAX_UPLOAD_BYTES + MULTIPART_SLACK_BYTES) throw tooLarge()

  const raw = await readBoundedBody(request, MAX_UPLOAD_BYTES + MULTIPART_SLACK_BYTES, tooLarge)
  let form
  try {
    form = await new Response(raw, { headers: { 'content-type': request.headers.get('content-type') || '' } }).formData()
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

  // Count what the zip unpacks to before anything opens it.
  try {
    await assertXlsxWithinLimits(buffer)
  } catch (err) {
    if (err instanceof UploadTooLarge) throw err.what === 'sheet' ? sheetTooLarge() : unpackedTooLarge()
    throw unreadable
  }

  // The cycle's own line count. A sheet never holds more lines to send than the cycle has.
  const { data: cycleDoc } = await rpc('rpc_stocktake_cycle_get', { p_cycle: id })
  const lineCount = cycleDoc ? cycleDoc.line_count : null
  if (!Number.isSafeInteger(lineCount) || lineCount < 0) {
    throw new StocktakeError('tripwire', 502,
      'The list did not load in full, so the sheet was not used. Reload the page. If it happens again tell SocialBrand support.')
  }

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
  if (parsed.lines.length > lineCount) {
    throw new StocktakeError('too_many_lines', 422,
      'This sheet holds more lines than the list does. Download the sheet again and fill that one.')
  }

  const { data } = await rpc('rpc_stocktake_capture', { p_cycle: id, p_lines: parsed.lines, p_source: 'UPLOAD' })

  // Where each sent line sat in the file, so the database's refusals name the tab and row.
  // A line goes in once (the later duplicate never reaches here), so each key is unique.
  const where = new Map()
  parsed.lines.forEach((line, i) => where.set(String(line.line_id), parsed.sources[i]))

  const rejected = parsed.rejected.map((r) => {
    const out = {}
    if (r.line_id !== undefined) out.line_id = r.line_id
    out.row = r.row
    out.tab = r.tab
    out.reason = r.reason
    return out
  })

  let unmatched = 0
  const fromDb = Array.isArray(data && data.rejected) ? data.rejected : []
  for (const r of fromDb) {
    if (r.reason === NOT_ON_CYCLE) unmatched += 1
    const out = { line_id: r.line_id }
    const src = where.get(String(r.line_id))
    if (src) {
      out.row = src.row
      out.tab = src.tab
    }
    out.reason = dbRefusalSentence(r.reason)
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
