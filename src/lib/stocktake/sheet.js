// src/lib/stocktake/sheet.js
// The count sheet (xlsx) and the PLU and scale sheet, built and read with exceljs.
//
// SHAPE IS FIXED by Pieter's own sheet (countsheets_2026-10-13.xlsx) and the build
// contract (SB-CC-STOCKTAKE-001 v1.2, ENG-241):
//   one tab per department, columns A..G = LineId (hidden), EAN, Description, Size,
//   System Stock, Front, Back. Header bold on E0E0E0 with thin borders, data rows 28
//   high with thin borders, A4 landscape fit to one page wide, row 1 repeats on every
//   printed page and stays frozen.
//
// Identifiers are TEXT end to end. The EAN column is a string cell with number format
// "@". Nothing here runs an identifier through Number or a float. The one number read
// as a number is the LineId, which is a number cell by contract and is checked exact.
//
// This file imports only exceljs and ./qty.js (with the extension) so the self-test
// script can load it straight from Node.

import ExcelJS from 'exceljs'
import { parseLineId, parseQty } from './qty.js'

const HEADER_FILL = 'FFE0E0E0'
const THIN = { style: 'thin' }
const BORDER = { top: THIN, left: THIN, bottom: THIN, right: THIN }
const ROW_HEIGHT = 28
const PAPER_A4 = 9
const SHEET_NAME_MAX = 31
const HEADER_SCAN_ROWS = 10
const OTHER_TAB = 'Other'
const PLU_TAB = 'PLU and scale'

export const COUNT_COLUMNS = [
  { key: 'line_id', header: 'LineId', width: 8, hidden: true },
  { key: 'identifier', header: 'EAN', width: 15 },
  { key: 'description', header: 'Description', width: 45 },
  { key: 'size', header: 'Size', width: 12 },
  { key: 'system_stock', header: 'System Stock', width: 12 },
  { key: 'front', header: 'Front', width: 10 },
  { key: 'back', header: 'Back', width: 10 },
]
export const PLU_HEADER = 'PLU / Code'

export const PLU_COLUMNS = [
  { header: PLU_HEADER, width: 16 },
  { header: 'Product code', width: 14 },
  { header: 'Description', width: 45 },
  { header: 'Size', width: 12 },
  { header: 'Department', width: 24 },
  { header: 'System stock', width: 13 },
  { header: 'Count', width: 10 },
  { header: 'Variance', width: 10 },
  { header: 'Variance value (R)', width: 18 },
]

// ---------------------------------------------------------------- tab names

// Excel's rules: no [ ] : * ? / \, at most 31 characters, not blank, no leading or
// trailing apostrophe, unique ignoring case, and "History" is reserved. A NULL or
// blank department reads Other. `taken` is a Set of lower-case names already used
// in the workbook, updated here.
export function sanitiseSheetName(name, taken) {
  const used = taken || new Set()
  const clean = (s) => String(s)
    .replace(/[\u0000-\u001f]/g, '')
    .replace(/[[\]:*?/\\]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^'+|'+$/g, '')
    .trim()

  let base = clean(name === null || name === undefined ? '' : name)
  if (!base) base = OTHER_TAB
  base = clean(base.slice(0, SHEET_NAME_MAX)) || OTHER_TAB

  let candidate = base
  let n = 1
  while (used.has(candidate.toLowerCase()) || candidate.toLowerCase() === 'history') {
    n += 1
    const suffix = ' ' + n
    candidate = clean(base.slice(0, SHEET_NAME_MAX - suffix.length)) + suffix
  }
  used.add(candidate.toLowerCase())
  return candidate
}

// ---------------------------------------------------------------- shared helpers

// A text identifier. A number is accepted only when it is an exact integer, so a
// float can never be written into an identifier cell.
function idText(v, what) {
  if (v === null || v === undefined) return ''
  if (typeof v === 'string') return v
  if (typeof v === 'number' && Number.isSafeInteger(v)) return String(v)
  const err = new Error('unsafe_identifier')
  err.code = 'unsafe_identifier'
  err.what = what
  throw err
}

function numOrNull(v) {
  if (v === null || v === undefined || v === '') return null
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : null
}

function textOrEmpty(v) {
  return v === null || v === undefined ? '' : String(v)
}

function styleHeader(row, cols) {
  for (let c = 1; c <= cols; c++) {
    const cell = row.getCell(c)
    cell.font = { bold: true }
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: HEADER_FILL } }
    cell.border = BORDER
  }
}

function styleData(row, cols) {
  row.height = ROW_HEIGHT
  for (let c = 1; c <= cols; c++) {
    const cell = row.getCell(c)
    cell.border = BORDER
    cell.alignment = { vertical: 'middle' }
  }
}

function sheetOptions() {
  return {
    views: [{ state: 'frozen', xSplit: 0, ySplit: 1 }],
    pageSetup: {
      paperSize: PAPER_A4,
      orientation: 'landscape',
      fitToPage: true,
      fitToWidth: 1,
      fitToHeight: 0,
      printTitlesRow: '1:1',
    },
  }
}

