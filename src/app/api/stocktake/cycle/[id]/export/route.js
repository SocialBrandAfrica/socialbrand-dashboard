// GET /api/stocktake/cycle/[id]/export?kind=TLX|PLU  (the cycle must be FINALISED)
//
//   kind=TLX  the TLX file, byte for byte what the database built: text/plain, no trailing
//             newline, no byte order mark, the filename the database chose. Sigma reads this
//             file, so nothing here touches the content. The header X-Fractional-Lines carries
//             how many lines hold a fractional count, so the page warns before the import.
//   kind=PLU  the PLU and scale rows (the MANUAL lines) as an xlsx.
//
// The EXPORT_TLX / EXPORT_PLU event is written by the database function itself.
import { StocktakeError, cycleIdParam, fileResponse, requireUser, route } from '@/lib/stocktake/server'
import { buildPluWorkbook } from '@/lib/stocktake/sheet'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

export const GET = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)
  const kind = String(new URL(request.url).searchParams.get('kind') || '').trim().toUpperCase()

  if (kind === 'TLX') {
    const { data } = await rpc('rpc_stocktake_export', { p_cycle: id, p_kind: 'TLX' })
    if (!data || data.kind !== 'TLX' || typeof data.content !== 'string' || data.content === '') {
      throw new StocktakeError('tripwire', 502, 'The TLX file came back empty, so no file was made. Tell SocialBrand support.')
    }
    // The database reports how many lines hold a fractional count. A file whose warning
    // cannot be sent is not served: the person would import it without being told.
    const fractional = data.fractional_lines
    if (!Number.isSafeInteger(fractional) || fractional < 0) {
      throw new StocktakeError('tripwire', 502,
        'The TLX file did not report its fractional lines, so no file was made. Tell SocialBrand support.')
    }
    return fileResponse(data.content, 'text/plain; charset=utf-8', data.filename, {
      'X-Fractional-Lines': String(fractional),
    })
  }

  if (kind === 'PLU') {
    const { data } = await rpc('rpc_stocktake_export', { p_cycle: id, p_kind: 'MANUAL' })
    if (!data || data.kind !== 'MANUAL' || !Array.isArray(data.rows) || data.rows.length !== data.line_count) {
      throw new StocktakeError('tripwire', 502,
        'The PLU and scale list did not load in full, so no file was made. Tell SocialBrand support.')
    }
    const buffer = await buildPluWorkbook(data)
    // The database names this export <...>_PLU.csv. The file here is a workbook.
    const name = String(data.filename || 'stocktake_PLU').replace(/\.csv$/i, '') + '.xlsx'
    return fileResponse(buffer, XLSX_TYPE, name)
  }

  throw new StocktakeError('bad_request', 400, 'Say which export you want: kind=TLX or kind=PLU.')
})
