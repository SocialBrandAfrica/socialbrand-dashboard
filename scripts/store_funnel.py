#!/usr/bin/env python3
"""
store_funnel.py  --  SB-AP-004 A1
=============================================================================
Elimination-funnel classifier for Sigma article data.
Keyed on dArtNr (EASYDB / dw220sdb article number -- the canonical server key).

Supersedes
----------
  store_classifier.py  (PRSSALE-signal classifier) -- RETIRED, do not use
  product_reference_import.csv as classifier input  -- RETIRED, do not use

Inputs
------
Three dArtNr-keyed CSVs from a Sigma SQL Server (same schema on all 5 stores):
  supplier_type  TYP / sTYP  (Z=DC / S=DRP / F=DIR)
  lifecycle      dtDatWE (last receipt), dtDatUms (last sale),
                 VerkWk1-6 + AktVerkWk1-6 (weekly sales),
                 dBestand (SOH), dMinBest, StockDays
  dbarts         description + dept + sub-dept

Legacy Roosville format (simplified extract) is also accepted; the loader
normalises both column sets to a single internal schema.

Outputs
-------
  <store>_classified.csv         full per-item table (analysis use)
  <store>_supabase_upload.csv    upload-ready for product_classification table
                                 (HOLD -- do not upload until bridge is proven;
                                  see Bridge Status below)

8-bucket funnel (order is load-bearing -- first match wins)
-----------------------------------------------------------
  1  NON_STOCK        packaging / expense / cleaning / advertising by dept or
                      sub-dept name.  Consumed by store, never sold as a unit.
  2  PARENT_CHILD     description ends with _N suffix (_6 / _12 / _24) indicating
                      a pack-parent of a single unit.  Same product, integer
                      multiplier, NOT a recipe.
  3  PRODUCTION       sells but has never been formally received (or last receipt
                      older than one year), in a production dept (BAKERY, BUTCHERY,
                      HMR, DELI, COFFEE, FISH).  Detect only -- no BOM / costing.
  4  DEAD_SLOW        received + has positive SOH + zero sales across all 12
                      recorded weeks.  Real dead capital.
  5  DELISTED         no stock + no sales (includes items in dbarts only with no
                      lifecycle record -- truly dormant / never stocked).
  6  NORMAL           sells and has been received.  Retail stock.
  7  RECEIPTING_BREAK large negative SOH (below -50) with DC or DRP supplier type.
                      Data-integrity issue; fix at source, not here.
  8  UNCERTAIN        residual that does not fit any of the above clearly.

Side stream (flag, not a class)
--------------------------------
  fresh_stock_alert   item in a short-shelf-life perishable dept, positive SOH,
                      and no recorded sale for >= 30 days.  Physically impossible
                      stock.  Route to Stock Integrity report.

Capital Tied / Top 20 exclusions (once bridge is proven)
---------------------------------------------------------
  Exclude: PRODUCTION, NON_STOCK, RECEIPTING_BREAK
  Ghost Stock report:       PRODUCTION, NON_STOCK
  Stock Integrity report:   RECEIPTING_BREAK + fresh_stock_alert = True

Bridge Status -- READ BEFORE WIRING TO DASHBOARD
-------------------------------------------------
  BLOCKED as of 2026-06-01.  Empirically proven on store 10116:
    dArtNr=50 (EASYDB) = "ESS BUNSPICE"
    daily_snapshots[ean='1011600000050'] = "HALF DOSYN EIERS"
  EASYDB dArtNr and PRSSALE PLU are completely different numbering systems.
  The formula store_code + dArtNr.zfill(8) does NOT resolve to daily_snapshots.ean.
  Bridge requires: Pieter pulls IntellistoX_EAN_Master from EASYDB (33,201 rows).
    USE EASYDB;
    SELECT dArtNr, cEAN, cTYP FROM IntelliAcc.IntellistoX_EAN_Master;
  Once that CSV lands, the bridge can be built and A2/A3/A4 proceed.
  Until then: keep this output in DIWAAIS only. Do not touch the live dashboard.

Usage
-----
  python store_funnel.py --store 10116
      --supplier-type  dela_supplier_type.csv
      --lifecycle      dela_lifecycle.csv
      --dbarts         dela_dbarts_dept.csv
      [--out-dir       DIWAAIS]
      [--precision-check  production_labelling_sample.csv]
      [--today YYYY-MM-DD]
"""

