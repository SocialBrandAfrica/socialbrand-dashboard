import LoadError from './LoadError'
import { fmtInt, plural, restReasonDays } from './format'

const GROUPS = [
  ['NEGATIVE', 'negative'],
  ['INACTIVE', 'inactive'],
  ['SUSPECT', 'suspect'],
  ['ZERO', 'zero stock'],
]

function num(v) {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

// How many lines each button will produce, from the store's own volume and the stocked draw.
export function generateCounts(store, state, subdept, supplier) {
  const draw = (state && state.draw) || {}
  const drawTotal = GROUPS.reduce((sum, g) => sum + num(draw[g[0]]), 0)
  const daily = num(store && store.daily_volume)
  const adhoc = num(store && store.adhoc_batch)
  const picked = ((state && state.subdepts) || []).find((s) => s.subdept_name === subdept)
  const pickedSupplier = ((state && state.suppliers) || []).find((s) => String(s.supplier_nr) === String(supplier))
  return {
    drawTotal,
    daily: Math.min(daily, drawTotal),
    confirm: Math.min(daily, num(state && state.confirm_lines)),
    plu: num(state && state.plu_lines),
    batch: picked ? Math.min(adhoc, num(picked.lines)) : 0,
    supplier: pickedSupplier ? Math.min(adhoc, num(pickedSupplier.lines)) : 0,
  }
}

function groupSentence(draw) {
  const parts = GROUPS.map((g) => fmtInt(num(draw[g[0]])) + ' ' + g[1])
  return parts.slice(0, -1).join(', ') + ' and ' + parts[parts.length - 1]
}

function hasOpen(openCycles, listType, subdept, supplier) {
  return (openCycles || []).some(
    (c) =>
      c.list_type === listType &&
      (listType !== 'ADHOC' || (c.subdept_name || '') === (subdept || '')) &&
      (listType !== 'SUPPLIER' || String(c.supplier_nr) === String(supplier))
  )
}

function linesLabel(n) {
  return fmtInt(n) + ' ' + plural(n, 'line', 'lines')
}

// One generate button with the one plain sentence that explains why it is off.
function GenerateRow({ label, listType, subdept, supplier, off, reason, working, isBusy, primary, onGenerate, children }) {
  return (
    <div className="stk-genrow">
      <div className="stk-genaction">
        {children}
        <button
          type="button"
          className={'stk-btn ' + (primary ? 'stk-btn-primary' : 'stk-btn-secondary')}
          disabled={working || off}
          onClick={() => onGenerate && onGenerate(listType, subdept, supplier)}
        >
          {isBusy ? 'Working' : label}
        </button>
      </div>
      {reason ? <p className="stk-caption">{reason}</p> : null}
    </div>
  )
}

function reasonFor(open, empty) {
  if (open) return 'This list is open. Finish it or cancel it first.'
  if (empty) return 'No lines are left for this list.'
  return ''
}

// props: store, state (rpc_stocktake_store_state or null), error ({message, signIn} when the read failed),
//        openCycles, subdept, supplier (a supplier number as text), busy (string or null), onSubdeptChange(name),
//        onSupplierChange(nr), onGenerate(listType, subdept, supplier),
//        onRetry() (read the store figures again), onSignIn()
export default function GeneratePanel({ store, state, error, openCycles, subdept, supplier, busy, onSubdeptChange, onSupplierChange, onGenerate, onRetry, onSignIn }) {
  const restDay = store && store.rest_day && store.rest_day.is_rest_day ? store.rest_day : null
  if (!state) {
    return (
      <section className="stk-section" aria-labelledby="stk-generate-title">
        <h2 id="stk-generate-title" className="stk-h2">
          Generate a list
        </h2>
        {error ? (
          <LoadError message={error.message} signIn={error.signIn} onSignIn={onSignIn} onTryAgain={onRetry} />
        ) : (
          <p className="stk-note" aria-busy="true">
            Loading
          </p>
        )}
      </section>
    )
  }
  const counts = generateCounts(store, state, subdept, supplier)
  const working = Boolean(busy)
  const subdepts = state.subdepts || []
  const suppliers = state.suppliers || []
  const openDaily = hasOpen(openCycles, 'DAILY')
  const openConfirm = hasOpen(openCycles, 'CONFIRM')
  const openPlu = hasOpen(openCycles, 'PLU')
  const openBatch = Boolean(subdept) && hasOpen(openCycles, 'ADHOC', subdept)
  const batchReason = subdept ? reasonFor(openBatch, counts.batch <= 0) : 'Pick a sub-department first.'
  const openSupplier = Boolean(supplier) && hasOpen(openCycles, 'SUPPLIER', null, supplier)
  const supplierReason = supplier ? reasonFor(openSupplier, counts.supplier <= 0) : 'Pick a supplier first.'

  return (
    <section className="stk-section" aria-labelledby="stk-generate-title">
      <h2 id="stk-generate-title" className="stk-h2">
        Generate a list
      </h2>
      {restDay ? (
        <p className="stk-note">No forced count on {restReasonDays(restDay.reason)}. A list is still allowed.</p>
      ) : null}
      <p className="stk-note">Lines left in the pool: {groupSentence(state.draw || {})}.</p>
      <div className="stk-genlist">
        <GenerateRow
          label={'Generate daily list (' + linesLabel(counts.daily) + ')'}
          listType="DAILY"
          primary
          subdept={null}
          off={openDaily || counts.daily <= 0}
          reason={reasonFor(openDaily, counts.daily <= 0)}
          working={working}
          isBusy={busy === 'generate:DAILY'}
          onGenerate={onGenerate}
        />
        <GenerateRow
          label={'Generate confirmation count (' + fmtInt(counts.confirm) + ')'}
          listType="CONFIRM"
          subdept={null}
          off={openConfirm || counts.confirm <= 0}
          reason={reasonFor(openConfirm, counts.confirm <= 0)}
          working={working}
          isBusy={busy === 'generate:CONFIRM'}
          onGenerate={onGenerate}
        />
        <GenerateRow
          label={'Generate PLU and scale list (' + linesLabel(counts.plu) + ')'}
          listType="PLU"
          subdept={null}
          off={openPlu || counts.plu <= 0}
          reason={reasonFor(openPlu, counts.plu <= 0)}
          working={working}
          isBusy={busy === 'generate:PLU'}
          onGenerate={onGenerate}
        />
        <GenerateRow
          label={'Generate batch (' + linesLabel(counts.batch) + ')'}
          listType="ADHOC"
          subdept={subdept || null}
          off={!subdept || openBatch || counts.batch <= 0}
          reason={batchReason}
          working={working}
          isBusy={busy === 'generate:ADHOC'}
          onGenerate={onGenerate}
        >
          <label className="stk-field">
            <span className="stk-label">Sub-department</span>
            <select
              className="stk-select"
              value={subdept || ''}
              onChange={(e) => onSubdeptChange && onSubdeptChange(e.target.value)}
              disabled={working || subdepts.length === 0}
            >
              <option value="">{subdepts.length === 0 ? 'None left' : 'Pick one'}</option>
              {subdepts.map((s) => (
                <option key={s.subdept_name} value={s.subdept_name}>
                  {s.subdept_name} ({fmtInt(s.lines)})
                </option>
              ))}
            </select>
          </label>
        </GenerateRow>
        <GenerateRow
          label={'Generate supplier count (' + linesLabel(counts.supplier) + ')'}
          listType="SUPPLIER"
          subdept={null}
          supplier={supplier || null}
          off={!supplier || openSupplier || counts.supplier <= 0}
          reason={supplierReason}
          working={working}
          isBusy={busy === 'generate:SUPPLIER'}
          onGenerate={onGenerate}
        >
          <label className="stk-field">
            <span className="stk-label">Supplier</span>
            <select
              className="stk-select"
              value={supplier || ''}
              onChange={(e) => onSupplierChange && onSupplierChange(e.target.value)}
              disabled={working || suppliers.length === 0}
            >
              <option value="">{suppliers.length === 0 ? 'None left' : 'Pick one'}</option>
              {suppliers.map((s) => (
                <option key={s.supplier_nr} value={String(s.supplier_nr)}>
                  {s.supplier_name} ({fmtInt(s.lines)})
                </option>
              ))}
            </select>
          </label>
        </GenerateRow>
      </div>
    </section>
  )
}
