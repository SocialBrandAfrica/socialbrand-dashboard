import { describeEvent, eventName, fmtDateTime } from './format'

// props: events (rpc_stocktake_events rows, newest first), title, headingLevel (2 or 3)
export default function EventLog({ events, title, titleId, headingLevel = 2, emptyText = 'No events yet.' }) {
  const list = Array.isArray(events) ? events : []
  const Heading = 'h' + headingLevel
  return (
    <div className="stk-eventlog">
      {title ? (
        <Heading id={titleId} className={headingLevel === 2 ? 'stk-h2' : 'stk-h3'}>
          {title}
        </Heading>
      ) : null}
      {list.length === 0 ? (
        <p className="stk-note">{emptyText}</p>
      ) : (
        <div className="stk-scroll">
          <table className="stk-plain">
            <thead>
              <tr>
                <th scope="col">Time</th>
                <th scope="col">User</th>
                <th scope="col">Event</th>
                <th scope="col">Detail</th>
              </tr>
            </thead>
            <tbody>
              {list.map((e) => (
                <tr key={e.event_id}>
                  <td className="stk-nowrap">{fmtDateTime(e.at)}</td>
                  <td>{e.actor}</td>
                  <td>{eventName(e.event_type)}</td>
                  <td>{describeEvent(e)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
