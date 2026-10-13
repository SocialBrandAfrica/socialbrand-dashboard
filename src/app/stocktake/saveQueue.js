// "Saved as typed": the count boxes save one line at a time, in order, 600 ms after the last key
// and at once on blur. A framework-free module so the page and the render test run the same code.
//
//   an empty box           -> { line_id, clear: true }
//   0                      -> { line_id, front: 0, back: 0 }   (0 is a real count)
//   12 or 12,5 or 12.5     -> { line_id, front: 12.5, back: 0 }
//   anything else          -> never sent, the row shows a plain error and keeps what was typed
//
// A draft leaves the screen only when the server confirmed that exact text. A newer draft typed
// while a save runs stays and saves next. A failed save keeps its draft and its error until the
// user tries again, the connection returns, or the text changes.
import { parseCountText } from './components/format'

export const SAVE_DELAY_MS = 600

const NOT_A_NUMBER = 'Enter a number such as 12 or 3.5.'

function sentence(text) {
  const t = String(text || '').trim()
  if (!t) return ''
  const cap = t.charAt(0).toUpperCase() + t.slice(1)
  return /[.!?]$/.test(cap) ? cap : cap + '.'
}

// options:
//   send(cycleId, lines)  -> Promise of the capture result { set, unchanged, rejected, blank, saved_at }
//   getCycleId()          -> the cycle the boxes belong to right now
//   on                    -> { drafts(map), row(lineId, state|null), status('idle'|'saving'|'error'),
//                              saved({ lineId, number, applied, savedAt }), failed(error) }
//   setTimer, clearTimer  -> injectable for tests
export function createSaveQueue(options) {
  const { send, getCycleId } = options
  const on = options.on || {}
  const setTimer = options.setTimer || ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = options.clearTimer || ((h) => clearTimeout(h))
  const delay = options.delay === undefined ? SAVE_DELAY_MS : options.delay

  let drafts = {}
  let chain = Promise.resolve()
  let inflight = 0
  let epoch = 0
  const timers = new Map()
  const errors = new Set()

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
      row(lineId, { state: 'error', message: NOT_A_NUMBER })
      emitStatus()
      return
    }
    const line = number === null ? { line_id: lineId, clear: true } : { line_id: lineId, front: number, back: 0 }
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
      if (applied) removeDraft(lineId)
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
      errors.delete(lineId)
      row(lineId, null)
      clearTimerFor(lineId)
      timers.set(
        lineId,
        setTimer(() => {
          timers.delete(lineId)
          enqueue(lineId)
        }, delay)
      )
      emitStatus()
    },
    // The box lost focus: send what is waiting now.
    blur(lineId) {
      if (clearTimerFor(lineId)) enqueue(lineId)
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
    // Forget a box without saving it (the line was sent for a recount).
    discard(lineId) {
      clearTimerFor(lineId)
      errors.delete(lineId)
      removeDraft(lineId)
      row(lineId, null)
      emitStatus()
    },
    // The list changed: drop every draft, timer and error.
    reset() {
      epoch += 1
      for (const id of Array.from(timers.keys())) clearTimerFor(id)
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
