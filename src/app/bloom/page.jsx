'use client'
// =============================================================================
// Bloom — ordering & replenishment applet (orders.socialbrand.africa)
// SB-CC-BLOOM-001 v0 FUNCTIONAL screen: store + dates + budget -> order table,
// edit, export. Engine computes the order server-side via rpc_bloom_order_dc
// (SET-BASED recipe, ~1.7s, reconciles to reference — HANDOVER-CURRENT 2026-07-06).
// The browser renders and edits only; it never computes a suggested quantity
// (NORTH_STAR three-layer rule, R21).
//
// Styled on CD's actual Pulse Design System components (Chip, Button,
// SegmentedControl, GlassCard, KpiCard — ported to src/components/ds/, see
// that file's header) rather than an approximation of them.
//
// Out of scope for this v0 (tracked debt, not silently dropped — R21 §5):
//   - GP% per line (rpc_bloom_order_dc carries no sell price yet, R23 gap)
//   - Not-on-Sigma well (promo lines with no sigma_articles match)
//   - rpc_bloom_submit persistence (no such RPC exists yet) — Submit locks the
//     on-screen preview only; export is the deliverable action for v0.
//   - Promo buy-in toy, week-strip picker (plain date inputs for v0)
// =============================================================================

import { useState, useEffect, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
import { zar, pct, num } from '@/lib/format'
import { Button, Chip, SegmentedControl, GlassCard, KpiCard } from '@/components/ds'
// dashboard.css is only bundled for the root `/` route (imported inside its
// own page.jsx) -- Next.js app-router CSS imports are per-route-segment, not
// automatically shared. Bloom needs its own import to get the token block.
import '../dashboard.css'

const TIER_LABEL = { TOP_100: 'Top 100', TOP_1000: 'Top 1000', BOR: 'BOR' }

function todayIso(offsetDays = 0) {
  const d = new Date()
  d.setDate(d.getDate() + offsetDays)
  return d.toISOString().slice(0, 10)
}

// Basis is a single global choice made before Generate (State A), not a
// per-row toggle — a per-row N/G select duplicated the qty column and could
// disagree with it (the select's own label showed the OLD suggested_packs
// figure, which the RPC always computes as the geared value for ANY promo
// line regardless of tier, while the row's number field held something
// else). One column, one source of truth: normal_packs/geared_packs read
// directly, never suggested_packs.
function lineQty(line, basis) {
  if (basis === 'geared' && line.promo_active && line.geared_packs != null) return line.geared_packs
  return line.normal_packs ?? 0
}

function downloadText(filename, text) {
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared bits (Bloom-specific — not part of the general DS component set)
// ─────────────────────────────────────────────────────────────────────────────
function Label({ children, style }) {
  return (
    <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9.5, letterSpacing: 'var(--label-tracking)',
      textTransform: 'uppercase', color: 'var(--veld-mist)', ...style }}>{children}</span>
  )
}

