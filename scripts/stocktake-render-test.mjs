// Render test for the stocktake page (SB-CC-STOCKTAKE-001 v1.2, UI half).
//
// Compiles the page's components with the SWC that ships with Next (no new dependency), renders each
// state of the contract's "UI states" section with fixtures through react-dom/server, and asserts the
// page TEXT. It also runs the save-as-typed queue against fake timers and scans the sources for the
// contract's hard rules (pure components, no keys or tables, text style, ASCII only, tokens declared once).
//
//   node scripts/stocktake-render-test.mjs
//
// Prints PASS or FAIL for every assertion and exits 1 if any failed. Does not touch the network.
import Module, { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const stkDir = path.join(root, 'src', 'app', 'stocktake')
const req = createRequire(path.join(root, 'package.json'))
const { transformSync } = req('next/dist/build/swc')
const React = req('react')
const { renderToStaticMarkup } = req('react-dom/server')

// ---- a small module loader: .jsx anywhere and .js inside the stocktake folder go through SWC ----
function compileInto(mod, filename) {
  const src = fs.readFileSync(filename, 'utf8')
  const out = transformSync(src, {
    filename,
    jsc: { parser: { syntax: 'ecmascript', jsx: true }, transform: { react: { runtime: 'automatic' } }, target: 'es2020' },
    module: { type: 'commonjs' },
    sourceMaps: false,
  })
  mod._compile(out.code, filename)
}
const plainJs = Module._extensions['.js']
Module._extensions['.jsx'] = compileInto
Module._extensions['.js'] = function (mod, filename) {
  if (filename.startsWith(stkDir + path.sep)) return compileInto(mod, filename)
  return plainJs(mod, filename)
}
const load = (rel) => req(path.join(stkDir, rel))

const EM_DASH = String.fromCharCode(0x2014)

// ---- tiny assertion kit ----
let passed = 0
let failed = 0
function check(name, ok, detail) {
  if (ok) {
    passed += 1
    console.log('PASS ' + name)
  } else {
    failed += 1
    console.log('FAIL ' + name + (detail ? '  >> ' + detail : ''))
  }
}
function has(name, text, needle) {
  check(name, text.includes(needle), 'missing: ' + needle + '\n       in: ' + text.slice(0, 400))
}
function lacks(name, text, needle) {
  check(name, !text.includes(needle), 'found: ' + needle)
}
function before(name, text, first, second) {
  const a = text.indexOf(first)
  const b = text.indexOf(second)
  check(name, a >= 0 && b >= 0 && a < b, 'positions ' + a + ' and ' + b + ' for "' + first + '" then "' + second + '"')
}
function textOf(html) {
  return html
    .replace(/<style[\s\S]*?<\/style>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim()
}
const h = React.createElement
function render(Component, props) {
  return renderToStaticMarkup(h(Component, props))
}
const everyText = []
function page(Component, props) {
  const html = render(Component, props)
  const text = textOf(html)
  everyText.push(text)
  return { html, text }
}

// ---- the modules under test ----
const fmt = load('components/format.js')
const saveQueueMod = load('saveQueue.js')
const StoreList = load('components/StoreList.jsx').default
const StoreScreen = load('components/StoreScreen.jsx').default
const HistoryTab = load('components/HistoryTab.jsx').default
const Page = load('page.jsx').default
const noop = () => {}

// ---- fixtures ----
function lineOf(id, o = {}) {
  return {
    line_id: id,
    seq: id,
    group_tag: 'SUSPECT',
    identifier: '6001234567890',
    identifier_kind: 'EAN',
    route: 'TLX',
    route_reason: null,
    product_code: 100000 + id,
    description: 'Item ' + id,
    size: '1kg',
    dept_name: 'Grocery',
    subdept_name: 'Rice',
    system_stock: 10,
    system_now: 10,
    unit_cost: 20,
    front: null,
    back: null,
    count_qty: null,
    variance_qty: null,
    variance_value: null,
    variance_pct: null,
    flagged: false,
    review_state: 'OPEN',
    recount_count: 0,
    captured_by: null,
    captured_at: null,
    story: 'The system claims R200 of stock on this line.',
    last_counted_date: null,
    ...o,
  }
}
function countsOf(lines, extra = {}) {
  const captured = lines.filter((l) => l.count_qty !== null && l.count_qty !== undefined).length
  return {
    lines: lines.length,
    captured,
    blank: lines.length - captured,
    flagged: lines.filter((l) => l.flagged).length,
    flagged_open: lines.filter((l) => l.flagged && l.review_state !== 'CONFIRMED').length,
    confirmed: lines.filter((l) => l.review_state === 'CONFIRMED').length,
    recounts: lines.filter((l) => l.review_state === 'RECOUNT').length,
    tlx_lines: lines.filter((l) => l.route === 'TLX').length,
    manual_lines: lines.filter((l) => l.route === 'MANUAL').length,
    ...extra,
  }
}
function cycleOf(o = {}) {
  return {
    cycle_id: '11111111-1111-4111-8111-111111111111',
    store_code: '10116',
    list_type: 'DAILY',
    subdept_name: null,
    status: 'CAPTURING',
    generated_by: 'pm@example.com',
    generated_at: '2026-10-13T05:12:00Z',
    generated_on: '2026-10-13',
    target_size: 200,
    pool_size: 5419,
    line_count: 6,
    ordering_basis: 'RULED',
    non_count_day: false,
    non_count_reason: null,
    finalised_by: null,
    finalised_at: null,
    cancelled_by: null,
    cancelled_at: null,
    cancel_reason: null,
    ...o,
  }
}
function docOf(lines, cycleOverrides = {}, countOverrides = {}) {
  return {
    status: 'ready',
    message: '',
    data: {
      cycle: cycleOf({ line_count: lines.length, ...cycleOverrides }),
      counts: countsOf(lines, countOverrides),
      lines,
      line_count: lines.length,
      served: lines.length,
    },
  }
}

const EAN13 = '6001234567890'
const EAN14 = '10600123456789'
const lines = [
  lineOf(1, { description: 'White Star Maize Meal 5kg', identifier: EAN13, count_qty: 10, front: 10, back: 0 }),
  lineOf(2, { description: 'Sunfoil Oil 750ml', identifier: EAN14, size: '750ml' }),
  lineOf(3, {
    description: 'Roll Brown Loose',
    dept_name: 'Bakery',
    identifier: '2113',
    identifier_kind: 'PLU',
    route: 'MANUAL',
    route_reason: 'PLU or scale line: counted by PLU or product code',
    story: 'The system shows 4 on hand and nothing has sold in 28 days.',
  }),
  lineOf(4, {
    description: 'Bread White Sliced',
    dept_name: 'Bakery',
    identifier: '104567',
    identifier_kind: 'PRODUCT_CODE',
    route: 'MANUAL',
    system_stock: 12,
    system_now: 9,
    count_qty: 12,
    front: 8,
    back: 4,
    last_counted_date: '2026-06-02',
  }),
  lineOf(5, { description: 'Mystery Item', dept_name: null, system_stock: 10, count_qty: 4, front: 4, back: 0, flagged: true, variance_qty: -6, variance_value: -120, variance_pct: -60 }),
  lineOf(6, { description: 'Cooldrink 2l', dept_name: 'Grocery', identifier: '6009876543210', review_state: 'RECOUNT', recount_count: 1 }),
]

const oneStore = {
  store_code: '10116',
  store_name: 'SPAR Delareyville',
  format: 'SPAR',
  daily_volume: 200,
  adhoc_batch: 200,
  today: '2026-10-13',
  pool: {
    pool: 6431,
    in_range: 9000,
    counted_91: 1012,
    uncounted: 5930,
    negative: 50,
    zero_stock: 12,
    cost_errors_out: 0,
    refreshed_at: '2026-10-13T03:30:00Z',
  },
  open_cycles: [
    {
      cycle_id: '11111111-1111-4111-8111-111111111111',
      list_type: 'DAILY',
      subdept_name: null,
      status: 'CAPTURING',
      generated_by: 'pm@example.com',
      generated_at: '2026-10-13T05:12:00Z',
      line_count: 200,
      captured: 143,
      flagged_open: 3,
    },
  ],
  last_finalised: null,
  awaiting_posting: 0,
  rest_day: { is_rest_day: false, reason: null },
}
const restStore = {
  ...oneStore,
  store_code: '80175',
  store_name: 'SPAR Ottosdal',
  today: '2026-10-17',
  open_cycles: [],
  awaiting_posting: 12,
  rest_day: { is_rest_day: true, reason: 'weekend' },
  pool: { ...oneStore.pool, uncounted: 1296 },
}
const dcStore = {
  ...oneStore,
  store_code: '21355',
  store_name: 'TOPS Sannieshof',
  daily_volume: 70,
  adhoc_batch: 70,
  open_cycles: [
    { cycle_id: '22222222-2222-4222-8222-222222222222', list_type: 'ADHOC', subdept_name: 'Bakery', status: 'PENDING_CAPTURE', generated_by: 'lizeka@example.com', generated_at: '2026-10-13T06:00:00Z', line_count: 70, captured: 0, flagged_open: 0 },
  ],
  rest_day: { is_rest_day: true, reason: 'DC delivery day' },
  pool: { ...oneStore.pool, uncounted: 166 },
}
const noPoolStore = { ...oneStore, store_code: '80579', store_name: 'TOPS Coligny', pool: null, open_cycles: [], rest_day: { is_rest_day: false, reason: null } }

const storeState = {
  store_code: '10116',
  draw: { NEGATIVE: 50, INACTIVE: 897, SUSPECT: 4472 },
  plu_lines: 82,
  confirm_lines: 120,
  cost_errors_out: 0,
  draw_refreshed_at: '2026-10-13T03:30:00Z',
  subdepts: [
    { subdept_name: 'Bakery', lines: 340 },
    { subdept_name: 'Spices', lines: 31 },
  ],
}

function screen(props) {
  return page(StoreScreen, {
    store: oneStore,
    storeState,
    tab: 'count',
    cycleId: null,
    cycle: {},
    generate: { subdept: '' },
    history: {},
    saveState: 'idle',
    savedAt: null,
    busy: null,
    actions: {},
    ...props,
  })
}
function cycleScreen(doc, extra = {}) {
  return screen({
    cycleId: doc.data ? doc.data.cycle.cycle_id : 'x',
    savedAt: '2026-10-13T12:07:00Z',
    cycle: {
      doc,
      capture: { drafts: {}, rowStates: {}, openRows: [], showOnlyBlank: false, keepVisible: [] },
      confirmedBy: {},
      finalise: { blankLines: [], unconfirmedLines: [] },
      upload: { result: null },
      exportNote: '',
      cancel: { open: false, reason: '' },
      ...extra.cycle,
    },
    ...extra.props,
  })
}

console.log('--- format helpers ---')
check('fmtInt groups thousands', fmt.fmtInt(5930) === '5,930')
check('fmtRand positive', fmt.fmtRand(400) === 'R400.00', fmt.fmtRand(400))
check('fmtRand negative uses an ASCII minus', fmt.fmtRand(-120.5) === '-R120.50', fmt.fmtRand(-120.5))
check('fmtPct negative', fmt.fmtPct(-33.333) === '-33.3%', fmt.fmtPct(-33.333))
check('fmtSigned', fmt.fmtSigned(3) === '+3' && fmt.fmtSigned(-4) === '-4' && fmt.fmtSigned(0) === '0')
check('fmtTime reads store time (UTC+2)', fmt.fmtTime('2026-10-13T12:07:00Z') === '14:07', fmt.fmtTime('2026-10-13T12:07:00Z'))
check('fmtDateTime', fmt.fmtDateTime('2026-10-13T14:20:00Z') === '13 Oct 16:20', fmt.fmtDateTime('2026-10-13T14:20:00Z'))
check('weekday of 2026-10-17 is Saturday', fmt.weekdayName('2026-10-17') === 'Saturday')
check('qtyText keeps 0 as a real count', fmt.qtyText(0) === '0')
check('qtyText of null is an empty box', fmt.qtyText(null) === '')
check('parseCountText: empty is null (clear)', fmt.parseCountText('  ') === null)
check('parseCountText: 0 is a number', fmt.parseCountText('0') === 0)
check('parseCountText: decimal comma', fmt.parseCountText('12,5') === 12.5)
check('parseCountText: decimal point', fmt.parseCountText('3.25') === 3.25)
check('parseCountText: letters refused', fmt.parseCountText('12a') === undefined)
check('parseCountText: negative refused', fmt.parseCountText('-3') === undefined)
check('parseCountText: two points refused', fmt.parseCountText('1.2.3') === undefined)
check('count window comes from the data (counted_91 key)', fmt.countWindowDays({ counted_91: 1 }) === 91)
check('count window from a value field wins', fmt.countWindowDays({ counted_91: 1, count_window_days: 60 }) === 60)

console.log('--- 1. Home: the store list ---')
{
  const { text } = page(StoreList, { stores: [oneStore, restStore, dcStore, noPoolStore], onOpenStore: noop })
  has('home names a store and its code', text, 'SPAR Delareyville 10116')
  has('home shows the pending line with progress', text, 'Daily list pending: 143 of 200 captured')
  has('home shows the uncounted figure', text, '5,930 lines not counted in 91 days')
  has('home shows the weekend note by weekday', text, 'Saturday: no forced count')
  has('home shows the DC delivery day note', text, 'DC delivery day: no forced count')
  has('home shows no list pending', text, 'No list pending today')
  has('home names a batch with its sub-department', text, 'Batch (Bakery) pending: 0 of 70 captured')
  has('home shows lines waiting for Sigma', text, '12 counted lines wait for Sigma to post')
  has('home says when the draw is not stocked', text, 'The draw for this store is not stocked yet')
}

console.log('--- 2a. Store screen: Generate and Pending ---')
{
  const { text, html } = screen({ store: { ...oneStore, open_cycles: [] } })
  has('header shows the store name and code', text, 'SPAR Delareyville 10116')
  has('header shows today', text, 'Tue 13 Oct')
  has('header shows the draw stocked time', text, 'Draw stocked 05:30')
  has('tabs read Count and History', text, 'Count History')
  has('daily button size is min(volume, draw total)', text, 'Generate daily list (200 lines)')
  has('confirmation button size', text, 'Generate confirmation count (120)')
  has('PLU button size', text, 'Generate PLU and scale list (82 lines)')
  has('batch button needs a sub-department first', text, 'Pick a sub-department first.')
  has('sub-department picker lists the sub-departments', text, 'Bakery (340)')
  has('group counts are plain text', text, 'Lines left in the pool: 50 negative, 897 inactive, 4,472 suspect and 0 zero stock.')
  has('no pending lists says so', text, 'No list pending today.')
  lacks('no rest day note on a working day', text, 'No forced count on')
  check('batch button is off with no sub-department', /<button[^>]*disabled[^>]*>Generate batch \(0 lines\)/.test(html))

  const picked = screen({ store: { ...oneStore, open_cycles: [] }, generate: { subdept: 'Bakery' } })
  has('batch size is min(batch, sub-department lines)', picked.text, 'Generate batch (200 lines)')
  const small = screen({ store: { ...oneStore, open_cycles: [] }, generate: { subdept: 'Spices' } })
  has('a small sub-department is taken whole', small.text, 'Generate batch (31 lines)')

  const tops = screen({ store: { ...dcStore, open_cycles: [] }, storeState: { ...storeState, draw: { NEGATIVE: 4, INACTIVE: 12, SUSPECT: 15 } } })
  has('a pool smaller than the volume is taken whole', tops.text, 'Generate daily list (31 lines)')
  has('DC delivery day note blocks nothing', tops.text, 'No forced count on DC delivery days. You can still generate a list.')

  const rest = screen({ store: { ...restStore, open_cycles: [] } })
  has('weekend note', rest.text, 'No forced count on weekend days. You can still generate a list.')
  check('rest day does not disable the daily button', !/<button[^>]*disabled[^>]*>Generate daily list/.test(rest.html))

  const loading = screen({ store: { ...oneStore, open_cycles: [] }, storeState: null })
  has('generate shows Loading before the draw figures arrive', loading.text, 'Loading')
}

console.log('--- 2b. Store screen: Pending cards ---')
{
  const { text, html } = screen({})
  has('pending section', text, 'Pending lists')
  has('card names the list', text, 'Daily list')
  has('card says who generated it and when', text, 'Generated by pm@example.com on 13 Oct 07:12')
  has('card progress sentence', text, '143 of 200 captured')
  has('card says flagged lines need a decision', text, '3 lines differ from the system and need a decision.')
  has('card has Open', text, 'Open')
  has('card has Download sheets', text, 'Download sheets')
  check('an open daily list switches its generate button off', /<button[^>]*disabled[^>]*>Generate daily list/.test(html))
  has('and says why', text, 'This list is open. Finish it or cancel it first.')
  const working = screen({ busy: 'download:11111111-1111-4111-8111-111111111111' })
  has('card shows Working while the sheet downloads', working.text, 'Working')
}

console.log('--- 2c. The count table ---')
{
  const doc = docOf(lines)
  const { text, html } = cycleScreen(doc)
  has('progress sentence N of M captured', text, '3 of 6 captured')
  has('saved stamp in the header', text, 'Saved 14:07')
  has('download button', text, 'Download count sheets')
  has('upload button', text, 'Upload filled sheet')
  has('blank filter toggle', text, 'Show only blank lines')
  for (const col of ['Code', 'Barcode', 'Description', 'Size', 'System stock', 'Count']) has('column ' + col, text, col)
  has('department Grocery is a section row', text, 'Grocery')
  has('department Bakery is a section row', text, 'Bakery')
  has('a line with no department sits under Other', text, 'Other')
  has('13-digit EAN beginning with 6 is shown whole', text, EAN13)
  has('14-digit EAN is shown whole', text, EAN14)
  lacks('no scientific notation anywhere', html, 'E+')
  has('product code is shown', text, '100001')
  has('PLU line carries the small word PLU', html, '<span class="stk-kind"> PLU</span>')
  has('product code line carries the small word code', html, '<span class="stk-kind"> code</span>')
  has('count box is a decimal keypad box', html, 'inputMode="decimal"')
  has('stored count shows in its box', html, 'value="10"')
  has('an uploaded split shows front + back under the box', text, '8 + 4')
  has('a recount line says so quietly', html, '<span class="stk-sub">Recount</span>')
  has('saved tick per captured row', html, 'data-saved="true"')
  const table = html.slice(html.indexOf('<table'), html.indexOf('</table>') + 8)
  check('no badge or chip class inside the table', !/badge|chip/i.test(table))
  check('no inline colour inside the table', !/style=/.test(table))
  lacks('the priority reason is hidden until the row is opened', text, 'The system claims R200')
  has('narrow screens carry barcode and size under the description', html, 'stk-narrow-only')

  const opened = cycleScreen(doc, { cycle: { capture: { drafts: {}, rowStates: {}, openRows: [3, 4], showOnlyBlank: false, keepVisible: [] } } })
  has('an opened row shows its priority reason', opened.text, 'The system shows 4 on hand and nothing has sold in 28 days.')
  has('an opened PLU row explains the route', opened.text, 'PLU or scale line: counted by PLU or product code.')
  has('an opened row shows stock that moved since issue', opened.text, 'The system stock is now 9.')
  has('an opened row shows the last count date', opened.text, 'Last counted Tue 2 Jun.')

  const blankOnly = cycleScreen(doc, { cycle: { capture: { drafts: {}, rowStates: {}, openRows: [], showOnlyBlank: true, keepVisible: [] } } })
  lacks('blank filter hides counted lines', blankOnly.text, 'White Star Maize Meal 5kg')
  has('blank filter keeps blank lines', blankOnly.text, 'Sunfoil Oil 750ml')
  const kept = cycleScreen(doc, { cycle: { capture: { drafts: {}, rowStates: {}, openRows: [], showOnlyBlank: true, keepVisible: [1] } } })
  has('a line edited while the filter is on stays in view', kept.text, 'White Star Maize Meal 5kg')
  const emptied = cycleScreen(doc, { cycle: { capture: { drafts: { 1: '' }, rowStates: {}, openRows: [], showOnlyBlank: true, keepVisible: [] } } })
  has('a box the user emptied counts as blank', emptied.text, 'White Star Maize Meal 5kg')
  const typed = cycleScreen(doc, { cycle: { capture: { drafts: { 2: '0' }, rowStates: {}, openRows: [], showOnlyBlank: true, keepVisible: [] } } })
  lacks('a typed 0 is a count, so the line leaves the blank filter', typed.text, 'Sunfoil Oil 750ml')
  const typedShown = cycleScreen(doc, { cycle: { capture: { drafts: { 2: '0' }, rowStates: {}, openRows: [], showOnlyBlank: false, keepVisible: [] } } })
  has('a typed 0 shows in the box', typedShown.html, 'value="0"')

  const bad = cycleScreen(doc, { cycle: { capture: { drafts: { 2: 'abc' }, rowStates: { 2: { state: 'error', message: 'Enter a number such as 12 or 3.5.' } }, openRows: [], showOnlyBlank: false, keepVisible: [] } } })
  has('a bad entry shows a plain row error', bad.text, 'Enter a number such as 12 or 3.5.')
  has('and offers Try again', bad.text, 'Try again')
  has('the bad text stays in the box', bad.html, 'value="abc"')
  const saving = cycleScreen(doc, { cycle: { capture: { drafts: { 2: '5' }, rowStates: { 2: { state: 'saving' } }, openRows: [], showOnlyBlank: false, keepVisible: [] } } })
  has('a saving row says Saving', saving.text, 'Saving')
  const failedState = cycleScreen(doc, { props: { saveState: 'error' } })
  has('the header warns when something did not save', failedState.text, 'Some counts are not saved')
  const savingHeader = cycleScreen(doc, { props: { saveState: 'saving' } })
  has('the header says Saving while a save runs', savingHeader.text, 'Saving')
  lacks('and not a stale Saved time', savingHeader.text, 'Saved 14:07')
  const loadingDoc = cycleScreen({ status: 'loading', data: null, message: '' }, { props: { cycleId: 'x' } })
  has('a list that is loading says Loading', loadingDoc.text, 'Loading')
  const errDoc = cycleScreen({ status: 'error', data: null, message: 'The list failed its own check and was not shown. Try again.' }, { props: { cycleId: 'x' } })
  has('a list that failed shows the plain sentence', errDoc.text, 'The list failed its own check and was not shown. Try again.')
}

console.log('--- 2d. Finalise ---')
{
  const blank12 = Array.from({ length: 12 }, (_, i) => ({ line_id: 200 + i, product_code: 300000 + i, identifier: '60012345678' + (10 + i), description: 'Blank item ' + (i + 1), seq: i + 1 }))
  const doc = docOf(lines)
  const { text, html } = cycleScreen(doc, { cycle: { finalise: { blankLines: blank12, unconfirmedLines: [] } } })
  has('blocking message names the count', text, '12 lines have no count. Enter 0 where the item is not on the shelf.')
  has('first listed line shows product code and description', text, '300000 Blank item 1')
  has('last listed line shows product code and description', text, '300011 Blank item 12')
  check('listed lines are links to their rows', blank12.every((b) => html.includes('href="#stk-row-' + b.line_id + '"')))
  has('Finalise button', text, 'Finalise')
  const one = cycleScreen(doc, { cycle: { finalise: { blankLines: blank12.slice(0, 1), unconfirmedLines: [] } } })
  has('singular blocking message', one.text, '1 line has no count. Enter 0 where the item is not on the shelf.')
  const diff = cycleScreen(doc, { cycle: { finalise: { blankLines: [], unconfirmedLines: [{ line_id: 5 }, { line_id: 6 }, { line_id: 7 }] } } })
  has('flagged lines need a decision', diff.text, '3 lines differ from the system and need a decision.')
  has('and link to the review', diff.html, 'href="#stk-review"')
  const none = cycleScreen(doc)
  lacks('no blocking message when nothing blocks', none.text, 'have no count')
  const working = cycleScreen(doc, { props: { busy: 'finalise' } })
  has('Finalise shows Working while it runs', working.text, 'Working')
  check('and the button is disabled', /<button[^>]*disabled[^>]*>Working<\/button>/.test(working.html))
}

console.log('--- 2e. Variance review ---')
{
  const flagged = [
    lineOf(1, { description: 'Alpha small', count_qty: 5, front: 5, back: 0, system_stock: 10, flagged: true, variance_qty: -5, variance_value: -50, variance_pct: -50 }),
    lineOf(2, { description: 'Bravo large gain', count_qty: 30, front: 30, back: 0, system_stock: 10, flagged: true, variance_qty: 20, variance_value: 400, variance_pct: 200 }),
    lineOf(3, { description: 'Charlie mid loss', count_qty: 4, front: 4, back: 0, system_stock: 10, flagged: true, variance_qty: -6, variance_value: -120.5, variance_pct: -33.333 }),
    lineOf(4, { description: 'Delta confirmed', count_qty: 11, front: 11, back: 0, system_stock: 10, flagged: true, review_state: 'CONFIRMED', variance_qty: 1, variance_value: 10, variance_pct: 10 }),
    lineOf(5, { description: 'Echo quiet match', count_qty: 10, front: 10, back: 0, system_stock: 10 }),
    lineOf(6, { description: 'Foxtrot unpriced', count_qty: 9, front: 9, back: 0, system_stock: 10, flagged: true, stale: true, variance_qty: -1, variance_value: -999, variance_pct: -10 }),
  ]
  const doc = docOf(flagged)
  const { text, html } = cycleScreen(doc, { cycle: { confirmedBy: { 4: 'lizeka@example.com' } } })
  const reviewHtml = html.slice(html.indexOf('id="stk-review"'), html.indexOf('id="stk-finalise"'))
  const reviewText = textOf(reviewHtml)
  has('review heading', text, 'Lines that differ from the system')
  before('largest absolute rand first', reviewText, 'Bravo large gain', 'Charlie mid loss')
  before('then the next largest', reviewText, 'Charlie mid loss', 'Alpha small')
  before('then the smallest', reviewText, 'Alpha small', 'Delta confirmed')
  lacks('a line that is not flagged is not listed in the review', reviewText, 'Echo quiet match')
  lacks('a flagged line the server has not re-priced waits out of the review', reviewText, 'Foxtrot unpriced')
  has('variance value in rand', reviewText, 'R400.00')
  has('negative variance value', reviewText, '-R120.50')
  has('variance percent', reviewText, '-33.3%')
  has('variance quantity', reviewText, '+20')
  has('system stock and count are shown', reviewText, 'System stock 10 Count 30')
  has('Confirm button', reviewHtml, '>Confirm<')
  has('Recount button', reviewHtml, '>Recount<')
  has('a confirmed line says who', reviewText, 'Confirmed by lizeka@example.com')
  const confirmedItem = html.slice(html.indexOf('id="stk-vr-4"'), html.indexOf('</li>', html.indexOf('id="stk-vr-4"')))
  lacks('a confirmed line has no Confirm button', confirmedItem, '>Confirm<')
  has('a confirmed line keeps Recount', confirmedItem, '>Recount<')
  const noName = cycleScreen(doc, { cycle: { confirmedBy: {} } })
  has('a confirmed line with no name yet says Confirmed', noName.text, 'Confirmed')
  const noFlags = cycleScreen(docOf(lines.slice(0, 4)))
  lacks('no review when nothing is flagged', noFlags.text, 'Lines that differ from the system')
}

console.log('--- 2f. Ready (FINALISED) ---')
{
  const done = lines.map((l) => (l.count_qty === null ? { ...l, count_qty: 0, front: 0, back: 0 } : l)).map((l) => ({ ...l, flagged: false }))
  const doc = docOf(done, { status: 'FINALISED', finalised_by: 'pm@example.com', finalised_at: '2026-10-13T14:20:00Z' }, { tlx_lines: 190, manual_lines: 10 })
  const { text, html } = cycleScreen(doc)
  has('ready summary sentence', text, 'Finalised by pm@example.com on 13 Oct 16:20. 6 of 6 lines counted.')
  has('TLX export button with its line count', text, 'Export TLX file (190 lines)')
  has('PLU export button with its line count', text, 'Export PLU and scale sheet (10 lines)')
  has('Sigma note', text, 'Import the TLX in Sigma. The counts post overnight and the lines leave the list.')
  lacks('no Finalise panel once final', html, 'id="stk-finalise"')
  lacks('no capture inputs once final', html, '<input')
  lacks('no download or upload once final', text, 'Upload filled sheet')
  lacks('no cancel once final', text, 'Cancel this list')
  const noTlx = cycleScreen(docOf(done, { status: 'FINALISED', finalised_by: 'a', finalised_at: '2026-10-13T14:20:00Z' }, { tlx_lines: 0, manual_lines: 10 }))
  lacks('no TLX button when there are no TLX lines', noTlx.text, 'Export TLX file')
  has('PLU button still shows', noTlx.text, 'Export PLU and scale sheet (10 lines)')
  const noPlu = cycleScreen(docOf(done, { status: 'FINALISED', finalised_by: 'a', finalised_at: '2026-10-13T14:20:00Z' }, { tlx_lines: 190, manual_lines: 0 }))
  lacks('no PLU button when there are no manual lines', noPlu.text, 'Export PLU and scale sheet')
  has('TLX button still shows', noPlu.text, 'Export TLX file (190 lines)')
  const note = cycleScreen(doc, { cycle: { exportNote: 'Downloaded 10116_stocktake_2026-10-13_DAILY.tlx.' } })
  has('export confirmation sentence', note.text, 'Downloaded 10116_stocktake_2026-10-13_DAILY.tlx.')
  const exporting = cycleScreen(doc, { props: { busy: 'export:TLX' } })
  has('export button shows Working', exporting.text, 'Working')
  const cancelled = cycleScreen(docOf(lines, { status: 'CANCELLED', cancelled_by: 'pm@example.com', cancelled_at: '2026-10-13T15:00:00Z', cancel_reason: 'wrong store' }))
  has('a cancelled list says so', cancelled.text, 'This list was cancelled by pm@example.com on 13 Oct 17:00. Reason: wrong store.')
  lacks('a cancelled list has no table', cancelled.html, '<table')
}

console.log('--- 2g. Upload result and cancel ---')
{
  const doc = docOf(lines)
  const result = { set: 140, unchanged: 3, blank: 57, rejected: [{ row: 12, reason: 'Front is not a number (tab Grocery)' }, { row: 15, reason: 'A count cannot be negative (tab Bakery)' }], unmatched_rows: 1, saved_at: '2026-10-13T12:07:00Z' }
  const { text } = cycleScreen(doc, { cycle: { upload: { result } } })
  has('upload sentence', text, 'Sheet read: 140 lines set, 3 unchanged. 2 rows were skipped.')
  has('skipped rows are listed with row number and reason', text, 'Row 12: Front is not a number (tab Grocery)')
  has('second skipped row', text, 'Row 15: A count cannot be negative (tab Bakery)')
  has('unmatched rows are named', text, '1 row is not on this list.')
  const clean = cycleScreen(doc, { cycle: { upload: { result: { set: 1, unchanged: 0, blank: 5, rejected: [], unmatched_rows: 0 } } } })
  has('a clean upload has no skipped sentence', clean.text, 'Sheet read: 1 line set, 0 unchanged.')
  lacks('and says nothing about skipped rows', clean.text, 'skipped')
  const link = cycleScreen(doc)
  has('cancel starts as a small text link', link.html, '>Cancel this list<')
  const confirm = cycleScreen(doc, { cycle: { cancel: { open: true, reason: '' } } })
  has('cancel asks first', confirm.text, 'Cancel this list? Its lines go back to the pool and the counts typed so far are not used.')
  has('cancel confirm button', confirm.text, 'Yes, cancel the list')
  has('cancel keep button', confirm.text, 'Keep the list')
  const uploading = cycleScreen(doc, { props: { busy: 'upload' } })
  has('upload shows Working', uploading.text, 'Working')
}

console.log('--- 3. History tab ---')
{
  const history = {
    store_code: '10116',
    cycles: [
      { cycle_id: 'c1', list_type: 'DAILY', subdept_name: null, status: 'FINALISED', generated_by: 'pm@example.com', generated_at: '2026-10-13T05:12:00Z', finalised_by: 'lizeka@example.com', finalised_at: '2026-10-13T14:20:00Z', line_count: 200, captured: 200, flagged: 7, variance_value: -1250.5 },
      { cycle_id: 'c2', list_type: 'ADHOC', subdept_name: 'Bakery', status: 'CAPTURING', generated_by: 'pm@example.com', generated_at: '2026-10-12T05:12:00Z', finalised_by: null, finalised_at: null, line_count: 70, captured: 20, flagged: 0, variance_value: null },
      { cycle_id: 'c3', list_type: 'PLU', subdept_name: null, status: 'CANCELLED', generated_by: 'pm@example.com', generated_at: '2026-10-11T05:12:00Z', finalised_by: null, finalised_at: null, line_count: 82, captured: 0, flagged: 0, variance_value: null },
    ],
    by_day: [
      { day: '2026-10-13', cycles_generated: 1, lines_issued: 200, cycles_finalised: 1, lines_counted: 200 },
      { day: '2026-10-12', cycles_generated: 1, lines_issued: 70, cycles_finalised: 0, lines_counted: 20 },
    ],
  }
  const events = [
    { event_id: 9, cycle_id: 'c1', store_code: '10116', event_type: 'FINALISE', line_id: null, actor: 'lizeka@example.com', at: '2026-10-13T14:20:00Z', detail: { lines: 200, tlx_lines: 190, manual_lines: 10 } },
    { event_id: 8, cycle_id: 'c1', store_code: '10116', event_type: 'EDIT', line_id: 4, actor: 'lizeka@example.com', at: '2026-10-13T12:07:00Z', detail: { product_code: 104567, source: 'TYPED', from: 3, to: 5 } },
    { event_id: 7, cycle_id: 'c1', store_code: '10116', event_type: 'EDIT', line_id: 5, actor: 'lizeka@example.com', at: '2026-10-13T12:06:00Z', detail: { product_code: 104568, source: 'TYPED', from: null, to: 0 } },
    { event_id: 6, cycle_id: 'c1', store_code: '10116', event_type: 'UPLOAD', line_id: null, actor: 'pm@example.com', at: '2026-10-13T11:00:00Z', detail: { lines_set: 140, unchanged: 3, rejected: 2 } },
    { event_id: 5, cycle_id: 'c1', store_code: '10116', event_type: 'DOWNLOAD', line_id: null, actor: 'pm@example.com', at: '2026-10-13T06:00:00Z', detail: { kind: 'xlsx', lines: 200, tabs: 7 } },
    { event_id: 4, cycle_id: 'c1', store_code: '10116', event_type: 'CONFIRM', line_id: 5, actor: 'pm@example.com', at: '2026-10-13T13:00:00Z', detail: { product_code: 104569, count: 4, variance_qty: -6, variance_value: -120 } },
    { event_id: 3, cycle_id: 'c1', store_code: '10116', event_type: 'RECOUNT', line_id: 6, actor: 'pm@example.com', at: '2026-10-13T13:10:00Z', detail: { product_code: 104570, prior_count: 12, prior_variance_qty: 2 } },
    { event_id: 2, cycle_id: 'c1', store_code: '10116', event_type: 'GENERATE', line_id: null, actor: 'pm@example.com', at: '2026-10-13T05:12:00Z', detail: { list_type: 'DAILY', lines: 200 } },
    { event_id: 1, cycle_id: 'c1', store_code: '10116', event_type: 'EXPORT_TLX', line_id: null, actor: 'pm@example.com', at: '2026-10-13T14:30:00Z', detail: { line_count: 190, fractional_lines: 0, filename: 'x.tlx', md5: 'abc' } },
  ]
  const lineHistory = {
    value: '104567',
    onValueChange: noop,
    onLookup: noop,
    busy: null,
    product: '104567',
    message: '',
    result: {
      app: [{ cycle_id: 'c1', list_type: 'DAILY', date: '2026-10-13', status: 'FINALISED', system_stock: 12, count_qty: 10, variance_qty: -2, variance_value: -40, captured_by: 'lizeka@example.com' }],
      ledger: [{ date: '2026-08-02', correction: -3, soh_before: 15, soh_after: 12, correction_pct: 20 }],
    },
  }
  const props = { loading: false, message: '', history, events, selectedCycleId: 'c1', cycleEvents: events.slice(0, 2), lineHistory, onSelectCycle: noop, onOpenCycle: noop }
  const { text, html } = page(HistoryTab, props)
  for (const heading of ['Lists', 'Adherence by day', 'Event log', 'Count history of a line']) has('history heading ' + heading, text, heading)
  for (const col of ['Lists generated', 'Lines issued', 'Lists finalised', 'Lines counted']) has('adherence column ' + col, text, col)
  has('adherence day', text, 'Tue 13 Oct')
  has('cycles table: list and status', text, 'Daily list Finalised')
  has('cycles table: batch with its sub-department', text, 'Batch (Bakery)')
  has('cycles table: generated by and time', text, 'pm@example.com 13 Oct 07:12')
  has('cycles table: finalised by and time', text, 'lizeka@example.com 13 Oct 16:20')
  has('cycles table: net variance in rand', text, '-R1,250.50')
  has('selected cycle shows its own events', text, 'Events for the daily list of 13 Oct 07:12')
  check('a cancelled list has no Open button', (html.match(/>Open</g) || []).length === 2, String((html.match(/>Open</g) || []).length))
  has('event log: time', text, '13 Oct 16:20')
  has('event log: user', text, 'lizeka@example.com')
  has('event log: finalise sentence', text, 'Finalised the list of 200 lines. 190 for the TLX and 10 for the PLU and scale sheet.')
  has('event log: edit sentence', text, 'Changed the count of 104567 from 3 to 5.')
  has('event log: first count sentence', text, 'Set the count of 104568 to 0.')
  has('event log: upload sentence', text, 'Uploaded a filled sheet: 140 set, 3 unchanged, 2 skipped.')
  has('event log: download sentence', text, 'Downloaded the count sheets (200 lines on 7 tabs).')
  has('event log: confirm sentence', text, 'Confirmed the count of 104569 at 4. Variance -6.')
  has('event log: recount sentence', text, 'Sent 104570 for a recount. The count was 12.')
  has('event log: generate sentence', text, 'Generated a daily list of 200 lines.')
  has('event log: export sentence', text, 'Exported the TLX file with 190 lines.')
  lacks('event log does not leak the file hash', text, 'abc')
  has('line history: app counts', text, 'Counts on this page for 104567')
  has('line history: ledger counts', text, 'Counts in the Sigma ledger for 104567')
  has('line history: app row', text, 'Daily list Tue 13 Oct 12 10 -2 -R40.00 lizeka@example.com')
  has('line history: ledger row', text, 'Sun 2 Aug -3 15 12 20.0%')
  const empty = page(HistoryTab, { ...props, history: { cycles: [], by_day: [] }, events: [], selectedCycleId: null, cycleEvents: null, lineHistory: { ...lineHistory, result: { app: [], ledger: [] } } })
  has('empty history says so', empty.text, 'No lists have been generated for this store yet.')
  has('empty event log says so', empty.text, 'No events yet.')
  has('empty line history says so', empty.text, 'No counts found for product code 104567.')

  const viaScreen = screen({ tab: 'history', history: props })
  has('the History tab is selected from the store screen', viaScreen.html, 'aria-selected="true" aria-controls="stk-panel" class="stk-tab stk-tab-on">History')
  has('and shows the history', viaScreen.text, 'Adherence by day')
}

console.log('--- callbacks out: every control calls the right handler ---')
// A mini renderer: expand function components into plain elements (the components hold no hooks)
// so the test can find a control and call its handler exactly as the browser would.
function expand(node) {
  if (node === null || node === undefined || typeof node === 'boolean' || typeof node === 'string' || typeof node === 'number') return node
  if (Array.isArray(node)) return node.map(expand)
  if (typeof node.type === 'function') return expand(node.type(node.props))
  return { type: node.type, props: { ...node.props, children: expand(node.props ? node.props.children : undefined) } }
}
function collect(node, pred, out = []) {
  if (Array.isArray(node)) node.forEach((n) => collect(n, pred, out))
  else if (node && typeof node === 'object') {
    if (pred(node)) out.push(node)
    collect(node.props && node.props.children, pred, out)
  }
  return out
}
function flat(node) {
  if (node === null || node === undefined || typeof node === 'boolean') return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(flat).join('')
  return flat(node.props && node.props.children)
}
const tree = (Component, props) => expand(h(Component, props))
const byId = (t, id) => collect(t, (n) => n.props && n.props.id === id)[0]
const button = (t, label) => collect(t, (n) => n.type === 'button' && flat(n).trim() === label)[0]
const link = (t, label) => collect(t, (n) => n.type === 'a' && flat(n).trim() === label)[0]
{
  const CountTable = load('components/CountTable.jsx').default
  const log = []
  const tableProps = (o = {}) => ({
    lines,
    drafts: {},
    rowStates: {},
    openRows: [],
    showOnlyBlank: false,
    keepVisible: [],
    onChange: (id, t) => log.push(['change', id, t]),
    onBlurLine: (id) => log.push(['blur', id]),
    onFocusLine: (id) => log.push(['focus', id]),
    onToggleRow: (id) => log.push(['toggle', id]),
    onRetry: (id) => log.push(['retry', id]),
    ...o,
  })
  let t = tree(CountTable, tableProps())
  const box2 = byId(t, 'stk-count-2')
  box2.props.onChange({ target: { value: '7' } })
  check('typing calls onChange with the line id and the text', JSON.stringify(log.pop()) === JSON.stringify(['change', 2, '7']))
  box2.props.onBlur()
  check('blur calls onBlurLine with the line id', JSON.stringify(log.pop()) === JSON.stringify(['blur', 2]))
  {
    // A box that holds 0 must take the next keystroke as a replacement: typing 1 over 0 reads 1, not 10.
    let selected = 0
    box2.props.onFocus({ currentTarget: { select: () => (selected += 1) } })
    check('focusing a count box selects its whole content so a typed digit replaces a 0', selected === 1)
  }
  let prevented = 0
  let blurred = 0
  const enter = { key: 'Enter', preventDefault: () => (prevented += 1), currentTarget: { blur: () => (blurred += 1) } }
  box2.props.onKeyDown(enter)
  check('Enter moves to the next row box and does not submit', JSON.stringify(log.pop()) === JSON.stringify(['focus', 3]) && prevented === 1)
  byId(t, 'stk-count-6').props.onKeyDown(enter)
  check('Enter on the last box leaves it (which saves it)', blurred === 1 && log.length === 0)
  const preventedBefore = prevented
  const blurredBefore = blurred
  box2.props.onKeyDown({ key: 'a', preventDefault: () => (prevented += 1), currentTarget: { blur: () => (blurred += 1) } })
  check('other keys do nothing', prevented === preventedBefore && blurred === blurredBefore && log.length === 0)
  t = tree(CountTable, tableProps({ showOnlyBlank: true }))
  byId(t, 'stk-count-2').props.onKeyDown(enter)
  check('with the blank filter on Enter goes to the next blank row', JSON.stringify(log.pop()) === JSON.stringify(['focus', 3]))
  byId(t, 'stk-count-3').props.onKeyDown(enter)
  check('and skips counted rows', JSON.stringify(log.pop()) === JSON.stringify(['focus', 6]))
  t = tree(CountTable, tableProps())
  const row1 = byId(t, 'stk-row-1')
  row1.props.onClick({ target: { closest: () => null } })
  check('clicking a row opens it', JSON.stringify(log.pop()) === JSON.stringify(['toggle', 1]))
  row1.props.onClick({ target: { closest: () => ({}) } })
  check('clicking the count box does not open the row', log.length === 0)
  t = tree(CountTable, tableProps({ rowStates: { 2: { state: 'error', message: 'Not saved.' } } }))
  button(t, 'Try again').props.onClick({})
  check('Try again retries that line', JSON.stringify(log.pop()) === JSON.stringify(['retry', 2]))
}
{
  const FinalisePanel = load('components/FinalisePanel.jsx').default
  const log = []
  const t = tree(FinalisePanel, {
    blankLines: [{ line_id: 7, product_code: 300001, description: 'Blank one' }],
    unconfirmedLines: [{ line_id: 8 }],
    busy: null,
    onFinalise: () => log.push('finalise'),
    onJump: (id) => log.push('jump:' + id),
    onJumpReview: () => log.push('review'),
  })
  button(t, 'Finalise').props.onClick()
  check('Finalise button calls onFinalise', log.pop() === 'finalise')
  let stopped = 0
  link(t, '300001 Blank one').props.onClick({ preventDefault: () => (stopped += 1) })
  check('a listed line scrolls to and focuses its row', log.pop() === 'jump:7' && stopped === 1)
  link(t, 'Open the review').props.onClick({ preventDefault: () => (stopped += 1) })
  check('the review link opens the review', log.pop() === 'review')
}
{
  const VarianceReview = load('components/VarianceReview.jsx').default
  const log = []
  const flaggedLines = [
    lineOf(1, { description: 'A', count_qty: 5, flagged: true, variance_qty: -5, variance_value: -50, variance_pct: -50 }),
    lineOf(2, { description: 'B', count_qty: 30, flagged: true, variance_qty: 20, variance_value: 400, variance_pct: 200 }),
  ]
  const props = { lines: flaggedLines, confirmedBy: {}, busy: null, onConfirm: (id) => log.push('confirm:' + id), onRecount: (id) => log.push('recount:' + id) }
  const t = tree(VarianceReview, props)
  const confirms = collect(t, (n) => n.type === 'button' && flat(n) === 'Confirm')
  const recounts = collect(t, (n) => n.type === 'button' && flat(n) === 'Recount')
  confirms[0].props.onClick()
  check('the first Confirm is the largest line (line 2)', log.pop() === 'confirm:2')
  recounts[1].props.onClick()
  check('the second Recount is the smaller line (line 1)', log.pop() === 'recount:1')
  const busyTree = tree(VarianceReview, { ...props, busy: 'review:2:CONFIRM' })
  check('every review button is disabled while one runs', collect(busyTree, (n) => n.type === 'button').every((b) => b.props.disabled === true))
  check('and the running one reads Working', collect(busyTree, (n) => n.type === 'button' && flat(n) === 'Working').length === 1)
}
{
  const GeneratePanel = load('components/GeneratePanel.jsx').default
  const log = []
  const props = { store: oneStore, state: storeState, openCycles: [], subdept: 'Bakery', busy: null, onSubdeptChange: (v) => log.push('sub:' + v), onGenerate: (type, sub) => log.push(type + ':' + sub) }
  const t = tree(GeneratePanel, props)
  button(t, 'Generate daily list (200 lines)').props.onClick()
  button(t, 'Generate confirmation count (120)').props.onClick()
  button(t, 'Generate PLU and scale list (82 lines)').props.onClick()
  button(t, 'Generate batch (200 lines)').props.onClick()
  check('each button asks for its list type, the batch with its sub-department', JSON.stringify(log) === JSON.stringify(['DAILY:null', 'CONFIRM:null', 'PLU:null', 'ADHOC:Bakery']), JSON.stringify(log))
  collect(t, (n) => n.type === 'select')[0].props.onChange({ target: { value: 'Spices' } })
  check('the picker reports the sub-department', log.pop() === 'sub:Spices')
  const busyTree = tree(GeneratePanel, { ...props, busy: 'generate:DAILY' })
  check('while one runs every generate button is disabled', collect(busyTree, (n) => n.type === 'button').every((b) => b.props.disabled === true))
  check('and the running one reads Working', Boolean(button(busyTree, 'Working')))
}
{
  const PendingCards = load('components/PendingCards.jsx').default
  const log = []
  const t = tree(PendingCards, { cycles: oneStore.open_cycles, busy: null, onOpen: (id) => log.push('open:' + id), onDownload: (id) => log.push('dl:' + id) })
  button(t, 'Open').props.onClick()
  button(t, 'Download sheets').props.onClick()
  check('Open and Download sheets pass the cycle id', JSON.stringify(log) === JSON.stringify(['open:11111111-1111-4111-8111-111111111111', 'dl:11111111-1111-4111-8111-111111111111']))
}
{
  const log = []
  const t = tree(StoreList, { stores: [oneStore], onOpenStore: (c) => log.push(c) })
  collect(t, (n) => n.type === 'button')[0].props.onClick()
  check('a store card opens that store', log.pop() === '10116')
}
{
  const CycleView = load('components/CycleView.jsx').default
  const log = []
  const names = ['onCloseCycle', 'onDownloadSheet', 'onUpload', 'onToggleBlank', 'onCancelAsk', 'onCancelKeep', 'onCancelReason', 'onCancelConfirm', 'onExportTlx', 'onExportPlu', 'onJumpReview']
  const actions = Object.fromEntries(names.map((n) => [n, (...a) => log.push(n + ':' + a.map((x) => (x && x.target ? 'event' : String(x))).join(','))]))
  const base = { doc: docOf(lines), capture: { drafts: {}, rowStates: {}, openRows: [], showOnlyBlank: false, keepVisible: [] }, confirmedBy: {}, finalise: { blankLines: [], unconfirmedLines: [] }, upload: { result: null }, exportNote: '', cancel: { open: false, reason: '' }, busy: null, actions }
  let t = tree(CycleView, base)
  button(t, 'Back to lists').props.onClick()
  button(t, 'Download count sheets').props.onClick()
  check('Back to lists and Download count sheets', JSON.stringify(log) === JSON.stringify(['onCloseCycle:', 'onDownloadSheet:11111111-1111-4111-8111-111111111111']), JSON.stringify(log))
  log.length = 0
  const file = collect(t, (n) => n.type === 'input' && n.props.type === 'file')[0]
  check('the upload input takes .xlsx', /\.xlsx/.test(file.props.accept))
  file.props.onChange({ target: { files: [] } })
  check('choosing a file calls onUpload with the event', log.pop() === 'onUpload:event')
  collect(t, (n) => n.type === 'input' && n.props.type === 'checkbox')[0].props.onChange({ target: { checked: true } })
  check('the blank toggle reports its state', log.pop() === 'onToggleBlank:true')
  button(t, 'Cancel this list').props.onClick()
  check('Cancel this list asks first', log.pop() === 'onCancelAsk:')
  t = tree(CycleView, { ...base, cancel: { open: true, reason: '' } })
  collect(t, (n) => n.type === 'input' && n.props.className === 'stk-input')[0].props.onChange({ target: { value: 'wrong store' } })
  check('the reason box reports its text', log.pop() === 'onCancelReason:wrong store')
  button(t, 'Keep the list').props.onClick()
  button(t, 'Yes, cancel the list').props.onClick()
  check('Keep and Yes call their handlers', JSON.stringify(log) === JSON.stringify(['onCancelKeep:', 'onCancelConfirm:']))
  log.length = 0
  const done = docOf(lines.map((l) => ({ ...l, flagged: false })), { status: 'FINALISED', finalised_by: 'a', finalised_at: '2026-10-13T14:20:00Z' }, { tlx_lines: 4, manual_lines: 2 })
  t = tree(CycleView, { ...base, doc: done })
  button(t, 'Export TLX file (4 lines)').props.onClick()
  button(t, 'Export PLU and scale sheet (2 lines)').props.onClick()
  check('the export buttons call their handlers', JSON.stringify(log) === JSON.stringify(['onExportTlx:', 'onExportPlu:']))
}

console.log('--- the API wrapper: routes, bodies, plain errors ---')
{
  const api = load('api.js')
  const seen = []
  const reply = (status, body, text) => ({
    ok: status >= 200 && status < 300,
    status,
    text: async () => (text !== undefined ? text : body === undefined ? '' : JSON.stringify(body)),
  })
  let next = reply(200, {})
  globalThis.fetch = async (url, init) => {
    seen.push({ url, method: (init && init.method) || 'GET', body: init && init.body, credentials: init && init.credentials })
    if (next instanceof Error) throw next
    return next
  }
  next = reply(200, { stores: [{ store_code: '10116' }] })
  const stores = await api.getOverview()
  check('getOverview GETs /api/stocktake/overview and returns the stores', seen[0].url === '/api/stocktake/overview' && seen[0].method === 'GET' && stores.length === 1)
  check('requests carry the cookie session', seen[0].credentials === 'same-origin')
  next = reply(200, { state: { store_code: '10116' } })
  await api.getStoreState('10116')
  check('getStoreState passes the store as a query', seen[1].url === '/api/stocktake/store?store=10116')
  next = reply(200, { cycle_id: 'abc' })
  await api.generate({ store: '10116', listType: 'ADHOC', subdept: 'Bakery' })
  check('generate POSTs list_type and subdept', seen[2].url === '/api/stocktake/generate' && seen[2].method === 'POST' && seen[2].body === JSON.stringify({ store: '10116', list_type: 'ADHOC', subdept: 'Bakery' }), seen[2].body)
  await api.generate({ store: '10116', listType: 'DAILY', subdept: null })
  check('generate leaves subdept out when there is none', seen[3].body === JSON.stringify({ store: '10116', list_type: 'DAILY' }), seen[3].body)
  await api.captureLines('c-1', [{ line_id: 5, front: 12.5, back: 0 }, { line_id: 6, clear: true }])
  check('captureLines POSTs the lines to the cycle', seen[4].url === '/api/stocktake/cycle/c-1/capture' && seen[4].body === JSON.stringify({ lines: [{ line_id: 5, front: 12.5, back: 0 }, { line_id: 6, clear: true }] }))
  await api.reviewLines('c-1', [{ line_id: 5, action: 'CONFIRM' }])
  check('reviewLines POSTs the actions', seen[5].url === '/api/stocktake/cycle/c-1/review' && seen[5].body === JSON.stringify({ actions: [{ line_id: 5, action: 'CONFIRM' }] }))
  await api.finalise('c-1')
  check('finalise POSTs to the cycle', seen[6].url === '/api/stocktake/cycle/c-1/finalise' && seen[6].method === 'POST')
  await api.cancelCycle('c-1', 'wrong store')
  check('cancelCycle sends the reason', seen[7].url === '/api/stocktake/cycle/c-1/cancel' && seen[7].body === JSON.stringify({ reason: 'wrong store' }))
  await api.cancelCycle('c-1', '')
  check('and sends nothing when there is no reason', seen[8].body === JSON.stringify({}))
  next = reply(200, { events: [] })
  await api.getCycleEvents('c-1')
  check('getCycleEvents reads the cycle events', seen[9].url === '/api/stocktake/events?cycle=c-1')
  next = reply(200, { app: [], ledger: [] })
  await api.getLineHistory('10116', '6001234567890')
  check('a long identifier travels as text in the query', seen[10].url === '/api/stocktake/line-history?store=10116&product=6001234567890')
  next = reply(200, { history: {}, events: [] })
  await api.getHistory('10116')
  check('getHistory reads the store history', seen[11].url === '/api/stocktake/history?store=10116')
  check('sheet and export links are the contract routes', api.sheetUrl('c-1') === '/api/stocktake/cycle/c-1/sheet' && api.exportUrl('c-1', 'TLX') === '/api/stocktake/cycle/c-1/export?kind=TLX' && api.exportUrl('c-1', 'PLU') === '/api/stocktake/cycle/c-1/export?kind=PLU')

  async function failure(res) {
    next = res
    try {
      await api.getOverview()
    } catch (e) {
      return e
    }
    return null
  }
  let e = await failure(reply(409, { error: 'open_cycle_exists', message: 'A daily list is already open for this store.', cycle_id: 'abc' }))
  check('409 open_cycle_exists keeps the server sentence, the code and the cycle id', e && e.message === 'A daily list is already open for this store.' && e.code === 'open_cycle_exists' && e.cycleId === 'abc' && e.status === 409)
  e = await failure(reply(401, { error: 'not authenticated' }))
  check('401 reads as a plain sign-in sentence', e && e.status === 401 && e.message === 'Your sign-in has ended. Sign in again to carry on.')
  e = await failure(reply(500, undefined, '<html>Internal Server Error</html>'))
  check('a 500 with a page body never leaks it', e && e.message === 'Something went wrong on our side. Try again in a moment.' && !/html/i.test(e.message))
  e = await failure(reply(502, { error: 'tripwire', message: 'The list failed its own check and was not shown. Try again.' }))
  check('502 tripwire shows the server sentence', e && e.code === 'tripwire' && /failed its own check/.test(e.message))
  e = await failure(new TypeError('Failed to fetch'))
  check('a dropped connection is a plain sentence', e && e.code === 'network' && e.message === 'The connection dropped. Check the signal and try again.')
  delete globalThis.fetch
}

console.log('--- the page file renders its first state ---')
{
  const { text } = page(Page, {})
  has('the page starts on Loading before the browser reads the URL', text, 'Loading')
}

console.log('--- saved as typed: the queue, against fake timers ---')
const tick = () => new Promise((r) => setImmediate(r))
function fakeTimers() {
  let now = 0
  let seq = 0
  const q = new Map()
  return {
    setTimer(fn, ms) {
      seq += 1
      q.set(seq, { at: now + ms, fn })
      return seq
    },
    clearTimer(id) {
      q.delete(id)
    },
    advance(ms) {
      now += ms
      for (const [id, t] of Array.from(q.entries()).sort((a, b) => a[1].at - b[1].at)) {
        if (t.at <= now) {
          q.delete(id)
          t.fn()
        }
      }
    },
    pending: () => q.size,
  }
}
function rig(sendImpl) {
  const timers = fakeTimers()
  const calls = []
  const events = { drafts: {}, rows: {}, status: 'idle', saved: [], failed: [] }
  const queue = saveQueueMod.createSaveQueue({
    send: (cycleId, ls) => {
      calls.push({ cycleId, lines: ls })
      return sendImpl ? sendImpl(cycleId, ls, calls.length) : Promise.resolve({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: '2026-10-13T12:07:00Z' })
    },
    getCycleId: () => 'c1',
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    on: {
      drafts: (d) => {
        events.drafts = d
      },
      row: (id, s) => {
        events.rows[id] = s
      },
      status: (s) => {
        events.status = s
      },
      saved: (e) => events.saved.push(e),
      failed: (e) => events.failed.push(e),
    },
  })
  return { queue, timers, calls, events }
}
{
  check('the delay is 600 ms', saveQueueMod.SAVE_DELAY_MS === 600)

  let r = rig()
  r.queue.change(11, '5')
  r.timers.advance(599)
  await tick()
  check('nothing is sent before 600 ms', r.calls.length === 0)
  r.timers.advance(1)
  await tick()
  check('one save at 600 ms', r.calls.length === 1)
  check('typed 5 sends front 5 back 0 to the cycle', JSON.stringify(r.calls[0] && r.calls[0].lines) === JSON.stringify([{ line_id: 11, front: 5, back: 0 }]) && r.calls[0].cycleId === 'c1')
  check('the draft leaves once the server confirmed it', Object.keys(r.events.drafts).length === 0)
  check('the saved event reports the time the server gave', r.events.saved.length === 1 && r.events.saved[0].savedAt === '2026-10-13T12:07:00Z' && r.events.saved[0].applied === true)
  check('status settles to idle', r.events.status === 'idle')

  r = rig()
  r.queue.change(12, '1')
  r.timers.advance(400)
  r.queue.change(12, '12')
  r.timers.advance(400)
  await tick()
  check('typing again restarts the 600 ms wait', r.calls.length === 0)
  r.timers.advance(200)
  await tick()
  check('and only the last text is sent', r.calls.length === 1 && r.calls[0].lines[0].front === 12)

  r = rig()
  r.queue.change(13, '7')
  r.queue.blur(13)
  await tick()
  check('blur sends at once', r.calls.length === 1 && r.calls[0].lines[0].front === 7)
  check('and leaves no timer behind', r.timers.pending() === 0)
  r.queue.blur(13)
  await tick()
  check('a second blur with nothing waiting sends nothing', r.calls.length === 1)

  r = rig()
  r.queue.change(14, '')
  r.queue.blur(14)
  await tick()
  check('an emptied box sends clear:true', JSON.stringify(r.calls[0].lines) === JSON.stringify([{ line_id: 14, clear: true }]))

  r = rig()
  r.queue.change(15, '0')
  r.queue.blur(15)
  await tick()
  check('0 is a real count: front 0 back 0, not a clear', JSON.stringify(r.calls[0].lines) === JSON.stringify([{ line_id: 15, front: 0, back: 0 }]))

  r = rig()
  r.queue.change(16, '12,5')
  r.queue.blur(16)
  await tick()
  check('a decimal comma is read as a point', r.calls[0].lines[0].front === 12.5)

  r = rig()
  r.queue.change(17, 'abc')
  r.queue.blur(17)
  await tick()
  check('letters are never sent', r.calls.length === 0)
  check('the row shows a plain error', r.events.rows[17] && r.events.rows[17].message === 'Enter a number such as 12 or 3.5.')
  check('the typed text stays', r.queue.drafts()[17] === 'abc')
  check('status turns to error', r.events.status === 'error')
  r.queue.change(17, '3')
  check('typing again clears the row error', r.events.rows[17] === null && r.events.status === 'saving')
  r.queue.change(18, '-3')
  r.queue.blur(18)
  await tick()
  check('a negative is never sent', r.calls.length === 0)

  // sequential: the second save waits for the first
  {
    const gates = []
    r = rig(
      () =>
        new Promise((resolve) => {
          gates.push(resolve)
        })
    )
    r.queue.change(21, '1')
    r.queue.change(22, '2')
    r.queue.blur(21)
    r.queue.blur(22)
    await tick()
    check('saves go one at a time: the second waits', r.calls.length === 1 && r.calls[0].lines[0].line_id === 21)
    gates[0]({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'a' })
    await tick()
    await tick()
    check('then the second runs, in order', r.calls.length === 2 && r.calls[1].lines[0].line_id === 22)
    gates[1]({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'b' })
    await tick()
    check('both confirmed and cleared', Object.keys(r.events.drafts).length === 0 && r.events.saved.length === 2)
  }

  // a newer draft typed while a save runs survives it
  {
    const gates = []
    r = rig(
      () =>
        new Promise((resolve) => {
          gates.push(resolve)
        })
    )
    r.queue.change(31, '1')
    r.queue.blur(31)
    await tick()
    r.queue.change(31, '2')
    gates[0]({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'a' })
    await tick()
    await tick()
    check('the newer draft stays after the older save', r.queue.drafts()[31] === '2' && r.events.saved[0].applied === false)
    r.timers.advance(600)
    await tick()
    gates[1]({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'b' })
    await tick()
    await tick()
    check('and saves next', r.calls.length === 2 && r.calls[1].lines[0].front === 2 && Object.keys(r.events.drafts).length === 0)
  }

  // a failed save keeps the draft until it works
  {
    let fail = true
    r = rig(() => (fail ? Promise.reject(new Error('The connection dropped. Check the signal and try again.')) : Promise.resolve({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'ok' })))
    r.queue.change(41, '9')
    r.queue.blur(41)
    await tick()
    check('a failed save keeps the draft', r.queue.drafts()[41] === '9')
    check('and shows Not saved on the row', r.events.rows[41] && r.events.rows[41].message === 'Not saved.')
    check('and reports the failure once', r.events.failed.length === 1)
    check('and the status says error', r.events.status === 'error' && r.queue.hasErrors())
    fail = false
    r.queue.retry(41)
    await tick()
    check('retry saves it', Object.keys(r.events.drafts).length === 0 && r.events.rows[41] === null && r.events.status === 'idle')
    fail = true
    r.queue.change(42, '1')
    r.queue.blur(42)
    await tick()
    fail = false
    r.queue.retryErrors()
    await tick()
    check('retryErrors tries every failed line when the connection returns', Object.keys(r.events.drafts).length === 0)
  }

  // the server can refuse a line
  {
    r = rig(() => Promise.resolve({ set: 0, unchanged: 0, rejected: [{ line_id: 51, reason: 'a count cannot be negative' }], blank: 1, saved_at: 'x' }))
    r.queue.change(51, '4')
    r.queue.blur(51)
    await tick()
    check('a server refusal shows its reason as a sentence', r.events.rows[51] && r.events.rows[51].message === 'Not saved. A count cannot be negative.')
    check('and keeps the draft', r.queue.drafts()[51] === '4')
  }

  // flushAll
  {
    r = rig()
    r.queue.change(61, '1')
    r.queue.change(62, '2')
    const ok = await r.queue.flushAll()
    check('flushAll sends everything typed and resolves true', ok === true && r.calls.length === 2 && r.timers.pending() === 0)
    r.queue.change(63, 'x')
    const bad = await r.queue.flushAll()
    check('flushAll resolves false while a bad entry remains', bad === false)
  }

  // reset
  {
    r = rig()
    r.queue.change(71, '1')
    r.queue.reset()
    check('reset drops timers and drafts', r.timers.pending() === 0 && Object.keys(r.events.drafts).length === 0 && !r.queue.isBusy())
  }

  // a save that outlives a reset never lands on the new list
  {
    const gates = []
    r = rig(
      () =>
        new Promise((resolve) => {
          gates.push(resolve)
        })
    )
    r.queue.change(81, '1')
    r.queue.blur(81)
    await tick()
    r.queue.reset()
    gates[0]({ set: 1, unchanged: 0, rejected: [], blank: 0, saved_at: 'late' })
    await tick()
    await tick()
    check('a save that finishes after the list changed is ignored', r.events.saved.length === 0)
  }
}

console.log('--- hard rules: sources ---')
function walk(dir, out = []) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name)
    if (fs.statSync(p).isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}
const files = walk(stkDir)
const rel = (p) => path.relative(root, p).replace(/\\/g, '/')
const sources = new Map(files.map((p) => [rel(p), fs.readFileSync(p, 'utf8')]))
sources.set('scripts/stocktake-render-test.mjs', fs.readFileSync(fileURLToPath(import.meta.url), 'utf8'))

for (const [name, src] of sources) {
  const nonAscii = /[^\x00-\x7F]/.exec(src)
  check('ASCII only: ' + name, !nonAscii, nonAscii ? 'U+' + nonAscii[0].codePointAt(0).toString(16) + ' near "' + src.slice(Math.max(0, nonAscii.index - 20), nonAscii.index + 20).replace(/\n/g, ' ') + '"' : '')
}
for (const [name, src] of sources) {
  if (!name.startsWith('src/app/stocktake/components/')) continue
  check('pure component, no @/ import: ' + name, !/from\s+['"]@\//.test(src))
  check('pure component, no supabase: ' + name, !/supabase/i.test(src))
  check('pure component, no fetch and no api import: ' + name, !/\bfetch\s*\(/.test(src) && !/from\s+['"]\.\.?\/(\.\.\/)?api['"]/.test(src))
}
for (const [name, src] of sources) {
  if (!name.startsWith('src/app/stocktake/')) continue
  check('no table access (.from) in ' + name, !/\.from\(\s*['"`]/.test(src))
  check('no service-role key in ' + name, !/service_role|SERVICE_ROLE/.test(src))
  check('no console.log of rows in ' + name, !/console\.log/.test(src))
}
check('page.jsx is the only file that imports the api wrapper', [...sources].filter(([n, s]) => n.startsWith('src/app/stocktake/') && /from\s+['"]\.\/api['"]/.test(s)).map(([n]) => n).join() === 'src/app/stocktake/page.jsx')
check('page.jsx is a client component', /^'use client'/.test(sources.get('src/app/stocktake/page.jsx')))
{
  // Every handler a component calls (a.onXxx) must exist in the page's actions object.
  const pageSrc = sources.get('src/app/stocktake/page.jsx')
  const start = pageSrc.indexOf('const actions = {')
  const block = pageSrc.slice(start, pageSrc.indexOf('\n  }\n', start))
  const provided = new Set([...block.matchAll(/^\s{4}(on[A-Z]\w+):/gm)].map((m) => m[1]))
  const wanted = new Set()
  for (const [name, src] of sources) {
    if (!name.startsWith('src/app/stocktake/components/')) continue
    for (const m of src.matchAll(/\ba\.(on[A-Z]\w+)/g)) wanted.add(m[1])
  }
  const missing = [...wanted].filter((n) => !provided.has(n))
  check('the page provides every handler the components call (' + wanted.size + ')', wanted.size > 15 && missing.length === 0, 'missing: ' + missing.join(', '))
  const unused = [...provided].filter((n) => !wanted.has(n))
  check('and the page provides nothing the components never call', unused.length === 0, 'unused: ' + unused.join(', '))
}
check('layout sets the title from APP_NAME.stocktake', /title:\s*APP_NAME\.stocktake/.test(sources.get('src/app/stocktake/layout.jsx')))
check('layout wraps children in the light root', /className="stk-root"/.test(sources.get('src/app/stocktake/layout.jsx')))
check('no number parsing of identifiers in the page code', ![...sources].some(([n, s]) => n.startsWith('src/app/stocktake/') && /(Number|parseInt|parseFloat)\(\s*(line\.)?(identifier|ean)/i.test(s)))
check('no config values typed into the code (200, 28, 91)', ![...sources].some(([n, s]) => n.startsWith('src/app/stocktake/') && !n.endsWith('.css') && /\b(200|28|91)\b/.test(s.replace(/\/\/.*$/gm, ''))), 'a literal 200, 28 or 91 appears in the stocktake code')

console.log('--- hard rules: visible text style ---')
{
  const all = everyText.join(' ')
  check('no em dash in any rendered text', !all.includes(EM_DASH))
  check('no semicolon in any rendered text', !all.includes(';'))
  check('no exclamation mark in any rendered text', !all.includes('!'))
  check('no Oxford comma in any rendered text', !/,\s+(and|or)\s/i.test(all), (/,\s+(and|or)\s.{0,30}/i.exec(all) || [''])[0])
  const literals = []
  for (const [name, src] of sources) {
    if (name.endsWith('.css') || name.includes('render-test') || !name.startsWith('src/app/stocktake/')) continue
    const code = src.replace(/\/\/.*$/gm, '').replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
    for (const m of code.matchAll(/'([^'\\\n]*[ ][^'\\\n]*)'/g)) literals.push([name, m[1]])
  }
  const looksLikeCode = /&&|\|\||===|!==|=>|\?/
  const sentences = literals.filter(([, s]) => !looksLikeCode.test(s))
  const offenders = sentences.filter(([, s]) => /;|!(\s|$)|,\s+(and|or)\s/.test(s) || s.includes(EM_DASH))
  check('no semicolon, exclamation, em dash or Oxford comma in any string literal', offenders.length === 0, offenders.slice(0, 3).map((o) => o.join(': ')).join(' | '))
  const filler = /\b(simply|just|please|very|really|actually|basically|easily|quickly)\b/i
  const fillerHits = sentences.filter(([, s]) => filler.test(s))
  check('no filler words in string literals', fillerHits.length === 0, fillerHits.slice(0, 3).map((o) => o.join(': ')).join(' | '))
}

console.log('--- css: tokens, light theme, narrow screens ---')
{
  const css = sources.get('src/app/stocktake/stocktake.css')
  const dash = fs.readFileSync(path.join(root, 'src', 'app', 'dashboard.css'), 'utf8')
  check('same Google Fonts @import line as dashboard.css line 1', css.split('\n')[0].trim() === dash.split('\n')[0].trim())
  const rootBlock = css.slice(css.indexOf(':root {'), css.indexOf('\n}', css.indexOf(':root {')) + 2)
  for (const [token, value] of [['--daisy-white', '#f9fbf7'], ['--charcoal-veld', '#121612'], ['--growth-green', '#4a6b53'], ['--core-yellow', '#ffd100'], ['--veld-green', '#1e3f20']]) {
    check('Bible token ' + token + ' = ' + value, new RegExp(token + ':\\s*' + value, 'i').test(rootBlock))
  }
  const derived = rootBlock.split('\n').filter((l) => /--stk-/.test(l))
  check('every stk- colour is marked DERIVED, not in Appendix A, flag to PM/CD', derived.length >= 5 && derived.every((l) => l.includes('DERIVED, not in Appendix A, flag to PM/CD')), derived.filter((l) => !l.includes('DERIVED')).join(' | '))
  check('negative ink is the derived dark red', /--stk-negative:\s*#b3261e/i.test(rootBlock))
  const outside = css.replace(rootBlock, '')
  check('no colour is declared outside the token block', !/#[0-9a-fA-F]{3,8}\b|rgba?\(/.test(outside.replace(/@import[^\n]*/, '')))
  check('the body is repainted light (no dark edge)', /body:has\(\.stk-root\)/.test(css) && /background-color:\s*var\(--daisy-white\)/.test(css))
  check('page title 24px Fraunces', /\.stk-h1\s*\{[^}]*font-family:\s*var\(--font-display\)[^}]*font-size:\s*24px/.test(css))
  check('section title 18px Fraunces', /\.stk-h2\s*\{[^}]*font-family:\s*var\(--font-display\)[^}]*font-size:\s*18px/.test(css))
  check('table cell 13px Geist Mono with tabular numerals', /\.stk-table\s*\{[^}]*font-family:\s*var\(--font-mono\)[^}]*font-size:\s*13px[^}]*tabular-nums/.test(css))
  check('buttons are at least 44px high', /\.stk-btn\s*\{[^}]*min-height:\s*44px/.test(css))
  check('control text is 16px', /\.stk-input,\s*\.stk-select\s*\{[^}]*font-size:\s*16px/.test(css))
  check('rows are at least 44px high', /\.stk-row\s*\{[^}]*height:\s*52px/.test(css) && /\.stk-desc-btn\s*\{[^}]*min-height:\s*44px/.test(css))
  check('card radius 16px and control radius 8px come from the tokens', /--radius-card:\s*16px/.test(css) && /--radius-chip:\s*8px/.test(css))
  check('focus ring is 3px Core Yellow plus a 1px Charcoal outline', /box-shadow:\s*0 0 0 3px var\(--core-yellow\)/.test(css) && /outline:\s*1px solid var\(--charcoal-veld\)/.test(css))
  check('primary buttons are Core Yellow with Charcoal text', /\.stk-btn-primary\s*\{[^}]*background-color:\s*var\(--core-yellow\)[^}]*color:\s*var\(--charcoal-veld\)/.test(css))
  check('secondary buttons are Growth Green with Daisy White text', /\.stk-btn-secondary\s*\{[^}]*background-color:\s*var\(--growth-green\)[^}]*color:\s*var\(--daisy-white\)/.test(css))
  const narrow = css.slice(css.indexOf('@media (max-width: 719px)'))
  check('narrow screens hide the Barcode and Size columns', /\.stk-c-bar,\s*\.stk-c-size\s*\{\s*display:\s*none/.test(narrow))
  check('and show them under the description', /\.stk-narrow-only\s*\{\s*display:\s*block/.test(narrow))
  check('the page never scrolls sideways', !/min-width:\s*[4-9]\d\dpx/.test(css.replace(/minmax\([^)]*\)/g, '')))
}

console.log('\n' + passed + ' passed, ' + failed + ' failed')
process.exit(failed === 0 ? 0 : 1)
