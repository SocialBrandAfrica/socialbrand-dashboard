// GET /api/stocktake/line-history?store=10116&product=150416 -> rpc_stocktake_line_history
//
// The product code is read as text and cast by the database. It is never turned into a JS number.
import { json, productParam, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const sp = new URL(request.url).searchParams
  const store = storeParam(sp.get('store'))
  const product = productParam(sp.get('product'))
  const { data } = await rpc('rpc_stocktake_line_history', { p_store: store, p_product: product })
  return json(data)
})
