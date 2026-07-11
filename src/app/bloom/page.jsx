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
  nextDeliveryDate, setNextDeliveryDate, budget, setBudget, basis, setBasis,
  daysCover, setDaysCover, onGenerate, generating, error }) {
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
          {field('Days cover', (
            <SegmentedControl value={daysCover} onChange={setDaysCover}
              options={[{ value: 7, label: '7' }, { value: 10, label: '10' }, { value: 14, label: '14' }]} />
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
// Desk mode — SB-CC-BLOOM-003 Ship 1 (EXPERIMENTAL). Budget gauge (real ledger,
// not manual entry) + SAB-equivalent direct-beer proposals for the 3 TOPS
// stores, via rpc_bloom_order_direct_beer. DC mode above is completely
// untouched (R30) -- this is a parallel, opt-in surface.
// =============================================================================
const TOPS_STORES = [
  { store_code: '21355', store_name: 'TOPS Delareyville' },
  { store_code: '80176', store_name: 'TOPS Roosville' },
  { store_code: '80579', store_name: 'TOPS Dice' },
]

function monthStartIso(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

function DeskRow({ line, qty, isEdited, onQty }) {
  const value = (qty ?? 0) * (Number(line.pack_cost) || 0)
  const wash = line.sibling_gated ? 'linear-gradient(90deg, rgba(0,224,140,0.13), rgba(0,224,140,0.02))' : 'transparent'
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '76px 40px minmax(180px,1.6fr) 100px 56px 90px 90px 100px 90px',
      alignItems: 'center', gap: 0, padding: '9px 18px', background: wash,
      borderBottom: '1px solid var(--hairline)', fontSize: 12, fontFamily: 'var(--font-mono)',
      fontVariantNumeric: 'tabular-nums',
    }} title={line.story}>
      <span style={{ color: 'var(--veld-mist)' }}>{String(line.product_code)}</span>
      <span style={{ color: 'var(--veld-mist)' }}>{line.pack_size ?? '—'}</span>
      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {line.description}
        {line.sibling_gated && (
          <span style={{ marginLeft: 6, fontSize: 9, color: 'var(--growth-green)', border: '1px solid var(--growth-green)',
            borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>DOOR REOPEN</span>
        )}
      </span>
      <span style={{ color: 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.merch_group_name ?? '—'}</span>
      <span style={{ textAlign: 'right', color: Number(line.soh) < 0 ? 'var(--data-neg)' : 'var(--veld-mist)' }}>{num(line.soh)}</span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{num(line.ros_used)}</span>
      <span style={{ textAlign: 'left', paddingLeft: 6, color: 'var(--veld-mist)' }}>{TIER_LABEL[line.tier] ?? line.tier ?? '—'}</span>
      <input type="number" min="0" value={qty ?? 0}
        onChange={e => onQty(line.product_code, Math.max(0, parseInt(e.target.value || '0', 10)))}
        style={{
          width: 64, textAlign: 'right', fontFamily: 'var(--font-mono)', fontSize: 12.5,
          color: 'var(--daisy-white)', padding: '5px 7px', background: 'rgba(0,0,0,0.28)',
          borderRadius: 'var(--radius-chip)', border: '1px solid var(--glass-border)', outline: 'none',
          boxShadow: isEdited ? '0 0 0 2px rgba(255,209,0,0.35)' : 'none', justifySelf: 'end',
        }} />
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{zar(value, 2)}</span>
    </div>
  )
}

function DeskFlags({ flags }) {
  if (!flags.length) return null
  const totalUnits = flags.reduce((s, f) => s + (Number(f.q364) || 0), 0)
  return (
    <GlassCard style={{ margin: '0 32px 20px', padding: '16px 22px' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', flexWrap: 'wrap', gap: 8 }}>
        <span style={{ fontFamily: 'var(--font-display)', fontSize: 15, fontWeight: 'var(--weight-semi)', color: 'var(--core-yellow)' }}>
          Data quality — {flags.length} door{flags.length > 1 ? 's' : ''} the engine cannot order (fix at source, R21)
        </span>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)' }}>{num(totalUnits)} units sold last 12 months, no order proposed</span>
      </div>
      <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 180, overflow: 'auto' }}>
        {flags.map(f => (
          <div key={f.product_code} style={{ display: 'flex', justifyContent: 'space-between', gap: 12,
            fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
            <span style={{ color: 'var(--daisy-white)' }}>{f.description}</span>
            <span style={{ color: 'var(--veld-mist)', textAlign: 'right', flex: '0 0 auto' }}>
              {num(f.q364)} units/12m · {f.reason}
            </span>
          </div>
        ))}
      </div>
    </GlassCard>
  )
}

function DeskMode() {
  const [store, setStore] = useState(TOPS_STORES[1].store_code) // default 80176, the worked example
  const [deliveryDate, setDeliveryDate] = useState(todayIso(3))
  const [nextDeliveryDate, setNextDeliveryDate] = useState(todayIso(10))
  const [budgetRow, setBudgetRow] = useState(null)
  const [lines, setLines] = useState([])
  const [qty, setQty] = useState({})
  const [edited, setEdited] = useState({})
  const [flags, setFlags] = useState([])
  const [generating, setGenerating] = useState(false)
  const [error, setError] = useState(null)
  const [generated, setGenerated] = useState(false)

  useEffect(() => {
    let cancelled = false
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', store).eq('route_key', 'DIRECT_BEER').eq('year_month', monthStartIso())
      .maybeSingle()
      .then(({ data, error: err }) => { if (!cancelled) { setBudgetRow(err ? null : data); } })
    supabase.rpc('rpc_bloom_direct_beer_flags', { p_store_code: store })
      .then(({ data, error: err }) => { if (!cancelled) setFlags(err ? [] : (data ?? [])) })
    setGenerated(false); setLines([]); setQty({}); setEdited({})
    return () => { cancelled = true }
  }, [store])

  async function generate() {
    setError(null); setGenerating(true)
    const { data, error: err } = await supabase.rpc('rpc_bloom_order_direct_beer', {
      p_store_code: store, p_delivery_date: deliveryDate, p_next_delivery: nextDeliveryDate,
    })
    setGenerating(false)
    if (err) { setError(err.message); return }
    const rows = (data ?? []).sort((a, b) => (b.ros_used ?? 0) - (a.ros_used ?? 0))
    const q = {}
    for (const r of rows) q[r.product_code] = r.suggested_packs ?? 0
    setLines(rows); setQty(q); setEdited({}); setGenerated(true)
  }

  function onQty(code, v) {
    setQty(q => ({ ...q, [code]: v }))
    setEdited(e => ({ ...e, [code]: true }))
  }

  const total = useMemo(() => lines.reduce((s, l) => s + (qty[l.product_code] ?? 0) * (Number(l.pack_cost) || 0), 0), [lines, qty])
  const storeInfo = TOPS_STORES.find(s => s.store_code === store)
  const budget = Number(budgetRow?.budget_amount) || 0
  const landed = Number(budgetRow?.landed_amount) || 0
  const salesActual = Number(budgetRow?.sales_actual) || 0
  const spent = landed + total // landed-to-date + this order's committed value

  function exportCsv() {
    const header = 'product_code,description,pack_size,qty_packs,pack_cost,line_value\n'
    const body = lines.filter(l => (qty[l.product_code] ?? 0) > 0).map(l => {
      const q = qty[l.product_code] ?? 0
      const v = q * (Number(l.pack_cost) || 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return `${l.product_code},"${desc}",${l.pack_size ?? ''},${q},${l.pack_cost ?? ''},${v.toFixed(2)}`
    }).join('\n')
    downloadText(`${store}_direct_beer_order_${deliveryDate}.csv`, header + body)
  }

  const inputStyle = {
    fontFamily: 'var(--font-mono)', fontSize: 13, color: 'var(--daisy-white)',
    background: 'rgba(0,0,0,0.28)', border: '1px solid var(--glass-border)',
    borderRadius: 'var(--radius-chip)', padding: '9px 11px', outline: 'none',
  }

  return (
    <div>
      <GlassCard style={{ margin: '20px 32px', padding: '18px 24px' }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 20, alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, alignItems: 'flex-end' }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Store (direct-beer route)</Label>
              <div style={{ display: 'flex', gap: 6 }}>
                {TOPS_STORES.map(s => (
                  <Chip key={s.store_code} active={store === s.store_code} onClick={() => setStore(s.store_code)}>
                    {s.store_code} · {s.store_name}
                  </Chip>
                ))}
              </div>
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Delivery date</Label>
              <input type="date" value={deliveryDate} onChange={e => setDeliveryDate(e.target.value)} style={inputStyle} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Following delivery</Label>
              <input type="date" value={nextDeliveryDate} onChange={e => setNextDeliveryDate(e.target.value)} style={inputStyle} />
            </label>
            <Button variant="daisy" onClick={generate} {...(generating ? { disabled: true } : {})}>
              {generating ? 'Running engine …' : 'Generate beer order'}
            </Button>
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 28, flexWrap: 'wrap' }}>
            <KpiCard label="This order" value={zar(total)} sub={`${lines.filter(l => (qty[l.product_code] ?? 0) > 0).length} lines`} style={{ padding: 0 }} />
            <KpiCard label={`${new Date().toLocaleString('en-ZA', { month: 'long' })} landed`} value={zar(landed)} sub={`sales ${zar(salesActual)}`} style={{ padding: 0 }} />
            <BudgetGauge total={spent} budget={budget} />
          </div>
        </div>
        {error && (
          <div style={{ marginTop: 12, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: '#fca5a5',
            background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.35)', borderRadius: 8, padding: '8px 12px' }}>
            {error}
          </div>
        )}
        {!budgetRow && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)' }}>
            No budget row found for {storeInfo?.store_name} this month — check order_budget_ledger.
          </div>
        )}
      </GlassCard>

      <DeskFlags flags={flags} />

      {generated && (
        <GlassCard style={{ margin: '0 32px 32px', padding: 0, overflow: 'hidden' }}>
          <div style={{ maxHeight: '52vh', overflow: 'auto' }}>
            <div style={{ minWidth: 820 }}>
              <div style={{
                display: 'grid', gridTemplateColumns: '76px 40px minmax(180px,1.6fr) 100px 56px 90px 90px 100px 90px',
                position: 'sticky', top: 0, zIndex: 2, padding: '9px 18px', background: 'rgba(14,18,14,0.96)',
                borderBottom: '1px solid var(--glass-border)',
              }}>
                {['Code', 'Pack', 'Description', 'Merch grp', 'SOH', 'ROS/day', 'Tier', 'Qty · packs', 'Value'].map((c, i) => (
                  <span key={i} style={{ fontFamily: 'var(--font-mono)', fontSize: 9, fontWeight: 500,
                    letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--veld-mist)',
                    textAlign: i >= 4 && i !== 6 ? 'right' : 'left' }}>{c}</span>
                ))}
              </div>
              {lines.map(l => (
                <DeskRow key={l.product_code} line={l} qty={qty[l.product_code]} isEdited={!!edited[l.product_code]} onQty={onQty} />
              ))}
              {lines.length === 0 && (
                <p style={{ padding: 24, textAlign: 'center', fontFamily: 'var(--font-display)', fontStyle: 'italic', color: 'var(--veld-mist)' }}>
                  No lines proposed for this store / delivery window.
                </p>
              )}
            </div>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 14,
            padding: '16px 24px', borderTop: '1px solid var(--glass-border)', flexWrap: 'wrap' }}>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)', flex: '1 1 200px' }}>
              Hover a row for its story (R29) · green ring = door reopen off the sibling rule
            </span>
            <Button variant="solid" onClick={exportCsv}>Export CSV</Button>
          </div>
        </GlassCard>
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Recipe mode — SB-CC-BLOOM-004 (EXPERIMENTAL). The profile-driven recipe:
// life gate -> rhythm-adjusted demand -> stock band -> per-line automatic
// mode (minimum/build) -> KVI floor -> GMROI fill -> Fit-to-Budget -> story
// per row (R29), via rpc_bloom_order_recipe. Budget gauge reads the REAL
// weekly order_budget_ledger (route_key='DC'), never a manual field -- this
// is what distinguishes Recipe mode from the DC baseline's typed budget.
// DC mode above is untouched (R30) -- this is a third, parallel, opt-in
// surface, same pattern as Desk mode.
// =============================================================================
const KVI_LABEL = {
  KVI_CRITICAL: 'KVI Critical', KVI_IMPORTANT: 'KVI Important',
  STANDARD: 'Standard', CONSUMABLE_CARVE: 'Consumable', LONG_TAIL: 'Long tail',
}
const MODE_LABEL = { minimum: 'Minimum', build: 'Build ahead' }
const PRESET_OPTIONS = [
  { value: 'standard', label: 'Standard' },
  { value: 'order_essentials', label: 'Order Essentials' },
  { value: 'catch_up', label: 'Catch-up' },
]
const FIT_REASON_LABEL = {
  protected_kvi: 'Protected · KVI floor', fits: 'Fits budget',
  trimmed_partial: 'Trimmed to fit', trimmed_to_zero: 'Trimmed to zero',
}

function RecipeGenerateForm({ stores, storeCode, setStoreCode, deliveryDate, setDeliveryDate,
  nextDeliveryDate, setNextDeliveryDate, preset, setPreset, fitToBudget, setFitToBudget,
  daysCoverOverride, setDaysCoverOverride, onGenerate, generating, error }) {
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
  const catchUpForced = preset === 'catch_up'
  return (
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 24 }}>
      <GlassCard style={{ width: 'min(480px, 100%)', padding: '30px' }}>
        <div style={{ marginBottom: 22, display: 'flex', flexDirection: 'column' }}>
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 28, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>Bloom</span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, letterSpacing: '0.14em', color: 'var(--growth-green)' }}>
            recipe · life gate · KVI floor · GMROI fill
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
          {field('Preset', (
            <SegmentedControl value={preset} onChange={v => { setPreset(v); if (v === 'catch_up') setFitToBudget(true) }}
              options={PRESET_OPTIONS} />
          ))}
          {field('Fit to budget', (
            <SegmentedControl value={(catchUpForced || fitToBudget) ? 'on' : 'off'}
              onChange={v => { if (!catchUpForced) setFitToBudget(v === 'on') }}
              options={[{ value: 'off', label: 'Off' }, { value: 'on', label: 'On' }]} />
          ))}
          {catchUpForced && (
            <p style={{ margin: 0, fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)' }}>
              Catch-up forces Fit to Budget on — part of the preset's own definition.
            </p>
          )}
          {field('Days-cover override (optional)', (
            <input value={daysCoverOverride} onChange={e => setDaysCoverOverride(e.target.value)} inputMode="numeric"
              placeholder="auto — per-line mode/band" style={inputStyle} />
          ))}
          {error && (
            <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, color: '#fca5a5',
              background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.35)', borderRadius: 8, padding: '8px 12px' }}>
              {error}
            </div>
          )}
          <Button variant="daisy" onClick={onGenerate} style={{ marginTop: 6, width: '100%', textAlign: 'center', padding: '13px', fontSize: 14 }}
            {...(generating ? { disabled: true } : {})}>
            {generating ? 'Running engine …' : 'Generate Recipe order'}
          </Button>
          <p style={{ margin: 0, fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)', textAlign: 'center' }}>
            The engine runs server-side — rpc_bloom_order_recipe
          </p>
        </div>
      </GlassCard>
    </div>
  )
}

function RecipeRow({ line, qty, isEdited, onQty, fitActive }) {
  const code = line.product_code
  const value = (qty ?? 0) * (Number(line.pack_cost) || 0)
  const protectedKvi = line.kvi_band === 'KVI_CRITICAL' || line.kvi_band === 'KVI_IMPORTANT'
  const wash = protectedKvi
    ? 'linear-gradient(90deg, rgba(255,179,0,0.13), rgba(255,179,0,0.02))'
    : line.mode === 'build'
      ? 'linear-gradient(90deg, rgba(149,117,255,0.12), rgba(149,117,255,0.02))'
      : 'transparent'
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '76px 44px minmax(160px,1.6fr) 110px 96px 84px 56px 64px 110px 100px',
      alignItems: 'center', gap: 0, padding: '9px 18px', background: wash,
      borderBottom: '1px solid var(--hairline)', fontSize: 12, fontFamily: 'var(--font-mono)',
      fontVariantNumeric: 'tabular-nums',
    }} title={line.story}>
      <span style={{ color: 'var(--veld-mist)' }}>{String(line.product_code)}</span>
      <span style={{ color: 'var(--veld-mist)' }}>{line.pack_size ?? '—'}</span>
      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {line.description}
        {line.is_bt_hero && (
          <span style={{ marginLeft: 6, fontSize: 9, color: 'var(--growth-green)', border: '1px solid var(--growth-green)',
            borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>BT HERO</span>
        )}
      </span>
      <span style={{ color: 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.dept_name ?? '—'}</span>
      <span style={{ color: protectedKvi ? 'var(--core-yellow)' : 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {KVI_LABEL[line.kvi_band] ?? line.kvi_band ?? '—'}
      </span>
      <span style={{ color: 'var(--veld-mist)' }}>{MODE_LABEL[line.mode] ?? line.mode ?? '—'}</span>
      <span style={{ textAlign: 'right', color: Number(line.soh) < 0 ? 'var(--data-neg)' : 'var(--veld-mist)' }}>
        {line.soh == null ? '—' : Number.isInteger(Number(line.soh)) ? line.soh : num(line.soh)}
      </span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{num(line.need_units)}</span>
      <span style={{ display: 'flex', alignItems: 'center', gap: 6, justifyContent: 'flex-end' }}>
        <input type="number" min="0" value={qty ?? 0}
          onChange={e => onQty(code, Math.max(0, parseInt(e.target.value || '0', 10)))}
          style={{
            width: 56, textAlign: 'right', fontFamily: 'var(--font-mono)', fontSize: 12.5,
            color: 'var(--daisy-white)', padding: '5px 7px', background: 'rgba(0,0,0,0.28)',
            borderRadius: 'var(--radius-chip)', border: '1px solid var(--glass-border)', outline: 'none',
            boxShadow: isEdited ? '0 0 0 2px rgba(255,209,0,0.35)' : 'none',
          }} />
        {fitActive && line.budget_fit_reason && line.budget_fit_reason !== 'fits' && (
          <span title={FIT_REASON_LABEL[line.budget_fit_reason] ?? line.budget_fit_reason}
            style={{ fontSize: 9, color: line.budget_fit_reason === 'protected_kvi' ? 'var(--core-yellow)' : 'var(--data-warn)', cursor: 'help' }}>
            {line.budget_fit_reason === 'protected_kvi' ? '🛡' : '✂'}
          </span>
        )}
      </span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{zar(value, 2)}</span>
    </div>
  )
}

function RecipeOrderForm({ store, deliveryDate, nextDeliveryDate, budgetRow, lines, qty, edited,
  onQty, total, filter, setFilter, fitActive, onExportCsv, onExportTlx, onSubmit }) {
  const orderedCount = lines.filter(l => (l.suggested_packs ?? 0) > 0).length
  const shown = filter === 'ordered' ? lines.filter(l => (l.suggested_packs ?? 0) > 0) : lines
  const cols = ['Code', 'Pack', 'Description', 'Dept', 'KVI', 'Mode', 'SOH', 'Need', 'Qty · packs', 'Value']
  const gridCols = '76px 44px minmax(160px,1.6fr) 110px 96px 84px 56px 64px 110px 100px'
  const budgetTotal = Number(budgetRow?.budget_amount) || 0
  const committed = Number(budgetRow?.committed_amount) || 0
  return (
    <GlassCard style={{ margin: '20px 32px', padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 20, justifyContent: 'space-between',
        alignItems: 'flex-start', padding: '18px 24px', borderBottom: '1px solid var(--glass-border)' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 20, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>
            {store?.store_code} · {store?.store_name}
          </span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)' }}>
            Recipe · deliver {deliveryDate} · next {nextDeliveryDate}
          </span>
        </div>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 28, flexWrap: 'wrap' }}>
          <KpiCard label="Running total" value={zar(total)} sub={`${orderedCount} lines`} style={{ padding: 0 }} />
          <BudgetGauge total={committed + total} budget={budgetTotal} />
        </div>
      </div>
      {!budgetRow && (
        <div style={{ padding: '8px 24px', fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)',
          borderBottom: '1px solid var(--hairline)' }}>
          No weekly DC budget row found for this store — order_budget_ledger.
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 24px', borderBottom: '1px solid var(--hairline)', flexWrap: 'wrap' }}>
        <Label style={{ color: 'var(--veld-mist)' }}>Sorted by value · protected KVI lines never trimmed</Label>
        <div style={{ flex: 1 }} />
        <SegmentedControl size="sm" value={filter} onChange={setFilter}
          options={[{ value: 'ordered', label: `Ordered ${orderedCount}` }, { value: 'all', label: `All ${lines.length}` }]} />
      </div>

      <div style={{ maxHeight: '52vh', overflow: 'auto' }}>
        <div style={{ minWidth: 920 }}>
          <div style={{
            display: 'grid', gridTemplateColumns: gridCols, position: 'sticky', top: 0, zIndex: 2,
            padding: '9px 18px', background: 'rgba(14,18,14,0.96)', borderBottom: '1px solid var(--glass-border)',
          }}>
            {cols.map((c, i) => (
              <span key={i} style={{ fontFamily: 'var(--font-mono)', fontSize: 9, fontWeight: 500,
                letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--veld-mist)',
                textAlign: i >= 6 ? 'right' : 'left' }}>{c}</span>
            ))}
          </div>
          {shown.map(l => (
            <RecipeRow key={l.product_code} line={l} qty={qty[l.product_code]}
              isEdited={!!edited[l.product_code]} onQty={onQty} fitActive={fitActive} />
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
          Hover a row for its story (R29) · edited cells ringed
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

function RecipePreview({ store, deliveryDate, nextDeliveryDate, budgetRow, lines, qty, fitActive, onNewOrder }) {
  const rows = useMemo(() => lines.filter(l => (qty[l.product_code] ?? 0) > 0).map(l => ({
    ...l, value: (qty[l.product_code] ?? 0) * (Number(l.pack_cost) || 0),
  })), [lines, qty])
  const grand = rows.reduce((s, r) => s + r.value, 0)
  const budgetTotal = Number(budgetRow?.budget_amount) || 0
  const committed = Number(budgetRow?.committed_amount) || 0
  const overBudget = budgetTotal > 0 && (committed + grand) > budgetTotal

  const byMode = useMemo(() => {
    const m = {}
    for (const r of rows) { const k = MODE_LABEL[r.mode] ?? r.mode ?? '—'; m[k] = (m[k] ?? 0) + r.value }
    return Object.entries(m).filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1])
  }, [rows])
  const modeMax = Math.max(...byMode.map(([, v]) => v), 1)

  const byKvi = useMemo(() => {
    const m = {}
    for (const r of rows) { const k = KVI_LABEL[r.kvi_band] ?? r.kvi_band ?? '—'; m[k] = (m[k] ?? 0) + r.value }
    return Object.entries(m).sort((a, b) => b[1] - a[1])
  }, [rows])
  const kviMax = Math.max(...byKvi.map(([, v]) => v), 1)

  const protectedCount = rows.filter(r => r.budget_fit_reason === 'protected_kvi').length
  const trimmedCount = rows.filter(r => r.budget_fit_reason === 'trimmed_partial' || r.budget_fit_reason === 'trimmed_to_zero').length

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
          <BudgetGauge total={committed + grand} budget={budgetTotal} />
        </div>
        {fitActive && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)' }}>
            Fit to budget: {protectedCount} KVI-protected · {trimmedCount} trimmed
          </div>
        )}
      </GlassCard>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <GlassCard title="By mode">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {byMode.map(([m, v]) => <Bar key={m} label={m} value={zar(v)} share={(v / modeMax) * 100} sub={pct((v / grand) * 100)} />)}
          </div>
        </GlassCard>
        <GlassCard title="By KVI band">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {byKvi.map(([k, v]) => <Bar key={k} label={k} value={zar(v)} share={(v / kviMax) * 100} sub={pct((v / grand) * 100)} />)}
          </div>
        </GlassCard>
        <GlassCard title="Biggest movers" style={{ gridColumn: '1 / -1' }}>
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

function RecipeMode({ stores }) {
  const [storeCode, setStoreCode] = useState('')
  const [deliveryDate, setDeliveryDate] = useState(todayIso(1))
  const [nextDeliveryDate, setNextDeliveryDate] = useState(todayIso(4))
  const [preset, setPreset] = useState('standard')
  const [fitToBudget, setFitToBudget] = useState(false)
  const [daysCoverOverride, setDaysCoverOverride] = useState('')
  const [phase, setPhase] = useState('A')
  const [generating, setGenerating] = useState(false)
  const [lines, setLines] = useState([])
  const [qty, setQty] = useState({})
  const [edited, setEdited] = useState({})
  const [filter, setFilter] = useState('ordered')
  const [budgetRow, setBudgetRow] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    if (stores?.length && !storeCode) setStoreCode(stores[0].store_code)
  }, [stores, storeCode])

  useEffect(() => {
    if (!storeCode) return
    let cancelled = false
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', storeCode).eq('route_key', 'DC')
      .order('year_month', { ascending: false }).limit(1).maybeSingle()
      .then(({ data, error: err }) => { if (!cancelled) setBudgetRow(err ? null : data) })
    return () => { cancelled = true }
  }, [storeCode])

  const store = stores.find(s => s.store_code === storeCode)
  const fitActive = preset === 'catch_up' ? true : fitToBudget

  async function generate() {
    if (!storeCode || !deliveryDate) { setError('Pick a store and delivery date.'); return }
    setError(null); setGenerating(true)
    const override = daysCoverOverride === '' ? null : Number(daysCoverOverride)
    const PAGE = 1000
    let all = [], offset = 0
    for (;;) {
      const { data, error: err } = await supabase.rpc('rpc_bloom_order_recipe', {
        p_store_code: storeCode, p_delivery_date: deliveryDate,
        p_next_delivery: nextDeliveryDate || null,
        p_preset: preset === 'standard' ? null : preset,
        p_days_cover_override: override,
        p_fit_to_budget: fitActive,
      }).range(offset, offset + PAGE - 1)
      if (err) { setGenerating(false); setError(err.message); return }
      all = all.concat(data ?? [])
      if (!data || data.length < PAGE) break
      offset += PAGE
    }
    setGenerating(false)
    const rows = all.sort((a, b) => (b.value ?? 0) - (a.value ?? 0))
    const q = {}
    for (const r of rows) q[r.product_code] = r.suggested_packs ?? 0
    setLines(rows); setQty(q); setEdited({}); setFilter('ordered'); setPhase('B')
  }

  function onQty(code, v) {
    setQty(q => ({ ...q, [code]: v }))
    setEdited(e => ({ ...e, [code]: true }))
  }

  const total = useMemo(() => lines.reduce((s, l) => s + (qty[l.product_code] ?? 0) * (Number(l.pack_cost) || 0), 0), [lines, qty])

  function exportCsv() {
    const header = 'product_code,description,pack_size,qty_packs,pack_cost,line_value\n'
    const body = lines.filter(l => (qty[l.product_code] ?? 0) > 0).map(l => {
      const q = qty[l.product_code] ?? 0
      const v = q * (Number(l.pack_cost) || 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return `${l.product_code},"${desc}",${l.pack_size ?? ''},${q},${l.pack_cost ?? ''},${v.toFixed(2)}`
    }).join('\n')
    downloadText(`${storeCode}_recipe_order_${deliveryDate}.csv`, header + body)
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

  return (
    <div>
      {phase === 'A' && (
        <RecipeGenerateForm
          stores={stores} storeCode={storeCode} setStoreCode={setStoreCode}
          deliveryDate={deliveryDate} setDeliveryDate={setDeliveryDate}
          nextDeliveryDate={nextDeliveryDate} setNextDeliveryDate={setNextDeliveryDate}
          preset={preset} setPreset={setPreset}
          fitToBudget={fitToBudget} setFitToBudget={setFitToBudget}
          daysCoverOverride={daysCoverOverride} setDaysCoverOverride={setDaysCoverOverride}
          onGenerate={generate} generating={generating} error={error}
        />
      )}
      {phase === 'B' && (
        <RecipeOrderForm
          store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate} budgetRow={budgetRow}
          lines={lines} qty={qty} edited={edited} onQty={onQty} total={total}
          filter={filter} setFilter={setFilter} fitActive={fitActive}
          onExportCsv={exportCsv} onExportTlx={exportTlx}
          onSubmit={() => setPhase('C')}
        />
      )}
      {phase === 'C' && (
        <RecipePreview store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate}
          budgetRow={budgetRow} lines={lines} qty={qty} fitActive={fitActive} onNewOrder={() => setPhase('A')} />
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Order Desks — SB-CC-BLOOM-007 item 8, rebuilt per BUG-LOG UX-003 (Pieter,
// live-site walk 2026-07-11 evening). THE DESK SCREEN IS THE OLD DC ORDER
// SCREEN, PRESERVED -- do not redesign the grid. Carried over verbatim from
// OrderRow/OrderForm above: fastest-ROS->slowest sort, columns CODE/PACK/
// DESCRIPTION/DEPT/SOH/ROS+TIER/PROMO/QTY-PACKS/VALUE, ringed editable qty
// (free to retype), All/Promo count tabs, StockFlow CSV + TLX + Submit.
// Only the brain (recipe RPC per route) and the header controls (desk
// picker, calendar dates under the order cutoff, budget strip with basis,
// Normal/Geared, Fit, focus) are new. ONE landing (this is the only mode in
// the nav now -- DC/Desk-beer/Recipe stay in the file, hidden, R28 lineage,
// not deleted). The three presets (standard/order_essentials/catch_up) are
// THREE DIFFERENT ORDERS -- different line sets, different quantities,
// different export file pairs -- never a re-cut merge into the same order
// (canon v7 item 4, corrected wording 2026-07-11 evening).
// =============================================================================
const STORE_DESKS = {
  '10116': [{ value: 'DC_AMBIENT', label: 'SPAR DC Ambient' }],
  '80175': [{ value: 'DC_AMBIENT', label: 'SPAR DC Ambient' }],
  '21355': [{ value: 'DC_TOPS', label: 'TOPS DC' }, { value: 'DIRECT_BEER', label: 'SAB Direct' }],
  '80176': [{ value: 'DC_TOPS', label: 'TOPS DC' }, { value: 'DIRECT_BEER', label: 'SAB Direct' }],
  '80579': [{ value: 'DC_TOPS', label: 'TOPS DC' }],
}
const DESK_STORES = [
  { store_code: '10116', store_name: 'SPAR Delareyville' },
  { store_code: '80175', store_name: 'SPAR Roosville' },
  { store_code: '21355', store_name: 'TOPS Delareyville' },
  { store_code: '80176', store_name: 'TOPS Roosville' },
  { store_code: '80579', store_name: 'TOPS Dice' },
]
const DESK_PRESET_OPTIONS = [
  { value: 'standard', label: 'Standard' },
  { value: 'order_essentials', label: 'Order Essentials' },
  { value: 'catch_up', label: 'Catch-up' },
]

// The preserved DC row, adapted to the recipe's own fields. Same grid, same
// ten columns, same ringed-input pattern as OrderRow above -- the only
// additions are the count_first (# / pink wash) and BT-hero markers, which
// carry the SAME visual language the DC screen already uses for a selling-
// negative line (BloomPage/README.md's documented "count-first" pattern),
// now extended to any band_blocked claim per ENG-014.
function DeskOrderRow({ line, qty, isEdited, onQty }) {
  const code = line.product_code
  const isPromo = !!line.promo_active
  const value = (qty ?? 0) * (line.pack_cost ?? 0)
  const wash = line.count_first
    ? 'linear-gradient(90deg, rgba(239,83,80,0.14), rgba(239,83,80,0.02))'
    : isPromo
      ? 'linear-gradient(90deg, rgba(255,179,0,0.13), rgba(255,179,0,0.02))'
      : 'transparent'
  const hasGeared = isPromo && line.geared_packs != null && line.geared_packs !== line.normal_packs
  const selected = hasGeared && qty === line.geared_packs ? 'geared' : 'normal'
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px',
      alignItems: 'center', gap: 0, padding: '9px 18px', background: wash,
      borderBottom: '1px solid var(--hairline)', fontSize: 12, fontFamily: 'var(--font-mono)',
      fontVariantNumeric: 'tabular-nums',
    }} title={line.story}>
      <span style={{ color: line.count_first ? 'var(--data-neg)' : 'var(--veld-mist)' }}>
        {line.count_first ? '# ' : ''}{String(line.product_code)}
      </span>
      <span style={{ color: 'var(--veld-mist)' }}>{line.pack_size ?? '—'}</span>
      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {line.description}
        {line.is_bt_hero && (
          <span style={{ marginLeft: 6, fontSize: 9, color: 'var(--growth-green)', border: '1px solid var(--growth-green)',
            borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>BT</span>
        )}
      </span>
      <span style={{ color: 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.dept_name ?? '—'}</span>
      <span style={{ textAlign: 'right', color: line.count_first ? 'var(--data-neg)' : 'var(--veld-mist)' }}
        title={line.count_first ? 'Band-blocked claim — count first (canon ENG-014)' : undefined}>
        {line.soh == null ? '—' : Number.isInteger(line.soh) ? line.soh : num(line.soh)}
      </span>
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>
        {num(line.rhythm_adjusted_demand)}
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

function OrderDesksMode() {
  const [storeCode, setStoreCode] = useState(DESK_STORES[0].store_code)
  const [desk, setDesk] = useState(STORE_DESKS[DESK_STORES[0].store_code][0].value)
  const [deliveryDate, setDeliveryDate] = useState('')
  const [nextDeliveryDate, setNextDeliveryDate] = useState('')
  const [datesLoading, setDatesLoading] = useState(false)
  const [budgetRow, setBudgetRow] = useState(null)
  const [allBudgetRow, setAllBudgetRow] = useState(null)
  const [basis, setBasis] = useState('normal')
  const [fitToBudget, setFitToBudget] = useState(false)
  const [preset, setPreset] = useState('standard')
  const [generating, setGenerating] = useState(false)
  const [lines, setLines] = useState([])
  const [qty, setQty] = useState({})
  const [edited, setEdited] = useState({})
  const [filter, setFilter] = useState('all')
  const [error, setError] = useState(null)
  const [generated, setGenerated] = useState(false)
  const [submitted, setSubmitted] = useState(false)

  const desks = STORE_DESKS[storeCode] || []

  useEffect(() => {
    const first = STORE_DESKS[storeCode]?.[0]?.value
    if (first) setDesk(first)
    setGenerated(false); setLines([]); setQty({}); setEdited({}); setSubmitted(false)
  }, [storeCode])

  // Desk change -> prepopulate dates from the calendar (item 1, cutoff-
  // respecting per ENG-011), fetch this route's budget row plus the
  // group ALL-route row (carries the 80%-cash reference figure).
  useEffect(() => {
    if (!storeCode || !desk) return
    let cancelled = false
    setDatesLoading(true)
    supabase.rpc('rpc_bloom_next_deliveries', { p_store_code: storeCode, p_route: desk })
      .then(({ data, error: err }) => {
        if (cancelled) return
        setDatesLoading(false)
        if (err || !data?.[0]) { setError(err?.message ?? 'no calendar row for this desk'); return }
        setDeliveryDate(data[0].delivery_date); setNextDeliveryDate(data[0].following_date)
      })
    const ledgerRoute = desk === 'DIRECT_BEER' ? 'DIRECT_BEER' : 'DC'
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', storeCode).eq('route_key', ledgerRoute).order('year_month', { ascending: false }).limit(1).maybeSingle()
      .then(({ data }) => { if (!cancelled) setBudgetRow(data ?? null) })
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', storeCode).eq('route_key', 'ALL').order('year_month', { ascending: false }).limit(1).maybeSingle()
      .then(({ data }) => { if (!cancelled) setAllBudgetRow(data ?? null) })
    setGenerated(false); setLines([]); setQty({}); setEdited({}); setSubmitted(false)
    return () => { cancelled = true }
  }, [storeCode, desk])

  async function generate() {
    if (!deliveryDate || !nextDeliveryDate) { setError('Dates not ready yet — wait for the calendar to load.'); return }
    setError(null); setGenerating(true); setSubmitted(false)
    const PAGE = 1000
    let all = [], offset = 0
    for (;;) {
      const { data, error: err } = await supabase.rpc('rpc_bloom_order_recipe', {
        p_store_code: storeCode, p_delivery_date: deliveryDate, p_next_delivery: nextDeliveryDate,
        p_route: desk, p_fit_to_budget: fitToBudget,
        p_preset: preset === 'standard' ? null : preset,
      }).range(offset, offset + PAGE - 1)
      if (err) { setGenerating(false); setError(err.message); return }
      all = all.concat(data ?? [])
      if (!data || data.length < PAGE) break
      offset += PAGE
    }
    setGenerating(false)
    const rows = all.sort((a, b) => (b.rhythm_adjusted_demand ?? 0) - (a.rhythm_adjusted_demand ?? 0))
    const q = {}
    for (const r of rows) q[r.product_code] = lineQty(r, basis)
    setLines(rows); setQty(q); setEdited({}); setFilter('all'); setGenerated(true)
  }

  function onQty(code, v) {
    setQty(q => ({ ...q, [code]: v }))
    setEdited(e => ({ ...e, [code]: true }))
  }

  const total = useMemo(() => lines.reduce((s, l) => s + (qty[l.product_code] ?? 0) * (Number(l.pack_cost) || 0), 0), [lines, qty])
  const budgetTotal = Number(budgetRow?.budget_amount) || 0
  const committed = Number(budgetRow?.committed_amount) || 0
  const cash80Group = Number(allBudgetRow?.budget_80pct_cash) || 0
  const cashConstrained = !!budgetRow?.cash_constrained
  const promoCount = lines.filter(l => l.promo_active).length
  const shown = filter === 'all' ? lines : lines.filter(l => l.promo_active)
  const cols = ['Code', 'Pack', 'Description', 'Dept', 'SOH', 'ROS/day', 'Tier', 'Promo', 'Qty · packs', 'Value']
  const gridCols = '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px'
  const beforeFitTotal = useMemo(() => lines.reduce((s, l) => s + (Number(l.packs_before_fit) || 0) * (Number(l.pack_cost) || 0), 0), [lines])
  const trimmedCount = lines.filter(l => l.budget_fit_reason === 'trimmed_partial' || l.budget_fit_reason === 'trimmed_to_zero').length
  const protectedCount = lines.filter(l => l.budget_fit_reason === 'protected_kvi').length

  // UX-003: each order exports its OWN regular + geared/promo file pair --
  // never one blended file. Regular = every ordered line at its resolved
  // qty; the promo/geared companion = the promo subset only, at its geared
  // figure, so the buy-in decision is a document on its own (matches the
  // Bloom brief's own "promo Excel accompanies either export route").
  function exportCsv() {
    const header = 'product_code,description,pack_size,qty_packs,pack_cost,line_value\n'
    const body = lines.filter(l => (qty[l.product_code] ?? 0) > 0).map(l => {
      const q = qty[l.product_code] ?? 0
      const v = q * (Number(l.pack_cost) || 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return `${l.product_code},"${desc}",${l.pack_size ?? ''},${q},${l.pack_cost ?? ''},${v.toFixed(2)}`
    }).join('\n')
    downloadText(`${storeCode}_${desk}_${preset}_${deliveryDate}_regular.csv`, header + body)
  }

  function exportPromoCsv() {
    const header = 'product_code,description,pack_size,geared_packs,pack_cost,line_value,promo_start,promo_end\n'
    const body = lines.filter(l => l.promo_active && (l.geared_packs ?? 0) > 0).map(l => {
      const q = l.geared_packs ?? 0
      const v = q * (Number(l.pack_cost) || 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return `${l.product_code},"${desc}",${l.pack_size ?? ''},${q},${l.pack_cost ?? ''},${v.toFixed(2)},${l.promo_start ?? ''},${l.promo_end ?? ''}`
    }).join('\n')
    downloadText(`${storeCode}_${desk}_${preset}_${deliveryDate}_promo_geared.csv`, header + body)
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

  const inputStyle = {
    fontFamily: 'var(--font-mono)', fontSize: 13, color: 'var(--daisy-white)',
    background: 'rgba(0,0,0,0.28)', border: '1px solid var(--glass-border)',
    borderRadius: 'var(--radius-chip)', padding: '9px 11px', outline: 'none',
  }

  return (
    <div>
      <GlassCard style={{ margin: '20px 32px', padding: '18px 24px' }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, alignItems: 'flex-end', marginBottom: 14 }}>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <Label>Store</Label>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {DESK_STORES.map(s => (
                <Chip key={s.store_code} active={storeCode === s.store_code} onClick={() => setStoreCode(s.store_code)}>
                  {s.store_code} · {s.store_name}
                </Chip>
              ))}
            </div>
          </label>
        </div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, alignItems: 'flex-end' }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Desk</Label>
              <SegmentedControl value={desk} onChange={setDesk} options={desks} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Delivery date (cutoff-respecting)</Label>
              <input type="date" value={deliveryDate} onChange={e => setDeliveryDate(e.target.value)}
                style={inputStyle} disabled={datesLoading} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Following delivery</Label>
              <input type="date" value={nextDeliveryDate} onChange={e => setNextDeliveryDate(e.target.value)}
                style={inputStyle} disabled={datesLoading} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Preset</Label>
              <SegmentedControl size="sm" value={preset} onChange={setPreset} options={DESK_PRESET_OPTIONS} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Order basis (promo lines)</Label>
              <SegmentedControl size="sm" value={basis} onChange={setBasis}
                options={[{ value: 'normal', label: 'Normal' }, { value: 'geared', label: 'Geared' }]} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <Label>Fit to budget</Label>
              <SegmentedControl size="sm" value={fitToBudget ? 'on' : 'off'} onChange={v => setFitToBudget(v === 'on')}
                options={[{ value: 'off', label: 'Off' }, { value: 'on', label: 'On' }]} />
            </label>
            <Button variant="daisy" onClick={generate} {...(generating || datesLoading ? { disabled: true } : {})}>
              {generating ? 'Running engine …' : datesLoading ? 'Loading calendar …' : 'Generate order'}
            </Button>
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 24, flexWrap: 'wrap' }}>
            <KpiCard label="Running total" value={zar(total)} sub={`${lines.filter(l => (qty[l.product_code] ?? 0) > 0).length} lines`} style={{ padding: 0 }} />
            <BudgetGauge total={committed + total} budget={budgetTotal} />
          </div>
        </div>
        <div style={{ marginTop: 10, display: 'flex', gap: 18, flexWrap: 'wrap', fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)' }}>
          <span>Basis this week: <strong style={{ color: cashConstrained ? 'var(--core-yellow)' : 'var(--data-pos)' }}>
            {cashConstrained ? '80% CASH-CONSTRAINED (10d essentials)' : '82% FORECAST (21d essentials)'}
          </strong></span>
          <span>Route budget (82%): {zar(budgetTotal)}</span>
          {cash80Group > 0 && <span>Group 80%-cash reference: {zar(cash80Group)}</span>}
          {generated && fitToBudget && (
            <span>Fit: {zar(beforeFitTotal)} → {zar(total)} · {protectedCount} protected · {trimmedCount} trimmed</span>
          )}
        </div>
        {error && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: '#fca5a5',
            background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.35)', borderRadius: 8, padding: '8px 12px' }}>
            {error}
          </div>
        )}
      </GlassCard>

      {generated && (
        <GlassCard style={{ margin: '0 32px 32px', padding: 0, overflow: 'hidden' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 24px', borderBottom: '1px solid var(--hairline)', flexWrap: 'wrap' }}>
            <Label style={{ color: 'var(--veld-mist)' }}>Sorted fastest ROS → slowest · {DESK_PRESET_OPTIONS.find(o => o.value === preset)?.label} order</Label>
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
                <DeskOrderRow key={l.product_code} line={l} qty={qty[l.product_code]}
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
              {submitted ? 'Order locked.' : 'Edited cells ringed · # = count first · hover for story (R29)'}
            </span>
            <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
              <Button variant="solid" onClick={exportCsv}>StockFlow CSV</Button>
              <Button variant="solid" onClick={exportPromoCsv}>Promo/Geared CSV</Button>
              <Button variant="solid" onClick={exportTlx}>TLX</Button>
              <Button variant="daisy" onClick={() => setSubmitted(true)} {...(submitted ? { disabled: true } : {})}>
                {submitted ? 'Submitted' : 'Submit order'}
              </Button>
            </div>
          </div>
        </GlassCard>
      )}
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
  const [daysCover, setDaysCover] = useState(7)
  const [phase, setPhase] = useState('A')
  // UX-003 (2026-07-11): one landing, Desks only. 'dc'/'desk'/'recipe' stay
  // reachable in code (components below untouched, R28 lineage) but are no
  // longer offered in the visible nav -- see the SegmentedControl below.
  const [appMode, setAppMode] = useState('desks')
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
        p_days_cover: daysCover,
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
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 22, fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)' }}>Bloom</span>
          <SegmentedControl size="sm" value={appMode} onChange={setAppMode}
            options={[
              { value: 'desks', label: 'Desks' },
            ]} />
        </div>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, letterSpacing: '0.08em', color: 'var(--veld-mist)', textTransform: 'uppercase' }}>
          orders.socialbrand.africa
        </span>
      </header>

      {appMode === 'desk' && <DeskMode />}
      {appMode === 'recipe' && <RecipeMode stores={stores} />}
      {appMode === 'desks' && <OrderDesksMode />}

      {appMode === 'dc' && phase === 'A' && (
        <GenerateForm
          stores={stores} storeCode={storeCode} setStoreCode={setStoreCode}
          deliveryDate={deliveryDate} setDeliveryDate={setDeliveryDate}
          nextDeliveryDate={nextDeliveryDate} setNextDeliveryDate={setNextDeliveryDate}
          budget={budget} setBudget={setBudget}
          basis={basis} setBasis={setBasis}
          daysCover={daysCover} setDaysCover={setDaysCover}
          onGenerate={generate} generating={generating} error={error}
        />
      )}

      {appMode === 'dc' && phase === 'B' && (
        <OrderForm
          store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate} budget={budget}
          lines={lines} qty={qty} edited={edited}
          onQty={onQty} total={total}
          filter={filter} setFilter={setFilter}
          onExportCsv={exportCsv} onExportTlx={exportTlx}
          onSubmit={() => setPhase('C')}
        />
      )}

      {appMode === 'dc' && phase === 'C' && (
        <Preview store={store} deliveryDate={deliveryDate} nextDeliveryDate={nextDeliveryDate}
          budget={budget} lines={lines} qty={qty} onNewOrder={() => setPhase('A')} />
      )}
    </div>
  )
}
