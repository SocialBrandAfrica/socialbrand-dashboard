// src/lib/stocktake/reasons.js
// The plain sentences behind a refused line. Pure, no imports, so the routes and the
// self-test share ONE definition.
//
// A reason is a BARE sentence. It never carries the tab or the row. The API sends those as
// their own fields (`tab`, `row`) and the page writes "BAKERY row 3: <reason>" itself.

// What rpc_stocktake_capture says when a LineId is not on the cycle. It is the one reason
// the upload route counts as an unmatched row.
export const NOT_ON_CYCLE = 'line is not on this cycle'

// Turns the text the database puts in `rejected[].reason` into a bare sentence for the page.
// Anything the database says that is not listed here becomes a generic sentence, so no raw
// database text reaches the browser.
export function dbRefusalSentence(reason) {
  const text = String(reason === null || reason === undefined ? '' : reason)
  if (text === NOT_ON_CYCLE) return 'this line is not on this list.'
  if (text === 'a count cannot be negative') return 'a count cannot be below zero.'
  // The ceiling comes from the database (config), so the number is read from its own text.
  const ceiling = /^a count above (\d[\d.]*) is not accepted/.exec(text)
  if (ceiling) return `a count above ${ceiling[1]} is not accepted. Check the box.`
  return 'the database did not accept this line.'
}

// The later of two rows that carry the same LineId. `row` and `tab` name the FIRST one.
export function duplicateLineSentence(row, tab) {
  return `this line is already on row ${row} of tab ${tab}.`
}