function BudgetGauge({ total, budget }) {
  const b = Number(budget) || 0
  const ratio = b > 0 ? total / b : 0
  const over = b > 0 && total > b
  const near = !over && ratio >= 0.9
  const fillPct = Math.min(100, ratio * 100)
  const fill = over ? 'var(--core-yellow)' : near ? 'var(--data-warn)' : 'var(--data-pos)'
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 220 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between' }}>
        <Label>Budget</Label>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: over ? 'var(--core-yellow)' : 'var(--daisy-white)' }}>
          {zar(total)} {b > 0 ? `/ ${zar(b)}` : ''}
        </span>
      </div>
      <div style={{ height: 8, borderRadius: 'var(--radius-pill)', background: 'rgba(0,0,0,0.35)', boxShadow: 'var(--well-shadow)', overflow: 'hidden' }}>
        <span style={{ display: 'block', height: '100%', width: fillPct + '%', borderRadius: 'var(--radius-pill)', background: fill, transition: 'width 300ms ease' }} />
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// State A — the generate form
// ─────────────────────────────────────────────────────────────────────────────
function GenerateForm({ stores, storeCode, setStoreCode, deliveryDate, setDeliveryDate,
  nextDeliveryDate, setNextDeliveryDate, budget, setBudget, basis, setBasis, onGenerate, generating, error }) {
  const inputStyle = {
    fontFamily: 'var(--font-mono)', fontSize: 14, color: 'var(--daisy-white)',
    background: 'rgba(0,0,0,0.28)', border: '1px solid var(--glass-border)',
    borderRadius: 'var(--radius-chip)', padding: '11px 13px', outline: 'none', width: '100%',
  }
  const field = (label, node) => (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
      <Label>{label}</Label>{node}
    </label>
  )
  return (
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 24 }}>
      <GlassCard style={{ width: 'min(460px, 100%)', padding: '30px' }}>
        <div style={{ marginBottom: 22, display: 'flex', flexDirection: 'column' }}>
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 28, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>Bloom</span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, letterSpacing: '0.14em', color: 'var(--growth-green)' }}>
            ordering &amp; replenishment
          </span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {field('Store', (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
              {stores.map(s => (
                <Chip key={s.store_code} active={storeCode === s.store_code} onClick={() => setStoreCode(s.store_code)}>
                  {s.store_code} · {s.store_name}
                </Chip>
              ))}
            </div>
          ))}
          {field('Delivery date', (
            <input type="date" value={deliveryDate} onChange={e => setDeliveryDate(e.target.value)} style={inputStyle} />
          ))}
          {field('Following delivery', (
            <input type="date" value={nextDeliveryDate} onChange={e => setNextDeliveryDate(e.target.value)} style={inputStyle} />
          ))}
          {field('Budget (R, manual)', (
            <div style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
              <span style={{ position: 'absolute', left: 13, fontFamily: 'var(--font-mono)', fontSize: 14, color: 'var(--veld-mist)' }}>R</span>
              <input value={budget} onChange={e => setBudget(e.target.value)} inputMode="numeric"
                style={{ ...inputStyle, paddingLeft: 30 }} />
            </div>
          ))}
          {field('Order basis (promo lines)', (
            <SegmentedControl value={basis} onChange={setBasis}
              options={[{ value: 'normal', label: 'Normal' }, { value: 'geared', label: 'Geared (buy-in)' }]} />
          ))}
          {error && (
            <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, color: '#fca5a5',
              background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.35)', borderRadius: 8, padding: '8px 12px' }}>
              {error}
            </div>
          )}
          <Button variant="daisy" onClick={onGenerate} style={{ marginTop: 6, width: '100%', textAlign: 'center', padding: '13px', fontSize: 14 }}
            {...(generating ? { disabled: true } : {})}>
            {generating ? 'Running engine …' : 'Generate DC Groceries / Perishables Order'}
          </Button>
          <p style={{ margin: 0, fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)', textAlign: 'center' }}>
            The engine runs server-side — rpc_bloom_order_dc
          </p>
        </div>
      </GlassCard>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// State B — the order form
// ─────────────────────────────────────────────────────────────────────────────
function OrderRow({ line, qty, isEdited, onQty }) {
  const code = line.product_code
  const isPromo = !!line.promo_active
  const value = (qty ?? 0) * (line.pack_cost ?? 0)
  const wash = line.promo_active ? 'linear-gradient(90deg, rgba(255,179,0,0.13), rgba(255,179,0,0.02))' : 'transparent'
  // The per-line default is set once at Generate time (the "Order basis" toggle
  // applies to every promo line), but the buyer can still flip any ONE line to
  // its other suggestion here. The select has no state of its own -- its
  // selected option is DERIVED from the current qty, so it can never disagree
  // with the number field the way the old per-row mode tracking did.
  const hasGeared = isPromo && line.geared_packs != null && line.geared_packs !== line.normal_packs
  const selected = hasGeared && qty === line.geared_packs ? 'geared' : 'normal'
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px',
      alignItems: 'center', gap: 0, padding: '9px 18px', background: wash,
      borderBottom: '1px solid var(--hairline)', fontSize: 12, fontFamily: 'var(--font-mono)',
      fontVariantNumeric: 'tabular-nums',
    }}>
      <span style={{ color: 'var(--veld-mist)' }}>{String(line.product_code)}</span>
      <span style={{ color: 'var(--veld-mist)' }}>{line.pack_size ?? '—'}</span>
      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.description}</span>
      <span style={{ color: 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.dept_name ?? '—'}</span>
      <span style={{ textAlign: 'right', color: line.soh < 0 ? 'var(--data-neg)' : 'var(--veld-mist)' }}>
        {line.soh == null ? '—' : Number.isInteger(line.soh) ? line.soh : num(line.soh)}
      </span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>
        {num(line.ros_used)}
        {line.ros_correction_delta != null && Math.abs(line.ros_correction_delta) > 0.001 && (
          <sup title={`OOS-corrected delta ${num(line.ros_correction_delta)} (${pct(line.ros_correction_delta_pct)}) — window ${line.ros_window_used}`}
            style={{ color: 'var(--core-yellow)', cursor: 'help', fontSize: 9, marginLeft: 2 }}>△</sup>
        )}
      </span>
      <span style={{ textAlign: 'left', paddingLeft: 6, color: 'var(--veld-mist)' }}>{TIER_LABEL[line.tier] ?? line.tier ?? '—'}</span>
      <span style={{ textAlign: 'left', color: isPromo ? 'var(--data-warn)' : 'var(--veld-mist)' }}>
        {isPromo ? 'Promo' : '—'}
      </span>
      <span style={{ display: 'flex', alignItems: 'center', gap: 6, justifyContent: 'flex-end' }}>
        <input type="number" min="0" value={qty ?? 0}
          onChange={e => onQty(code, Math.max(0, parseInt(e.target.value || '0', 10)))}
          style={{
            width: 56, textAlign: 'right', fontFamily: 'var(--font-mono)', fontSize: 12.5,
            color: 'var(--daisy-white)', padding: '5px 7px', background: 'rgba(0,0,0,0.28)',
            borderRadius: 'var(--radius-chip)', border: '1px solid var(--glass-border)', outline: 'none',
            boxShadow: isEdited ? '0 0 0 2px rgba(255,209,0,0.35)' : 'none',
          }} />
        {hasGeared && (
          <select value={selected}
            onChange={e => onQty(code, e.target.value === 'geared' ? line.geared_packs : line.normal_packs)}
            style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)',
              background: 'rgba(0,0,0,0.28)', border: '1px solid var(--glass-border)', borderRadius: 'var(--radius-chip)', padding: '5px 4px' }}>
            <option value="normal">N {line.normal_packs}</option>
            <option value="geared">G {line.geared_packs}</option>
          </select>
        )}
      </span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{zar(value, 2)}</span>
    </div>
  )
}

