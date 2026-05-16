'use client'

import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'
import { zar } from '@/lib/format'
import Card from './Card'
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid,
  Tooltip, Legend, ResponsiveContainer
} from 'recharts'

/**
 * Find the same weekday in the previous month.
 * e.g. Mon 11 May → Mon 14 April (nearest same weekday, ~4 weeks prior)
 * Strategy: go back exactly 4 weeks (28 days) — that always lands on the
 * same weekday. If you want the nearest same weekday in the prior calendar
 * month instead, we can revisit, but 28-day offset is the most honest
 * trading comparison.
 */
function sameDayLastMonth(dateStr) {
  const d = new Date(dateStr)
  d.setDate(d.getDate() - 28)
  return d.toISOString().split('T')[0]
}

const STORE_LABELS = {
  '10116': 'SPAR Del',
  '21355': 'TOPS Del',
  '80175': 'SPAR Roosv',
  '80176': 'TOPS Roosv',
  '80579': 'TOPS Dice',
}

export default function YoyGraph({ date, store, stores }) {
  const compareDate = sameDayLastMonth(date)

  const { data, loading, error } = useQuery(async () => {
    const codes = store === 'all'
      ? stores.map(s => String(s.code))
      : [store]

    // v_kpi_by_date returns at most 5 rows per date (one per store) — tiny queries.
    let qCurrent = supabase
      .from('v_kpi_by_date')
      .select('store_code, total_sales')
      .eq('snapshot_date', date)
    let qPrior = supabase
      .from('v_kpi_by_date')
      .select('store_code, total_sales')
      .eq('snapshot_date', compareDate)

    if (store !== 'all') {
      qCurrent = qCurrent.eq('store_code', store)
      qPrior   = qPrior.eq('store_code', store)
    }

    const [{ data: currentRows, error: e1 }, { data: priorRows, error: e2 }] =
      await Promise.all([qCurrent, qPrior])

    if (e1) throw new Error(e1.message)
    if (e2) throw new Error(e2.message)

    // Build per-store totals
    const totals = {}
    for (const r of (currentRows || [])) {
      const sc = String(r.store_code)
      if (!totals[sc]) totals[sc] = { current: 0, prior: 0 }
      totals[sc].current += Number(r.total_sales) || 0
    }
    for (const r of (priorRows || [])) {
      const sc = String(r.store_code)
      if (!totals[sc]) totals[sc] = { current: 0, prior: 0 }
      totals[sc].prior += Number(r.total_sales) || 0
    }

    // Recharts wants an array of { store, current, prior }
    const chartData = codes.map(sc => ({
      store:   STORE_LABELS[sc] || String(sc),
      current: Math.round(totals[sc]?.current || 0),
      prior:   Math.round(totals[sc]?.prior   || 0),
    }))

    // Group totals
    const groupCurrent = chartData.reduce((s, r) => s + r.current, 0)
    const groupPrior   = chartData.reduce((s, r) => s + r.prior,   0)
    const diff = groupCurrent - groupPrior
    const pct  = groupPrior > 0 ? (diff / groupPrior) * 100 : null

    return { chartData, groupCurrent, groupPrior, diff, pct }
  }, [date, store, compareDate])

  const CustomTooltip = ({ active, payload, label }) => {
    if (!active || !payload?.length) return null
    return (
      <div className="bg-[#16213E] border border-[#0F3460] rounded p-3 text-xs">
        <p className="font-semibold mb-1">{label}</p>
        {payload.map(p => (
          <p key={p.dataKey} style={{ color: p.color }}>
            {p.name}: {zar(p.value)}
          </p>
        ))}
      </div>
    )
  }

  return (
    <Card title={`Sales vs Prior Same Weekday (${compareDate})`}>
      {loading && (
        <div className="h-64 bg-[#0F3460] rounded animate-pulse" />
      )}
      {error && <p className="text-red-400 text-sm">⚠ {error}</p>}

      {!loading && !error && data && (
        <>
          {/* Summary line */}
          <div className="flex gap-6 mb-4 text-sm flex-wrap">
            <span>
              <span className="text-slate-400">This day: </span>
              <span className="text-white font-semibold">{zar(data.groupCurrent)}</span>
            </span>
            <span>
              <span className="text-slate-400">Prior ({compareDate}): </span>
              <span className="text-slate-300">{zar(data.groupPrior)}</span>
            </span>
            {data.pct !== null && (
              <span className={data.diff >= 0 ? 'text-emerald-400' : 'text-red-400'}>
                {data.diff >= 0 ? '▲' : '▼'} {Math.abs(data.pct).toFixed(1)}%
              </span>
            )}
          </div>

          <ResponsiveContainer width="100%" height={280}>
            <BarChart data={data.chartData} barCategoryGap="30%">
              <CartesianGrid strokeDasharray="3 3" stroke="#0F3460" />
              <XAxis dataKey="store" tick={{ fill: '#94a3b8', fontSize: 12 }} />
              <YAxis tickFormatter={v => `R${(v/1000).toFixed(0)}k`} tick={{ fill: '#94a3b8', fontSize: 11 }} />
              <Tooltip content={<CustomTooltip />} />
              <Legend wrapperStyle={{ fontSize: 12, color: '#94a3b8' }} />
              <Bar dataKey="current" name={date}        fill="#3b82f6" radius={[4,4,0,0]} />
              <Bar dataKey="prior"   name={compareDate} fill="#64748b" radius={[4,4,0,0]} />
            </BarChart>
          </ResponsiveContainer>
        </>
      )}
    </Card>
  )
}
