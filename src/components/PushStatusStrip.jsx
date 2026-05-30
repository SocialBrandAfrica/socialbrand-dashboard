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

// Days between the data's effective date (snapshot_date, 'YYYY-MM-DD') and today,
// compared date-only in local (SAST) time. A nightly run for business day D writes
// snapshot_date = D, so the morning after, the freshest expected date is yesterday.
function daysBehind(snapDate) {
  const [y, m, d] = snapDate.split('-').map(Number)
  const snap  = new Date(y, m - 1, d)
  const now   = new Date()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  return Math.round((today - snap) / 86400000)
}

function formatEffDate(snapDate) {
  const [y, m, d] = snapDate.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString('en-ZA', { day: 'numeric', month: 'short' })
}

export default function PushStatusStrip() {
  const { data, loading } = useQuery(async () => {
    // One query per store to avoid the default 1000-row limit cutting off stores
    // that haven't pushed recently when other stores have many push_log entries.
    const results = await Promise.all(
      STORES.map(async s => {
        // Freshness is judged by snapshot_date (the effective business date of the
        // data), NOT completed_at (when the script ran). A stale TAC zip re-pushed
        // on a night with no end-of-day has a recent completed_at but an old
        // snapshot_date -- keying off completed_at showed a false green (SB-CC-PUSH-001).
        // rows_pushed > 0 excludes skip/retention rows that loaded nothing.
        const { data: row, error } = await supabase
          .from('push_log')
          .select('snapshot_date,completed_at')
          .eq('status', 'SUCCESS')
          .gt('rows_pushed', 0)
          .eq('store_code', s.code)
          .not('snapshot_date', 'is', null)
          .order('snapshot_date', { ascending: false })
          .limit(1)
          .maybeSingle()
        if (error) throw new Error(error.message)
        return [s.code, row ?? null]
      })
    )
    return Object.fromEntries(results)
  }, [])

  if (loading) return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 16 }}>
      {STORES.map(s => (
        <div key={s.code} style={{ height: 24, width: 130, borderRadius: 999, background: 'rgba(255,255,255,0.05)', animation: 'pulse 1.5s infinite' }} />
      ))}
    </div>
  )

  return (
    <div style={{ marginBottom: 16 }}>
    <div className="sb-push-strip-inner">
      <span style={{ fontSize: 9, color: 'rgba(245,245,244,0.3)', textTransform: 'uppercase', letterSpacing: '0.1em', marginRight: 2, flexShrink: 0 }}>Last push</span>
      {STORES.map(s => {
        const row      = data?.[s.code]
        const snap     = row?.snapshot_date ?? null
        const behind   = snap ? daysBehind(snap) : null
        // One-day grace: <=1 day behind is current; >=2 days behind means an
        // end-of-day was likely missed, so warn instead of showing green.
        const fresh    = behind !== null && behind <= 1
        const stale    = behind !== null && behind >= 2
        const never    = behind === null

        const bg      = fresh ? 'rgba(74,222,128,0.10)'  : stale ? 'rgba(251,191,36,0.10)'  : 'rgba(255,255,255,0.04)'
        const border  = fresh ? 'rgba(74,222,128,0.30)'  : stale ? 'rgba(251,191,36,0.30)'  : 'rgba(255,255,255,0.10)'
        const dot     = fresh ? '#4ade80'                : stale ? '#fbbf24'                 : 'rgba(255,255,255,0.2)'
        const label   = row?.completed_at ? timeAgo(row.completed_at) : snap ? formatEffDate(snap) : 'no data'
        const tip     = never
          ? 'No successful push with data recorded'
          : `Data as of ${snap}`
            + (row?.completed_at ? ` (pushed ${timeAgo(row.completed_at)})` : '')
            + (stale ? ` -- ${behind} days behind, end-of-day may have been missed` : '')

        return (
          <div key={s.code} title={tip} style={{
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
    </div>
  )
}
