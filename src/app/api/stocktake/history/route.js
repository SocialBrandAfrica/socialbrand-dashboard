// GET /api/stocktake/history?store=10116
//   -> { history: rpc_stocktake_history(store, HISTORY_CYCLE_LIMIT),
//        events: rpc_stocktake_events(null, store, EVENT_LIMIT) }
//
// The events function clamps its limit at EVENT_LIMIT, so that is the most it returns.
import { EVENT_LIMIT, HISTORY_CYCLE_LIMIT, json, requireUser, route, storeParam } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const store = storeParam(new URL(request.url).searchParams.get('store'))
  const [history, events] = await Promise.all([
    rpc('rpc_stocktake_history', { p_store: store, p_limit: HISTORY_CYCLE_LIMIT }),
    rpc('rpc_stocktake_events', { p_store: store, p_limit: EVENT_LIMIT }),
  ])
  return json({ history: history.data, events: events.data })
})
