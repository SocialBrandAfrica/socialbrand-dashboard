'use client'

import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'
import { zar, pct, short } from '@/lib/format'

function KpiCard({ label, value, sub, colour = 'text-white' }) {
  return (
    <div className="bg-[#16213E] border border-[#0F3460] rounded-xl px-5 py-4 flex flex-col gap-1 min-w-[140px]">
      <span className="text-xs uppercase tracking-widest text-slate-400">{label}</span>
      <span className={`text-2xl font-bold ${colour}`}>{value}</span>
      {sub && <span className="text-xs text-slate-500">{sub}</span>}
    </div>
  )
}

export default function KpiStrip({ date, store }) {
  const { data, loading, error } = useQuery(async () => {
    // v_kpi_by_date returns 1 row per store per date — at most 5 rows,
    // never hitting the Supabase 1 000-row default limit.
    let q = supabase
      .from('v_kpi_by_date')
      .select('total_sales, total_cost, total_qty, neg_soh_count, slow_mover_count')
      .eq('snapshot_date', date)

    if (store !== 'all') q = q.eq('store_code', store)

    const { data: rows, error } = await q
    if (error) throw new Error(error.message)

    let turnover   = 0
    let cost       = 0
    let totalQty   = 0
    let negSOH     = 0
    let slowMovers = 0

    for (const r of rows) {
      turnover   += Number(r.total_sales)       || 0
      cost       += Number(r.total_cost)        || 0
      totalQty   += Number(r.total_qty)         || 0
      negSOH     += Number(r.neg_soh_count)     || 0
      slowMovers += Number(r.slow_mover_count)  || 0
    }

    const gp = turnover > 0 ? ((turnover - cost) / turnover) * 100 : 0

    return { turnover, gp, totalQty, negSOH, slowMovers }
  }, [date, store])

  if (loading) return (
    <div className="flex gap-4 flex-wrap">
      {[...Array(5)].map((_, i) => (
        <div key={i} className="bg-[#16213E] border border-[#0F3460] rounded-xl px-5 py-4 min-w-[140px] h-20 animate-pulse" />
      ))}
    </div>
  )

  if (error) return (
    <div className="text-red-400 text-sm p-4 bg-[#16213E] rounded-xl border border-red-900">
      ⚠ KPI error: {error}
    </div>
  )

  if (!data) return null

  return (
    <div className="flex flex-wrap gap-4">
      <KpiCard
        label="Group Turnover"
        value={zar(data.turnover)}
        sub={`${short(data.totalQty)} units`}
        colour="text-emerald-400"
      />
      <KpiCard
        label="GP %"
        value={pct(data.gp)}
        sub="excl. VAT"
        colour={data.gp >= 20 ? 'text-emerald-400' : 'text-amber-400'}
      />
      <KpiCard
        label="Negative SOH"
        value={short(data.negSOH)}
        sub="lines below zero"
        colour={data.negSOH > 0 ? 'text-red-400' : 'text-emerald-400'}
      />
      <KpiCard
        label="Slow Movers"
        value={short(data.slowMovers)}
        sub="SOH > 0, no sales"
        colour={data.slowMovers > 50 ? 'text-red-400' : 'text-amber-400'}
      />
    </div>
  )
}
