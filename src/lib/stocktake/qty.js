// src/lib/stocktake/qty.js
// Pure parsers for the two kinds of number the count app reads from a person:
// a count box (Front, Back) and a line number (LineId). No imports, so the
// route handlers and the xlsx reader share ONE definition (contract section
// "Upload parse").
//
// Identifiers (EAN, PLU, product code) never pass through here. They are text
// everywhere. The only number read here as a number is the LineId, which the
// sheet carries as a number cell by contract, and it is checked to be exact.

// The refusal for a comma followed by exactly three digits ("1,200"). A person who types it
// means 1200 (a thousands comma) or 1.2 (a decimal comma) and nothing here knows which, so
// nothing is guessed. The same sentence is shown by the count page (components/format.js).
export const THOUSANDS_COMMA_SENTENCE = 'Enter 1200 or 1.2, not 1,200.'

// A count box.
//   { empty: true }          nothing typed
//   { value: <number> }      a count of zero or more
//   { bad: '<fragment>' }    refused, the fragment finishes the sentence
//                            "... holds "x", which <fragment>."
//   { bad: '<fragment>', refusal: '<sentence>' }
//                            refused, and the whole sentence to show is in `refusal`.
//                            A caller that does not know `refusal` still sees `bad`
//                            and refuses the value.
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
    // Exactly three digits after a single comma is ambiguous, so it is refused.
    if (/^\d+,\d{3}$/.test(s)) return { bad: 'has a comma that reads two ways', refusal: THOUSANDS_COMMA_SENTENCE }
    // Any other decimal comma ("2,5", "12,75") is read as a decimal point. Nothing else is repaired.
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
//   { bad: '<sentence>' }    a number that cannot be a line number (a bare reason, no tab or row)
export function parseLineId(raw) {
  if (raw === null || raw === undefined) return { none: true }

  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) return { none: true }
    if (!Number.isSafeInteger(raw) || raw <= 0) {
      return { bad: 'the LineId is not a whole positive number.' }
    }
    return { id: raw }
  }

  if (typeof raw === 'string') {
    const s = raw.trim()
    if (!/^\d+$/.test(s)) return { none: true }
    const n = Number(s)
    const plain = s.replace(/^0+(?=\d)/, '')
    if (!Number.isSafeInteger(n) || n <= 0 || String(n) !== plain) {
      return { bad: 'the LineId is not a whole positive number.' }
    }
    return { id: n }
  }

  return { none: true }
}
