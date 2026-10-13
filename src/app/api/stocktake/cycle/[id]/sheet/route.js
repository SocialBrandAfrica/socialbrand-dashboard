// GET /api/stocktake/cycle/[id]/sheet -> the count sheet (xlsx), one tab per department.
//
// The DOWNLOAD event is logged only AFTER the workbook is built, so a failed build leaves no
// entry. If the log write itself fails, the file is not served: a download the audit trail
// cannot see is not allowed to happen (R22). The person retries.
import { assertWholeCycle, cycleIdParam, fileResponse, requireUser, route } from '@/lib/stocktake/server'
import { buildCountWorkbook, describeCountSheet } from '@/lib/stocktake/sheet'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

export const GET = route(async (request, { params }) => {
  const { rpc } = await requireUser()
  const id = cycleIdParam(params.id)

  const { data } = await rpc('rpc_stocktake_cycle_get', { p_cycle: id })
  const doc = assertWholeCycle(data)

  const buffer = await buildCountWorkbook(doc)
  const { lines, tabs } = describeCountSheet(doc)

  await rpc('rpc_stocktake_log_event', {
    p_cycle: id,
    p_type: 'DOWNLOAD',
    p_detail: { kind: 'xlsx', lines, tabs },
  })

  // <store>_stocktake_<date>_<TYPE>.xlsx, with the sub-department added for a batch so two
  // batches downloaded the same day do not share a name (the database names its exports the same way).
  const c = doc.cycle
  const date = /^\d{4}-\d{2}-\d{2}/.test(String(c.generated_on || '')) ? String(c.generated_on).slice(0, 10) : 'undated'
  const sub = c.subdept_name ? '_' + String(c.subdept_name).replace(/[^A-Za-z0-9]+/g, '-') : ''
  const name = `${c.store_code}_stocktake_${date}_${c.list_type}${sub}.xlsx`

  return fileResponse(buffer, XLSX_TYPE, name)
})
