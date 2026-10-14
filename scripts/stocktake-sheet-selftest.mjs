// scripts/stocktake-sheet-selftest.mjs
// Self-test for the stocktake count sheet (src/lib/stocktake/sheet.js), SB-CC-STOCKTAKE-001 / ENG-241.
//
//   node scripts/stocktake-sheet-selftest.mjs
//
// 1. Builds the count workbook from a fixture cycle (a 13-digit EAN starting with 6, a 14-digit
//    EAN, a PLU code, two departments plus a NULL one, a department with a colon and brackets,
//    two departments over 31 characters that collide) and reads it back with exceljs.
// 2. Fills Front and Back in that buffer the way a person would (typed numbers, a comma-decimal
//    string, a blank pair, a letter, a negative) and runs parseCountUpload on it.
// 3. Builds the PLU and scale workbook and reads it back.
// 4. The hardening pass (decisions D1 to D5): a blank box is sent as 0, a thousands comma is refused,
//    a rejection carries a bare reason with its tab and row, a duplicate LineId is refused, a zip
//    bomb is refused before it is opened, and the routes cap their request sizes, set the TLX
//    header and ask for the full history. Section 4 loads the real route files through module
//    hooks with a fake database, so it needs Node 22.15 or newer.
// Prints PASS or FAIL per assertion and exits 1 if any failed.

import ExcelJS from 'exceljs'
import JSZip from 'jszip'
import * as nodeModule from 'node:module'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

// exceljs ships jszip. Load it through exceljs so the test does not depend on where npm hoisted it.
const requireHere = createRequire(import.meta.url)
const requireFromExcel = createRequire(requireHere.resolve('exceljs'))
async function workbookXml(buffer) {
  const JSZip = requireFromExcel('jszip')
  const zip = await JSZip.loadAsync(buffer)
  return zip.file('xl/workbook.xml').async('string')
}

// The sheet module sits in a package with no "type" field. Node reads it as ES module on its own
// and says so on stderr. That note is not part of this test.
process.removeAllListeners('warning')
const { buildCountWorkbook, buildPluWorkbook, describeCountSheet, parseCountUpload, sanitiseSheetName } =
  await import('../src/lib/stocktake/sheet.js')
const { parseQty, parseLineId, THOUSANDS_COMMA_SENTENCE } = await import('../src/lib/stocktake/qty.js')
const { dbRefusalSentence, duplicateLineSentence, NOT_ON_CYCLE } = await import('../src/lib/stocktake/reasons.js')
const { assertXlsxWithinLimits, UploadTooLarge, MAX_UNZIPPED_BYTES, MAX_SHEET_XML_BYTES } =
  await import('../src/lib/stocktake/zipguard.js')

let passed = 0
let failed = 0
function check(name, ok, detail) {
  if (ok) {
    passed += 1
    console.log('PASS ' + name)
  } else {
    failed += 1
    console.log('FAIL ' + name + (detail === undefined ? '' : ' -> ' + JSON.stringify(detail)))
  }
}
function eq(name, actual, expected) {
  check(name, JSON.stringify(actual) === JSON.stringify(expected), { actual, expected })
}

// ---------------------------------------------------------------- fixture

const LONG_A = 'HEALTH AND BEAUTY AND PERSONAL CARE PRODUCTS'
const LONG_B = 'HEALTH AND BEAUTY AND PERSONAL CARE ACCESSORIES'
const EAN13 = '6001008646386'
const EAN14 = '16001008646383'
const PLU = '4017'

let nextId = 5000
function line(over) {
  nextId += 1
  return {
    line_id: nextId, seq: nextId - 5000, group_tag: 'SUSPECT', identifier: EAN13, identifier_kind: 'EAN',
    route: 'TLX', route_reason: null, product_code: 150000 + nextId, description: 'ITEM ' + nextId, size: '1KG',
    dept_name: 'BAKERY', subdept_name: null, system_stock: 3, system_now: 3, unit_cost: 10, front: null, back: null,
    count_qty: null, variance_qty: null, variance_value: null, variance_pct: null, flagged: false,
    review_state: 'OPEN', recount_count: 0, captured_by: null, captured_at: null, story: null, last_counted_date: null,
    ...over,
  }
}

// Lines arrive ordered by dept_name (NULLs last) then seq, as the database sends them. The first
// BAKERY lines are out of seq order on purpose: the sheet must sort a tab by seq.
const lines = [
  line({ seq: 2, identifier: EAN13, description: 'S/B B/ROLLS GARLIC', size: "6'S", system_stock: 3 }),
  line({ seq: 1, identifier: EAN14, description: 'FOURTEEN DIGIT EAN', size: '500G', system_stock: 12.5 }),
  line({ seq: 3, identifier: PLU, identifier_kind: 'PLU', route: 'MANUAL', description: 'SCALE ROLLS', size: 'KG', system_stock: 0 }),
  line({ seq: 1, dept_name: 'GROCERIES: FOODS [A]', description: 'GROC ONE', front: 4, back: 0 }),
  line({ seq: 2, dept_name: 'GROCERIES: FOODS [A]', description: 'GROC TWO', identifier: EAN14 }),
  line({ seq: 1, dept_name: LONG_A, description: 'LONG A ONE' }),
  line({ seq: 2, dept_name: LONG_A, description: 'LONG A TWO' }),
  line({ seq: 1, dept_name: LONG_B, description: 'LONG B ONE' }),
  line({ seq: 1, dept_name: null, description: 'NO DEPARTMENT', identifier: '150999', identifier_kind: 'PRODUCT_CODE', route: 'MANUAL' }),
]
const cycleDoc = {
  cycle: { cycle_id: '11111111-2222-3333-4444-555555555555', store_code: '10116', list_type: 'DAILY', status: 'PENDING_CAPTURE' },
  counts: {}, lines, line_count: lines.length, served: lines.length,
}
const idOf = (desc) => lines.find((l) => l.description === desc).line_id

// ---------------------------------------------------------------- 0. sheet names and parsers

{
  const taken = new Set()
  eq('sanitise strips [ ] : * ? / \\', sanitiseSheetName('A[1]:B*C?D/E\\F', taken), 'A1BCDEF')
  eq('sanitise NULL reads Other', sanitiseSheetName(null, new Set()), 'Other')
  eq('sanitise blank reads Other', sanitiseSheetName('  []  ', new Set()), 'Other')
  eq('sanitise caps at 31 characters', sanitiseSheetName('X'.repeat(40), new Set()).length, 31)
  const t2 = new Set()
  const first = sanitiseSheetName('Other', t2)
  const second = sanitiseSheetName('OTHER', t2)
  eq('sanitise de-duplicates ignoring case', [first, second], ['Other', 'OTHER 2'])
  eq('sanitise keeps the suffix inside 31 characters', sanitiseSheetName('Y'.repeat(31), new Set(['y'.repeat(31)])), 'Y'.repeat(29) + ' 2')
  eq('sanitise avoids the reserved name History', sanitiseSheetName('History', new Set()), 'History 2')
  eq('sanitise strips edge apostrophes', sanitiseSheetName("'Sweets'", new Set()), 'Sweets')

  eq('parseQty number', parseQty(3), { value: 3 })
  eq('parseQty zero is a count', parseQty(0), { value: 0 })
  eq('parseQty comma decimal', parseQty('2,5'), { value: 2.5 })
  eq('parseQty padded decimal', parseQty(' 3.25 '), { value: 3.25 })
  eq('parseQty blank string is empty', parseQty('  '), { empty: true })
  eq('parseQty letters are refused', parseQty('abc').bad, 'is not a number')
  eq('parseQty negative number is refused', parseQty(-1).bad, 'is below zero')
  eq('parseQty negative text is refused', parseQty('-2').bad, 'is below zero')
  eq('parseQty two commas are refused', parseQty('1,000,5').bad, 'is not a number')
  // D2: exactly three digits after a single comma is refused with its own sentence.
  eq('D2 the thousands comma sentence is exact', THOUSANDS_COMMA_SENTENCE, 'Enter 1200 or 1.2, not 1,200.')
  eq('D2 parseQty refuses "1,200" with the sentence', parseQty('1,200').refusal, 'Enter 1200 or 1.2, not 1,200.')
  eq('D2 parseQty refuses "1,000" with the sentence', parseQty('1,000').refusal, 'Enter 1200 or 1.2, not 1,200.')
  eq('D2 parseQty refuses " 1,200 " (padded) with the sentence', parseQty(' 1,200 ').refusal, 'Enter 1200 or 1.2, not 1,200.')
  check('D2 a refused comma also carries bad, so a caller that ignores refusal still refuses', typeof parseQty('1,200').bad === 'string' && parseQty('1,200').value === undefined)
  eq('D2 "2,5" stays a decimal', parseQty('2,5'), { value: 2.5 })
  eq('D2 "12,75" stays a decimal', parseQty('12,75'), { value: 12.75 })
  eq('D2 four digits after the comma stay a decimal', parseQty('1,5000'), { value: 1.5 })
  eq('D2 a decimal point with three digits stays a decimal', parseQty('1.200'), { value: 1.2 })
  eq('D2 the number 1200 is a count of 1200', parseQty(1200), { value: 1200 })
  eq('D2 the text 1200 is a count of 1200', parseQty('1200'), { value: 1200 })
  eq('parseLineId number', parseLineId(150416), { id: 150416 })
  eq('parseLineId digit text', parseLineId(' 150416 '), { id: 150416 })
  eq('parseLineId blank is skipped', parseLineId(null), { none: true })
  eq('parseLineId letters are skipped', parseLineId('TOTAL'), { none: true })
  check('parseLineId refuses a fraction', parseLineId(12.5).bad !== undefined)
  check('parseLineId refuses a number past 2^53', parseLineId('9007199254740993').bad !== undefined)
}

