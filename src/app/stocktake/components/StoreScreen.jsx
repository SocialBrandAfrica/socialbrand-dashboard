import CycleView from './CycleView'
import GeneratePanel from './GeneratePanel'
import HistoryTab from './HistoryTab'
import PendingCards from './PendingCards'
import ReadyCard from './ReadyCard'
import StepBar from './StepBar'
import { fmtDay, fmtStocked, fmtTime } from './format'

// Shown only while a typed count is waiting or failed. Typed counts are kept on the tablet.
export const OFFLINE_NOTE = 'Counts typed while offline are kept on this tablet and send when the signal returns.'

// The text beside the header: Saving, Saved 14:07, or the warning that something did not save.
export function savedText(saveState, savedAt) {
  if (saveState === 'error') return 'Some counts are not saved'
  if (saveState === 'saving') return 'Saving'
  if (savedAt) return 'Saved ' + fmtTime(savedAt)
  return ''
}

// One store, one screen. The count is a flow, not tabs: Generate, then Print, Count, Review, Finish (StepBar).
// History is its own screen, one link away. props: store (overview row), storeState, storeStateError ({message, signIn} or null),
// tab ('count' | 'history': which screen), cycleId (opened cycle or null), step (the chosen step of the open list or null),
// cycle ({doc, capture, confirmedBy, finalise, upload, exportNote, fractionalLines, cancel}), generate ({subdept, supplier}),
// history (HistoryTab props), saveState, savedAt, busy, actions.
export default function StoreScreen({
  store,
  storeState,
  storeStateError,
  tab,
  cycleId,
  step,
  cycle,
  generate,
  history,
  saveState,
  savedAt,
  busy,
  actions,
}) {
  const a = actions || {}
  const stocked = store.pool && store.pool.refreshed_at ? fmtStocked(store.pool.refreshed_at, store.today) : ''
  const saved = savedText(saveState, savedAt)
  const openCycles = Array.isArray(store.open_cycles) ? store.open_cycles : []
  const onHistory = tab === 'history'
  return (
    <div className="stk-store">
      <header className="stk-header">
        <div className="stk-header-top">
          <button type="button" className="stk-link" onClick={() => a.onBackToStores && a.onBackToStores()}>
            All stores
          </button>
          <div className="stk-headlinks">
            {onHistory ? null : (
              <button type="button" className="stk-link" onClick={() => a.onTab && a.onTab('history')}>
                History
              </button>
            )}
            <p className={'stk-saved' + (saveState === 'error' ? ' stk-neg' : '')} aria-live="polite" data-save-state={saveState || 'idle'}>
              {saved}
            </p>
          </div>
        </div>
        <h1 className="stk-h1">
          {store.store_name} <span className="stk-code">{store.store_code}</span>
        </h1>
        <p className="stk-caption">
          {fmtDay(store.today)}
          {stocked ? '. Draw stocked ' + stocked : ''}
        </p>
      </header>

      {onHistory ? (
        <div id="stk-panel">
          <p className="stk-backline">
            <button type="button" className="stk-link" onClick={() => a.onTab && a.onTab('count')}>
              Back to counting
            </button>
          </p>
          <HistoryTab
            {...(history || {})}
            busy={busy}
            onSelectCycle={a.onSelectHistoryCycle}
            onOpenCycle={a.onOpenCycle}
            onDownloadSheet={a.onDownloadSheet}
            onExport={a.onExport}
            onSignIn={a.onSignIn}
          />
        </div>
      ) : cycleId ? (
        <div id="stk-panel">
          <CycleView {...(cycle || {})} step={step} busy={busy} actions={a} />
        </div>
      ) : (
        <div id="stk-panel">
          <StepBar current="generate" reachable={false} />
          <ReadyCard finalised={store.last_finalised} onOpen={a.onOpenCycle} />
          <PendingCards cycles={openCycles} busy={busy} onOpen={a.onOpenCycle} onDownload={a.onDownloadSheet} />
          <GeneratePanel
            store={store}
            state={storeState}
            error={storeStateError}
            openCycles={openCycles}
            subdept={generate ? generate.subdept : ''}
            supplier={generate ? generate.supplier : ''}
            busy={busy}
            onSubdeptChange={a.onSubdeptChange}
            onSupplierChange={a.onSupplierChange}
            onGenerate={a.onGenerate}
            onRetry={a.onRetryStoreState}
            onSignIn={a.onSignIn}
          />
        </div>
      )}

      {saveState && saveState !== 'idle' ? (
        <p className="stk-offline" role="status">
          {OFFLINE_NOTE}
        </p>
      ) : null}
    </div>
  )
}
