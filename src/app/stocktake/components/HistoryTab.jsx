import EventLog from './EventLog'
import LineHistory from './LineHistory'
import { fmtDateTime, fmtDay, fmtInt, fmtRand, listName, statusName } from './format'

// props: loading, message (plain error sentence or ''), history ({cycles, by_day}), events (store event log),
//        selectedCycleId, cycleEvents (events of the selected cycle or null), lineHistory (props of LineHistory),
//        onSelectCycle(cycleId), onOpenCycle(cycleId)
export default function HistoryTab({
  loading,
  message,
  history,
  events,
  selectedCycleId,
  cycleEvents,
  lineHistory,
  onSelectCycle,
  onOpenCycle,
}) {
  const cycles = history && Array.isArray(history.cycles) ? history.cycles : []
  const byDay = history && Array.isArray(history.by_day) ? history.by_day : []
  const selected = cycles.find((c) => c.cycle_id === selectedCycleId)
  return (
    <div className="stk-history">
      {loading ? (
        <p className="stk-note" aria-busy="true">
          Loading
        </p>
      ) : null}
      {message ? (
        <p className="stk-note stk-neg" role="alert">
          {message}
        </p>
      ) : null}

      <section className="stk-section" aria-labelledby="stk-cycles-title">
        <h2 id="stk-cycles-title" className="stk-h2">
          Lists
        </h2>
        {cycles.length === 0 ? (
          <p className="stk-note">No lists have been generated for this store yet.</p>
        ) : (
          <div className="stk-scroll">
            <table className="stk-plain">
              <thead>
                <tr>
                  <th scope="col">List</th>
                  <th scope="col">Status</th>
                  <th scope="col">Generated</th>
                  <th scope="col">Finalised</th>
                  <th scope="col" className="stk-num">Lines</th>
                  <th scope="col" className="stk-num">Captured</th>
                  <th scope="col" className="stk-num">Flagged</th>
                  <th scope="col" className="stk-num">Net variance</th>
                  <th scope="col"><span className="stk-sr">Actions</span></th>
                </tr>
              </thead>
              <tbody>
                {cycles.map((c) => (
                  <tr key={c.cycle_id} className={c.cycle_id === selectedCycleId ? 'stk-selected' : ''}>
                    <td>
                      <button
                        type="button"
                        className="stk-link stk-cyclebtn"
                        aria-pressed={c.cycle_id === selectedCycleId ? 'true' : 'false'}
                        onClick={() => onSelectCycle && onSelectCycle(c.cycle_id)}
                      >
                        {listName(c)}
                      </button>
                    </td>
                    <td>{statusName(c.status)}</td>
                    <td>
                      {c.generated_by}
                      <br />
                      <span className="stk-caption">{fmtDateTime(c.generated_at)}</span>
                    </td>
                    <td>
                      {c.finalised_at ? (
                        <>
                          {c.finalised_by}
                          <br />
                          <span className="stk-caption">{fmtDateTime(c.finalised_at)}</span>
                        </>
                      ) : (
                        ''
                      )}
                    </td>
                    <td className="stk-mono stk-num">{fmtInt(c.line_count)}</td>
                    <td className="stk-mono stk-num">{fmtInt(c.captured)}</td>
                    <td className="stk-mono stk-num">{fmtInt(c.flagged)}</td>
                    <td className="stk-mono stk-num">{c.variance_value === null || c.variance_value === undefined ? '' : fmtRand(c.variance_value)}</td>
                    <td>
                      {c.status !== 'CANCELLED' ? (
                        <button type="button" className="stk-btn stk-btn-secondary" onClick={() => onOpenCycle && onOpenCycle(c.cycle_id)}>
                          Open
                        </button>
                      ) : null}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {selected ? (
          <EventLog
            title={'Events for the ' + listName(selected).toLowerCase() + ' of ' + fmtDateTime(selected.generated_at)}
            headingLevel={3}
            events={cycleEvents}
            emptyText="No events were logged for this list."
          />
        ) : null}
      </section>

      <section className="stk-section" aria-labelledby="stk-adherence-title">
        <h2 id="stk-adherence-title" className="stk-h2">
          Adherence by day
        </h2>
        {byDay.length === 0 ? (
          <p className="stk-note">No days to show yet.</p>
        ) : (
          <div className="stk-scroll">
            <table className="stk-plain">
              <thead>
                <tr>
                  <th scope="col">Day</th>
                  <th scope="col" className="stk-num">Lists generated</th>
                  <th scope="col" className="stk-num">Lines issued</th>
                  <th scope="col" className="stk-num">Lists finalised</th>
                  <th scope="col" className="stk-num">Lines counted</th>
                </tr>
              </thead>
              <tbody>
                {byDay.map((d) => (
                  <tr key={d.day}>
                    <td className="stk-nowrap">{fmtDay(d.day)}</td>
                    <td className="stk-mono stk-num">{fmtInt(d.cycles_generated)}</td>
                    <td className="stk-mono stk-num">{fmtInt(d.lines_issued)}</td>
                    <td className="stk-mono stk-num">{fmtInt(d.cycles_finalised)}</td>
                    <td className="stk-mono stk-num">{fmtInt(d.lines_counted)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="stk-section" aria-labelledby="stk-events-title">
        <EventLog title="Event log" titleId="stk-events-title" events={events} headingLevel={2} />
      </section>

      <LineHistory {...(lineHistory || {})} />
    </div>
  )
}
