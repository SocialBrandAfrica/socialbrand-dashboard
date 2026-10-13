'use client'
// =============================================================================
// Stocktake count app (stocktake.socialbrand.africa, SB-CC-STOCKTAKE-001 v1.2).
//
// This file holds state and the URL query and talks to the server through ./api.js.
// Everything drawn on screen is a pure component under ./components (props in, callbacks out).
// The page never computes a variance, a flag or a list size: it shows what the database returns
// and sends what the user typed. The count boxes save through ./saveQueue.js: 600 ms after the
// last key and on blur, one line at a time, in order, so a refresh or a dropped connection loses
// nothing the page showed as saved.
// =============================================================================

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import * as api from './api'
import { isBlankLine } from './components/CountTable'
import Notice from './components/Notice'
import StoreList from './components/StoreList'
import StoreScreen from './components/StoreScreen'
import { listName, plural } from './components/format'
import { createSaveQueue } from './saveQueue'

const REFRESH_DELAY_MS = 900
const LEAVE_MESSAGE = 'Some counts are not saved. Fix the lines marked Not saved before you leave.'

function readRoute() {
  const p = new URLSearchParams(window.location.search)
  return {
    store: p.get('store') || null,
    cycle: p.get('cycle') || null,
    tab: p.get('tab') === 'history' ? 'history' : 'count',
  }
}

function routeQuery(r) {
  const p = new URLSearchParams()
  if (r.store) p.set('store', r.store)
  if (r.cycle) p.set('cycle', r.cycle)
  if (r.tab === 'history') p.set('tab', 'history')
  const s = p.toString()
  return s ? '?' + s : ''
}

function sentence(text) {
  const t = String(text || '').trim()
  if (!t) return ''
  const cap = t.charAt(0).toUpperCase() + t.slice(1)
  return /[.!?]$/.test(cap) ? cap : cap + '.'
}

