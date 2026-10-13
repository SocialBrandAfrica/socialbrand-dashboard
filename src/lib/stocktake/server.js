// src/lib/stocktake/server.js
// Server-side plumbing for the stocktake count app's API routes (SB-CC-STOCKTAKE-001, ENG-241).
//
// Every route here calls the count app's published rpc_stocktake_* functions AS THE SIGNED-IN USER:
// the cookie session and the anon key, the same pattern as src/app/api/forge/run/route.js. The
// service-role key is never used and no table is read or written from here (R30 addendum 2: apps
// write only through published SECURITY DEFINER functions, and the grant is `authenticated` only).
//
// Errors leave this file as { error: <code>, message: <plain sentence> } and nothing else. A
// database raise text is matched to a code and a sentence written here. The raw text is never sent
// back, so no SQL, table name or row value reaches the browser.

import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'

// The upload ceiling is part of the contract (5 MB). Multipart framing adds a little to the
// declared request size, so the early check on Content-Length allows for it.
export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024
export const MULTIPART_SLACK_BYTES = 64 * 1024

// Request size caps. A request over a cap is refused with a 400 and a plain sentence.
export const MAX_CAPTURE_LINES = 2000
export const MAX_REVIEW_ACTIONS = 2000
export const MAX_CANCEL_REASON = 300

// How much history the page reads. The events function clamps its limit at 1000 itself.
export const HISTORY_CYCLE_LIMIT = 60
export const EVENT_LIMIT = 1000

const NO_STORE = { 'Cache-Control': 'no-store' }
const SERVER_ERROR_TEXT = 'Something went wrong on our side. Try again in a moment.'
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// ---------------------------------------------------------------- the typed error

export class StocktakeError extends Error {
  constructor(code, status, message, extra) {
    super(message)
    this.name = 'StocktakeError'
    this.code = code
    this.status = status
    this.extra = extra || null
  }
}

const LIST_WORD = { DAILY: 'daily', CONFIRM: 'confirmation', ADHOC: 'batch', SUPPLIER: 'supplier', PLU: 'PLU and scale' }

// The database raise texts the contract lists, matched by their stable front part.
function mapRaise(text) {
  let m = /^open_cycle_exists:([0-9a-f-]{36})/i.exec(text)
  if (m) {
    return new StocktakeError('open_cycle_exists', 409,
      'A list of this type is already open for this store. Open that list instead.', { cycle_id: m[1] })
  }
  m = /^nothing_to_count:([A-Z]+)/.exec(text)
  if (m) {
    const word = LIST_WORD[m[1]] || 'this'
    return new StocktakeError('nothing_to_count', 422, `No lines are left for a ${word} list right now.`)
  }
  if (text.startsWith('draw_not_built:')) {
    return new StocktakeError('draw_not_built', 503,
      'The stock draw for this store is not ready yet. Try again after the nightly run.')
  }
  m = /^cycle_closed:([A-Z_]+)/.exec(text)
  if (m) {
    const how = m[1] === 'CANCELLED' ? 'was cancelled' : 'is already finalised'
    return new StocktakeError('cycle_closed', 409, `This list ${how}. It no longer changes.`)
  }
  if (text.startsWith('cycle_not_finalised:')) {
    return new StocktakeError('cycle_not_finalised', 409, 'Finalise this list before you export it.')
  }
  if (text.startsWith('tlx_count_mismatch')) {
    return new StocktakeError('tripwire', 500,
      'The export did not pass its line count check, so no file was made. Tell SocialBrand support.')
  }
  if (text === 'no_tlx_lines') {
    return new StocktakeError('no_tlx_lines', 422, 'This list has no lines for a TLX file.')
  }
  if (text.startsWith('unknown cycle')) {
    return new StocktakeError('unknown_cycle', 404, 'That list was not found.')
  }
  if (text.startsWith('unknown or inactive store')) {
    return new StocktakeError('unknown_store', 404, 'That store was not found.')
  }
  if (text.startsWith('a supplier count needs a supplier')) {
    return new StocktakeError('supplier_required', 422, 'A supplier count needs a supplier. Pick one and try again.')
  }
  if (text.startsWith('unknown_supplier:')) {
    return new StocktakeError('unknown_supplier', 404, 'That supplier has no received products at this store.')
  }
  if (text.startsWith('an ad hoc batch needs a sub-department')) {
    return new StocktakeError('subdept_required', 422, 'A batch needs a sub-department. Pick one and try again.')
  }
  return null
}

// PostgREST puts the raise text in error.message. Anything not matched is a server error with a
// generic sentence. Only the function name and the error code are logged, never the text or a row.
export function mapRpcError(error, httpStatus, rpcName) {
  const text = String((error && error.message) || '')
  if (text === 'not authenticated' || (error && error.code === '28000') || httpStatus === 401) {
    return new StocktakeError('not authenticated', 401, 'Sign in again to continue.')
  }
  const mapped = mapRaise(text)
  if (mapped) return mapped
  console.error('stocktake rpc failed:', rpcName, (error && error.code) || httpStatus || 'no code')
  return new StocktakeError('server_error', 500, SERVER_ERROR_TEXT)
}