function OrderForm({ store, deliveryDate, nextDeliveryDate, budget, lines, qty, edited,
  onQty, total, filter, setFilter, onExportCsv, onExportTlx, onSubmit }) {
  const shown = filter === 'all' ? lines : lines.filter(l => l.promo_active)
  const promoCount = lines.filter(l => l.promo_active).length
  const cols = ['Code', 'Pack', 'Description', 'Dept', 'SOH', 'ROS/day', 'Tier', 'Promo', 'Qty · packs', 'Value']
  const gridCols = '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px'
  return (
    <GlassCard style={{ margin: '20px 32px', padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 20, justifyContent: 'space-between',
        alignItems: 'flex-start', padding: '18px 24px', borderBottom: '1px solid var(--glass-border)' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 20, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>
            {store?.store_code} · {store?.store_name}
          </span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)' }}>
            DC Groceries · deliver {deliveryDate} · next {nextDeliveryDate}
          </span>
        </div>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 28, flexWrap: 'wrap' }}>
          <KpiCard label="Running total" value={zar(total)} sub={`${lines.length} lines`} style={{ padding: 0 }} />
          <BudgetGauge total={total} budget={budget} />
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 24px', borderBottom: '1px solid var(--hairline)', flexWrap: 'wrap' }}>
        <Label style={{ color: 'var(--veld-mist)' }}>Sorted fastest ROS → slowest</Label>
        <div style={{ flex: 1 }} />
        <SegmentedControl size="sm" value={filter} onChange={setFilter}
          options={[{ value: 'all', label: `All ${lines.length}` }, { value: 'promo', label: `Promo ${promoCount}` }]} />
      </div>

      <div style={{ maxHeight: '52vh', overflow: 'auto' }}>
        <div style={{ minWidth: 900 }}>
          <div style={{
            display: 'grid', gridTemplateColumns: gridCols, position: 'sticky', top: 0, zIndex: 2,
            padding: '9px 18px', background: 'rgba(14,18,14,0.96)', borderBottom: '1px solid var(--glass-border)',
          }}>
            {cols.map((c, i) => (
              <span key={i} style={{ fontFamily: 'var(--font-mono)', fontSize: 9, fontWeight: 500,
                letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--veld-mist)',
                textAlign: i >= 4 && i !== 6 && i !== 7 ? 'right' : 'left' }}>{c}</span>
            ))}
          </div>
          {shown.map(l => (
            <OrderRow key={l.product_code} line={l} qty={qty[l.product_code]}
              isEdited={!!edited[l.product_code]} onQty={onQty} />
          ))}
          {shown.length === 0 && (
            <p style={{ padding: 24, textAlign: 'center', fontFamily: 'var(--font-display)', fontStyle: 'italic', color: 'var(--veld-mist)' }}>
              No lines in this filter.
            </p>
          )}
        </div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 14,
        padding: '16px 24px', borderTop: '1px solid var(--glass-border)', flexWrap: 'wrap' }}>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)', flex: '1 1 200px' }}>
          Edited cells ringed · quantities free to retype
        </span>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          <Button variant="solid" onClick={onExportCsv}>StockFlow CSV</Button>
          <Button variant="solid" onClick={onExportTlx}>TLX</Button>
          <Button variant="daisy" onClick={onSubmit}>Submit order</Button>
        </div>
      </div>
    </GlassCard>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// State C — preview