// ---------------------------------------------------------------- 1. build and read back

const built = await buildCountWorkbook(cycleDoc)
check('buildCountWorkbook returns a Buffer', Buffer.isBuffer(built))
eq('describeCountSheet counts lines and tabs', describeCountSheet(cycleDoc), { lines: 9, tabs: 5 })

const wb = new ExcelJS.Workbook()
await wb.xlsx.load(built)

eq('tab names', wb.worksheets.map((w) => w.name), [
  'BAKERY',
  'GROCERIES FOODS A',
  'HEALTH AND BEAUTY AND PERSONAL',
  'HEALTH AND BEAUTY AND PERSONA 2',
  'Other',
])
check('every tab name is 31 characters or fewer', wb.worksheets.every((w) => w.name.length <= 31))

const bakery = wb.getWorksheet('BAKERY')
const colInfo = (ws) => [1, 2, 3, 4, 5, 6, 7].map((i) => ({ w: ws.getColumn(i).width, h: !!ws.getColumn(i).hidden }))
for (const ws of wb.worksheets) {
  const tag = '[' + ws.name + '] '
  eq(tag + 'column A hidden, widths 8 15 45 12 12 10 10', colInfo(ws), [
    { w: 8, h: true }, { w: 15, h: false }, { w: 45, h: false }, { w: 12, h: false },
    { w: 12, h: false }, { w: 10, h: false }, { w: 10, h: false },
  ])
  check(tag + 'landscape', ws.pageSetup.orientation === 'landscape', ws.pageSetup.orientation)
  check(tag + 'A4', ws.pageSetup.paperSize === 9, ws.pageSetup.paperSize)
  check(tag + 'fit to one page wide, height automatic',
    ws.pageSetup.fitToPage === true && ws.pageSetup.fitToWidth === 1 && ws.pageSetup.fitToHeight === 0,
    { fitToPage: ws.pageSetup.fitToPage, w: ws.pageSetup.fitToWidth, h: ws.pageSetup.fitToHeight })
  check(tag + 'frozen header row', ws.views && ws.views[0] && ws.views[0].state === 'frozen' && ws.views[0].ySplit === 1, ws.views)
  const h = ws.getRow(1)
  check(tag + 'header cells bold, fill E0E0E0, thin border all round',
    [1, 2, 3, 4, 5, 6, 7].every((c) => {
      const cell = h.getCell(c)
      const b = cell.border || {}
      return cell.font && cell.font.bold === true
        && cell.fill && cell.fill.type === 'pattern' && cell.fill.pattern === 'solid'
        && String(cell.fill.fgColor && cell.fill.fgColor.argb).toUpperCase().endsWith('E0E0E0')
        && ['top', 'left', 'bottom', 'right'].every((s) => b[s] && b[s].style === 'thin')
    }))
  eq(tag + 'header texts (B varies)', [1, 3, 4, 5, 6, 7].map((c) => h.getCell(c).value), ['LineId', 'Description', 'Size', 'System Stock', 'Front', 'Back'])
  const dataRows = []
  ws.eachRow({ includeEmpty: false }, (row, n) => { if (n > 1) dataRows.push(row) })
  check(tag + 'every data row is 28 high with thin borders and vertical centre',
    dataRows.length > 0 && dataRows.every((row) => row.height === 28 && [1, 2, 3, 4, 5, 6, 7].every((c) => {
      const cell = row.getCell(c)
      const b = cell.border || {}
      return ['top', 'left', 'bottom', 'right'].every((s) => b[s] && b[s].style === 'thin')
        && cell.alignment && cell.alignment.vertical === 'middle'
    })))
  check(tag + 'column A is a number, B is a string with number format @, E is a number',
    dataRows.every((row) => typeof row.getCell(1).value === 'number'
      && typeof row.getCell(2).value === 'string' && row.getCell(2).numFmt === '@'
      && typeof row.getCell(5).value === 'number'))
}

// print titles: exceljs keeps them as a defined name per sheet, read it from the file itself
{
  const xml = await workbookXml(built)
  const titles = xml.match(/_xlnm\.Print_Titles/g) || []
  check('print titles (row 1) set on every tab', titles.length === 5 && /\$1:\$1/.test(xml), { titles: titles.length })
}

// header of column B
eq('BAKERY (has a PLU line) header reads PLU / Code', bakery.getCell('B1').value, 'PLU / Code')
eq('GROCERIES tab (EANs only) header reads EAN', wb.getWorksheet('GROCERIES FOODS A').getCell('B1').value, 'EAN')
eq('Other tab (product code line) header reads PLU / Code', wb.getWorksheet('Other').getCell('B1').value, 'PLU / Code')

// rows by seq and the exact identifier text
eq('BAKERY rows run in seq order', [2, 3, 4].map((r) => bakery.getCell('C' + r).value), ['FOURTEEN DIGIT EAN', 'S/B B/ROLLS GARLIC', 'SCALE ROLLS'])
eq('14-digit EAN is the exact text', bakery.getCell('B2').value, EAN14)
eq('13-digit EAN beginning with 6 is the exact text', bakery.getCell('B3').value, EAN13)
eq('PLU code is the exact text', bakery.getCell('B4').value, PLU)
eq('LineId is the line_id number', bakery.getCell('A3').value, idOf('S/B B/ROLLS GARLIC'))
eq('Size is written', bakery.getCell('D3').value, "6'S")
eq('System Stock keeps a fraction', bakery.getCell('E2').value, 12.5)
eq('System Stock zero stays a number', bakery.getCell('E4').value, 0)
eq('captured Front and Back are written back', [wb.getWorksheet('GROCERIES FOODS A').getCell('F2').value, wb.getWorksheet('GROCERIES FOODS A').getCell('G2').value], [4, 0])
check('an empty count box stays empty', bakery.getCell('F3').value === null && bakery.getCell('G3').value === null)

