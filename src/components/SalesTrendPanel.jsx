'use client'

import {
    AreaChart, Area, XAxis, YAxis,
    CartesianGrid, Tooltip, ResponsiveContainer, ReferenceArea,
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

// Colour per rhythm profile — matched on profile_name prefix (case-insensitive)
const RHYTHM_COLOURS = [
    { match: 'payday',     fill: 'rgba(245,158,11,0.10)',  stroke: 'rgba(245,158,11,0.35)',  label: '#f59e0b' },
    { match: 'pension',    fill: 'rgba(96,165,250,0.10)',  stroke: 'rgba(96,165,250,0.35)',  label: '#60a5fa' },
    { match: 'pre-payday', fill: 'rgba(251,146,60,0.10)',  stroke: 'rgba(251,146,60,0.35)',  label: '#fb923c' },
    { match: 'mini-payday',fill: 'rgba(251,191,36,0.09)',  stroke: 'rgba(251,191,36,0.35)',  label: '#fbbf24' },
    { match: '',           fill: 'rgba(168,85,247,0.08)',  stroke: 'rgba(168,85,247,0.3)',   label: '#a855f7' }, // fallback
]

function rhythmColour(profileName) {
    const key = (profileName ?? '').toLowerCase()
    return RHYTHM_COLOURS.find(c => c.match && key.startsWith(c.match)) ?? RHYTHM_COLOURS[RHYTHM_COLOURS.length - 1]
}

// Compute [{ x1, x2, profile }] for every contiguous run of dates inside a rhythm window
function getRhythmWindows(points, profiles) {
    if (!profiles?.length || !points?.length) return []
    const windows = []
    for (const profile of profiles) {
        let runStart = null
        for (let i = 0; i < points.length; i++) {
            const day = new Date(points[i].date + 'T12:00:00').getDate() // noon avoids DST edge
            const inside = day >= profile.start_day && day <= profile.end_day
            if (inside && runStart === null) {
                runStart = points[i].date
            } else if (!inside && runStart !== null) {
                windows.push({ x1: runStart, x2: points[i - 1].date, profile })
                runStart = null
            }
        }
        if (runStart !== null) {
            windows.push({ x1: runStart, x2: points[points.length - 1].date, profile })
        }
    }
    return windows
}

export function SalesTrendPanel({ trendData, lyTrendData, storeCodes, rhythmProfiles = [] }) {
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

    const rhythmWindows = getRhythmWindows(points, rhythmProfiles)

    // Which profiles actually appear in this date range (for legend)
    const activeInRange = rhythmProfiles.filter(p =>
        rhythmWindows.some(w => w.profile.id === p.id)
    )

    return (
        <div className="sb-glass" style={{ padding: '20px 22px', minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
                <span style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: 16, fontWeight: 600 }}>Sales Trend</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
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
                    {/* Rhythm window legend — only for profiles visible in this date range */}
                    {activeInRange.map(p => {
                        const col = rhythmColour(p.profile_name)
                        return (
                            <span key={p.id} style={{ fontSize: 10, color: col.label, display: 'flex', alignItems: 'center', gap: 5 }}>
                                <span style={{ width: 12, height: 12, background: col.fill, border: `1px solid ${col.stroke}`, borderRadius: 3, display: 'inline-block', flexShrink: 0 }} />
                                {p.profile_name}
                            </span>
                        )
                    })}
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

                    {/* Community Rhythm shaded bands — rendered before data lines so they sit behind */}
                    {rhythmWindows.map((w, i) => {
                        const col = rhythmColour(w.profile.profile_name)
                        return (
                            <ReferenceArea
                                key={`rhythm-${i}`}
                                x1={w.x1}
                                x2={w.x2}
                                fill={col.fill}
                                stroke={col.stroke}
                                strokeWidth={0}
                                fillOpacity={1}
                                label={{
                                    value: w.profile.profile_name.replace(/ \(.*\)/, ''), // strip day range if present
                                    position: 'insideTopLeft',
                                    fontSize: 8,
                                    fill: col.label,
                                    fontFamily: 'Geist, sans-serif',
                                    dy: 4,
                                }}
                            />
                        )
                    })}

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
