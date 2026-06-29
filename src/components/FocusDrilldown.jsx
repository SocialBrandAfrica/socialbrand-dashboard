'use client'

import { useState, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'
import { zar, short } from '@/lib/format'
import Card from './Card'
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid,
  Tooltip, ResponsiveContainer
} from 'recharts'

const SEARCH_MODES = [
  { key: 'description', label: 'Product name' },
  { key: 'dept_name',   label: 'Department'   },
  { key: 'supplier',    label: 'Supplier'      },
]

const STORE_LABELS = {
  '10116': 'SPAR Del',
  '21355': 'TOPS Del',
  '80175': 'SPAR Roosv',
  '80176': 'TOPS Roosv',
  '80579': 'TOPS Dice',
}

// Build a date range: last N days from `date`
function dateRange(dateStr, days = 30) {
  const end   = new Date(dateStr)
  const start = new Date(dateStr)
  start.setDate(start.getDate() - days + 1)
  return {
    from: start.toISOString().split('T')[0],
    to:   end.toISOString().split('T')[0],
  }
}

export default function FocusDrilldown({ date, store, stores }) {
  const [mode,   setMode]   = useState('description')
  const [term,   setTerm]   = useState('')
  const [active, setActive] = useState('')   // the committed search term

  const { from, to } = dateRange(date, 30)

  const { data, loading, error } = useQuery(async () => {
    if (!active) return null

    const storeFilter = store !== 'all' ? [store] : stores.map(s => String(s.code))

    let rows = []

    if (mode === 'supplier') {
      // supplier is not stored in daily_snapshots — look it up via the products table
      // to get the matching EAN list, then query v_focus_trend by those EANs.
      // SB-CC-SEC-001: routed through rpc_eans_by_supplier (SECURITY DEFINER).
      const { data: prodRows, error: pe } = await supabase
        .rpc('rpc_eans_by_supplier', { p_supplier: active })

      if (pe) throw new Error(pe.message)
      if (!prodRows || prodRows.length === 0) {
        return { totalQty: 0, totalSales: 0, trend: [], storeComp: [], rowCount: 0 }
      }

      const eans = prodRows.map(p => p.ean)

      const { data: trendRows, error: te } = await supabase
        .from('v_focus_trend')
        .select('snapshot_date, store_code, sales, qty')
        .gte('snapshot_date', from)
        .lte('snapshot_date', to)
        .in('store_code', storeFilter)
        .in('ean', eans)

      if (te) throw new Error(te.message)
      rows = trendRows || []

    } else {
      // description or dept_name — query v_focus_trend directly.
      // v_focus_trend aggregates by (store, date, ean, dept, description) so it's
      // much smaller than daily_snapshots but still supports ilike filtering.
      let q = supabase
        .from('v_focus_trend')
        .select('snapshot_date, store_code, sales, qty')
        .gte('snapshot_date', from)
        .lte('snapshot_date', to)
        .in('store_code', storeFilter)

      if (mode === 'description') {
        q = q.ilike('description', `%${active}%`)
      } else if (mode === 'dept_name') {
        q = q.ilike('dept_name', `%${active}%`)
      }

      const { data: trendRows, error: te } = await q
      if (te) throw new Error(te.message)
      rows = trendRows || []
    }

    // Aggregate
    let totalQty   = 0
    let totalSales = 0
    const byDate   = {}
    const byStore  = {}

    for (const r of rows) {
      const qty   = Number(r.qty)   || 0
      const sales = Number(r.sales) || 0
      totalQty   += qty
      totalSales += sales

      const d = r.snapshot_date
      if (!byDate[d]) byDate[d] = { date: d, sales: 0, qty: 0 }
      byDate[d].sales += sales
      byDate[d].qty   += qty

      const sc = String(r.store_code)
      if (!byStore[sc]) byStore[sc] = { store: STORE_LABELS[sc] || sc, sales: 0, qty: 0 }
      byStore[sc].sales += sales
      byStore[sc].qty   += qty
    }

    const trend     = Object.values(byDate).sort((a, b) => a.date.localeCompare(b.date))
    const storeComp = Object.values(byStore).sort((a, b) => b.sales - a.sales)

    return { totalQty, totalSales, trend, storeComp, rowCount: rows.length }
  }, [active, mode, date, store])

  const handleSearch = () => setActive(term.trim())

  const CustomTooltip = ({ active, payload, label }) => {
    if (!active || !payload?.length) return null
    return (
      <div className="bg-[#16213E] border border-[#0F3460] rounded p-3 text-xs">
        <p className="font-semibold mb-1">{label}</p>
        {payload.map(p => (
          <p key={p.dataKey} style={{ color: p.color }}>
            {p.name}: {p.dataKey === 'sales' ? zar(p.value) : short(p.value)}
          </p>
        ))}
      </div>
    )
  }

  return (
    <Card title="Focus Drilldown">
      {/* Search controls */}
      <div className="flex flex-wrap gap-3 mb-5 items-center">
        {/* Mode selector */}
        <div className="flex gap-1">
          {SEARCH_MODES.map(m => (
            <button
              key={m.key}
              onClick={() => { setMode(m.key); setActive(''); setTerm('') }}
              className={`px-3 py-1 rounded text-xs font-medium transition-colors ${
                mode === m.key
                  ? 'bg-blue-600 text-white'
                  : 'bg-[#0F3460] text-slate-400 hover:text-white'
              }`}
            >
              {m.label}
            </button>
          ))}
        </div>

        {/* Search input */}
        <div className="flex gap-2 flex-1">
          <input
            type="text"
            placeholder={`Search by ${SEARCH_MODES.find(m => m.key === mode)?.label}…`}
            value={term}
            onChange={e => setTerm(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && handleSearch()}
            className="flex-1 bg-[#0F3460] border border-[#0F3460] text-slate-200 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500 placeholder-slate-500"
          />
          <button
            onClick={handleSearch}
            className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-1.5 rounded text-sm font-medium transition-colors"
          >
            Search
          </button>
        </div>
      </div>

      <p className="text-xs text-slate-500 mb-4">
        Showing last 30 days · {from} → {to}
      </p>

      {/* No search yet */}
      {!active && (
        <p className="text-slate-500 text-sm text-center py-8">
          Search for a product, department, or supplier to see the trend.
        </p>
      )}

      {loading && active && (
        <div className="space-y-4">
          <div className="h-8 bg-[#0F3460] rounded animate-pulse w-1/3" />
          <div className="h-48 bg-[#0F3460] rounded animate-pulse" />
        </div>
      )}

      {error && <p className="text-red-400 text-sm">⚠ {error}</p>}

      {!loading && !error && data && (
        <div className="space-y-6">
          {/* Summary KPIs */}
          <div className="flex gap-6 text-sm flex-wrap">
            <div>
              <span className="text-slate-400">Total Sales </span>
              <span className="text-white font-semibold">{zar(data.totalSales)}</span>
            </div>
            <div>
              <span className="text-slate-400">Total Qty </span>
              <span className="text-white font-semibold">{short(data.totalQty)}</span>
            </div>
            <div>
              <span className="text-slate-400">Lines matched </span>
              <span className="text-slate-300">{data.rowCount.toLocaleString()}</span>
            </div>
          </div>

          {/* Trend graph */}
          <div>
            <h3 className="text-xs uppercase tracking-widest text-slate-400 mb-3">
              Sales trend (last 30 days)
            </h3>
            <ResponsiveContainer width="100%" height={220}>
              <LineChart data={data.trend}>
                <CartesianGrid strokeDasharray="3 3" stroke="#0F3460" />
                <XAxis
                  dataKey="date"
                  tick={{ fill: '#94a3b8', fontSize: 10 }}
                  tickFormatter={d => d.slice(5)} // MM-DD
                />
                <YAxis tickFormatter={v => `R${(v/1000).toFixed(0)}k`} tick={{ fill: '#94a3b8', fontSize: 10 }} />
                <Tooltip content={<CustomTooltip />} />
                <Line
                  type="monotone" dataKey="sales" name="Sales"
                  stroke="#3b82f6" strokeWidth={2} dot={false}
                />
              </LineChart>
            </ResponsiveContainer>
          </div>

          {/* Store comparison */}
          <div>
            <h3 className="text-xs uppercase tracking-widest text-slate-400 mb-3">
              Store comparison
            </h3>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-slate-400 text-xs border-b border-[#0F3460]">
                    <th className="text-left py-2">Store</th>
                    <th className="text-right py-2">Sales</th>
                    <th className="text-right py-2">Qty</th>
                    <th className="text-left py-2 pl-4 w-32 hidden md:table-cell"></th>
                  </tr>
                </thead>
                <tbody>
                  {data.storeComp.map(s => {
                    const share = data.totalSales > 0 ? (s.sales / data.totalSales) * 100 : 0
                    return (
                      <tr key={s.store} className="border-b border-[#0F3460]/50">
                        <td className="py-2 font-medium">{s.store}</td>
                        <td className="py-2 text-right tabular-nums">{zar(s.sales)}</td>
                        <td className="py-2 text-right tabular-nums text-slate-300">{short(s.qty)}</td>
                        <td className="py-2 pl-4 hidden md:table-cell">
                          <div className="w-32 bg-[#0F3460] rounded-full h-1.5">
                            <div
                              className="bg-blue-500 h-1.5 rounded-full"
                              style={{ width: `${Math.min(share, 100)}%` }}
                            />
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}

      {!loading && !error && data && data.rowCount === 0 && (
        <p className="text-slate-500 text-sm text-center py-4">
          No data found for "{active}" in the selected period.
        </p>
      )}
    </Card>
  )
}
