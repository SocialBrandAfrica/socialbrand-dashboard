'use client'
import { useState, useEffect, useRef, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
  ResponsiveContainer, ComposedChart, Bar,
} from 'recharts'

const STORE_COLORS = ['#4ade80', '#22d3ee', '#f59e0b', '#f472b6', '#818cf8']

// Module-level cache — survives re-renders, cleared only on page reload.
// Key: `${ean}|${sortedStoreCodes}|${lastDate}`
const _detailCache = new Map()

const TOOLTIP  = { background: 'rgba(10,14,26,0.95)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 8, fontSize: 11, fontFamily: "'Geist Mono', monospace" }
const AX_TICK  = { fontSize: 10, fill: 'rgba(245,245,244,0.4)' }
const GRID_CLR = { stroke: 'rgba(255,255,255,0.05)' }
const CM       = { top: 8, right: 16, left: 0, bottom: 0 }

// Availability cell colour: green / amber / red
function availColour(soh, dailyRos) {
  if (soh == null) return 'rgba(255,255,255,0.04)'
  if (soh <= 0)    return 'rgba(239,68,68,0.75)'
  if (dailyRos > 0 && soh / dailyRos < 3) return 'rgba(245,158,11,0.75)'
  return 'rgba(74,222,128,0.75)'
}

function shortDay(iso) {
  return iso ? iso.slice(8) : ''      // "2026-05-10" → "10"
}

function ChartBox({ title, sub, children, wide }) {
  return (
    <div style={{
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid rgba(255,255,255,0.06)',
      borderRadius: 12,
      padding: '14px 16px',
      gridColumn: wide ? '1 / -1' : undefined,
      minWidth: 0,
      overflow: 'hidden',
    }}>
      <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 14, fontWeight: 600, marginBottom: 2 }}>{title}</p>
      <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', marginBottom: 12, fontFamily: "'Geist Mono', monospace" }}>{sub}</p>
      {children}
    </div>
  )
}

