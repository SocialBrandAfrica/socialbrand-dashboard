// "Saved as typed": the count boxes save one line at a time, in order, 600 ms after the last key
// and at once on blur. A framework-free module so the page and the render test run the same code.
//
//   an empty box           -> { line_id, clear: true }
//   0                      -> { line_id, front: 0, back: 0 }   (0 is a real count)
//   12 or 12,5 or 12.5     -> { line_id, front: 12.5, back: 0 }
//   2. or 2,               -> a number still being typed: waits for the blur, no error until then
//   anything else          -> never sent, the row shows a plain error and keeps what was typed
//
// A draft leaves the screen only when the server confirmed that exact text. A newer draft typed
// while a save runs stays and saves next. A failed save keeps its draft and its error until the
// user tries again, the connection returns, or the text changes.
//
// Every draft is also written to the tablet (options.persist) so a refresh, an app switch or a
// dropped connection loses nothing. restore() puts stored drafts back into the queue when the list
// opens. flushKeepalive() sends every valid draft with a request that outlives the page.
import { countTextProblem, isUnfinishedNumber, parseCountText } from './components/format'

export const SAVE_DELAY_MS = 600

function sentence(text) {
  const t = String(text || '').trim()
  if (!t) return ''
  const cap = t.charAt(0).toUpperCase() + t.slice(1)
  return /[.!?]$/.test(cap) ? cap : cap + '.'
}

function lineFor(lineId, number) {
  return number === null ? { line_id: lineId, clear: true } : { line_id: lineId, front: number, back: 0 }
}