async function toBuffer(wb) {
  const out = await wb.xlsx.writeBuffer()
  return Buffer.isBuffer(out) ? out : Buffer.from(out)
}

// ---------------------------------------------------------------- the count sheet

// Departments in order of first appearance (the database sends dept_name with NULLs
// last), lines inside a department by seq.
function groupByDept(lines) {
  const order = []
  const byKey = new Map()
  for (const line of lines) {
    const raw = line.dept_name
    const dept = raw === null || raw === undefined || String(raw).trim() === '' ? null : String(raw)
    const key = dept === null ? '\u0000' : dept
    let group = byKey.get(key)
    if (!group) {
      group = { dept, lines: [] }
      byKey.set(key, group)
      order.push(group)
    }
    group.lines.push(line)
  }
  for (const group of order) {
    group.lines = group.lines
      .map((line, i) => ({ line, i }))
      .sort((a, b) => (numOrNull(a.line.seq) ?? 0) - (numOrNull(b.line.seq) ?? 0) || a.i - b.i)
      .map((x) => x.line)
  }
  return order
}

function lineIdNumber(v) {
  const parsed = parseLineId(v)
  if (parsed.id === undefined) {
    const err = new Error('bad_line_id')
    err.code = 'bad_line_id'
    throw err
  }
  return parsed.id
}

// How many lines and tabs the sheet will carry (for the DOWNLOAD event).
export function describeCountSheet(cycleDoc) {
  const lines = Array.isArray(cycleDoc && cycleDoc.lines) ? cycleDoc.lines : []
  return { lines: lines.length, tabs: groupByDept(lines).length }
}

// cycleDoc is the rpc_stocktake_cycle_get document. Returns a Buffer (xlsx).
export async function buildCountWorkbook(cycleDoc) {
  const lines = Array.isArray(cycleDoc && cycleDoc.lines) ? cycleDoc.lines : []
  const listType = cycleDoc && cycleDoc.cycle ? cycleDoc.cycle.list_type : null

  const wb = new ExcelJS.Workbook()
  wb.creator = 'SocialBrand Stocktake'
  wb.created = new Date()

  const taken = new Set()
  for (const group of groupByDept(lines)) {
    const ws = wb.addWorksheet(sanitiseSheetName(group.dept, taken), sheetOptions())

    // The header of column B reads "PLU / Code" when any line on the tab is not an EAN,
    // and always on the PLU and scale list.
    const allEan = group.lines.every((l) => l.identifier_kind === 'EAN')
    const idHeader = listType === 'PLU' || !allEan ? PLU_HEADER : 'EAN'

    COUNT_COLUMNS.forEach((col, i) => {
      const column = ws.getColumn(i + 1)
      column.width = col.width
      if (col.hidden) column.hidden = true
    })

    const header = ws.getRow(1)
    COUNT_COLUMNS.forEach((col, i) => {
      header.getCell(i + 1).value = i === 1 ? idHeader : col.header
    })
    styleHeader(header, COUNT_COLUMNS.length)

    group.lines.forEach((line, i) => {
      const row = ws.getRow(i + 2)
      row.getCell(1).value = lineIdNumber(line.line_id)
      const ean = row.getCell(2)
      ean.value = idText(line.identifier, 'identifier')
      ean.numFmt = '@'
      row.getCell(3).value = textOrEmpty(line.description)
      row.getCell(4).value = textOrEmpty(line.size)
      row.getCell(5).value = numOrNull(line.system_stock)
      // A count already captured is written back, so a re-download shows the work done.
      const front = numOrNull(line.front)
      const back = numOrNull(line.back)
      if (front !== null) row.getCell(6).value = front
      if (back !== null) row.getCell(7).value = back
      styleData(row, COUNT_COLUMNS.length)
    })
  }

  return toBuffer(wb)
}

// ---------------------------------------------------------------- reading a filled sheet

function cellPlain(v) {
  if (v === null || v === undefined) return null
  if (v instanceof Date) return { unreadable: 'a date' }
  if (typeof v === 'object') {
    if ('result' in v) return cellPlain(v.result)
    if ('richText' in v && Array.isArray(v.richText)) return v.richText.map((t) => t.text).join('')
    if ('text' in v) return cellPlain(v.text)
    if ('error' in v) return { unreadable: 'an error' }
    if ('formula' in v || 'sharedFormula' in v) return { unreadable: 'a formula with no value' }
    return { unreadable: 'something that is not a number' }
  }
  return v
}

function headerKey(v) {
  const t = cellPlain(v)
  if (typeof t !== 'string') return ''
  return t.toLowerCase().replace(/[\s_]/g, '')
}

