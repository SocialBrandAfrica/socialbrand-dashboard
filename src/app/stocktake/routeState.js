// The page's route (store, list, step, screen) lives in the URL query. These helpers read it, write it and
// decide what a route change owes the screen. Pure functions, no browser objects, so the render test
// runs the same code as the page.

// The steps of one list, in the order a person works them. Generate comes first and is done the moment
// a list exists, so the four steps inside an open list are these.
export const STEPS = ['print', 'count', 'review', 'finish']
export const STEP_LABELS = { generate: 'Generate', print: 'Print', count: 'Count', review: 'Review', finish: 'Finish' }

// search: the URL's query string, "?store=10116&cycle=<uuid>&step=count" or "?store=10116&tab=history"
export function readRoute(search) {
  const p = new URLSearchParams(search || '')
  const step = p.get('step')
  return {
    store: p.get('store') || null,
    cycle: p.get('cycle') || null,
    // tab names the screen: the count flow ('count') or the separate History screen ('history')
    tab: p.get('tab') === 'history' ? 'history' : 'count',
    step: STEPS.includes(step) ? step : null,
  }
}

export function routeQuery(r) {
  const p = new URLSearchParams()
  if (r.store) p.set('store', r.store)
  if (r.cycle) p.set('cycle', r.cycle)
  if (r.tab === 'history') p.set('tab', 'history')
  if (r.cycle && r.step && STEPS.includes(r.step)) p.set('step', r.step)
  const s = p.toString()
  return s ? '?' + s : ''
}

// The step an open list shows. A step chosen by the user (in the URL) wins. Otherwise the list opens
// where the work stands: nothing counted yet is Print, counts still blank is Count, differences still
// waiting is Review, and everything counted and decided is Finish. Counted, never computed: these
// are the counts the database returned.
export function stepFor(chosen, counts) {
  if (STEPS.includes(chosen)) return chosen
  const c = counts || {}
  const total = Number(c.lines) || 0
  const captured = Number(c.captured) || 0
  if (captured <= 0) return 'print'
  if (captured < total) return 'count'
  if ((Number(c.flagged_open) || 0) > 0) return 'review'
  return 'finish'
}

// The home list and a store screen show the progress of each open list ("143 of 200 captured").
// That figure is current only if the overview is read again whenever the route lands on Home or on
// a store: from a list, from another store, from Home, or through the browser's back button.
// The first route needs no refresh because the page has just read the overview.
export function shouldRefreshOverview(prev, next) {
  if (!prev || !next) return false
  if (next.cycle) return false
  return Boolean(prev.cycle) || prev.store !== next.store
}

// What the History screen holds before a store has loaded: nothing from any other store.
export function emptyHistoryDoc() {
  return { status: 'idle', history: null, events: [], eventsLimit: null, message: '', signIn: false }
}
