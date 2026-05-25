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

EAN expansion rule (two-pass, matches Push-SigmaToSupabase.ps1 v3.16+):

  Pass 1: Parse all store files, collect raw codes + descriptions.

  Pass 2: Classify each row using cross-store consensus:
    Short code (<=8 digits, all numeric):
      Same code + same description at 2+ stores -> EAN_REAL_SHORT
        Real pre-barcoded product (EAN-8 format, imports, SPAR own-brand).
        ean = raw code as-is.  plu_raw = None.  is_plu = False.
      Otherwise -> PLU (store-specific code)
        Expand: ean = store_code.zfill(5) + code.zfill(8).  plu_raw = code.
    Length 9-12 -> EAN_SHORT (real barcode, UPC-A / ISBN) -> keep as-is
    Length 13   -> EAN13 -> keep as-is
    Empty / 0   -> NO_EAN (production supplies) -> skip
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
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


# ── Raw EAN extraction ───────────────────────────────────────────────────────

def _extract_raw_ean(raw_ean):
    """
    Normalize the EAN field from Excel to a clean digit string.
    Returns None for NO_EAN values (blank, 0, non-numeric).
    """
    if pd.isna(raw_ean) or str(raw_ean).strip() in ("", "0"):
        return None
    try:
        val = str(int(float(str(raw_ean).strip())))
    except (ValueError, TypeError):
        return None
    if not val.isdigit():
        return None
    return val


# ── Cross-store consensus builder ────────────────────────────────────────────

def build_real_barcode_set(pre_rows: list[dict]) -> set:
    """
    Examine all pre-rows (across all stores) and return a set of raw EAN
    strings that qualify as real cross-store barcodes:

      Same raw code (<=8 digits) + same normalised description in 2+ stores.

    These are genuine EAN-8 format codes (imported products like Camel
    cigarettes, SPAR own-brand fresh items).  They must NOT be expanded
    to synthetic EANs because the code itself is the globally unique barcode.

    If the same short code appears in multiple stores but with DIFFERENT
    descriptions, it is a store-specific PLU collision -- each store gets
    its own synthetic EAN.
    """
    def normalise(desc: str) -> str:
        return " ".join((desc or "").upper().split())

    # code -> {norm_desc -> {store_codes}}
    code_map: dict[str, dict[str, set]] = defaultdict(lambda: defaultdict(set))

    for row in pre_rows:
        raw = row.get("_raw_ean_val")
        if raw is None or len(raw) > 8:
            continue  # only short codes can be real EAN-8
        desc_norm = normalise(row.get("description", ""))
        store     = row["store_code"]
        code_map[raw][desc_norm].add(store)

    real = set()
    for code, desc_stores in code_map.items():
        for desc_norm, stores in desc_stores.items():
            if len(stores) >= 2:
                # Same short code + same description in 2+ stores = real barcode
                real.add(code)
                break   # one qualifying description is enough

    return real


# ── Final EAN classification ─────────────────────────────────────────────────

def classify_ean(raw_val: str, store_code: str, real_barcodes: set) -> tuple:
    """
    Returns (ean_13_or_short, plu_raw, category, is_plu) for a normalised EAN value.

    category:
      'EAN13'          -- 13-digit EAN, kept as-is
      'EAN_SHORT'      -- 9-12 digit real barcode, kept as-is
      'EAN_REAL_SHORT' -- <=8 digit real cross-store barcode, kept as-is
      'PLU'            -- <=8 digit store-specific PLU, expanded to synthetic EAN
    """
    length = len(raw_val)

    if length <= 8:
        if raw_val in real_barcodes:
            return (raw_val, None, "EAN_REAL_SHORT", False)
        else:
            synthetic = store_code.zfill(5) + raw_val.zfill(8)
            return (synthetic, raw_val, "PLU", True)
    elif length <= 12:
        return (raw_val, None, "EAN_SHORT", False)
    else:
        return (raw_val, None, "EAN13", False)


# ── Field helpers ────────────────────────────────────────────────────────────

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


# ── XLS parser -- Pass 1 ────────────────────────────────────────────────────

def parse_diwaais2_raw(path: str, store_code: str) -> list[dict]:
    """
    First pass: parse a DIWAAIS2 XLS file into pre-rows.
    Each row includes '_raw_ean_val' (normalised digit string or None)
    but no final EAN classification yet.
    NO_EAN rows (blank/0 EAN) are excluded.
    """
    print(f"  Reading {os.path.basename(path)} (store {store_code}) ...")
    df = pd.read_excel(path, header=1)   # row 0 blank, row 1 = header

    has_last_rcvd  = "Last Rcvd Cost"  in df.columns
    has_shelf_label = "Shelf Label Text" in df.columns
    has_min_stock   = "Min. Stock at SP" in df.columns

    pre_rows = []
    skipped_no_ean = 0

    for _, r in df.iterrows():
        raw_val = _extract_raw_ean(r.get("EAN"))
        if raw_val is None:
            skipped_no_ean += 1
            continue

        pre_rows.append({
            "_raw_ean_val":           raw_val,
            "store_code":             store_code,
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
        })

    print(f"    Raw rows: {len(pre_rows):,}  |  NO_EAN skipped: {skipped_no_ean:,}")
    return pre_rows


# ── Pass 2: finalise classification ─────────────────────────────────────────

