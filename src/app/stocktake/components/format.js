// Pure display helpers for the stocktake page. No imports, no API, no config values.
// Every figure shown on the page is a number the database returned. These helpers only
// choose how it is written down. Identifiers (EAN, PLU, product code) never pass through
// here as numbers: they are rendered as the text they arrive as.

const TZ = 'Africa/Johannesburg'
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const DAYS_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

const intFmt = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })
const qtyFmt = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 })
const randFmt = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const pctFmt = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })
const zoneFmt = new Intl.DateTimeFormat('en-GB', {
  timeZone: TZ,
  year: 'numeric',
  month: 'numeric',
  day: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
})

function isNum(n) {
  return n !== null && n !== undefined && n !== '' && Number.isFinite(Number(n))
}

export function plural(n, one, many) {
  return Number(n) === 1 ? one : many
}

// 5930 -> "5,930"
export function fmtInt(n) {
  return isNum(n) ? intFmt.format(Number(n)) : ''
}

// A stock or count quantity: up to three decimals, no trailing zeros.
export function fmtQty(n) {
  return isNum(n) ? qtyFmt.format(Number(n)) : ''
}

// The text a count box holds: no grouping, no trailing zeros.
export function qtyText(n) {
  return isNum(n) ? String(Number(n)) : ''
}

// +3, -4, 0
export function fmtSigned(n) {
  if (!isNum(n)) return ''
  const v = Number(n)
  if (v > 0) return '+' + qtyFmt.format(v)
  return qtyFmt.format(v)
}

// 1234.5 -> "R1,234.50", -120 -> "-R120.00"
export function fmtRand(n) {
  if (!isNum(n)) return 'no cost on file'
  const v = Number(n)
  const body = 'R' + randFmt.format(Math.abs(v))
  return v < 0 && Math.abs(v) >= 0.005 ? '-' + body : body
}

// -33.333 -> "-33.3%"
export function fmtPct(n) {
  if (!isNum(n)) return 'n/a'
  return pctFmt.format(Number(n)) + '%'
}

function zoneParts(iso) {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const o = {}
  for (const p of zoneFmt.formatToParts(d)) o[p.type] = p.value
  return { year: Number(o.year), month: Number(o.month), day: Number(o.day), hour: o.hour, minute: o.minute }
}

// "14:07" in store time (South Africa).
export function fmtTime(iso) {
  const p = zoneParts(iso)
  return p ? p.hour + ':' + p.minute : ''
}

// "13 Oct 14:07"
export function fmtDateTime(iso) {
  const p = zoneParts(iso)
  return p ? p.day + ' ' + MONTHS[p.month - 1] + ' ' + p.hour + ':' + p.minute : ''
}

// The store-local calendar day of a timestamp: "2026-10-13"
export function dayOf(iso) {
  const p = zoneParts(iso)
  if (!p) return ''
  const mm = String(p.month).padStart(2, '0')
  const dd = String(p.day).padStart(2, '0')
  return p.year + '-' + mm + '-' + dd
}

function utcDate(day) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(day || ''))
  if (!m) return null
  return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])))
}

// "2026-10-13" -> "Tue 13 Oct"
export function fmtDay(day) {
  const d = utcDate(day)
  if (!d) return ''
  return DAYS_SHORT[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()]
}

// "2026-10-13" -> "Tuesday"
export function weekdayName(day) {
  const d = utcDate(day)
  return d ? DAYS[d.getUTCDay()] : ''
}

// "Draw stocked 05:30" on the day it was stocked, "Draw stocked 12 Oct 05:30" on any other day.
export function fmtStocked(iso, today) {
  if (!iso) return ''
  return dayOf(iso) === today ? fmtTime(iso) : fmtDateTime(iso)
}

export function listName(c) {
  switch (c && c.list_type) {
    case 'DAILY':
      return 'Daily list'
    case 'CONFIRM':
      return 'Confirmation count'
    case 'ADHOC':
      return c.subdept_name ? 'Batch (' + c.subdept_name + ')' : 'Batch'
    case 'PLU':
      return 'PLU and scale list'
    default:
      return c && c.list_type ? String(c.list_type) : 'List'
  }
}

export function statusName(status) {
  switch (status) {
    case 'PENDING_CAPTURE':
      return 'Awaiting capture'
    case 'CAPTURING':
      return 'Capturing'
    case 'FINALISED':
      return 'Finalised'
    case 'CANCELLED':
      return 'Cancelled'
    default:
      return status || ''
  }
}

