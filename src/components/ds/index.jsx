'use client'
// =============================================================================
// SocialBrand Pulse Design System -- ported components (SB-CC-BLOOM-001)
//
// Faithfully ported from CD's compiled bundle
// (SocialBrandPulseDesignSystem_02dcc236-4a58-49d2-bc81-69c8f9965d8b), which
// the CD-SPEC-BLOOM-001 Bloom.dc.html prototype loads at runtime. That bundle
// is a design-system deliverable, not live app code (CLAUDE.md: "CC never
// touches CD's design-system project files") -- these are proper React
// source files under CC's own component tree, behaviourally identical to the
// bundle's components, using the token names added to dashboard.css.
//
// Only the components Bloom actually uses are ported: Button, Chip,
// DateButton, SegmentedControl, GlassCard, KpiCard, DataTable, DataValue,
// DeltaBadge. TrendChart/ChartLegend/Slider/Tab/Toggle/VerdictBadge are not
// needed here and were left out.
// =============================================================================

import { useState, useRef, useCallback, useLayoutEffect, useEffect } from 'react'

// ── Button — 'ghost' | 'subtle' | 'solid' | 'daisy'. daisy = the ONE primary
// action per view (core-yellow fill, lifts + gold glow on hover). ──────────
export function Button({ children, label, variant = 'ghost', size = 'md', onClick, style, ...rest }) {
  const [hover, setHover] = useState(false)
  const [press, setPress] = useState(false)
  const pad = size === 'sm' ? '5px 12px' : '9px 18px'
  const fs = size === 'sm' ? 11 : 13
  const variants = {
    ghost: {
      fontFamily: 'var(--font-ui)', fontWeight: 500,
      color: hover ? 'var(--daisy-white)' : 'rgba(245,245,244,0.5)',
      background: hover ? 'rgba(255,255,255,0.09)' : 'rgba(255,255,255,0.05)',
      border: '1px solid var(--glass-border)',
    },
    subtle: {
      fontFamily: 'var(--font-ui)', fontWeight: 500,
      color: hover ? 'var(--daisy-white)' : 'rgba(245,245,244,0.7)',
      background: hover ? 'rgba(255,255,255,0.07)' : 'rgba(255,255,255,0.04)',
      border: '1px solid var(--glass-border-hover)',
    },
    solid: {
      fontFamily: 'var(--font-ui)', fontWeight: 600, color: 'var(--daisy-white)',
      background: hover ? '#56795f' : 'var(--growth-green)', border: '1px solid var(--growth-green)',
    },
    daisy: {
      fontFamily: 'var(--font-display)', fontWeight: 600, color: 'var(--charcoal-veld)',
      background: 'var(--core-yellow)', border: '1px solid var(--core-yellow)',
      boxShadow: hover && !press ? '0 4px 16px rgba(255,209,0,0.25)' : 'none',
    },
  }
  const lifts = variant === 'daisy' || variant === 'solid'
  const v = variants[variant] || variants.ghost
  return (
    <button type="button" onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setPress(false) }}
      onMouseDown={() => setPress(true)}
      onMouseUp={() => setPress(false)}
      style={{
        fontSize: fs, padding: pad, borderRadius: size === 'sm' ? 6 : 'var(--radius-chip)',
        cursor: 'pointer',
        transition: 'transform var(--hover-duration), box-shadow var(--hover-duration), background var(--hover-duration), color var(--hover-duration)',
        transform: lifts && hover && !press ? 'translateY(-1px)' : 'translateY(0)',
        ...v, ...style,
      }} {...rest}>
      {children ?? label}
    </button>
  )
}