{
  let numericIds = 0
  let total = 0
  for (const ws of wb.worksheets) {
    ws.eachRow({ includeEmpty: false }, (row, n) => {
      if (n === 1) return
      total += 1
      if (typeof row.getCell(2).value !== 'string') numericIds += 1
    })
  }
  eq('no identifier cell is a number anywhere (' + total + ' rows)', numericIds, 0)
}

// ---------------------------------------------------------------- 2. fill the sheet and read it back

const fill = new ExcelJS.Workbook()
await fill.xlsx.load(built)

// BAKERY: row 2 typed numbers, row 3 comma-decimal string, row 4 a blank pair
const fb = fill.getWorksheet('BAKERY')
fb.getCell('F2').value = 3
fb.getCell('G2').value = 2
fb.getCell('F3').value = '2,5'
// GROCERIES: row 2 keeps its captured 4 and 0, row 3 gets a letter
const fg = fill.getWorksheet('GROCERIES FOODS A')
fg.getCell('F3').value = 'abc'
// LONG A: row 2 a negative number, row 3 a negative string in Back with a good Front
const fl = fill.getWorksheet('HEALTH AND BEAUTY AND PERSONAL')
fl.getCell('F2').value = -1
fl.getCell('F3').value = 2
fl.getCell('G3').value = '-2'
// LONG B: row 2 Back only, as a padded string with a comma decimal
const fl2 = fill.getWorksheet('HEALTH AND BEAUTY AND PERSONA 2')
fl2.getCell('G2').value = ' 1,5 '
// Other: a formula cell with a cached result
const fo = fill.getWorksheet('Other')
fo.getCell('F2').value = { formula: '1+2', result: 3 }

const filled = Buffer.from(await fill.xlsx.writeBuffer())
const parsed = await parseCountUpload(filled)

// The order of lines follows the tabs and rows of the file. Assert the exact set and order.
eq('upload: exactly five lines sent', parsed.lines.length, 5)
eq('upload: line ids in file order', parsed.lines.map((l) => l.line_id), [
  idOf('FOURTEEN DIGIT EAN'), idOf('S/B B/ROLLS GARLIC'), idOf('GROC ONE'), idOf('LONG B ONE'), idOf('NO DEPARTMENT'),
])
eq('upload: typed numbers 3 and 2', parsed.lines[0], { line_id: idOf('FOURTEEN DIGIT EAN'), front: 3, back: 2 })
eq('upload (D1): comma decimal 2,5 read as 2.5, the blank Back is sent as 0', parsed.lines[1], { line_id: idOf('S/B B/ROLLS GARLIC'), front: 2.5, back: 0 })
eq('upload: a captured 4 and 0 come back as they were', parsed.lines[2], { line_id: idOf('GROC ONE'), front: 4, back: 0 })
eq('upload (D1): Back-only padded comma string, the blank Front is sent as 0', parsed.lines[3], { line_id: idOf('LONG B ONE'), front: 0, back: 1.5 })
eq('upload (D1): formula result read as a number, the blank Back is sent as 0', parsed.lines[4], { line_id: idOf('NO DEPARTMENT'), front: 3, back: 0 })
check('upload: the blank pair (SCALE ROLLS) is not sent', !parsed.lines.some((l) => l.line_id === idOf('SCALE ROLLS')))
eq('upload: three rows rejected', parsed.rejected.length, 3)
eq('upload (D3): letter rejected, bare reason with tab and row as fields', parsed.rejected.find((r) => r.line_id === idOf('GROC TWO')), {
  line_id: idOf('GROC TWO'), row: 3, tab: 'GROCERIES FOODS A',
  reason: 'the Front box holds "abc", which is not a number.',
})
eq('upload (D3): negative number rejected, bare reason', parsed.rejected.find((r) => r.line_id === idOf('LONG A ONE')), {
  line_id: idOf('LONG A ONE'), row: 2, tab: 'HEALTH AND BEAUTY AND PERSONAL',
  reason: 'the Front box holds "-1", which is below zero.',
})
eq('upload (D3): negative string rejected, the good Front is not sent alone', parsed.rejected.find((r) => r.line_id === idOf('LONG A TWO')), {
  line_id: idOf('LONG A TWO'), row: 3, tab: 'HEALTH AND BEAUTY AND PERSONAL',
  reason: 'the Back box holds "-2", which is below zero.',
})
check('upload (D3): no reason repeats its own tab or row', parsed.rejected.every((r) => !r.reason.includes(r.tab) && !/\brow \d/.test(r.reason)), parsed.rejected)
check('upload (D3): every rejected item carries reason, row and tab', parsed.rejected.every((r) => typeof r.reason === 'string' && Number.isInteger(r.row) && typeof r.tab === 'string'))
check('upload: no rejected line was sent', parsed.rejected.every((r) => !parsed.lines.some((l) => l.line_id === r.line_id)))
eq('upload: rows seen (every row with a LineId)', parsed.rows_seen, 9)
eq('upload: tabs read', parsed.tabs_read, 5)
eq('upload: sources name tab and row', parsed.sources[0], { tab: 'BAKERY', row: 2 })

// a re-saved sheet keeps the EANs as text
{
  const again = new ExcelJS.Workbook()
  await again.xlsx.load(filled)
  const ws = again.getWorksheet('BAKERY')
  check('after a fill and save the 13-digit EAN is still text', ws.getCell('B3').value === EAN13 && ws.getCell('B3').numFmt === '@')
  check('after a fill and save the 14-digit EAN is still text', ws.getCell('B2').value === EAN14 && ws.getCell('B2').numFmt === '@')
}

// a header typed in another case, with a title row above it, still reads
{
  const odd = new ExcelJS.Workbook()
  const ws = odd.addWorksheet('Anything')
  ws.getCell('A1').value = 'Count sheet for the bakery'
  ws.getRow(3).values = ['lineid', 'ean', 'front', 'BACK']
  ws.getRow(4).values = [77, '6001008646386', 1, 2]
  const out = await parseCountUpload(Buffer.from(await odd.xlsx.writeBuffer()))
  eq('upload: header found by text, case blind, below a title row', out.lines, [{ line_id: 77, front: 1, back: 2 }])
}

// not a count sheet, not a spreadsheet
{
  const plain = new ExcelJS.Workbook()
  plain.addWorksheet('Sheet1').getRow(1).values = ['Name', 'Qty']
  const out = await parseCountUpload(Buffer.from(await plain.xlsx.writeBuffer()))
  eq('upload: a workbook with no LineId header reads zero tabs', [out.tabs_read, out.lines.length, out.rows_seen], [0, 0, 0])
  let threw = false
  try { await parseCountUpload(Buffer.from('this is not a spreadsheet')) } catch { threw = true }
  check('upload: a file that is not an xlsx throws', threw)
}

// ---------------------------------------------------------------- 3. the PLU and scale workbook

