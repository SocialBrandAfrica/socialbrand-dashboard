import CycleView from './CycleView'
import GeneratePanel from './GeneratePanel'
import HistoryTab from './HistoryTab'
import PendingCards from './PendingCards'
import { fmtDay, fmtStocked, fmtTime } from './format'

// The text beside the header: Saving, Saved 14:07, or the warning that something did not save.
export function savedText(saveState, savedAt) {
  if (saveState === 'error') return 'Some counts are not saved'
  if (saveState === 'saving') return 'Saving'
  if (savedAt) return 'Saved ' + fmtTime(savedAt)
  return ''
}

// One store, one screen. props: store (overview row), storeState, tab ('count' | 'history'), cycleId (opened cycle or null),
// cycle ({doc, capture, confirmedBy, finalise, upload, exportNote, cancel}), generate ({subdept}), history (HistoryTab props),
// saveState, savedAt, busy, actions.
export default function StoreScreen({
  store,
  storeState,
  tab,
  cycleId,
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
  return (
    <div className="stk-store">
      <header className="stk-header">
        <div className="stk-header-top">
          <button type="button" className="stk-link" onClick={() => a.onBackToStores && a.onBackToStores()}>
            All stores
          </button>
          <p className={'stk-saved' + (saveState === 'error' ? ' stk-neg' : '')} aria-live="polite" data-save-state={saveState || 'idle'}>
            {saved}
          </p>
        </div>
        <h1 className="stk-h1">
          {store.store_name} <span className="stk-code">{store.store_code}</span>
        </h1>
        <p className="stk-caption">
          {fmtDay(store.today)}
          {stocked ? '. Draw stocked ' + stocked : ''}
        </p>
      </header>

      <div className="stk-tabs" role="tablist" aria-label="Store views">
        <button
          type="button"
          role="tab"
          id="stk-tab-count"
          aria-selected={tab !== 'history' ? 'true' : 'false'}
          aria-controls="stk-panel"
          className={'stk-tab' + (tab !== 'history' ? ' stk-tab-on' : '')}
          onClick={() => a.onTab && a.onTab('count')}
        >
          Count
        </button>
        <button
          type="button"
          role="tab"
          id="stk-tab-history"
          aria-selected={tab === 'history' ? 'true' : 'false'}
          aria-controls="stk-panel"
          className={'stk-tab' + (tab === 'history' ? ' stk-tab-on' : '')}
          onClick={() => a.onTab && a.onTab('history')}
        >
          History
        </button>
      </div>

      <div id="stk-panel" role="tabpanel" aria-labelledby={tab === 'history' ? 'stk-tab-history' : 'stk-tab-count'}>
        {tab === 'history' ? (
          <HistoryTab
            {...(history || {})}
            onSelectCycle={a.onSelectHistoryCycle}
            onOpenCycle={a.onOpenCycle}
          />
        ) : cycleId ? (
          <CycleView {...(cycle || {})} busy={busy} actions={a} />
        ) : (
          <>
            <PendingCards cycles={openCycles} busy={busy} onOpen={a.onOpenCycle} onDownload={a.onDownloadSheet} />
            <GeneratePanel
              store={store}
              state={storeState}
              openCycles={openCycles}
              subdept={generate ? generate.subdept : ''}
              busy={busy}
              onSubdeptChange={a.onSubdeptChange}
              onGenerate={a.onGenerate}
            />
          </>
        )}
      </div>
    </div>
  )
}
