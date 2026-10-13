// Typed counts that the server has not confirmed yet, kept on the tablet.
//
// A refresh, an app switch or a dropped connection must lose nothing. The save queue writes the
// unsaved boxes of the open list here on every change: { lineId: text }, one key per list. A draft
// leaves the store only when the server confirmed that exact text (the queue does that), when the
// line is sent for a recount, or when the list is closed.
//
// Storage can be blocked (private mode, a policy) or full. Every call is wrapped, and the page works
// the same without it. Every function takes an optional storage so the render test runs without a
// browser.
import { parseCountText } from './components/format'

const PREFIX = 'stocktake-drafts:'

export function draftKey(cycleId) {
  return PREFIX + String(cycleId)
}

function browserStorage() {
  try {
    if (typeof window !== 'undefined' && window.localStorage) return window.localStorage
  } catch {
    // reading window.localStorage itself throws when site data is blocked
  }
  return null
}

function pick(storage) {
  return storage === undefined ? browserStorage() : storage
}

// { lineId: text } of the list, or {} when nothing is stored or storage is blocked.
export function readDrafts(cycleId, storage) {
  const s = pick(storage)
  if (!s || !cycleId) return {}
  try {
    const raw = s.getItem(draftKey(cycleId))
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    const out = {}
    for (const [id, text] of Object.entries(parsed)) {
      if (/^\d+$/.test(id) && typeof text === 'string') out[id] = text
    }
    return out
  } catch {
    return {}
  }
}

// Replace the stored drafts of the list. An empty map removes the key. Returns true when it wrote.
export function writeDrafts(cycleId, drafts, storage) {
  const s = pick(storage)
  if (!s || !cycleId) return false
  try {
    if (!drafts || Object.keys(drafts).length === 0) s.removeItem(draftKey(cycleId))
    else s.setItem(draftKey(cycleId), JSON.stringify(drafts))
    return true
  } catch {
    return false
  }
}

export function clearDrafts(cycleId, storage) {
  return writeDrafts(cycleId, {}, storage)
}

// Which stored drafts still need to reach the server. A draft for a line that is not on the list
// is dropped. So is a draft whose number the server already holds (an empty box that the server
// already shows as blank counts the same way). Text that is not a number stays, so the box shows
// the problem to the person who typed it.
export function draftsToReplay(stored, lines) {
  const byId = new Map((Array.isArray(lines) ? lines : []).map((l) => [String(l.line_id), l]))
  const keep = {}
  for (const [id, text] of Object.entries(stored || {})) {
    const line = byId.get(String(id))
    if (!line) continue
    const number = parseCountText(text)
    if (number !== undefined) {
      const held = line.count_qty !== null && line.count_qty !== undefined
      const same = number === null ? !held : held && Number(line.count_qty) === number
      if (same) continue
    }
    keep[id] = text
  }
  return keep
}
