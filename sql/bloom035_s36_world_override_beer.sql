-- =============================================================================
-- BLOOM-035 s36 step 1 (PM 14-10-2026 20:55): "the 7 beer products in the wrong world".
--
-- FINDING (read 14-10 21:1x, DEDUCTIVE, l2_product_resolution + l2_world_assignment + l2_stock_position):
--   Seven SAB-account beer codes sit in WORLD_2 / PROD_INPUT because ENG-020's third leg ("no selling family member") cannot fire: the family
--   builder (refresh_l2_family_ros, ENG-073) reads l2_product_resolution rows that carry a pack_multiple, and these seven sit in the
--   human queue (verdict RESIDUE_HUMAN) with NO pack_multiple, so none of them has an l2_family_ros row. Beer is bought to be sold.
--     21355  163    CORONA ZERO              resolution: no scannable code, never sold ("Scan the pack on the shelf")
--     21355  12929  STELLA ARTOIS NRB        family 205|330ML|STELLA ARTOIS NRB, pack count unanswered; sibling 95265 sells 251/91d
--     21355  21879  STELLA ARTOIS NRB_24     same family, description says _24, price says ~30.5x, unanswered
--     80176  125    CORONA CERO REGULAR      no scannable code, never sold
--     80176  469    BRUTAL FRUIT LITCHE SECHE NRB   no resolution row; siblings 103 and 266 sell 37 and 48/91d
--     80176  59713  CASTLE MILK STOUT CASE   no scannable code, never sold, SOH 2,737 (resolution capital impact R550,848)
--     80579  10011  HANSA PILSNER NRB_24     family 203|330ML|HANSA PILSNER NRB, pack count unanswered
--   (REDD'S ORIGINAL RB 21355/20389 is NOT in the list: a one-member family that never sold, three receipts in 212 days. Left as is.)
--
-- THE FIX, and its evidence class: a RULING, not a derivation. The seven are named by PM in section 36. The derived fix (the family builder
-- linking a receipt-only twin to its selling family once the pack answer arrives) is owed and logged in BUG-LOG. Until then a ruled, auditable list:
--   public.l2_world_override  (store_code, product_code, world, ruled_by, ruled_on, reason, falsifier, retired_on). WORLD_1 only.
--   refresh_l2_world_assignment reads it: an overridden code is WORLD_1 with no sub_class, reason names the ruling, confidence NULL.
-- confirmed_by is left NULL on every row: PM has not confirmed the seven line by line (never pre-stamp another party's confirmation).
-- The change reaches the desks at the next nightly chain (world assignment, then the population verdict and the order caches). Nothing is run here.
-- =============================================================================

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.l2_world_override (
  client_id    text   NOT NULL DEFAULT 'socialbrand',
  store_code   text   NOT NULL,
  product_code bigint NOT NULL,
  world        text   NOT NULL CHECK (world = 'WORLD_1'),
  ruled_by     text   NOT NULL,
  ruled_on     date   NOT NULL,
  confirmed_by text,
  reason       text   NOT NULL,
  falsifier    text   NOT NULL,
  retired_on   date,
  PRIMARY KEY (store_code, product_code)
);
ALTER TABLE public.l2_world_override ENABLE ROW LEVEL SECURITY;
DO $pol$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'l2_world_override' AND policyname = 'l2_world_override_read') THEN
    CREATE POLICY l2_world_override_read ON public.l2_world_override FOR SELECT TO authenticated USING (true);
  END IF;
END
$pol$;
REVOKE ALL ON public.l2_world_override FROM PUBLIC, anon;
GRANT SELECT ON public.l2_world_override TO authenticated;
COMMENT ON TABLE public.l2_world_override IS 'Ruled per-product World 1 list read by refresh_l2_world_assignment (BLOOM-035 s36). SEED, UNDERIVED: chosen by ruling, not derived. The derivation (family builder links a receipt-only twin) is owed, BUG-LOG.';

INSERT INTO public.l2_world_override (store_code, product_code, world, ruled_by, ruled_on, confirmed_by, reason, falsifier, retired_on)
SELECT v.store_code, v.product_code, 'WORLD_1', 'PM handover section 36 (14-10-2026 20:55): named as the 7 beer products in the wrong world', DATE '2026-10-14', NULL, v.reason,
       'Retire when the family builder links this code to its selling family (the floor answers the pack-count question in the resolution queue) or when a till sale moves it to World 1 by the ENG-020 legs.', NULL
  FROM (VALUES
    ('21355', 163::bigint,   'CORONA ZERO: SAB beer, received 12 times over 616 days, SOH 75, no scannable code in the resolution table. Beer is bought to be sold.'),
    ('21355', 12929::bigint, 'STELLA ARTOIS NRB: SAB beer, 17 receipt dates, SOH 345, family named by resolution but pack count unanswered, so no family row. Its twin 95265 sells 251 in 91 days.'),
    ('21355', 21879::bigint, 'STELLA ARTOIS NRB_24: SAB beer case code, 15 receipt dates, family named by resolution but pack count unanswered, so no family row.'),
    ('80176', 125::bigint,   'CORONA CERO REGULAR: SAB beer, 11 receipt dates, SOH 70, no scannable code in the resolution table. Siblings 150756 and 150862 sell.'),
    ('80176', 469::bigint,   'BRUTAL FRUIT LITCHE SECHE NRB: SAB beer, 28 receipt dates, SOH 312, no resolution row. Siblings 103 and 266 sell 37 and 48 in 91 days.'),
    ('80176', 59713::bigint, 'CASTLE MILK STOUT CASE: SAB beer case code, 33 receipt dates, SOH 2,737, no scannable code in the resolution table. Siblings sell.'),
    ('80579', 10011::bigint, 'HANSA PILSNER NRB_24: SAB beer case code, 7 receipt dates, family named by resolution but pack count unanswered, so no family row. Siblings sell.')
  ) AS v(store_code, product_code, reason)
ON CONFLICT (store_code, product_code) DO NOTHING;

-- ASSERTED REPLACE of refresh_l2_world_assignment (pinned to the live md5 read at 21:1x; one overload, p_store_code text).
DO $m$
DECLARE
  d  text;
  e1 constant text := E'CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL THEN ''WORLD_2'' ELSE ''WORLD_1'' END,';
  r1 constant text := E'CASE WHEN o.product_code IS NOT NULL THEN o.world WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL THEN ''WORLD_2'' ELSE ''WORLD_1'' END,';
  e2 constant text := E'CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL THEN ''PROD_INPUT'' END,';
  r2 constant text := E'CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL AND o.product_code IS NULL THEN ''PROD_INPUT'' END,';
  e3 constant text := E'CASE WHEN f.product_code IS NOT NULL THEN\n                ''World 1, not a World 2 input: a family member sells';
  r3 constant text := E'CASE WHEN o.product_code IS NOT NULL THEN\n                format(''World 1 by ruling (%s, %s): %s'', o.ruled_by, o.ruled_on, o.reason)\n              WHEN f.product_code IS NOT NULL THEN\n                ''World 1, not a World 2 input: a family member sells';
  e4 constant text := E'AND f.product_code IS NULL\n              THEN LEAST(';
  r4 constant text := E'AND f.product_code IS NULL AND o.product_code IS NULL\n              THEN LEAST(';
  e5 constant text := 'FROM cand c LEFT JOIN fam f ON f.product_code = c.product_code;';
  r5 constant text := 'FROM cand c LEFT JOIN fam f ON f.product_code = c.product_code LEFT JOIN l2_world_override o ON o.store_code = p_store_code AND o.product_code = c.product_code AND o.retired_on IS NULL;';
  e6 constant text := '(BLOOM-035 item 1)';
  r6 constant text := '(BLOOM-035 item 1; s36 ruled World 1 override)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'refresh_l2_world_assignment';
  IF md5(d) <> '286ff32731137a26423d329c05a41f63' THEN
    IF position('l2_world_override' IN d) > 0 THEN RAISE NOTICE 'already patched, nothing to do'; RETURN; END IF;
    RAISE EXCEPTION 'refresh_l2_world_assignment body moved: md5 %', md5(d);
  END IF;
  IF (length(d) - length(replace(d, e1, ''))) / length(e1) <> 1 THEN RAISE EXCEPTION 'e1 count'; END IF;
  IF (length(d) - length(replace(d, e2, ''))) / length(e2) <> 1 THEN RAISE EXCEPTION 'e2 count'; END IF;
  IF (length(d) - length(replace(d, e3, ''))) / length(e3) <> 1 THEN RAISE EXCEPTION 'e3 count'; END IF;
  IF (length(d) - length(replace(d, e4, ''))) / length(e4) <> 1 THEN RAISE EXCEPTION 'e4 count'; END IF;
  IF (length(d) - length(replace(d, e5, ''))) / length(e5) <> 1 THEN RAISE EXCEPTION 'e5 count'; END IF;
  IF (length(d) - length(replace(d, e6, ''))) / length(e6) <> 1 THEN RAISE EXCEPTION 'e6 count'; END IF;
  d := replace(d, e1, r1);
  d := replace(d, e2, r2);
  d := replace(d, e3, r3);
  d := replace(d, e4, r4);
  d := replace(d, e5, r5);
  d := replace(d, e6, r6);
  EXECUTE d;
END
$m$;

SELECT pg_notify('pgrst', 'reload schema');
