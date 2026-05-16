'use client'

import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'
import { zar, pct } from '@/lib/format'
import Card from './Card'

export default function DeptTable({ date, store }) {
  const { data, loading, error } = useQuery(async () => {
    // v_dept_by_date returns 1 row per dept per store per date (~60 rows max).
    let q = supabase
      .from('v_dept_by_date')
      .select('dept_name, dept_sales, dept_cost')
      .eq('snapshot_date', date)

    if (store !== 'all') q = q.eq('store_code', store)

    const { data: rows, error } = await q
    if (error) throw new Error(error.message)

    // Sum across stores when viewing "all" (multiple rows per dept)
    const map = {}
    let totalSales = 0
    for (const r of rows) {
      const dept  = r.dept_name || 'Unknown'
      const sales = Number(r.dept_sales) || 0
      const cost  = Number(r.dept_cost)  || 0
      if (!map[dept]) map[dept] = { dept, sales: 0, cost: 0 }
      map[dept].sales += sales
      map[dept].cost  += cost
      totalSales      += sales
    }

    const depts = Object.values(map)
      .map(d => ({
        ...d,
        gp:    d.sales > 0 ? ((d.sales - d.cost) / d.sales) * 100 : 0,
        share: totalSales  > 0 ? (d.sales / totalSales) * 100       : 0,
      }))
      .sort((a, b) => b.sales - a.sales)

    return { depts, totalSales }
  }, [date, store])

  return (
    <Card title="Department Performance">
      {loading && (
        <div className="space-y-2">
          {[...Array(8)].map((_, i) => (
            <div key={i} className="h-6 bg-[#0F3460] rounded animate-pulse" />
          ))}
        </div>
      )}

      {error && <p className="text-red-400 text-sm">⚠ {error}</p>}

      {!loading && !error && data && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-slate-400 text-xs border-b border-[#0F3460]">
                <th className="text-left py-2">Department</th>
                <th className="text-right py-2">Sales (excl. VAT)</th>
                <th className="text-right py-2">GP%</th>
                <th className="text-right py-2">Share</th>
                {/* Participation bar */}
                <th className="text-left py-2 pl-4 w-32 hidden md:table-cell"></th>
              </tr>
            </thead>
            <tbody>
              {data.depts.map((d, i) => (
                <tr
                  key={d.dept}
                  className="border-b border-[#0F3460]/50 hover:bg-[#0F3460]/30 transition-colors"
                >
                  <td className="py-2 font-medium">{d.dept}</td>
                  <td className="py-2 text-right tabular-nums">{zar(d.sales)}</td>
                  <td className={`py-2 text-right tabular-nums ${
                    d.gp >= 25 ? 'text-emerald-400' : d.gp >= 15 ? 'text-amber-400' : 'text-red-400'
                  }`}>
                    {pct(d.gp)}
                  </td>
                  <td className="py-2 text-right tabular-nums text-slate-400">
                    {pct(d.share)}
                  </td>
                  {/* Share bar */}
                  <td className="py-2 pl-4 hidden md:table-cell">
                    <div className="w-32 bg-[#0F3460] rounded-full h-1.5">
                      <div
                        className="bg-blue-500 h-1.5 rounded-full"
                        style={{ width: `${Math.min(d.share, 100)}%` }}
                      />
                    </div>
                  </td>
                </tr>
              ))}
              {/* Total row */}
              <tr className="border-t-2 border-[#0F3460] font-semibold text-white">
                <td className="py-2">Total</td>
                <td className="py-2 text-right tabular-nums">{zar(data.totalSales)}</td>
                <td className="py-2 text-right">—</td>
                <td className="py-2 text-right">100%</td>
                <td className="hidden md:table-cell" />
              </tr>
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}
