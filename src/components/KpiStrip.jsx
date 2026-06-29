'use client'

// Verdict Wall KPI strip — Pulse design system.
// Presentational: all data arrives as props from page.jsx (no Supabase calls here).
//
// cards prop: Array<{
//   key:       string,
//   label:     string,
//   value:     string,
//   tone:      'pos' | 'neg' | 'warn' | 'neutral',
//   sparkline: number[] | null,
//   chips:     Array<{ t: string, k: 'pos' | 'neg' | 'warn' | 'mute' }>,
//   meta:      string | null,   -- faint reference line (bench / LY ref)
//   sub:       string | null,   -- faint descriptor line
//   edge:      'green' | 'blue' | 'red' | 'amber' | null,
//   onClick:   function | undefined,
//   tooltip:   object | undefined,
// }>

const TONE_COLOR = {
  pos:     'var(--data-pos)',
  neg:     'var(--data-neg)',
  warn:    'var(--data-warn)',
  neutral: 'var(--daisy-white)',
}

const CHIP_STYLE = {
  pos:  { color: 'var(--data-pos)',   background: 'rgba(102,187,106,0.13)' },
  neg:  { color: 'var(--data-neg)',   background: 'rgba(239,83,80,0.13)'   },
  warn: { color: 'var(--data-warn)',  background: 'rgba(255,179,0,0.13)'   },
  mute: { color: 'var(--veld-mist)',  background: 'rgba(255,255,255,0.05)' },
}

function VwSpark({ values, tone }) {
  if (!values || values.length < 2) return null
  const w = 150, h = 26
  const max = Math.max(...values), min = Math.min(...values)
  const range = (max - min) || 1
  const pts = values.map((p, i) =>
    `${((i / (values.length - 1)) * w).toFixed(1)},${(h - ((p - min) / range) * h).toFixed(1)}`
  ).join(' ')
  const color = tone === 'neutral' ? 'var(--data-neutral)' : (TONE_COLOR[tone] ?? 'rgba(245,245,244,0.25)')
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none"
      style={{ display: 'block', margin: '2px 0' }}>
      <polyline points={pts} fill="none" stroke={color} strokeWidth="2"
        strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
    </svg>
  )
}

function VwChip({ t, k = 'mute' }) {
  const s = CHIP_STYLE[k] ?? CHIP_STYLE.mute
  return (
    <span style={{
      fontFamily: "'Geist Mono', monospace", fontSize: 10, padding: '2px 7px',
      borderRadius: 'var(--radius-chip)', fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap', lineHeight: 1.5, ...s,
    }}>{t}</span>
  )
}

export default function KpiStrip({ loading, cards = [], onTooltip, onTooltipClear }) {
  if (loading) return (
    <div className="sb-kpi-strip">
      {Array.from({ length: 5 }, (_, i) => (
        <div key={i} className="sb-glass sb-edge sb-frost-veil" data-loading="true"
          style={{ padding: '18px 20px', '--d': `${i * 80}ms` }} />
      ))}
    </div>
  )

  return (
    <div className="sb-kpi-strip">
      {cards.map((k, idx) => (
        <div key={k.key}
          className={`sb-glass sb-edge sb-unfrost sb-frost-veil${k.edge ? ` sb-edge-${k.edge}` : ''}`}
          data-loading="false"
          onClick={k.onClick}
          onMouseEnter={k.tooltip && onTooltip ? (e) => {
            const rect = e.currentTarget.getBoundingClientRect()
            onTooltip(k.key, { ...k.tooltip, edgeColor: k.edge }, rect)
          } : undefined}
          onMouseLeave={k.tooltip && onTooltipClear ? onTooltipClear : undefined}
          style={{ padding: '18px 20px', position: 'relative', cursor: k.onClick ? 'pointer' : 'default', '--d': `${idx * 80}ms` }}>

          <p style={{
            fontSize: 10, fontFamily: "'Geist Mono', monospace", textTransform: 'uppercase',
            letterSpacing: '0.12em', color: 'var(--veld-mist)', marginBottom: 8,
          }}>{k.label}</p>

          <p className="sb-kpi-num" style={{ color: TONE_COLOR[k.tone] ?? undefined }}>
            {k.value}
          </p>

          {k.sparkline && <VwSpark values={k.sparkline} tone={k.tone} />}

          {k.chips?.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center', marginTop: 6 }}>
              {k.chips.map((c, ci) => <VwChip key={ci} t={c.t} k={c.k} />)}
            </div>
          )}

          {k.meta && (
            <p style={{
              fontFamily: "'Geist Mono', monospace", fontSize: 10, color: 'rgba(245,245,244,0.25)',
              fontVariantNumeric: 'tabular-nums', marginTop: 5,
            }}>{k.meta}</p>
          )}

          {k.sub && (
            <p style={{
              fontFamily: "'Geist Mono', monospace", fontSize: 10.5, fontVariantNumeric: 'tabular-nums',
              color: k.onClick ? 'rgba(249,251,247,0.75)' : 'rgba(245,245,244,0.35)',
              textDecoration: k.onClick ? 'underline' : 'none', marginTop: 3,
            }}>{k.sub}</p>
          )}
        </div>
      ))}
    </div>
  )
}
