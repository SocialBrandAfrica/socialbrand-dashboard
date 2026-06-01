#!/usr/bin/env python3
# =============================================================================
# load_product_classification.py          SB-AP-003 Action A2
# -----------------------------------------------------------------------------
# Loads production_scored.csv (output of production_classifier.py) into the
# product_classification table in Supabase for a given store.
#
# PREREQUISITES:
#   1. Run sql/sb_ap_003_a1_product_classification.sql in Supabase first.
#   2. production_scored.csv must be in DIWAAIS (or pass --csv <path>).
#   3. Set env vars SUPABASE_URL and SUPABASE_KEY (anon key is fine).
#      Or pass --url and --key on the command line.
#
# HOW TO RUN:
#   python load_product_classification.py --store 10116 --version 1.0-del
#
# OPTIONAL:
#   --csv   "C:\path\to\production_scored.csv"    (default: looks in DIWAAIS)
#   --url   "https://crklvhfwyxlisfcvqenc.supabase.co"
#   --key   "sb_publishable__..."
#   --dry-run    Print summary without writing to Supabase.
#
# WHAT IT DOES:
#   Reads production_scored.csv, maps columns, then upserts into
#   product_classification in batches of 500 rows. Existing rows for the
#   same (store_code, ean) are overwritten — this is intentional so re-runs
#   pick up classifier updates. Human-confirmed rows (confirmed_by IS NOT NULL)
#   are NOT overwritten — add --force to override.
# =============================================================================

import csv
import json
import os
import sys
import argparse
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
DEFAULT_CSV  = r"C:\Users\User\Desktop\DIWAAIS\production_scored.csv"
DEFAULT_URL  = "https://crklvhfwyxlisfcvqenc.supabase.co"
BATCH_SIZE   = 500
TABLE        = "product_classification"
CLASSIFIER_VERSION_PREFIX = "1.0"  # bumped when classifier logic changes

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ap = argparse.ArgumentParser(description="Load production_scored.csv into Supabase")
ap.add_argument("--store",   required=True,  help="Store code e.g. 10116")
ap.add_argument("--version", default=None,   help="Classifier version label e.g. 1.0-del")
ap.add_argument("--csv",     default=None,   help="Path to production_scored.csv")
ap.add_argument("--url",     default=None,   help="Supabase URL")
ap.add_argument("--key",     default=None,   help="Supabase anon or service key")
ap.add_argument("--dry-run", action="store_true", help="Print summary, do not write")
ap.add_argument("--force",   action="store_true", help="Overwrite human-confirmed rows")
args = ap.parse_args()

STORE_CODE = args.store.strip()
CSV_PATH   = args.csv or DEFAULT_CSV
URL        = args.url or os.environ.get("SUPABASE_URL", DEFAULT_URL)
KEY        = args.key or os.environ.get("SUPABASE_KEY", "")
VERSION    = args.version or (CLASSIFIER_VERSION_PREFIX + "-" + STORE_CODE[:3].lower())
SCORED_AT  = datetime.now(timezone.utc).isoformat()

if not KEY:
    sys.exit("ERROR: Supabase key required. Set SUPABASE_KEY env var or pass --key.")

if not os.path.exists(CSV_PATH):
    sys.exit(f"ERROR: CSV not found: {CSV_PATH}")

# ---------------------------------------------------------------------------
# Classification mapping
# ---------------------------------------------------------------------------
def derive_classification(row):
    """Map classifier output columns to a single classification label."""
    if row.get("production_flag", "").strip() == "Y":
        return "PRODUCTION"
    quad = row.get("quadrant", "").strip()
    band = row.get("band", "").strip()
    if quad == "INERT":
        return "INERT"
    if band == "REVIEW":
        return "SUSPECT"   # score 2-4; needs human review
    return "RETAIL"         # score < 2, bought-in retail

# ---------------------------------------------------------------------------
# Load CSV
# ---------------------------------------------------------------------------
print(f"Loading: {CSV_PATH}")
print(f"Store:   {STORE_CODE}  |  Version: {VERSION}")
print()

