import { countWindowDays, fmtInt, listName, plural, weekdayName } from './format'

// The plain status lines of one store on the home list.
export function storeStatusLines(s) {
  const lines = []
  const open = Array.isArray(s.open_cycles) ? s.open_cycles : []
  if (open.length === 0) {
    lines.push('No list pending today')
  } else {
    for (const c of open) {
      lines.push(listName(c) + ' pending: ' + fmtInt(c.captured) + ' of ' + fmtInt(c.line_count) + ' captured')
    }
  }
  if (s.pool) {
    const days = countWindowDays(s.pool)
    const within = days ? ' in ' + days + ' days' : ' yet'
    lines.push(fmtInt(s.pool.uncounted) + ' ' + plural(s.pool.uncounted, 'line', 'lines') + ' not counted' + within)
  } else {
    lines.push('The draw for this store is not stocked yet')
  }
  if (Number(s.awaiting_posting) > 0) {
    lines.push(
      fmtInt(s.awaiting_posting) + ' counted ' + plural(s.awaiting_posting, 'line waits', 'lines wait') + ' for Sigma to post'
    )
  }
  if (s.rest_day && s.rest_day.is_rest_day) {
    const what = s.rest_day.reason === 'weekend' ? weekdayName(s.today) || 'Weekend' : s.rest_day.reason || 'Rest day'
    lines.push(what + ': no forced count')
  }
  return lines
}

// props: stores (rpc_stocktake_overview rows), onOpenStore(storeCode)
export default function StoreList({ stores, onOpenStore }) {
  const list = Array.isArray(stores) ? stores : []
  if (list.length === 0) {
    return <p className="stk-note">No stores are available to you.</p>
  }
  return (
    <section aria-labelledby="stk-stores-title">
      <h2 id="stk-stores-title" className="stk-h2">
        Stores
      </h2>
      <ul className="stk-storelist">
        {list.map((s) => (
          <li key={s.store_code}>
            <button
              type="button"
              className="stk-storecard"
              onClick={() => onOpenStore && onOpenStore(s.store_code)}
            >
              <span className="stk-storename">
                {s.store_name} <span className="stk-code">{s.store_code}</span>
              </span>
              {storeStatusLines(s).map((line, i) => (
                <span key={i} className="stk-statusline">
                  {line}
                </span>
              ))}
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}
