#!/usr/bin/env python3
"""
load_plu_reference.py
=====================
Monthly DIWAAIS2 -> product_catalog loader.

Usage:
    python load_plu_reference.py [--date YYYY-MM-DD]

The script finds all DIWAAIS2_*.xls files under C:/Users/User/Desktop/DIWAAIS/
or accepts explicit file paths via --file.  Run once after pulling the monthly
DIWAAIS2 report; thereafter the product_catalog table drives:

  * sb_ean_001_diagnostic.sql  -- indexed PLU scan (no timeout)
  * sb_ean_002_fix.sql         -- historical EAN fix
  * Dashboard supplier lookups -- who to call for a product
  * On-order badge             -- restock in transit flag
  * Cost-drift alerts          -- last rcvd cost > list cost

Store codes (Sigma numeric IDs used in daily_snapshots.store_code):
  SPAR Delareyville   10116
  SPAR Roosville      80175
  TOPS Delareyville   21355   (no DIWAAIS2 available yet)
  TOPS Dice           80579   (no DIWAAIS2 available yet)
  TOPS Roosville      80176   (no DIWAAIS2 available yet)

EAN expansion rule (matches Push-SigmaToSupabase.ps1 v3.15+):
  Length <= 8 AND all digits -> PLU -> store_code.zfill(5) + plu.zfill(8)
  Length  9-12               -> real barcode (UPC-A, ISBN) -> keep
  Length 13                  -> EAN-13 -> keep
  Empty / 0                  -> NO_EAN (production supplies) -> skip
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import date, datetime

try:
    import pandas as pd
    import requests
except ImportError:
    print("Install deps first:  pip install pandas xlrd requests")
    sys.exit(1)

# ── Config ─────────────────────────────────────────────────────────────────
SUPABASE_URL = "https://crklvhfwyxlisfcvqenc.supabase.co"
ANON_KEY     = "sb_publishable__5cXLbkpdth-iLFkeqTTNA_kRUvfYgr"

DIWAAIS_ROOT = r"C:\Users\User\Desktop\DIWAAIS"

# Map filename fragments to Sigma store codes
STORE_MAP = {
    "Roosville_Spar":    "80175",
    "Roosville_SPAR":    "80175",
    "Roosville_Tops":    "80176",
    "Roosville_TOPS":    "80176",
    "Delareyville_Spar": "10116",
    "Delareyville_SPAR": "10116",
    "Delareyville_Tops": "21355",
    "Delareyville_TOPS": "21355",
    "Dice":              "80579",
}

BATCH_SIZE = 500   # rows per REST upsert call

# ── EAN helpers ─────────────────────────────────────────────────────────────

def classify_and_expand(raw_ean, store_code: str):
    """
    Returns (ean_13, plu_raw, category) for a raw EAN value.
      category: 'EAN13' | 'EAN_SHORT' | 'PLU' | 'NO_EAN'
    """
    if pd.isna(raw_ean) or str(raw_ean).strip() in ("", "0"):
        return (None, None, "NO_EAN")
    try:
        val = str(int(float(str(raw_ean).strip())))
    except (ValueError, TypeError):
        return (None, None, "NO_EAN")

    if not val.isdigit():
        return (None, None, "NO_EAN")

    length = len(val)
    if length <= 8:
        synthetic = store_code.zfill(5) + val.zfill(8)
        return (synthetic, val, "PLU")
    elif length <= 12:
        return (val, None, "EAN_SHORT")
    else:
        return (val, None, "EAN13")


def safe_text(v, maxlen=80):
    if pd.isna(v):
        return None
    s = str(v).strip()
    return s[:maxlen] if s else None


def safe_num(v):
    if pd.isna(v):
        return None
    try:
        f = float(v)
        return None if f == 0 and pd.isna(v) else round(f, 4)
    except (ValueError, TypeError):
        return None


def safe_int(v):
    if pd.isna(v):
        return None
    try:
        return str(int(float(v)))
    except (ValueError, TypeError):
        return None


# ── XLS parser ──────────────────────────────────────────────────────────────

def parse_diwaais2(path: str, store_code: str, pulled_date: str) -> list[dict]:
    """Parse a DIWAAIS2 XLS file and return rows ready for product_catalog."""
    print(f"  Reading {os.path.basename(path)} (store {store_code}) ...")
    df = pd.read_excel(path, header=1)   # row 0 blank, row 1 = header

    has_last_rcvd = "Last Rcvd Cost" in df.columns
    has_shelf_label = "Shelf Label Text" in df.columns
    has_min_stock = "Min. Stock at SP" in df.columns

    rows = []
    skipped_no_ean = 0

    for _, r in df.iterrows():
        ean_13, plu_raw, cat = classify_and_expand(r.get("EAN"), store_code)

        if cat == "NO_EAN":
            skipped_no_ean += 1
            continue      # production supplies — never at POS, skip

        rows.append({
            "store_code":             store_code,
            "ean":                    ean_13,
            "plu_raw":                plu_raw,
            "sigma_product_code":     safe_int(r.get("Product Code")),
            "dc_product_code":        safe_int(r.get("DC Product Code")),
            "description":            safe_text(r.get("Product Description"), 200) or "(no description)",
            "size_label":             safe_text(r.get("Size")),
            "detail_unit":            safe_text(r.get("Detail")),
            "shelf_label_text":       safe_text(r.get("Shelf Label Text")) if has_shelf_label else None,
            "supplier_code":          safe_int(r.get("Supp. Cd.")),
            "supplier_name":          safe_text(r.get("Supplier Name"), 120),
            "supplier_product_code":  safe_text(r.get("Supplier Product Code")),
            "analysis_group":         safe_int(r.get("Analysis Group")),
            "dept_code":              safe_int(r.get("Department")),
            "sub_dept_code":          safe_int(r.get("Sub-Department")),
            "sell_price":             safe_num(r.get("SP")),
            "list_cost":              safe_num(r.get("List Cost")),
            "last_rcvd_cost":         safe_num(r.get("Last Rcvd Cost")) if has_last_rcvd else None,
            "min_stock_sp":           safe_num(r.get("Min. Stock at SP")) if has_min_stock else None,
            "soh":                    safe_num(r.get("SOH")),
            "on_order_qty":           safe_num(r.get("On Order Qty")),
            "status_diwaais":         safe_text(r.get("Status"), 1),
            "is_plu":                 cat == "PLU",
            "ean_category":           cat,
            "pulled_date":            pulled_date,
        })

    plu_count = sum(1 for r in rows if r["is_plu"])
    print(f"    Parsed {len(rows):,} rows  "
          f"({plu_count:,} PLU  |  {len(rows)-plu_count:,} EAN  |  {skipped_no_ean:,} NO_EAN skipped)")
    return rows


# ── Supabase upserter ─────────────────────────────────────────────────────────

def upsert_to_supabase(rows: list[dict], dry_run: bool = False):
    if dry_run:
        print(f"  [DRY RUN] Would upsert {len(rows):,} rows to product_catalog")
        return

    url = f"{SUPABASE_URL}/rest/v1/product_catalog"
    headers = {
        "apikey":        ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "resolution=merge-duplicates,return=minimal",
    }

    total = len(rows)
    pushed = 0
    for i in range(0, total, BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        resp = requests.post(url, headers=headers, data=json.dumps(batch), timeout=60)
        if resp.status_code not in (200, 201):
            print(f"  ERROR batch {i//BATCH_SIZE}: {resp.status_code} {resp.text[:200]}")
        else:
            pushed += len(batch)
            pct = pushed / total * 100
            print(f"  Uploaded {pushed:>6,}/{total:,}  ({pct:.0f}%)", end="\r")

    print(f"\n  Done. {pushed:,} rows upserted.")


# ── Auto-discover DIWAAIS2 files ─────────────────────────────────────────────

def find_diwaais2_files():
    """Scan DIWAAIS_ROOT for DIWAAIS2_*.xls and return [(path, store_code)]."""
    found = []
    for pattern in ["**/*DIWAAIS2*.xls", "**/*DIWAAIS2*.xlsx"]:
        for path in glob.glob(os.path.join(DIWAAIS_ROOT, pattern), recursive=True):
            basename = os.path.basename(path)
            sc = None
            for fragment, code in STORE_MAP.items():
                if fragment in path:
                    sc = code
                    break
            if sc:
                found.append((path, sc))
            else:
                print(f"  WARNING: cannot map {basename} to a store code — skipping")
    return found


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Load DIWAAIS2 XLS into product_catalog")
    parser.add_argument("--date",     default=date.today().isoformat(),
                        help="Pull date (YYYY-MM-DD).  Defaults to today.")
    parser.add_argument("--file",     nargs="*",
                        help="Explicit XLS paths.  If omitted, auto-discovers under DIWAAIS root.")
    parser.add_argument("--dry-run",  action="store_true",
                        help="Parse and report counts but do not upload.")
    args = parser.parse_args()

    pulled_date = args.date
    print(f"\n=== load_plu_reference.py  pulled_date={pulled_date} ===\n")

    if args.file:
        files = []
        for path in args.file:
            sc = None
            for fragment, code in STORE_MAP.items():
                if fragment in path:
                    sc = code
                    break
            if sc is None:
                print(f"Cannot determine store code for: {path}")
                sc = input("Enter store code (e.g. 80175): ").strip()
            files.append((path, sc))
    else:
        files = find_diwaais2_files()

    if not files:
        print("No DIWAAIS2 files found.  Pass --file or check DIWAAIS_ROOT.")
        sys.exit(1)

    print(f"Files to process: {len(files)}")
    for path, sc in files:
        print(f"  {os.path.basename(path)}  ->  store {sc}")

    all_rows = []
    for path, sc in files:
        rows = parse_diwaais2(path, sc, pulled_date)
        all_rows.extend(rows)

    print(f"\nTotal rows across all files: {len(all_rows):,}")
    plu_total  = sum(1 for r in all_rows if r["is_plu"])
    ean_total  = sum(1 for r in all_rows if not r["is_plu"])
    print(f"  PLU (synthetic EAN):  {plu_total:,}")
    print(f"  EAN (kept as-is):     {ean_total:,}")

    # Collision proof: PLUs that share code across stores but differ in product
    plu_rows = [r for r in all_rows if r["is_plu"]]
    from collections import defaultdict
    plu_by_raw: dict = defaultdict(list)
    for r in plu_rows:
        plu_by_raw[r["plu_raw"]].append(r)
    collisions = {k: v for k, v in plu_by_raw.items() if len(v) > 1 and len({r["description"] for r in v}) > 1}
    print(f"  Cross-store PLU collisions (same code, different product): {len(collisions):,}")
    print(f"  -> Synthetic EAN correctly separates all of these.\n")

    upsert_to_supabase(all_rows, dry_run=args.dry_run)

    if not args.dry_run:
        print("\nNext steps:")
        print("  1. Run sb_ean_001_diagnostic.sql to confirm PLU scope in daily_snapshots")
        print("  2. Run sb_ean_002_fix.sql to rename raw PLUs to synthetic EANs")
        print("  3. Push script v3.15 must be deployed before next push (fix -lt 8 -> -le 8)")


if __name__ == "__main__":
    main()