function scrollToId(id) {
  const el = document.getElementById(id)
  if (el && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function errorNotice(e) {
  return {
    kind: 'error',
    message: e && e.message ? e.message : 'Something went wrong. Try again.',
    signIn: Boolean(e && e.status === 401),
    cycleId: e && e.code === 'open_cycle_exists' ? e.cycleId : null,
  }
}

function without(map, key) {
  if (!(key in map)) return map
  const next = { ...map }
  delete next[key]
  return next
}

export default function StocktakePage() {
  const [route, setRoute] = useState(null)
  const [overview, setOverview] = useState({ status: 'loading', stores: [], message: '' })
  const [storeState, setStoreState] = useState(null)
  const [cycleDoc, setCycleDoc] = useState({ status: 'idle', data: null, message: '' })
  const [historyDoc, setHistoryDoc] = useState({ status: 'idle', history: null, events: [], message: '' })
  const [historyCycle, setHistoryCycle] = useState(null)
  const [historyCycleEvents, setHistoryCycleEvents] = useState(null)
  const [lookup, setLookup] = useState({ text: '', product: '', result: null, message: '' })
  const [drafts, setDrafts] = useState({})
  const [rowStates, setRowStates] = useState({})
  const [openRows, setOpenRows] = useState([])
  const [showOnlyBlank, setShowOnlyBlank] = useState(false)
  const [keepVisible, setKeepVisible] = useState([])
  const [saveState, setSaveState] = useState('idle')
  const [savedAt, setSavedAt] = useState(null)
  const [busy, setBusy] = useState(null)
  const [notice, setNotice] = useState(null)
  const [uploadResult, setUploadResult] = useState(null)
  const [finaliseResult, setFinaliseResult] = useState(null)
  const [confirmedBy, setConfirmedBy] = useState({})
  const [exportNote, setExportNote] = useState('')
  const [cancelUi, setCancelUi] = useState({ open: false, reason: '' })
  const [subdept, setSubdept] = useState('')

  // Refs hold what async work needs to read at the moment it runs.
  const routeRef = useRef(null)
  const cycleIdRef = useRef(null)
  const storeRef = useRef(null)
  const queueRef = useRef(null)
  const savesRef = useRef(0)
  const refreshTimerRef = useRef(null)

  const storeCode = route ? route.store : null
  const cycleId = route ? route.cycle : null
  const tab = route ? route.tab : 'count'

  // ---- navigation --------------------------------------------------------------------------

  const go = useCallback((patch, replace) => {
    const next = { store: null, cycle: null, tab: 'count', ...(routeRef.current || {}), ...patch }
    routeRef.current = next
    setRoute(next)
    const url = window.location.pathname + routeQuery(next)
    if (replace) window.history.replaceState(null, '', url)
    else window.history.pushState(null, '', url)
  }, [])

  // ---- loading -----------------------------------------------------------------------------

  const loadOverview = useCallback(async (quiet) => {
    if (!quiet) setOverview({ status: 'loading', stores: [], message: '' })
    try {
      const stores = await api.getOverview()
      setOverview({ status: 'ready', stores, message: '' })
    } catch (e) {
      setOverview((o) => ({ status: 'error', stores: quiet ? o.stores : [], message: e.message }))
    }
  }, [])

  const loadStoreState = useCallback(async (store, quiet) => {
    if (!quiet) setStoreState(null)
    try {
      const state = await api.getStoreState(store)
      if (storeRef.current === store) setStoreState(state)
    } catch (e) {
      if (storeRef.current === store) setNotice(errorNotice(e))
    }
  }, [])

  const loadCycle = useCallback(async (id, quiet) => {
    if (!quiet) setCycleDoc({ status: 'loading', data: null, message: '' })
    for (let attempt = 0; attempt < 4; attempt++) {
      const token = savesRef.current
      try {
        const data = await api.getCycle(id)
        if (cycleIdRef.current !== id) return
        // A save finished while this read ran, so the read may be older than that save. Read again.
        if (quiet && token !== savesRef.current && attempt < 3) continue
        setCycleDoc({ status: 'ready', data, message: '' })
        return
      } catch (e) {
        if (cycleIdRef.current !== id) return
        if (quiet) setNotice(errorNotice(e))
        else setCycleDoc({ status: 'error', data: null, message: e.message })
        return
      }
    }
  }, [])

  const loadHistory = useCallback(async (store) => {
    setHistoryDoc((d) => ({ ...d, status: 'loading', message: '' }))
    try {
      const body = await api.getHistory(store)
      if (storeRef.current !== store) return
      setHistoryDoc({
        status: 'ready',
        history: body && body.history ? body.history : { cycles: [], by_day: [] },
        events: body && Array.isArray(body.events) ? body.events : [],
        message: '',
      })
    } catch (e) {
      if (storeRef.current === store) setHistoryDoc((d) => ({ ...d, status: 'error', message: e.message }))
    }
  }, [])

  // ---- saved as typed ----------------------------------------------------------------------

  const setRowState = useCallback((lineId, value) => {
    setRowStates((prev) => {
      const next = { ...prev }
      if (value) next[lineId] = value
      else delete next[lineId]
      return next
    })
  }, [])

  // Show the saved count at once. The variance fields wait for the next read of the cycle.
  const patchLine = useCallback((lineId, number) => {
    setCycleDoc((doc) => {
      if (!doc.data) return doc
      const lines = doc.data.lines.map((l) =>
        l.line_id !== lineId
          ? l
          : { ...l, front: number, back: number === null ? null : 0, count_qty: number, stale: true }
      )
      const captured = lines.filter((l) => l.count_qty !== null && l.count_qty !== undefined).length
      return { ...doc, data: { ...doc.data, lines, counts: { ...doc.data.counts, captured, blank: lines.length - captured } } }
    })
  }, [])

  // Read the cycle again once the boxes have been quiet for a moment.
  const refreshSoon = useCallback(() => {
    clearTimeout(refreshTimerRef.current)
    const tick = () => {
      const id = cycleIdRef.current
      if (!id) return
      if (queueRef.current && queueRef.current.isBusy()) {
        refreshTimerRef.current = setTimeout(tick, REFRESH_DELAY_MS)
        return
      }
      loadCycle(id, true)
    }
    refreshTimerRef.current = setTimeout(tick, REFRESH_DELAY_MS)
  }, [loadCycle])

  const saveQueue = useMemo(
    () =>
      createSaveQueue({
        send: (id, lines) => api.captureLines(id, lines),
        getCycleId: () => cycleIdRef.current,
        on: {
          drafts: setDrafts,
          row: setRowState,
          status: setSaveState,
          saved: ({ lineId, number, applied, savedAt: at }) => {
            savesRef.current += 1
            if (applied) {
              patchLine(lineId, number)
              setConfirmedBy((prev) => without(prev, lineId))
            }
            setSavedAt(at || new Date().toISOString())
            refreshSoon()
          },
          failed: (e) => setNotice(errorNotice(e)),
        },
      }),
    [patchLine, refreshSoon, setRowState]
  )
  queueRef.current = saveQueue

  const changeCount = useCallback(
    (lineId, text) => {
      saveQueue.change(lineId, text)
      setKeepVisible((prev) => (prev.includes(lineId) ? prev : [...prev, lineId]))
    },
    [saveQueue]
  )

  const resetCapture = useCallback(() => {
    saveQueue.reset()
    clearTimeout(refreshTimerRef.current)
    setRowStates({})
    setOpenRows([])
    setShowOnlyBlank(false)
    setKeepVisible([])
    setFinaliseResult(null)
    setUploadResult(null)
    setConfirmedBy({})
    setExportNote('')
    setCancelUi({ open: false, reason: '' })
    setSaveState('idle')
    setSavedAt(null)
  }, [saveQueue])

  // Leave the open list only after everything typed has saved.
  const leave = useCallback(
    async (patch) => {
      if (cycleIdRef.current) {
        const ok = await saveQueue.flushAll()
        if (!ok) {
          setNotice({ kind: 'error', message: LEAVE_MESSAGE })
          return false
        }
      }
      setNotice(null)
      go(patch)
      return true
    },
    [saveQueue, go]
  )

  // ---- effects -----------------------------------------------------------------------------

  // Start: read the URL, load the stores, guard the browser's own back button and tab close.
  useEffect(() => {
    const first = readRoute()
    routeRef.current = first
    setRoute(first)
    loadOverview(false)

    function onPop() {
      const target = readRoute()
      const here = routeRef.current
      if (!here || here.cycle === target.cycle) {
        routeRef.current = target
        setRoute(target)
        return
      }
      saveQueue.flushAll().then((ok) => {
        if (ok) {
          routeRef.current = target
          setRoute(target)
        } else {
          window.history.pushState(null, '', window.location.pathname + routeQuery(here))
          setNotice({ kind: 'error', message: LEAVE_MESSAGE })
        }
      })
    }
    function onBeforeUnload(e) {
      if (Object.keys(saveQueue.drafts()).length > 0) {
        e.preventDefault()
        e.returnValue = ''
      }
    }
    function onOnline() {
      saveQueue.retryErrors()
    }
    window.addEventListener('popstate', onPop)
    window.addEventListener('beforeunload', onBeforeUnload)
    window.addEventListener('online', onOnline)
    return () => {
      window.removeEventListener('popstate', onPop)
      window.removeEventListener('beforeunload', onBeforeUnload)
      window.removeEventListener('online', onOnline)
    }
  }, [saveQueue, loadOverview])

  // A store opens: the stock figures behind its buttons.
  useEffect(() => {
    storeRef.current = storeCode
    setSubdept('')
    setHistoryCycle(null)
    setHistoryCycleEvents(null)
    setLookup({ text: '', product: '', result: null, message: '' })
    if (storeCode) loadStoreState(storeCode, false)
    else setStoreState(null)
  }, [storeCode, loadStoreState])

  // A list opens or closes.
  useEffect(() => {
    cycleIdRef.current = cycleId
    resetCapture()
    if (cycleId) loadCycle(cycleId, false)
    else setCycleDoc({ status: 'idle', data: null, message: '' })
  }, [cycleId, loadCycle, resetCapture])

  // A link with a list but no store: take the store from the list.
  const listStore = cycleDoc.data && cycleDoc.data.cycle ? cycleDoc.data.cycle.store_code : null
  useEffect(() => {
    if (cycleId && !storeCode && listStore) go({ store: listStore }, true)
  }, [cycleId, storeCode, listStore, go])

  // The History tab opens.
  useEffect(() => {
    if (storeCode && tab === 'history') {
      setHistoryCycle(null)
      setHistoryCycleEvents(null)
      loadHistory(storeCode)
    }
  }, [storeCode, tab, loadHistory])

  // Who confirmed a flagged line is in the event log, not on the line.
  const confirmedKey = useMemo(() => {
    const ls = cycleDoc.data ? cycleDoc.data.lines : []
    return ls
      .filter((l) => l.review_state === 'CONFIRMED' && !confirmedBy[l.line_id])
      .map((l) => l.line_id)
      .join(',')
  }, [cycleDoc.data, confirmedBy])
  useEffect(() => {
    if (!confirmedKey || !cycleId) return undefined
    let live = true
    api
      .getCycleEvents(cycleId)
      .then((events) => {
        if (!live) return
        const found = {}
        for (const ev of events) {
          if (ev.event_type === 'CONFIRM' && ev.line_id !== null && ev.line_id !== undefined && !(ev.line_id in found)) {
            found[ev.line_id] = ev.actor
          }
        }
        setConfirmedBy((prev) => ({ ...prev, ...found }))
      })
      .catch(() => {})
    return () => {
      live = false
    }
  }, [confirmedKey, cycleId])

  // ---- actions -----------------------------------------------------------------------------

  function focusLine(lineId, center) {
    const el = document.getElementById('stk-count-' + lineId)
    if (!el) return
    if (center && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'center' })
    el.focus({ preventScroll: Boolean(center) })
  }

  async function doGenerate(listType, sub) {
    setBusy('generate:' + listType)
    setNotice(null)
    try {
      const res = await api.generate({ store: storeCode, listType, subdept: sub })
      loadOverview(true)
      loadStoreState(storeCode, true)
      go({ cycle: res.cycle_id, tab: 'count' })
      setNotice({
        kind: 'info',
        message:
          'Generated a ' +
          listName({ list_type: res.list_type, subdept_name: res.subdept_name }).toLowerCase() +
          ' of ' +
          res.line_count +
          ' ' +
          plural(res.line_count, 'line', 'lines') +
          '.',
      })
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function doDownloadSheet(id) {
    setBusy('download:' + id)
    setNotice(null)
    try {
      const f = await api.downloadFile(api.sheetUrl(id), 'stocktake-count-sheets.xlsx')
      setNotice({ kind: 'info', message: 'Downloaded ' + f.filename + '.' })
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function doUpload(e) {
    const input = e.target
    const file = input.files && input.files[0]
    input.value = ''
    const id = cycleIdRef.current
    if (!file || !id) return
    if (!/\.xlsx$/i.test(file.name)) {
      setNotice({ kind: 'error', message: 'Choose the .xlsx count sheet you downloaded from this page.' })
      return
    }
    setBusy('upload')
    setNotice(null)
    try {
      await saveQueue.flushAll()
      const res = await api.uploadSheet(id, file)
      setUploadResult(res)
      savesRef.current += 1
      await loadCycle(id, true)
    } catch (err) {
      setNotice(errorNotice(err))
    } finally {
      setBusy(null)
    }
  }

  async function doFinalise() {
    const id = cycleIdRef.current
    setBusy('finalise')
    setNotice(null)
    try {
      const saved = await saveQueue.flushAll()
      if (!saved) {
        setNotice({ kind: 'error', message: 'Some counts are not saved. Fix the lines marked Not saved and try again.' })
        return
      }
      const res = await api.finalise(id)
      if (res && res.ok) {
        setFinaliseResult(null)
        await loadCycle(id, true)
        loadOverview(true)
        window.scrollTo({ top: 0, behavior: 'smooth' })
        return
      }
      setFinaliseResult(res)
      await loadCycle(id, true)
      const noBlank = !res || !Array.isArray(res.blank_lines) || res.blank_lines.length === 0
      scrollToId(noBlank ? 'stk-review' : 'stk-finalise')
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function doReview(lineId, action) {
    const id = cycleIdRef.current
    setBusy('review:' + lineId + ':' + action)
    setNotice(null)
    try {
      await saveQueue.flushAll()
      const res = await api.reviewLines(id, [{ line_id: lineId, action }])
      const rejected = res && Array.isArray(res.rejected) ? res.rejected : []
      if (rejected.length > 0) setNotice({ kind: 'error', message: sentence(rejected[0].reason) })
      if (action === 'RECOUNT') {
        saveQueue.discard(lineId)
        setKeepVisible((prev) => (prev.includes(lineId) ? prev : [...prev, lineId]))
      }
      setConfirmedBy((prev) => without(prev, lineId))
      savesRef.current += 1
      await loadCycle(id, true)
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function doExport(kind) {
    const id = cycleIdRef.current
    setBusy('export:' + kind)
    setNotice(null)
    try {
      const f = await api.downloadFile(api.exportUrl(id, kind), kind === 'TLX' ? 'stocktake.tlx' : 'stocktake-plu.xlsx')
      setExportNote('Downloaded ' + f.filename + '.')
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function doCancel() {
    const id = cycleIdRef.current
    setBusy('cancel')
    setNotice(null)
    try {
      await api.cancelCycle(id, cancelUi.reason.trim())
      resetCapture()
      loadOverview(true)
      loadStoreState(storeCode, true)
      go({ cycle: null, tab: 'count' })
      setNotice({ kind: 'info', message: 'The list was cancelled.' })
    } catch (e) {
      setNotice(errorNotice(e))
    } finally {
      setBusy(null)
    }
  }

  async function closeCycle() {
    const left = await leave({ cycle: null, tab: 'count' })
    if (left) {
      loadOverview(true)
      loadStoreState(storeCode, true)
    }
  }

  async function selectHistoryCycle(id) {
    if (historyCycle === id) {
      setHistoryCycle(null)
      setHistoryCycleEvents(null)
      return
    }
    setHistoryCycle(id)
    setHistoryCycleEvents(null)
    try {
      const events = await api.getCycleEvents(id)
      setHistoryCycleEvents(events)
    } catch (e) {
      setHistoryCycleEvents([])
      setNotice(errorNotice(e))
    }
  }

  async function doLookup() {
    const code = lookup.text.trim()
    if (!/^\d+$/.test(code)) {
      setLookup((l) => ({ ...l, result: null, message: 'Enter the product code as digits only.' }))
      return
    }
    setBusy('linehistory')
    setLookup((l) => ({ ...l, message: '' }))
    try {
      const result = await api.getLineHistory(storeCode, code)
      setLookup((l) => ({ ...l, product: code, result, message: '' }))
    } catch (e) {
      setLookup((l) => ({ ...l, result: null, message: e.message }))
    } finally {
      setBusy(null)
    }
  }

  const actions = {
    onBackToStores: () => leave({ store: null, cycle: null, tab: 'count' }),
    onTab: (t) => leave({ tab: t }),
    onOpenCycle: (id) => leave({ cycle: id, tab: 'count' }),
    onCloseCycle: closeCycle,
    onSubdeptChange: setSubdept,
    onGenerate: doGenerate,
    onDownloadSheet: doDownloadSheet,
    onUpload: doUpload,
    onChange: changeCount,
    onBlurLine: (id) => saveQueue.blur(id),
    onFocusLine: (id) => focusLine(id, false),
    onToggleRow: (id) => setOpenRows((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id])),
    onToggleBlank: (checked) => {
      setShowOnlyBlank(checked)
      setKeepVisible([])
    },
    onRetry: (id) => saveQueue.retry(id),
    onFinalise: doFinalise,
    onJump: (id) => focusLine(id, true),
    onJumpReview: () => scrollToId('stk-review'),
    onConfirm: (id) => doReview(id, 'CONFIRM'),
    onRecount: (id) => doReview(id, 'RECOUNT'),
    onExportTlx: () => doExport('TLX'),
    onExportPlu: () => doExport('PLU'),
    onCancelAsk: () => setCancelUi({ open: true, reason: '' }),
    onCancelKeep: () => setCancelUi({ open: false, reason: '' }),
    onCancelReason: (reason) => setCancelUi((c) => ({ ...c, reason })),
    onCancelConfirm: doCancel,
    onSelectHistoryCycle: selectHistoryCycle,
  }

  // ---- what the finalise message lists ------------------------------------------------------
  // The lists shrink as the user fixes lines, so the message never reads older than the table.

  const lines = cycleDoc.data ? cycleDoc.data.lines : null
  const blankLines = useMemo(() => {
    if (!finaliseResult || !Array.isArray(finaliseResult.blank_lines) || !lines) return []
    const byId = new Map(lines.map((l) => [l.line_id, l]))
    return finaliseResult.blank_lines.filter((b) => {
      const l = byId.get(b.line_id)
      return !l || isBlankLine(l, drafts)
    })
  }, [finaliseResult, lines, drafts])
  const unconfirmedLines = useMemo(() => {
    if (!finaliseResult || !Array.isArray(finaliseResult.unconfirmed_lines) || !lines) return []
    const byId = new Map(lines.map((l) => [l.line_id, l]))
    return finaliseResult.unconfirmed_lines.filter((u) => {
      const l = byId.get(u.line_id)
      if (!l || l.stale) return true
      return Boolean(l.flagged) && l.review_state !== 'CONFIRMED' && l.count_qty !== null && l.count_qty !== undefined
    })
  }, [finaliseResult, lines])

  // ---- screen ------------------------------------------------------------------------------

  const store = storeCode ? overview.stores.find((s) => s.store_code === storeCode) : null

  let body
  if (!route || (overview.status === 'loading' && overview.stores.length === 0)) {
    body = (
      <p className="stk-note" aria-busy="true">
        Loading
      </p>
    )
  } else if (overview.status === 'error' && overview.stores.length === 0) {
    body = (
      <div>
        <Notice kind="error" message={overview.message || 'The stores did not load.'} />
        <button type="button" className="stk-btn stk-btn-primary" onClick={() => loadOverview(false)}>
          Try again
        </button>
      </div>
    )
  } else if (!storeCode) {
    body = (
      <>
        <header className="stk-homehead">
          <h1 className="stk-h1">Stocktake</h1>
          <p className="stk-caption">Choose a store to count.</p>
        </header>
        <StoreList stores={overview.stores} onOpenStore={(code) => leave({ store: code, cycle: null, tab: 'count' })} />
      </>
    )
  } else if (!store) {
    body = (
      <div>
        <p className="stk-note">That store is not on your list.</p>
        <button type="button" className="stk-btn stk-btn-secondary" onClick={() => go({ store: null, cycle: null, tab: 'count' })}>
          All stores
        </button>
      </div>
    )
  } else {
    body = (
      <StoreScreen
        store={store}
        storeState={storeState}
        tab={tab}
        cycleId={cycleId}
        cycle={{
          doc: cycleDoc,
          capture: { drafts, rowStates, openRows, showOnlyBlank, keepVisible },
          confirmedBy,
          finalise: { blankLines, unconfirmedLines },
          upload: { result: uploadResult },
          exportNote,
          cancel: cancelUi,
        }}
        generate={{ subdept }}
        history={{
          loading: historyDoc.status === 'loading',
          message: historyDoc.status === 'error' ? historyDoc.message : '',
          history: historyDoc.history,
          events: historyDoc.events,
          selectedCycleId: historyCycle,
          cycleEvents: historyCycleEvents,
          lineHistory: {
            value: lookup.text,
            onValueChange: (text) => setLookup((l) => ({ ...l, text })),
            onLookup: doLookup,
            busy,
            result: lookup.result,
            product: lookup.product,
            message: lookup.message,
          },
        }}
        saveState={saveState}
        savedAt={savedAt}
        busy={busy}
        actions={actions}
      />
    )
  }

  let noticeAction
  if (notice && notice.signIn) {
    noticeAction = { label: 'Sign in', onClick: () => window.location.assign('/login') }
  } else if (notice && notice.cycleId) {
    noticeAction = {
      label: 'Open that list',
      onClick: () => {
        setNotice(null)
        leave({ cycle: notice.cycleId, tab: 'count' })
      },
    }
  }

  return (
    <main className="stk-page">
      {body}
      {notice ? (
        <div className="stk-notice-dock">
          <Notice kind={notice.kind} message={notice.message} action={noticeAction} onClose={() => setNotice(null)} />
        </div>
      ) : null}
    </main>
  )
}
