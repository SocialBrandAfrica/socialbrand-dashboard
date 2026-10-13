// src/lib/stocktake/qty.js
// Pure parsers for the two kinds of number the count app reads from a person:
// a count box (Front, Back) and a line number (LineId). No imports, so the
// route handlers and the xlsx reader share ONE definition (contract section
// "Upload parse").
//
// Identifiers (EAN, PLU, product code) never pass through here. They are text
// everywhere. The only number read here as a number is the LineId, which the
// sheet carries as a number cell by contract, and it is checked to be exact.

// A count box.
//   { empty: true }          nothing typed
//   { value: <number> }      a count of zero or more
//   { bad: '<fragment>' }    refused, the fragment finishes the sentence
//                            "... holds "x", which <fragment>."
export function parseQty(raw) {
  if (raw === null || raw === undefined) return { empty: true }

  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) return { bad: 'is not a number' }
    if (raw < 0) return { bad: 'is below zero' }
    return { value: raw }
  }

  if (typeof raw === 'string') {
    let s = raw.trim()
    if (s === '') return { empty: true }
    // A decimal comma ("2,5") is read as a decimal point. Nothing else is repaired.
    if (/^\d+,\d+$/.test(s)) s = s.replace(',', '.')
    if (/^-\s*\d/.test(s)) return { bad: 'is below zero' }
    if (!/^\d+(\.\d+)?$/.test(s)) return { bad: 'is not a number' }
    const n = Number(s)
    if (!Number.isFinite(n)) return { bad: 'is not a number' }
    return { value: n }
  }

  return { bad: 'is not a number' }
}

// A line number.
//   { none: true }           nothing usable (blank, text): the row is skipped
//   { id: <safe integer> }   a whole, positive, exact number
//   { bad: '<sentence>' }    a number that cannot be a line number
export function parseLineId(raw) {
  if (raw === null || raw === undefined) return { none: true }

  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) return { none: true }
    if (!Number.isSafeInteger(raw) || raw <= 0) {
      return { bad: 'The LineId is not a whole positive number.' }
    }
    return { id: raw }
  }

  if (typeof raw === 'string') {
    const s = raw.trim()
    if (!/^\d+$/.test(s)) return { none: true }
    const n = Number(s)
    const plain = s.replace(/^0+(?=\d)/, '')
    if (!Number.isSafeInteger(n) || n <= 0 || String(n) !== plain) {
      return { bad: 'The LineId is not a whole positive number.' }
    }
    return { id: n }
  }

  return { none: true }
}
