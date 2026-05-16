'use client'

import { useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'
import { zar, short } from '@/lib/format'
import Card from './Card'

export default function Top20Panel({ date, store, stores }) {
  const [mode, setMode] = useState('value') // 'value' | 'qty'

  const { data, loading, error } = useQuery(async () => {
    // v_top_products_by_date already has rank_by_sales and rank_by_qty.
    // We fetch rank <= 20 for each mode with two small queries (max 20 rows each).
    const base = { snapshot_date: date }

    let qValue = supabase
      .from('v_top_products_by_date')
      .select('ean, description, dept_name, today_sales, today_qty, store_code')
      .eq('snapshot_date', date)
      .lte('rank_by_sales', 20)
      .order('rank_by_sales', { ascending: true })

    let qQty = supabase
      .from('v_top_products_by_date')
      .select('ean, description, dept_name, today_sales, today_qty, store_code')
      .eq('snapshot_date', date)
      .lte('rank_by_qty', 20)
      .order('rank_by_qty', { ascending: true })

    if (store !== 'all') {
      qValue = qValue.eq('store_code', store)
      qQty   = qQty.eq('store_code', store)
    }

    const [{ data: valueRows, error: e1 }, { data: qtyRows, error: e2 }] =
      await Promise.all([qValue, qQty])

    if (e1) throw new Error(e1.message)
    if (e2) throw new Error(e2.message)

    // When store === 'all' we still need to aggregate across stores
    // (the view has one row per store per EAN per date, ranked within each store).
    function aggregate(rows) {
      const map = {}
      for (const r of rows) {
        const key = r.ean
        if (!map[key]) map[key] = {
          ean: r.ean,
          description: r.description,
          dept: r.dept_name,
          sales: 0,
          qty: 0,
        }
        map[key].sales += Number(r.today_sales) || 0
        map[key].qty   += Number(r.today_qty)   || 0
      }
      return Object.values(map)
    }

    const byValue = aggregate(valueRows || []).sort((a, b) => b.sales - a.sales).slice(0, 20)
    const byQty   = aggregate(qtyRows   || []).sort((a, b) => b.qty   - a.qty  ).slice(0, 20)

    return { byValue, byQty }
  }, [date, store])

  const rows = data ? (mode === 'value' ? data.byValue : data.byQty) : []

  return (
    <Card title="Top 20 Sellers">
      {/* Toggle */}
      <div className="flex gap-2 mb-4">
        {['value', 'qty'].map(m => (
          <button
            key={m}
            onClick={() => setMode(m)}
            className={`px-3 py-1 rounded text-xs font-medium transition-colors ${
              mode === m
                ? 'bg-blue-600 text-white'
                : 'bg-[#0F3460] text-slate-400 hover:text-white'
            }`}
          >
            By {m === 'value' ? 'Sales Value' : 'Qty Sold'}
          </button>
        ))}
      </div>

      {loading && (
        <div className="space-y-2">
          {[...Array(10)].map((_, i) => (
            <div key={i} className="h-6 bg-[#0F3460] rounded animate-pulse" />
          ))}
        </div>
      )}

      {error && <p className="text-red-400 text-sm">⚠ {error}</p>}

      {!loading && !error && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-slate-400 text-xs border-b border-[#0F3460]">
                <th className="text-left py-2 w-6">#</th>
                <th className="text-left py-2">Description</th>
                <th className="text-left py-2 hidden sm:table-cell">Dept</th>
                <th className="text-right py-2">Sales</th>
                <th className="text-right py-2">Qty</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr
                  key={r.ean}
                  className={`border-b border-[#0F3460]/50 hover:bg-[#0F3460]/30 transition-colors ${
                    i === 0 ? 'text-amber-300 font-semibold' : ''
                  }`}
                >
                  <td className="py-2 text-slate-500 text-xs">{i + 1}</td>
                  <td className="py-2 pr-4 truncate max-w-[200px]">{r.description}</td>
                  <td className="py-2 text-slate-400 text-xs hidden sm:table-cell">{r.dept}</td>
                  <td className="py-2 text-right tabular-nums">{zar(r.sales)}</td>
                  <td className="py-2 text-right tabular-nums text-slate-300">{short(r.qty)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}