// ─────────────────────────────────────────────────────────────────────────────
function Bar({ label, value, share, sub }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5 }}>
        <span style={{ color: 'var(--daisy-white)' }}>{label}</span>
        <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--veld-mist)' }}>{value}{sub ? ` · ${sub}` : ''}</span>
      </div>
      <div style={{ height: 8, borderRadius: 'var(--radius-pill)', background: 'rgba(0,0,0,0.35)', overflow: 'hidden' }}>
        <span style={{ display: 'block', height: '100%', width: `${share}%`, borderRadius: 'var(--radius-pill)', background: 'var(--growth-green)' }} />
      </div>
    </div>
  )
}

function Preview({ store, deliveryDate, nextDeliveryDate, budget, lines, qty, onNewOrder }) {
  const rows = useMemo(() => lines.map(l => ({
    ...l, value: (qty[l.product_code] ?? 0) * (l.pack_cost ?? 0),
  })), [lines, qty])
  const grand = rows.reduce((s, r) => s + r.value, 0)
  const overBudget = Number(budget) > 0 && grand > Number(budget)

  const byTier = useMemo(() => {
    const m = {}
    for (const r of rows) { const k = r.tier ?? 'BOR'; m[k] = (m[k] ?? 0) + r.value }
    return Object.entries(m).filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1])
  }, [rows])
  const tierMax = Math.max(...byTier.map(([, v]) => v), 1)

  const byDept = useMemo(() => {
    const m = {}
    for (const r of rows) { const k = r.dept_name ?? 'Unmapped'; m[k] = (m[k] ?? 0) + r.value }
    return Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 8)
  }, [rows])
  const deptMax = Math.max(...byDept.map(([, v]) => v), 1)

  const promoRows = rows.filter(r => r.promo_active)
  const promoValue = promoRows.reduce((s, r) => s + r.value, 0)

  const movers = [...rows].sort((a, b) => b.value - a.value).slice(0, 8)
  const moverMax = movers[0]?.value || 1

  return (
    <div style={{ margin: '20px 32px', display: 'flex', flexDirection: 'column', gap: 14 }}>
      <GlassCard style={{ padding: '22px 26px' }}>
        <span style={{ fontFamily: 'var(--font-display)', fontSize: 19, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>
          Order locked · {store?.store_code} {store?.store_name}
        </span>
        <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)', marginTop: 4 }}>
          deliver {deliveryDate} · next {nextDeliveryDate}
        </div>
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 28, flexWrap: 'wrap', marginTop: 14 }}>
          <KpiCard label="Order value" value={zar(grand)} sub={`${rows.length} lines`}
            tone={overBudget ? 'warn' : 'default'} style={{ padding: 0 }} />
          <BudgetGauge total={grand} budget={budget} />
        </div>
      </GlassCard>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <GlassCard title="By tier">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {byTier.map(([t, v]) => <Bar key={t} label={TIER_LABEL[t] ?? t} value={zar(v)} share={(v / tierMax) * 100} sub={pct((v / grand) * 100)} />)}
          </div>
        </GlassCard>
        <GlassCard title="By department">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {byDept.map(([d, v]) => <Bar key={d} label={d} value={zar(v)} share={(v / deptMax) * 100} sub={pct((v / grand) * 100)} />)}
          </div>
        </GlassCard>
        <GlassCard title="Promo take-in">
          <div style={{ fontFamily: 'var(--font-display)', fontWeight: 'var(--weight-bold)', fontSize: 26, color: 'var(--daisy-white)' }}>{zar(promoValue)}</div>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)' }}>{promoRows.length} promo lines</span>
        </GlassCard>
        <GlassCard title="Biggest movers">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {movers.map(m => <Bar key={m.product_code} label={m.description} value={zar(m.value)} share={(m.value / moverMax) * 100} />)}
          </div>
        </GlassCard>
      </div>

      <GlassCard style={{ padding: '16px 22px', display: 'flex', justifyContent: 'flex-end' }}>
        <Button variant="solid" onClick={onNewOrder}>New order</Button>
      </GlassCard>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// App shell