const exportDoc = {
  kind: 'MANUAL', filename: '10116_stocktake_2026-10-13_PLU.csv', line_count: 3,
  rows: [
    { identifier: PLU, identifier_kind: 'PLU', product_code: 150123, description: 'SCALE ROLLS', size: 'KG', dept_name: 'BAKERY', system_stock: 4.5, count_qty: 3, variance_qty: -1.5, variance_value: -12.3, route_reason: 'PLU or scale line' },
    { identifier: '150999', identifier_kind: 'PRODUCT_CODE', product_code: 150999, description: 'NO BARCODE', size: null, dept_name: null, system_stock: 0, count_qty: 0, variance_qty: 0, variance_value: 0, route_reason: 'no proven barcode' },
    { identifier: '0000123', identifier_kind: 'PLU', product_code: 150124, description: 'LEADING ZEROS', size: '', dept_name: 'DELI', system_stock: 1, count_qty: 1, variance_qty: 0, variance_value: null, route_reason: null },
  ],
}
const pluBuf = await buildPluWorkbook(exportDoc)
const pwb = new ExcelJS.Workbook()
await pwb.xlsx.load(pluBuf)
eq('PLU workbook has one tab named PLU and scale', pwb.worksheets.map((w) => w.name), ['PLU and scale'])
const pws = pwb.getWorksheet('PLU and scale')
eq('PLU headers', pws.getRow(1).values.slice(1), ['PLU / Code', 'Product code', 'Description', 'Size', 'Department', 'System stock', 'Count', 'Variance', 'Variance value (R)'])
check('PLU header styled bold on E0E0E0 with thin borders', [1, 2, 3, 4, 5, 6, 7, 8, 9].every((c) => {
  const cell = pws.getRow(1).getCell(c)
  const b = cell.border || {}
  return cell.font && cell.font.bold === true && String(cell.fill && cell.fill.fgColor && cell.fill.fgColor.argb).toUpperCase().endsWith('E0E0E0')
    && ['top', 'left', 'bottom', 'right'].every((s) => b[s] && b[s].style === 'thin')
}))
check('PLU sheet landscape, one page wide, frozen header',
  pws.pageSetup.orientation === 'landscape' && pws.pageSetup.fitToWidth === 1 && pws.pageSetup.fitToHeight === 0
  && pws.views[0] && pws.views[0].state === 'frozen')
{
  const xml = await workbookXml(pluBuf)
  check('PLU sheet repeats row 1 on every printed page', /_xlnm\.Print_Titles/.test(xml) && /\$1:\$1/.test(xml))
}
eq('PLU code and product code are text cells', [2, 3, 4].map((r) => [typeof pws.getCell('A' + r).value, pws.getCell('A' + r).numFmt, typeof pws.getCell('B' + r).value, pws.getCell('B' + r).numFmt]),
  [['string', '@', 'string', '@'], ['string', '@', 'string', '@'], ['string', '@', 'string', '@']])
eq('PLU leading zeros survive', pws.getCell('A4').value, '0000123')
eq('PLU product code is text', pws.getCell('B2').value, '150123')
eq('PLU numbers stay numbers', [pws.getCell('F2').value, pws.getCell('G2').value, pws.getCell('H2').value, pws.getCell('I2').value], [4.5, 3, -1.5, -12.3])
check('PLU empty department and size stay empty text', pws.getCell('E3').value === '' || pws.getCell('E3').value === null)

let unsafe = null
try {
  await buildPluWorkbook({ rows: [{ identifier: 6001008646386.5, product_code: 1 }] })
} catch (e) {
  unsafe = e.code
}
eq('a float identifier is refused, never written', unsafe, 'unsafe_identifier')

// ---------------------------------------------------------------- 4. the hardening pass

const COUNT_HEADER = ['LineId', 'EAN', 'Description', 'Size', 'System Stock', 'Front', 'Back']

// A count sheet built by hand. tabs = [{ name, header?, rows: [[LineId, Front, Back]] }].
async function handSheet(tabs) {
  const w = new ExcelJS.Workbook()
  for (const tab of tabs) {
    const ws = w.addWorksheet(tab.name)
    ws.getRow(1).values = tab.header || COUNT_HEADER
    tab.rows.forEach((r, i) => {
      ws.getRow(i + 2).values = [r[0], '6001008646386', 'ITEM ' + r[0], '1KG', 3, ...r.slice(1)]
    })
  }
  return Buffer.from(await w.xlsx.writeBuffer())
}

// ---- D1: a row with a box filled sends BOTH boxes, a blank one as 0
{
  const out = await parseCountUpload(await handSheet([{
    name: 'BAKERY',
    rows: [
      [11, 3, null],     // Front only
      [12, null, 4],     // Back only
      [13, null, null],  // both blank
      [14, 0, null],     // a zero is a count
      [15, '', '2'],     // empty text reads as blank
      [16, '  ', null],  // spaces read as blank
      [17, 2.5, 1.5],    // both filled
    ],
  }]))
  eq('D1 Front only sends Back as 0', out.lines.find((l) => l.line_id === 11), { line_id: 11, front: 3, back: 0 })
  eq('D1 Back only sends Front as 0', out.lines.find((l) => l.line_id === 12), { line_id: 12, front: 0, back: 4 })
  check('D1 a row with both boxes blank is not sent', !out.lines.some((l) => l.line_id === 13 || l.line_id === 16))
  eq('D1 a Front of 0 is a count and sends Back as 0', out.lines.find((l) => l.line_id === 14), { line_id: 14, front: 0, back: 0 })
  eq('D1 empty text counts as blank', out.lines.find((l) => l.line_id === 15), { line_id: 15, front: 0, back: 2 })
  eq('D1 two filled boxes go as they are', out.lines.find((l) => l.line_id === 17), { line_id: 17, front: 2.5, back: 1.5 })
  check('D1 no box is ever null on a sent row', out.lines.every((l) => typeof l.front === 'number' && typeof l.back === 'number'), out.lines)
  eq('D1 the rows sent, in file order', out.lines.map((l) => l.line_id), [11, 12, 14, 15, 17])
  eq('D1 nothing was rejected', out.rejected, [])

  // A tab with no Back column never showed that box, so it is left alone (null), not zeroed.
  const noBack = await parseCountUpload(await handSheet([{
    name: 'NOBACK', header: COUNT_HEADER.slice(0, 6), rows: [[21, 5], [22, null]],
  }]))
  eq('D1 a tab with no Back column sends Back as null, so the stored Back stays', noBack.lines, [{ line_id: 21, front: 5, back: null }])
  const noFront = await parseCountUpload(await handSheet([{
    name: 'NOFRONT', header: ['LineId', 'EAN', 'Description', 'Size', 'System Stock', 'Back'], rows: [[31, 6], [32, null]],
  }]))
  eq('D1 a tab with no Front column sends Front as null', noFront.lines, [{ line_id: 31, front: null, back: 6 }])
}

// ---- D2: a thousands comma on an uploaded sheet is refused with the exact sentence
{
  const out = await parseCountUpload(await handSheet([{
    name: 'BAKERY',
    rows: [[41, '1,200', null], [42, 3, '1,000'], [43, '2,5', null], [44, '12,75', 1]],
  }]))
  eq('D2 upload: "1,200" in Front is refused with the sentence', out.rejected.find((r) => r.line_id === 41),
    { line_id: 41, row: 2, tab: 'BAKERY', reason: 'Enter 1200 or 1.2, not 1,200.' })
  eq('D2 upload: "1,000" in Back is refused with the sentence', out.rejected.find((r) => r.line_id === 42),
    { line_id: 42, row: 3, tab: 'BAKERY', reason: 'Enter 1200 or 1.2, not 1,200.' })
  eq('D2 upload: "2,5" stays a decimal', out.lines.find((l) => l.line_id === 43), { line_id: 43, front: 2.5, back: 0 })
  eq('D2 upload: "12,75" stays a decimal', out.lines.find((l) => l.line_id === 44), { line_id: 44, front: 12.75, back: 1 })
  check('D2 upload: the refused rows are not sent', !out.lines.some((l) => l.line_id === 41 || l.line_id === 42))
}