rows = []
with open(CSV_PATH, encoding="utf-8-sig", newline="") as fh:
    for r in csv.DictReader(fh):
        ean = r.get("ean", "").strip()
        if not ean:
            continue
        rows.append({
            "store_code":         STORE_CODE,
            "ean":                ean,
            "classification":     derive_classification(r),
            "band":               r.get("band", "STOCK").strip() or "STOCK",
            "score":              int(r.get("score", 0) or 0),
            "why_flagged":        r.get("why_flagged", "").strip() or None,
            "classifier_version": VERSION,
            "scored_at":          SCORED_AT,
            # confirmed_by / confirmed_at intentionally omitted — null on load
        })

# Band summary
from collections import Counter
band_counts = Counter(r["band"] for r in rows)
cls_counts  = Counter(r["classification"] for r in rows)

print(f"Rows read:       {len(rows):,}")
print(f"Bands:           " + "  ".join(f"{k}={v}" for k, v in sorted(band_counts.items())))
print(f"Classification:  " + "  ".join(f"{k}={v}" for k, v in sorted(cls_counts.items())))
print()

if args.dry_run:
    print("DRY RUN — nothing written.")
    sys.exit(0)

# ---------------------------------------------------------------------------
# Upsert to Supabase (REST API, batched)
# ---------------------------------------------------------------------------
endpoint = f"{URL.rstrip('/')}/rest/v1/{TABLE}"
headers = {
    "apikey":          KEY,
    "Authorization":   f"Bearer {KEY}",
    "Content-Type":    "application/json",
    "Prefer":          "resolution=merge-duplicates,return=minimal",
}

# If --force is NOT set, exclude rows where confirmed_by is already set.
# We achieve this by using upsert with ignoreDuplicates=false (default) but
# Supabase REST upsert always overwrites — to protect confirmed rows we must
# filter them out before upserting.
if not args.force:
    # Fetch EANs that are already human-confirmed for this store.
    protected_url = (
        f"{endpoint}?store_code=eq.{STORE_CODE}"
        f"&confirmed_by=not.is.null"
        f"&select=ean"
    )
    req = urllib.request.Request(
        protected_url,
        headers={k: v for k, v in headers.items() if k != "Prefer"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            protected = {r["ean"] for r in json.loads(resp.read())}
    except urllib.error.HTTPError as e:
        protected = set()

    if protected:
        before = len(rows)
        rows = [r for r in rows if r["ean"] not in protected]
        print(f"Skipped {before - len(rows):,} human-confirmed rows (use --force to overwrite).")

batches = [rows[i:i+BATCH_SIZE] for i in range(0, len(rows), BATCH_SIZE)]
print(f"Upserting {len(rows):,} rows in {len(batches)} batches of {BATCH_SIZE}...")

loaded = 0
errors = 0
for i, batch in enumerate(batches, 1):
    payload = json.dumps(batch).encode("utf-8")
    req = urllib.request.Request(endpoint, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            loaded += len(batch)
            if i % 5 == 0 or i == len(batches):
                pct = round(loaded / len(rows) * 100)
                print(f"  Batch {i}/{len(batches)} — {loaded:,} rows ({pct}%)")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"  ERROR batch {i}: HTTP {e.code} — {body[:200]}")
        errors += 1
        if errors >= 3:
            sys.exit("Too many errors — aborting.")

print()
print(f"Done. Loaded: {loaded:,}  Errors: {errors}")
if errors == 0:
    print()
    print("VERIFY in Supabase SQL editor:")
    print(f"  SELECT band, COUNT(*) FROM product_classification")
    print(f"  WHERE store_code = '{STORE_CODE}'")
    print(f"  GROUP BY band ORDER BY band;")
    print()
    print(f"Expected: AUTO_EXCLUDE={band_counts.get('AUTO_EXCLUDE',0)}  "
          f"REVIEW={band_counts.get('REVIEW',0)}  "
          f"STOCK={band_counts.get('STOCK',0)}")
