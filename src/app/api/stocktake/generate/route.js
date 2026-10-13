// POST /api/stocktake/generate  { store, list_type, subdept?, supplier? } -> the rpc_stocktake_generate result
//
// The database enforces the real rules (one open cycle per store, list type and sub-department,
// the stocked draw, an empty pool). This route checks only the shape of the request.
import { StocktakeError, json, readJsonObject, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const LIST_TYPES = ['DAILY', 'CONFIRM', 'ADHOC', 'PLU', 'SUPPLIER']

export const POST = route(async (request) => {
  const { rpc } = await requireUser()
  const body = await readJsonObject(request)

  const store = storeParam(body.store)
  const listType = typeof body.list_type === 'string' ? body.list_type.trim().toUpperCase() : ''
  if (!LIST_TYPES.includes(listType)) {
    throw new StocktakeError('bad_request', 400, 'Pick one of the list types: daily, confirmation, batch, supplier or PLU and scale.')
  }

  let subdept = null
  if (body.subdept !== undefined && body.subdept !== null) {
    if (typeof body.subdept !== 'string') throw new StocktakeError('bad_request', 400, 'The sub-department must be text.')
    subdept = body.subdept.trim() || null
  }
  if (listType === 'ADHOC' && !subdept) {
    throw new StocktakeError('subdept_required', 422, 'A batch needs a sub-department. Pick one and try again.')
  }

  // A supplier number is a whole number. The database checks that the supplier has products at this store.
  let supplier = null
  if (body.supplier !== undefined && body.supplier !== null && body.supplier !== '') {
    const text = String(body.supplier).trim()
    if (!/^\d{1,12}$/.test(text)) throw new StocktakeError('bad_request', 400, 'The supplier must be a number.')
    supplier = Number(text)
  }
  if (listType === 'SUPPLIER' && supplier === null) {
    throw new StocktakeError('supplier_required', 422, 'A supplier count needs a supplier. Pick one and try again.')
  }

  // p_supplier is sent only for a supplier count, so every other list type is the same call as before.
  const { data } = await rpc('rpc_stocktake_generate', {
    p_store: store,
    p_list_type: listType,
    p_subdept: listType === 'ADHOC' ? subdept : null,
    ...(listType === 'SUPPLIER' ? { p_supplier: supplier } : {}),
  })
  return json(data)
})
