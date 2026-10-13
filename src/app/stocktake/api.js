// The stocktake page's only line to the server: one function per HTTP route of the contract
// (SB-CC-STOCKTAKE-001 v1.2). Same-origin, cookie session, no keys, no tables. Every function
// resolves with the parsed JSON body or throws an ApiError whose message is a plain sentence.
// Identifiers (EAN, PLU, product code) travel as text in every query and body. Nothing here parses them.

const BASE = '/api/stocktake'

export class ApiError extends Error {
  constructor(message, { code, status, cycleId } = {}) {
    super(message)
    this.name = 'ApiError'
    this.code = code || 'error'
    this.status = status || 0
    this.cycleId = cycleId || null
  }
}

const NETWORK_MESSAGE = 'The connection dropped. Check the signal and try again.'
// The most events the history route asks the database for in one read (decision D5). The route
// reports its own figure as events_limit. This is the figure to use when it does not.
export const EVENTS_READ_LIMIT = 1000
const SIGNED_OUT_MESSAGE = 'Your sign-in has ended. Sign in again to carry on.'
// A request that hangs on a dead link must fail in the open, so the row shows Not saved with Try again.
const REQUEST_TIMEOUT_MS = 30000

// A signed-out call must never read as a success. The server answers 401 JSON, and these tests also
// catch a redirect to the login page (a 200 page of HTML) and a body that is not what was asked for.
function signedOut() {
  return new ApiError(SIGNED_OUT_MESSAGE, { code: 'not authenticated', status: 401 })
}
function landedOnLogin(res) {
  if (res.redirected) return true
  try {
    return /\/login\/?$/.test(new URL(res.url).pathname)
  } catch {
    return false
  }
}

function fallbackMessage(status) {
  if (status === 401) return 'Your sign-in has ended. Sign in again to carry on.'
  if (status === 403) return 'You do not have access to this.'
  if (status === 404) return 'That list or store was not found.'
  if (status === 409) return 'That action is not possible in the current state of the list.'
  if (status === 413) return 'That file is too large.'
  if (status === 422) return 'The request could not be used.'
  if (status === 502) return 'The list failed its own check and was not shown. Try again.'
  if (status === 503) return 'The draw is not ready yet. Try again later.'
  return 'Something went wrong on our side. Try again in a moment.'
}

async function readBody(res) {
  let text = ''
  try {
    text = await res.text()
  } catch {
    return null
  }
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

function toError(res, body) {
  const message = body && typeof body.message === 'string' && body.message ? body.message : fallbackMessage(res.status)
  const code = body && typeof body.error === 'string' ? body.error : 'http_' + res.status
  return new ApiError(message, { code, status: res.status, cycleId: body && body.cycle_id })
}

async function send(method, path, { json, form } = {}) {
  const init = { method, credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' } }
  if (json !== undefined) {
    init.headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(json)
  } else if (form) {
    init.body = form
  }
  const timer = typeof AbortController === 'function' ? new AbortController() : null
  if (timer) init.signal = timer.signal
  const timeout = timer ? setTimeout(() => timer.abort(), REQUEST_TIMEOUT_MS) : null
  let res
  try {
    res = await fetch(BASE + path, init)
  } catch {
    throw new ApiError(NETWORK_MESSAGE, { code: 'network' })
  } finally {
    if (timeout) clearTimeout(timeout)
  }
  if (landedOnLogin(res)) throw signedOut()
  const body = await readBody(res)
  if (!res.ok) throw toError(res, body)
  // A 2xx that is not a JSON document is not an answer from this app. Treat it as a signed-out page.
  if (body === null || typeof body !== 'object') throw signedOut()
  return body
}

function q(params) {
  const parts = []
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)))
  }
  return parts.length ? '?' + parts.join('&') : ''
}

function cyclePath(cycleId) {
  return '/cycle/' + encodeURIComponent(String(cycleId))
}

// --- reads ---------------------------------------------------------------------------------------

export async function getOverview() {
  const body = await send('GET', '/overview')
  return Array.isArray(body && body.stores) ? body.stores : []
}

export async function getStoreState(store) {
  const body = await send('GET', '/store' + q({ store }))
  if (!body || !body.state) throw new ApiError('The stock figures did not load. Try again.', { code: 'no_state' })
  return body.state
}

export function getCycle(cycleId) {
  return send('GET', cyclePath(cycleId))
}

