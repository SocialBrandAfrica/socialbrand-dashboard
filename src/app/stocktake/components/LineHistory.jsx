import { fmtDay, fmtPct, fmtQty, fmtRand, fmtSigned, listName } from './format'

// props: value (the product code box text), onValueChange(text), onLookup(), busy (string or null),
//        result ({ app, ledger } from rpc_stocktake_line_history or null), product (the code that was looked up),
//        message (a plain error sentence or '')
export default function LineHistory({ value, onValueChange, onLookup, busy, result, product, message }) {
  const app = result && Array.isArray(result.app) ? result.app : []
  const ledger = result && Array.isArray(result.ledger) ? result.ledger : []
  return (
    <section className="stk-section" aria-labelledby="stk-linehist-title">
      <h2 id="stk-linehist-title" className="stk-h2">
        Count history of a line
      </h2>
      <form
        className="stk-inline"
        onSubmit={(e) => {
          e.preventDefault()
          if (onLookup) onLookup()
        }}
      >
        <label className="stk-field">
          <span className="stk-label">Product code</span>
          <input
            className="stk-input stk-mono"
            type="text"
            inputMode="numeric"
            autoComplete="off"
            value={value || ''}
            onChange={(e) => onValueChange && onValueChange(e.target.value)}
          />
        </label>
        <button type="submit" className="stk-btn stk-btn-secondary" disabled={Boolean(busy)}>
          {busy === 'linehistory' ? 'Working' : 'Show history'}
        </button>
      </form>
      {message ? (
        <p className="stk-note stk-neg" role="alert">
          {message}
        </p>
      ) : null}
      {result ? (
        app.length === 0 && ledger.length === 0 ? (
          <p className="stk-note">No counts found for product code {product}.</p>
        ) : (
          <>
            <h3 className="stk-h3">Counts on this page for {product}</h3>
            {app.length === 0 ? (
              <p className="stk-note">No counts were made on this page.</p>
            ) : (
              <div className="stk-scroll">
                <table className="stk-plain">
                  <thead>
                    <tr>
                      <th scope="col">List</th>
                      <th scope="col">Date</th>
                      <th scope="col" className="stk-num">System stock</th>
                      <th scope="col" className="stk-num">Count</th>
                      <th scope="col" className="stk-num">Variance</th>
                      <th scope="col" className="stk-num">Variance value</th>
                      <th scope="col">Counted by</th>
                    </tr>
                  </thead>
                  <tbody>
                    {app.map((r, i) => (
                      <tr key={r.cycle_id + '-' + i}>
                        <td>{listName(r)}</td>
                        <td className="stk-nowrap">{fmtDay(r.date)}</td>
                        <td className="stk-mono stk-num">{fmtQty(r.system_stock)}</td>
                        <td className="stk-mono stk-num">{fmtQty(r.count_qty)}</td>
                        <td className="stk-mono stk-num">{fmtSigned(r.variance_qty)}</td>
                        <td className="stk-mono stk-num">{r.variance_value === null || r.variance_value === undefined ? '' : fmtRand(r.variance_value)}</td>
                        <td>{r.captured_by || ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <h3 className="stk-h3">Counts in the Sigma ledger for {product}</h3>
            {ledger.length === 0 ? (
              <p className="stk-note">No counts are posted in Sigma.</p>
            ) : (
              <div className="stk-scroll">
                <table className="stk-plain">
                  <thead>
                    <tr>
                      <th scope="col">Date</th>
                      <th scope="col" className="stk-num">Correction</th>
                      <th scope="col" className="stk-num">Stock before</th>
                      <th scope="col" className="stk-num">Stock after</th>
                      <th scope="col" className="stk-num">Correction %</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ledger.map((r, i) => (
                      <tr key={String(r.date) + '-' + i}>
                        <td className="stk-nowrap">{fmtDay(r.date)}</td>
                        <td className="stk-mono stk-num">{fmtSigned(r.correction)}</td>
                        <td className="stk-mono stk-num">{fmtQty(r.soh_before)}</td>
                        <td className="stk-mono stk-num">{fmtQty(r.soh_after)}</td>
                        <td className="stk-mono stk-num">{fmtPct(r.correction_pct)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )
      ) : null}
    </section>
  )
}