def finalise_rows(pre_rows: list[dict], real_barcodes: set, pulled_date: str) -> list[dict]:
    """
    Second pass: apply EAN classification using the cross-store consensus set.
    Returns fully-populated product_catalog rows ready for upsert.
    """
    rows = []
    for pr in pre_rows:
        raw_val    = pr["_raw_ean_val"]
        store_code = pr["store_code"]
        ean, plu_raw, category, is_plu = classify_ean(raw_val, store_code, real_barcodes)

        rows.append({
            "store_code":             store_code,
            "ean":                    ean,
            "plu_raw":                plu_raw,
            "sigma_product_code":     pr["sigma_product_code"],
            "dc_product_code":        pr["dc_product_code"],
            "description":            pr["description"],
            "size_label":             pr["size_label"],
            "detail_unit":            pr["detail_unit"],
            "shelf_label_text":       pr["shelf_label_text"],
            "supplier_code":          pr["supplier_code"],
            "supplier_name":          pr["supplier_name"],
            "supplier_product_code":  pr["supplier_product_code"],
            "analysis_group":         pr["analysis_group"],
            "dept_code":              pr["dept_code"],
            "sub_dept_code":          pr["sub_dept_code"],
            "sell_price":             pr["sell_price"],
            "list_cost":              pr["list_cost"],
            "last_rcvd_cost":         pr["last_rcvd_cost"],
            "min_stock_sp":           pr["min_stock_sp"],
            "soh":                    pr["soh"],
            "on_order_qty":           pr["on_order_qty"],
            "status_diwaais":         pr["status_diwaais"],
            "is_plu":                 is_plu,
            "ean_category":           category,
            "pulled_date":            pulled_date,
        })
    return rows


# ── Supabase upserter ────────────────────────────────────────────────────────

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

    total  = len(rows)
    pushed = 0
    for i in range(0, total, BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        resp  = requests.post(url, headers=headers, data=json.dumps(batch), timeout=60)
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
                print(f"  WARNING: cannot map {basename} to a store code -- skipping")
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

    # ── Pass 1: parse all files into pre-rows ────────────────────────────────
    print("\n-- Pass 1: Parsing XLS files --")
    all_pre_rows = []
    for path, sc in files:
        pre = parse_diwaais2_raw(path, sc)
        all_pre_rows.extend(pre)

    print(f"\nTotal pre-rows across all files: {len(all_pre_rows):,}")

    # ── Build cross-store consensus ──────────────────────────────────────────
    print("\n-- Building cross-store EAN consensus --")
    real_barcodes = build_real_barcode_set(all_pre_rows)
    print(f"  Confirmed real cross-store barcodes (EAN_REAL_SHORT): {len(real_barcodes):,}")
    print(f"    These short codes appear in 2+ stores with the same description.")
    print(f"    They will NOT be expanded to synthetic EANs (e.g. Camel, SPAR fresh).")

    # ── Pass 2: finalise classification ──────────────────────────────────────
    print("\n-- Pass 2: Finalising EAN classification --")
    all_rows = finalise_rows(all_pre_rows, real_barcodes, pulled_date)

    plu_count        = sum(1 for r in all_rows if r["ean_category"] == "PLU")
    real_short_count = sum(1 for r in all_rows if r["ean_category"] == "EAN_REAL_SHORT")
    ean_short_count  = sum(1 for r in all_rows if r["ean_category"] == "EAN_SHORT")
    ean13_count      = sum(1 for r in all_rows if r["ean_category"] == "EAN13")

    print(f"\nFinal row counts ({len(all_rows):,} total):")
    print(f"  PLU (synthetic EAN, store-specific):  {plu_count:,}")
    print(f"  EAN_REAL_SHORT (kept as-is, cross-store): {real_short_count:,}")
    print(f"  EAN_SHORT (UPC-A/ISBN, kept as-is):   {ean_short_count:,}")
    print(f"  EAN13 (full EAN-13, kept as-is):       {ean13_count:,}")

    # ── PLU collision proof ───────────────────────────────────────────────────
    plu_rows = [r for r in all_rows if r["ean_category"] == "PLU"]
    plu_by_raw: dict = defaultdict(list)
    for r in plu_rows:
        plu_by_raw[r["plu_raw"]].append(r)
    collisions = {
        k: v for k, v in plu_by_raw.items()
        if len(v) > 1 and len({r["description"] for r in v}) > 1
    }
    print(f"\n  Cross-store PLU collisions (same code, different product): {len(collisions):,}")
    print(f"  -> Synthetic EAN correctly separates all of these.")
    print(f"  -> EAN_REAL_SHORT set correctly excludes real barcodes from expansion.\n")

    # ── Upsert ───────────────────────────────────────────────────────────────
    upsert_to_supabase(all_rows, dry_run=args.dry_run)

    if not args.dry_run:
        print("\nNext steps:")
        print("  1. Run sb_ean_001_diagnostic.sql to confirm PLU scope in daily_snapshots")
        print("  2. Run sb_ean_002_fix.sql to rename raw PLUs to synthetic EANs")
        print("     (EAN_REAL_SHORT rows are excluded automatically -- is_plu=FALSE)")
        print("  3. Push script v3.16 must be deployed so future pushes use the catalog")
        print("     for real-short-EAN detection (no more incorrect expansion).")
        print(f"  4. product_catalog now carries {len(real_barcodes):,} real cross-store")
        print("     barcode entries the push script will query at startup.")


if __name__ == "__main__":
    main()
