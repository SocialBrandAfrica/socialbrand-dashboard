# Diagnose data quality

Run the SocialBrand data diagnostic. Checks push log health, date coverage gaps, row count anomalies, and sales spikes across all stores (or a specific store).

## Usage
- `/diagnose` — run all stores, last 30 days
- `/diagnose --store 80579` — single store
- `/diagnose --days 90` — last 90 days
- `/diagnose --from 2025-05-01 --to 2025-05-31` — specific date range

## What it does

Run the following command and show the full output to the user:

```
cd C:\Users\User\Desktop\DIWAAIS && python diagnose_data.py $ARGUMENTS
```

If `$ARGUMENTS` is empty, run without arguments (defaults: all stores, last 30 days).

After showing output, summarise:
1. Any ERR or WARN items — what store, what date, what the problem likely is
2. Whether any action is needed (missing data push, investigate anomaly, etc.)
3. If everything is clean, say so in one line

## Flags reference (pass through to the script)
| Flag | Example | Effect |
|---|---|---|
| `--store CODE` | `--store 80579` | Single store only |
| `--days N` | `--days 90` | Last N days (default 30) |
| `--from DATE` | `--from 2025-05-01` | Start date (YYYY-MM-DD) |
| `--to DATE` | `--to 2025-05-31` | End date (YYYY-MM-DD) |

## Store codes
| Code | Name |
|---|---|
| 10116 | SPAR Delareyville |
| 21355 | TOPS Delareyville |
| 80175 | SPAR Roosville |
| 80176 | TOPS Roosville |
| 80579 | TOPS Dice |

## Severity guide
| Badge | Meaning |
|---|---|
| `[ERR]` | Action required — missing data, push failure, data corruption |
| `[WARN]` | Investigate — unusual pattern, may be expected (e.g. public holiday rollover) |
| `[INFO]` | Note — normal but worth knowing (e.g. TOPS Dice full-catalog day) |
| `[OK]` | All clear |
