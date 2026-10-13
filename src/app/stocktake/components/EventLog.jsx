import { describeEvent, eventName, fmtDateTime, fmtInt, fmtShortDate, joinNames } from './format'

// The store-wide log can hold thousands of EDIT rows, one per typed count. A run of EDIT events of
// one list reads as one row. Every other event type stays its own row. A single EDIT is not a run,
// so it keeps its own row and its full sentence.
//   events: newest first. listDates: { cycleId: generated_at } to name the list by its date.
// Returns [{ key, event }] for a plain row and [{ key, run: [events] }] for a collapsed run.
export function collapseEdits(events, listDates) {
  const list = Array.isArray(events) ? events : []
  const rows = []
  let i = 0
  while (i < list.length) {
    const e = list[i]
    let j = i + 1
    if (e.event_type === 'EDIT') {
      while (j < list.length && list[j].event_type === 'EDIT' && list[j].cycle_id === e.cycle_id) j += 1
    }
    if (j - i > 1) rows.push({ key: 'run-' + e.event_id, run: list.slice(i, j), listDate: listDates ? listDates[e.cycle_id] : null })
    else rows.push({ key: 'event-' + e.event_id, event: e })
    i = j
  }
  return rows
}

function runSentence(run, listDate) {
  const n = run.length
  const when = listDate ? 'the list of ' + fmtShortDate(listDate) : 'an earlier list'
  return fmtInt(n) + ' counts typed or changed on ' + when + '.'
}

function uniqueActors(run) {
  const seen = []
  for (const e of run) if (e.actor && !seen.includes(e.actor)) seen.push(e.actor)
  return seen
}

// props: events (rpc_stocktake_events rows, newest first), title, headingLevel (2 or 3),
//        collapse (true in the store-wide log), listDates ({cycleId: generated_at}),
//        limit (the most events one read returns: when events reach it the read was cut short)
export default function EventLog({
  events,
  title,
  titleId,
  headingLevel = 2,
  emptyText = 'No events yet.',
  collapse = false,
  listDates,
  limit,
}) {
  const list = Array.isArray(events) ? events : []
  const Heading = 'h' + headingLevel
  const cut = Number(limit) > 0 && list.length >= Number(limit)
  const rows = collapse ? collapseEdits(list, listDates) : list.map((e) => ({ key: 'event-' + e.event_id, event: e }))
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
        <>
          {cut ? <p className="stk-note">Showing the newest {fmtInt(list.length)} events.</p> : null}
          <div className="stk-scroll">
            <table className="stk-plain stk-stack stk-events">
              <thead>
                <tr>
                  <th scope="col">Time</th>
                  <th scope="col">User</th>
                  <th scope="col">Event</th>
                  <th scope="col">Detail</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) =>
                  r.run ? (
                    <tr key={r.key} data-run="true">
                      <td className="stk-nowrap" data-label="Time">{fmtDateTime(r.run[0].at)}</td>
                      <td data-label="User">{joinNames(uniqueActors(r.run))}</td>
                      <td data-label="Event">{eventName('EDIT')}</td>
                      <td data-label="Detail">{runSentence(r.run, r.listDate)}</td>
                    </tr>
                  ) : (
                    <tr key={r.key}>
                      <td className="stk-nowrap" data-label="Time">{fmtDateTime(r.event.at)}</td>
                      <td data-label="User">{r.event.actor}</td>
                      <td data-label="Event">{eventName(r.event.event_type)}</td>
                      <td data-label="Detail">{describeEvent(r.event)}</td>
                    </tr>
                  )
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}
