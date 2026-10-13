'use client'
// =============================================================================
// StoredOverview -- the scenario cards on every desk, from STORED facts.
// SB-CC-BLOOM-035 item 9 = SB-CC-BLOOM-034 Part 1 + the weekly verdict (Pieter).
//
// This component renders what rpc_bloom_stored_overview returns and computes
// nothing (R21, R32 section 3). The figures are summed server-side from the orders the
// night job stored: value = sum(suggested_packs * pack_cost). No recipe runs from the
// page and no call goes to rpc_bloom_scenario_overview.
//
//   Full need  = standard order, fit off.       Fitted = standard order, fit on.
//   Order Essentials and Catch-up get no card until they are stored (SB-CC-BLOOM-032
//   Phase 1 item 2): 0 of each exist in bloom_order_cache today.
//
// HELD is not FAILED (the ENG-097 rule): a card with nothing stored says so in mist,
// never in red. Red is reserved for a read that actually broke.
// =============================================================================

import { zar } from '@/lib/format'

const MONO = { fontFamily: 'var(--font-mono)' }

function isoToDmy(iso) {
  if (!iso) return null
  const m = String(iso).slice(0, 10).split('-')
  return m.length === 3 ? `${m[2]}-${m[1]}-${m[0]}` : String(iso)
}