import csv
import re
import sys
import argparse
import datetime
from collections import Counter
from pathlib import Path

# ---------------------------------------------------------------------------
CLASSIFIER_VERSION = "v2.0-dArtNr"

# ---------------------------------------------------------------------------
# Domain constants
# ---------------------------------------------------------------------------

PRODUCTION_DEPTS = {
    "BAKERY", "BUTCHERY", "HMR", "DELI", "DELICATESSEN",
    "COFFEE SHOP", "COFFEE", "SEAFOOD", "FISH SHOP", "FISH",
}

# Sub-dept keyword fragments that strongly indicate in-store production context.
# Only used inside production depts to boost confidence -- not as a standalone
# trigger (avoids false positives in non-production depts that might share words).
PRODUCTION_SUBDEPT_SIGNALS = [
    "PRODUCTION", "(PRODUCTI",   # Sigma truncates to 30 chars, see "(PRODUCTI"
    "INGREDIENTS",
    "CATERING",
    "SCALE PRODUCT",
    "WASTAGE",
]

# Depts whose entire output is non-stock (expense, admin, logistics).
NON_STOCK_DEPTS = {
    "EXPENSES",
    "FRONTEND PACK",
    "NON SCAN SALES",
    "DEPARTMENT OVERS/UNDERS",   # pre-uppercased
    "AIRTIME",
    "SPAR MOBILE",
    "ONLINE VAS PRODUCTS",
    "ONLINE TRANSACTIONS",
    "DC - SPECIAL PROMOTIONS",
}

# Sub-dept keyword fragments that reliably indicate non-stock regardless of dept.
# IMPORTANT: only include patterns that are unambiguous:
#   - "PACKAGING"  matches BUTCHERY PACKAGING, BAKERY PACKAGING, etc.
#                  does NOT match SWEETS BAGS, KIT- FOILS/WRAPS (retail).
#   - "CRATE"      matches CRATES OTHER, CRATES - ABI.
#   - "ADVERTISING" matches ADVERTISING GENERAL / LEAFLETS / GUILD FEES.
#   - "PACK & WRAP" / "PACK&WRAP" matches wrap-cost allocations.
#   - "FUTURE USE"  placeholder / unallocated article codes.
# Excluded deliberately: STATIONERY (retail dept), CLEANING (retail products),
#   HARDWARE (retail), BAGS (SWEETS BAGS is retail), SUPPLY (too generic).
NON_STOCK_SUBDEPT_SIGNALS = [
    "PACKAGING",
    "CRATE",
    "ADVERTISING",
    "PACK & WRAP",
    "PACK&WRAP",
    "FUTURE USE",
]

# Perishable depts eligible for fresh-stock alerts.
FRESH_DEPTS = {
    "BAKERY", "BUTCHERY", "HMR", "DELI", "DELICATESSEN",
    "PRODUCE", "PERISHABLES", "FISH SHOP", "FISH", "SEAFOOD",
    "FLOWERS", "COFFEE SHOP",
}

# Sub-dept fragments that indicate long shelf-life even inside a fresh dept.
# These are excluded from the fresh-stock alert (they can legitimately hold stock).
FRESH_EXCLUDE_SUBDEPT_SIGNALS = [
    "FROZEN", "ICE CREAM", "LONG LIFE", "LONG-LIFE",
    "CANNED", "TINNED", "PACKAGING", "INGREDIENTS",
    "BUY OUT", "PREPACKED", "CONFECTIONARY", "RUSKS",
    "BISCUITS", "FUTURE USE",
]

# Regex for PARENT_CHILD detection.
# Matches descriptions containing _N where N is 2-3 digits (pack size marker).
# Examples: BACARDI BREEZER PEACH_24 275ML, CLOVER MILK UHT FAT FRE_6
PACK_SUFFIX_RE = re.compile(r"_(\d{1,3})(?:\s|$)")

# SOH threshold below which (with DC/DRP supplier) = RECEIPTING_BREAK.
NEG_SOH_THRESHOLD = -50

# Days since last receipt to classify as "never formally received" for PRODUCTION.
# Items last received more than one year ago are treated as never received for
# purposes of the production heuristic.
LONG_NO_RECV_DAYS = 365

# Days without a sale while holding positive stock = fresh-stock alert.
FRESH_NO_MOVE_DAYS = 30

