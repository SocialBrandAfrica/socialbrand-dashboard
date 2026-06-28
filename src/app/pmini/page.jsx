'use client'
// =============================================================================
// src/app/pmini/page.jsx — Pulse Mini partner page
// SB-CC-PMINI-GO-LIVE-001 (2026-06-23)
//
// Standalone supplier-facing consignment report for the HMR SUSHI counter
// at SPAR Delareyville (store 10116). Opened by the sushi supplier on a phone
// — no login UI, no dashboard chrome.
//
// Auth: uses a dedicated partner Supabase key (NEXT_PUBLIC_PMINI_ANON_KEY).
// Falls back to the shared anon key during development so the page works
// before Pieter mints the partner JWT. Once pmini_partner_lockdown.sql is
// applied and the JWT set in Vercel, PMINI_KEY scopes access to
// rpc_consignment_lines + rpc_feed_health_daily only.
//
// Data: two RPCs in Promise.all — same pattern as ConsignmentPanel.jsx.
// Business model: store keeps 10% commission; 90% owed to supplier at month-end.
// Anchor: 2026-06 (combo PLU launch date — no data before this by design).
// =============================================================================

import { useState, useEffect, useMemo } from 'react'
import { createClient } from '@supabase/supabase-js'

// ─────────────────────────────────────────────────────────────────────────────
// PARTNER SUPABASE CLIENT
// Falls back to anon key so development works without the partner JWT.
// ─────────────────────────────────────────────────────────────────────────────
const PMINI_KEY = process.env.NEXT_PUBLIC_PMINI_ANON_KEY
               || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

const pminiSupabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL,
  PMINI_KEY,
  { auth: { persistSession: false } }
)

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────
const STORE     = '10116'
const MIN_MONTH = '2026-06'

