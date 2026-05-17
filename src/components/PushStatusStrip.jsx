'use client'

import { supabase } from '@/lib/supabase'
import { useQuery } from '@/lib/useQuery'

const STORES = [
  { code: '10116', name: 'SPAR Delareyville' },
  { code: '80175', name: 'SPAR Roosville'    },
  { code: '21355', name: 'TOPS Delareyville' },
  { code: '80579', name: 'TOPS Dice'         },
  { code: '80176', name: 'TOPS Roosville'    },
]

function timeAgo(isoString) {
  const diffMs  = Date.now() - new Date(isoString).getTime()
  const diffMin = Math.floor(diffMs / 60000)
  if (diffMin < 60)  return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr  < 24)  return `${diffHr}h ago`
  return `${Math.floor(diffHr / 24)}d ago`
}

export default function PushStatusStrip() {
  const { data, loading } = useQuery(async () => {
    const { data: rows, error } = await supabase
      .from('push_log')
      .select('store_code, completed_at')
      .eq('status', 'SUCCESS')
      .order('completed_at', { ascending: false })

    if (error) throw new Error(error.message)

    // Latest SUCCESS per store
    const latest = {}
    for (const r of rows ?? []) {
      if (!latest[r.store_code]) latest[r.store_code] = r.completed_at
    }
    return latest
  }, [])

  if (loading) return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 16 }}>
      {STORES.map(s => (
        <div key={s.code} style={{ height: 24, width: 130, borderRadius: 999, background: 'rgba(255,255,255,0.05)', animation: 'pulse 1.5s infinite' }} />
      ))}
    </div>
  )

  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 16, alignItems: 'center' }}>
      <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', textTransform: 'uppercase', letterSpacing: '0.1em', marginRight: 2 }}>Last push</span>
      {STORES.map(s => {
        const ts       = data?.[s.code]
        const diffHr   = ts ? (Date.now() - new Date(ts).getTime()) / 3600000 : null
        const fresh    = diffHr !== null && diffHr < 24
        const stale    = diffHr !== null && diffHr >= 24
        const never    = diffHr === null

        const bg      = fresh ? 'rgba(74,222,128,0.10)'  : stale ? 'rgba(251,191,36,0.10)'  : 'rgba(255,255,255,0.04)'
        const border  = fresh ? 'rgba(74,222,128,0.30)'  : stale ? 'rgba(251,191,36,0.30)'  : 'rgba(255,255,255,0.10)'
        const dot     = fresh ? '#4ade80'                : stale ? '#fbbf24'                 : 'rgba(255,255,255,0.2)'
        const label   = ts ? timeAgo(ts) : 'no data'

        return (
          <div key={s.code} title={ts ? new Date(ts).toLocaleString('en-ZA') : 'No successful push recorded'} style={{
            display: 'flex', alignItems: 'center', gap: 5,
            padding: '3px 10px',
            background: bg, border: `1px solid ${border}`,
            borderRadius: 999, fontSize: 10,
            color: never ? 'rgba(245,245,244,0.3)' : 'rgba(245,245,244,0.75)',
            fontFamily: 'Geist, sans-serif', whiteSpace: 'nowrap',
          }}>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: dot, flexShrink: 0 }} />
            <span style={{ fontWeight: 500 }}>{s.name}</span>
            <span style={{ color: fresh ? '#4ade80' : stale ? '#fbbf24' : 'rgba(245,245,244,0.3)', fontFamily: 'Geist Mono, monospace', fontSize: 9 }}>{label}</span>
          </div>
        )
      })}
    </div>
  )
}
