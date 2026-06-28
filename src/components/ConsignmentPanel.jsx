'use client'
// =============================================================================
// ConsignmentPanel.jsx  -- AUDIT-002 Step 4
// Consignment business panel: HMR SUSHI at SPAR Delareyville (store 10116)
//
// Data sources (DBUMBA -- exact Sigma ledger, NOT daily_snapshots):
//   rpc_consignment_lines(p_month, p_store)   -- line-level sales
//   rpc_feed_health_daily(p_store, p_month)   -- per-day completeness strip
//
// Business model (Pieter confirmed):
//   Supplier provides labour + materials. Store keeps 10% commission.
//   90% owed to supplier at month-end. Float = 100% of takings until settlement.
//
// Notes:
//   Combo PLU launch = 2026-06-01. Pre-June sushi is structurally understated.
//   BREAKFAST + MABELA excluded in rpc_consignment_lines (merch_group_nr 610 only).
//   merch_group_nr 610 = HMR SUSHI (102 articles). Verified 2026-06-07.
//
// Refs: SB-CC-AUDIT-002, SB-CC-PMINI-001, RULE-BOOK R21/R22
// =============================================================================

import { useState, useEffect, useMemo } from 'react'
import { supabase } from '@/lib/supabase'

// ─────────────────────────────────────────────────────────────────────────────
// FORMATTERS
// ─────────────────────────────────────────────────────────────────────────────
const R   = v => v == null || isNaN(v) ? '—' : 'R ' + Number(v).toLocaleString('en-ZA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const Rsh = v => {
  if (v == null || isNaN(v)) return '—'
  const n = Math.abs(v)
  if (n >= 1e6) return 'R ' + (v/1e6).toFixed(2) + 'M'
  if (n >= 1e3) return 'R ' + (v/1e3).toFixed(1) + 'k'
  return 'R ' + Number(v).toFixed(0)
}

// ─────────────────────────────────────────────────────────────────────────────
// MONTH HELPERS
// ─────────────────────────────────────────────────────────────────────────────
function toYYYYMM(date) { return date.toISOString().slice(0, 7) }

