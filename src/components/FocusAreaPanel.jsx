'use client'
import { useState, useEffect } from 'react'
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
  ResponsiveContainer,
} from 'recharts'
import { supabase } from '@/lib/supabase'

// ─────────────────────────────────────────────────────────────────────────────
// FOCUS AREA PANEL
//
// Shows a multi-product comparison chart for items added to the focus basket.
// Designed for service departments (HMR, Butchery, Deli) where SOH doesn't
// deplete normally, and for combo/promotional analysis across any products.
//
// Each basket item is identified by { ean, description, store_code, dept_name }.
// One coloured line per item on a shared date-axis chart.
// ─────────────────────────────────────────────────────────────────────────────

const FOCUS_COLORS = [
  '#4ade80', // green
  '#f59e0b', // amber
  '#f472b6', // pink
  '#22d3ee', // cyan
  '#a78bfa', // violet
  '#fb923c', // orange
]

const zarFmt = v => v == null || isNaN(v) ? '—' : 'R ' + Number(v).toFixed(2)

function shortDay(iso) {
  return iso ? iso.slice(8) : ''
}

// When only one date is selected, expand to the full week-to-date range
// (Monday → selected date) so the chart has a meaningful trend line.
// When multiple dates are already selected, use them as-is.
function resolveChartDates(selectedDates) {
  if (selectedDates.length !== 1) return selectedDates
  const latest = selectedDates[0]
  const latestDate = new Date(latest + 'T00:00:00')
  const dow = latestDate.getDay() // 0=Sun … 6=Sat
  const daysBack = dow === 0 ? 6 : dow - 1  // steps back to Monday
  const monday = new Date(latestDate)
  monday.setDate(latestDate.getDate() - daysBack)
  const dates = []
  const cur = new Date(monday)
  while (cur <= latestDate) {
    dates.push(cur.toISOString().slice(0, 10))
    cur.setDate(cur.getDate() + 1)
  }
  return dates
}

// Each basket item label on the chart.
// When store_code is null (multi-store default mode) we omit the store tag.
function itemLabel(item) {
  const desc = item.description.length > 22
    ? item.description.slice(0, 20) + '…'
    : item.description
  return item.store_code ? `${desc} [${item.store_code}]` : desc
}