// ---------------------------------------------------------------- the session

export function serverClient() {
  const cookieStore = cookies()
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() { return cookieStore.getAll() },
        setAll(cookiesToSet) {
          // A session refresh may set cookies. Where the store is read-only, skip quietly.
          try {
            cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options))
          } catch {
            /* read-only cookie store */
          }
        },
      },
    }
  )
}

// Calls one rpc as the signed-in user. Returns { data } or throws a StocktakeError.
// Pass the request's own client so one request holds one session.
export async function callRpc(name, args, supabase) {
  const client = supabase || serverClient()
  const { data, error, status } = await client.rpc(name, args || {})
  if (error) throw mapRpcError(error, status, name)
  return { data }
}

// Belt for the middleware's gate: no user, no call. Returns the client, the user and an rpc
// function bound to that client.
export async function requireUser() {
  const supabase = serverClient()
  const { data } = await supabase.auth.getUser()
  const user = data && data.user
  if (!user) throw new StocktakeError('not authenticated', 401, 'Sign in to use the stocktake page.')
  return { supabase, user, rpc: (name, args) => callRpc(name, args, supabase) }
}

// ---------------------------------------------------------------- responses

export function json(data, status = 200, headers) {
  return NextResponse.json(data, { status: status, headers: { ...NO_STORE, ...(headers || {}) } })
}

export function errorResponse(err) {
  if (err instanceof StocktakeError) {
    // Extra fields (cycle_id on a 409) go first so they can never replace error or message.
    return NextResponse.json(
      { ...(err.extra || {}), error: err.code, message: err.message },
      { status: err.status, headers: NO_STORE }
    )
  }
  console.error('stocktake route failed:', (err && err.name) || 'unknown')
  return NextResponse.json(
    { error: 'server_error', message: SERVER_ERROR_TEXT },
    { status: 500, headers: NO_STORE }
  )
}

// Wraps a route handler so a thrown StocktakeError or anything else becomes the error body.
export function route(handler) {
  return async (request, context) => {
    try {
      return await handler(request, context)
    } catch (err) {
      return errorResponse(err)
    }
  }
}

// A file response (xlsx or tlx). The body goes out untouched. `extraHeaders` adds headers
// beside the file ones and never replaces them.
export function fileResponse(body, contentType, filename, extraHeaders) {
  return new NextResponse(body, {
    status: 200,
    headers: {
      ...(extraHeaders || {}),
      'Content-Type': contentType,
      'Content-Disposition': `attachment; filename="${safeFilename(filename)}"`,
      ...NO_STORE,
    },
  })
}

// Header-safe file name: letters, digits, dot, dash and underscore only.
export function safeFilename(name) {
  return String(name || 'stocktake').replace(/[^A-Za-z0-9._-]+/g, '_')
}

// ---------------------------------------------------------------- input checks

const bad = (message) => new StocktakeError('bad_request', 400, message)

export function cycleIdParam(value) {
  const id = String(value || '')
  if (!UUID_RE.test(id)) throw bad('That list id is not valid.')
  return id
}

// A store code is text. It is never turned into a number.
export function storeParam(value) {
  const code = String(value || '').trim()
  if (!/^[A-Za-z0-9_-]{1,32}$/.test(code)) throw bad('Name a store.')
  return code
}

// A product code is a whole number kept as text and cast by the database.
export function productParam(value) {
  const code = String(value || '').trim()
  if (!/^\d{1,18}$/.test(code)) throw bad('Name a product code made of digits.')
  return code
}

// Reads a request body as a stream with a running byte count and stops at `limit`. A body
// with no Content-Length (chunked) is held to the same limit as one that declares its size.
// `refuse` builds the error thrown when the limit is passed. Returns a Buffer.
export async function readBoundedBody(request, limit, refuse) {
  if (!request.body) return Buffer.alloc(0)
  const reader = request.body.getReader()
  const chunks = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > limit) {
      try {
        await reader.cancel()
      } catch {
        /* the stream is already closed */
      }
      throw refuse()
    }
    chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength))
  }
  return Buffer.concat(chunks, total)
}

export async function readJsonObject(request) {
  let body
  try {
    body = await request.json()
  } catch {
    throw bad('Send the request as JSON.')
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw bad('Send the request as a JSON object.')
  return body
}

// The one-document tripwire (contract rule 4): the lines served must be the lines the cycle holds.
export function assertWholeCycle(doc) {
  const whole = doc && doc.cycle && Array.isArray(doc.lines)
    && doc.served === doc.line_count && doc.lines.length === doc.line_count
  if (!whole) {
    throw new StocktakeError('tripwire', 502,
      'The list did not load in full, so it was not used. Reload the page. If it happens again tell SocialBrand support.')
  }
  return doc
}