// ── Chip — pill filter (store selector). Active = green wash + yellow underline. ──
export function Chip({ children, active = false, onClick, style, ...rest }) {
  const [hover, setHover] = useState(false)
  return (
    <button type="button" onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        fontFamily: 'var(--font-ui)', fontSize: 12, fontWeight: active ? 500 : 400,
        padding: '6px 14px', borderRadius: 'var(--radius-pill)', cursor: 'pointer', whiteSpace: 'nowrap',
        transition: 'all var(--hover-duration)',
        color: active ? 'var(--daisy-white)' : hover ? 'var(--daisy-white)' : 'rgba(245,245,244,0.6)',
        background: active ? 'rgba(74,107,83,0.18)' : hover ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.05)',
        border: `1px solid ${active ? 'var(--glass-border-hover)' : 'var(--glass-border)'}`,
        boxShadow: active ? 'inset 0 -2px 0 var(--core-yellow)' : 'none',
        ...style,
      }} {...rest}>
      {children}
    </button>
  )
}

// ── DateButton — mono date-selector pill. ──────────────────────────────────
export function DateButton({ children, active = false, onClick, style, ...rest }) {
  const [hover, setHover] = useState(false)
  return (
    <button type="button" onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        fontFamily: 'var(--font-mono)', fontSize: 12, fontWeight: active ? 600 : 400,
        padding: '8px 14px', minWidth: 96, textAlign: 'center', borderRadius: 'var(--radius-md)',
        cursor: 'pointer', flexShrink: 0, transition: 'all var(--hover-duration)',
        color: active ? 'var(--daisy-white)' : hover ? 'var(--daisy-white)' : 'rgba(245,245,244,0.55)',
        background: active ? 'linear-gradient(135deg, rgba(74,107,83,0.35), rgba(74,107,83,0.14))' : hover ? 'rgba(255,255,255,0.07)' : 'rgba(255,255,255,0.04)',
        border: `1px solid ${active ? 'rgba(74,107,83,0.65)' : 'var(--glass-border)'}`,
        boxShadow: active ? '0 4px 14px rgba(0,0,0,0.20)' : 'none',
        ...style,
      }} {...rest}>
      {children}
    </button>
  )
}

// ── SegmentedControl — recessed track, thumb glides under the active option. ──
export function SegmentedControl({ options = [], value, onChange, size = 'md', style, ...rest }) {
  const pad = size === 'sm' ? '5px 13px' : '7px 18px'
  const fs = size === 'sm' ? 12 : 13
  const trackRef = useRef(null)
  const btnRefs = useRef({})
  const [thumb, setThumb] = useState(null)
  const measure = useCallback(() => {
    const track = trackRef.current
    const el = btnRefs.current[value]
    if (!track || !el) { setThumb(null); return }
    const t = track.getBoundingClientRect()
    const r = el.getBoundingClientRect()
    setThumb({ left: r.left - t.left, width: r.width })
  }, [value])
  useLayoutEffect(() => { measure() }, [measure, options, size])
  useEffect(() => {
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [measure])
  return (
    <div ref={trackRef} role="tablist" style={{
      position: 'relative', display: 'inline-flex', gap: 2, padding: 4, borderRadius: 'var(--radius-md)',
      background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(0,0,0,0.32)', boxShadow: 'var(--well-shadow)',
      ...style,
    }} {...rest}>
      {thumb && (
        <div aria-hidden="true" style={{
          position: 'absolute', top: 4, bottom: 4, left: thumb.left, width: thumb.width, borderRadius: 9,
          background: 'linear-gradient(180deg, rgba(255,255,255,0.12), rgba(255,255,255,0.02))',
          boxShadow: 'var(--key-shadow)',
          transition: 'left 260ms cubic-bezier(0.34, 1.28, 0.42, 1), width 260ms cubic-bezier(0.34, 1.28, 0.42, 1)',
          pointerEvents: 'none',
        }} />
      )}
      {options.map(opt => {
        const v = typeof opt === 'object' ? opt.value : opt
        const label = typeof opt === 'object' ? opt.label : opt
        const active = v === value
        return (
          <button key={v} type="button" role="tab" aria-selected={active}
            ref={el => { if (el) btnRefs.current[v] = el }}
            onClick={() => onChange && onChange(v)}
            style={{
              position: 'relative', zIndex: 1, fontFamily: 'var(--font-ui)', fontSize: fs,
              fontWeight: active ? 600 : 500, padding: pad, border: 'none', borderRadius: 9,
              cursor: 'pointer', whiteSpace: 'nowrap', background: 'transparent', boxShadow: 'none',
              transition: 'color var(--hover-duration)',
              color: active ? 'var(--daisy-white)' : 'rgba(245,245,244,0.5)',
            }}>
            {label}
          </button>
        )
      })}
    </div>
  )
}

// ── GlassCard — resting liquid-glass panel with optional Fraunces title + mono meta. ──
export function GlassCard({ title, meta, action, children, style, ...rest }) {
  return (
    <section style={{
      position: 'relative',
      background: 'linear-gradient(180deg, rgba(255,255,255,0.07), rgba(255,255,255,0) 16%), var(--glass-tint-rest)',
      border: '1px solid var(--glass-border)', borderRadius: 'var(--radius-card)',
      backdropFilter: 'blur(var(--glass-blur-rest)) saturate(140%)',
      WebkitBackdropFilter: 'blur(var(--glass-blur-rest)) saturate(140%)',
      boxShadow: 'var(--glass-bevel-shadow)', padding: '20px 24px', minWidth: 0,
      ...style,
    }} {...rest}>
      {(title || action) && (
        <header style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, marginBottom: children ? 16 : 0 }}>
          <div>
            {title && <h3 style={{ fontFamily: 'var(--font-display)', fontSize: 'var(--type-h3)', fontWeight: 'var(--weight-semi)', color: 'var(--daisy-white)', margin: 0 }}>{title}</h3>}
            {meta && <p style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--type-meta)', color: 'var(--text-faint)', margin: '4px 0 0' }}>{meta}</p>}
          </div>
          {action}
        </header>
      )}
      {children}
    </section>
  )
}

