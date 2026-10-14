-- =============================================================================
-- eng180_aud011_rpc_gp_cost_quarantine.sql   (migration eng180_aud011_rpc_gp_cost_quarantine)
-- AUD-011 option B and ENG-180 option A (PM rulings 14-10-2026 09:0x), dashboard lane.
--
-- ONE detector, two uses, derived from the ledger and never typed per store:
--   a (store, product, day) line is a COST ERROR when its cost is at least gp_quarantine_min_cost
--   AND at least gp_quarantine_cost_ratio times its ex-VAT revenue (sales_incl_vat - vat_value).
--   * AUD-011 B: called with this period's dates, the Gross Profit card states "quarantined R x
--     across n lines" beside the headline, which is NOT smoothed.
--   * ENG-180 A: called with last year's dates (the selection shifted by 364 days), the card hides
--     last year's GP when removing the flagged lines moves it by at least ly_gp_hide_min_effect_pp.
--
-- Measured 14-10-2026, October 2025 window 02..14 (before building):
--   10116 22 lines on all 13 days, R1,493,490 of cost, LY GP -33.3 per cent, 20.1 without them;
--   80579 one line a day, GP -73 to -248 per cent, 16 to 20 without; 21355 one line on one day,
--   16.1 against 16.5 (0.4 pp, below the hide threshold); 80175 and 80176 none.
--   This period 01..13 Oct 2026: 10116 8 lines, 21355 16 lines, 80175 / 80176 / 80579 none.
--   At cost >= R100 and 3 times revenue the detector also flags genuine thin-margin lines
--   (80175: 33 lines), so the R1,000 and 10 times floor is what keeps it quiet.
--
-- The three thresholds are SEED, UNDERIVED, held in forge_config (R21, R28); the PM rules them
-- provisional (14-10-2026). Read-only SECURITY DEFINER, reads sigma_sales only, bounded to the
-- requested dates. ACL as the other dashboard RPCs: anon, authenticated, service_role.
-- Rollback: DROP FUNCTION public.rpc_gp_cost_quarantine(text[], text[], text[]);
--           UPDATE forge_config SET retired_on = CURRENT_DATE WHERE config_key IN (the three keys).
-- =============================================================================
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('gp_quarantine_min_cost',      '*', 1000, 'DEMO_CALIBRATION', DATE '2026-10-14',
  'SEED, UNDERIVED. Rand floor of cost on one (store, product, day) line before it can be a cost error for the GP quarantine detector (rpc_gp_cost_quarantine). Measured 14-10-2026 with the ratio below. Derivation owed.'),
 ('gp_quarantine_cost_ratio',    '*', 10,   'DEMO_CALIBRATION', DATE '2026-10-14',
  'SEED, UNDERIVED. A line is a cost error when its cost is at least this multiple of its ex-VAT revenue (and at least gp_quarantine_min_cost). At 3 times and R100 the detector flags genuine thin-margin lines. Derivation owed.'),
 ('ly_gp_hide_min_effect_pp',    '*', 1.0,  'DEMO_CALIBRATION', DATE '2026-10-14',
  'SEED, UNDERIVED. The dashboard hides last year''s GP when removing the flagged lines moves it by at least this many percentage points (ENG-180 A). 21355 last year October: 0.4 pp, shown; 10116: 53.4 pp, hidden. Derivation owed.')
ON CONFLICT (config_key, store_format) DO NOTHING;

