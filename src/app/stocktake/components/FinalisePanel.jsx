import { fmtInt, plural } from './format'

// The blocking sentences, worded once so the page and the tests read the same text.
export function blankMessage(n) {
  return (
    fmtInt(n) +
    ' ' +
    plural(n, 'line has', 'lines have') +
    ' no count. Enter 0 where the item is not on the shelf.'
  )
}

export function unconfirmedMessage(n) {
  return fmtInt(n) + ' ' + plural(n, 'line differs', 'lines differ') + ' from the system and ' + plural(n, 'needs', 'need') + ' a decision.'
}

// props: blankLines ([{line_id, product_code, description}]), unconfirmedLines ([{line_id, ...}]),
//        busy (string or null), onFinalise(), onJump(lineId), onJumpReview()
export default function FinalisePanel({ blankLines, unconfirmedLines, busy, onFinalise, onJump, onJumpReview }) {
  const blank = Array.isArray(blankLines) ? blankLines : []
  const unconfirmed = Array.isArray(unconfirmedLines) ? unconfirmedLines : []
  return (
    <section id="stk-finalise" className="stk-section" aria-labelledby="stk-finalise-title">
      <h2 id="stk-finalise-title" className="stk-h2">
        Finalise
      </h2>
      <p className="stk-note">Every line needs a count and every difference needs a decision.</p>
      {blank.length > 0 ? (
        <div className="stk-block" role="alert">
          <p className="stk-block-text">{blankMessage(blank.length)}</p>
          <ul className="stk-blocklist">
            {blank.map((b) => (
              <li key={b.line_id}>
                <a
                  className="stk-link"
                  href={'#stk-row-' + b.line_id}
                  onClick={(e) => {
                    e.preventDefault()
                    if (onJump) onJump(b.line_id)
                  }}
                >
                  <span className="stk-mono">{b.product_code}</span> {b.description}
                </a>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      {unconfirmed.length > 0 ? (
        <div className="stk-block" role="alert">
          <p className="stk-block-text">{unconfirmedMessage(unconfirmed.length)}</p>
          <a
            className="stk-link"
            href="#stk-review"
            onClick={(e) => {
              e.preventDefault()
              if (onJumpReview) onJumpReview()
            }}
          >
            Open the review
          </a>
        </div>
      ) : null}
      <div className="stk-actions">
        <button type="button" className="stk-btn stk-btn-primary" disabled={Boolean(busy)} onClick={() => onFinalise && onFinalise()}>
          {busy === 'finalise' ? 'Working' : 'Finalise'}
        </button>
      </div>
    </section>
  )
}
