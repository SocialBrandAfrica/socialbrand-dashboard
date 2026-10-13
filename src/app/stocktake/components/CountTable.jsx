import { fmtDay, fmtQty, plural, qtyText } from './format'

const COLUMNS = 6

function hasText(v) {
  return typeof v === 'string' && v.trim() !== ''
}

// A line is blank when its box is empty: the typed text if there is one, the stored count if not.
export function isBlankLine(line, drafts) {
  const d = drafts ? drafts[line.line_id] : undefined
  if (d !== undefined) return !hasText(d)
  return line.count_qty === null || line.count_qty === undefined
}

function boxValue(line, drafts) {
  const d = drafts ? drafts[line.line_id] : undefined
  if (d !== undefined) return d
  return qtyText(line.count_qty)
}

// The barcode column: the EAN as text, or the PLU or product code with a small grey word.
function Barcode({ line }) {
  const kind = line.identifier_kind
  return (
    <>
      <span className="stk-mono">{line.identifier}</span>
      {kind === 'PLU' ? <span className="stk-kind"> PLU</span> : null}
      {kind === 'PRODUCT_CODE' ? <span className="stk-kind"> code</span> : null}
    </>
  )
}

function Tick() {
  return (
    <svg className="stk-tick" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">
      <path d="M3 8.5l3.2 3.2L13 4.8" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

// What sits under a count box: the front plus back split of an uploaded count, or the save state.
function UnderBox({ line, hasDraft, rowState, onRetry }) {
  if (rowState && rowState.state === 'error') {
    return (
      <span className="stk-under stk-under-error">
        <span>{rowState.message || 'Not saved.'}</span>{' '}
        <button type="button" className="stk-link" data-stk-noopen="true" onClick={() => onRetry && onRetry(line.line_id)}>
          Try again
        </button>
      </span>
    )
  }
  if (rowState && rowState.state === 'saving') {
    return <span className="stk-under">Saving</span>
  }
  const back = Number(line.back)
  if (!hasDraft && Number.isFinite(back) && back > 0) {
    return (
      <span className="stk-under stk-mono">
        {fmtQty(line.front)} + {fmtQty(line.back)}
      </span>
    )
  }
  return null
}

function Row({ line, drafts, rowState, open, readOnly, onChange, onBlurLine, onKeyEnter, onToggleRow, onRetry }) {
  const id = line.line_id
  const hasDraft = drafts && drafts[id] !== undefined
  const captured = line.count_qty !== null && line.count_qty !== undefined
  const saved = !hasDraft && captured && !(rowState && rowState.state === 'error')
  const nowDiffers =
    line.system_now !== null &&
    line.system_now !== undefined &&
    Number(line.system_now) !== Number(line.system_stock)
  const description = line.description || 'No description'

  function rowClick(e) {
    if (e.target && e.target.closest && e.target.closest('input, a, select, [data-stk-noopen]')) return
    if (onToggleRow) onToggleRow(id)
  }

  return (
    <>
      <tr id={'stk-row-' + id} className={'stk-row' + (open ? ' stk-row-open' : '')} onClick={rowClick}>
        <td className="stk-c-code stk-mono">{line.product_code}</td>
        <td className="stk-c-bar">
          <Barcode line={line} />
        </td>
        <td className="stk-c-desc">
          <button type="button" className="stk-desc-btn" aria-expanded={open ? 'true' : 'false'}>
            {description}
          </button>
          <span className="stk-sub stk-narrow-only">
            <span className="stk-sub-line">
              <Barcode line={line} />
            </span>
            {line.size ? <span className="stk-sub-line">{line.size}</span> : null}
          </span>
          {line.review_state === 'RECOUNT' ? <span className="stk-sub">Recount</span> : null}
        </td>
        <td className="stk-c-size">{line.size || ''}</td>
        <td className="stk-c-sys stk-mono stk-num">{fmtQty(line.system_stock)}</td>
        <td className="stk-c-count">
          {readOnly ? (
            <span className="stk-mono stk-num stk-readcount">{qtyText(line.count_qty)}</span>
          ) : (
            <span className="stk-countwrap">
              <input
                id={'stk-count-' + id}
                className="stk-input stk-mono stk-num"
                type="text"
                inputMode="decimal"
                enterKeyHint="next"
                autoComplete="off"
                autoCorrect="off"
                spellCheck="false"
                aria-label={'Count for ' + description}
                aria-invalid={rowState && rowState.state === 'error' ? 'true' : undefined}
                value={boxValue(line, drafts)}
                onFocus={(e) => {
                  // A box that holds 0 (a real count) must take the next keystroke as a replacement,
                  // never as an addition: typing 1 over 0 reads 1, not 10. Select the whole box on focus,
                  // and again after the pointer settles, because a touch or mouse-up would clear the selection.
                  const el = e.currentTarget
                  if (el && el.select) {
                    el.select()
                    setTimeout(() => el.select(), 0)
                  }
                }}
                onChange={(e) => onChange && onChange(id, e.target.value)}
                onBlur={() => onBlurLine && onBlurLine(id)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    if (onKeyEnter) onKeyEnter(id, e.currentTarget)
                  }
                }}
              />
              {saved ? (
                <span className="stk-saved-mark" data-saved="true" role="img" aria-label="Saved">
                  <Tick />
                </span>
              ) : null}
            </span>
          )}
          <UnderBox line={line} hasDraft={hasDraft} rowState={rowState} onRetry={onRetry} />
        </td>
      </tr>
      {open ? (
        <tr className="stk-story-row">
          <td colSpan={COLUMNS}>
            {line.story ? <p className="stk-story">{line.story}</p> : null}
            {line.route_reason ? <p className="stk-story">{line.route_reason}.</p> : null}
            {nowDiffers ? (
              <p className="stk-story">The system stock is now {fmtQty(line.system_now)}.</p>
            ) : null}
            {line.last_counted_date ? (
              <p className="stk-story">Last counted {fmtDay(line.last_counted_date)}.</p>
            ) : null}
          </td>
        </tr>
      ) : null}
    </>
  )
}