DO $$
BEGIN
  IF to_regprocedure('public.rpc_gp_cost_quarantine(text[],text[],text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'rpc_gp_cost_quarantine already exists; refusing to overwrite it';
  END IF;
END $$;

CREATE FUNCTION public.rpc_gp_cost_quarantine(p_store_codes text[], p_dates text[], p_dept_names text[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '15s'
AS $fn$
DECLARE
  v_min    numeric;
  v_ratio  numeric;
  v_pp     numeric;
  v_dates  date[];
  v_out    jsonb;
BEGIN
  SELECT value_num INTO v_min   FROM forge_config WHERE config_key = 'gp_quarantine_min_cost'   AND store_format = '*' AND retired_on IS NULL;
  SELECT value_num INTO v_ratio FROM forge_config WHERE config_key = 'gp_quarantine_cost_ratio' AND store_format = '*' AND retired_on IS NULL;
  SELECT value_num INTO v_pp    FROM forge_config WHERE config_key = 'ly_gp_hide_min_effect_pp' AND store_format = '*' AND retired_on IS NULL;
  IF v_min IS NULL OR v_ratio IS NULL OR v_pp IS NULL THEN
    RAISE EXCEPTION 'forge_config gp_quarantine_min_cost, gp_quarantine_cost_ratio or ly_gp_hide_min_effect_pp is missing';
  END IF;
  v_dates := p_dates::date[];

  WITH l AS (
    SELECT ss.store_code, ss.sale_date, ss.product_code,
           sum(ss.cost_value) AS cost, sum(ss.sales_incl_vat - ss.vat_value) AS exv
      FROM public.sigma_sales ss
      LEFT JOIN public.sigma_articles a    ON a.store_code = ss.store_code AND a.product_code = ss.product_code
      LEFT JOIN public.sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
     WHERE ss.store_code = ANY(p_store_codes) AND ss.sale_date = ANY(v_dates)
       AND ss.period_kind = 'T' AND ss.txn_kind = 1
       AND (p_dept_names IS NULL OR sd.name = ANY(p_dept_names))
     GROUP BY ss.store_code, ss.sale_date, ss.product_code
  ), f AS (
    SELECT *, (cost >= v_min AND cost > v_ratio * greatest(exv, 0.01)) AS flagged FROM l
  ), s AS (
    SELECT store_code,
           sum(exv) AS exv, sum(cost) AS cost,
           count(*) FILTER (WHERE flagged) AS n,
           count(DISTINCT sale_date) FILTER (WHERE flagged) AS days,
           COALESCE(sum(cost) FILTER (WHERE flagged), 0) AS fcost,
           COALESCE(sum(exv)  FILTER (WHERE flagged), 0) AS fexv
      FROM f GROUP BY store_code
  ), t AS (
    SELECT COALESCE(sum(exv),0) AS exv, COALESCE(sum(cost),0) AS cost, COALESCE(sum(n),0) AS n,
           COALESCE(sum(fcost),0) AS fcost, COALESCE(sum(fexv),0) AS fexv FROM s
  )
  SELECT jsonb_build_object(
    'dates',        to_jsonb(p_dates),
    'dept_names',   to_jsonb(p_dept_names),
    'thresholds',   jsonb_build_object('min_cost', v_min, 'cost_ratio', v_ratio, 'hide_min_effect_pp', v_pp),
    'stores',       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                       'store_code', s.store_code, 'sales_ex_vat', round(s.exv, 2), 'cost', round(s.cost, 2),
                       'flagged_lines', s.n, 'flagged_days', s.days, 'flagged_cost', round(s.fcost, 2),
                       'gp_pct', round(100 * (s.exv - s.cost) / nullif(s.exv, 0), 2),
                       'gp_pct_ex_flagged', round(100 * ((s.exv - s.fexv) - (s.cost - s.fcost)) / nullif(s.exv - s.fexv, 0), 2))
                       ORDER BY s.store_code) FROM s), '[]'::jsonb),
    'total',        (SELECT jsonb_build_object(
                       'sales_ex_vat', round(t.exv, 2), 'cost', round(t.cost, 2),
                       'flagged_lines', t.n, 'flagged_cost', round(t.fcost, 2),
                       'gp_pct', round(100 * (t.exv - t.cost) / nullif(t.exv, 0), 2),
                       'gp_pct_ex_flagged', round(100 * ((t.exv - t.fexv) - (t.cost - t.fcost)) / nullif(t.exv - t.fexv, 0), 2),
                       'effect_pp', round(100 * ((t.exv - t.fexv) - (t.cost - t.fcost)) / nullif(t.exv - t.fexv, 0)
                                        - 100 * (t.exv - t.cost) / nullif(t.exv, 0), 2),
                       'poisoned', (t.n > 0 AND t.exv > 0 AND t.exv - t.fexv > 0
                                    AND (100 * ((t.exv - t.fexv) - (t.cost - t.fcost)) / (t.exv - t.fexv)
                                         - 100 * (t.exv - t.cost) / t.exv) >= v_pp)
                     ) FROM t)
  ) INTO v_out;
  RETURN v_out;
END
$fn$;

COMMENT ON FUNCTION public.rpc_gp_cost_quarantine(text[], text[], text[]) IS
  'GRADE: CALCULATED. AUD-011 B and ENG-180 A (dashboard lane, 14-10-2026): per store and in total, the lines whose cost is at least gp_quarantine_min_cost and gp_quarantine_cost_ratio times their ex-VAT revenue for the given dates (optionally one department), the GP with and without them, and poisoned = removing them moves GP by at least ly_gp_hide_min_effect_pp. Reads sigma_sales for the requested dates only.';

REVOKE EXECUTE ON FUNCTION public.rpc_gp_cost_quarantine(text[], text[], text[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_gp_cost_quarantine(text[], text[], text[]) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