function builtAt(ts) {
  if (!ts) return null
  const d = new Date(ts)
  if (isNaN(d)) return null
  const pad = n => String(n).padStart(2, '0')
  return `${pad(d.getDate())}-${pad(d.getMonth() + 1)}-${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

const CARD_TITLE = { full: 'Full need', fitted: 'Fitted to budget' }
const CARD_SUB = {
  full: 'Standard order, fit off. The whole pool at per-line minimums, no money limit.',
  fitted: 'Standard order, fit on. Full need after the budget fit, protected lines whole.',
}

function Card({ c }) {
  const box = {
    padding: '10px 12px', borderRadius: 'var(--radius-chip)',
    border: '1px solid var(--hairline)', background: 'rgba(255,255,255,0.02)',
  }
  const title = (
    <div style={{ ...MONO, fontSize: 9, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--veld-mist)' }}>
      {CARD_TITLE[c.card] ?? c.card}
    </div>
  )
  if (!c.found) {
    return (
      <div style={box}>
        {title}
        <div style={{ ...MONO, fontSize: 11, color: 'var(--veld-mist)', marginTop: 6, lineHeight: 1.45 }}>
          {c.message ?? 'No stored order for these dates.'}
        </div>
      </div>
    )
  }
  const normal = Number(c.value) - Number(c.promo_value ?? 0)
  return (
    <div style={box}>
      {title}
      <div style={{ ...MONO, fontSize: 15, color: 'var(--daisy-white)', marginTop: 2 }}>{zar(c.value)}</div>
      <div style={{ ...MONO, fontSize: 9.5, color: 'var(--veld-mist)', marginTop: 3, lineHeight: 1.4 }}>{CARD_SUB[c.card]}</div>
      <div style={{ ...MONO, fontSize: 10, color: 'var(--veld-mist)', marginTop: 4 }}>
        {c.lines} lines on the order
      </div>
      {c.promo_share_pct != null && (
        <div style={{ ...MONO, fontSize: 10.5, marginTop: 3, color: 'var(--data-warn)' }}>
          {c.promo_share_pct}% promotional
          <span style={{ color: 'var(--veld-mist)' }}> · {zar(c.promo_value)} promo / {zar(normal)} normal</span>
        </div>
      )}
      <div style={{ ...MONO, fontSize: 10, color: 'var(--veld-mist)', marginTop: 3 }}>
        {c.kept_whole} kept whole · {c.cut_lines} cut
        {Number(c.cut_lines) > 0 && ` (${zar(c.cut_value)} off)`}
      </div>
      <div style={{ ...MONO, fontSize: 9, color: 'var(--veld-mist)', opacity: 0.8, marginTop: 4 }}>
        Stored order built {builtAt(c.generated_at) ?? '—'}
      </div>
      {c.engine_current === false && (
        <div style={{ ...MONO, fontSize: 9.5, color: 'var(--data-warn)', marginTop: 3 }}>
          Built by an earlier version of the recipe. It is rebuilt at 01:30.
        </div>
      )}
    </div>
  )
}

const VERDICT_STYLE = {
  FLAG:          { color: 'var(--data-warn)', border: '1px solid rgba(245,158,11,0.45)', background: 'rgba(245,158,11,0.10)', label: 'FLAG' },
  WITHIN:        { color: 'var(--data-pos)',  border: '1px solid var(--hairline)',       background: 'rgba(255,255,255,0.02)', label: 'WITHIN' },
  EXEMPT:        { color: 'var(--veld-mist)', border: '1px solid var(--hairline)',       background: 'rgba(255,255,255,0.02)', label: 'EXEMPT' },
  NOT_JUDGEABLE: { color: 'var(--veld-mist)', border: '1px solid var(--hairline)',       background: 'rgba(255,255,255,0.02)', label: 'NOT JUDGED' },
  NO_BASIS:      { color: 'var(--veld-mist)', border: '1px solid var(--hairline)',       background: 'rgba(255,255,255,0.02)', label: 'NO BASIS' },
}

function Benchmark({ data }) {
  const b = data.benchmark ?? {}
  const box = {
    padding: '10px 12px', borderRadius: 'var(--radius-chip)',
    border: '1px solid var(--hairline)', background: 'rgba(255,255,255,0.02)',
  }
  return (
    <div style={box}>
      <div style={{ ...MONO, fontSize: 9, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--veld-mist)' }}>
        Route’s weekly demand
      </div>
      {b.weekly_demand != null ? (
        <>
          <div style={{ ...MONO, fontSize: 15, color: 'var(--daisy-white)', marginTop: 2 }}>{zar(b.weekly_demand)}</div>
          <div style={{ ...MONO, fontSize: 9.5, color: 'var(--veld-mist)', marginTop: 3, lineHeight: 1.4 }}>
            One week of sales at cost for this desk’s departments, to {isoToDmy(b.anchor_date)}.
          </div>
          <div style={{ ...MONO, fontSize: 10, color: 'var(--veld-mist)', marginTop: 4 }}>
            This order covers {data.drop_cover_days ?? '—'} days, one drop. The demand is one week.
          </div>
        </>
      ) : (
        <div style={{ ...MONO, fontSize: 11, color: 'var(--veld-mist)', marginTop: 6, lineHeight: 1.45 }}>
          {b.note ?? 'No basis is ruled for this desk. Nothing is invented.'}
        </div>
      )}
    </div>
  )
}

function WeekVerdict({ week }) {
  if (!week) return null
  const st = VERDICT_STYLE[week.verdict] ?? VERDICT_STYLE.NOT_JUDGEABLE
  return (
    <div style={{ marginTop: 10, padding: '10px 12px', borderRadius: 'var(--radius-chip)', border: st.border, background: st.background }}>
      <div style={{ ...MONO, fontSize: 9, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--veld-mist)' }}>
        The week’s verdict
        <span style={{ marginLeft: 8, color: st.color }}>{st.label}</span>
        {week.deviation_pct != null && (
          <span style={{ marginLeft: 8, color: st.color }}>
            {Number(week.deviation_pct) > 0 ? '+' : ''}{week.deviation_pct}% against the week’s demand
          </span>
        )}
      </div>
      <div style={{ ...MONO, fontSize: 11, color: 'var(--daisy-white)', marginTop: 4, lineHeight: 1.5 }}>{week.reason}</div>
      {week.week_value != null && (
        <div style={{ ...MONO, fontSize: 9.5, color: 'var(--veld-mist)', marginTop: 4, lineHeight: 1.45 }}>
          Drop {week.drop_index} of {week.drops_total}, week of {isoToDmy(week.budget_week_start)}.
          {week.week_needs_budget != null && ` Needs budget for the week on the ledger: ${zar(week.week_needs_budget)}.`}
          {` cash_constrained is ${week.cash_constrained ? 'true' : 'false'} on this week’s row`}
          {week.cash_constrained ? ', so the week is exempt.' : ' (ENG-111: nothing writes it yet, so the exemption cannot apply).'}
        </div>
      )}
    </div>
  )
}

export default function StoredOverview({ data, loading, error }) {
  if (error) {
    return <p style={{ ...MONO, fontSize: 11, color: '#fca5a5', margin: 0 }}>Could not read the stored orders: {error}</p>
  }
  if (!data) {
    return (
      <p style={{ ...MONO, fontSize: 11, color: 'var(--veld-mist)', margin: 0 }}>
        {loading ? 'Reading the stored orders …' : 'Pick a store, a desk and the delivery dates.'}
      </p>
    )
  }
  return (
    <>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 10 }}>
        {(data.cards ?? []).map(c => <Card key={c.card} c={c} />)}
        <Benchmark data={data} />
      </div>
      <WeekVerdict week={data.week} />
      <p style={{ margin: '10px 0 0', ...MONO, fontSize: 9.5, color: 'var(--veld-mist)', lineHeight: 1.5 }}>
        Read from the orders stored by the night job. No recipe runs here and no quantity moves.
        The verdict compares the week’s orders together with the week’s demand, never one order with a week.
        It flags and never blocks. Order Essentials and Catch-up show no card until they are stored.
      </p>
    </>
  )
}
