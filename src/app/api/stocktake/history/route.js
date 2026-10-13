// GET /api/stocktake/history?store=10116
//   -> { history: rpc_stocktake_history, events: rpc_stocktake_events(null, store, 200) }
//
// The history length is the database's own default. The 200 event rows are the contract's.
import { json, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const store = storeParam(new URL(request.url).searchParams.get('store'))
  const [history, events] = await Promise.all([
    rpc('rpc_stocktake_history', { p_store: store }),
    rpc('rpc_stocktake_events', { p_store: store, p_limit: 200 }),
  ])
  return json({ history: history.data, events: events.data })
})