function findHeader(ws) {
  const last = Math.min(ws.rowCount, HEADER_SCAN_ROWS)
  for (let r = 1; r <= last; r++) {
    const cols = {}
    ws.getRow(r).eachCell({ includeEmpty: false }, (cell, c) => {
      const key = headerKey(cell.value)
      if (key === 'lineid' && !cols.lineId) cols.lineId = c
      else if (key === 'front' && !cols.front) cols.front = c
      else if (key === 'back' && !cols.back) cols.back = c
    })
    if (cols.lineId) return { row: r, cols }
  }
  return null
}

function shown(v) {
  const t = cellPlain(v)
  if (t && typeof t === 'object') return ''
  const s = String(t)
  return s.length > 20 ? s.slice(0, 20) + '...' : s
}

// Reads one box. Returns { empty } | { value } | { reject: '<sentence>' }.
function readBox(raw, label, where) {
  const plain = cellPlain(raw)
  if (plain && typeof plain === 'object') {
    return { reject: `${where}: the ${label} box holds ${plain.unreadable}, which is not a number.` }
  }
  const q = parseQty(plain)
  if (q.empty) return { empty: true }
  if (q.bad) {
    return { reject: `${where}: the ${label} box holds "${shown(raw)}", which ${q.bad}.` }
  }
  return { value: q.value }
}

// buffer: the uploaded .xlsx. Returns
//   lines      [{line_id, front, back}]   what to send to rpc_stocktake_capture
//   sources    [{tab, row}]               where each line came from (same order)
//   rejected   [{line_id?, row, tab, reason}]
//   rows_seen  rows with a numeric LineId
//   tabs_read  tabs that carry a LineId header (0 means: not a count sheet)
export async function parseCountUpload(buffer) {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(buffer)

  const lines = []
  const sources = []
  const rejected = []
  let rowsSeen = 0
  let tabsRead = 0

  wb.eachSheet((ws) => {
    const header = findHeader(ws)
    if (!header) return
    tabsRead += 1
    const { cols } = header

    if (!cols.front && !cols.back) {
      rejected.push({ row: header.row, tab: ws.name, reason: `${ws.name}: this tab has no Front or Back column, so it was not read.` })
      return
    }

    ws.eachRow({ includeEmpty: false }, (row, r) => {
      if (r <= header.row) return
      const id = parseLineId(cellPlain(row.getCell(cols.lineId).value))
      if (id.none) return
      rowsSeen += 1
      const where = `${ws.name} row ${r}`
      if (id.bad) {
        rejected.push({ row: r, tab: ws.name, reason: `${where}: ${id.bad}` })
        return
      }

      const front = cols.front ? readBox(row.getCell(cols.front).value, 'Front', where) : { empty: true }
      const back = cols.back ? readBox(row.getCell(cols.back).value, 'Back', where) : { empty: true }
      const problem = front.reject || back.reject
      if (problem) {
        rejected.push({ line_id: id.id, row: r, tab: ws.name, reason: problem })
        return
      }
      // Both boxes empty changes nothing, so the row is not sent.
      if (front.empty && back.empty) return
      lines.push({
        line_id: id.id,
        front: front.empty ? null : front.value,
        back: back.empty ? null : back.value,
      })
      sources.push({ tab: ws.name, row: r })
    })
  })

  return { lines, sources, rejected, rows_seen: rowsSeen, tabs_read: tabsRead }
}

// ---------------------------------------------------------------- the PLU and scale sheet

// exportDoc is the rpc_stocktake_export result for kind MANUAL: { rows: [...] }.
// Returns a Buffer (xlsx).
export async function buildPluWorkbook(exportDoc) {
  const rows = Array.isArray(exportDoc && exportDoc.rows) ? exportDoc.rows : []

  const wb = new ExcelJS.Workbook()
  wb.creator = 'SocialBrand Stocktake'
  wb.created = new Date()

  const ws = wb.addWorksheet(PLU_TAB, sheetOptions())
  PLU_COLUMNS.forEach((col, i) => {
    ws.getColumn(i + 1).width = col.width
  })

  const header = ws.getRow(1)
  PLU_COLUMNS.forEach((col, i) => {
    header.getCell(i + 1).value = col.header
  })
  styleHeader(header, PLU_COLUMNS.length)

  rows.forEach((r, i) => {
    const row = ws.getRow(i + 2)
    const code = row.getCell(1)
    code.value = idText(r.identifier, 'identifier')
    code.numFmt = '@'
    const product = row.getCell(2)
    product.value = idText(r.product_code, 'product_code')
    product.numFmt = '@'
    row.getCell(3).value = textOrEmpty(r.description)
    row.getCell(4).value = textOrEmpty(r.size)
    row.getCell(5).value = textOrEmpty(r.dept_name)
    row.getCell(6).value = numOrNull(r.system_stock)
    row.getCell(7).value = numOrNull(r.count_qty)
    row.getCell(8).value = numOrNull(r.variance_qty)
    const value = row.getCell(9)
    value.value = numOrNull(r.variance_value)
    value.numFmt = '#,##0.00'
    styleData(row, PLU_COLUMNS.length)
  })

  return toBuffer(wb)
}