// "weekend" -> "weekend days", "DC delivery day" -> "DC delivery days"
export function restReasonDays(reason) {
  const r = String(reason || 'rest')
  return /day$/i.test(r) ? r + 's' : r + ' days'
}

// The count window comes from the data, never from the code: a pool object that carries
// count_window_days wins, otherwise the number sits in the name of its counted_NN field.
export function countWindowDays(pool) {
  if (!pool) return null
  if (isNum(pool.count_window_days)) return Number(pool.count_window_days)
  for (const k of Object.keys(pool)) {
    const m = /^counted_(\d+)$/.exec(k)
    if (m) return Number(m[1])
  }
  return null
}

const EVENT_NAMES = {
  GENERATE: 'Generated',
  DOWNLOAD: 'Downloaded',
  UPLOAD: 'Uploaded',
  EDIT: 'Edited',
  RECOUNT: 'Recount',
  CONFIRM: 'Confirmed',
  FINALISE: 'Finalised',
  EXPORT_TLX: 'TLX export',
  EXPORT_PLU: 'PLU export',
  CANCEL: 'Cancelled',
}

export function eventName(type) {
  return EVENT_NAMES[type] || String(type || '')
}

function nOf(v, one, many) {
  return fmtInt(v) + ' ' + plural(v, one, many)
}

// One plain sentence per event, built only from the fields the database logged.
export function describeEvent(e) {
  const d = (e && e.detail) || {}
  switch (e && e.event_type) {
    case 'GENERATE': {
      const name = listName({ list_type: d.list_type, subdept_name: d.subdept })
      return 'Generated a ' + name.toLowerCase() + ' of ' + nOf(d.lines, 'line', 'lines') + '.'
    }
    case 'DOWNLOAD': {
      const tabs = isNum(d.tabs) ? ' on ' + nOf(d.tabs, 'tab', 'tabs') : ''
      const lines = isNum(d.lines) ? ' (' + nOf(d.lines, 'line', 'lines') + tabs + ')' : ''
      return 'Downloaded the count sheets' + lines + '.'
    }
    case 'UPLOAD':
      return (
        'Uploaded a filled sheet: ' +
        fmtInt(d.lines_set) +
        ' set, ' +
        fmtInt(d.unchanged) +
        ' unchanged, ' +
        fmtInt(d.rejected) +
        ' skipped.'
      )
    case 'EDIT': {
      const code = d.product_code != null ? String(d.product_code) : 'a line'
      if (d.to === null || d.to === undefined) return 'Cleared the count of ' + code + '.'
      if (d.from === null || d.from === undefined) return 'Set the count of ' + code + ' to ' + fmtQty(d.to) + '.'
      return 'Changed the count of ' + code + ' from ' + fmtQty(d.from) + ' to ' + fmtQty(d.to) + '.'
    }
    case 'RECOUNT': {
      const code = d.product_code != null ? String(d.product_code) : 'a line'
      const was = isNum(d.prior_count) ? ' The count was ' + fmtQty(d.prior_count) + '.' : ''
      return 'Sent ' + code + ' for a recount.' + was
    }
    case 'CONFIRM': {
      const code = d.product_code != null ? String(d.product_code) : 'a line'
      const v = isNum(d.variance_qty) ? ' Variance ' + fmtSigned(d.variance_qty) + '.' : ''
      return 'Confirmed the count of ' + code + ' at ' + fmtQty(d.count) + '.' + v
    }
    case 'FINALISE':
      return (
        'Finalised the list of ' +
        nOf(d.lines, 'line', 'lines') +
        '. ' +
        fmtInt(d.tlx_lines) +
        ' for the TLX and ' +
        fmtInt(d.manual_lines) +
        ' for the PLU and scale sheet.'
      )
    case 'EXPORT_TLX':
      return 'Exported the TLX file with ' + nOf(d.line_count, 'line', 'lines') + '.'
    case 'EXPORT_PLU':
      return 'Exported the PLU and scale sheet with ' + nOf(d.line_count, 'line', 'lines') + '.'
    case 'CANCEL':
      return d.reason ? 'Cancelled the list. Reason: ' + d.reason + '.' : 'Cancelled the list.'
    default:
      return ''
  }
}

// A count box accepts digits with one decimal point or comma. Returns the number, null for an
// empty box, or undefined when the text is not a count.
export function parseCountText(text) {
  const t = String(text === undefined || text === null ? '' : text).trim()
  if (t === '') return null
  const norm = /^\d+,\d+$/.test(t) ? t.replace(',', '.') : t
  if (!/^\d+(\.\d+)?$/.test(norm)) return undefined
  return Number(norm)
}
