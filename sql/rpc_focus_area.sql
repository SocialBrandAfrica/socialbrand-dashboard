-- =============================================================================
-- Focus Area RPCs
-- SB-CC-DASH-SOURCE-002 Step 4 (SB-INDEX-005 Phase 2).
-- Two functions = TWO separate pastes in the Supabase SQL Editor.
--
-- SALES FACTS re-sourced onto sigma_sales (DBUMBA exact ledger, missed-EOD
--   complete). Output stays keyed by EAN, so sigma product_code is bridged back
--   to ean via product_catalog (~96.8%); the unbridged tail (~3%) cannot carry
--   an ean and is therefore not rankable here -- inherent to ean-keyed output
--   over a product_code-keyed ledger (flagged to PM; keying by product_code
--   would be a page change, out of scope).
-- STOCK FACT soh in rpc_focus_chart STAYS on daily_snapshots (held stock-facts
--   thread); NULL on missed-EOD days = honestly unknown, fixed by the later step.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PASTE 1 of 2
-- rpc_focus_top5
--   Top products by period sales for the Focus Area basket (the ranking that
--   chooses which EANs the chart then draws). Pure SALES FACT -> sigma_sales.
--   Optional dept / sub-dept filters resolved sigma-native (sigma_articles ->
--   sigma_departments / sigma_subdepts.name), mirroring rpc_dept_summary.
--   One row per ean + store_code so multi-store selections draw per-store lines.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_focus_top5(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text DEFAULT NULL,
    p_subdept      text DEFAULT NULL
)
RETURNS TABLE(
    ean           text,
    description   text,
    store_code    text,
    dept_name     text,
    sub_dept_name text,
    period_sales  numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH bridge AS (
        SELECT pc.ean,
               pc.store_code,
               NULLIF(regexp_replace(pc.sigma_product_code, '\D', '', 'g'), '')::bigint AS product_code
        FROM   product_catalog pc
        WHERE  pc.store_code = ANY(p_store_codes)
          AND  pc.sigma_product_code ~ '^[0-9]+$'
    )
    SELECT
        b.ean,
        MAX(COALESCE(a.description, a.short_description)) AS description,
        ss.store_code,
        MAX(COALESCE(sd.name,  'UNMAPPED'))               AS dept_name,
        MAX(COALESCE(sub.name, 'UNMAPPED'))               AS sub_dept_name,
        ROUND(SUM(ss.sales_incl_vat)::numeric, 2)         AS period_sales
    FROM   sigma_sales ss
    JOIN   bridge b               ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    LEFT   JOIN sigma_articles a  ON a.store_code = ss.store_code AND a.product_code = ss.product_code
    LEFT   JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
    LEFT   JOIN sigma_subdepts sub   ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
    WHERE  ss.store_code  = ANY(p_store_codes)
      AND  ss.sale_date   = ANY(p_dates::date[])          -- index-safe (Rule 4)
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
      AND  ss.sales_incl_vat > 0
      AND  (p_dept    IS NULL OR sd.name  = p_dept)
      AND  (p_subdept IS NULL OR sub.name = p_subdept)
    GROUP  BY b.ean, ss.store_code
    ORDER  BY period_sales DESC
    LIMIT  50;
$$;

GRANT EXECUTE ON FUNCTION rpc_focus_top5(text[], text[], text, text) TO anon, authenticated;


-- -----------------------------------------------------------------------------
-- PASTE 2 of 2
-- rpc_focus_chart
--   Daily series for a set of EANs / stores / dates (time-series comparison).
--   HYBRID: today_sales + today_qty -> sigma_sales (sales facts, missed-EOD
--   complete); soh -> daily_snapshots (held). FULL OUTER on ean×store×date so a
--   missed-EOD sale still draws (soh NULL that day). Labels (description/size/
--   unit) fall back to sigma_articles / product_catalog for sigma-only rows.
--   today_qty = SUM(qty) selling-units per the resolved qty convention.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_focus_chart(
    p_eans        text[],
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    ean           text,
    description   text,
    size          text,
    unit          text,
    snapshot_date text,
    store_code    text,
    today_sales   numeric,
    today_qty     numeric,
    soh           numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH bridge AS (
        SELECT pc.ean,
               pc.store_code,
               NULLIF(regexp_replace(pc.sigma_product_code, '\D', '', 'g'), '')::bigint AS product_code
        FROM   product_catalog pc
        WHERE  pc.store_code = ANY(p_store_codes)
          AND  pc.ean = ANY(p_eans)
          AND  pc.sigma_product_code ~ '^[0-9]+$'
    ),
    sigma_side AS (             -- SALES FACTS off the ledger
        SELECT b.ean,
               ss.store_code,
               ss.sale_date,
               SUM(ss.sales_incl_vat) AS sig_sales,
               SUM(ss.qty)            AS sig_qty
        FROM   sigma_sales ss
        JOIN   bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
        WHERE  ss.store_code  = ANY(p_store_codes)
          AND  ss.sale_date   = ANY(p_dates::date[])
          AND  ss.period_kind = 'T' AND ss.txn_kind = 1
        GROUP  BY b.ean, ss.store_code, ss.sale_date
    ),
    snap_side AS (             -- STOCK FACT soh (held) + labels
        SELECT ds.ean,
               ds.store_code,
               ds.snapshot_date,
               ds.description, ds.size, ds.unit,
               ds.today_sales AS snap_sales,
               ds.today_qty   AS snap_qty,
               ds.soh
        FROM   daily_snapshots ds
        WHERE  ds.ean          = ANY(p_eans)
          AND  ds.store_code   = ANY(p_store_codes)
          AND  ds.snapshot_date = ANY(p_dates::date[])
    )
    SELECT
        COALESCE(sg.ean, sn.ean)                                       AS ean,
        COALESCE(sn.description, a.description, pc.description)        AS description,
        COALESCE(sn.size, pc.size_label)                              AS size,
        COALESCE(sn.unit, a.unit, pc.detail_unit)                    AS unit,
        COALESCE(sg.sale_date, sn.snapshot_date)::text                AS snapshot_date,
        COALESCE(sg.store_code, sn.store_code)                        AS store_code,
        ROUND(COALESCE(sg.sig_sales, sn.snap_sales, 0)::numeric, 2)   AS today_sales,
        COALESCE(sg.sig_qty, sn.snap_qty)::numeric                    AS today_qty,
        sn.soh::numeric                                              AS soh
    FROM   sigma_side sg
    FULL   OUTER JOIN snap_side sn
           ON sn.ean = sg.ean AND sn.store_code = sg.store_code AND sn.snapshot_date = sg.sale_date
    LEFT   JOIN bridge bb ON bb.ean = COALESCE(sg.ean, sn.ean)
                         AND bb.store_code = COALESCE(sg.store_code, sn.store_code)
    LEFT   JOIN sigma_articles a ON a.store_code = COALESCE(sg.store_code, sn.store_code)
                                AND a.product_code = bb.product_code
    LEFT   JOIN product_catalog pc ON pc.store_code = COALESCE(sg.store_code, sn.store_code)
                                  AND pc.ean = COALESCE(sg.ean, sn.ean)
    ORDER  BY snapshot_date ASC;
$$;

GRANT EXECUTE ON FUNCTION rpc_focus_chart(text[], text[], text[]) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
