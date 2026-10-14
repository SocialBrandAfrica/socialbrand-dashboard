-- =============================================================================
-- BLOOM-035 s36 (PM 14-10-2026 20:55, handover section 36), step 2: ENGINE COLUMNS, NOT PAGE CODE.
--
--   (1) public.sigma_action_list : ONE table for everything someone must do in Sigma before an order is imported or a line can trade.
--       action_kind  ACTIVATE_LINK        no active supplier link, or the order line's link is lapsed (filled by refresh_sigma_action_list)
--                    VERIFY_LINK_OR_PACK  on the order, link carries more than one pack size (filled by refresh_sigma_action_list)
--                    SET_STOCK_FLAG       non-stock in Sigma but it sold: set Record Stock Qty to Yes (filled by refresh_sigma_action_list)
--                    CLOSE_STALE_ORDER, FIX_PACK_QTY   ENG-224 (59 DC orders open past due, an order keyed at the pack size squared): folded into this
--                    table by PM. The kinds are admitted by the check. The detector that fills them is NOT in this migration.
--       The toolkit worklist (dashboard lane, public/toolkit.html) reads this table. Rows are resolved (resolved_on), never deleted.
--   (2) public.refresh_sigma_action_list(p_store) : reads the latest standard / fit-on stored sheet of every desk of a store (the reasons are the
--       engine's own `hidden_reason` text on the stored lines) and writes the worklist. Run it after the order caches are rebuilt.
--   (3) public.rpc_bloom_desk_lines(p_store_code, p_route, p_fit) : EVERY line of one desk (the latest stored sheet's lines, ordered, covered,
--       unordered and hidden, plus the desk's population-verdict rows the sheet does not hold, which is every unordered line of a supplier desk), each with its plain-word reason, the interim active range, the rand a day it sells at cost, the supplier-link status and
--       whether it needs activating in Sigma. Hidden sellers sort last, then rand a day, fastest first.
--       in_range / range_basis: INTERIM_91D until item 4b defines KVI, core, tail and long tail (PM: marked interim until 4b). A line is in the
--       interim range when it is not a catalogue stub (never sold and never received) and it sold in the last 91 days, holds stock, is a new
--       range line or is on this order.
--
--   Three NEW objects, nothing existing is modified (R22). SECURITY DEFINER with a fixed search_path. EXECUTE revoked from PUBLIC and anon.
--   Pre-flight (14-10 21:2x): no overloads of either name; columns read from pg_attribute; line_kind set = ordered/covered/unordered/hidden;
--   bloom_dc_config.status = RULED (5 stores); link status set A/L/S; plain reasons already stored in bloom_order_cache_line.hidden_reason.
-- =============================================================================

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.sigma_action_list (
  client_id          text        NOT NULL DEFAULT 'socialbrand',
  store_code         text        NOT NULL,
  action_kind        text        NOT NULL CHECK (action_kind IN ('ACTIVATE_LINK', 'VERIFY_LINK_OR_PACK', 'SET_STOCK_FLAG', 'CLOSE_STALE_ORDER', 'FIX_PACK_QTY')),
  ref_key            text        NOT NULL,
  product_code       bigint,
  ean                text,
  description        text,
  supplier_nr        bigint,
  desk_route         text,
  link_status        text,
  reason             text        NOT NULL,
  weekly_cost_demand numeric,
  on_order           boolean     NOT NULL DEFAULT false,
  detail             jsonb,
  first_seen         date        NOT NULL DEFAULT CURRENT_DATE,
  last_seen          date        NOT NULL DEFAULT CURRENT_DATE,
  resolved_on        date,
  PRIMARY KEY (store_code, action_kind, ref_key)
);
ALTER TABLE public.sigma_action_list ENABLE ROW LEVEL SECURITY;
DO $pol$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sigma_action_list' AND policyname = 'sigma_action_list_read') THEN
    CREATE POLICY sigma_action_list_read ON public.sigma_action_list FOR SELECT TO authenticated USING (true);
  END IF;
END
$pol$;
REVOKE ALL ON public.sigma_action_list FROM PUBLIC, anon;
GRANT SELECT ON public.sigma_action_list TO authenticated;
CREATE INDEX IF NOT EXISTS sigma_action_list_open_ix ON public.sigma_action_list (store_code, action_kind) WHERE resolved_on IS NULL;
COMMENT ON TABLE public.sigma_action_list IS 'One worklist for what someone must do in Sigma (BLOOM-035 s36, ENG-224 folded in). Filled by refresh_sigma_action_list from the stored order sheets. Rows are resolved, never deleted.';

CREATE OR REPLACE FUNCTION public.refresh_sigma_action_list(p_store text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $f$
DECLARE
  v_store   text;
  v_written int := 0;
  v_total   int := 0;
  v_anchor  date;
BEGIN
  FOR v_store IN SELECT dc.store_code FROM bloom_dc_config dc WHERE dc.status = 'RULED' AND (p_store IS NULL OR dc.store_code = p_store) ORDER BY dc.store_code LOOP

    SELECT max(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code = v_store AND ss.sale_date >= CURRENT_DATE - 30;

    UPDATE sigma_action_list a SET resolved_on = CURRENT_DATE
     WHERE a.store_code = v_store AND a.resolved_on IS NULL
       AND a.action_kind IN ('ACTIVATE_LINK', 'VERIFY_LINK_OR_PACK', 'SET_STOCK_FLAG');

    WITH latest AS (
      SELECT DISTINCT ON (bc.route_key) bc.cache_id, bc.route_key
        FROM bloom_order_cache bc
       WHERE bc.store_code = v_store AND bc.preset = 'standard' AND bc.fit_to_budget
       ORDER BY bc.route_key, bc.generated_at DESC),
    src AS (
      SELECT lt.route_key, l.product_code, l.ean, l.description, l.line_kind, l.hidden_reason, l.suggested_packs, l.value,
             v.chosen_supplier_nr, v.flag_link_lapsed, v.flag_verify_link_pack, v.cost_demand_28d, v.population_state,
             (SELECT sl.status FROM sigma_supplier_link sl
               WHERE sl.store_code = v_store AND sl.product_code = l.product_code AND sl.supplier_nr = v.chosen_supplier_nr
               ORDER BY (sl.status = 'A') DESC LIMIT 1) AS lstatus
        FROM latest lt
        JOIN bloom_order_cache_line l ON l.cache_id = lt.cache_id
        LEFT JOIN l2_population_verdict v ON v.store_code = v_store AND v.product_code = l.product_code),
    k AS (
      SELECT s.*,
             CASE WHEN s.hidden_reason ILIKE 'No active supplier link%' THEN 'ACTIVATE_LINK'
                  WHEN s.line_kind = 'ordered' AND (COALESCE(s.flag_link_lapsed, false) OR COALESCE(s.lstatus, 'A') <> 'A') THEN 'ACTIVATE_LINK'
                  WHEN s.hidden_reason ILIKE 'Non-stock in Sigma%' THEN 'SET_STOCK_FLAG'
                  WHEN s.line_kind = 'ordered' AND COALESCE(s.flag_verify_link_pack, false) THEN 'VERIFY_LINK_OR_PACK'
             END AS kind
        FROM src s),
    pick AS (
      SELECT DISTINCT ON (k.kind, k.product_code) k.*
        FROM k WHERE k.kind IS NOT NULL
       ORDER BY k.kind, k.product_code, COALESCE(k.cost_demand_28d, 0) DESC),
    s28 AS (
      -- Weekly cost demand: the population verdict's own figure where the line has a verdict row, else the till cost of the last 28 days to the
      -- store's last sale date (a line with no active link has no verdict row).
      SELECT ss.product_code, SUM(ss.cost_value) / 4.0 AS wk
        FROM sigma_sales ss
       WHERE ss.store_code = v_store AND ss.period_kind = 'T' AND ss.txn_kind = 1
         AND ss.sale_date > v_anchor - 28 AND ss.sale_date <= v_anchor
         AND ss.product_code IN (SELECT pk.product_code FROM pick pk)
       GROUP BY ss.product_code)
    INSERT INTO sigma_action_list AS a (store_code, action_kind, ref_key, product_code, ean, description, supplier_nr, desk_route, link_status,
                                        reason, weekly_cost_demand, on_order, detail, first_seen, last_seen, resolved_on)
    SELECT v_store, p.kind, p.product_code::text, p.product_code, p.ean, p.description, p.chosen_supplier_nr, p.route_key, p.lstatus,
           CASE WHEN p.kind = 'ACTIVATE_LINK' AND p.line_kind = 'ordered'
                  THEN 'On the order, but its supplier link is not active in Sigma (status ' || COALESCE(p.lstatus, 'lapsed') || '). Activate it before the order is imported.'
                WHEN p.kind = 'VERIFY_LINK_OR_PACK' AND p.population_state = 'COST_UNPRICED'
                  THEN 'On the order, but the supplier link carries no cost. Fix the cost in Sigma before the order is imported.'
                WHEN p.kind = 'VERIFY_LINK_OR_PACK'
                  THEN 'On the order, but the supplier link carries more than one pack size. Check the pack in Sigma before the order is imported.'
                ELSE p.hidden_reason END,
           round(CASE WHEN COALESCE(p.cost_demand_28d, 0) > 0 THEN p.cost_demand_28d / 4.0 ELSE COALESCE(s.wk, 0) END, 2),
           (p.line_kind = 'ordered'),
           jsonb_build_object('line_kind', p.line_kind, 'packs', p.suggested_packs, 'value', p.value),
           CURRENT_DATE, CURRENT_DATE, NULL
      FROM pick p
      LEFT JOIN s28 s ON s.product_code = p.product_code
    ON CONFLICT (store_code, action_kind, ref_key) DO UPDATE
       SET ean = EXCLUDED.ean, description = EXCLUDED.description, supplier_nr = EXCLUDED.supplier_nr, desk_route = EXCLUDED.desk_route,
           link_status = EXCLUDED.link_status, reason = EXCLUDED.reason, weekly_cost_demand = EXCLUDED.weekly_cost_demand,
           on_order = EXCLUDED.on_order, detail = EXCLUDED.detail, last_seen = CURRENT_DATE, resolved_on = NULL;
    GET DIAGNOSTICS v_written = ROW_COUNT;
    v_total := v_total + v_written;
  END LOOP;
  RETURN jsonb_build_object('rows_written', v_total, 'refreshed_at', now());
END
$f$;
REVOKE EXECUTE ON FUNCTION public.refresh_sigma_action_list(text) FROM PUBLIC, anon, authenticated;

-- Signature changed during the build (a 4th argument): drop the 3-argument first version, this migration's own object, so no overload is left behind.
DROP FUNCTION IF EXISTS public.rpc_bloom_desk_lines(text, text, boolean);
CREATE OR REPLACE FUNCTION public.rpc_bloom_desk_lines(p_store_code text, p_route text, p_fit boolean DEFAULT true, p_exceptions_only boolean DEFAULT false)
RETURNS TABLE (
  product_code     bigint,
  ean              text,
  description      text,
  dept_name        text,
  supplier_nr      bigint,
  link_status      text,
  line_kind        text,
  in_range         boolean,
  range_basis      text,
  reason_plain     text,
  soh              numeric,
  cost_per_day     numeric,
  packs            integer,
  line_value       numeric,
  needs_activation boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $f$
  WITH c AS (
    SELECT bc.cache_id FROM bloom_order_cache bc
     WHERE bc.store_code = p_store_code AND bc.route_key = p_route AND bc.preset = 'standard' AND bc.fit_to_budget = p_fit
     ORDER BY bc.generated_at DESC LIMIT 1),
  sl AS (
    SELECT l.* FROM c JOIN bloom_order_cache_line l ON l.cache_id = c.cache_id),
  -- The stored sheet holds every line on the DC desks but only the ordered lines on a supplier desk, so the desk's population
  -- verdict rows that are not on the sheet are added as 'unordered'. Together they are every line of the desk.
  u AS (
    SELECT l.product_code AS pcode, l.ean AS ean_c, l.description AS descr, l.dept_name AS dname, l.line_kind AS lkind,
           l.hidden_reason AS hreason, COALESCE(l.suggested_packs, 0) AS packs_c, COALESCE(l.value, 0) AS value_c, l.soh::numeric AS soh_c,
           v.population_state AS pstate, v.chosen_supplier_nr AS snr, v.never_sold AS never_sold, v.last_sale_date AS last_sale,
           v.first_receipt_date AS first_receipt, v.cost_demand_28d AS cd28, v.flag_link_lapsed AS lapsed
      FROM sl l
      LEFT JOIN l2_population_verdict v ON v.store_code = p_store_code AND v.product_code = l.product_code
    UNION ALL
    SELECT v.product_code, (SELECT eb.ean FROM v_ean_bridge eb WHERE eb.store_code = p_store_code AND eb.product_code = v.product_code LIMIT 1),
           v.description, v.dept_name, 'unordered', NULL, 0, 0, v.soh::numeric,
           v.population_state, v.chosen_supplier_nr, v.never_sold, v.last_sale_date, v.first_receipt_date, v.cost_demand_28d, v.flag_link_lapsed
      FROM l2_population_verdict v
     WHERE v.store_code = p_store_code AND v.route_key = p_route
       AND NOT EXISTS (SELECT 1 FROM sl WHERE sl.product_code = v.product_code)),
  x AS (
    SELECT u.*,
           (SELECT sk.status FROM sigma_supplier_link sk
             WHERE sk.store_code = p_store_code AND sk.product_code = u.pcode AND sk.supplier_nr = u.snr
             ORDER BY (sk.status = 'A') DESC LIMIT 1) AS lstatus
      FROM u),
  y AS (
    SELECT x.*,
           (COALESCE(x.hreason, '') ILIKE 'No active supplier link%'
              OR (x.lkind = 'ordered' AND (COALESCE(x.lapsed, false) OR COALESCE(x.lstatus, 'A') <> 'A'))) AS needs_act
      FROM x)
  SELECT x.pcode, x.ean_c, x.descr, x.dname, x.snr, x.lstatus, x.lkind,
         -- INTERIM active range until item 4b: not a catalogue stub, and it sold in 91 days, holds stock, is a new range line or is on this order.
         -- Applied as bloom035_s36_desk_lines_exception_lines_in_range (21:3x): a line needing activation, and an unordered line carrying an engine reason
         -- of its own (non-stock but it sold, stock on no desk), are in the range. They have no verdict row, so pstate IS NULL had hidden them.
         ((x.pstate IS NOT NULL
            AND NOT (COALESCE(x.never_sold, false) AND x.first_receipt IS NULL)
            AND (COALESCE(x.last_sale >= CURRENT_DATE - 91, false) OR COALESCE(x.soh_c, 0) > 0 OR x.pstate = 'NEW_RANGE' OR x.packs_c > 0))
            OR x.needs_act
            OR (x.lkind = 'unordered' AND x.hreason IS NOT NULL AND x.hreason NOT LIKE 'In the desk pool, nothing to order:%' AND x.hreason NOT LIKE 'Expense, not stock%')) AS in_range,
         'INTERIM_91D'::text AS range_basis,
         (CASE
            WHEN x.lkind = 'ordered' THEN 'On this order: ' || x.packs_c || ' pack' || CASE WHEN x.packs_c = 1 THEN '' ELSE 's' END || '.'
                                          || CASE WHEN x.hreason IS NOT NULL THEN ' ' || x.hreason ELSE '' END
            WHEN x.lkind = 'covered' THEN 'Enough stock for the next delivery. Nothing to order.'
            WHEN x.hreason IS NOT NULL AND x.hreason NOT LIKE 'In the desk pool, nothing to order:%' THEN x.hreason
            WHEN x.pstate = 'COVERED_TRUSTED_RATE' THEN 'Enough stock for the next delivery. Nothing to order.'
            WHEN x.pstate = 'NEW_RANGE' THEN 'New line with no sales history yet. Kept on the desk, not judged on its rate.'
            WHEN x.pstate = 'SLOW_BELOW_GATE' AND COALESCE(x.never_sold, false) AND x.first_receipt IS NULL THEN 'Catalogue entry. Never sold and never received.'
            WHEN x.pstate = 'SLOW_BELOW_GATE' AND COALESCE(x.never_sold, false) THEN 'Received, but has not sold yet. Below the life gate, not ordered.'
            WHEN x.pstate = 'SLOW_BELOW_GATE' THEN 'Sells too slowly to carry' || CASE WHEN x.last_sale IS NOT NULL THEN ' (last sold ' || to_char(x.last_sale, 'DD Mon YYYY') || ')' ELSE '' END || '. Not ordered.'
            WHEN x.pstate = 'VERIFY_LINK_OR_PACK' THEN 'More than one pack size or link. Check the pack in Sigma before ordering.'
            WHEN x.pstate = 'DORMANT_EMPTY' THEN 'Stopped selling and now empty. Not ordered.'
            WHEN x.pstate = 'COST_UNPRICED' THEN 'The supplier link carries no cost. Fix the cost in Sigma.'
            WHEN x.pstate = 'PHANTOM_CLAIMS_STOCK' THEN 'The ledger claims stock it cannot support. Count it before ordering.'
            ELSE COALESCE(x.hreason, 'Not ordered this delivery.') END) AS reason_plain,
         x.soh_c, round(COALESCE(x.cd28, 0) / 28.0, 2) AS cost_per_day,
         x.packs_c::integer, round(x.value_c, 2),
         x.needs_act AS needs_activation
    FROM y AS x
   -- p_exceptions_only (DC ambient and TOPS DC, PM s36.4 / Pieter 20-3x: show a line only when there is a reason it is not on the desk):
   -- the unordered lines the engine gave a reason of its own (no active link, non-stock but it sold, expense, in no desk pool) plus the lines needing activation.
   WHERE NOT p_exceptions_only
      OR x.needs_act
      OR (x.lkind = 'unordered' AND x.hreason IS NOT NULL AND x.hreason NOT LIKE 'In the desk pool, nothing to order:%')
   ORDER BY (x.lkind = 'hidden'), round(COALESCE(x.cd28, 0) / 28.0, 2) DESC, x.descr;
$f$;
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_desk_lines(text, text, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_desk_lines(text, text, boolean, boolean) TO authenticated;
COMMENT ON FUNCTION public.rpc_bloom_desk_lines(text, text, boolean, boolean) IS 'BLOOM-035 s36: every line of one desk (latest stored standard sheet plus the desk verdict rows it does not hold), plain-word reason, INTERIM active range (until item 4b), rand a day, link status, packs. p_exceptions_only for DC ambient and TOPS DC.';

SELECT pg_notify('pgrst', 'reload schema');