// ---- D3: the database's refusals become bare sentences
{
  eq('D3 "line is not on this cycle"', dbRefusalSentence(NOT_ON_CYCLE), 'this line is not on this list.')
  eq('D3 "a count cannot be negative"', dbRefusalSentence('a count cannot be negative'), 'a count cannot be below zero.')
  eq('D3 the count ceiling is read from the database text', dbRefusalSentence('a count above 10000 is not accepted, check the box and the scanner'),
    'a count above 10000 is not accepted. Check the box.')
  eq('D3 a ceiling with a fraction', dbRefusalSentence('a count above 2500.5 is not accepted, check the box and the scanner'),
    'a count above 2500.5 is not accepted. Check the box.')
  const unknown = dbRefusalSentence('relation "stocktake_cycle_line" does not exist')
  eq('D3 an unknown database text becomes a generic sentence', unknown, 'the database did not accept this line.')
  check('D3 no database text leaks through', !/relation|stocktake_cycle_line/.test(unknown))
  eq('D3 a missing reason is generic', dbRefusalSentence(undefined), 'the database did not accept this line.')
  eq('dup: the sentence names the first row and tab', duplicateLineSentence(2, 'BAKERY'), 'this line is already on row 2 of tab BAKERY.')

  // the other two reasons the sheet reader writes carry no location either
  const badId = await parseCountUpload(await handSheet([{ name: 'BAKERY', rows: [[12.5, 1, 0], ['9007199254740993', 1, 0]] }]))
  eq('D3 a LineId that is not a whole number is refused with a bare reason, tab and row', badId.rejected, [
    { row: 2, tab: 'BAKERY', reason: 'the LineId is not a whole positive number.' },
    { row: 3, tab: 'BAKERY', reason: 'the LineId is not a whole positive number.' },
  ])
  const noBoxes = await parseCountUpload(await handSheet([{ name: 'NOBOXES', header: ['LineId', 'EAN', 'Description'], rows: [[71]] }]))
  eq('D3 a tab with no Front or Back column is refused with a bare reason, tab and row', noBoxes.rejected,
    [{ row: 1, tab: 'NOBOXES', reason: 'this tab has no Front or Back column, so it was not read.' }])
}

// ---- a duplicate LineId in one file: the LATER row is refused and never sent
{
  const out = await parseCountUpload(await handSheet([
    { name: 'BAKERY', rows: [[51, 3, 1], [52, 2, null], [51, 9, 9], [53, null, null], [53, 4, 4]] },
    { name: 'DELI', rows: [[52, 7, 7], [54, 1, null], [51, null, null]] },
  ]))
  eq('dup: the lines sent are the first row of each LineId, in file order', out.lines, [
    { line_id: 51, front: 3, back: 1 },
    { line_id: 52, front: 2, back: 0 },
    { line_id: 54, front: 1, back: 0 },
  ])
  eq('dup: the later row on the same tab is refused and names the first', out.rejected.find((r) => r.line_id === 51 && r.tab === 'BAKERY'),
    { line_id: 51, row: 4, tab: 'BAKERY', reason: 'this line is already on row 2 of tab BAKERY.' })
  eq('dup: a row on a later tab is refused and names the first tab', out.rejected.find((r) => r.line_id === 52),
    { line_id: 52, row: 2, tab: 'DELI', reason: 'this line is already on row 3 of tab BAKERY.' })
  eq('dup: a blank first row still counts as the first, the later row with counts is refused', out.rejected.find((r) => r.line_id === 53),
    { line_id: 53, row: 6, tab: 'BAKERY', reason: 'this line is already on row 5 of tab BAKERY.' })
  eq('dup: a blank later duplicate is refused too, naming the first', out.rejected.find((r) => r.line_id === 51 && r.tab === 'DELI'),
    { line_id: 51, row: 4, tab: 'DELI', reason: 'this line is already on row 2 of tab BAKERY.' })
  eq('dup: four rows refused in all', out.rejected.length, 4)
  check('dup: no LineId is sent twice', new Set(out.lines.map((l) => l.line_id)).size === out.lines.length)
  eq('dup: rows seen counts every row with a LineId', out.rows_seen, 8)

  // a row refused for its content is still the first row of its LineId
  const first = await parseCountUpload(await handSheet([{ name: 'BAKERY', rows: [[61, 'abc', null], [61, 3, 1]] }]))
  eq('dup: a bad first row still owns its LineId', first.rejected.map((r) => [r.row, r.reason]), [
    [2, 'the Front box holds "abc", which is not a number.'],
    [3, 'this line is already on row 2 of tab BAKERY.'],
  ])
  eq('dup: and nothing is sent for it', first.lines, [])
}

// ---- the zip bomb guard: refused before anything opens the file
{
  const zipOf = async (entries) => {
    const z = new JSZip()
    for (const [name, size] of entries) z.file(name, Buffer.alloc(size))
    return z.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 9 } })
  }
  const verdict = async (buf, limits) => {
    try {
      await assertXlsxWithinLimits(buf, limits)
      return 'ok'
    } catch (e) {
      return e instanceof UploadTooLarge ? 'too_large:' + e.what : 'unreadable'
    }
  }

  check('the sheet limit is 20 MB and the total limit is 50 MB', MAX_SHEET_XML_BYTES === 20 * 1024 * 1024 && MAX_UNZIPPED_BYTES === 50 * 1024 * 1024)

  // a worksheet XML one byte over the limit: 20 MB of zeros packs to a few KB
  const bomb = await zipOf([['[Content_Types].xml', 40], ['xl/worksheets/sheet1.xml', MAX_SHEET_XML_BYTES + 1]])
  check('the bomb fixture is tiny (' + bomb.length + ' bytes) and starts with PK', bomb.length < 64 * 1024 && bomb[0] === 0x50 && bomb[1] === 0x4b, bomb.length)
  const t0 = Date.now()
  eq('a worksheet XML over 20 MB is refused', await verdict(bomb), 'too_large:sheet')
  check('the refusal came fast (' + (Date.now() - t0) + ' ms)', Date.now() - t0 < 5000)

  eq('a worksheet XML of exactly 20 MB passes', await verdict(await zipOf([['xl/worksheets/sheet1.xml', MAX_SHEET_XML_BYTES]])), 'ok')

  // four worksheets under the sheet limit that together pass the total limit
  const each = Math.floor(MAX_UNZIPPED_BYTES / 4) + 1
  eq('four worksheets that pass 50 MB together are refused as a total', await verdict(await zipOf([
    ['xl/worksheets/sheet1.xml', each], ['xl/worksheets/sheet2.xml', each], ['xl/worksheets/sheet3.xml', each], ['xl/worksheets/sheet4.xml', each],
  ])), 'too_large:total')
  eq('three non-sheet entries that pass 50 MB together are refused as a total', await verdict(await zipOf([
    ['xl/media/a.bin', Math.floor(MAX_UNZIPPED_BYTES / 3) + 1], ['xl/media/b.bin', Math.floor(MAX_UNZIPPED_BYTES / 3) + 1], ['xl/media/c.bin', Math.floor(MAX_UNZIPPED_BYTES / 3) + 1],
  ])), 'too_large:total')
  eq('a file of exactly 50 MB passes', await verdict(await zipOf([['xl/media/a.bin', MAX_UNZIPPED_BYTES / 2], ['xl/media/b.bin', MAX_UNZIPPED_BYTES / 2]])), 'ok')
  eq('small limits are honoured (the limits argument)', await verdict(await zipOf([['xl/worksheets/sheet1.xml', 2000]]), { sheet: 1000, total: 5000 }), 'too_large:sheet')

  eq('a real count sheet passes', await verdict(built), 'ok')
  eq('a filled count sheet passes', await verdict(filled), 'ok')
  eq('a file that is not a zip is unreadable, not too large', await verdict(Buffer.from('PK this is not a zip file at all')), 'unreadable')

  // the sender writes the sizes a zip declares, so the guard counts what the data really unpacks to
  const patchDeclaredSize = (buf, entryName, size) => {
    const out = Buffer.from(buf)
    let at = 0
    for (;;) {
      at = out.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]), at)
      if (at < 0) return null
      const nameLen = out.readUInt16LE(at + 28)
      if (out.toString('utf8', at + 46, at + 46 + nameLen) === entryName) {
        out.writeUInt32LE(size, at + 24)
        return out
      }
      at += 4
    }
  }
  const honest = await zipOf([['xl/worksheets/sheet1.xml', MAX_SHEET_XML_BYTES + 5 * 1024 * 1024]])
  const lying = patchDeclaredSize(honest, 'xl/worksheets/sheet1.xml', 100)
  check('the lying-header fixture was built', lying !== null)
  const lie = await verdict(lying)
  check('a header that declares 100 bytes for 25 MB is still refused (' + lie + ')', lie !== 'ok', lie)
}

