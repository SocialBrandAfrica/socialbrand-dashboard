import EventLog from './EventLog'
import LineHistory from './LineHistory'
import LoadError from './LoadError'
import { fmtDateTime, fmtDay, fmtInt, fmtRand, listName, listNoun, statusName } from './format'

// The actions of one list, first in its row so nothing hides behind a sideways scroll.
//   Open            every list that exists, a cancelled one read only
//   Reprint sheets  every list that is not cancelled, counts filled in
//   TLX again       a finalised list. The database logs every export.
//   PLU sheet again a finalised list
//   Events          the drill-down of every event of that list
function RowActions({ cycle, selected, busy, onSelectCycle, onOpenCycle, onDownloadSheet, onExport }) {
  const id = cycle.cycle_id
  const working = Boolean(busy)
  const finalised = cycle.status === 'FINALISED'
  const cancelled = cycle.status === 'CANCELLED'
  return (
    <div className="stk-rowactions">
      <button type="button" className="stk-btn stk-btn-secondary" onClick={() => onOpenCycle && onOpenCycle(id)}>
        Open
      </button>
      {!cancelled ? (
        <button type="button" className="stk-link" disabled={working} onClick={() => onDownloadSheet && onDownloadSheet(id)}>
          {busy === 'download:' + id ? 'Working' : 'Reprint sheets'}
        </button>
      ) : null}
      {finalised ? (
        <button type="button" className="stk-link" disabled={working} onClick={() => onExport && onExport(id, 'TLX')}>
          {busy === 'export:TLX:' + id ? 'Working' : 'TLX again'}
        </button>
      ) : null}
      {finalised ? (
        <button type="button" className="stk-link" disabled={working} onClick={() => onExport && onExport(id, 'PLU')}>
          {busy === 'export:PLU:' + id ? 'Working' : 'PLU sheet again'}
        </button>
      ) : null}
      <button type="button" className="stk-link" aria-pressed={selected ? 'true' : 'false'} onClick={() => onSelectCycle && onSelectCycle(id)}>
        Events
      </button>
    </div>
  )
}

// props: loading, message (plain error sentence or ''), signIn (the message is a sign-in that ended),
//        history ({cycles, by_day}), events (store event log), eventsLimit (the most events one read returns),
//        selectedCycleId, cycleEvents (events of the selected cycle or null), lineHistory (props of LineHistory), busy,
//        onSelectCycle(cycleId), onOpenCycle(cycleId), onDownloadSheet(cycleId), onExport(cycleId, 'TLX' | 'PLU'), onSignIn()
export default function HistoryTab({
  loading,
  message,
  signIn,
  history,
  events,
  eventsLimit,
  selectedCycleId,
  cycleEvents,
  lineHistory,
  busy,
  onSelectCycle,
  onOpenCycle,
  onDownloadSheet,
  onExport,
  onSignIn,
}) {
  const cycles = history && Array.isArray(history.cycles) ? history.cycles : []
  const byDay = history && Array.isArray(history.by_day) ? history.by_day : []
  const selected = cycles.find((c) => c.cycle_id === selectedCycleId)
  const listDates = Object.fromEntries(cycles.map((c) => [c.cycle_id, c.generated_at]))
  return (
    <div className="stk-history">
      {loading ? (
        <p className="stk-note" aria-busy="true">
          Loading
        </p>
      ) : null}
      {message ? <LoadError message={message} signIn={signIn} onSignIn={onSignIn} /> : null}

      <section className="stk-section" aria-labelledby="stk-cycles-title">
        <h2 id="stk-cycles-title" className="stk-h2">
          Lists
        </h2>
        {cycles.length === 0 ? (
          <p className="stk-note">No lists have been generated for this store yet.</p>
        ) : (
          <div className="stk-scroll">
            <table className="stk-plain stk-cycles">
              <thead>
                <tr>
                  <th scope="col">Actions</th>
                  <th scope="col">List</th>
                  <th scope="col">Status</th>
                  <th scope="col">Generated</th>
                  <th scope="col">Finalised</th>
                  <th scope="col" className="stk-num">Lines</th>
                  <th scope="col" className="stk-num">Captured</th>
                  <th scope="col" className="stk-num">Flagged</th>
                  <th scope="col" className="stk-num">Net variance</th>
                </tr>
              </thead>
              <tbody>
                {cycles.map((c) => (
                  <tr key={c.cycle_id} className={c.cycle_id === selectedCycleId ? 'stk-selected' : ''}>
                    <td className="stk-c-actions">
                      <RowActions
                        cycle={c}
                        selected={c.cycle_id === selectedCycleId}
                        busy={busy}
                        onSelectCycle={onSelectCycle}
                        onOpenCycle={onOpenCycle}
                        onDownloadSheet={onDownloadSheet}
                        onExport={onExport}
                      />
                    </td>
                    <td data-label="List">
                      <button type="button" className="stk-link stk-cyclebtn" onClick={() => onOpenCycle && onOpenCycle(c.cycle_id)}>
                        {listName(c)}
                      </button>
                    </td>
                    <td data-label="Status">{statusName(c.status)}</td>
                    <td data-label="Generated">
                      {c.generated_by}
                      <br />
                      <span className="stk-caption">{fmtDateTime(c.generated_at)}</span>
                    </td>
                    <td data-label="Finalised">
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
                    <td className="stk-mono stk-num" data-label="Lines">{fmtInt(c.line_count)}</td>
                    <td className="stk-mono stk-num" data-label="Captured">{fmtInt(c.captured)}</td>
                    <td className="stk-mono stk-num" data-label="Flagged">{fmtInt(c.flagged)}</td>
                    <td className="stk-mono stk-num" data-label="Net variance">{c.variance_value === null || c.variance_value === undefined ? '' : fmtRand(c.variance_value)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {selected ? (
          <EventLog
            title={'Events for the ' + listNoun(selected) + ' of ' + fmtDateTime(selected.generated_at)}
            headingLevel={3}
            events={cycleEvents}
            limit={eventsLimit}
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
            <table className="stk-plain stk-stack">
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
                    <td className="stk-nowrap" data-label="Day">{fmtDay(d.day)}</td>
                    <td className="stk-mono stk-num" data-label="Lists generated">{fmtInt(d.cycles_generated)}</td>
                    <td className="stk-mono stk-num" data-label="Lines issued">{fmtInt(d.lines_issued)}</td>
                    <td className="stk-mono stk-num" data-label="Lists finalised">{fmtInt(d.cycles_finalised)}</td>
                    <td className="stk-mono stk-num" data-label="Lines counted">{fmtInt(d.lines_counted)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="stk-section" aria-labelledby="stk-events-title">
        <EventLog
          title="Event log"
          titleId="stk-events-title"
          events={events}
          headingLevel={2}
          collapse
          listDates={listDates}
          limit={eventsLimit}
        />
      </section>

      <LineHistory {...(lineHistory || {})} />
    </div>
  )
}