// ─────────────────────────────────────────────────────────────────────────────
// FORMATTERS  (mirrors ConsignmentPanel.jsx)
// ─────────────────────────────────────────────────────────────────────────────
const R = v =>
  v == null || isNaN(v)
    ? '—'
    : 'R ' + Number(v).toLocaleString('en-ZA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// ─────────────────────────────────────────────────────────────────────────────
// MONTH HELPERS  (copied from ConsignmentPanel.jsx)
// ─────────────────────────────────────────────────────────────────────────────
function toYYYYMM(date) { return date.toISOString().slice(0, 7) }

function addMonths(ym, delta) {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(y, m - 1 + delta, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

function monthLabel(ym) {
  const [y, m] = ym.split('-').map(Number)
  const MONTHS = ['January','February','March','April','May','June',
                  'July','August','September','October','November','December']
  return MONTHS[m - 1] + ' ' + y
}

// ─────────────────────────────────────────────────────────────────────────────
// STATUS CONFIG  (identical to ConsignmentPanel.jsx)
// ─────────────────────────────────────────────────────────────────────────────
const STATUS_CFG = {
  COMPLETE:    { bg: '#22c55e', title: 'Complete'              },
  EOD_MISSING: { bg: '#f59e0b', title: 'Sigma OK · PRSSALE gap' },
  DIVERGENT:   { bg: '#ef4444', title: 'Divergent'             },
  NO_TRADE:    { bg: '#334155', title: 'No trade'              },
  FUTURE:      { bg: '#1e293b', title: 'Future'                },
}

// ─────────────────────────────────────────────────────────────────────────────
// SMALL COMPONENTS
// ─────────────────────────────────────────────────────────────────────────────
function SummaryCard({ label, value, sub, accent }) {
  return (
    <div style={{
      background: '#16213E',
      border: '1px solid #0F3460',
      borderRadius: 12,
      padding: '14px 16px',
    }}>
      <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.45)', marginBottom: 4 }}>
        {label}
      </p>
      <p style={{
        fontSize: 22, fontWeight: 700,
        color: accent ?? '#f5f5f4',
        fontFamily: "'Geist Mono', monospace",
      }}>
        {value}
      </p>
      {sub && (
        <p style={{ fontSize: 10, color: 'rgba(245,245,244,0.35)', marginTop: 4 }}>{sub}</p>
      )}
    </div>
  )
}

function AlertBanner({ children }) {
  return (
    <div style={{
      background: 'rgba(239,68,68,0.12)',
      border: '1px solid rgba(239,68,68,0.35)',
      borderRadius: 8,
      padding: '8px 12px',
      fontSize: 12,
      color: '#fca5a5',
      lineHeight: 1.5,
    }}>
      {children}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN PAGE
// ─────────────────────────────────────────────────────────────────────────────
export default function PminiPage() {
  const nowYM = toYYYYMM(new Date())

  const [month,   setMonth]   = useState(nowYM)
  const [lines,   setLines]   = useState([])
  const [health,  setHealth]  = useState([])
  const [loading, setLoading] = useState(false)
  const [error,   setError]   = useState(null)

  // ── data fetch ─────────────────────────────────────────────────────────────
  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
    setLines([])
    setHealth([])

    Promise.all([
      pminiSupabase.rpc('rpc_consignment_lines', {
        p_month: month, p_store: STORE, p_include_catalog: true,
      }),
      pminiSupabase.rpc('rpc_feed_health_daily', {
        p_store: STORE, p_month: month,
      }),
    ]).then(([lRes, hRes]) => {
      if (cancelled) return
      if (lRes.error) { setError(lRes.error.message); setLoading(false); return }
      if (hRes.error) { setError(hRes.error.message); setLoading(false); return }
      setLines(lRes.data ?? [])
      setHealth(hRes.data ?? [])
      setLoading(false)
    }).catch(e => { if (!cancelled) { setError(e.message); setLoading(false) } })

    return () => { cancelled = true }
  }, [month])

  // ── aggregations ───────────────────────────────────────────────────────────
  const soldLines = useMemo(() => lines.filter(r => r.sale_date), [lines])

  const totalSales  = useMemo(() => soldLines.reduce((s, r) => s + Number(r.sales ?? 0), 0), [soldLines])
  const sushiSales  = useMemo(() => soldLines.filter(r => r.item_type === 's').reduce((s, r) => s + Number(r.sales ?? 0), 0), [soldLines])
  const chineseSales = useMemo(() => soldLines.filter(r => r.item_type === 'c').reduce((s, r) => s + Number(r.sales ?? 0), 0), [soldLines])
  const owed        = totalSales * 0.90
  const commission  = totalSales * 0.10

  // ── feed health ────────────────────────────────────────────────────────────
  const missingDays = health.filter(h => h.status === 'EOD_MISSING')

  // ─────────────────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────────────────
  return (
    <div style={{
      maxWidth: 420,
      margin: '0 auto',
      padding: '20px 16px 48px',
      display: 'flex',
      flexDirection: 'column',
      gap: 16,
    }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,700;1,9..144,400&family=Geist+Mono:wght@400;600;700&display=swap');
        @keyframes spin { to { transform: rotate(360deg); } }
      `}</style>

      {/* ── Header ── */}
      <div style={{ paddingBottom: 4 }}>
        <h1 style={{
          fontFamily: 'Fraunces, Georgia, serif',
          fontVariant: 'small-caps',
          fontSize: 22,
          fontWeight: 700,
          color: '#f5f5f4',
          letterSpacing: '0.04em',
          marginBottom: 4,
        }}>
          Sushi Consignment
        </h1>
        <p style={{
          fontFamily: "'Geist Mono', monospace",
          fontSize: 11,
          color: 'rgba(245,245,244,0.4)',
        }}>
          SPAR Delareyville · HMR counter
        </p>
      </div>

      {/* ── Month picker ── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button
          onClick={() => setMonth(m => addMonths(m, -1))}
          disabled={month <= MIN_MONTH}
          style={{
            background: 'none',
            border: '1px solid #0F3460',
            borderRadius: 6,
            color: month <= MIN_MONTH ? 'rgba(245,245,244,0.2)' : 'rgba(245,245,244,0.6)',
            padding: '4px 12px',
            cursor: month <= MIN_MONTH ? 'not-allowed' : 'pointer',
            fontSize: 18,
            lineHeight: 1,
          }}>
          ‹
        </button>
        <span style={{
          fontWeight: 600,
          color: '#f5f5f4',
          minWidth: 130,
          textAlign: 'center',
          fontFamily: "'Geist Mono', monospace",
          fontSize: 14,
        }}>
          {monthLabel(month)}
        </span>
        <button
          onClick={() => setMonth(m => addMonths(m, 1))}
          disabled={month >= nowYM}
          style={{
            background: 'none',
            border: '1px solid #0F3460',
            borderRadius: 6,
            color: month >= nowYM ? 'rgba(245,245,244,0.2)' : 'rgba(245,245,244,0.6)',
            padding: '4px 12px',
            cursor: month >= nowYM ? 'not-allowed' : 'pointer',
            fontSize: 18,
            lineHeight: 1,
          }}>
          ›
        </button>
      </div>

      {/* ── Data quality banner ── */}
      {missingDays.length > 0 && (
        <AlertBanner>
          <strong>PRSSALE export missing for {missingDays.length} day{missingDays.length > 1 ? 's' : ''}:</strong>{' '}
          {missingDays.map(d => d.sale_date).join(', ')}.{' '}
          Consignment figures are complete — sourced directly from the Sigma ledger.
        </AlertBanner>
      )}

      {/* ── Loading ── */}
      {loading && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '24px 0' }}>
          <div style={{
            width: 20, height: 20,
            border: '2px solid rgba(74,222,128,0.2)',
            borderTopColor: '#4ade80',
            borderRadius: '50%',
            animation: 'spin 0.8s linear infinite',
          }} />
          <span style={{ fontSize: 12, color: 'rgba(245,245,244,0.4)', fontFamily: "'Geist Mono', monospace" }}>
            Loading…
          </span>
        </div>
      )}

      {/* ── Error ── */}
      {error && (
        <AlertBanner>Error loading data: {error}</AlertBanner>
      )}

      {/* ── No data (pre-June or empty) ── */}
      {!loading && !error && soldLines.length === 0 && (
        <p style={{
          color: 'rgba(245,245,244,0.3)',
          fontFamily: 'Fraunces, Georgia, serif',
          fontStyle: 'italic',
          fontSize: 13,
          textAlign: 'center',
          padding: '32px 0',
        }}>
          No consignment sales for {monthLabel(month)}.
          {month < MIN_MONTH && (
            <span style={{ display: 'block', marginTop: 6, fontSize: 11 }}>
              Data begins June 2026 (combo PLU launch date).
            </span>
          )}
        </p>
      )}

      {/* ── Main content — only when data loaded ── */}
      {!loading && !error && soldLines.length > 0 && (
        <>
          {/* ── 3 summary cards ── */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <SummaryCard
              label="Total sold"
              value={R(totalSales)}
              sub="All items · ex-VAT adjustments"
            />
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
              <SummaryCard
                label="Sushi"
                value={R(sushiSales)}
                sub="Your counter"
              />
              <SummaryCard
                label="Chinese / other"
                value={R(chineseSales)}
                sub="Your counter"
              />
            </div>
          </div>

          {/* ── Settlement card ── */}
          <div style={{
            background: '#16213E',
            border: '1px solid rgba(74,222,128,0.25)',
            borderRadius: 14,
            padding: '18px 16px',
          }}>
            <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.12em', color: 'rgba(245,245,244,0.4)', marginBottom: 6 }}>
              Owed to you
            </p>
            <p style={{
              fontFamily: 'Fraunces, Georgia, serif',
              fontSize: 36,
              fontWeight: 700,
              color: '#4ade80',
              lineHeight: 1.1,
              marginBottom: 6,
            }}>
              {R(owed)}
            </p>
            <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.45)', marginBottom: 2 }}>
              90% of total sold · settled at month-end
            </p>
            <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.3)' }}>
              Commission kept by store: {R(commission)}
            </p>
          </div>

          {/* ── Feed health strip ── */}
          {health.length > 0 && (
            <div>
              <p style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.1em', color: 'rgba(245,245,244,0.35)', marginBottom: 8 }}>
                Data completeness — {monthLabel(month)}
              </p>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                {health.map(h => {
                  const cfg = STATUS_CFG[h.status] ?? STATUS_CFG.FUTURE
                  const day = parseInt(h.sale_date.slice(8), 10)
                  return (
                    <div
                      key={h.sale_date}
                      title={`${h.sale_date} — ${cfg.title}`}
                      style={{
                        width: 26, height: 26, borderRadius: 5,
                        background: cfg.bg,
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        fontSize: 9, fontWeight: 700, color: '#fff',
                        opacity: h.status === 'FUTURE' ? 0.3 : 1,
                        cursor: 'default',
                      }}>
                      {day}
                    </div>
                  )
                })}
              </div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginTop: 8, fontSize: 10, color: 'rgba(245,245,244,0.35)' }}>
                {[['#22c55e','Complete'],['#f59e0b','PRSSALE gap'],['#ef4444','Divergent'],['#334155','No trade']].map(([c, l]) => (
                  <span key={l} style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                    <span style={{ width: 8, height: 8, borderRadius: 2, background: c, display: 'inline-block' }} />
                    {l}
                  </span>
                ))}
              </div>
            </div>
          )}

        </>
      )}

      {/* ── Footer ── */}
      <p style={{
        fontSize: 10,
        color: 'rgba(245,245,244,0.2)',
        textAlign: 'center',
        marginTop: 8,
        lineHeight: 1.6,
      }}>
        Data: SIGMA ledger · Updated nightly · Figures ex-VAT adjustments
      </p>

    </div>
  )
}