// ---- routes: the real route files, a fake session and a fake database
const loadRoutes = async () => {
  if (typeof nodeModule.registerHooks !== 'function') throw new Error('node:module registerHooks is missing')
  globalThis.__stocktakeSelftest = { user: { id: 'u1' }, rpc: async () => ({ data: null, error: { message: 'no fake', code: 'X' }, status: 500 }) }
  const stubHeaders = 'data:text/javascript,' + encodeURIComponent('export function cookies() { return { getAll() { return [] }, set() {} } }')
  const stubSsr = 'data:text/javascript,' + encodeURIComponent(
    'export function createServerClient() { const f = globalThis.__stocktakeSelftest; ' +
    'return { auth: { getUser: async () => ({ data: { user: f.user }, error: null }) }, rpc: async (n, a) => f.rpc(n, a) } }')
  const src = new URL('../src/', import.meta.url)
  nodeModule.registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === '@supabase/ssr') return { url: stubSsr, shortCircuit: true }
      if (specifier === 'next/headers') return { url: stubHeaders, shortCircuit: true }
      if (specifier === 'next/server') return nextResolve('next/server.js', context)
      if (specifier.startsWith('@/')) {
        let rel = specifier.slice(2)
        if (!/\.[a-z]+$/i.test(rel)) rel += '.js'
        return { url: new URL(rel, src).href, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    },
  })
  const at = (p) => import(pathToFileURL(new URL('../src/app/api/stocktake/' + p, import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')).href)
  return {
    server: await import(new URL('../src/lib/stocktake/server.js', import.meta.url).href),
    capture: await at('cycle/[id]/capture/route.js'),
    review: await at('cycle/[id]/review/route.js'),
    cancel: await at('cycle/[id]/cancel/route.js'),
    upload: await at('cycle/[id]/upload/route.js'),
    exporter: await at('cycle/[id]/export/route.js'),
    sheet: await at('cycle/[id]/sheet/route.js'),
    history: await at('history/route.js'),
    events: await at('events/route.js'),
  }
}

let R = null
try {
  R = await loadRoutes()
} catch (e) {
  check('the route files load through module hooks (needs Node 22.15 or newer)', false, String(e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e))
}

if (R) {
  const CID = '11111111-2222-3333-4444-555555555555'
  const ctx = { params: { id: CID } }
  const FAKE = globalThis.__stocktakeSelftest
  let calls = []
  let handlers = {}
  FAKE.rpc = async (name, args) => {
    calls.push({ name, args })
    const h = handlers[name]
    if (!h) return { data: null, error: { message: 'no handler for ' + name, code: 'X' }, status: 500 }
    const r = await h(args)
    return r.error ? { data: null, error: r.error, status: 400 } : { data: r.data, error: null, status: 200 }
  }
  const setup = (h) => { calls = []; handlers = h || {} }
  const jbody = async (res) => JSON.parse(await res.text())
  const jpost = (route, payload) => route.POST(new Request('http://x', { method: 'POST', body: JSON.stringify(payload) }), ctx)
  const capOk = async (a) => ({ data: { set: a.p_lines.length, unchanged: 0, rejected: [], blank: 0, saved_at: 'T' } })

  // ---- the request size caps
  {
    const many = (n) => Array.from({ length: n }, (_, i) => ({ line_id: i + 1, front: 1, back: 0 }))
    const cap = R.server.MAX_CAPTURE_LINES
    eq('the capture cap is 2000 lines', cap, 2000)
    setup({ rpc_stocktake_capture: capOk })
    let r = await jpost(R.capture, { lines: many(cap + 1) })
    let b = await jbody(r)
    check('capture: 2001 lines is a 400 with a plain sentence', r.status === 400 && b.error === 'bad_request' && b.message === 'Send 2000 lines or fewer in one request.', b)
    eq('capture: the refused request made no database call', calls.length, 0)
    r = await jpost(R.capture, { lines: many(cap) })
    check('capture: 2000 lines passes', r.status === 200 && calls.length === 1 && calls[0].args.p_lines.length === 2000)

    eq('the review cap is 2000 actions', R.server.MAX_REVIEW_ACTIONS, 2000)
    const acts = (n) => Array.from({ length: n }, (_, i) => ({ line_id: i + 1, action: 'CONFIRM' }))
    setup({ rpc_stocktake_review: async (a) => ({ data: { done: a.p_actions.length, rejected: [] } }) })
    r = await jpost(R.review, { actions: acts(R.server.MAX_REVIEW_ACTIONS + 1) })
    b = await jbody(r)
    check('review: 2001 actions is a 400 with a plain sentence', r.status === 400 && b.error === 'bad_request' && b.message === 'Send 2000 lines or fewer in one request.', b)
    eq('review: the refused request made no database call', calls.length, 0)
    r = await jpost(R.review, { actions: acts(R.server.MAX_REVIEW_ACTIONS) })
    check('review: 2000 actions passes', r.status === 200 && calls.length === 1)

    eq('the cancel reason cap is 300 characters', R.server.MAX_CANCEL_REASON, 300)
    setup({ rpc_stocktake_cancel: async () => ({ data: { ok: true, status: 'CANCELLED' } }) })
    r = await jpost(R.cancel, { reason: 'x'.repeat(301) })
    b = await jbody(r)
    check('cancel: a 301 character reason is a 400 with a plain sentence', r.status === 400 && b.error === 'bad_request' && b.message === 'Keep the reason to 300 characters or fewer.', b)
    eq('cancel: the refused request made no database call', calls.length, 0)
    r = await jpost(R.cancel, { reason: 'x'.repeat(300) })
    check('cancel: a 300 character reason passes', r.status === 200 && calls[0].args.p_reason.length === 300)
    r = await jpost(R.cancel, { reason: '  ' + 'y'.repeat(300) + '  ' })
    check('cancel: the cap counts the trimmed reason', r.status === 200 && calls[1].args.p_reason.length === 300)
  }

  // ---- typed capture: D2 and the bare database reasons
  {
    setup({ rpc_stocktake_capture: async (a) => ({ data: { set: a.p_lines.length, unchanged: 0, blank: 4, saved_at: 'T',
      rejected: [{ line_id: 9, reason: NOT_ON_CYCLE }, { line_id: 8, reason: 'a count above 10000 is not accepted, check the box and the scanner' }] } }) })
    const r = await jpost(R.capture, { lines: [
      { line_id: 1, front: '1,200', back: 0 },
      { line_id: 2, front: 3, back: '1,000' },
      { line_id: 3, front: '2,5', back: 0 },
      { line_id: 4, front: 'abc' },
      { line_id: 9, front: 1 },
    ] })
    const b = await jbody(r)
    eq('D2 typed: only the readable lines are sent', calls[0].args.p_lines, [{ line_id: 3, front: 2.5, back: 0 }, { line_id: 9, front: 1 }])
    eq('D2 typed: "1,200" in Front is refused with the exact sentence', b.rejected[0], { line_id: 1, reason: 'Enter 1200 or 1.2, not 1,200.' })
    eq('D2 typed: "1,000" in Back is refused with the exact sentence', b.rejected[1], { line_id: 2, reason: 'Enter 1200 or 1.2, not 1,200.' })
    eq('typed: a letter keeps its own sentence', b.rejected[2], { line_id: 4, reason: 'The Front count is not a number.' })
    eq('D3 typed: the database refusals are bare sentences', b.rejected.slice(3), [
      { line_id: 9, reason: 'this line is not on this list.' },
      { line_id: 8, reason: 'a count above 10000 is not accepted. Check the box.' },
    ])
    check('typed: the rest of the result passes through', b.set === 2 && b.blank === 4 && b.saved_at === 'T', b)
  }

  // ---- the TLX export header (D4)
  {
    const content = '10116++6001008646386+3+16001008646383+2.5'
    const tlx = (over) => ({ rpc_stocktake_export: async () => ({ data: { kind: 'TLX', filename: '10116_stocktake_2026-10-13_DAILY.tlx', content, line_count: 2, fractional_lines: 1, ...over } }) })
    setup(tlx({}))
    let r = await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    eq('D4 TLX: X-Fractional-Lines carries the count from the database', r.headers.get('x-fractional-lines'), '1')
    eq('D4 TLX: the file body is still the exact content', await r.text(), content)
    check('D4 TLX: the file headers are still set', r.headers.get('content-type').startsWith('text/plain') && r.headers.get('content-disposition') === 'attachment; filename="10116_stocktake_2026-10-13_DAILY.tlx"')
    setup(tlx({ fractional_lines: 0 }))
    r = await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    eq('D4 TLX: zero fractional lines is the header 0', r.headers.get('x-fractional-lines'), '0')
    setup(tlx({ fractional_lines: 12 }))
    r = await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    eq('D4 TLX: twelve fractional lines is the header 12', r.headers.get('x-fractional-lines'), '12')
    setup(tlx({ fractional_lines: undefined }))
    r = await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    let b = await jbody(r)
    check('D4 TLX: no fractional_lines from the database is a 502 tripwire, no file', r.status === 502 && b.error === 'tripwire', b)
    setup(tlx({ fractional_lines: -1 }))
    r = await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    eq('D4 TLX: a negative count is a tripwire too', r.status, 502)
    setup({ rpc_stocktake_export: async () => ({ data: { kind: 'MANUAL', filename: 'f_PLU.csv', rows: [], line_count: 0 } }) })
    r = await R.exporter.GET(new Request('http://x?kind=PLU'), ctx)
    check('D4 PLU: no TLX header on the PLU sheet', r.status === 200 && r.headers.get('x-fractional-lines') === null)
    // D6: an export can be repeated for a finalised list, one database call each
    setup(tlx({}))
    await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    await R.exporter.GET(new Request('http://x?kind=TLX'), ctx)
    eq('D6 the TLX export repeats, one database call each', calls.filter((c) => c.name === 'rpc_stocktake_export').length, 3)
  }

  // ---- history and events limits (D5)
  {
    setup({ rpc_stocktake_history: async () => ({ data: { store_code: '10116', cycles: [], by_day: [] } }), rpc_stocktake_events: async () => ({ data: [] }) })
    await R.history.GET(new Request('http://x?store=10116'))
    eq('D5 history asks for 60 cycles', calls.find((c) => c.name === 'rpc_stocktake_history').args, { p_store: '10116', p_limit: 60 })
    eq('D5 history asks for 1000 events', calls.find((c) => c.name === 'rpc_stocktake_events').args, { p_store: '10116', p_limit: 1000 })
    setup({ rpc_stocktake_events: async () => ({ data: [{ event_id: 1 }] }) })
    const r = await R.events.GET(new Request('http://x?cycle=' + CID))
    eq('D5 the events route asks for 1000 events for the cycle', calls[0].args, { p_cycle: CID, p_limit: 1000 })
    eq('D5 the events route still wraps the list', await jbody(r), { events: [{ event_id: 1 }] })
  }

  // ---- D6: the count sheet downloads again for a finalised list, counts filled in
  {
    const done = lines.map((l, i) => ({ ...l, front: i + 1, back: i % 2 }))
    const doc = { cycle: { ...cycleDoc.cycle, status: 'FINALISED', generated_on: '2026-10-13' }, counts: {}, lines: done, line_count: done.length, served: done.length }
    setup({ rpc_stocktake_cycle_get: async () => ({ data: doc }), rpc_stocktake_log_event: async () => ({ data: { ok: true } }) })
    const r = await R.sheet.GET(new Request('http://x'), ctx)
    const buf = Buffer.from(await r.arrayBuffer())
    check('D6 a finalised list downloads its sheet (200, xlsx)', r.status === 200 && buf[0] === 0x50 && buf[1] === 0x4b, r.status)
    const w = new ExcelJS.Workbook()
    await w.xlsx.load(buf)
    const bk = w.getWorksheet('BAKERY')
    // BAKERY is sorted by seq: FOURTEEN DIGIT EAN (done[1]), S/B B/ROLLS (done[0]), SCALE ROLLS (done[2])
    eq('D6 the counts are filled in on the finalised sheet', [bk.getCell('F2').value, bk.getCell('G2').value, bk.getCell('F3').value, bk.getCell('G3').value], [2, 1, 1, 0])
    eq('D6 the download is logged', calls.map((c) => c.name), ['rpc_stocktake_cycle_get', 'rpc_stocktake_log_event'])
    const again = await R.sheet.GET(new Request('http://x'), ctx)
    eq('D6 and it downloads again', again.status, 200)
  }

  // ---- the upload route
  {
    const form = (buf, name = 'sheet.xlsx') => { const fd = new FormData(); fd.append('file', new File([buf], name)); return fd }
    const post = (buf, name) => R.upload.POST(new Request('http://x', { method: 'POST', body: form(buf, name) }), ctx)
    const cycleGet = (n) => async () => ({ data: { ...cycleDoc, line_count: n, served: n } })

    // the sheet of section 2: five lines sent, three refused by the sheet reader
    setup({
      rpc_stocktake_cycle_get: cycleGet(lines.length),
      rpc_stocktake_capture: async () => ({ data: { set: 4, unchanged: 1, blank: 3, saved_at: 'T',
        rejected: [{ line_id: idOf('S/B B/ROLLS GARLIC'), reason: NOT_ON_CYCLE }] } }),
    })
    let r = await post(filled)
    let b = await jbody(r)
    eq('upload: the cycle line count is read first, then ONE capture call', calls.map((c) => c.name), ['rpc_stocktake_cycle_get', 'rpc_stocktake_capture'])
    eq('upload: the capture is source UPLOAD', calls[1].args.p_source, 'UPLOAD')
    eq('upload: the rows the route could not read are counted into the capture (p_unread)', calls[1].args.p_unread, 3)
    eq('upload (D1): both boxes of every sent line are numbers', calls[1].args.p_lines, [
      { line_id: idOf('FOURTEEN DIGIT EAN'), front: 3, back: 2 },
      { line_id: idOf('S/B B/ROLLS GARLIC'), front: 2.5, back: 0 },
      { line_id: idOf('GROC ONE'), front: 4, back: 0 },
      { line_id: idOf('LONG B ONE'), front: 0, back: 1.5 },
      { line_id: idOf('NO DEPARTMENT'), front: 3, back: 0 },
    ])
    check('upload: the response keeps its contract fields', r.status === 200 && b.set === 4 && b.unchanged === 1 && b.blank === 3 && b.saved_at === 'T' && b.unmatched_rows === 1, b)
    eq('upload (D3): every rejected item is { line_id, row, tab, reason } with a bare reason', b.rejected, [
      { line_id: idOf('GROC TWO'), row: 3, tab: 'GROCERIES FOODS A', reason: 'the Front box holds "abc", which is not a number.' },
      { line_id: idOf('LONG A ONE'), row: 2, tab: 'HEALTH AND BEAUTY AND PERSONAL', reason: 'the Front box holds "-1", which is below zero.' },
      { line_id: idOf('LONG A TWO'), row: 3, tab: 'HEALTH AND BEAUTY AND PERSONAL', reason: 'the Back box holds "-2", which is below zero.' },
      { line_id: idOf('S/B B/ROLLS GARLIC'), row: 3, tab: 'BAKERY', reason: 'this line is not on this list.' },
    ])

    // D2 through the route
    setup({ rpc_stocktake_cycle_get: cycleGet(lines.length), rpc_stocktake_capture: capOk })
    r = await post(await handSheet([{ name: 'BAKERY', rows: [[idOf('GROC ONE'), '1,200', null]] }]))
    b = await jbody(r)
    check('D2 route: a thousands comma is refused with the sentence, tab and row',
      JSON.stringify(b.rejected) === JSON.stringify([{ line_id: idOf('GROC ONE'), row: 2, tab: 'BAKERY', reason: 'Enter 1200 or 1.2, not 1,200.' }]), b.rejected)

    // a duplicate LineId through the route
    setup({ rpc_stocktake_cycle_get: cycleGet(lines.length), rpc_stocktake_capture: capOk })
    r = await post(await handSheet([{ name: 'BAKERY', rows: [[idOf('GROC ONE'), 3, 1], [idOf('GROC ONE'), 8, 8]] }]))
    b = await jbody(r)
    eq('dup route: only the first row is sent', calls[1].args.p_lines, [{ line_id: idOf('GROC ONE'), front: 3, back: 1 }])
    eq('dup route: the refused duplicate is counted as unread', calls[1].args.p_unread, 1)
    eq('dup route: the later row comes back refused', b.rejected, [{ line_id: idOf('GROC ONE'), row: 3, tab: 'BAKERY', reason: 'this line is already on row 2 of tab BAKERY.' }])

    // more lines to send than the cycle holds
    setup({ rpc_stocktake_cycle_get: cycleGet(2), rpc_stocktake_capture: capOk })
    r = await post(await handSheet([{ name: 'BAKERY', rows: [[1, 1, 0], [2, 1, 0], [3, 1, 0]] }]))
    b = await jbody(r)
    check('upload: more lines to send than the cycle holds is a 422 and nothing is captured',
      r.status === 422 && b.error === 'too_many_lines' && typeof b.message === 'string' && !calls.some((c) => c.name === 'rpc_stocktake_capture'), b)
    setup({ rpc_stocktake_cycle_get: cycleGet(3), rpc_stocktake_capture: capOk })
    r = await post(await handSheet([{ name: 'BAKERY', rows: [[1, 1, 0], [2, 1, 0], [3, 1, 0]] }]))
    eq('upload: exactly as many lines as the cycle holds passes', r.status, 200)
    setup({ rpc_stocktake_cycle_get: cycleGet(3), rpc_stocktake_capture: capOk })
    r = await post(await handSheet([{ name: 'BAKERY', rows: [[1, 1, 0], [1, 1, 0], [2, 1, 0], [3, null, null], [3, 4, 4]] }]))
    eq('upload: refused duplicates and blank rows do not count against the cycle line count', r.status, 200)
    setup({ rpc_stocktake_cycle_get: async () => ({ data: { ...cycleDoc, line_count: undefined } }), rpc_stocktake_capture: capOk })
    r = await post(filled)
    check('upload: a cycle with no line count is a 502 tripwire and nothing is captured', r.status === 502 && !calls.some((c) => c.name === 'rpc_stocktake_capture'))
    setup({ rpc_stocktake_cycle_get: async () => ({ error: { message: 'unknown cycle ' + CID, code: 'P0001' } }) })
    r = await post(filled)
    eq('upload: an unknown cycle is a 404', r.status, 404)

    // the zip bomb: refused before the cycle is read, before the sheet is opened
    const bombZip = new JSZip()
    bombZip.file('[Content_Types].xml', '<Types/>')
    bombZip.file('xl/worksheets/sheet1.xml', Buffer.alloc(MAX_SHEET_XML_BYTES + 1))
    const bombBuf = await bombZip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 9 } })
    setup({ rpc_stocktake_cycle_get: cycleGet(9), rpc_stocktake_capture: capOk })
    const t1 = Date.now()
    r = await post(bombBuf)
    b = await jbody(r)
    check('bomb route: a worksheet over 20 MB is a 413 file_too_large with a plain sentence',
      r.status === 413 && b.error === 'file_too_large' && typeof b.message === 'string' && b.message.length > 0, b)
    eq('bomb route: refused before any database call', calls.length, 0)
    check('bomb route: the refusal came fast (' + (Date.now() - t1) + ' ms)', Date.now() - t1 < 5000)
    const totalZip = new JSZip()
    const part = Math.floor(MAX_UNZIPPED_BYTES / 3) + 1
    for (const n of ['a', 'b', 'c']) totalZip.file('xl/media/' + n + '.bin', Buffer.alloc(part))
    setup({ rpc_stocktake_cycle_get: cycleGet(9), rpc_stocktake_capture: capOk })
    r = await post(await totalZip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 9 } }))
    b = await jbody(r)
    check('bomb route: more than 50 MB in all is a 413 file_too_large', r.status === 413 && b.error === 'file_too_large' && calls.length === 0, b)

    // the old checks still stand
    setup({ rpc_stocktake_cycle_get: cycleGet(9), rpc_stocktake_capture: capOk })
    r = await post(Buffer.concat([Buffer.from('PK\x03\x04'), Buffer.from('garbage garbage')]))
    b = await jbody(r)
    check('upload: a broken zip is still a 422 bad_file', r.status === 422 && b.error === 'bad_file', b)
    r = await post(Buffer.alloc(R.server.MAX_UPLOAD_BYTES + 1, 1))
    eq('upload: over 5 MB is still a 413', r.status, 413)
    r = await post(filled, 'sheet.xls')
    eq('upload: .xls is still a 415', r.status, 415)

    // a request with no Content-Length is read with a running count and cut off at the limit
    const CHUNK = 64 * 1024
    let pulled = 0
    let cancelled = false
    const endless = new ReadableStream({
      pull(controller) { pulled += CHUNK; controller.enqueue(new Uint8Array(CHUNK)) },
      cancel() { cancelled = true },
    })
    setup({ rpc_stocktake_cycle_get: cycleGet(9), rpc_stocktake_capture: capOk })
    r = await R.upload.POST(new Request('http://x', {
      method: 'POST', body: endless, duplex: 'half', headers: { 'content-type': 'multipart/form-data; boundary=zz' },
    }), ctx)
    b = await jbody(r)
    check('stream: a body with no Content-Length that never ends is a 413', r.status === 413 && b.error === 'file_too_large', b)
    check('stream: the read stopped at the limit (' + pulled + ' bytes pulled) and the stream was cancelled',
      cancelled === true && pulled <= R.server.MAX_UPLOAD_BYTES + R.server.MULTIPART_SLACK_BYTES + 4 * CHUNK, { pulled, cancelled })
    eq('stream: no database call was made', calls.length, 0)

    // a good file sent as a stream with no Content-Length still works
    const multipart = new Response(form(filled))
    const wire = Buffer.from(await multipart.arrayBuffer())
    const pieces = [wire.subarray(0, 1000), wire.subarray(1000, 5000), wire.subarray(5000)]
    setup({ rpc_stocktake_cycle_get: cycleGet(lines.length), rpc_stocktake_capture: capOk })
    r = await R.upload.POST(new Request('http://x', {
      method: 'POST', duplex: 'half', headers: { 'content-type': multipart.headers.get('content-type') },
      body: new ReadableStream({ start(c) { pieces.forEach((p) => c.enqueue(new Uint8Array(p))); c.close() } }),
    }), ctx)
    b = await jbody(r)
    check('stream: a chunked upload of a real sheet still reads (200, five lines sent)', r.status === 200 && calls[1].args.p_lines.length === 5, b)
    r = await R.upload.POST(new Request('http://x', { method: 'POST', body: 'x', headers: { 'content-length': String(9 * 1024 * 1024), 'content-type': 'multipart/form-data; boundary=x' } }), ctx)
    eq('upload: a declared 9 MB request is still refused before reading', r.status, 413)
    r = await R.upload.POST(new Request('http://x', { method: 'POST', body: 'not multipart', headers: { 'content-type': 'text/plain' } }), ctx)
    eq('upload: a body that is not multipart is a 400', r.status, 400)
    r = await R.upload.POST(new Request('http://x', { method: 'POST', body: new FormData() }), ctx)
    eq('upload: no file is a 400', r.status, 400)
  }
}

// ---------------------------------------------------------------- result

console.log('')
console.log(`${passed} passed, ${failed} failed`)
console.log(failed === 0 ? 'RESULT PASS' : 'RESULT FAIL')
process.exit(failed === 0 ? 0 : 1)
