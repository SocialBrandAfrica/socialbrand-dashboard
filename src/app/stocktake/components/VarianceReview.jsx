import { fmtPct, fmtQty, fmtRand, fmtSigned } from './format'

function absValue(l) {
  const v = Number(l.variance_value)
  return Number.isFinite(v) ? Math.abs(v) : -1
}

// Only the flagged lines that hold a count, largest absolute rand variance first.
// A line the server has not re-priced since its last save is held back until it has.
export function flaggedLines(lines) {
  return (Array.isArray(lines) ? lines : [])
    .filter((l) => l.flagged && l.count_qty !== null && l.count_qty !== undefined && !l.stale)
    .slice()
    .sort((a, b) => {
      const d = absValue(b) - absValue(a)
      return d !== 0 ? d : Number(a.seq) - Number(b.seq)
    })
}

function Figure({ label, value, negative }) {
  return (
    <div className="stk-fig">
      <dt>{label}</dt>
      <dd className={'stk-mono stk-num' + (negative ? ' stk-neg' : '')}>{value}</dd>
    </div>
  )
}

// props: lines (cycle_get lines), confirmedBy ({line_id: who}), busy (string or null),
//        onConfirm(lineId), onRecount(lineId)
export default function VarianceReview({ lines, confirmedBy, busy, onConfirm, onRecount }) {
  const flagged = flaggedLines(lines)
  if (flagged.length === 0) return null
  const open = flagged.filter((l) => l.review_state !== 'CONFIRMED').length
  return (
    <section id="stk-review" className="stk-section" aria-labelledby="stk-review-title">
      <h2 id="stk-review-title" className="stk-h2">
        Lines that differ from the system
      </h2>
      <p className="stk-note">
        {open > 0
          ? 'Confirm each line or send it for a recount. The largest rand difference comes first.'
          : 'Every line has a decision. You can still send a line for a recount.'}
      </p>
      <ul className="stk-vr">
        {flagged.map((l) => {
          const confirmed = l.review_state === 'CONFIRMED'
          const who = confirmedBy ? confirmedBy[l.line_id] : null
          const negQty = Number(l.variance_qty) < 0
          const negVal = Number(l.variance_value) < 0
          const working = Boolean(busy)
          return (
            <li key={l.line_id} id={'stk-vr-' + l.line_id} className="stk-vr-item">
              <p className="stk-vr-head">
                <span className="stk-mono">{l.product_code}</span> <span className="stk-vr-desc">{l.description}</span>
              </p>
              <dl className="stk-figs">
                <Figure label="System stock" value={fmtQty(l.system_stock)} />
                <Figure label="Count" value={fmtQty(l.count_qty)} />
                <Figure label="Variance" value={fmtSigned(l.variance_qty)} negative={negQty} />
                <Figure label="Variance value" value={fmtRand(l.variance_value)} negative={negVal} />
                <Figure label="Variance %" value={fmtPct(l.variance_pct)} negative={Number(l.variance_pct) < 0} />
              </dl>
              <div className="stk-actions">
                {confirmed ? (
                  <p className="stk-confirmed">{who ? 'Confirmed by ' + who : 'Confirmed'}</p>
                ) : (
                  <button
                    type="button"
                    className="stk-btn stk-btn-primary"
                    disabled={working}
                    onClick={() => onConfirm && onConfirm(l.line_id)}
                  >
                    {busy === 'review:' + l.line_id + ':CONFIRM' ? 'Working' : 'Confirm'}
                  </button>
                )}
                <button
                  type="button"
                  className="stk-btn stk-btn-secondary"
                  disabled={working}
                  onClick={() => onRecount && onRecount(l.line_id)}
                >
                  {busy === 'review:' + l.line_id + ':RECOUNT' ? 'Working' : 'Recount'}
                </button>
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
