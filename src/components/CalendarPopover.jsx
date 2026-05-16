'use client'
import { useState, useMemo, useRef, useEffect } from 'react'

const MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December']
const DAY_LABELS  = ['Su','Mo','Tu','We','Th','Fr','Sa']

export function CalendarPopover({ availableDates, selectedDates, onChange, onClose, anchorRef }) {
  const newest   = availableDates[0] ?? ''
  const [yr, setYr] = useState(() => newest ? +newest.slice(0, 4) : new Date().getFullYear())
  const [mo, setMo] = useState(() => newest ? +newest.slice(5, 7) : new Date().getMonth() + 1)
  const popRef   = useRef(null)
  const lastHit  = useRef(null)

  const availSet = useMemo(() => new Set(availableDates), [availableDates])
  const selSet   = useMemo(() => new Set(selectedDates),  [selectedDates])

  // Close on click outside (skip the trigger anchor so its own toggle handler wins)
  useEffect(() => {
    function down(e) {
      const inPop     = popRef.current?.contains(e.target)
      const inAnchor  = anchorRef?.current?.contains(e.target)
      if (!inPop && !inAnchor) onClose()
    }
    document.addEventListener('mousedown', down)
    return () => document.removeEventListener('mousedown', down)
  }, [onClose, anchorRef])

  const prefix     = `${yr}-${String(mo).padStart(2, '0')}`
  const monthAvail = useMemo(() => availableDates.filter(d => d.startsWith(prefix)), [availableDates, prefix])
  const firstDow   = new Date(yr, mo - 1, 1).getDay()
  const daysInMo   = new Date(yr, mo, 0).getDate()
  const allMoSel   = monthAvail.length > 0 && monthAvail.every(d => selSet.has(d))

  const cells = useMemo(() => {
    const out = Array(firstDow).fill(null)
    for (let d = 1; d <= daysInMo; d++)
      out.push(`${prefix}-${String(d).padStart(2, '0')}`)
    return out
  }, [prefix, firstDow, daysInMo])

  function goBack() {
    if (mo === 1) { setYr(y => y - 1); setMo(12) } else { setMo(m => m - 1) }
  }
  function goFwd() {
    if (mo === 12) { setYr(y => y + 1); setMo(1) } else { setMo(m => m + 1) }
  }

  function toggleDay(iso, shift) {
    if (!availSet.has(iso)) return
    if (shift && lastHit.current && availSet.has(lastHit.current)) {
      const a = availableDates.indexOf(lastHit.current)
      const b = availableDates.indexOf(iso)
      const [lo, hi] = [Math.min(a, b), Math.max(a, b)]
      const range = availableDates.slice(lo, hi + 1)
      onChange(prev => [...new Set([...prev, ...range])])
    } else {
      onChange(prev =>
        prev.includes(iso) && prev.length > 1
          ? prev.filter(d => d !== iso)
          : [...new Set([...prev, iso])]
      )
    }
    lastHit.current = iso
  }

  function toggleMonth() {
    if (allMoSel) {
      onChange(prev => {
        const next = prev.filter(d => !monthAvail.includes(d))
        return next.length ? next : [availableDates[0]]
      })
    } else {
      onChange(prev => [...new Set([...prev, ...monthAvail])])
    }
  }

  function pickLatest() { onChange([availableDates[0]]); onClose() }

  const btn = {
    fontFamily: 'Geist, sans-serif', fontSize: 11,
    background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.1)',
    borderRadius: 6, color: 'rgba(245,245,244,0.7)', cursor: 'pointer', padding: '5px 10px',
  }

  return (
    <div ref={popRef} style={{
      position: 'absolute', top: 'calc(100% + 8px)', right: 0, zIndex: 200,
      background: 'rgba(10,14,26,0.98)', border: '1px solid rgba(255,255,255,0.13)',
      borderRadius: 14, padding: 16, width: 272,
      boxShadow: '0 24px 64px rgba(0,0,0,0.65)',
      backdropFilter: 'blur(24px)',
    }}>

      {/* Month navigation */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <button onClick={goBack} style={{ ...btn, padding: '4px 10px' }}>‹</button>
        <div style={{ textAlign: 'center' }}>
          <button onClick={toggleMonth} style={{
            background: 'none', border: 'none', cursor: 'pointer',
            fontFamily: 'Fraunces, Georgia, serif', fontWeight: 600, fontSize: 14,
            color: allMoSel ? '#4ade80' : '#f5f5f4', padding: '2px 4px', borderRadius: 4,
          }}>
            {MONTH_NAMES[mo - 1]} {yr}
          </button>
          <p style={{ fontSize: 9, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 1 }}>
            {monthAvail.length} snapshot{monthAvail.length !== 1 ? 's' : ''} · click to {allMoSel ? 'deselect' : 'select all'}
          </p>
        </div>
        <button onClick={goFwd} style={{ ...btn, padding: '4px 10px' }}>›</button>
      </div>

      {/* Weekday headers */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2, marginBottom: 3 }}>
        {DAY_LABELS.map(d => (
          <div key={d} style={{ textAlign: 'center', fontSize: 9, color: 'rgba(245,245,244,0.3)', padding: '2px 0' }}>{d}</div>
        ))}
      </div>

      {/* Day cells */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2 }}>
        {cells.map((iso, i) => {
          if (!iso) return <div key={`e${i}`} />
          const day   = +iso.slice(8)
          const avail = availSet.has(iso)
          const sel   = selSet.has(iso)
          return (
            <button key={iso} disabled={!avail}
              onClick={e => toggleDay(iso, e.shiftKey)}
              title={avail ? iso : undefined}
              style={{
                padding: '6px 0', fontSize: 11, textAlign: 'center', border: 'none',
                borderRadius: 5, cursor: avail ? 'pointer' : 'default',
                background: sel ? '#4ade80' : avail ? 'rgba(255,255,255,0.07)' : 'transparent',
                color: sel ? '#0a0e1a' : avail ? '#f5f5f4' : 'rgba(245,245,244,0.18)',
                fontWeight: sel ? 700 : 400,
                outline: sel ? '2px solid rgba(74,222,128,0.4)' : 'none',
                outlineOffset: 1,
              }}>
              {day}
            </button>
          )
        })}
      </div>

      {/* Footer */}
      <div style={{ display: 'flex', gap: 6, marginTop: 12, paddingTop: 10, borderTop: '1px solid rgba(255,255,255,0.07)' }}>
        <button onClick={pickLatest} style={{ ...btn, flex: 1 }}>Latest only</button>
        <button onClick={onClose} style={{ ...btn, flex: 1, background: 'rgba(74,222,128,0.12)', borderColor: 'rgba(74,222,128,0.25)', color: '#4ade80' }}>
          Done · {selectedDates.length}d
        </button>
      </div>
    </div>
  )
}