// ─────────────────────────────────────────────────────────────────────────────
export default function BloomPage() {
  const [stores, setStores] = useState([])
  const [storeCode, setStoreCode] = useState('')
  const [deliveryDate, setDeliveryDate] = useState(todayIso(1))
  const [nextDeliveryDate, setNextDeliveryDate] = useState(todayIso(4))
  const [budget, setBudget] = useState('')
  const [basis, setBasis] = useState('normal')
  const [phase, setPhase] = useState('A')
  const [generating, setGenerating] = useState(false)
  const [lines, setLines] = useState([])
  const [qty, setQty] = useState({})
  const [edited, setEdited] = useState({})
  const [filter, setFilter] = useState('all')
  const [error, setError] = useState(null)

  useEffect(() => {
    let cancelled = false
    supabase.from('stores').select('store_code,store_name').eq('is_active', true).order('store_code')
      .then(({ data, error: err }) => {
        if (cancelled) return
        if (err) { setError(err.message); return }
        setStores(data ?? [])
        if (data?.length && !storeCode) setStoreCode(data[0].store_code)
      })
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const store = stores.find(s => s.store_code === storeCode)

  async function generate() {
    if (!storeCode || !deliveryDate || !nextDeliveryDate) {
      setError('Pick a store and both delivery dates.')
      return
    }
    setError(null)
    setGenerating(true)
    // The project's PostgREST max_rows caps a single response at 1000 regardless of
    // .range() — the DC pool runs ~4,300+ candidates (DB-SCHEMA/canon §0f), so page
    // through in 1000-row batches until a short page proves we've reached the end.
    // Silently trusting one page here would drop lines with no sign on screen (R22).
    const PAGE = 1000
    let all = [], offset = 0
    for (;;) {
      const { data, error: err } = await supabase.rpc('rpc_bloom_order_dc', {
        p_store_code: storeCode, p_delivery_date: deliveryDate, p_next_delivery: nextDeliveryDate,
      }).range(offset, offset + PAGE - 1)
      if (err) { setGenerating(false); setError(err.message); return }
      all = all.concat(data ?? [])
      if (!data || data.length < PAGE) break
      offset += PAGE
    }
    setGenerating(false)
    const rows = all.sort((a, b) => (b.ros_used ?? 0) - (a.ros_used ?? 0))
    const q = {}
    for (const r of rows) q[r.product_code] = lineQty(r, basis)
    setLines(rows)
    setQty(q)
    setEdited({})
    setFilter('all')
    setPhase('B')
  }

  function onQty(code, v) {
    setQty(q => ({ ...q, [code]: v }))
    setEdited(e => ({ ...e, [code]: true }))
  }

  const total = useMemo(() => lines.reduce((s, l) => s + (qty[l.product_code] ?? 0) * (l.pack_cost ?? 0), 0), [lines, qty])

  function exportCsv() {
    const header = 'product_code,description,pack_size,qty_packs,pack_cost,line_value\n'
    const body = lines.filter(l => (qty[l.product_code] ?? 0) > 0).map(l => {
      const q = qty[l.product_code] ?? 0
      const v = q * (l.pack_cost ?? 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return `${l.product_code},"${desc}",${l.pack_size ?? ''},${q},${l.pack_cost ?? ''},${v.toFixed(2)}`
    }).join('\n')
    downloadText(`${storeCode}_bloom_order_${deliveryDate}.csv`, header + body)
  }

  function exportTlx() {
    const parts = []
    for (const l of lines) {
      const q = qty[l.product_code] ?? 0
      if (q <= 0 || !l.ean) continue
      const units = q * (l.pack_size ?? 1)
      parts.push(`${l.ean}+${units}`)
    }
    downloadText(`${storeCode}.tlx`, `${storeCode}++${parts.join('+')}`)
  }

  const backdrop = { minHeight: '100vh', background: 'var(--backdrop)' }

  return (
    <div style={backdrop}>
      <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '18px 32px', flexWrap: 'wrap', gap: 12 }}>
        <span style={{ fontFamily: 'var(--font-display)', fontSize: 22, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>Bloom</span>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, letterSpacing: '0.08em', color: 'var(--veld-mist)', textTransform: 'uppercase' }}>
          orders.socialbrand.africa
        </span>
      </header>

      {phase === 'A' && (
        <GenerateForm
          stores={stores} storeCode={storeCode} setStoreCode={setStoreCode}
          deliveryDate={deliveryDate} setDeliveryDate={setDeliveryDate}
          nextDeliveryDate={nextDeliveryDate} setNextDeliveryDate={setNextDeliveryDate}
          budget={budget} setBudget={setBudget}
          basis={basis} setBasis={setBasis}
          onGenerate={generate} generating={generating} error={error}
        />
      )}

      {phase === 'B' && (
        <OrderForm
          store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate} budget={budget}
          lines={lines} qty={qty} edited={edited}
          onQty={onQty} total={total}
          filter={filter} setFilter={setFilter}
          onExportCsv={exportCsv} onExportTlx={exportTlx}
          onSubmit={() => setPhase('C')}
        />
      )}

      {phase === 'C' && (
        <Preview store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate}
          budget={budget} lines={lines} qty={qty} onNewOrder={() => setPhase('A')} />
      )}
    </div>
  )
}
