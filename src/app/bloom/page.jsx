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

import { useState, useEffect, useMemo, useRef } from 'react'
import * as XLSX from 'xlsx'
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

// KVI / core / tail pie -- scenario-board request (Pieter, mid-session
// amendment): each scenario's ORDERED-LINE mix at a glance. Grouped from
// the recipe's own kvi_band, by LINE COUNT (never rand value -- "percentage
// of lines ordered"): KVI = KVI_CRITICAL + KVI_IMPORTANT, core = STANDARD +
// CONSUMABLE_CARVE, tail = LONG_TAIL. Groups with zero lines are dropped
// from both the ring and the legend ("if those are the only ones") rather
// than drawn as an empty slice. Hand-rolled SVG, no new chart dependency.
const PIE_GROUPS = [
  { key: 'kvi', label: 'KVI', color: 'var(--core-yellow)', bands: ['KVI_CRITICAL', 'KVI_IMPORTANT'] },
  { key: 'core', label: 'Core', color: 'var(--data-pos)', bands: ['STANDARD', 'CONSUMABLE_CARVE'] },
  { key: 'tail', label: 'Tail', color: 'var(--veld-mist)', bands: ['LONG_TAIL'] },
]
function kviCoreTailSplit(byKviBandLines) {
  const src = byKviBandLines ?? {}
  return PIE_GROUPS.map(g => ({
    ...g, count: g.bands.reduce((s, b) => s + (Number(src[b]) || 0), 0),
  })).filter(g => g.count > 0)
}
function KviPie({ byKviBandLines, size = 46 }) {
  const groups = kviCoreTailSplit(byKviBandLines)
  const total = groups.reduce((s, g) => s + g.count, 0)
  if (total === 0) return null
  const r = size / 2
  let angle = -90
  const slices = groups.map(g => {
    const frac = g.count / total
    const start = angle
    angle += frac * 360
    const end = angle
    const large = (end - start) > 180 ? 1 : 0
    const toXY = a => [r + r * Math.cos(a * Math.PI / 180), r + r * Math.sin(a * Math.PI / 180)]
    const [x1, y1] = toXY(start)
    const [x2, y2] = toXY(end)
    const path = groups.length === 1
      ? null // single group = full circle, drawn separately below
      : `M ${r},${r} L ${x1},${y1} A ${r},${r} 0 ${large} 1 ${x2},${y2} Z`
    return { ...g, path, pct: Math.round(frac * 100) }
  })
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ flexShrink: 0 }}>
        {slices.length === 1
          ? <circle cx={r} cy={r} r={r} fill={slices[0].color} />
          : slices.map(s => <path key={s.key} d={s.path} fill={s.color} stroke="var(--backdrop)" strokeWidth={0.5} />)}
      </svg>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        {slices.map(s => (
          <span key={s.key} style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--veld-mist)', display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ width: 6, height: 6, borderRadius: 2, background: s.color, display: 'inline-block' }} />
            {s.label} {s.pct}% ({s.count})
          </span>
        ))}
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

  // ENG-031: same engine verdict as the desk exporter (rpc_bloom_export_eligibility).
  // This screen has no report strip, so held-back lines are announced loudly rather
  // than dropped quietly -- the whole point of the fix (R22, no silent drops).
  async function exportTlx() {
    const wanted = lines.filter(l => (qty[l.product_code] ?? 0) > 0)
    const { data, error: eligErr } = await supabase.rpc('rpc_bloom_export_eligibility', {
      p_store_code: storeCode, p_product_codes: wanted.map(l => Number(l.product_code)),
    })
    if (eligErr) { window.alert(`Export blocked -- could not read export eligibility: ${eligErr.message}`); return }
    const elig = new Map((data ?? []).map(r => [Number(r.product_code), r]))
    const parts = []
    const excluded = []
    for (const l of wanted) {
      const q = qty[l.product_code] ?? 0
      const e = elig.get(Number(l.product_code))
      if (!e || !e.export_eligible) { excluded.push(`${l.product_code} ${l.description ?? ''} (${e?.ineligible_reason ?? 'no engine identity row'})`); continue }
      const units = q * (l.pack_size ?? 1)
      parts.push(`${e.export_key}+${units}`)
    }
    if (excluded.length) {
      window.alert(`TLX: ${parts.length} lines written, ${excluded.length} held back -- Sigma cannot match the key.\nOrder these by hand or fix the barcode at source:\n\n${excluded.join('\n')}`)
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
  // SB-CC-BLOOM-009: direct desks beside the DC, ordered by weekly rand per the
  // brief's own priority (item 6). Wave 1 = Coca-Cola. Wave 2 = Clover, Simba,
  // Danone -- config-only, the recipe/stock-state/overview RPCs already
  // generalise on the DIRECT_<brand> route pattern.
  // Wave 3 (2026-07-17) = National Brands at 10116 ONLY. Canon 7f rounds cadence
  // to the nearest whole cycle with ties resolving weekly: its median drop gap is
  // 10.5 over 16 observations = exactly 1.50 cycles = the tie = WEEKLY, so it
  // needs no fortnightly grain. Stable at every noise floor, delivery day Tue 76%.
  //
  // Mondelez is STILL NOT listed, and the reason has changed -- it is no longer
  // "fortnightly, waiting on the grain". Its cadence flips on the lines-per-day
  // noise floor that no canon item states (>=1 -> median 9 -> weekly; >=3, which
  // SB-CC-BLOOM-009 rule 2 mandates -> median 12 -> fortnightly), and it has no
  // dominant delivery day at all (Wed 38% / Thu 38%, tied and adjacent -- the
  // wave-1 bug that collapses the lead to 1). Held for a PM ruling on the floor,
  // never seeded at a coin-toss (canon v9 item 8, the accuracy gate).
  // ENG-025 (2026-07-18): the 7e grain landed (supplier_calendar.cycle_weeks +
  // cycle_anchor_week_start), so fortnightly desks are now supported. National
  // Brands 80175 (supplier 47, gap 14) and Coca-Cola 21355 (316, gap 13) are
  // SEEDED cycle_weeks=2, DC-overlap guard clean, awaiting Pieter's R31 walk.
  // Mondelez x2 stays HELD: it is Super Group distributor-delivered (its link
  // account carries no receipts), a multi-brand scoping question for PM -- never
  // name-guessed (canon 7d, R21/R22).
  '10116': [
    { value: 'DC_AMBIENT', label: 'SPAR DC Ambient' },
    { value: 'DIRECT_COCACOLA', label: 'Coca-Cola Direct' },
    { value: 'DIRECT_CLOVER', label: 'Clover Direct' },
    { value: 'DIRECT_SIMBA', label: 'Simba Direct' },
    { value: 'DIRECT_DANONE', label: 'Danone Direct' },
    { value: 'DIRECT_NATBRANDS', label: 'National Brands Direct' },
    { value: 'DIRECT_MONDELEZ', label: 'Mondelez Direct' },
  ],
  '80175': [
    { value: 'DC_AMBIENT', label: 'SPAR DC Ambient' },
    { value: 'DIRECT_COCACOLA', label: 'Coca-Cola Direct' },
    { value: 'DIRECT_CLOVER', label: 'Clover Direct' },
    { value: 'DIRECT_SIMBA', label: 'Simba Direct' },
    { value: 'DIRECT_DANONE', label: 'Danone Direct' },
    { value: 'DIRECT_NATBRANDS', label: 'National Brands Direct' },
    { value: 'DIRECT_MONDELEZ', label: 'Mondelez Direct' },
  ],
  '21355': [{ value: 'DC_TOPS', label: 'TOPS DC' }, { value: 'DIRECT_BEER', label: 'SAB Direct' }, { value: 'DIRECT_COCACOLA', label: 'Coca-Cola Direct' }],
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
const SCENARIO_LABEL = {
  full: 'Full need', fitted: 'Fitted to budget',
  order_essentials: 'Order Essentials', catch_up: 'Catch-up',
}
// Board honesty pass (canon v9 item 5, Pieter ruling 2026-07-12): each
// card states its own objective in plain terms, so the screen never
// implies more precision than the FORMULA FREEZE-era build actually has.
// Canon v9 names four objective TAGS (BUDGET/MAX PROFIT/BASIC DEMANDS/
// AVAILABILITY) but "PM owns the screen-text walk" for the exact wording
// -- these captions describe what each scenario's CODE actually does
// today (verifiable against rpc_bloom_order_recipe), not a guess at PM's
// four-word taxonomy mapping. Swap for PM's exact copy when it lands.
const SCENARIO_OBJECTIVE = {
  full: 'Whole pool at per-line minimums -- the unconstrained need.',
  fitted: 'Full need, trimmed to this week’s budget (KVI protected first).',
  order_essentials: 'Selection only: KVI + BT heroes + top-tier lines -- not the whole store.',
  catch_up: 'Priority basket lifted toward the store-wide floor, fit forced on.',
}
// Canon v7 item 9, v10 re-anchor (2026-07-14): the reason a card's
// deviation is not a defect, surfaced (R29) even when there's no flag.
const YARDSTICK_REASON_LABEL = {
  full_is_luxury_by_definition: 'Full is the luxury order by definition -- expected to exceed the 7-day yardstick, never a defect.',
  cash_constrained: 'This week runs cash-constrained -- deviation from the yardstick is expected, not flagged.',
}

// ⭐ ENG-054 -- HOW MUCH IS THE UPLIFT BEHIND THIS GAP WORTH? In one word.
// The engine is the authority: rpc_bloom_promo_floor_gap.uplift_confidence
// derives exactly this CASE server-side. This mirror exists ONLY so the desk
// panel can keep recomputing against the buyer's LIVE edited quantities (the
// RPC answers for a generate, not for an in-progress edit). Keep the two in
// lockstep -- if the engine's classes change, this changes with it.
//   AT_CAP   the uplift sits on promo_uplift_cap. A BOUND, not a measurement:
//            the true value is >= this and unknown. 154 of 1,436 group-wide.
//   SEED     the 2.00 ladder default. UNDERIVED (FILE-GOVERNANCE §0h). 436 of 1,436.
//   BORROWED measured, but on a same-format sibling's ledger (DF-1), not this line's.
//   MEASURED this line's own promo history. The only one you can bank on.
const UPLIFT_CONFIDENCE_CAP = 5
function upliftConfidence(line) {
  const u = line?.promo_uplift_band
  if (u == null) return null
  if (Number(u) >= UPLIFT_CONFIDENCE_CAP) return 'AT_CAP'
  if (line.promo_uplift_band_basis === 'default') return 'SEED'
  if (line.promo_uplift_band_basis === 'sibling_store'
      || line.promo_uplift_band_source === 'sibling_store') return 'BORROWED'
  return 'MEASURED'
}
const UPLIFT_CONFIDENCE_WORD = {
  MEASURED: 'measured',
  BORROWED: 'borrowed',
  AT_CAP:   'at cap',
  SEED:     'seed',
}
const UPLIFT_CONFIDENCE_TITLE = {
  MEASURED: 'Measured on this line’s own promo history. Bankable.',
  BORROWED: 'Measured, but on a same-format sibling store’s ledger (DF-1), not this line’s own.',
  AT_CAP:   'AT THE CAP — a BOUND, not a measurement. The true uplift is at least this and is unknown, so the gap below is a floor, never a ceiling (ENG-054).',
  SEED:     'The 2.00 ladder default. Nobody derived it — SEED, UNDERIVED (FILE-GOVERNANCE §0h). Treat the gap as indicative only.',
}
const UPLIFT_CONFIDENCE_COLOR = {
  MEASURED: 'var(--growth-green)',
  BORROWED: 'var(--veld-mist)',
  AT_CAP:   'var(--core-yellow)',
  SEED:     'var(--data-neg)',
}

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

  // SB-CC-BLOOM-018 item 2 -- THE PROMO FLOOR GAP, surfaced never silent.
  // The engine holds both demands: the band's promo-lifted one and the
  // unlifted one the order was actually computed on (ENG-052, open). The row
  // SHOWS the difference and changes no quantity. The gap is recomputed
  // against the buyer's OWN edited quantity, not the recipe's raw suggestion,
  // so closing it by hand makes the chip disappear as it should.
  const posUnits = (qty ?? 0) * (line.pack_size ?? 0) + Number(line.soh ?? 0)
  const floorUnits = line.promo_floor_units == null ? null : Number(line.promo_floor_units)
  const hasPromoGap = !!line.promo_in_window && floorUnits != null && posUnits < floorUnits
  const gapUnits = hasPromoGap ? Math.max(0, floorUnits - posUnits) : 0
  const gapPacks = hasPromoGap && line.pack_size ? Math.ceil(gapUnits / line.pack_size) : 0
  const upliftConf = upliftConfidence(line)

  // SB-CC-BLOOM-018 item 1 -- THE BUYER SEES THE TRUCK (canon SS14 v15 6a,
  // Pieter ruling 2026-07-28). Where in-transit reduced this line, say so with
  // the quantity and the landing. Never a silent reduction.
  const truckCounted = !!line.in_transit_counted
  const truckPending = !truckCounted && Number(line.in_transit_qty ?? 0) > 0

  // R29 -- every reason the engine produced travels to the hover, in order.
  const rowTitle = [line.story, line.promo_gap_reason, line.in_transit_reason]
    .filter(Boolean).join('\n\n')

  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px',
      alignItems: 'center', gap: 0, padding: '9px 18px', background: wash,
      borderBottom: '1px solid var(--hairline)', fontSize: 12, fontFamily: 'var(--font-mono)',
      fontVariantNumeric: 'tabular-nums',
    }} title={rowTitle}>
      {/* BLOOM-018 v1.2 item 4: the bare '#' prefix is GONE. Pieter read it as a
          broken product code on his largest line. The count-first signal now says
          the word, as a chip in the description cell, and the code stays a code. */}
      <span style={{ color: line.count_first ? 'var(--data-neg)' : 'var(--veld-mist)' }}>
        {String(line.product_code)}
      </span>
      <span style={{ color: 'var(--veld-mist)' }}>{line.pack_size ?? '—'}</span>
      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {line.description}
        {/* BLOOM-018 v1.2 item 4: PACK CONTENT. Five pairs at 80175 render as the
            same product under two codes without it -- GOLDI IQF MP 2KG vs 5KG,
            SPAR EGGS LARGE 60'S vs 48'S, SUNFLOWER OIL 2LT vs 4LT, MAQ FLEXI 1KG
            vs 2KG, STORK 500GR vs 1KG. pack_size does not separate them either
            (6 vs 3, 12 vs 8). Zero shared EANs: the pool is clean, the screen was
            not, and Pieter called the duplicate-order risk. */}
        {line.pack_content && (
          <span style={{ marginLeft: 5, color: 'var(--veld-mist)' }}>{line.pack_content}</span>
        )}
        {line.count_first && (
          <span title={line.band_blocked_reason
            ? `Count first — ${line.band_blocked_reason}`
            : 'Count first — the SOH claim on this line is unverified, so it was ordered conservatively (canon ENG-014). Not a broken code.'}
            style={{ marginLeft: 6, fontSize: 9, color: 'var(--data-neg)', border: '1px solid var(--data-neg)',
              borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>COUNT FIRST</span>
        )}
        {line.is_bt_hero && (
          <span style={{ marginLeft: 6, fontSize: 9, color: 'var(--growth-green)', border: '1px solid var(--growth-green)',
            borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>BT</span>
        )}
        {/* BLOOM-018 item 2: the promo floor gap, on the row that has it. */}
        {hasPromoGap && (
          <span title={line.promo_gap_reason ?? undefined}
            style={{ marginLeft: 6, fontSize: 9, color: 'var(--data-warn)', border: '1px solid var(--data-warn)',
              borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>
            GAP {gapPacks}
          </span>
        )}
        {/* ENG-054: what the uplift behind this gap is worth, IN A WORD, never a
            basis string. A censored 5.00 and a measured 1.12 must not read alike. */}
        {hasPromoGap && upliftConf && (
          <span title={UPLIFT_CONFIDENCE_TITLE[upliftConf]}
            style={{ marginLeft: 4, fontSize: 9, color: UPLIFT_CONFIDENCE_COLOR[upliftConf],
              border: `1px ${upliftConf === 'MEASURED' ? 'solid' : 'dashed'} ${UPLIFT_CONFIDENCE_COLOR[upliftConf]}`,
              borderRadius: 'var(--radius-pill)', padding: '1px 5px' }}>
            {UPLIFT_CONFIDENCE_WORD[upliftConf]}
          </span>
        )}
        {/* BLOOM-018 item 1: the truck. Counted = it reduced this order. */}
        {truckCounted && (
          <span title={line.in_transit_reason ?? undefined}
            style={{ marginLeft: 6, fontSize: 9, color: 'var(--growth-green)', border: '1px solid var(--growth-green)',
              borderRadius: 'var(--radius-pill)', padding: '1px 6px' }}>
            IN TRANSIT {num(line.in_transit_qty)}
          </span>
        )}
        {truckPending && (
          <span title={line.in_transit_reason ?? undefined}
            style={{ marginLeft: 6, fontSize: 9, color: 'var(--veld-mist)', border: '1px dashed var(--veld-mist)',
              borderRadius: 'var(--radius-pill)', padding: '1px 5px' }}>
            EN ROUTE {num(line.in_transit_qty)}
          </span>
        )}
      </span>
      <span style={{ color: 'var(--veld-mist)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{line.dept_name ?? '—'}</span>
      <span style={{ textAlign: 'right', color: line.count_first ? 'var(--data-neg)' : truckCounted ? 'var(--growth-green)' : 'var(--veld-mist)' }}
        title={line.count_first
          ? 'Band-blocked claim — count first (canon ENG-014)'
          : truckCounted
            ? (line.in_transit_reason ?? 'In-transit stock was added to this projection.')
            : undefined}>
        {line.soh == null ? '—' : Number.isInteger(line.soh) ? line.soh : num(line.soh)}
        {truckCounted && <span style={{ marginLeft: 3 }}>+</span>}
      </span>
      {/* BLOOM-018 item 2: BOTH demands, never one. The top figure is what the
          order was computed on; the figure beneath it is the band's promo-lifted
          demand the order did NOT use (ENG-052 is open, the quantity is
          unchanged). Showing one without the other is the silence this closes. */}
      <span style={{ textAlign: 'right', color: 'var(--daisy-white)', lineHeight: 1.25 }}>
        {num(line.rhythm_adjusted_demand)}
        {line.promo_in_window && line.promo_band_demand != null
          && Number(line.promo_band_demand) > Number(line.rhythm_adjusted_demand ?? 0) && (
          <span
            title={line.promo_gap_reason
              ?? 'Band promo-lifted demand. The order was computed on the unlifted rate (ENG-052, open).'}
            style={{ display: 'block', fontSize: 10, color: 'var(--data-warn)' }}>
            promo {num(line.promo_band_demand)}
          </span>
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
  const [overview, setOverview] = useState([])
  const [overviewLoading, setOverviewLoading] = useState(false)
  const [overviewError, setOverviewError] = useState(null)
  const [stockState, setStockState] = useState([])
  const [stockStateError, setStockStateError] = useState(null)
  const [deliveryChain, setDeliveryChain] = useState(null)
  const [deliveryChainError, setDeliveryChainError] = useState(null)
  const [monthProjection, setMonthProjection] = useState(null)
  const [importReport, setImportReport] = useState(null)
  // ENG-031 / Track A item 1: what the TLX actually carried, and what it could not.
  const [tlxReport, setTlxReport] = useState(null)
  // ENG-034 sign-off (PM 2026-07-21, canon SS14 v13): the rail's own LY coverage.
  // l2_sales_budget is LY-anchored and canon carries it as PROVISIONAL, so the
  // strip states that plainly with the MEASURED coverage rather than a store list
  // or an invented threshold (R21 -- a TOPS-only label would be exactly the
  // hardcoded-store-list rule we ban, and the SPAR/TOPS split is 2 observations,
  // not a constant). The buyer sees ~27% at a SPAR and ~11% at a TOPS and weighs
  // the over-rail figure accordingly.
  const [railCoverage, setRailCoverage] = useState(null)
  // ENG-056 (canon §16 wired): the last delivery before the next income window and
  // its placement deadline. Read from the engine, never derived here.
  const [incomeWindow, setIncomeWindow] = useState(null)
  const fileInputRef = useRef(null)

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
        setIncomeWindow(data[0])   // ENG-056 -- same call, no extra round trip
      })
    // The budget ledger fetch MOVED to its own effect below -- it depends on the
    // delivery date, which is only known once the call above resolves (ENG-055).
    // ENG-034 sign-off: the NEEDS rail's own LY coverage, keyed per DESK (that is
    // l2_sales_budget's grain, not the ledger's). Published interface, SELECT
    // granted -- the surface reads the engine's own measurement, never derives it.
    setRailCoverage(null)
    supabase.from('l2_sales_budget').select('products_in_pool, products_with_ly_history, budget_week_start')
      .eq('store_code', storeCode).eq('route_key', desk).order('budget_week_start', { ascending: true }).limit(1).maybeSingle()
      .then(({ data }) => { if (!cancelled) setRailCoverage(data ?? null) })
    setGenerated(false); setLines([]); setQty({}); setEdited({}); setSubmitted(false)
    return () => { cancelled = true }
  }, [storeCode, desk])

  // ⭐ ENG-055 -- THE BUDGET ROW MUST BE THE DELIVERY WEEK'S ROW.
  // Was: .order('year_month', desc).limit(1) -- which takes the LATEST row in the
  // table. `order_budget_ledger` holds 28 FORWARD weeks (to 2027-01-16), so every
  // desk was judged against the furthest-out week, and that week happens to be the
  // table's minimum. Measured at 80175 DC: the screen read R157,951.96 (week of
  // 2027-01-16) against the true delivery-week budget of R363,695.98 (2026-08-01).
  // The buyer read 92% spent while sitting at 40% spent -- which suppresses exactly
  // the promo depth BLOOM-018 exists to recover. Not cosmetic: a cause of the under-buy.
  //
  // Fixed by filtering to the delivery week instead of sorting to the end of time:
  // the newest ledger row AT OR BEFORE the delivery date IS the delivery week's row
  // (rows are Saturday-anchored week starts, canon §14 v7 item 7). This reproduces
  // the engine's own resolution rather than re-deriving a week boundary client-side
  // (R21/R27 -- the recipe picks, the surface never re-cooks). Verified in lockstep
  // with `rpc_bloom_scenario_overview`, which stamps `budget_week_start` itself:
  // both return 2026-08-01 / R363,695.98 for this desk.
  useEffect(() => {
    if (!storeCode || !desk || !deliveryDate) { setBudgetRow(null); setAllBudgetRow(null); return }
    let cancelled = false
    // SB-CC-BLOOM-009: DIRECT_<brand> desks share the generic 'DIRECT' weekly
    // ledger row (mirrors rpc_bloom_order_recipe's own v_ledger_route CASE --
    // must stay in lockstep with it, R21).
    const ledgerRoute = desk === 'DIRECT_BEER' ? 'DIRECT_BEER' : desk.startsWith('DIRECT_') ? 'DIRECT' : 'DC'
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', storeCode).eq('route_key', ledgerRoute)
      .lte('year_month', deliveryDate)
      .order('year_month', { ascending: false }).limit(1).maybeSingle()
      .then(({ data }) => { if (!cancelled) setBudgetRow(data ?? null) })
    // Same defect, same fix (PM flagged it in the same breath) -- the group 'ALL'
    // row was also taking the furthest-out period.
    supabase.from('order_budget_ledger').select('*')
      .eq('store_code', storeCode).eq('route_key', 'ALL')
      .lte('year_month', deliveryDate)
      .order('year_month', { ascending: false }).limit(1).maybeSingle()
      .then(({ data }) => { if (!cancelled) setAllBudgetRow(data ?? null) })
    return () => { cancelled = true }
  }, [storeCode, desk, deliveryDate])

  // UX-003 landing board: the scenario overview + 7-day-yardstick sanity
  // strip (canon v7 item 9) load BEFORE Generate -- one published call,
  // R22-equal to what each scenario's own Generate press would return
  // (rpc_bloom_scenario_overview literally runs the same recipe RPC per
  // scenario server-side and aggregates, never a client-side estimate).
  // ENG-070 (2026-08-05) -- ONE SCENARIO PER CALL, RENDERED AS EACH LANDS.
  //
  // The single call asked the database to run the FULL recipe FIVE times in one
  // request: the four scenarios plus the ENG-018 yardstick. Measured at source:
  //   80175  recipe 2.72s -> overview 13.6s  (5 x 2.72 = 13.6, reproduces exactly)
  //   10116  recipe 8.11s -> overview ~40.6s -> dies on the function's own
  //          `SET LOCAL statement_timeout = '45s'`
  // It sat on the boundary, so it failed INTERMITTENTLY -- three panels timing out
  // one minute and answering the next, which is why it read as flaky rather than
  // broken. Confirmed live on 2026-08-05 at BOTH stores under real page load.
  //
  // The ceiling cannot be raised (Kong ~30s, canon standing constraint 4), so the
  // work had to shrink PER REQUEST rather than be given more time. `p_scenarios`
  // was added to the RPC for exactly this -- each call now runs ONE scenario plus
  // the yardstick (~2 recipe runs), which is comfortably inside every limit at the
  // heaviest store.
  //
  // Sequential, not parallel: four concurrent recipe runs on one small instance
  // contend and would re-create the problem in a new shape. Sequential costs
  // wall-clock but each scenario PAINTS AS IT ARRIVES, so the buyer sees Full
  // Need almost immediately instead of a blank card for forty seconds.
  //
  // R22: the aggregation stays server-side and untouched. The surface requests a
  // subset, it never re-cooks one (R21/R27). Verified before wiring -- the four
  // subset calls return rows identical to the single call, and
  // demonstrated_weekly_demand holds at the same value in every one.
  const OVERVIEW_SCENARIOS = ['full', 'fitted', 'order_essentials', 'catch_up']

  useEffect(() => {
    if (!storeCode || !desk || !deliveryDate) { setOverview([]); return }
    let cancelled = false
    setOverviewLoading(true); setOverviewError(null); setOverview([])

    ;(async () => {
      const collected = []
      const failures  = []

      for (const scenario of OVERVIEW_SCENARIOS) {
        if (cancelled) return
        const { data, error: err } = await supabase.rpc('rpc_bloom_scenario_overview', {
          p_store_code:    storeCode,
          p_delivery_date: deliveryDate,
          p_next_delivery: nextDeliveryDate || null,
          p_route:         desk,
          p_scenarios:     [scenario],
        })
        if (cancelled) return

        if (err) {
          // No silent skips: a scenario that failed is NAMED. The others still
          // render -- one dead scenario must not blank the whole board.
          console.error('[rpc_bloom_scenario_overview]', scenario, err.message)
          failures.push(`${scenario}: ${err.message}`)
        } else {
          collected.push(...(data ?? []))
          // Paint progressively, in the canon order the card row expects.
          setOverview(collected
            .slice()
            .sort((a, b) => OVERVIEW_SCENARIOS.indexOf(a.scenario) - OVERVIEW_SCENARIOS.indexOf(b.scenario)))
        }
      }

      if (cancelled) return
      setOverviewLoading(false)
      setOverviewError(failures.length ? failures.join(' · ') : null)
    })()

    return () => { cancelled = true }
  }, [storeCode, desk, deliveryDate, nextDeliveryDate])

  // SB-CC-BLOOM-008 item 7 -- THE STOCK-STATE INSTRUMENT. Read-only, keyed
  // on store/desk only (current SOH, not a delivery-date scenario). Days-
  // after per group recomputes CLIENT-SIDE below (stockStateWithDaysAfter)
  // from this call's daily_cost_demand plus the live qty state -- never a
  // server round-trip per edit.
  useEffect(() => {
    if (!storeCode || !desk) { setStockState([]); return }
    let cancelled = false
    setStockStateError(null)
    supabase.rpc('rpc_bloom_stock_state', { p_store_code: storeCode, p_route: desk })
      .then(({ data, error: err }) => {
        if (cancelled) return
        if (err) { setStockStateError(err.message); setStockState([]); return }
        setStockState(data ?? [])
      })
    return () => { cancelled = true }
  }, [storeCode, desk])

  // SB-CC-BLOOM-008 item 16(a) -- THE DELIVERY CHAIN TEASER. Fetched once
  // per desk/store selection (the recipe's own raw suggested_packs, no
  // buyer overrides) -- re-fetched with the buyer's own on-screen qty as
  // p_order1_overrides right after Generate, so the teaser reflects what's
  // actually about to be submitted rather than a stale pre-edit guess.
  // Not wired to recompute per keystroke (unlike stock-days above) --
  // a genuine second recipe run per edit would be a real round-trip cost,
  // documented limitation, same class as the promo toy's own live-reactivity
  // gap noted elsewhere in this file.
  useEffect(() => {
    if (!storeCode || !desk) { setDeliveryChain(null); return }
    let cancelled = false
    setDeliveryChainError(null)
    supabase.rpc('rpc_bloom_delivery_chain', { p_store_code: storeCode, p_route: desk })
      .then(({ data, error: err }) => {
        if (cancelled) return
        if (err) { setDeliveryChainError(err.message); setDeliveryChain(null); return }
        setDeliveryChain(data?.[0] ?? null)
      })
    return () => { cancelled = true }
  }, [storeCode, desk])

  // SB-CC-BLOOM-008 item 16(b) -- THE MONTH PICTURE. Read-only, chained off
  // the same recipe/simulated-SOH mechanism as the two-drop teaser above,
  // walked forward through every remaining drop in the calendar month.
  useEffect(() => {
    if (!storeCode || !desk) { setMonthProjection(null); return }
    let cancelled = false
    supabase.rpc('rpc_bloom_month_projection', { p_store_code: storeCode, p_route: desk })
      .then(({ data, error: err }) => {
        if (cancelled || err) return
        setMonthProjection((data ?? []).find(r => r.row_kind === 'MONTH_SUMMARY') ?? null)
      })
    return () => { cancelled = true }
  }, [storeCode, desk])

  // Days-after per group = current stock-days + (this order's added value
  // in that group / the group's own daily_cost_demand) -- pure client-side
  // arithmetic off `lines`+`qty` already in memory, recomputes on every
  // qty edit with no network round-trip ("recomputing live as quantities
  // edit", canon v8 item 7).
  const stockStateWithDaysAfter = useMemo(() => {
    const groups = stockState.filter(s => s.group_name !== 'TOTAL')
    if (!groups.length) return []
    const addedByGroup = { KVI: 0, CORE: 0, TAIL: 0 }
    for (const l of lines) {
      const q = qty[l.product_code] ?? 0
      if (q <= 0) continue
      const grp = ['KVI_CRITICAL', 'KVI_IMPORTANT'].includes(l.kvi_band) ? 'KVI'
        : l.kvi_band === 'LONG_TAIL' ? 'TAIL' : 'CORE'
      addedByGroup[grp] += q * (Number(l.pack_cost) || 0)
    }
    return groups.map(g => ({
      ...g,
      daysAfter: g.daily_cost_demand > 0
        ? Math.round(((Number(g.stock_at_cost) + addedByGroup[g.group_name]) / Number(g.daily_cost_demand)) * 10) / 10
        : null,
    }))
  }, [stockState, lines, qty])

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

    // item 16(a): re-run the teaser against the buyer's OWN on-screen qty
    // (the just-set `q`) rather than the recipe's raw suggested_packs, so
    // "drop 2's order will be ~R..." reflects what's actually about to be
    // submitted. Fire-and-forget -- desk stays usable while this resolves.
    const overrides = {}
    for (const r of rows) overrides[r.product_code] = q[r.product_code] ?? 0
    supabase.rpc('rpc_bloom_delivery_chain', { p_store_code: storeCode, p_route: desk, p_order1_overrides: overrides })
      .then(({ data, error: err }) => {
        if (err) { setDeliveryChainError(err.message); return }
        setDeliveryChain(data?.[0] ?? null)
      })
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
  // WALK-FINDINGS W5: a manual budget insert overrides the 82%/80% basis
  // label -- independent of cash_constrained, which still governs the
  // order_essentials day-cover on its own (unaffected by this flag).
  const budgetManualOverride = !!budgetRow?.budget_manual_override
  // LEG D: the rail's own basis and WHICH week the engine actually priced against.
  // budget_week_source has been an engine output all along and nothing displayed it,
  // which is what made ENG-016's nearest-past-week fallback silent -- every order was
  // fitted to a 3-week-stale WC-11-Jul budget with nothing on screen saying so.
  const budgetIsNeeds = String(budgetRow?.source_note ?? '').startsWith('NEEDS')
  const budgetWeekSource = lines[0]?.budget_week_source ?? null
  const budgetWeekPriced = lines[0]?.budget_week_start ?? null
  const budgetWeekStale = !!budgetWeekSource && budgetWeekSource !== 'delivery_week_exact'
  const promoCount = lines.filter(l => l.promo_active).length
  const shown = filter === 'all' ? lines : lines.filter(l => l.promo_active)
  const cols = ['Code', 'Pack', 'Description', 'Dept', 'SOH', 'ROS/day', 'Tier', 'Promo', 'Qty · packs', 'Value']
  const gridCols = '76px 44px minmax(180px,1.7fr) 110px 56px 90px 90px 60px 130px 100px'
  const beforeFitTotal = useMemo(() => lines.reduce((s, l) => s + (Number(l.packs_before_fit) || 0) * (Number(l.pack_cost) || 0), 0), [lines])
  // ENG-034: the fit reasons the engine ACTUALLY emits. The previous filters
  // ('trimmed_partial' / 'trimmed_to_zero' / 'protected_kvi') matched no engine
  // value at all, so this strip has been reading 0 protected and 0 trimmed on
  // every order since it shipped -- a silent display defect, fixed here.
  const trimmedCount = lines.filter(l => l.budget_fit_reason === 'below_cutoff_held_at_floor' || l.budget_fit_reason === 'below_cutoff_not_funded').length
  const protectedCount = lines.filter(l => l.budget_fit_reason === 'protected_kvi_hero' || l.budget_fit_reason === 'min_presence_floor').length
  // Canon SS14 v9 item 5 / v7 item 9: an order over its ceiling with the floors
  // protected is the RULED behaviour, surfaced as the real decision it is --
  // never silently trimmed into an empty shelf.
  const overRail = fitToBudget && budgetTotal > 0 && total > budgetTotal ? total - budgetTotal : 0
  const railLyPct = Number(railCoverage?.products_in_pool) > 0
    ? Math.round(100 * Number(railCoverage.products_with_ly_history) / Number(railCoverage.products_in_pool))
    : null

  // Canon v7 item 11 -- THE EXPORT CONTRACT, three files per order:
  // (1) CSV = EVERYTHING, StockFlow benchmark format (Bloom/BENCHMARK_
  //     order_2314_10116_2026-07-11.csv), promo lines flagged but never
  //     excluded. (2) TLX = the NORMAL order ONLY -- promo lines and
  //     unresolvable (no-EAN) lines never ride it (BLOOM-001 SS5).
  // (3) Promo sheet = the PROMO order ONLY, geared quantities, EXACT
  //     format of Bloom/EXPORT-TEMPLATE_Promo-Order-Capture-Sheet.xlsx
  //     (title row merged A1:E1 "Promo Order - <Store> - <date>", header
  //     Product Code/Description/Size/Order Qty/Promo Suffix, Total
  //     Items/Total Qty footer). Promo naming uses promo_suffix (the DC
  //     code parsed server-side from sigma_promotions.description,
  //     ENG-017 sibling) with the promo_nr fallback surfaced, never
  //     guessed, when promo_naming_gap is true.
  function exportCsv() {
    const header = ['Rank','Product Code','EAN','Description','Size','Pack Size','List Cost',
      'Opening Stock','Avg Daily Sales','Units Needed','Order Qty','Closing Stock','Stock Days',
      'Order Value','Line Category','Ranking','Current Promo','Next Promo','Is Promo'].join(',') + '\n'
    const ordered = [...lines].sort((a, b) => (b.rhythm_adjusted_demand ?? 0) - (a.rhythm_adjusted_demand ?? 0))
    const body = ordered.map((l, i) => {
      const q = qty[l.product_code] ?? 0
      const unitCost = l.pack_size ? (Number(l.pack_cost) || 0) / l.pack_size : (Number(l.pack_cost) || 0)
      const closing = (Number(l.projected_soh) || 0) + q * (l.pack_size ?? 1)
      const demand = Number(l.rhythm_adjusted_demand) || 0
      const stockDays = demand > 0 ? (closing / demand) : 0
      const value = q * (Number(l.pack_cost) || 0)
      const desc = String(l.description ?? '').replace(/"/g, '""')
      return [
        i + 1, l.product_code, l.ean ?? '', `"${desc}"`, '', l.pack_size ?? '',
        unitCost.toFixed(6), l.soh ?? 0, demand.toFixed(2), l.need_units ?? 0, q,
        closing.toFixed(2), stockDays.toFixed(2), value.toFixed(2), '', l.tier ?? '',
        l.promo_active ? (l.promo_suffix ?? (l.promo_naming_gap ? `#${l.promo_nr}` : '')) : '',
        '', l.promo_active ? 'Yes' : 'No',
      ].join(',')
    }).join('\n')
    downloadText(`${storeCode}_${desk}_${preset}_${deliveryDate}.csv`, header + body)
  }

  // Pieter ruling 2026-07-14: the three-file export contract (CSV/TLX/Promo
  // Sheet) is a DC-only shape. Coca-Cola, SAB and every other direct desk
  // never get a separate promo sheet -- just TLX and CSV, so TLX on those
  // routes must carry promo lines itself (nothing else would carry them).
  const isDcRoute = desk === 'DC_AMBIENT' || desk === 'DC_TOPS'

  // TLX: on DC routes, NORMAL order only -- promo lines and no-EAN lines
  // never ride it (they go out on the separate Promo Sheet). On direct
  // routes (no promo sheet exists there), promo lines ride the TLX too --
  // it is the buyer's only export for that desk.
  // Carries the PACK quantity (q), never units -- Sigma's TLX order import
  // reads packs, not each. (Bug: this line used to multiply by pack_size,
  // writing units; corrected 2026-07-14 per floor report.)
  // ENG-031: the old `if (!l.ean) continue` guard was DEAD CODE. The R20-addendum
  // COALESCE (2026-06-30) made `ean` never null, so manufactured store-prefixed keys
  // rode the TLX, Sigma silently dropped them on import, and the buyer saw a line
  // count that never arrived. Eligibility is now an ENGINE verdict read from
  // rpc_bloom_export_eligibility (l2_export_key) -- the frontend never decides what a
  // real barcode is (R21, R30), and the key written is the engine's own export_key,
  // so there is one home for it. Excluded lines are SURFACED with their reason
  // (R21 sec 5, R22 no silent drops), never quietly skipped.
  async function exportTlx() {
    setTlxReport(null)
    const wanted = lines.filter(l => (qty[l.product_code] ?? 0) > 0 && !(isDcRoute && l.promo_active))
    if (wanted.length === 0) { setTlxReport({ exported: 0, excluded: [] }); return }

    const { data, error: eligErr } = await supabase.rpc('rpc_bloom_export_eligibility', {
      p_store_code: storeCode,
      p_product_codes: wanted.map(l => Number(l.product_code)),
    })
    // Fail loudly, never ship a guessed file (R22). A TLX built without the verdict
    // is exactly the silent-drop failure this fix exists to end.
    if (eligErr) { setTlxReport({ error: `Export blocked -- could not read export eligibility: ${eligErr.message}` }); return }

    const elig = new Map((data ?? []).map(r => [Number(r.product_code), r]))
    const parts = []
    const excluded = []
    for (const l of wanted) {
      const q = qty[l.product_code] ?? 0
      const e = elig.get(Number(l.product_code))
      if (!e) { excluded.push({ code: l.product_code, desc: l.description, reason: 'no engine identity row' }); continue }
      if (!e.export_eligible) { excluded.push({ code: l.product_code, desc: l.description, reason: e.ineligible_reason }); continue }
      parts.push(`${e.export_key}+${q}`)
    }
    setTlxReport({ exported: parts.length, excluded })
    downloadText(`${storeCode}_${desk}_${preset}_${deliveryDate}.tlx`, `${storeCode}++${parts.join('+')}`)
  }

  // Promo capture sheet: PROMO order only, geared quantities, the exact
  // Pieter-supplied template layout (title merged row, 5-col header,
  // Total Items/Total Qty footer) via the xlsx lib already used elsewhere
  // in this codebase (src/app/page.jsx report export).
  function exportPromoSheet() {
    // ENG-021: read the buyer's live on-screen qty, same source as the CSV/TLX
    // exporters -- a zeroed promo line must never export at full geared qty.
    const promoLines = lines.filter(l => l.promo_active && (qty[l.product_code] ?? 0) > 0)
    const title = `Promo Order - ${storeCode} - ${deliveryDate}`
    const aoa = [
      [title, '', '', '', ''],
      ['Product Code', 'Description', 'Size', 'Order Qty', 'Promo Suffix'],
      ...promoLines.map(l => [
        l.product_code, l.description ?? '', '', qty[l.product_code] ?? 0,
        l.promo_suffix ?? (l.promo_naming_gap ? `#${l.promo_nr}` : ''),
      ]),
      ['Total Items:', promoLines.length, '', 'Total Qty:', promoLines.reduce((s, l) => s + (qty[l.product_code] ?? 0), 0)],
    ]
    const ws = XLSX.utils.aoa_to_sheet(aoa)
    ws['!merges'] = [{ s: { r: 0, c: 0 }, e: { r: 0, c: 4 } }]
    ws['!cols'] = [{ wch: 15 }, { wch: 45 }, { wch: 12 }, { wch: 12 }, { wch: 15 }]
    const wb = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(wb, ws, 'Promo Order')
    XLSX.writeFile(wb, `${storeCode}_${desk}_${preset}_${deliveryDate}_promo.xlsx`)
  }

  // Canon item 11b -- THE ROUND-TRIP RULE. Quantities only: match on Product
  // Code, consume Order Qty, ignore every other column. The engine owns pool
  // membership (a code not in the generated order is never added, only
  // reported); a code missing from the file is left unchanged; an explicit
  // 0 zeroes the line. Rejects per row, never per file (R22, no silent
  // drops -- every unknown code and every rejected row is named in the
  // report, never dropped quietly).
  function parseCsvGrid(text) {
    const rows = []
    let field = '', row = [], inQuotes = false
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (inQuotes) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++ } else inQuotes = false }
        else field += c
        continue
      }
      if (c === '"') { inQuotes = true }
      else if (c === ',') { row.push(field); field = '' }
      else if (c === '\r') { /* skip */ }
      else if (c === '\n') { row.push(field); rows.push(row); row = []; field = '' }
      else field += c
    }
    if (field.length || row.length) { row.push(field); rows.push(row) }
    return rows.filter(r => r.some(c => String(c ?? '').trim() !== ''))
  }

  async function importOrderFile(file) {
    setImportReport(null)
    let rows
    try {
      if (/\.xlsx$/i.test(file.name)) {
        const buf = await file.arrayBuffer()
        const wb = XLSX.read(buf, { type: 'array' })
        rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' })
      } else {
        rows = parseCsvGrid(await file.text())
      }
    } catch (e) {
      setImportReport({ fileError: `Could not read "${file.name}": ${e.message}` })
      return
    }
    if (!rows || rows.length < 2) {
      setImportReport({ fileError: `"${file.name}" has no data rows.` })
      return
    }
    const header = rows[0].map(h => String(h ?? '').trim().toLowerCase())
    const codeIdx = header.indexOf('product code')
    const qtyIdx = header.indexOf('order qty')
    if (codeIdx === -1 || qtyIdx === -1) {
      setImportReport({ fileError: `"${file.name}" needs "Product Code" and "Order Qty" columns -- the desk's own CSV/XLSX export format.` })
      return
    }

    // Guard: the export filename carries store + delivery date
    // (`${store}_${desk}_${preset}_${date}...`) -- warn, never block, if
    // the file looks like it belongs to a different order (item 11b rule 5).
    // Anchored on the FIRST token (store, never contains "_") and the
    // TRAILING ISO date (never split on a fixed position -- `desk` values
    // like DC_AMBIENT/DIRECT_BEER and presets like order_essentials
    // legitimately contain underscores, which breaks any fixed-index split).
    const stem = file.name.replace(/\.(csv|xlsx)$/i, '')
    const fileStore = stem.split('_')[0]
    const fileDateMatch = stem.match(/(\d{4}-\d{2}-\d{2})$/)
    const nameMismatch = (fileStore && fileStore !== storeCode) || (fileDateMatch && fileDateMatch[1] !== deliveryDate)
      ? `"${file.name}" looks like it belongs to a different order (this desk: ${storeCode}, delivery ${deliveryDate}). Applied anyway -- check before submitting.`
      : null

    const known = new Set(lines.map(l => String(l.product_code)))
    const nextQty = { ...qty }
    const nextEdited = { ...edited }
    let changed = 0, unchanged = 0
    const unknownSet = new Set()
    const rejected = []

    for (let r = 1; r < rows.length; r++) {
      const row = rows[r]
      if (!row || row.every(c => String(c ?? '').trim() === '')) continue
      const code = String(row[codeIdx] ?? '').trim()
      if (!code) continue
      if (!known.has(code)) { unknownSet.add(code); continue }
      const raw = row[qtyIdx]
      const n = Number(raw)
      if (raw === '' || raw == null || !Number.isFinite(n) || n < 0) {
        rejected.push({ code, value: String(raw ?? ''), reason: !Number.isFinite(n) || raw === '' || raw == null ? 'non-numeric Order Qty' : 'negative Order Qty' })
        continue
      }
      const q = Math.round(n)
      if ((Number(nextQty[code]) || 0) === q) { unchanged++ }
      else { nextQty[code] = q; nextEdited[code] = true; changed++ }
    }

    const unknown = [...unknownSet]
    setQty(nextQty)
    setEdited(nextEdited)
    setImportReport({ changed, unchanged, unknown, rejected, nameMismatch, fileName: file.name })
  }

  function onImportFileChosen(e) {
    const file = e.target.files?.[0]
    e.target.value = '' // allow re-choosing the same file name back-to-back
    if (file) importOrderFile(file)
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
        {/* ⭐ ENG-056 -- THE LAST DELIVERY BEFORE PENSION, AND WHEN IT MUST BE PLACED.
            Canon §16 wired (SB-CC-BLOOM-018 v1.3 item A). Every figure here is READ
            from the engine off the published income calendar and this route's own
            delivery_dows and derived cutoff -- there is no day-of-month anywhere in
            it, which is the whole point: the fixed day-25 rule was wrong in 12 of 12
            months by 2 to 8 days and twice named a day nothing can happen on.
            No demand multiplier rides this (§14 v15 6a -- the date model stops at useful). */}
        {incomeWindow?.income_window_start && (
          <div style={{
            marginTop: 12, padding: '10px 14px', borderRadius: 'var(--radius-chip)',
            fontFamily: 'var(--font-mono)', fontSize: 11.5, lineHeight: 1.6,
            border: `1px solid ${incomeWindow.income_calendar_state === 'DEADLINE PASSED' ? 'var(--data-neg)'
                      : incomeWindow.income_calendar_state === 'PLACE TODAY' ? 'var(--core-yellow)' : 'var(--hairline)'}`,
            background: incomeWindow.income_calendar_state === 'DEADLINE PASSED' ? 'rgba(239,83,80,0.10)'
                      : incomeWindow.income_calendar_state === 'PLACE TODAY' ? 'rgba(255,209,0,0.10)' : 'rgba(255,255,255,0.02)',
          }}>
            <span style={{ color: 'var(--daisy-white)' }}>
              <strong>Last delivery before pension: {incomeWindow.last_delivery_before_income ?? '—'}</strong>
              {incomeWindow.placement_deadline && <> · <strong style={{
                color: incomeWindow.income_calendar_state === 'DEADLINE PASSED' ? 'var(--data-neg)'
                     : incomeWindow.income_calendar_state === 'PLACE TODAY' ? 'var(--core-yellow)' : 'var(--daisy-white)' }}>
                place by {incomeWindow.placement_deadline}</strong></>}
              {incomeWindow.income_calendar_state === 'PLACE TODAY' && <strong style={{ color: 'var(--core-yellow)' }}> — that is TODAY</strong>}
              {incomeWindow.income_calendar_state === 'DEADLINE PASSED' && <strong style={{ color: 'var(--data-neg)' }}> — THAT DATE HAS PASSED</strong>}
            </span>
            <span style={{ display: 'block', color: 'var(--veld-mist)', fontSize: 10 }}>
              Income window opens {incomeWindow.income_window_start}
              {incomeWindow.income_window_streams && <> · {incomeWindow.income_window_streams}</>}
              {incomeWindow.placement_deadline_basis && <> · {incomeWindow.placement_deadline_basis}</>}
            </span>
          </div>
        )}
        {/* No silent empty: if the calendar has run out, the desk says so (§8.6 guard 4). */}
        {incomeWindow && !incomeWindow.income_window_start && incomeWindow.income_calendar_state && (
          <div style={{ marginTop: 12, padding: '8px 14px', borderRadius: 'var(--radius-chip)',
            border: '1px dashed var(--core-yellow)', fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--core-yellow)' }}>
            Pension timing unavailable — {incomeWindow.income_calendar_state}.
          </div>
        )}
        <div style={{ marginTop: 10, display: 'flex', gap: 18, flexWrap: 'wrap', fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)' }}>
          <span>Basis this week: <strong style={{ color: budgetManualOverride ? 'var(--daisy-white)' : cashConstrained ? 'var(--core-yellow)' : 'var(--data-pos)' }}>
            {budgetManualOverride ? 'MANUAL' : budgetIsNeeds ? 'NEEDS (projection)' : cashConstrained ? '80% CASH-CONSTRAINED (10d essentials)' : '82% FORECAST (21d essentials)'}
          </strong></span>
          <span>Route budget{budgetManualOverride || budgetIsNeeds ? '' : ' (82%)'}: {zar(budgetTotal)}</span>
          {budgetIsNeeds && railLyPct != null && (
            <span style={{ color: 'var(--core-yellow)' }}>rail provisional · LY {railLyPct}% of pool</span>
          )}
          {!budgetManualOverride && cash80Group > 0 && <span>Group 80%-cash reference: {zar(cash80Group)}</span>}
          {generated && fitToBudget && (
            <span>Fit: {zar(beforeFitTotal)} → {zar(total)} · {protectedCount} at floor · {trimmedCount} held below cutoff</span>
          )}
        </div>
        {/* ENG-034: floors are never trimmed, so an order can legitimately sit above
            its rail. Canon v9 item 5 -- surface it as the decision it is. */}
        {generated && overRail > 0 && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--core-yellow)',
            background: 'rgba(234,179,8,0.10)', border: '1px solid rgba(234,179,8,0.35)', borderRadius: 8, padding: '8px 12px' }}>
            Over the week’s rail by {zar(overRail)} — HERO/KVI floors and the minimum-presence packs are protected and never trimmed.
            Nothing has been shaved into an empty shelf; this is a buying decision, not a fault.
            {budgetIsNeeds && railLyPct != null && (
              <> The rail itself is <strong>provisional</strong> — it is projected off last year and only {railLyPct}% of this pool has last-year history, so treat the over-rail figure as indicative, not a cash verdict.</>
            )}
          </div>
        )}
        {/* LEG D: the fallback is no longer silent. */}
        {generated && budgetWeekStale && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--core-yellow)',
            background: 'rgba(234,179,8,0.10)', border: '1px solid rgba(234,179,8,0.35)', borderRadius: 8, padding: '8px 12px' }}>
            {budgetWeekSource === 'no_ledger_row'
              ? 'No budget row exists for this delivery week on this route — the order is priced against a budget of R0. Fit to budget will trim everything. Generate the budget rail before ordering.'
              : `This delivery week has no budget row. The engine fell back to the nearest PAST week (${budgetWeekPriced}) — the figure above is stale and the fit is judged against it.`}
          </div>
        )}
        {error && (
          <div style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: '#fca5a5',
            background: 'rgba(239,68,68,0.12)', border: '1px solid rgba(239,68,68,0.35)', borderRadius: 8, padding: '8px 12px' }}>
            {error}
          </div>
        )}
      </GlassCard>

      {/* UX-003 landing board: scenario overview + 7-day-yardstick sanity strip,
          visible BEFORE Generate, one server call (rpc_bloom_scenario_overview),
          R22-equal to what pressing Generate on each scenario would return. */}
      <GlassCard style={{ margin: '0 32px 20px', padding: '16px 22px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <Label style={{ color: 'var(--veld-mist)' }}>Scenario overview {overviewLoading ? '· loading …' : ''}</Label>
        </div>
        {overviewError && (
          <p style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: '#fca5a5' }}>{overviewError}</p>
        )}
        {!overviewError && overview.length > 0 && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 10 }}>
              {overview.map(s => (
                <div key={s.scenario} style={{
                  padding: '10px 12px', borderRadius: 'var(--radius-chip)',
                  border: s.yardstick_flag === 'DEFECT_SIGNAL' ? '1px solid rgba(239,83,80,0.55)' : '1px solid var(--hairline)',
                  background: s.yardstick_flag === 'DEFECT_SIGNAL' ? 'rgba(239,83,80,0.08)' : 'rgba(255,255,255,0.02)',
                }}>
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--veld-mist)' }}>
                    {SCENARIO_LABEL[s.scenario] ?? s.scenario}
                  </div>
                  {/* PM ruling 2026-07-12: normal/geared is a VALUE PAIR on
                      each card, never separate cards -- closes CC's own
                      flagged "4 vs 6 scenarios" question. value_normal is the
                      TRUE fit-applied order value (what Generate submits);
                      value_geared is the pre-fit "fully geared" comparison
                      (informational -- see the RPC's own header note). Both
                      always visible, never toggled away. */}
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 15, color: 'var(--daisy-white)', marginTop: 2 }}>
                    {zar(s.value_normal)}
                  </div>
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5, color: 'var(--veld-mist)', marginTop: 1 }}>
                    geared basis {zar(s.value_geared)}
                  </div>
                  {/* BLOOM-018 item 2 pt 3 (Pieter ruling 2026-07-29): the
                      PROMOTIONAL SHARE of value, percentage beside the rand.
                      Split on promo_active -- the same flag the CSV/TLX/promo-
                      sheet export splits on (canon SS14 v7 item 11) -- so the
                      figure reconciles to the files, not to a second definition
                      of "promo". promo + normal sums back to the card total. */}
                  {s.promo_share_pct != null && (
                    <div style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5, marginTop: 3,
                      color: 'var(--data-warn)' }}
                      title={`Promotional ${zar(s.value_promo_lines)} + normal ${zar(s.value_nonpromo_lines)} = ${zar(Number(s.value_promo_lines) + Number(s.value_nonpromo_lines))}. Split on promo_active, the same flag the export splits on.`}>
                      {s.promo_share_pct}% promotional
                      <span style={{ color: 'var(--veld-mist)' }}> · {zar(s.value_promo_lines)} promo / {zar(s.value_nonpromo_lines)} normal</span>
                    </div>
                  )}
                  {/* Board honesty pass (canon v9 item 5): each card states its
                      own objective in plain terms -- what the code actually
                      does, not a guess at PM's four-word taxonomy (BUDGET/MAX
                      PROFIT/BASIC DEMANDS/AVAILABILITY) -- PM owns that exact
                      copy on the walk. Fitted specifically says "= full need,
                      no trim required" when full already sits inside budget
                      (the mechanical reason full==fitted can be legitimate). */}
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)', marginTop: 3, lineHeight: 1.4 }}>
                    {s.scenario === 'fitted' && Number(s.value_normal) <= Number(s.budget_amount)
                      ? '= full need, no trim required (already inside budget).'
                      : SCENARIO_OBJECTIVE[s.scenario]}
                  </div>
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)', marginTop: 4 }}>
                    {s.lines} lines · {s.promo_lines} promo · {s.count_first_lines} count-first (ordered)
                    {s.trimmed_lines > 0 && ` · ${s.trimmed_lines} trimmed`}
                  </div>
                  {/* UX-004: ordered-set count-first (above) is never the whole
                      pool -- the pool figure rides separately, labelled, so the
                      two are never read as the same number again. */}
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--veld-mist)', opacity: 0.7, marginTop: 1 }}>
                    {s.count_first_pool} count-first across the WHOLE POOL (band_blocked, includes lines not ordered)
                  </div>
                  <div style={{ marginTop: 8 }}>
                    <KviPie byKviBandLines={s.by_kvi_band_lines} />
                  </div>
                  {s.yardstick_flag === 'DEFECT_SIGNAL' && (
                    <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--data-neg)', marginTop: 4 }}>
                      DEFECT SIGNAL — {s.yardstick_deviation_pct}% off yardstick
                    </div>
                  )}
                  {/* R29 -- the reason travels with the number, even when there's
                      no flag (canon v7 item 9 v10 re-anchor: full's deviation is
                      permanent and expected, never a defect). */}
                  {s.yardstick_reason && (
                    <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--veld-mist)', opacity: 0.75, marginTop: 3 }}>
                      {YARDSTICK_REASON_LABEL[s.yardstick_reason] ?? s.yardstick_reason}
                    </div>
                  )}
                  {/* ENG-025 step 2b -- the direct supplier minimum, a FLAG that
                      never blocks (canon v7 item 7e). Shown only on direct desks
                      (min_order_value is NULL on DC). Below the minimum the card
                      says so and shows the shortfall; the buyer decides
                      (accumulate or send). R29 -- the reason travels. */}
                  {s.min_order_value != null && (
                    <div style={{
                      fontFamily: 'var(--font-mono)', fontSize: 9, marginTop: 3,
                      color: Number(s.min_shortfall) > 0 ? 'var(--data-warn, #c9a227)' : 'var(--veld-mist)',
                      opacity: Number(s.min_shortfall) > 0 ? 1 : 0.75,
                    }}>
                      {s.min_reason}
                    </div>
                  )}
                </div>
              ))}
            </div>
            <p style={{ margin: '10px 0 0', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)' }}>
              7-day yardstick (canon v7 item 9): {zar(overview[0]?.yardstick_value ?? 0)} · flag never blocks · computed {overview[0]?.computed_at ? new Date(overview[0].computed_at).toLocaleTimeString() : '—'}
            </p>
            <p style={{ margin: '4px 0 0', fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--veld-mist)', opacity: 0.75 }}>
              Pie = ordered-line mix (KVI/Core/Tail by count). Also computed server-side per scenario, not yet visualized here: value by mode (minimum/build/month-end), value by tier (T100/T1000/BOR) — available on the same call (`by_mode`, `by_tier`) for a future breakdown panel.
            </p>
          </>
        )}
      </GlassCard>

      {/* SB-CC-BLOOM-008 item 7 -- THE STOCK-STATE INSTRUMENT. Read-only,
          zero formula risk (FORMULA FREEZE holds until after Pieter's
          Monday walk) -- current SOH in stock-days by KVI/Core/Tail, plus
          days-after recomputing live off the desk's own in-memory qty
          state as the buyer edits, no server round-trip per keystroke. */}
      <GlassCard style={{ margin: '0 32px 20px', padding: '16px 22px' }}>
        <Label style={{ color: 'var(--veld-mist)' }}>Stock now — where the store stands</Label>
        {stockStateError && (
          <p style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: '#fca5a5', marginTop: 8 }}>{stockStateError}</p>
        )}
        {!stockStateError && stockStateWithDaysAfter.length > 0 && (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 10, marginTop: 10 }}>
            {stockStateWithDaysAfter.map(g => (
              <div key={g.group_name} style={{ padding: '10px 12px', borderRadius: 'var(--radius-chip)', border: '1px solid var(--hairline)', background: 'rgba(255,255,255,0.02)' }}>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--veld-mist)' }}>
                  {g.group_name}
                </div>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 20, color: 'var(--daisy-white)', marginTop: 2 }}>
                  {g.stock_days ?? '—'}d <span style={{ fontSize: 11, color: 'var(--veld-mist)' }}>now</span>
                </div>
                {generated && (
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 13, color: 'var(--data-pos)', marginTop: 2 }}>
                    → {g.daysAfter ?? '—'}d <span style={{ fontSize: 10, color: 'var(--veld-mist)' }}>after this order</span>
                  </div>
                )}
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)', marginTop: 4 }}>
                  {g.lines} lines ({g.selling_lines} selling) · stock {zar(g.stock_at_cost)} · daily {zar(g.daily_cost_demand)}
                </div>
              </div>
            ))}
          </div>
        )}
        {stockState.find(s => s.group_name === 'TOTAL') && (
          <p style={{ margin: '10px 0 0', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)' }}>
            {(() => {
              const t = stockState.find(s => s.group_name === 'TOTAL')
              return `Dept demand ${zar(t.weekly_demand_dept)}/wk = orderable ${zar(t.weekly_demand_orderable)} + ${zar(t.weekly_demand_gap)} (${t.weekly_demand_gap_lines} lines, ${t.weekly_demand_gap_label} -- no active DC supplier link, ENG-008)`
            })()}
          </p>
        )}
      </GlassCard>

      {/* SB-CC-BLOOM-008 item 16(a) -- THE DELIVERY CHAIN TEASER, per CD-SPEC-
          BLOOM-002 item 6: "If this lands Thu, Sat's order runs ~R..." Reads
          the buyer's own on-screen qty once Generate has run (fire-and-forget
          refetch above), the recipe's raw suggested_packs before that. */}
      {(deliveryChain || deliveryChainError || monthProjection) && (
        <GlassCard style={{ margin: '0 32px 20px', padding: '16px 22px' }}>
          <Label style={{ color: 'var(--veld-mist)' }}>Delivery chain</Label>
          {deliveryChainError && (
            <p style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: '#fca5a5', marginTop: 8 }}>{deliveryChainError}</p>
          )}
          {deliveryChain && (
            <>
              <p style={{ margin: '8px 0 0', fontFamily: 'var(--font-display)', fontSize: 15, color: 'var(--daisy-white)' }}>
                {deliveryChain.story}
              </p>
              <p style={{ margin: '6px 0 0', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)' }}>
                Order 1 ({deliveryChain.d1}): {deliveryChain.order1_lines} lines, {zar(deliveryChain.order1_value)}
                {' · '}Order 2 projected ({deliveryChain.d2}): {deliveryChain.order2_projected_lines} lines, {zar(deliveryChain.order2_projected_value)}
                {' · '}needs {deliveryChain.d3} for its own cover
              </p>
            </>
          )}
          {monthProjection && (
            <p style={{ margin: '10px 0 0', paddingTop: 8, borderTop: '1px solid var(--hairline)', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)' }}>
              Month: landed {zar(monthProjection.month_to_date_landed)} + projected = {zar(monthProjection.month_purchases_projected_total)}
              {monthProjection.route_budget_amount != null && <>{' · '}route budget {zar(monthProjection.route_budget_amount)}</>}
              {monthProjection.drops_capped && <> · drops beyond 8 not shown</>}
              {' · '}<span title={monthProjection.sales_target_note}>no sales target configured yet</span>
            </p>
          )}
        </GlassCard>
      )}

      {/* ===== SB-CC-BLOOM-018 -- THE PROMO FLOOR GAP + THE TRUCK =====
          Item 2: every promo-in-window line finishing below its own promo-lifted
          floor, ranked HERO then KVI then rand, with the packs and rand to close.
          This is the list PM built by hand on 2026-07-29; it stops being a hand job.
          Item 1 (canon SS14 v15 6a): wherever in-transit reduced this order, the
          buyer is SHOWN the truck -- quantity and landing -- never a silent
          reduction. Both read the buyer's LIVE quantities, so the numbers move as
          the order is edited. NEITHER changes a suggested quantity: ENG-052 stays
          open and the model lands with item 3. */}
      {generated && (() => {
        const gapRows = lines
          .map(l => {
            const posUnits = (qty[l.product_code] ?? 0) * (l.pack_size ?? 0) + Number(l.soh ?? 0)
            const floor = l.promo_floor_units == null ? null : Number(l.promo_floor_units)
            if (!l.promo_in_window || floor == null || posUnits >= floor) return null
            const shortUnits = Math.max(0, floor - posUnits)
            const shortPacks = l.pack_size ? Math.ceil(shortUnits / l.pack_size) : 0
            const pri = l.is_bt_hero ? 1 : l.kvi_band === 'KVI_CRITICAL' ? 2 : l.kvi_band === 'KVI_IMPORTANT' ? 3 : 4
            return { l, posUnits, floor, shortUnits, shortPacks, pri,
                     shortRand: shortPacks * Number(l.pack_cost ?? 0),
                     conf: upliftConfidence(l) }
          })
          .filter(Boolean)
          .sort((a, b) => a.pri - b.pri || b.shortRand - a.shortRand || a.l.product_code - b.l.product_code)

        const gapRand = gapRows.reduce((s, r) => s + r.shortRand, 0)
        const gapPriority = gapRows.filter(r => r.pri <= 3).length
        const gapCapped = gapRows.filter(r => r.conf === 'AT_CAP').length
        // ENG-054: how much of this gap rests on a number we actually measured.
        // The buyer can act on the measured tranche today; the at-cap tranche is a
        // FLOOR (true gap >= shown), and the seed tranche is indicative only.
        const randByConf = gapRows.reduce((acc, r) => {
          const k = r.conf ?? 'UNKNOWN'; acc[k] = (acc[k] ?? 0) + r.shortRand; return acc
        }, {})
        const kviMeasuredRand = gapRows
          .filter(r => r.pri <= 3 && r.conf === 'MEASURED')
          .reduce((s, r) => s + r.shortRand, 0)

        // The worklist EXPORTS -- the buyer captures from a file, he does not read
        // it off a screen (PM, BLOOM-018 v1.2 item 2). Cut from the LIVE quantities
        // on screen, never the recipe's raw figures (canon §14 v7 item 11b, the
        // round-trip rule that ENG-021 breached).
        const exportGap = () => {
          // v1.3 item C: the run's parameters ride on EVERY row, so a figure that
          // leaves this screen cannot be quoted without the generate that produced it.
          const head = ['Store','Route','Delivery Date','Next Delivery','Generated At',
                        'Rank','Product Code','Description','Priority','Confidence',
                        'SOH','Ordered Packs','Pack Size','Position Units','Promo Floor Units',
                        'Order Demand/Day','Band Demand/Day','Uplift','Uplift Basis',
                        'Short Units','Short Packs','Short Rand']
          const stamp = new Date().toISOString()
          const esc = v => {
            const s = v == null ? '' : String(v)
            return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
          }
          const body = gapRows.map((r, i) => [
            storeCode, desk, deliveryDate, nextDeliveryDate, stamp,
            i + 1, r.l.product_code, r.l.description,
            r.l.is_bt_hero ? 'HERO' : (r.l.kvi_band ?? ''),
            UPLIFT_CONFIDENCE_WORD[r.conf] ?? '',
            r.l.soh, qty[r.l.product_code] ?? 0, r.l.pack_size,
            r.posUnits, Math.round(r.floor * 10) / 10,
            r.l.rhythm_adjusted_demand, r.l.promo_band_demand,
            r.l.promo_uplift_band, r.l.promo_uplift_band_basis,
            Math.round(r.shortUnits * 10) / 10, r.shortPacks,
            Math.round(r.shortRand * 100) / 100,
          ].map(esc).join(','))
          const csv = [head.join(','), ...body].join('\r\n')
          const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }))
          const a = document.createElement('a')
          a.href = url
          a.download = `promo-floor-gap_${storeCode}_${desk}_${deliveryDate}.csv`
          document.body.appendChild(a); a.click(); document.body.removeChild(a)
          URL.revokeObjectURL(url)
        }

        const truckLines = lines.filter(l => l.in_transit_counted)
        const truckUnits = truckLines.reduce((s, l) => s + Number(l.in_transit_qty ?? 0), 0)
        const truckCost = truckLines.reduce((s, l) => s + Number(l.in_transit_cost ?? 0), 0)
        const enRoute = lines.filter(l => !l.in_transit_counted && Number(l.in_transit_qty ?? 0) > 0)
        const staleLines = lines.filter(l => Number(l.in_transit_stale_qty ?? 0) > 0)
        const staleOldest = staleLines.reduce((m, l) => Math.max(m, Number(l.in_transit_stale_age_days ?? 0)), 0)
        // canon §14 v15 rule 5a: the derived landing estimate is an ESTIMATE, never
        // an exclusion test -- roughly half of genuine deliveries land after their own
        // median, so a past estimate is COUNTED and SURFACED, never silently dropped
        // and never silently counted either. 16 such lines at 21355 today.
        const elapsedEst = truckLines.filter(l => l.in_transit_landing_state === 'estimate_elapsed')
        const elapsedUnits = elapsedEst.reduce((s, l) => s + Number(l.in_transit_qty ?? 0), 0)

        if (gapRows.length === 0 && truckLines.length === 0 && enRoute.length === 0 && staleLines.length === 0) return null

        return (
          <GlassCard style={{ margin: '0 32px 20px', padding: '16px 22px' }}>
            {/* --- item 1: the truck, as a desk-header total --- */}
            {(truckLines.length > 0 || enRoute.length > 0 || staleLines.length > 0) && (
              <div style={{ marginBottom: gapRows.length ? 14 : 0, paddingBottom: gapRows.length ? 12 : 0,
                borderBottom: gapRows.length ? '1px solid var(--hairline)' : 'none' }}>
                <Label style={{ color: 'var(--veld-mist)' }}>In transit</Label>
                <p style={{ margin: '6px 0 0', fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--daisy-white)' }}>
                  {truckLines.length > 0
                    ? <><strong style={{ color: 'var(--growth-green)' }}>{truckLines.length} line{truckLines.length === 1 ? '' : 's'}</strong>
                        {' '}carry {num(truckUnits)} units ({zar(truckCost)}) already on their way and landing on or before this delivery.
                        {' '}<strong>This order was reduced by that stock.</strong></>
                    : staleLines.length > 0
                      ? <>No in-transit stock on this desk — <strong>every open document here is stale</strong> and none is counted.
                          A desk fed by inter-branch transfer legitimately carries none of its own; this states that rather than
                          showing an empty panel (§8.6 guard 4, no silent empties).</>
                      : <>No open orders at all on this desk, so nothing was reduced.</>}
                </p>
                {/* canon §14 v15 rule 5a -- counted, and SAID SO. */}
                {elapsedEst.length > 0 && (
                  <p style={{ margin: '4px 0 0', fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--core-yellow)' }}
                    title="The landing estimate is order_date + the route's median lead. By construction about half of genuine deliveries land after their own median, so a past estimate is NOT an exclusion test (canon §14 v15 rule 5a) — these are counted, and flagged so the buyer can chase them.">
                    <strong>{elapsedEst.length} of those</strong> ({num(elapsedUnits)} units) are past their landing ESTIMATE and are still counted —
                    the estimate is not an exclusion test, so chase them rather than assume they have arrived.
                  </p>
                )}
                {enRoute.length > 0 && (
                  <p style={{ margin: '4px 0 0', fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)' }}>
                    {enRoute.length} further line{enRoute.length === 1 ? '' : 's'} have stock en route landing AFTER this delivery — not counted, order not reduced.
                  </p>
                )}
                {staleLines.length > 0 && (
                  <p style={{ margin: '4px 0 0', fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--veld-mist)' }}>
                    {staleLines.length} line{staleLines.length === 1 ? '' : 's'} sit against stale open documents (oldest {staleOldest} days) — worklisted, never counted as in transit (canon §14 v15 rule 1).
                  </p>
                )}
              </div>
            )}

            {/* --- item 2: the promo floor gap worklist --- */}
            {gapRows.length > 0 && (
              <>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
                  <Label style={{ color: 'var(--data-warn)' }}>Promo floor gap</Label>
                  <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)' }}>
                    {gapRows.length} line{gapRows.length === 1 ? '' : 's'} below their promo floor · {gapPriority} HERO/KVI · {zar(gapRand)} to close
                  </span>
                  {/* v1.3 item C: a published figure carries the run that produced it.
                      The buy-in window and the drop cover both move with the delivery
                      date, so this total is meaningless without its parameters. */}
                  <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)', opacity: 0.8 }}>
                    {storeCode} · {desk} · delivery {deliveryDate} → next {nextDeliveryDate}
                  </span>
                  <div style={{ flex: 1 }} />
                  <button onClick={exportGap}
                    title="Export this worklist as CSV, cut from the quantities currently on screen."
                    style={{ fontFamily: 'var(--font-mono)', fontSize: 10, letterSpacing: '0.06em',
                      textTransform: 'uppercase', color: 'var(--daisy-white)', cursor: 'pointer',
                      background: 'rgba(255,179,0,0.14)', border: '1px solid var(--data-warn)',
                      borderRadius: 'var(--radius-chip)', padding: '6px 12px' }}>
                    Export worklist
                  </button>
                </div>
                <p style={{ margin: '5px 0 6px', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)', lineHeight: 1.5 }}>
                  The order was computed on each line&apos;s unlifted demand; the floor is its promo-lifted one (ENG-052, open — quantities are unchanged).
                </p>
                {/* ENG-054 -- WHAT THE GAP IS BUILT ON. Money you can bank, money that
                    is a floor, money that is a guess. Never one undifferentiated total. */}
                <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', margin: '0 0 9px',
                  fontFamily: 'var(--font-mono)', fontSize: 10 }}>
                  {['MEASURED', 'BORROWED', 'AT_CAP', 'SEED'].filter(k => randByConf[k]).map(k => (
                    <span key={k} title={UPLIFT_CONFIDENCE_TITLE[k]} style={{ color: UPLIFT_CONFIDENCE_COLOR[k] }}>
                      {UPLIFT_CONFIDENCE_WORD[k]} {zar(randByConf[k])}
                    </span>
                  ))}
                  {kviMeasuredRand > 0 && (
                    <span style={{ color: 'var(--growth-green)' }}>
                      · <strong>{zar(kviMeasuredRand)} of the HERO/KVI gap is measured</strong> — bankable without the model
                    </span>
                  )}
                  {gapCapped > 0 && (
                    <span style={{ color: 'var(--core-yellow)' }}>
                      · {gapCapped} at cap, so those gaps are a FLOOR, never a ceiling
                    </span>
                  )}
                </div>
                <div style={{ maxHeight: '30vh', overflow: 'auto' }}>
                  {gapRows.slice(0, 60).map(r => (
                    <div key={r.l.product_code} title={r.l.promo_gap_reason ?? undefined}
                      style={{ display: 'grid', gridTemplateColumns: '70px minmax(150px,1.6fr) 92px 74px 68px 68px 62px 82px',
                        gap: 0, padding: '6px 4px', borderBottom: '1px solid var(--hairline)',
                        fontFamily: 'var(--font-mono)', fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>
                      <span style={{ color: 'var(--veld-mist)' }}>{r.l.product_code}</span>
                      <span style={{ color: 'var(--daisy-white)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        {r.l.description}
                      </span>
                      <span style={{ color: r.pri === 1 ? 'var(--growth-green)' : r.pri <= 3 ? 'var(--core-yellow)' : 'var(--veld-mist)' }}>
                        {r.l.is_bt_hero ? 'HERO' : (r.l.kvi_band ?? '—').replace('KVI_', '')}
                      </span>
                      {/* the word, never a basis string (PM, BLOOM-018 v1.2 item 2) */}
                      <span title={UPLIFT_CONFIDENCE_TITLE[r.conf]}
                        style={{ color: UPLIFT_CONFIDENCE_COLOR[r.conf] ?? 'var(--veld-mist)' }}>
                        {UPLIFT_CONFIDENCE_WORD[r.conf] ?? '—'}
                      </span>
                      <span style={{ textAlign: 'right', color: 'var(--veld-mist)' }} title="position after this order">{num(r.posUnits)}</span>
                      <span style={{ textAlign: 'right', color: 'var(--veld-mist)' }} title="promo floor">{num(r.floor)}</span>
                      <span style={{ textAlign: 'right', color: 'var(--data-warn)' }}>+{r.shortPacks}</span>
                      <span style={{ textAlign: 'right', color: 'var(--daisy-white)' }}>{zar(r.shortRand)}</span>
                    </div>
                  ))}
                </div>
                {gapRows.length > 60 && (
                  <p style={{ margin: '6px 0 0', fontFamily: 'var(--font-mono)', fontSize: 9.5, color: 'var(--veld-mist)' }}>
                    Showing the top 60 of {gapRows.length} by priority then rand. The full list is `rpc_bloom_promo_floor_gap`.
                  </p>
                )}
              </>
            )}
          </GlassCard>
        )
      })()}

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

          {importReport && (
            <div style={{ margin: '0 24px', marginTop: 14, fontFamily: 'var(--font-mono)', fontSize: 10.5,
              color: importReport.fileError ? '#fca5a5' : 'var(--veld-mist)',
              background: importReport.fileError ? 'rgba(239,68,68,0.12)' : 'rgba(255,255,255,0.03)',
              border: `1px solid ${importReport.fileError ? 'rgba(239,68,68,0.35)' : 'var(--hairline)'}`,
              borderRadius: 8, padding: '8px 12px', lineHeight: 1.6 }}>
              {importReport.fileError ? importReport.fileError : (
                <>
                  Import "{importReport.fileName}": {importReport.changed} changed · {importReport.unchanged} unchanged
                  {' · '}{importReport.unknown.length} unknown code{importReport.unknown.length === 1 ? '' : 's'}
                  {' · '}{importReport.rejected.length} rejected row{importReport.rejected.length === 1 ? '' : 's'}
                  {importReport.unknown.length > 0 && <div style={{ marginTop: 4 }}>Unknown (not in this order, never added): {importReport.unknown.join(', ')}</div>}
                  {importReport.rejected.length > 0 && (
                    <div style={{ marginTop: 4 }}>
                      Rejected: {importReport.rejected.map(r => `${r.code} (${r.value || '—'}, ${r.reason})`).join(' · ')}
                    </div>
                  )}
                  {importReport.nameMismatch && <div style={{ marginTop: 4, color: 'var(--core-yellow)' }}>{importReport.nameMismatch}</div>}
                </>
              )}
            </div>
          )}

          {tlxReport && (
            <div style={{ margin: '0 24px', marginTop: 14, fontFamily: 'var(--font-mono)', fontSize: 10.5,
              color: tlxReport.error ? '#fca5a5' : (tlxReport.excluded?.length ? 'var(--core-yellow)' : 'var(--veld-mist)'),
              background: tlxReport.error ? 'rgba(239,68,68,0.12)' : 'rgba(255,255,255,0.03)',
              border: `1px solid ${tlxReport.error ? 'rgba(239,68,68,0.35)' : 'var(--hairline)'}`,
              borderRadius: 8, padding: '8px 12px', lineHeight: 1.6 }}>
              {tlxReport.error ? tlxReport.error : (
                <>
                  TLX: {tlxReport.exported} line{tlxReport.exported === 1 ? '' : 's'} written
                  {tlxReport.excluded.length > 0 && <> · <strong>{tlxReport.excluded.length} held back</strong> (Sigma cannot match the key -- order these by hand or fix the barcode at source)</>}
                  {tlxReport.excluded.length > 0 && (
                    <div style={{ marginTop: 4 }}>
                      {tlxReport.excluded.map(x => `${x.code} ${x.desc ?? ''} (${x.reason})`).join(' · ')}
                    </div>
                  )}
                </>
              )}
            </div>
          )}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 14,
            padding: '16px 24px', borderTop: '1px solid var(--glass-border)', flexWrap: 'wrap' }}>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--veld-mist)', flex: '1 1 200px' }}>
              {submitted ? 'Order locked.' : 'Edited cells ringed · # = count first · hover for story (R29)'}
            </span>
            <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
              <Button variant="solid" onClick={exportCsv}>StockFlow CSV</Button>
              <Button variant="solid" onClick={exportTlx}>TLX</Button>
              {isDcRoute && <Button variant="solid" onClick={exportPromoSheet}>Promo Sheet</Button>}
              <input ref={fileInputRef} type="file" accept=".csv,.xlsx" style={{ display: 'none' }} onChange={onImportFileChosen} />
              <Button variant="solid" onClick={() => fileInputRef.current?.click()} {...(submitted ? { disabled: true } : {})}>
                Import
              </Button>
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

  // ENG-031: same engine verdict as the desk exporter (rpc_bloom_export_eligibility).
  async function exportTlx() {
    const wanted = lines.filter(l => (qty[l.product_code] ?? 0) > 0)
    const { data, error: eligErr } = await supabase.rpc('rpc_bloom_export_eligibility', {
      p_store_code: storeCode, p_product_codes: wanted.map(l => Number(l.product_code)),
    })
    if (eligErr) { window.alert(`Export blocked -- could not read export eligibility: ${eligErr.message}`); return }
    const elig = new Map((data ?? []).map(r => [Number(r.product_code), r]))
    const parts = []
    const excluded = []
    for (const l of wanted) {
      const q = qty[l.product_code] ?? 0
      const e = elig.get(Number(l.product_code))
      if (!e || !e.export_eligible) { excluded.push(`${l.product_code} ${l.description ?? ''} (${e?.ineligible_reason ?? 'no engine identity row'})`); continue }
      const units = q * (l.pack_size ?? 1)
      parts.push(`${e.export_key}+${units}`)
    }
    if (excluded.length) {
      window.alert(`TLX: ${parts.length} lines written, ${excluded.length} held back -- Sigma cannot match the key.\nOrder these by hand or fix the barcode at source:\n\n${excluded.join('\n')}`)
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
              { value: 'desk', label: 'SAB Direct (beer)' },
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