// ── KpiCard — hero metric tile. Fraunces tabular numeral, mono label. ──────
export function KpiCard({ label, value, sub, tone = 'default', style, ...rest }) {
  const toneColor = {
    default: 'var(--daisy-white)', pos: 'var(--data-pos)', neg: 'var(--data-neg)',
    warn: 'var(--data-warn)', neutral: 'var(--data-neutral)',
  }[tone] || 'var(--daisy-white)'
  return (
    <div style={{ padding: '16px 18px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 8, ...style }} {...rest}>
      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--type-label)', textTransform: 'uppercase', letterSpacing: 'var(--label-tracking)', color: 'var(--veld-mist)' }}>{label}</span>
      <span style={{ fontFamily: 'var(--font-display)', fontSize: 'var(--kpi-number)', fontWeight: 'var(--weight-bold)', fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.01em', lineHeight: 1, color: toneColor }}>{value}</span>
      {sub != null && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--type-meta)', color: 'var(--text-faint)' }}>{sub}</span>}
    </div>
  )
}

// ── DataValue — single tabular figure with tone + optional trend arrow. ────
export function DataValue({ value, tone = 'neutral', trend, display = false, size, style, ...rest }) {
  const toneColor = { pos: 'var(--data-pos)', neg: 'var(--data-neg)', warn: 'var(--data-warn)', neutral: 'var(--text-muted)', mute: 'var(--text-faint)' }[tone] || 'var(--text-muted)'
  const arrow = trend === 'up' ? '▲' : trend === 'down' ? '▼' : null
  return (
    <span style={{
      fontFamily: display ? 'var(--font-display)' : 'var(--font-mono)', fontVariantNumeric: 'tabular-nums',
      fontWeight: display ? 'var(--weight-bold)' : 'var(--weight-medium)', fontSize: size || (display ? '24px' : 'var(--type-data)'),
      color: toneColor, display: 'inline-flex', alignItems: 'baseline', gap: 4,
      letterSpacing: display ? '-0.01em' : 'normal', ...style,
    }} {...rest}>
      {arrow && <span aria-hidden="true" style={{ fontSize: '0.7em' }}>{arrow}</span>}
      {value}
    </span>
  )
}

// ── DataTable — dense table. Uppercased mono headers, zebra, tabular figures. ──
export function DataTable({ columns = [], rows = [], total, style, ...rest }) {
  const toneColor = { pos: 'var(--data-pos)', neg: 'var(--data-neg)', warn: 'var(--data-warn)', mute: 'var(--text-faint)' }
  const cellFont = c => c.mono ? 'var(--font-mono)' : 'var(--font-ui)'
  return (
    <div style={{ overflowX: 'auto', minWidth: 0 }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 'var(--type-data)', tableLayout: 'auto', ...style }} {...rest}>
        <thead>
          <tr>
            {columns.map(c => (
              <th key={c.key} style={{
                padding: '9px 10px', background: 'rgba(18,22,18,0.92)', position: 'sticky', top: 0, zIndex: 2,
                fontFamily: 'var(--font-mono)', fontWeight: 500, fontSize: 9.5, color: 'var(--veld-mist)',
                textTransform: 'uppercase', letterSpacing: '0.08em', textAlign: c.align === 'right' ? 'right' : 'left', whiteSpace: 'nowrap',
              }}>{c.label}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={row.key ?? i} style={{ background: i % 2 ? 'rgba(255,255,255,0.03)' : 'transparent' }}>
              {columns.map(c => {
                const val = c.render ? c.render(row[c.key], row) : row[c.key]
                const tone = c.tone ? c.tone(row) : null
                return (
                  <td key={c.key} style={{
                    padding: '7px 10px', borderBottom: '1px solid rgba(255,255,255,0.03)', fontFamily: cellFont(c),
                    fontVariantNumeric: c.mono ? 'tabular-nums' : 'normal', textAlign: c.align === 'right' ? 'right' : 'left',
                    color: tone ? toneColor[tone] : c.emphasis ? 'var(--daisy-white)' : 'rgba(245,245,244,0.65)',
                    whiteSpace: 'nowrap', maxWidth: 220, overflow: 'hidden', textOverflow: 'ellipsis',
                  }}>{val}</td>
                )
              })}
            </tr>
          ))}
          {total && (
            <tr style={{ borderTop: '2px solid var(--glass-border)', fontWeight: 600 }}>
              {columns.map((c, ci) => (
                <td key={c.key} style={{
                  padding: '9px 10px', fontFamily: cellFont(c), fontVariantNumeric: c.mono ? 'tabular-nums' : 'normal',
                  textAlign: c.align === 'right' ? 'right' : 'left', color: 'var(--daisy-white)',
                }}>{total[c.key] ?? (ci === 0 ? 'Total' : '')}</td>
              ))}
            </tr>
          )}
        </tbody>
      </table>
    </div>
  )
}

// ── DeltaBadge — reconciliation badge (ok/amber/red). ──────────────────────
export function DeltaBadge({ children, level = 'ok', title, style, ...rest }) {
  const levels = {
    ok: { color: 'rgba(245,245,244,0.30)', background: 'transparent', border: '1px solid transparent' },
    amber: { color: '#fbbf24', background: 'rgba(245,127,23,0.12)', border: '1px solid rgba(245,127,23,0.30)' },
    red: { color: '#fca5a5', background: 'rgba(198,40,40,0.14)', border: '1px solid rgba(198,40,40,0.35)' },
  }
  return (
    <span title={title} style={{
      display: 'inline-flex', alignItems: 'center', fontFamily: 'var(--font-mono)', fontSize: 9.5,
      fontVariantNumeric: 'tabular-nums', borderRadius: 5, padding: '2px 5px', cursor: title ? 'help' : 'default',
      ...levels[level], ...style,
    }} {...rest}>
      {children}
    </span>
  )
}
