'use client'

import {
    AreaChart, Area, XAxis, YAxis,
    CartesianGrid, Tooltip, ResponsiveContainer,
} from 'recharts'

const zarShort = v => {
    if (v == null || isNaN(v)) return '—'
    const n = Math.abs(v)
    if (n >= 1e6) return 'R ' + (v / 1e6).toFixed(2) + 'M'
    if (n >= 1e3) return 'R ' + (v / 1e3).toFixed(1) + 'k'
    return 'R ' + v.toFixed(0)
}

function shiftDate(isoDate, days) {
    const d = new Date(isoDate)
    d.setDate(d.getDate() + days)
    return d.toISOString().slice(0, 10)
}

function rollingAverage(points, window) {
    return points.map((pt, i) => {
        const slice = points.slice(Math.max(0, i - window + 1), i + 1)
        const avg   = slice.reduce((s, p) => s + p.sales, 0) / slice.length
        return { ...pt, avg: Math.round(avg) }
    })
}

const CustomTooltip = ({ active, payload, label }) => {
    if (!active || !payload || !payload.length) return null
    const labelDate = iso => new Date(iso).toLocaleDateString('en-ZA', { day: 'numeric', month: 'short' })
    return (
        <div style={{ background: 'rgba(10,14,26,0.95)', border: '1px solid rgba(255,255,255,0.12)', borderRadius: 8, padding: '10px 14px', fontFamily: 'Geist, sans-serif' }}>
            <p style={{ fontSize: 11, color: 'rgba(245,245,244,0.5)', marginBottom: 6 }}>{labelDate(label)}</p>
            {payload.map(p => (
                <p key={p.name} style={{ fontSize: 12, color: p.color || p.stroke, marginBottom: 3 }}>
                    {p.name === 'sales' ? 'This year' : p.name === 'ly' ? 'Last year' : '4-wk avg'}: {zarShort(p.value)}
                </p>
            ))}
        </div>
    )
}

export function SalesTrendPanel({ trendData, lyTrendData, storeCodes }) {
    const aggregate = rows => {
        const byDate = {}
        for (const r of rows) {
            if (!storeCodes.includes(r.store_code)) continue
            byDate[r.snapshot_date] = (byDate[r.snapshot_date] ?? 0) + (r.total_sales ?? 0)
        }
        return byDate
    }

    const currentByDate = aggregate(trendData)
    const lyByDate      = aggregate(lyTrendData)
    const hasLY         = Object.keys(lyByDate).length > 0

    const rawPoints = Object.entries(currentByDate)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([date, sales]) => ({
            date,
            sales: Math.round(sales),
            ly:    hasLY ? (Math.round(lyByDate[shiftDate(date, -364)] ?? 0) || null) : null,
        }))
        .filter(p => p.sales > 0)

    const points = rollingAverage(rawPoints, 28)

    const labelDate = iso => new Date(iso).toLocaleDateString('en-ZA', { day: 'numeric', month: 'short' })

    if (points.length < 2) {
        return (
            <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0, minHeight: 180, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <p style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 14, fontStyle: 'italic', color: 'rgba(245,245,244,0.3)' }}>
                    Select a date range to see the trend
                </p>
            </div>
        )
    }

    return (
        <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 14 }}>
                <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Sales Trend</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                    <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.4)', display: 'flex', alignItems: 'center', gap: 5 }}>
                        <span style={{ width: 18, height: 2, background: '#4ade80', display: 'inline-block', borderRadius: 1 }} />
                        This year
                    </span>
                    {hasLY && (
                        <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.4)', display: 'flex', alignItems: 'center', gap: 5 }}>
                            <span style={{ width: 18, borderBottom: '2px dashed rgba(245,245,244,0.35)', display: 'inline-block' }} />
                            LY
                        </span>
                    )}
                    <span style={{ fontSize: 10, color: 'rgba(245,245,244,0.4)', display: 'flex', alignItems: 'center', gap: 5 }}>
                        <span style={{ width: 18, height: 1, background: 'rgba(245,245,244,0.3)', display: 'inline-block' }} />
                        4-wk avg
                    </span>
                </div>
            </div>

            <ResponsiveContainer width="100%" height={200}>
                <AreaChart data={points} margin={{ top: 4, right: 4, left: 0, bottom: 0 }}>
                    <defs>
                        <linearGradient id="salesGrad" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%"  stopColor="#4ade80" stopOpacity={0.15} />
                            <stop offset="95%" stopColor="#4ade80" stopOpacity={0}    />
                        </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" vertical={false} />
                    <XAxis
                        dataKey="date"
                        tickFormatter={labelDate}
                        tick={{ fontSize: 9, fill: 'rgba(245,245,244,0.3)', fontFamily: 'Geist Mono, monospace' }}
                        axisLine={false} tickLine={false}
                        interval="preserveStartEnd"
                    />
                    <YAxis
                        tickFormatter={v => zarShort(v)}
                        tick={{ fontSize: 9, fill: 'rgba(245,245,244,0.3)', fontFamily: 'Geist Mono, monospace' }}
                        axisLine={false} tickLine={false} width={52}
                    />
                    <Tooltip content={<CustomTooltip />} />
                    <Area
                        type="monotone" dataKey="sales" name="sales"
                        stroke="#4ade80" strokeWidth={2}
                        fill="url(#salesGrad)"
                        dot={false} activeDot={{ r: 4, fill: '#4ade80' }}
                    />
                    {hasLY && (
                        <Area
                            type="monotone" dataKey="ly" name="ly"
                            stroke="rgba(245,245,244,0.35)" strokeWidth={1.5}
                            strokeDasharray="5 3" fill="none"
                            dot={false} activeDot={{ r: 3, fill: 'rgba(245,245,244,0.5)' }}
                        />
                    )}
                    <Area
                        type="monotone" dataKey="avg" name="avg"
                        stroke="rgba(245,245,244,0.25)" strokeWidth={1}
                        fill="none" dot={false}
                    />
                </AreaChart>
            </ResponsiveContainer>
        </div>
    )
}
