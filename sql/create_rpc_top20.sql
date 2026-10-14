-- =============================================================================
-- create_rpc_top20.sql   REGENERATED FROM THE LIVE DEFINITION, 14-10-2026 (ENG-140 A, dashboard lane)
-- LIVE PIN: md5(pg_get_functiondef) = ced3dfe2bfcf493286f254ae640e320a, 6,562 characters, one overload,
--           SECURITY DEFINER, VOLATILE, no function-level SET (no statement_timeout, no search_path).
-- The body below is byte for byte what pg_get_functiondef returns; the gate (md5 and length) passed before
-- this file was written. It replaces a hand-written file that had drifted (the ENG-115 class): that file
-- carried a DO NOT APPLY banner, two branches, STABLE and SET LOCAL statement_timeout = '60s', none of
-- which is live. Do NOT re-apply this file to the database: the pin must be identical before and after.
--
-- Behaviour on record:
--   * p_activity other than movers / non_movers RAISES (ENG-140, migration eng140_rpc_top20_reject_unknown_p_activity,
--     20260824153007). NULL still means movers.
--   * non_movers ignores p_dates BY DESIGN: it reads l2_stock_position (stock on hand now, slow_mover_signal),
--     so the dashboard says "current stock - date range not applied" (ENG-140 B, 14-10-2026).
--   * Three branches: non_movers; a department / sub-department / EAN branch (agg); the default branch
--     (base, keyed, picked, deco; ENG-104b). Movers returns the union of the top 20 by value and the top 20 by
--     quantity, so a date page cannot be merged exactly (relevant to ENG-103).
-- ACL (live, unchanged by this file): anon, authenticated, service_role EXECUTE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_top20(p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL::text, p_subdept text DEFAULT NULL::text, p_eans text[] DEFAULT NULL::text[], p_activity text DEFAULT 'movers'::text, p_parents boolean DEFAULT false)
 RETURNS TABLE(ean text, description text, dept_name text, sub_dept_name text, size text, unit text, total_sales numeric, total_qty numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_dates date[] := p_dates::date[];
BEGIN
  IF COALESCE(p_activity, 'movers') NOT IN ('movers','non_movers') THEN
    RAISE EXCEPTION 'unknown p_activity: %. Valid: movers, non_movers', p_activity;
  END IF;

  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    RETURN QUERY
      SELECT
          b.ean::text,
          COALESCE(sp.description, a.description, a.short_description)  AS description,
          COALESCE(sp.dept_name, 'UNMAPPED')                            AS dept_name,
          COALESCE(sp.subdept_name, 'UNMAPPED')                         AS sub_dept_name,
          pc.size_label                                                  AS size,
          COALESCE(a.unit, pc.detail_unit)                              AS unit,
          ROUND((sp.soh * COALESCE(sp.unit_cost, 0))::numeric, 2)       AS total_sales,
          sp.soh::numeric                                                AS total_qty
      FROM l2_stock_position sp
      JOIN   v_ean_bridge b         ON b.store_code = sp.store_code AND b.product_code = sp.product_code
      LEFT   JOIN sigma_articles a  ON a.store_code = sp.store_code AND a.product_code = sp.product_code
      LEFT   JOIN product_catalog pc ON pc.store_code = sp.store_code AND pc.ean = b.ean
      WHERE sp.store_code      = ANY(p_store_codes)
        AND sp.slow_mover_signal = TRUE
        AND sp.soh               > 0
        AND (p_parents OR sp.class NOT IN ('PRODUCTION', 'NON_STOCK'))
        AND (p_dept    IS NULL OR TRIM(replace(sp.dept_name, '.', '')) = TRIM(replace(p_dept, '.', '')))
        AND (p_subdept IS NULL OR sp.subdept_name = p_subdept)
        AND (p_eans    IS NULL OR b.ean = ANY(p_eans))
      ORDER BY total_sales DESC
      LIMIT 40;
    RETURN;
  END IF;

  IF p_dept IS NOT NULL OR p_subdept IS NOT NULL OR p_eans IS NOT NULL THEN
    RETURN QUERY
      WITH agg AS MATERIALIZED (
          SELECT
              b.ean,
              MAX(COALESCE(a.description, a.short_description)) AS description,
              MAX(COALESCE(sd.name,  'UNMAPPED'))              AS dept_name,
              MAX(COALESCE(sub.name, 'UNMAPPED'))              AS sub_dept_name,
              MAX(pc.size_label)                               AS size,
              MAX(COALESCE(a.unit, pc.detail_unit))            AS unit,
              ROUND(SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0))::numeric, 2) AS total_sales,
              SUM(ss.qty)::numeric                                               AS total_qty
          FROM sigma_sales ss
          JOIN   v_ean_bridge b            ON b.store_code = ss.store_code AND b.product_code = ss.product_code
          LEFT   JOIN sigma_articles a     ON a.store_code = ss.store_code AND a.product_code = ss.product_code
          LEFT   JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
          LEFT   JOIN sigma_subdepts sub   ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
          LEFT   JOIN product_catalog pc   ON pc.store_code = ss.store_code AND pc.ean = b.ean
          WHERE ss.store_code   = ANY(p_store_codes)
            AND ss.sale_date    = ANY(v_dates)
            AND ss.period_kind  = 'T' AND ss.txn_kind = 1
            AND ss.sales_incl_vat > 0
            AND (p_dept    IS NULL OR sd.name  = p_dept)
            AND (p_subdept IS NULL OR sub.name = p_subdept)
            AND (p_eans    IS NULL OR b.ean    = ANY(p_eans))
          GROUP BY b.ean
      )
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_sales DESC LIMIT 20)
      UNION
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_qty DESC LIMIT 20);
    RETURN;
  END IF;

  RETURN QUERY
  WITH base AS MATERIALIZED (
      SELECT ss.store_code, ss.product_code,
             SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0)) AS sv,
             SUM(ss.qty)                                        AS q
      FROM sigma_sales ss
      WHERE ss.store_code  = ANY(p_store_codes)
        AND ss.sale_date   = ANY(v_dates)
        AND ss.period_kind = 'T' AND ss.txn_kind = 1
        AND ss.sales_incl_vat > 0
      GROUP BY ss.store_code, ss.product_code
  ),
  keyed AS MATERIALIZED (
      SELECT b.ean,
             ROUND(SUM(base.sv)::numeric, 2) AS total_sales,
             SUM(base.q)::numeric            AS total_qty
      FROM base
      JOIN v_ean_bridge b ON b.store_code = base.store_code AND b.product_code = base.product_code
      GROUP BY b.ean
  ),
  picked AS (
      (SELECT keyed.ean FROM keyed ORDER BY keyed.total_sales DESC LIMIT 20)
      UNION
      (SELECT keyed.ean FROM keyed ORDER BY keyed.total_qty   DESC LIMIT 20)
  ),
  deco AS (
      SELECT b.ean,
             MAX(COALESCE(a.description, a.short_description)) AS description,
             MAX(COALESCE(sd.name,  'UNMAPPED'))               AS dept_name,
             MAX(COALESCE(sub.name, 'UNMAPPED'))               AS sub_dept_name,
             MAX(pc.size_label)                                AS size,
             MAX(COALESCE(a.unit, pc.detail_unit))             AS unit
      FROM picked p
      JOIN v_ean_bridge b               ON b.ean = p.ean AND b.store_code = ANY(p_store_codes)
      LEFT JOIN sigma_articles a        ON a.store_code = b.store_code AND a.product_code = b.product_code
      LEFT JOIN sigma_departments sd    ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
      LEFT JOIN sigma_subdepts sub      ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
      LEFT JOIN product_catalog pc      ON pc.store_code = b.store_code AND pc.ean = b.ean
      GROUP BY b.ean
  )
  SELECT k.ean::text, d.description, d.dept_name, d.sub_dept_name,
         d.size, d.unit, k.total_sales, k.total_qty
  FROM keyed k
  JOIN picked p ON p.ean = k.ean
  LEFT JOIN deco d ON d.ean = k.ean;
END;
$function$
;
