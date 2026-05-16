/** Format a number as South African Rand */
export function zar(value, decimals = 0) {
  if (value == null || isNaN(value)) return '—'
  return 'R ' + Number(value).toLocaleString('en-ZA', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/** Format as percentage */
export function pct(value, decimals = 1) {
  if (value == null || isNaN(value)) return '—'
  return Number(value).toFixed(decimals) + '%'
}

/** Short number (1 234 → 1.2k) — always rounds to whole number first */
export function short(value) {
  if (value == null || isNaN(value)) return '—'
  const n = Math.round(Number(value))
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M'
  if (n >= 1_000)     return (n / 1_000).toFixed(1) + 'k'
  return n.toLocaleString('en-ZA')
}
