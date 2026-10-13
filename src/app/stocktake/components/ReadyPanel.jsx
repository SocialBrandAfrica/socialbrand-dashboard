import { fmtDateTime, fmtInt, plural } from './format'

// props: cycle, counts (cycle_get cycle and counts objects), busy (string or null),
//        onExportTlx(), onExportPlu(), exportNote (a sentence about the last file)
export default function ReadyPanel({ cycle, counts, busy, onExportTlx, onExportPlu, exportNote }) {
  const c = cycle || {}
  const k = counts || {}
  const tlx = Number(k.tlx_lines) || 0
  const manual = Number(k.manual_lines) || 0
  const working = Boolean(busy)
  return (
    <section id="stk-ready" className="stk-section" aria-labelledby="stk-ready-title">
      <h2 id="stk-ready-title" className="stk-h2">
        Ready to export
      </h2>
      <p className="stk-note">
        Finalised by {c.finalised_by} on {fmtDateTime(c.finalised_at)}. {fmtInt(k.captured)} of {fmtInt(k.lines)}{' '}
        {plural(k.lines, 'line', 'lines')} counted.
      </p>
      <div className="stk-actions">
        {tlx > 0 ? (
          <button type="button" className="stk-btn stk-btn-primary" disabled={working} onClick={() => onExportTlx && onExportTlx()}>
            {busy === 'export:TLX' ? 'Working' : 'Export TLX file (' + fmtInt(tlx) + ' ' + plural(tlx, 'line', 'lines') + ')'}
          </button>
        ) : null}
        {manual > 0 ? (
          <button type="button" className="stk-btn stk-btn-secondary" disabled={working} onClick={() => onExportPlu && onExportPlu()}>
            {busy === 'export:PLU'
              ? 'Working'
              : 'Export PLU and scale sheet (' + fmtInt(manual) + ' ' + plural(manual, 'line', 'lines') + ')'}
          </button>
        ) : null}
      </div>
      {exportNote ? <p className="stk-note" role="status">{exportNote}</p> : null}
      <p className="stk-note">Import the TLX in Sigma. The counts post overnight and the lines leave the list.</p>
    </section>
  )
}
