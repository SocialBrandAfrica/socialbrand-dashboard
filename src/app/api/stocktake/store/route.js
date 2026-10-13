// GET /api/stocktake/store?store=10116 -> { state: rpc_stocktake_store_state }
import { json, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const store = storeParam(new URL(request.url).searchParams.get('store'))
  const { data } = await rpc('rpc_stocktake_store_state', { p_store: store })
  return json({ state: data })
})