export function FocusAreaPanel({ basket, onRemove, onClear, selectedDates, allStoreCodes, isDefault }) {
  const [chartData,  setChartData]  = useState([])
  const [totals,     setTotals]     = useState([])
  const [loading,    setLoading]    = useState(false)

  // ── Fetch data for all basket items whenever basket or dates change ──────
  useEffect(() => {
    if (!basket.length || !selectedDates.length) {
      setChartData([])
      setTotals([])
      return
    }
    setLoading(true)

    // EANs come from rpc_top20 which may return them as numbers (PostgreSQL bigint).
    // daily_snapshots.ean is a text column, so stringify to ensure the filter matches.
    const eans = [...new Set(basket.map(b => String(b.ean)))]

    // When items have no store_code (multi-store default mode), query across
    // all currently selected stores via the allStoreCodes prop.
    // When items have an explicit store_code (manually added), use those.
    const basketStoreCodes = [...new Set(basket.map(b => b.store_code).filter(Boolean))]
    const queryStoreCodes = basketStoreCodes.length > 0 ? basketStoreCodes : (allStoreCodes ?? [])

    // Expand a single selected date to the full week-to-date range so the chart
    // always has a meaningful trend line rather than a single data point.
    const chartDates = resolveChartDates(selectedDates)

    // rpc_focus_chart is a SECURITY DEFINER function — direct daily_snapshots
    // reads are blocked by RLS for the anon key.
    supabase.rpc('rpc_focus_chart', {
      p_eans:        eans,
      p_store_codes: queryStoreCodes,
      p_dates:       chartDates,
    }).then(({ data, error }) => {
      if (error) { console.error('rpc_focus_chart error', error); setLoading(false); return }
      const rows = data ?? []
        const dates = [...new Set(rows.map(r => r.snapshot_date))].sort()

        // Time series: one object per date, one key per basket item.
        // Items with no store_code are aggregated across all stores for that EAN.
        // Use String() on both sides of the EAN compare — the column type in
        // daily_snapshots vs rpc_top20 may differ (text vs bigint).
        const series = dates.map(date => {
          const obj = { date, label: shortDay(date) }
          for (const item of basket) {
            const matchRows = item.store_code
              ? rows.filter(r => String(r.ean) === String(item.ean) && r.store_code === item.store_code && r.snapshot_date === date)
              : rows.filter(r => String(r.ean) === String(item.ean) && r.snapshot_date === date)
            obj[itemLabel(item)] = matchRows.reduce((s, r) => s + Number(r.today_sales ?? 0), 0)
          }
          return obj
        })

        // Per-item totals — same aggregation logic as the chart
        const tots = basket.map(item => {
          const itemRows    = item.store_code
            ? rows.filter(r => String(r.ean) === String(item.ean) && r.store_code === item.store_code)
            : rows.filter(r => String(r.ean) === String(item.ean))
          const periodSales = itemRows.reduce((s, r) => s + Number(r.today_sales ?? 0), 0)
          const periodQty   = itemRows.reduce((s, r) => s + Number(r.today_qty   ?? 0), 0)
          const sellingDays = itemRows.filter(r => Number(r.today_qty ?? 0) > 0).length
          const totalDays   = itemRows.length
          const avgDaily    = sellingDays > 0 ? periodSales / sellingDays : 0
          const ros         = totalDays   > 0 ? periodQty  / totalDays   : 0
          const latest      = [...itemRows].sort((a, b) => b.snapshot_date.localeCompare(a.snapshot_date))[0]
          const sizeLabel   = [latest?.size, latest?.unit].filter(Boolean).join(' ').trim()
          return { ...item, periodSales, periodQty, sellingDays, avgDaily, ros, latestSoh: latest?.soh ?? null, sizeLabel }
        })

        setChartData(series)
        setTotals(tots)
        setLoading(false)
      })
  }, [basket, selectedDates, allStoreCodes])

  const combinedTotal = totals.reduce((s, t) => s + t.periodSales, 0)
  const combinedQty   = totals.reduce((s, t) => s + t.periodQty,   0)

  return (
    <div style={{
      background: 'rgba(255,255,255,0.02)',
      border: '1px solid rgba(255,255,255,0.07)',
      borderRadius: 16,
      padding: '20px 24px',
      marginTop: 16,
    }}>

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 16 }}>
        <div>
          <p style={{
            fontFamily: 'Fraunces, Georgia, serif',
            fontSize: 16, fontWeight: 600, margin: 0, color: '#f5f5f4',
          }}>
            Focus Area
          </p>
          <p style={{
            fontSize: 10, color: 'rgba(245,245,244,0.35)',
            fontFamily: "'Geist Mono', monospace", margin: '3px 0 0',
          }}>
            {isDefault ? 'top 5 by value · ' : ''}{basket.length} item{basket.length !== 1 ? 's' : ''} · daily sales comparison{basket.length > 0 ? ` · combined R ${zarFmt(combinedTotal).replace('R ', '')}` : ''}
          </p>
        </div>
        <button
          onClick={onClear}
          title={isDefault ? 'Reset to top 5' : 'Clear all and reset to top 5'}
          style={{
            fontSize: 10, color: 'rgba(245,245,244,0.4)',
            background: 'none', border: '1px solid rgba(255,255,255,0.1)',
            borderRadius: 6, padding: '4px 10px', cursor: 'pointer',
            fontFamily: 'Geist, sans-serif',
          }}
        >{isDefault ? 'Reset' : 'Clear all'}</button>
      </div>

      {/* ── Basket chips ───────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 18 }}>
        {basket.map((item, i) => (
          <div key={`${item.ean}-${item.store_code}`} style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            padding: '4px 8px 4px 10px',
            background: 'rgba(255,255,255,0.04)',
            border: `1px solid ${FOCUS_COLORS[i % FOCUS_COLORS.length]}50`,
            borderRadius: 20, fontSize: 11,
          }}>
            <span style={{
              width: 8, height: 8, borderRadius: '50%',
              background: FOCUS_COLORS[i % FOCUS_COLORS.length],
              flexShrink: 0, display: 'inline-block',
            }} />
            <span style={{ color: '#f5f5f4' }}>{item.description}</span>
            {item.store_code && (
              <span style={{
                color: 'rgba(245,245,244,0.4)',
                fontFamily: "'Geist Mono', monospace", fontSize: 9,
              }}>{item.store_code}</span>
            )}
            <button
              onClick={() => onRemove(item)}
              title="Remove from Focus Area"
              style={{
                background: 'none', border: 'none',
                color: 'rgba(245,245,244,0.35)', cursor: 'pointer',
                fontSize: 14, lineHeight: 1, padding: '0 2px',
              }}
            >×</button>
          </div>
        ))}
      </div>

      {/* ── Loading state ─────────────────────────────────────────────────── */}
      {loading && (
        <div style={{ textAlign: 'center', padding: 40, color: 'rgba(245,245,244,0.3)', fontStyle: 'italic', fontSize: 12 }}>
          Loading Focus Area data…
        </div>
      )}

      {/* ── Chart ─────────────────────────────────────────────────────────── */}
      {!loading && chartData.length > 0 && (
        <>
          <div style={{ height: 220, marginBottom: 22 }}>
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
                <CartesianGrid stroke="rgba(255,255,255,0.05)" />
                <XAxis
                  dataKey="label"
                  tick={{ fontSize: 10, fill: 'rgba(245,245,244,0.4)' }}
                />
                <YAxis
                  tick={{ fontSize: 10, fill: 'rgba(245,245,244,0.4)' }}
                  tickFormatter={v => v >= 1000 ? `R${(v / 1000).toFixed(1)}k` : `R${v.toFixed(0)}`}
                  width={56}
                />
                <Tooltip
                  contentStyle={{
                    background: 'rgba(10,14,26,0.95)',
                    border: '1px solid rgba(255,255,255,0.1)',
                    borderRadius: 8, fontSize: 11,
                    fontFamily: "'Geist Mono', monospace",
                  }}
                  formatter={(v, name) => [`R ${Number(v).toFixed(2)}`, name]}
                />
                <Legend wrapperStyle={{ fontSize: 10, fontFamily: 'Geist, sans-serif', paddingTop: 8 }} />
                {basket.map((item, i) => (
                  <Line
                    key={itemLabel(item)}
                    type="monotone"
                    dataKey={itemLabel(item)}
                    stroke={FOCUS_COLORS[i % FOCUS_COLORS.length]}
                    strokeWidth={2}
                    dot={{ r: 3, fill: FOCUS_COLORS[i % FOCUS_COLORS.length] }}
                    activeDot={{ r: 5 }}
                    connectNulls
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </div>

          {/* ── Summary table ─────────────────────────────────────────────── */}
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 11, fontFamily: 'Geist, sans-serif' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid rgba(255,255,255,0.08)' }}>
                  {['Product', 'Store', 'Dept', 'Period Sales', 'Units Sold', 'Selling Days', 'Avg / Day', 'ROS (u/day)', 'Latest SOH'].map((h, i) => (
                    <th key={h} style={{
                      textAlign: i > 2 ? 'right' : 'left',
                      padding: '6px 10px',
                      color: 'rgba(245,245,244,0.4)',
                      fontSize: 9, textTransform: 'uppercase',
                      letterSpacing: '0.06em', fontWeight: 500,
                    }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {totals.map((item, i) => (
                  <tr key={`${item.ean}-${item.store_code}`} style={{ borderBottom: '1px solid rgba(255,255,255,0.04)' }}>
                    <td style={{ padding: '9px 10px', whiteSpace: 'nowrap' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{
                          display: 'inline-block', width: 8, height: 8, flexShrink: 0,
                          borderRadius: '50%', background: FOCUS_COLORS[i % FOCUS_COLORS.length],
                        }} />
                        <div>
                          <div style={{ color: '#f5f5f4' }}>{item.description}</div>
                          {item.sizeLabel && (
                            <div style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', fontFamily: "'Geist Mono', monospace", marginTop: 1 }}>{item.sizeLabel}</div>
                          )}
                        </div>
                      </div>
                    </td>
                    <td style={{ padding: '9px 10px', color: 'rgba(245,245,244,0.5)', fontFamily: "'Geist Mono', monospace", fontSize: 10 }}>{item.store_code ?? 'All'}</td>
                    <td style={{ padding: '9px 10px', color: 'rgba(245,245,244,0.5)' }}>{item.dept_name}</td>
                    <td style={{ padding: '9px 10px', textAlign: 'right', color: '#4ade80', fontFamily: "'Geist Mono', monospace" }}>
                      R {Number(item.periodSales).toFixed(2)}
                    </td>
                    <td style={{ padding: '9px 10px', textAlign: 'right', color: 'rgba(245,245,244,0.7)', fontFamily: "'Geist Mono', monospace" }}>
                      {Number(item.periodQty).toFixed(0)}
                    </td>
                    <td style={{ padding: '9px 10px', textAlign: 'right', color: 'rgba(245,245,244,0.6)', fontFamily: "'Geist Mono', monospace" }}>
                      {item.sellingDays}
                    </td>
                    <td style={{ padding: '9px 10px', textAlign: 'right', fontFamily: "'Geist Mono', monospace" }}>
                      R {Number(item.avgDaily).toFixed(2)}
                    </td>
                    <td style={{ padding: '9px 10px', textAlign: 'right', fontFamily: "'Geist Mono', monospace", color: 'rgba(245,245,244,0.7)' }}>
                      {Number(item.ros).toFixed(2)}
                    </td>
                    <td style={{
                      padding: '9px 10px', textAlign: 'right',
                      fontFamily: "'Geist Mono', monospace",
                      color: item.latestSoh != null && Number(item.latestSoh) < 0
                        ? 'rgba(239,68,68,0.8)' : 'rgba(245,245,244,0.5)',
                    }}>
                      {item.latestSoh != null ? Number(item.latestSoh).toFixed(0) : '—'}
                    </td>
                  </tr>
                ))}
                {/* Combined total row */}
                <tr style={{ borderTop: '2px solid rgba(255,255,255,0.1)', background: 'rgba(74,222,128,0.03)' }}>
                  <td colSpan={3} style={{ padding: '9px 10px', color: 'rgba(245,245,244,0.4)', fontSize: 10, fontStyle: 'italic' }}>
                    Combined total
                  </td>
                  <td style={{ padding: '9px 10px', textAlign: 'right', color: '#4ade80', fontFamily: "'Geist Mono', monospace", fontWeight: 700, fontSize: 13 }}>
                    R {Number(combinedTotal).toFixed(2)}
                  </td>
                  <td style={{ padding: '9px 10px', textAlign: 'right', color: 'rgba(245,245,244,0.7)', fontFamily: "'Geist Mono', monospace", fontWeight: 700, fontSize: 13 }}>
                    {Number(combinedQty).toFixed(0)}
                  </td>
                  <td colSpan={4} />
                </tr>
              </tbody>
            </table>
          </div>

          {/* Service dept note */}
          {totals.some(t => ['HMR', 'BUTCHERY', 'DELI', 'BAKERY'].some(d => (t.dept_name ?? '').toUpperCase().includes(d))) && (
            <p style={{ marginTop: 14, fontSize: 10, color: 'rgba(245,245,244,0.25)', fontStyle: 'italic', fontFamily: 'Geist, sans-serif' }}>
              ℹ Service dept and high-velocity items — SOH may be negative or zero by design. Sales velocity (Avg/Day) is the meaningful metric here.
            </p>
          )}
        </>
      )}

      {/* Empty basket while default items are still loading */}
      {!loading && basket.length === 0 && (
        <p style={{ textAlign: 'center', color: 'rgba(245,245,244,0.3)', fontStyle: 'italic', fontSize: 12, padding: '24px 0' }}>
          {isDefault ? 'Loading top 5 items…' : 'Use the + button on any search result to add items here.'}
        </p>
      )}

      {!loading && !chartData.length && basket.length > 0 && (
        <p style={{ textAlign: 'center', color: 'rgba(245,245,244,0.3)', fontStyle: 'italic', fontSize: 12, padding: '24px 0' }}>
          No sales data found for the selected dates.
        </p>
      )}
    </div>
  )
}
