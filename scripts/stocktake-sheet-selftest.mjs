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
// Prints PASS or FAIL per assertion and exits 1 if any failed.

import ExcelJS from 'exceljs'
import { createRequire } from 'node:module'

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
const { parseQty, parseLineId } = await import('../src/lib/stocktake/qty.js')

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
  eq('parseQty thousands comma is refused', parseQty('1,000,5').bad, 'is not a number')
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
eq('upload: comma decimal 2,5 read as 2.5, Back left alone', parsed.lines[1], { line_id: idOf('S/B B/ROLLS GARLIC'), front: 2.5, back: null })
eq('upload: a captured 4 and 0 come back as they were', parsed.lines[2], { line_id: idOf('GROC ONE'), front: 4, back: 0 })
eq('upload: Back-only padded comma string, Front null', parsed.lines[3], { line_id: idOf('LONG B ONE'), front: null, back: 1.5 })
eq('upload: formula result read as a number', parsed.lines[4], { line_id: idOf('NO DEPARTMENT'), front: 3, back: null })
check('upload: the blank pair (SCALE ROLLS) is not sent', !parsed.lines.some((l) => l.line_id === idOf('SCALE ROLLS')))
eq('upload: three rows rejected', parsed.rejected.length, 3)
eq('upload: letter rejected with tab and row', parsed.rejected.find((r) => r.line_id === idOf('GROC TWO')), {
  line_id: idOf('GROC TWO'), row: 3, tab: 'GROCERIES FOODS A',
  reason: 'GROCERIES FOODS A row 3: the Front box holds "abc", which is not a number.',
})
eq('upload: negative number rejected with tab and row', parsed.rejected.find((r) => r.line_id === idOf('LONG A ONE')), {
  line_id: idOf('LONG A ONE'), row: 2, tab: 'HEALTH AND BEAUTY AND PERSONAL',
  reason: 'HEALTH AND BEAUTY AND PERSONAL row 2: the Front box holds "-1", which is below zero.',
})
eq('upload: negative string rejected, the good Front is not sent alone', parsed.rejected.find((r) => r.line_id === idOf('LONG A TWO')), {
  line_id: idOf('LONG A TWO'), row: 3, tab: 'HEALTH AND BEAUTY AND PERSONAL',
  reason: 'HEALTH AND BEAUTY AND PERSONAL row 3: the Back box holds "-2", which is below zero.',
})
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

// ---------------------------------------------------------------- result

console.log('')
console.log(`${passed} passed, ${failed} failed`)
console.log(failed === 0 ? 'RESULT PASS' : 'RESULT FAIL')
process.exit(failed === 0 ? 0 : 1)