// options:
//   send(cycleId, lines)  -> Promise of the capture result { set, unchanged, rejected, blank, saved_at }
//   getCycleId()          -> the cycle the boxes belong to right now
//   on                    -> { drafts(map), row(lineId, state|null), status('idle'|'saving'|'error'),
//                              saved({ lineId, number, applied, savedAt }), failed(error) }
//   persist               -> { save(cycleId, draftsMap) } called on every change of the drafts, never on reset
//   sendKeepalive(cycleId, lines) -> fire and forget, used when the page is hidden or closing
//   setTimer, clearTimer  -> injectable for tests
export function createSaveQueue(options) {
  const { send, getCycleId } = options
  const on = options.on || {}
  const persist = options.persist || null
  const sendKeepalive = options.sendKeepalive || null
  const setTimer = options.setTimer || ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = options.clearTimer || ((h) => clearTimeout(h))
  const delay = options.delay === undefined ? SAVE_DELAY_MS : options.delay

  let drafts = {}
  let chain = Promise.resolve()
  let inflight = 0
  let epoch = 0
  const timers = new Map()
  const errors = new Set()
  // Boxes whose timer ran out while the text was an unfinished number. The blur sends them.
  const held = new Set()

  function emitDrafts() {
    if (on.drafts) on.drafts(drafts)
  }
  function row(lineId, state) {
    if (on.row) on.row(lineId, state)
  }
  function status() {
    if (errors.size > 0) return 'error'
    if (Object.keys(drafts).length > 0 || inflight > 0) return 'saving'
    return 'idle'
  }
  function emitStatus() {
    if (on.status) on.status(status())
  }
  function keep(cycleId) {
    if (!persist || !cycleId) return
    try {
      persist.save(cycleId, drafts)
    } catch {
      // the tablet's storage is blocked or full: the page works without it
    }
  }
  function setDrafts(next) {
    drafts = next
    emitDrafts()
  }
  function removeDraft(lineId) {
    if (drafts[lineId] === undefined) return
    const next = { ...drafts }
    delete next[lineId]
    setDrafts(next)
  }

  async function save(lineId) {
    const cycleId = getCycleId()
    const text = drafts[lineId]
    if (!cycleId || text === undefined) return
    const number = parseCountText(text)
    if (number === undefined) {
      errors.add(lineId)
      row(lineId, { state: 'error', message: countTextProblem(text) })
      emitStatus()
      return
    }
    const line = lineFor(lineId, number)
    const started = epoch
    inflight += 1
    row(lineId, { state: 'saving' })
    emitStatus()
    try {
      const res = await send(cycleId, [line])
      const rejected = res && Array.isArray(res.rejected) ? res.rejected : []
      if (rejected.length > 0) {
        if (started !== epoch) return
        errors.add(lineId)
        row(lineId, { state: 'error', message: 'Not saved. ' + sentence(rejected[0].reason) })
        return
      }
      errors.delete(lineId)
      if (started !== epoch || getCycleId() !== cycleId) return
      const applied = drafts[lineId] === text
      if (applied) {
        removeDraft(lineId)
        keep(cycleId)
      }
      row(lineId, null)
      if (on.saved) on.saved({ lineId, number, applied, savedAt: res && res.saved_at ? res.saved_at : null })
    } catch (e) {
      if (started === epoch) {
        errors.add(lineId)
        row(lineId, { state: 'error', message: 'Not saved.' })
        if (on.failed) on.failed(e)
      }
    } finally {
      inflight -= 1
      emitStatus()
    }
  }

  function enqueue(lineId) {
    held.delete(lineId)
    chain = chain.then(() => save(lineId)).catch(() => {})
    return chain
  }

  function clearTimerFor(lineId) {
    if (!timers.has(lineId)) return false
    clearTimer(timers.get(lineId))
    timers.delete(lineId)
    return true
  }

  return {
    // The box text changed.
    change(lineId, text) {
      setDrafts({ ...drafts, [lineId]: text })
      keep(getCycleId())
      errors.delete(lineId)
      held.delete(lineId)
      row(lineId, null)
      clearTimerFor(lineId)
      timers.set(
        lineId,
        setTimer(() => {
          timers.delete(lineId)
          if (isUnfinishedNumber(drafts[lineId])) {
            // Still being typed. No error, no send. The blur decides.
            held.add(lineId)
            emitStatus()
            return
          }
          enqueue(lineId)
        }, delay)
      )
      emitStatus()
    },
    // The box lost focus: send what is waiting now.
    blur(lineId) {
      const waiting = clearTimerFor(lineId)
      const heldBack = held.delete(lineId)
      if (waiting || heldBack) enqueue(lineId)
    },
    retry(lineId) {
      errors.delete(lineId)
      enqueue(lineId)
    },
    // The connection came back: try every failed line again.
    retryErrors() {
      for (const id of Array.from(errors)) {
        errors.delete(id)
        enqueue(id)
      }
    },
    // Send everything typed and wait. Resolves true when nothing typed is left unsaved.
    async flushAll() {
      for (const id of Array.from(timers.keys())) clearTimerFor(id)
      for (const key of Object.keys(drafts)) enqueue(Number(key))
      await chain
      return Object.keys(drafts).length === 0
    },
    // Put drafts read from the tablet back into the queue and send them. A box typed since wins
    // over a stored one. Returns how many boxes came back.
    restore(stored) {
      const next = { ...drafts }
      const ids = []
      for (const [key, text] of Object.entries(stored || {})) {
        const id = Number(key)
        if (next[id] !== undefined) continue
        next[id] = text
        ids.push(id)
      }
      if (ids.length === 0) return 0
      setDrafts(next)
      keep(getCycleId())
      emitStatus()
      for (const id of ids) enqueue(id)
      return ids.length
    },
    // The page is hidden or closing: send every valid draft in one request that outlives the page.
    // The drafts stay where they are. The next load compares them with the server and drops what it holds.
    flushKeepalive() {
      const cycleId = getCycleId()
      if (!cycleId || !sendKeepalive) return false
      const lines = []
      for (const [key, text] of Object.entries(drafts)) {
        const number = parseCountText(text)
        if (number !== undefined) lines.push(lineFor(Number(key), number))
      }
      if (lines.length === 0) return false
      sendKeepalive(cycleId, lines)
      return true
    },
    // Forget a box without saving it (the line was sent for a recount).
    discard(lineId) {
      clearTimerFor(lineId)
      held.delete(lineId)
      errors.delete(lineId)
      removeDraft(lineId)
      keep(getCycleId())
      row(lineId, null)
      emitStatus()
    },
    // The list changed: drop every draft, timer and error from the screen. The tablet keeps its copy.
    reset() {
      epoch += 1
      for (const id of Array.from(timers.keys())) clearTimerFor(id)
      held.clear()
      errors.clear()
      setDrafts({})
      emitStatus()
    },
    drafts() {
      return drafts
    },
    // True while a box is waiting to send or a save is running.
    isBusy() {
      return timers.size > 0 || inflight > 0
    },
    hasErrors() {
      return errors.size > 0
    },
  }
}