// props: lines (cycle_get lines, server order), drafts ({line_id: text}), rowStates ({line_id: {state, message}}),
//        openRows ([line_id]), showOnlyBlank, keepVisible ([line_id]), readOnly,
//        onChange(lineId, text), onBlurLine(lineId), onFocusLine(lineId), onToggleRow(lineId), onRetry(lineId)
export default function CountTable({
  lines,
  drafts,
  rowStates,
  openRows,
  showOnlyBlank,
  keepVisible,
  readOnly,
  onChange,
  onBlurLine,
  onFocusLine,
  onToggleRow,
  onRetry,
}) {
  const all = Array.isArray(lines) ? lines : []
  const keep = new Set(keepVisible || [])
  const opened = new Set(openRows || [])
  const visible = showOnlyBlank ? all.filter((l) => isBlankLine(l, drafts) || keep.has(l.line_id)) : all

  if (all.length === 0) {
    return <p className="stk-note">This list has no lines.</p>
  }
  if (visible.length === 0) {
    return <p className="stk-note">Every line has a count.</p>
  }

  function onKeyEnter(id, el) {
    const at = visible.findIndex((l) => l.line_id === id)
    const next = at >= 0 ? visible[at + 1] : null
    if (next && onFocusLine) onFocusLine(next.line_id)
    else if (el && el.blur) el.blur()
  }

  const rows = []
  let dept = Symbol('none')
  for (const line of visible) {
    const name = line.dept_name || 'Other'
    if (name !== dept) {
      dept = name
      rows.push(
        <tr key={'dept-' + name + '-' + line.line_id} className="stk-dept">
          <th scope="colgroup" colSpan={COLUMNS}>
            {name}
          </th>
        </tr>
      )
    }
    rows.push(
      <Row
        key={line.line_id}
        line={line}
        drafts={drafts}
        rowState={rowStates ? rowStates[line.line_id] : undefined}
        open={opened.has(line.line_id)}
        readOnly={readOnly}
        onChange={onChange}
        onBlurLine={onBlurLine}
        onKeyEnter={onKeyEnter}
        onToggleRow={onToggleRow}
        onRetry={onRetry}
      />
    )
  }

  return (
    <div className="stk-tablewrap">
      <table className="stk-table">
        <caption className="stk-sr">
          Count lines. {visible.length} {plural(visible.length, 'line', 'lines')} shown.
        </caption>
        <thead>
          <tr>
            <th scope="col" className="stk-c-code">Code</th>
            <th scope="col" className="stk-c-bar">Barcode</th>
            <th scope="col" className="stk-c-desc">Description</th>
            <th scope="col" className="stk-c-size">Size</th>
            <th scope="col" className="stk-c-sys stk-num">System stock</th>
            <th scope="col" className="stk-c-count stk-num">Count</th>
          </tr>
        </thead>
        <tbody>{rows}</tbody>
      </table>
    </div>
  )
}