function addMonths(ym, delta) {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(y, m - 1 + delta, 1)
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}`
}

function monthLabel(ym) {
  const [y, m] = ym.split('-').map(Number)
  const MONTHS = ['January','February','March','April','May','June',
                  'July','August','September','October','November','December']
  return MONTHS[m-1] + ' ' + y
}

// ─────────────────────────────────────────────────────────────────────────────
// STATUS COLOURS (completeness strip)
// ─────────────────────────────────────────────────────────────────────────────
const STATUS_CFG = {
  COMPLETE:    { bg: '#22c55e', title: 'Complete'              },
  EOD_MISSING: { bg: '#f59e0b', title: 'Sigma OK · PRSSALE gap' },
  DIVERGENT:   { bg: '#ef4444', title: 'Divergent'             },
  NO_TRADE:    { bg: '#334155', title: 'No trade'              },
  FUTURE:      { bg: '#1e293b', title: 'Future'                },
}

// ─────────────────────────────────────────────────────────────────────────────
// METRIC CARD
// ─────────────────────────────────────────────────────────────────────────────
function MetricCard({ label, value, sub }) {
  return (
    <div style={{ background: '#16213E', border: '1px solid #0F3460', borderRadius: 12, padding: '14px 16px' }}>
      <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.45)', marginBottom: 4 }}>{label}</p>
      <p style={{ fontSize: 22, fontWeight: 700, color: '#f5f5f4', fontFamily: "'Geist Mono', monospace" }}>{value}</p>
      {sub && <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', marginTop: 4 }}>{sub}</p>}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT BANNER
// ─────────────────────────────────────────────────────────────────────────────
function AlertBanner({ colour, children }) {
  const MAP = {
    red:    { bg: 'rgba(239,68,68,0.12)',  border: 'rgba(239,68,68,0.35)',  text: '#fca5a5' },
    amber:  { bg: 'rgba(245,158,11,0.12)', border: 'rgba(245,158,11,0.35)', text: '#fcd34d' },
  }
  const s = MAP[colour] ?? MAP.amber
  return (
    <div style={{ background: s.bg, border: `1px solid ${s.border}`, borderRadius: 8, padding: '8px 12px', fontSize: 11, color: s.text, lineHeight: 1.5 }}>
      {children}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────────────────────
const COMBO_LAUNCH_MONTH = '2026-06'
const CONSIGNMENT_STORE  = '10116'   // only SPAR Delareyville has HMR SUSHI

export default function ConsignmentPanel({ store = CONSIGNMENT_STORE, commissionRate = 0.10 }) {
  const [month,   setMonth]   = useState(toYYYYMM(new Date()))
  const [lines,   setLines]   = useState([])
  const [health,  setHealth]  = useState([])
  const [loading, setLoading] = useState(false)
  const [error,   setError]   = useState(null)

  const nowYM = toYYYYMM(new Date())

  // ── data fetch ──────────────────────────────────────────────────────────────
  useEffect(() => {
    if (store !== CONSIGNMENT_STORE) return
    let cancelled = false
    setLoading(true)
    setError(null)

    Promise.all([
      supabase.rpc('rpc_consignment_lines',  { p_month: month, p_store: store }),
      supabase.rpc('rpc_feed_health_daily',  { p_store: store, p_month: month }),
    ]).then(([lRes, hRes]) => {
      if (cancelled) return
      if (lRes.error) { setError(lRes.error.message);  setLoading(false); return }
      if (hRes.error) { setError(hRes.error.message);  setLoading(false); return }
      setHealth(hRes.data ?? [])
      setLines(lRes.data ?? [])
      setLoading(false)
    }).catch(e => { if (!cancelled) { setError(e.message); setLoading(false) } })

    return () => { cancelled = true }
  }, [store, month])

  // ── aggregations ────────────────────────────────────────────────────────────
  const totalSales = useMemo(
    () => lines.reduce((s, r) => s + Number(r.sales ?? 0), 0),
    [lines]
  )
  const commission  = totalSales * commissionRate
  const owed        = totalSales * (1 - commissionRate)

  const missingDays   = health.filter(h => h.status === 'EOD_MISSING')
  const divergentDays = health.filter(h => h.status === 'DIVERGENT')

  const top5 = useMemo(() => {
    const byDesc = {}
    for (const r of lines) {
      byDesc[r.description] = (byDesc[r.description] ?? 0) + Number(r.sales ?? 0)
    }
    return Object.entries(byDesc).sort((a, b) => b[1] - a[1]).slice(0, 5)
  }, [lines])

  const byDay = useMemo(() => {
    const d = {}
    for (const r of lines) {
      if (!d[r.sale_date]) d[r.sale_date] = { sales: 0, qty: 0 }
      d[r.sale_date].sales += Number(r.sales ?? 0)
      d[r.sale_date].qty   += Number(r.qty   ?? 0)
    }
    return Object.entries(d).sort(([a], [b]) => a.localeCompare(b))
  }, [lines])

  // ── wrong-store guard ───────────────────────────────────────────────────────
  if (store !== CONSIGNMENT_STORE) {
    return (
      <div style={{ padding: 32, textAlign: 'center', color: 'rgba(245,245,244,0.35)', fontFamily: 'Fraunces, Georgia, serif', fontStyle: 'italic' }}>
        HMR SUSHI consignment is specific to SPAR Delareyville (store 10116).
      </div>
    )
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────────────────────
  return (
    <div style={{ padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 16 }}>

      {/* Month picker */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button
          onClick={() => setMonth(m => addMonths(m, -1))}
          style={{ background: 'none', border: '1px solid #0F3460', borderRadius: 6, color: 'rgba(245,245,244,0.6)', padding: '3px 10px', cursor: 'pointer', fontSize: 16 }}>
          ‹
        </button>
        <span style={{ fontWeight: 600, color: '#f5f5f4', minWidth: 130, textAlign: 'center' }}>
          {monthLabel(month)}
        </span>
        <button
          onClick={() => setMonth(m => addMonths(m, 1))}
          disabled={month >= nowYM}
          style={{ background: 'none', border: '1px solid #0F3460', borderRadius: 6, color: month >= nowYM ? 'rgba(245,245,244,0.2)' : 'rgba(245,245,244,0.6)', padding: '3px 10px', cursor: month >= nowYM ? 'not-allowed' : 'pointer', fontSize: 16 }}>
          ›
        </button>
        <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.3)', marginLeft: 4 }}>
          Source: DBUMBA (Sigma ledger) · {(commissionRate*100).toFixed(0)}% commission
        </span>
      </div>

      {/* Boundary note */}
      {month < COMBO_LAUNCH_MONTH && (
        <AlertBanner colour="amber">
          Combo PLUs launched 1 June 2026. Pre-June sushi figures are structurally understated — do not compare across this boundary as if continuous.
        </AlertBanner>
      )}

      {/* EOD / divergence warnings */}
      {missingDays.length > 0 && (
        <AlertBanner colour="amber">
          <strong>PRSSALE export missing for {missingDays.length} day{missingDays.length > 1 ? 's' : ''}:</strong>{' '}
          {missingDays.map(d => d.sale_date + ' (' + d.day_name + ')').join(', ')}.{' '}
          Consignment figures are complete — sourced directly from the Sigma ledger (DBUMBA) and are not affected by the PRSSALE export.
        </AlertBanner>
      )}
      {divergentDays.length > 0 && (
        <AlertBanner colour="amber">
          <strong>{divergentDays.length} day{divergentDays.length > 1 ? 's' : ''} with &gt;3% DBUMBA/PRSSALE variance:</strong>{' '}
          {divergentDays.map(d => `${d.sale_date} (${d.variance_pct}%)`).join(', ')}.
        </AlertBanner>
      )}

      {/* Loading / error */}
      {loading && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: 16 }}>
          <div style={{ width: 20, height: 20, border: '2px solid rgba(74,222,128,0.2)', borderTopColor: '#4ade80', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
          <span style={{ fontSize: 12, color: 'rgba(245,245,244,0.4)', fontFamily: "'Geist Mono', monospace" }}>Loading…</span>
        </div>
      )}
      {error && (
        <AlertBanner colour="red">RPC error: {error}</AlertBanner>
      )}

      {!loading && !error && (
        <>
          {/* Metric cards */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))', gap: 10 }}>
            <MetricCard label="Cash taken"                            value={Rsh(totalSales)} sub="Exact from Sigma ledger" />
            <MetricCard label={`Commission (${(commissionRate*100).toFixed(0)}%)`} value={Rsh(commission)} sub="Retained by store" />
            <MetricCard label="Owed to supplier"                      value={Rsh(owed)}       sub={`Due month-end (${(100-commissionRate*100).toFixed(0)}%)`} />
            <MetricCard label="Capital float"                         value={Rsh(totalSales)} sub="Held until settlement" />
          </div>

          {/* Completeness strip */}
          {health.length > 0 && (
            <div>
              <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.35)', marginBottom: 8 }}>
                Feed health
              </p>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                {health.map(h => {
                  const cfg = STATUS_CFG[h.status] ?? STATUS_CFG.FUTURE
                  const day = parseInt(h.sale_date.slice(8), 10)
                  return (
                    <div
                      key={h.sale_date}
                      title={`${h.sale_date} (${h.day_name}) — ${cfg.title}${h.variance_pct != null ? ' · ' + h.variance_pct + '%' : ''}`}
                      style={{
                        width: 26, height: 26, borderRadius: 5, background: cfg.bg,
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        fontSize: 9, fontWeight: 700, color: '#fff', cursor: 'default',
                        opacity: h.status === 'FUTURE' ? 0.3 : 1,
                      }}>
                      {day}
                    </div>
                  )
                })}
              </div>
              <div style={{ display: 'flex', gap: 12, marginTop: 6, fontSize: 10, color: 'rgba(245,245,244,0.35)' }}>
                {[['#22c55e','Complete'],['#f59e0b','PRSSALE gap'],['#ef4444','Divergent'],['#334155','No trade']].map(([c,l]) => (
                  <span key={l} style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                    <span style={{ width: 8, height: 8, borderRadius: 2, background: c, display: 'inline-block' }} />
                    {l}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Top 5 sellers */}
          {top5.length > 0 && (
            <div>
              <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.35)', marginBottom: 8 }}>
                Top 5 lines
              </p>
              {top5.map(([desc, sales], i) => (
                <div key={desc} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', borderBottom: '1px solid rgba(255,255,255,0.05)', fontSize: 12 }}>
                  <span style={{ color: 'rgba(245,245,244,0.7)' }}>{i+1}. {desc}</span>
                  <span style={{ color: '#f5f5f4', fontWeight: 600, fontFamily: "'Geist Mono', monospace" }}>{R(sales)}</span>
                </div>
              ))}
            </div>
          )}

          {/* Daily sales bar chart */}
          {byDay.length > 0 && (() => {
            const maxSales  = Math.max(...byDay.map(([, d]) => d.sales), 1)
            const CHART_H   = 100
            const cumTotal  = byDay.reduce((s, [, d]) => s + d.sales, 0)
            return (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 8 }}>
                  <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.35)' }}>
                    Daily sales
                  </p>
                  <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.45)', fontFamily: "'Geist Mono', monospace" }}>
                    Cumulative {Rsh(cumTotal)}
                  </span>
                </div>
                <div style={{ display: 'flex', alignItems: 'flex-end', gap: 2 }}>
                  {byDay.map(([date, d]) => {
                    const h      = health.find(x => x.sale_date === date)
                    const flagged = h?.status === 'EOD_MISSING' || h?.status === 'DIVERGENT'
                    const barH   = Math.max(4, Math.round((d.sales / maxSales) * CHART_H))
                    const day    = parseInt(date.slice(8), 10)
                    const lbl    = d.sales >= 1000
                      ? (d.sales / 1000).toFixed(1) + 'k'
                      : Math.round(d.sales).toString()
                    return (
                      <div
                        key={date}
                        title={`${date} (${h?.day_name ?? ''}) · ${R(d.sales)} · ${Math.round(d.qty)} units`}
                        style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flex: '1 1 0', minWidth: 0 }}>
                        <span style={{
                          fontSize: 7, lineHeight: 1, marginBottom: 2,
                          fontFamily: "'Geist Mono', monospace",
                          color: flagged ? '#fcd34d' : 'rgba(245,245,244,0.5)',
                        }}>
                          {lbl}
                        </span>
                        <div style={{
                          width: '100%',
                          height: barH,
                          background: flagged ? '#f59e0b' : '#16a34a',
                          borderRadius: '2px 2px 0 0',
                        }} />
                        <span style={{
                          fontSize: 7, marginTop: 3,
                          fontFamily: "'Geist Mono', monospace",
                          color: 'rgba(245,245,244,0.3)',
                        }}>
                          {day}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </div>
            )
          })()}

          {lines.length === 0 && (
            <p style={{ color: 'rgba(245,245,244,0.3)', fontFamily: 'Fraunces, Georgia, serif', fontStyle: 'italic', fontSize: 13, textAlign: 'center', padding: 24 }}>
              No sushi sales data for {monthLabel(month)}.
            </p>
          )}
        </>
      )}
    </div>
  )
}
