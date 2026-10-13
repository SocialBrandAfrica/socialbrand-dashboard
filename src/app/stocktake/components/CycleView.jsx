import CountTable from './CountTable'
import FinalisePanel from './FinalisePanel'
import LoadError from './LoadError'
import ReadyPanel from './ReadyPanel'
import StepBar from './StepBar'
import VarianceReview from './VarianceReview'
import { stepFor } from '../routeState'
import { fmtDateTime, fmtInt, listName, plural, skippedText, statusName } from './format'

export function uploadSentence(r) {
  const set = Number(r.set) || 0
  const same = Number(r.unchanged) || 0
  const skipped = Array.isArray(r.rejected) ? r.rejected.length : 0
  let s = 'Sheet read: ' + fmtInt(set) + ' ' + plural(set, 'line', 'lines') + ' set, ' + fmtInt(same) + ' unchanged.'
  if (skipped > 0) s += ' ' + fmtInt(skipped) + ' ' + plural(skipped, 'row was', 'rows were') + ' skipped.'
  return s
}

function UploadResult({ result }) {
  if (!result) return null
  const skipped = Array.isArray(result.rejected) ? result.rejected : []
  const unmatched = Number(result.unmatched_rows) || 0
  return (
    <div className="stk-result" role="status">
      <p className="stk-note">{uploadSentence(result)}</p>
      {unmatched > 0 ? (
        <p className="stk-note">
          {fmtInt(unmatched)} {plural(unmatched, 'row is', 'rows are')} not on this list.
        </p>
      ) : null}
      {skipped.length > 0 ? (
        <ul className="stk-skiplist">
          {skipped.map((item, i) => (
            <li key={i}>{skippedText(item)}</li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}

function CancelBox({ cancel, busy, onAsk, onKeep, onReason, onConfirm }) {
  if (!cancel || !cancel.open) {
    return (
      <p className="stk-cancel-line">
        <button type="button" className="stk-link" onClick={() => onAsk && onAsk()}>
          Cancel this list
        </button>
      </p>
    )
  }
  return (
    <div className="stk-block" role="alertdialog" aria-label="Cancel this list">
      <p className="stk-block-text">Cancel this list? Its lines go back to the pool and the counts typed so far are not used.</p>
      <label className="stk-field">
        <span className="stk-label">Reason (optional)</span>
        <input
          className="stk-input"
          type="text"
          autoComplete="off"
          value={cancel.reason || ''}
          onChange={(e) => onReason && onReason(e.target.value)}
        />
      </label>
      <div className="stk-actions">
        <button type="button" className="stk-btn stk-btn-danger" disabled={Boolean(busy)} onClick={() => onConfirm && onConfirm()}>
          {busy === 'cancel' ? 'Working' : 'Yes, cancel the list'}
        </button>
        <button type="button" className="stk-btn stk-btn-secondary" disabled={Boolean(busy)} onClick={() => onKeep && onKeep()}>
          Keep the list
        </button>
      </div>
    </div>
  )
}

// What each step says it is for, in one sentence. Worded once so the page and the tests read the same text.
export const STEP_NOTES = {
  print: 'Download the count sheets and print them. Or count on the tablet and skip the sheets. Upload a filled sheet here.',
  count: 'Type the count for every line. Counts save as you type. Enter 0 where the item is not on the shelf.',
  review: 'These lines differ from the system. Confirm the count or send the line for a recount.',
  finish: 'Every line needs a count and every difference needs a decision.',
}

function NextButton({ label, onClick }) {
  return (
    <p className="stk-nextline">
      <button type="button" className="stk-btn stk-btn-primary" onClick={() => onClick && onClick()}>
        {label}
      </button>
    </p>
  )
}

// The opened cycle. props: doc ({status, data, message, signIn}), step (the chosen step or null), capture, confirmedBy,
// finalise ({blankLines, unconfirmedLines}), upload ({result}), exportNote, fractionalLines, cancel ({open, reason}), busy, actions.
export default function CycleView({ doc, step, capture, confirmedBy, finalise, upload, exportNote, fractionalLines, cancel, busy, actions }) {
  const a = actions || {}
  const cap = capture || {}
  if (!doc || doc.status === 'loading') {
    return (
      <p className="stk-note" aria-busy="true">
        Loading
      </p>
    )
  }
  if (doc.status === 'error' || !doc.data) {
    return (
      <LoadError message={doc.message || 'This list did not load.'} signIn={doc.signIn} onSignIn={a.onSignIn}>
        <button type="button" className="stk-btn stk-btn-secondary" onClick={() => a.onCloseCycle && a.onCloseCycle()}>
          Back to lists
        </button>
      </LoadError>
    )
  }

  const { cycle, counts, lines } = doc.data
  const status = cycle.status
  const closed = status === 'FINALISED' || status === 'CANCELLED'
  const total = Number(counts.lines) || 0
  const captured = Number(counts.captured) || 0
  const percent = total > 0 ? Math.round((100 * captured) / total) : 0
  const flaggedOpen = Number(counts.flagged_open) || 0
  const current = closed ? null : stepFor(step, counts)

  return (
    <div className="stk-cycle">
      {closed ? (
        <p className="stk-backline">
          <button type="button" className="stk-link" onClick={() => a.onCloseCycle && a.onCloseCycle()}>
            Back to lists
          </button>
        </p>
      ) : (
        <StepBar current={current} reachable onStep={a.onStep} onGenerate={a.onCloseCycle} />
      )}
      <h2 className="stk-h2">{listName(cycle)}</h2>
      <p className="stk-caption">
        Generated by {cycle.generated_by} on {fmtDateTime(cycle.generated_at)}. {statusName(status)}.
      </p>
      <div className="stk-progress">
        <p className="stk-progress-text" aria-live="polite">
          {fmtInt(captured)} of {fmtInt(total)} captured
        </p>
        <div
          className="stk-bar"
          role="progressbar"
          aria-label="Lines captured"
          aria-valuemin="0"
          aria-valuemax={total}
          aria-valuenow={captured}
        >
          <div className="stk-bar-fill" style={{ width: percent + '%' }} />
        </div>
        {!closed && flaggedOpen > 0 && current !== 'review' ? (
          <p className="stk-caption">
            {fmtInt(flaggedOpen)} {plural(flaggedOpen, 'line differs', 'lines differ')} from the system.{' '}
            <a
              className="stk-link"
              href="#stk-review"
              onClick={(e) => {
                e.preventDefault()
                if (a.onJumpReview) a.onJumpReview()
              }}
            >
              Review
            </a>
          </p>
        ) : null}
      </div>

      {status === 'CANCELLED' ? (
        <p className="stk-note">
          This list was cancelled by {cycle.cancelled_by} on {fmtDateTime(cycle.cancelled_at)}.
          {cycle.cancel_reason ? ' Reason: ' + cycle.cancel_reason + '.' : ''}
        </p>
      ) : null}

      {status === 'FINALISED' ? (
        <ReadyPanel
          cycle={cycle}
          counts={counts}
          busy={busy}
          exportNote={exportNote}
          fractionalLines={fractionalLines}
          onExportTlx={a.onExportTlx}
          onExportPlu={a.onExportPlu}
        />
      ) : null}

      {status === 'FINALISED' ? (
        <section className="stk-section" aria-label="Sheets">
          <div className="stk-actions">
            <button
              type="button"
              className="stk-btn stk-btn-secondary"
              disabled={Boolean(busy)}
              onClick={() => a.onDownloadSheet && a.onDownloadSheet(cycle.cycle_id)}
            >
              {busy === 'download:' + cycle.cycle_id ? 'Working' : 'Download count sheets'}
            </button>
          </div>
        </section>
      ) : null}

      {current === 'print' ? (
        <section className="stk-section" aria-labelledby="stk-print-title">
          <h2 id="stk-print-title" className="stk-h2">
            Print the count sheets
          </h2>
          <p className="stk-note">{STEP_NOTES.print}</p>
          <div className="stk-actions">
            <button
              type="button"
              className="stk-btn stk-btn-secondary"
              disabled={Boolean(busy)}
              onClick={() => a.onDownloadSheet && a.onDownloadSheet(cycle.cycle_id)}
            >
              {busy === 'download:' + cycle.cycle_id ? 'Working' : 'Download count sheets'}
            </button>
            <label className={'stk-btn stk-btn-secondary stk-filebtn' + (busy ? ' stk-disabled' : '')}>
              <input
                className="stk-fileinput"
                type="file"
                accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                disabled={Boolean(busy)}
                onChange={(e) => a.onUpload && a.onUpload(e)}
              />
              <span>{busy === 'upload' ? 'Working' : 'Upload filled sheet'}</span>
            </label>
          </div>
          <UploadResult result={upload ? upload.result : null} />
          <NextButton label="Next: Count" onClick={() => a.onStep && a.onStep('count')} />
        </section>
      ) : null}

      {current === 'count' || status === 'FINALISED' ? (
        <section className="stk-section" aria-labelledby="stk-lines-title">
          <div className="stk-tablehead">
            <h2 id="stk-lines-title" className="stk-h2">
              {closed ? 'Counts' : 'Count the lines'}
            </h2>
            {!closed ? (
              <label className="stk-toggle">
                <input
                  type="checkbox"
                  checked={Boolean(cap.showOnlyBlank)}
                  onChange={(e) => a.onToggleBlank && a.onToggleBlank(e.target.checked)}
                />
                <span>Show only blank lines</span>
              </label>
            ) : null}
          </div>
          {!closed ? <p className="stk-note">{STEP_NOTES.count}</p> : null}
          <CountTable
            lines={lines}
            drafts={cap.drafts}
            rowStates={cap.rowStates}
            openRows={cap.openRows}
            showOnlyBlank={cap.showOnlyBlank && !closed}
            keepVisible={cap.keepVisible}
            readOnly={closed}
            onChange={a.onChange}
            onBlurLine={a.onBlurLine}
            onFocusLine={a.onFocusLine}
            onToggleRow={a.onToggleRow}
            onRetry={a.onRetry}
          />
          {!closed ? <NextButton label="Next: Review" onClick={() => a.onStep && a.onStep('review')} /> : null}
        </section>
      ) : null}

      {current === 'review' ? (
        Number(counts.flagged) > 0 ? (
          <>
            <VarianceReview lines={lines} confirmedBy={confirmedBy} busy={busy} onConfirm={a.onConfirm} onRecount={a.onRecount} />
            <NextButton label="Next: Finish" onClick={() => a.onStep && a.onStep('finish')} />
          </>
        ) : (
          <section id="stk-review" className="stk-section" aria-labelledby="stk-review-title">
            <h2 id="stk-review-title" className="stk-h2">
              Review the differences
            </h2>
            <p className="stk-note">No line differs from the system. Nothing needs a decision.</p>
            <NextButton label="Next: Finish" onClick={() => a.onStep && a.onStep('finish')} />
          </section>
        )
      ) : null}

      {current === 'finish' ? (
        <FinalisePanel
          blankLines={finalise ? finalise.blankLines : []}
          unconfirmedLines={finalise ? finalise.unconfirmedLines : []}
          busy={busy}
          onFinalise={a.onFinalise}
          onJump={a.onJump}
          onJumpReview={a.onJumpReview}
        />
      ) : null}

      {!closed ? (
        <CancelBox
          cancel={cancel}
          busy={busy}
          onAsk={a.onCancelAsk}
          onKeep={a.onCancelKeep}
          onReason={a.onCancelReason}
          onConfirm={a.onCancelConfirm}
        />
      ) : null}
    </div>
  )
}
