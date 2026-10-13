// GET /api/stocktake/overview -> { stores: [...rpc_stocktake_overview] }
import { json, requireUser, route } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async () => {
  const { rpc } = await requireUser()
  const { data } = await rpc('rpc_stocktake_overview')
  return json({ stores: data })
})