export function ProductDetailPanel({ product, detailRows, rosData, storeCodes, storeMap, onClose, compact }) {
  if (!product) return null

  const dates = useMemo(
    () => [...new Set(detailRows.map(r => r.snapshot_date))].sort(),
    [detailRows]
  )

  const storeList = storeCodes.map((code, i) => ({
    code,
    name: storeMap[code] ?? code,
    color: STORE_COLORS[i % STORE_COLORS.length],
  }))

  // Time-series pivot: one object per date with per-store fields
  const timeSeries = useMemo(() => dates.map(date => {
    const obj = { date, label: shortDay(date) }
    for (const s of storeList) {
      const r = detailRows.find(d => d.snapshot_date === date && d.store_code === s.code)
      obj[`qty_${s.code}`]   = r ? (r.today_qty  ?? 0) : null
      obj[`soh_${s.code}`]   = r ? (r.soh        ?? 0) : null
      obj[`price_${s.code}`] = r ? (r.sell_price ?? 0) : null
    }
    return obj
  }), [dates, detailRows, storeList])

  // Per-store ROS / days cover bar chart
  const rosByStore = useMemo(() => storeList.map(s => {
    const r = rosData.find(d => d.store_code === s.code)
    return {
      store: s.name.replace(/^(SPAR|TOPS) /, ''),
      fullName: s.name,
      daily_ros:  r?.daily_ros  ?? 0,
      days_cover: r?.days_cover ?? null,
      color: s.color,
    }
  }), [rosData, storeList])

  // Summary table rows
  const summary = storeList.map(s => {
    const r = rosData.find(d => d.store_code === s.code)
    return { ...s, soh: r?.soh, daily_ros: r?.daily_ros, days_cover: r?.days_cover }
  })

  const ean  = product['EAN']  ?? product.ean  ?? '—'
  const desc = product['Description'] ?? product.description ?? '—'
  const dept = product['Dept'] ?? product.dept_name ?? ''

  return (
    <div style={{ marginTop: 14 }}>
      <div className="sb-glass" style={{ overflow: 'hidden' }}>

        {/* ── Header ────────────────────────────────────────────────────────── */}
        <div style={{ padding: '18px 22px', borderBottom: '1px solid rgba(255,255,255,0.07)', display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 16 }}>
          <div>
            <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 18, fontWeight: 600, marginBottom: 4 }}>{desc}</p>
            <p style={{ fontFamily: "'Geist Mono', monospace", fontSize: 11, color: 'rgba(245,245,244,0.4)' }}>
              EAN {ean}{dept ? ' · ' + dept : ''}
            </p>
          </div>
          <button onClick={onClose} style={{ flexShrink: 0, padding: '6px 14px', fontSize: 12, background: 'rgba(255,255,255,0.07)', border: '1px solid rgba(255,255,255,0.12)', borderRadius: 8, color: 'rgba(245,245,244,0.55)', cursor: 'pointer', fontFamily: 'Geist, sans-serif', whiteSpace: 'nowrap' }}>
            ✕ Close
          </button>
        </div>

        {/* ── Summary strip ─────────────────────────────────────────────────── */}
        <div style={{ padding: '12px 22px', borderBottom: '1px solid rgba(255,255,255,0.07)', overflowX: 'auto' }}>
          <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 12 }}>
            <thead>
              <tr>
                {['Store', 'Current SOH', 'Daily ROS', 'Days Cover'].map(h => (
                  <th key={h} style={{ padding: '4px 14px', fontSize: 10, color: 'rgba(245,245,244,0.35)', textTransform: 'uppercase', letterSpacing: '0.1em', textAlign: h === 'Store' ? 'left' : 'right', fontWeight: 500, whiteSpace: 'nowrap' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {summary.map(s => {
                const dc = s.days_cover
                const dcColor = dc == null ? 'rgba(245,245,244,0.4)' : dc < 3 ? '#fca5a5' : dc < 7 ? '#f59e0b' : '#4ade80'
                return (
                  <tr key={s.code}>
                    <td style={{ padding: '6px 14px', color: s.color, fontWeight: 600 }}>{s.name}</td>
                    <td style={{ padding: '6px 14px', fontFamily: "'Geist Mono', monospace", textAlign: 'right', color: 'rgba(245,245,244,0.8)' }}>
                      {s.soh != null ? Number(s.soh).toLocaleString('en-ZA', { minimumFractionDigits: 0, maximumFractionDigits: 2 }) : '—'}
                    </td>
                    <td style={{ padding: '6px 14px', fontFamily: "'Geist Mono', monospace", textAlign: 'right', color: 'rgba(245,245,244,0.8)' }}>
                      {s.daily_ros != null ? Number(s.daily_ros).toFixed(2) : '—'}
                    </td>
                    <td style={{ padding: '6px 14px', fontFamily: "'Geist Mono', monospace", textAlign: 'right', color: dcColor, fontWeight: dc != null && dc < 3 ? 600 : 400 }}>
                      {dc != null ? Number(dc).toFixed(1) + ' d' : 'N/A'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        {/* ── 5 Charts — only when not compact ─────────────────────────────── */}
        {!compact && <div className="sb-two-col" style={{ padding: '20px 22px' }}>

          {/* 1. Daily Sales Trend */}
          <ChartBox title="Daily Sales Trend" sub="units sold per day per store">
            <ResponsiveContainer width="100%" height={200}>
              <LineChart data={timeSeries} margin={CM}>
                <CartesianGrid {...GRID_CLR} />
                <XAxis dataKey="label" tick={AX_TICK} />
                <YAxis tick={AX_TICK} width={36} />
                <Tooltip contentStyle={TOOLTIP} />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                {storeList.map(s => (
                  <Line key={s.code} type="monotone" dataKey={`qty_${s.code}`} name={s.name}
                    stroke={s.color} dot={false} strokeWidth={2} connectNulls />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </ChartBox>

          {/* 2. Stock Availability Timeline */}
          <ChartBox title="Stock Availability" sub="green = in stock · amber = <3d cover · red = OOS">
            <div style={{ overflowX: 'auto' }}>
              {storeList.map(s => {
                const ros = rosData.find(r => r.store_code === s.code)?.daily_ros ?? 0
                return (
                  <div key={s.code} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                    <span style={{ fontSize: 10, color: s.color, minWidth: 108, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.name}</span>
                    <div style={{ display: 'flex', gap: 2 }}>
                      {dates.map(date => {
                        const row = detailRows.find(r => r.snapshot_date === date && r.store_code === s.code)
                        return (
                          <div key={date}
                            title={`${date}  SOH: ${row?.soh ?? '—'}`}
                            style={{ flexShrink: 0, width: 8, height: 22, borderRadius: 3, background: availColour(row?.soh ?? null, ros) }}
                          />
                        )
                      })}
                    </div>
                  </div>
                )
              })}
              {dates.length > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 2 }}>
                  <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', fontFamily: "'Geist Mono', monospace" }}>{dates[0]}</span>
                  {dates.length > 1 && <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', fontFamily: "'Geist Mono', monospace" }}>{dates[dates.length - 1]}</span>}
                </div>
              )}
            </div>
          </ChartBox>

          {/* 3. SOH Movement */}
          <ChartBox title="SOH Movement" sub="closing stock per day — jumps = deliveries landed">
            <ResponsiveContainer width="100%" height={200}>
              <LineChart data={timeSeries} margin={CM}>
                <CartesianGrid {...GRID_CLR} />
                <XAxis dataKey="label" tick={AX_TICK} />
                <YAxis tick={AX_TICK} width={36} />
                <Tooltip contentStyle={TOOLTIP} />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                {storeList.map(s => (
                  <Line key={s.code} type="monotone" dataKey={`soh_${s.code}`} name={s.name}
                    stroke={s.color} dot={false} strokeWidth={2} connectNulls />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </ChartBox>

          {/* 4. Price History */}
          <ChartBox title="Sell Price History" sub="per store — catches unintended price changes">
            <ResponsiveContainer width="100%" height={200}>
              <LineChart data={timeSeries} margin={CM}>
                <CartesianGrid {...GRID_CLR} />
                <XAxis dataKey="label" tick={AX_TICK} />
                <YAxis tick={AX_TICK} width={48} tickFormatter={v => `R${v}`} />
                <Tooltip contentStyle={TOOLTIP} formatter={v => ['R ' + Number(v).toFixed(2)]} />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                {storeList.map(s => (
                  <Line key={s.code} type="monotone" dataKey={`price_${s.code}`} name={s.name}
                    stroke={s.color} dot={false} strokeWidth={2} connectNulls />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </ChartBox>

          {/* 5. ROS vs Days Cover — full width */}
          <ChartBox title="Rate of Sale vs Days Cover" sub="bar = daily ROS (units/day) · line = days cover at current SOH" wide>
            {rosByStore.every(r => r.daily_ros === 0)
              ? <p style={{ textAlign: 'center', padding: '40px 0', color: 'rgba(245,245,244,0.3)', fontSize: 13, fontStyle: 'italic' }}>No rate-of-sale data — run the SQL migration first</p>
              : (
                <ResponsiveContainer width="100%" height={220}>
                  <ComposedChart data={rosByStore} margin={CM}>
                    <CartesianGrid {...GRID_CLR} />
                    <XAxis dataKey="store" tick={AX_TICK} />
                    <YAxis yAxisId="ros" tick={AX_TICK} width={40}
                      label={{ value: 'ROS', angle: -90, position: 'insideLeft', style: { fill: 'rgba(245,245,244,0.3)', fontSize: 10 } }} />
                    <YAxis yAxisId="dc" orientation="right" tick={AX_TICK} width={40}
                      label={{ value: 'Days', angle: 90, position: 'insideRight', style: { fill: 'rgba(245,245,244,0.3)', fontSize: 10 } }} />
                    <Tooltip contentStyle={TOOLTIP} />
                    <Legend wrapperStyle={{ fontSize: 11 }} />
                    <Bar yAxisId="ros" dataKey="daily_ros" name="Daily ROS"
                      fill="rgba(74,222,128,0.55)" radius={[4, 4, 0, 0]} />
                    <Line yAxisId="dc" type="monotone" dataKey="days_cover" name="Days Cover"
                      stroke="#f59e0b" strokeWidth={2} dot={{ fill: '#f59e0b', r: 5 }} />
                  </ComposedChart>
                </ResponsiveContainer>
              )
            }
          </ChartBox>

        </div>}
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// CONNECTED WRAPPER — self-fetching; one per product in the activeProducts map
// ─────────────────────────────────────────────────────────────────────────────
export function ProductDetailPanelConnected({ product, storeCodes, storeMap, availableDates, onClose, compact }) {
  const [detailRows, setDetailRows] = useState([])
  const [rosData,    setRosData]    = useState([])
  const [loading,    setLoading]    = useState(true)

  const ean = String(product['EAN'] ?? product.ean ?? '')

  useEffect(() => {
    if (!ean || !storeCodes.length) return
    if (!compact && !availableDates.length) return
    let cancelled = false

    // Layer 3 cache — module-level Map, survives re-renders within the tab session.
    const lastDate  = availableDates.slice(-1)[0] ?? ''
    const cacheKey  = `${ean}|${[...storeCodes].sort().join(',')}|${lastDate}|${compact ? 'c' : 'f'}`
    const cached    = _detailCache.get(cacheKey)
    if (cached) {
      setDetailRows(cached.detailRows)
      setRosData(cached.rosData)
      setLoading(false)
      return
    }

    setLoading(true)
    setDetailRows([])
    setRosData([])

    const calls = compact
      ? [
          Promise.resolve({ data: [], error: null }),
          supabase.from('v_rate_of_sale')
            .select('store_code,store_name,soh,daily_ros,days_cover')
            .eq('ean', ean).in('store_code', storeCodes),
        ]
      : [
          supabase.rpc('rpc_product_detail', {
            p_ean:         ean,
            p_store_codes: storeCodes,
            p_dates:       availableDates.slice(-90),
          }),
          supabase.from('v_rate_of_sale')
            .select('store_code,store_name,soh,daily_ros,days_cover')
            .eq('ean', ean).in('store_code', storeCodes),
        ]

    Promise.all(calls).then(([detailRes, rosRes]) => {
      if (cancelled) return
      const dr = detailRes.data ?? []
      const rr = rosRes.data    ?? []
      _detailCache.set(cacheKey, { detailRows: dr, rosData: rr })
      setDetailRows(dr)
      setRosData(rr)
      setLoading(false)
    })

    return () => { cancelled = true }
  }, [ean, storeCodes, availableDates, compact])

  if (loading) {
    return (
      <div style={{ marginTop: 14 }}>
        <div className="sb-glass" style={{ padding: '40px 24px', textAlign: 'center' }}>
          <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontStyle: 'italic', color: 'rgba(245,245,244,0.4)' }}>
            Loading product detail…
          </p>
        </div>
      </div>
    )
  }

  return (
    <ProductDetailPanel
      product={product}
      detailRows={detailRows}
      rosData={rosData}
      storeCodes={storeCodes}
      storeMap={storeMap}
      onClose={onClose}
      compact={compact}
    />
  )
}
