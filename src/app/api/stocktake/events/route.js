// GET /api/stocktake/events?cycle=<uuid> -> { events: [...rpc_stocktake_events] } (newest first)
import { EVENT_LIMIT, cycleIdParam, json, requireUser, route } from '@/lib/stocktake/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export const GET = route(async (request) => {
  const { rpc } = await requireUser()
  const cycle = cycleIdParam(new URL(request.url).searchParams.get('cycle'))
  const { data } = await rpc('rpc_stocktake_events', { p_cycle: cycle, p_limit: EVENT_LIMIT })
  return json({ events: data })
})
