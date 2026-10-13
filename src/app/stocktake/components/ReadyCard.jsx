import { fmtDateTime, fmtInt, listName, plural } from './format'

// The last finalised list of a store, so a finished count is one tap from its exports.
// props: finalised (overview.last_finalised or null), onOpen(cycleId)
export default function ReadyCard({ finalised, onOpen }) {
  if (!finalised || !finalised.cycle_id) return null
  return (
    <section className="stk-section" aria-labelledby="stk-readycard-title">
      <h2 id="stk-readycard-title" className="stk-h2">
        Ready to export
      </h2>
      <ul className="stk-cards">
        <li className="stk-card">
          <h3 className="stk-card-title">{listName(finalised)}</h3>
          <p className="stk-caption">
            Finalised by {finalised.finalised_by} on {fmtDateTime(finalised.finalised_at)}
          </p>
          <p className="stk-progress-text">
            {fmtInt(finalised.line_count)} {plural(finalised.line_count, 'line', 'lines')}
          </p>
          <div className="stk-actions">
            <button type="button" className="stk-btn stk-btn-primary" onClick={() => onOpen && onOpen(finalised.cycle_id)}>
              Open
            </button>
          </div>
        </li>
      </ul>
    </section>
  )
}
