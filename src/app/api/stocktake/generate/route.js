// POST /api/stocktake/generate  { store, list_type, subdept? } -> the rpc_stocktake_generate result
//
// The database enforces the real rules (one open cycle per store, list type and sub-department,
// the stocked draw, an empty pool). This route checks only the shape of the request.
import { StocktakeError, json, readJsonObject, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const LIST_TYPES = ['DAILY', 'CONFIRM', 'ADHOC', 'PLU']

export const POST = route(async (request) => {
  const { rpc } = await requireUser()
  const body = await readJsonObject(request)

  const store = storeParam(body.store)
  const listType = typeof body.list_type === 'string' ? body.list_type.trim().toUpperCase() : ''
  if (!LIST_TYPES.includes(listType)) {
    throw new StocktakeError('bad_request', 400, 'Pick one of the list types: daily, confirmation, batch or PLU and scale.')
  }

  let subdept = null
  if (body.subdept !== undefined && body.subdept !== null) {
    if (typeof body.subdept !== 'string') throw new StocktakeError('bad_request', 400, 'The sub-department must be text.')
    subdept = body.subdept.trim() || null
  }
  if (listType === 'ADHOC' && !subdept) {
    throw new StocktakeError('subdept_required', 422, 'A batch needs a sub-department. Pick one and try again.')
  }

  const { data } = await rpc('rpc_stocktake_generate', {
    p_store: store,
    p_list_type: listType,
    p_subdept: listType === 'ADHOC' ? subdept : null,
  })
  return json(data)
})