// { history: {cycles, by_day}, events: [...], events_limit } where events_limit is the most events
// one read returns. A read that returns that many has been cut short.
export async function getHistory(store) {
  const body = await send('GET', '/history' + q({ store }))
  const reported = Number(body && body.events_limit)
  return { ...body, events_limit: Number.isFinite(reported) && reported > 0 ? reported : EVENTS_READ_LIMIT }
}

export async function getCycleEvents(cycleId) {
  const body = await send('GET', '/events' + q({ cycle: cycleId }))
  return Array.isArray(body && body.events) ? body.events : []
}

// { app: [...], ledger: [...] }
export function getLineHistory(store, product) {
  return send('GET', '/line-history' + q({ store, product }))
}

// --- writes --------------------------------------------------------------------------------------

export function generate({ store, listType, subdept, supplier }) {
  const json = { store, list_type: listType }
  if (subdept) json.subdept = subdept
  if (supplier) json.supplier = supplier
  return send('POST', '/generate', { json })
}

// lines: [{ line_id, front, back, clear }]. Saved as TYPED.
export function captureLines(cycleId, lines) {
  return send('POST', cyclePath(cycleId) + '/capture', { json: { lines } })
}

// The page is hidden or closing. Send the typed counts with a request the browser finishes after the
// page is gone. Fire and forget: the next load compares the stored drafts with the server.
export function captureLinesKeepalive(cycleId, lines) {
  try {
    fetch(BASE + cyclePath(cycleId) + '/capture', {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
      keepalive: true,
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify({ lines }),
    }).catch(() => {})
  } catch {
    // nothing more to do: the drafts are still on the tablet
  }
}

export function uploadSheet(cycleId, file) {
  const form = new FormData()
  form.append('file', file, file.name)
  return send('POST', cyclePath(cycleId) + '/upload', { form })
}

// actions: [{ line_id, action: 'CONFIRM' | 'RECOUNT' }]
export function reviewLines(cycleId, actions) {
  return send('POST', cyclePath(cycleId) + '/review', { json: { actions } })
}

export function finalise(cycleId) {
  return send('POST', cyclePath(cycleId) + '/finalise', { json: {} })
}

export function cancelCycle(cycleId, reason) {
  const json = reason ? { reason } : {}
  return send('POST', cyclePath(cycleId) + '/cancel', { json })
}

// --- files ---------------------------------------------------------------------------------------

export function sheetUrl(cycleId) {
  return BASE + cyclePath(cycleId) + '/sheet'
}

// kind: 'TLX' or 'PLU'
export function exportUrl(cycleId, kind) {
  return BASE + cyclePath(cycleId) + '/export' + q({ kind })
}

function filenameFrom(header, fallback) {
  if (!header) return fallback
  const star = /filename\*=(?:UTF-8'')?([^;]+)/i.exec(header)
  if (star) {
    try {
      return decodeURIComponent(star[1].trim().replace(/^"|"$/g, ''))
    } catch {
      // fall through to the plain filename
    }
  }
  const plain = /filename="?([^";]+)"?/i.exec(header)
  return plain ? plain[1].trim() : fallback
}

// The TLX route reports how many of its lines hold a fraction in X-Fractional-Lines (decision D4).
function countHeader(value) {
  const t = String(value === null || value === undefined ? '' : value).trim()
  return /^\d+$/.test(t) ? Number(t) : null
}

// Fetch a file and hand it to the browser as a download. A failure shows as a plain sentence on the
// page, never as a JSON page that replaces it. Resolves { filename, fractionalLines } where
// fractionalLines is null when the route sent no such header.
export async function downloadFile(url, fallbackName) {
  let res
  try {
    res = await fetch(url, { credentials: 'same-origin', cache: 'no-store' })
  } catch {
    throw new ApiError(NETWORK_MESSAGE, { code: 'network' })
  }
  if (landedOnLogin(res)) throw signedOut()
  if (!res.ok) throw toError(res, await readBody(res))
  const type = String(res.headers.get('Content-Type') || '')
  if (/text\/html/i.test(type) || !res.headers.get('Content-Disposition')) throw signedOut()
  const blob = await res.blob()
  const filename = filenameFrom(res.headers.get('Content-Disposition'), fallbackName || 'stocktake-file')
  const href = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = href
  link.download = filename
  link.rel = 'noopener'
  document.body.appendChild(link)
  link.click()
  link.remove()
  setTimeout(() => URL.revokeObjectURL(href), 30000)
  return { filename, fractionalLines: countHeader(res.headers.get('X-Fractional-Lines')) }
}