# Band mapping: class -> actionable band for the product_classification table.
BAND = {
    "NON_STOCK":        "AUTO_EXCLUDE",
    "PRODUCTION":       "AUTO_EXCLUDE",
    "RECEIPTING_BREAK": "AUTO_EXCLUDE",
    "PARENT_CHILD":     "REVIEW",
    "DEAD_SLOW":        "REVIEW",
    "UNCERTAIN":        "REVIEW",
    "NORMAL":           "STOCK",
    "DELISTED":         "STOCK",
}

EXCLUDE_CAPITAL_TIED = {"PRODUCTION", "NON_STOCK", "RECEIPTING_BREAK"}
GHOST_STOCK_REPORT   = {"PRODUCTION", "NON_STOCK"}
STOCK_INTEGRITY_RPT  = {"RECEIPTING_BREAK"}    # plus fresh_stock_alert flag


# ---------------------------------------------------------------------------
# CSV loading helpers
# ---------------------------------------------------------------------------

def _normalise_key(k: str) -> str:
    """Lower-case and normalise the dArtNr key column to 'art_nr'."""
    k = k.strip().lower()
    return "art_nr" if k == "dartnr" else k


def _load_csv(path: str) -> list:
    """Load a CSV, normalise column names.  Returns list of dicts."""
    rows = []
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                rows.append(
                    {_normalise_key(k): (v or "").strip() for k, v in row.items()}
                )
    except FileNotFoundError:
        print(f"  ERROR: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    return rows


def _float(v, default: float = 0.0) -> float:
    try:
        return float(v) if v not in ("", None) else default
    except (ValueError, TypeError):
        return default


def _date(v: str):
    """Return datetime.date or None.  Handles Sigma sentinel 1990-01-01."""
    if not v or v in ("", "None", "NULL", "1900-01-01", "1990-01-01", "0001-01-01"):
        return None
    try:
        return datetime.date.fromisoformat(v[:10])
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Signal helpers
# ---------------------------------------------------------------------------

def _total_sales(row: dict) -> float:
    """Sum all 12 weekly sales columns (Dela: VerkWk1-6 + AktVerkWk1-6,
    and legacy Roosville: wk_sum + aktwk_sum)."""
    total = 0.0
    for i in range(1, 7):
        total += _float(row.get(f"verkwk{i}"))
        total += _float(row.get(f"aktverkwk{i}"))
    total += _float(row.get("wk_sum"))     # legacy format
    total += _float(row.get("aktwk_sum"))  # legacy format
    return total


def _current_sales(row: dict) -> float:
    """Current-period sales: AktVerkWk1-6 or legacy aktwk_sum."""
    total = 0.0
    for i in range(1, 7):
        total += _float(row.get(f"aktverkwk{i}"))
    total += _float(row.get("aktwk_sum"))
    return total


# ---------------------------------------------------------------------------
# Funnel classifier
# ---------------------------------------------------------------------------

def _fresh_alert(dept: str, subdept: str, soh: float,
                 last_sold, today: datetime.date) -> bool:
    """Side stream: perishable + positive SOH + no movement >= 30 days."""
    if dept not in FRESH_DEPTS:
        return False
    if any(kw in subdept for kw in FRESH_EXCLUDE_SUBDEPT_SIGNALS):
        return False
    if soh <= 0:
        return False
    if last_sold is None:
        return True  # has stock, never sold -- physically impossible
    return (today - last_sold).days >= FRESH_NO_MOVE_DAYS


def classify(row: dict, today: datetime.date):
    """
    Apply the 8-bucket funnel to a merged row.

    Parameters
    ----------
    row   : merged dict from dbarts + lifecycle + supplier_type
    today : reference date for age calculations

    Returns
    -------
    (class_name, confidence_0_to_1, reason_str, fresh_alert_bool)
    """
    dept    = row.get("dept_name",    "").upper().strip()
    subdept = row.get("sub_dept_name","").upper().strip()
    desc    = row.get("description",  "").upper().strip()
    styp    = row.get("styp", "").upper().strip()   # sTYP: DC / DRP / DIR
    typ     = row.get("typ",  "").upper().strip()   # TYP:  Z / S / F

    soh        = _float(row.get("dbestand") or row.get("soh"))
    last_recv  = _date(row.get("dtdatwe")  or row.get("last_recv"))
    last_sold  = _date(row.get("dtdatums") or row.get("last_sold"))
    total_s    = _total_sales(row)
    current_s  = _current_sales(row)

    is_dc_drp      = styp in ("DC", "DRP") or typ in ("Z", "S")
    in_prod_dept   = dept in PRODUCTION_DEPTS
    prod_subdept_ok= any(kw in subdept for kw in PRODUCTION_SUBDEPT_SIGNALS)
    never_received = (last_recv is None
                      or (today - last_recv).days > LONG_NO_RECV_DAYS)
    has_stock      = soh > 0
    has_receipt    = last_recv is not None
    has_any_sales  = total_s > 0

    alert = _fresh_alert(dept, subdept, soh, last_sold, today)

    # ------------------------------------------------------------------
    # Bucket 1: NON_STOCK
    # ------------------------------------------------------------------
    if (dept in NON_STOCK_DEPTS
            or any(kw in subdept for kw in NON_STOCK_SUBDEPT_SIGNALS)):
        return ("NON_STOCK", 1.0,
                f"dept={dept}|subdept={subdept}", alert)

    # ------------------------------------------------------------------
    # Bucket 2: PARENT_CHILD
    # ------------------------------------------------------------------
    m = PACK_SUFFIX_RE.search(desc)
    if m and int(m.group(1)) >= 2:
        return ("PARENT_CHILD", 0.90,
                f"pack_n={m.group(1)}|desc_fragment={desc[-20:]}", alert)

    # ------------------------------------------------------------------
    # Bucket 3: PRODUCTION
    # ------------------------------------------------------------------
    if in_prod_dept and (has_any_sales or current_s > 0) and never_received:
        # Higher confidence when the sub-dept name also signals production
        conf = 0.95 if prod_subdept_ok else 0.80
        return ("PRODUCTION", conf,
                f"dept={dept}|subdept={subdept}|total_sales={total_s:.0f}|no_recv",
                alert)

    # ------------------------------------------------------------------
    # Bucket 7: RECEIPTING_BREAK  (before DEAD_SLOW -- large neg SOH trumps)
    # ------------------------------------------------------------------
    if soh < NEG_SOH_THRESHOLD and is_dc_drp:
        return ("RECEIPTING_BREAK", 0.85,
                f"soh={soh:.0f}|supplier_typ={styp or typ}", alert)

    # ------------------------------------------------------------------
    # Bucket 4: DEAD_SLOW
    # ------------------------------------------------------------------
    if has_receipt and has_stock and not has_any_sales:
        return ("DEAD_SLOW", 0.90,
                f"soh={soh:.2f}|last_recv={last_recv}|total_sales=0", alert)

    # ------------------------------------------------------------------
    # Bucket 5: DELISTED
    # ------------------------------------------------------------------
    # No stock, no sales, no receipt history -- truly dormant
    if not has_stock and not has_any_sales and not has_receipt:
        return ("DELISTED", 0.95, "soh=0|no_recv|no_sales", False)

    # Received in the past but now zero stock, zero sales
    if has_receipt and not has_stock and not has_any_sales:
        return ("DELISTED", 0.90,
                f"last_recv={last_recv}|soh=0|no_sales", False)

    # ------------------------------------------------------------------
    # Bucket 6: NORMAL
    # ------------------------------------------------------------------
    if has_any_sales and has_receipt:
        return ("NORMAL", 1.0,
                f"total_sales={total_s:.0f}|last_recv={last_recv}", False)

    # Sells but has never been received -- could be production missed above
    if has_any_sales and not has_receipt:
        if in_prod_dept:
            return ("PRODUCTION", 0.70,
                    f"dept={dept}|no_recv|sales={total_s:.0f}|low_conf", alert)
        return ("UNCERTAIN", 0.50,
                f"sells_no_recv|dept={dept}|sales={total_s:.0f}", alert)

    # ------------------------------------------------------------------
    # Bucket 8: UNCERTAIN
    # ------------------------------------------------------------------
    return ("UNCERTAIN", 0.30,
            f"dept={dept}|soh={soh:.2f}|sales={total_s:.0f}|recv={has_receipt}",
            alert)


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

def run_funnel(store_code: str,
               supplier_type_csv: str,
               lifecycle_csv: str,
               dbarts_csv: str,
               out_dir: str = ".",
               today: datetime.date = None) -> tuple:
    """
    Load three CSVs, classify every article, write results.

    Returns
    -------
    (results_list, counts_Counter)
    """
    if today is None:
        today = datetime.date.today()

    print(f"\n{'='*70}")
    print(f"  store_funnel.py  {CLASSIFIER_VERSION}  |  store {store_code}  |  {today}")
    print(f"{'='*70}")

    sup_rows = _load_csv(supplier_type_csv)
    lc_rows  = _load_csv(lifecycle_csv)
    db_rows  = _load_csv(dbarts_csv)

    sup_by = {r["art_nr"]: r for r in sup_rows if r.get("art_nr")}
    lc_by  = {r["art_nr"]: r for r in lc_rows  if r.get("art_nr")}
    db_ids = {r["art_nr"] for r in db_rows      if r.get("art_nr")}

    print(f"\n  Rows loaded:")
    print(f"    supplier_type : {len(sup_rows):>8,}")
    print(f"    lifecycle     : {len(lc_rows):>8,}")
    print(f"    dbarts        : {len(db_rows):>8,}")

    # Items in lifecycle that have no dbarts row (rare; classify from signals only)
    lc_only_ids = set(lc_by.keys()) - db_ids
    if lc_only_ids:
        print(f"    lifecycle-only (no dbarts row): {len(lc_only_ids):,}")

    results = []

    def _classify_item(art_nr: str, db_row: dict):
        """Merge all three sources and classify one article."""
        merged = {}
        if db_row:
            merged.update(db_row)
        if art_nr in lc_by:
            merged.update(lc_by[art_nr])
        if art_nr in sup_by:
            merged.update(sup_by[art_nr])
        merged["art_nr"] = art_nr

        cls, conf, reason, fresh = classify(merged, today)

        soh_val  = _float(merged.get("dbestand") or merged.get("soh"))
        desc     = db_row.get("description", "") if db_row else merged.get("description", "")
        dept     = merged.get("dept_name", "")
        subdept  = merged.get("sub_dept_name", "")

        # Synthetic EAN (forward design -- NOT yet valid for daily_snapshots join;
        # see Bridge Status note in module docstring).
        synthetic_ean = f"{store_code}{art_nr.zfill(8)}"

        return {
            "store_code":        store_code,
            "dArtNr":            art_nr,
            "synthetic_ean":     synthetic_ean,
            "description":       desc,
            "dept_name":         dept,
            "sub_dept_name":     subdept,
            "supplier_typ":      merged.get("typ", ""),
            "supplier_styp":     merged.get("styp",
                                           merged.get("supplier_type", "")),
            "soh":               f"{soh_val:.4g}",
            "last_recv":         merged.get("dtdatwe",
                                           merged.get("last_recv", "")),
            "last_sold":         merged.get("dtdatums",
                                           merged.get("last_sold", "")),
            "total_sales_wks":   f"{_total_sales(merged):.1f}",
            "class":             cls,
            "confidence":        f"{conf:.2f}",
            "band":              BAND.get(cls, "REVIEW"),
            "exclude_capital":   str(cls in EXCLUDE_CAPITAL_TIED),
            "ghost_stock_rpt":   str(cls in GHOST_STOCK_REPORT),
            "stock_integrity":   str(cls in STOCK_INTEGRITY_RPT or fresh),
            "fresh_alert":       str(fresh),
            "reason":            reason,
            "classifier_version": CLASSIFIER_VERSION,
        }

    # ------------------------------------------------------------------
    # Classify every article in dbarts (the full article universe)
    # ------------------------------------------------------------------
    for db_row in db_rows:
        art_nr = db_row.get("art_nr", "").strip()
        if not art_nr:
            continue
        results.append(_classify_item(art_nr, db_row))

    # Also classify lifecycle-only articles (no dbarts entry)
    for art_nr in lc_only_ids:
        results.append(_classify_item(art_nr, None))

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    counts = Counter(r["class"] for r in results)
    total  = len(results)
    fresh_total  = sum(1 for r in results if r["fresh_alert"]    == "True")
    excl_total   = sum(1 for r in results if r["exclude_capital"] == "True")
    ghost_total  = sum(1 for r in results if r["ghost_stock_rpt"] == "True")
    integ_total  = sum(1 for r in results if r["stock_integrity"] == "True")

    print(f"\n  Classification results  (n={total:,})")
    print(f"  {'Class':<20} {'Count':>8}  {'%':>6}  {'Band'}")
    print(f"  {'-'*52}")
    for cls_name in ["NON_STOCK", "PARENT_CHILD", "PRODUCTION",
                     "DEAD_SLOW", "DELISTED", "NORMAL",
                     "RECEIPTING_BREAK", "UNCERTAIN"]:
        n = counts.get(cls_name, 0)
        print(f"  {cls_name:<20} {n:>8,}  {n/total*100:>5.1f}%  "
              f"{BAND.get(cls_name,'')}")
    print(f"  {'-'*52}")
    print(f"  {'TOTAL':<20} {total:>8,}")
    print()
    print(f"  Excluded from Capital Tied (AUTO_EXCLUDE): {excl_total:,}")
    print(f"    -> Ghost Stock report items:             {ghost_total:,}")
    print(f"    -> Stock Integrity report items:         {integ_total:,}")
    print(f"  Fresh-stock alerts (side stream):          {fresh_total:,}")

    # ------------------------------------------------------------------
    # Write full analysis CSV
    # ------------------------------------------------------------------
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    analysis_path = out / f"store_{store_code}_classified.csv"
    _fields = list(results[0].keys()) if results else []
    with open(analysis_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=_fields)
        w.writeheader()
        w.writerows(results)
    print(f"\n  Analysis CSV     : {analysis_path}")

    # ------------------------------------------------------------------
    # Write Supabase-upload CSV
    # NOTE: do not load this until IntellistoX_EAN_Master bridge is proven.
    #       The synthetic_ean column does not join to daily_snapshots.ean yet.
    # ------------------------------------------------------------------
    upload_path = out / f"store_{store_code}_supabase_upload.csv"
    upload_fields = ["store_code", "ean", "classification", "band",
                     "score", "why_flagged", "classifier_version"]
    with open(upload_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=upload_fields)
        w.writeheader()
        for r in results:
            w.writerow({
                "store_code":         r["store_code"],
                "ean":                r["synthetic_ean"],
                "classification":     r["class"],
                "band":               r["band"],
                "score":              int(float(r["confidence"]) * 10),
                "why_flagged":        r["reason"],
                "classifier_version": CLASSIFIER_VERSION,
            })
    print(f"  Supabase upload  : {upload_path}")
    print(f"  (HOLD -- bridge not yet proven; see module docstring)")

    return results, counts


# ---------------------------------------------------------------------------
# A6 -- Precision check
# ---------------------------------------------------------------------------

def precision_check(classified_csv: str, labels_csv: str) -> None:
    """
    Attempt to measure per-bucket precision against ground-truth labels.

    Labels file: production_labelling_sample.csv  (ean + YOUR LABEL).
    Labels were produced by the old PRSSALE-based classifier and are keyed
    on PRSSALE EAN codes (e.g. 209576 for BEEF C-GRADE NECK).

    The funnel is keyed on EASYDB dArtNr -- a completely different numbering
    system.  Empirically confirmed overlap = 0/175 rows.

    This function:
      1. Reports the join failure honestly.
      2. Falls back to a qualitative review of the PRODUCTION bucket.
    """
    print(f"\n{'='*70}")
    print(f"  A6 -- Precision check vs 175 ground-truth labels")
    print(f"{'='*70}")

    with open(classified_csv, encoding="utf-8-sig") as fh:
        classified = list(csv.DictReader(fh))

    with open(labels_csv, encoding="utf-8-sig") as fh:
        labels = list(csv.DictReader(fh))

    labelled = {r["ean"].strip(): r["YOUR LABEL"].strip()
                for r in labels if r.get("YOUR LABEL", "").strip()}

    classified_by_art = {r["dArtNr"]: r for r in classified}

    joined = [(lbl, classified_by_art[ean])
              for ean, lbl in labelled.items()
              if ean in classified_by_art]

    print(f"\n  Label file   : {len(labelled)} labelled rows"
          f"  (PRODUCTION={sum(1 for v in labelled.values() if v=='PRODUCTION')},"
          f" REAL_STOCK={sum(1 for v in labelled.values() if v=='REAL_STOCK')})")
    print(f"  Funnel items : {len(classified):,}")
    print(f"  Joined rows  : {len(joined)}")

    if not joined:
        print("""
  *** PRECISION MEASUREMENT BLOCKED ***

  Root cause: the 175 labels (production_labelling_sample.csv) are keyed on
  PRSSALE EAN codes (e.g. "209576" for BEEF C-GRADE NECK).  These are the
  npos POS/PLU numbers used in PRSSALE.DAT.  The funnel keys on EASYDB
  dArtNr -- a separate numbering system that does not overlap with PRSSALE
  PLU numbers at all (confirmed: intersection size = 0).

  The same data-bridge gap that blocks A2/A3 also blocks this measurement.

  To unblock A6: pull IntellistoX_EAN_Master (EASYDB, 33,201 rows):
    USE EASYDB;
    SELECT dArtNr, cEAN, cTYP FROM IntelliAcc.IntellistoX_EAN_Master;
  This maps dArtNr to its barcode/PLU, bridging the two systems.
  Once that CSV lands the labels can be mapped to dArtNr and precision
  measured properly, per bucket.
""")
    else:
        # Precision / recall for PRODUCTION class
        tp = sum(1 for lbl, r in joined
                 if lbl == "PRODUCTION" and r["class"] == "PRODUCTION")
        fp = sum(1 for lbl, r in joined
                 if lbl != "PRODUCTION" and r["class"] == "PRODUCTION")
        fn = sum(1 for lbl, r in joined
                 if lbl == "PRODUCTION" and r["class"] != "PRODUCTION")
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec  = tp / (tp + fn) if (tp + fn) else 0.0
        print(f"\n  PRODUCTION bucket  precision={prec:.1%}  "
              f"recall={rec:.1%}  TP={tp} FP={fp} FN={fn}")

    # ------------------------------------------------------------------
    # Qualitative review of PRODUCTION bucket
    # ------------------------------------------------------------------
    prod_items = [r for r in classified if r["class"] == "PRODUCTION"]
    print(f"\n  --- Qualitative PRODUCTION bucket review ---")
    print(f"  Total PRODUCTION items : {len(prod_items):,}")

    subdept_dist = Counter(r["sub_dept_name"] for r in prod_items)
    print(f"\n  Sub-dept distribution (top 20):")
    for sd, n in subdept_dist.most_common(20):
        print(f"    {n:>5,}  {sd}")

    sup_dist = Counter(r["supplier_styp"] for r in prod_items)
    print(f"\n  Supplier type distribution:")
    for styp, n in sup_dist.most_common():
        print(f"    {n:>5,}  {styp or '(no supplier record)'}")

    print(f"\n  Sample PRODUCTION items (first 10):")
    for r in prod_items[:10]:
        print(f"    dArtNr={r['dArtNr']:>8}  soh={r['soh']:>8}  "
              f"sales={r['total_sales_wks']:>6}  {r['description'][:40]}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="SB-AP-004 A1: dArtNr-keyed elimination funnel classifier")

    ap.add_argument("--store",          required=True,
                    help="Store code, e.g. 10116")
    ap.add_argument("--supplier-type",  required=True,
                    help="Path to supplier_type CSV (dARTNR, TYP, sTYP)")
    ap.add_argument("--lifecycle",      required=True,
                    help="Path to lifecycle CSV (dArtNr, dates, sales, dBestand)")
    ap.add_argument("--dbarts",         required=True,
                    help="Path to dbarts CSV (dARTNR, description, dept, sub_dept)")
    ap.add_argument("--out-dir",        default=".",
                    help="Output directory (default: current dir)")
    ap.add_argument("--today",          default=None,
                    help="Override today's date (YYYY-MM-DD) for testing")
    ap.add_argument("--precision-check", default=None, metavar="LABELS_CSV",
                    help="Run A6 precision check against a labels CSV after classifying")

    args = ap.parse_args()

    today = (datetime.date.fromisoformat(args.today)
             if args.today else datetime.date.today())

    results, counts = run_funnel(
        store_code        = args.store,
        supplier_type_csv = args.supplier_type,
        lifecycle_csv     = args.lifecycle,
        dbarts_csv        = args.dbarts,
        out_dir           = args.out_dir,
        today             = today,
    )

    if args.precision_check:
        classified_path = (Path(args.out_dir)
                           / f"store_{args.store}_classified.csv")
        precision_check(str(classified_path), args.precision_check)

    print(f"\n  Done.\n")


if __name__ == "__main__":
    main()
