-- create_rpc_bloom_promo_preorders.sql
--
-- SB-CC-BLOOM-031 §T1 (2026-09-21). WHAT SIGMA ALREADY HOLDS ON THE PROMOTION ORDER,
-- per promo line, split by drop date. Display only: this function moves no quantity.
--
-- Pieter, 21-09 ~12:45: "we have already ordered on that promo from the last order".
-- The desk showed the bare word "Promo" and nothing of the Sigma promotion order, so
-- every pre-ordered line read as a fresh suggestion.
--
-- SOURCE. The promotion order lands in the mirror as order_type '2' documents on the
-- store's DC supplier, one document per promotion per drop, all placed together
-- (80175: #89904 16-09, #89906 23-09, #89905 30-09 for RI4, placed 01-09; 10116:
-- #166827/8/9, placed 06-08). `ordered_qty` on those lines is SINGLES, proven 21-09
-- against Pieter's "Already Ordered" column on 4 of 4 lines (811441 20/10, 811442
-- 20/10, 76176 18/6, 827380 96/96 = 2, 2, 3, 1 packs).
--
-- THE DOCUMENT -> PROMOTION LINK IS A PROXY until A1 extracts the header link
-- (DBAufK.lAktNr / cAktKz, not on sigma_orders). A document belongs to the promotion
-- holding the most of its products among promotions whose window, opened 21 days
-- early, contains the drop date. Measured 21-09 on all 40 type-2 documents dropping
-- on or after 10-09 across 80175, 10116, 21355 and 80579: 37 match on every line,
-- 3 on 52/54, 31/34 and 27/28, and no runner-up comes close (best second 105 of 823).
--
-- `grv_nr` is never set on a type-2 document (0 on all 734 in the mirror), so this
-- function does not claim a drop was received. It reports the units received of the
-- product since the promotion's first drop (DIWAREPR, qty > 0) and leaves the
-- judgement to the buyer (§T4 is Pieter's).
--
-- Returns ONE jsonb row, never SETOF: the project carries a live 1,000-row cap
-- (measured 2026-08-16), and a SETOF read would drop lines silently.
-- Only promotions that have not ended (end_date >= today) are returned.

CREATE OR REPLACE FUNCTION public.rpc_bloom_promo_preorders(p_store_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  -- EXECUTE with the store as a literal: a custom plan per call. The LANGUAGE sql form ran
  -- 9.4 s at 10116 on a generic plan against 89 ms for the same text planned with the literal.
  EXECUTE format($q$
  WITH docs AS (
    SELECT o.order_nr, o.expected_grv_date AS d, o.order_date
    FROM public.sigma_orders o
    JOIN public.v_supplier_class sc
      ON sc.store_code = o.store_code AND sc.supplier_nr = o.supplier_nr AND sc.supplier_class = 'DC'
    WHERE o.store_code = %1$L
      AND o.order_type = '2'
      AND o.expected_grv_date >= current_date - 60
  ),
  dl AS (
    SELECT d.order_nr, d.d, d.order_date, l.product_code, l.ordered_qty, l.pack_size
    FROM docs d
    JOIN public.sigma_order_lines l
      ON l.store_code = %1$L AND l.order_nr = d.order_nr AND l.ordered_qty > 0
  ),
  cand AS (
    SELECT dl.order_nr, pa.promo_nr, count(DISTINCT dl.product_code) AS hit
    FROM dl
    JOIN public.sigma_promotion_articles pa
      ON pa.store_code = %1$L AND pa.product_code = dl.product_code
     AND dl.d BETWEEN pa.start_date - 21 AND pa.end_date
    GROUP BY 1, 2
  ),
  dmap AS (
    SELECT DISTINCT ON (order_nr) order_nr, promo_nr
    FROM cand ORDER BY order_nr, hit DESC, promo_nr
  ),
  hdr AS (
    SELECT sp.promo_nr, sp.start_date, sp.end_date,
           COALESCE(substring(sp.description from '\(([A-Za-z0-9]+)\)\s*$'),
                    substring(sp.description from 'DC Promotion Number\s+(\S+)')) AS suffix
    FROM public.sigma_promotions sp
    WHERE sp.store_code = %1$L
      AND sp.promo_nr IN (SELECT promo_nr FROM dmap)
      AND sp.end_date >= current_date
  ),
  pl AS (
    SELECT dl.product_code, dm.promo_nr, dl.d, dl.order_nr, dl.order_date,
           sum(dl.ordered_qty) AS units, max(dl.pack_size) AS ps
    FROM dl JOIN dmap dm USING (order_nr) JOIN hdr h ON h.promo_nr = dm.promo_nr
    GROUP BY 1, 2, 3, 4, 5
  ),
  per_line AS (
    SELECT product_code, promo_nr, min(d) AS first_drop, max(ps) AS ps,
           sum(units) AS units,
           jsonb_agg(jsonb_build_object(
             'drop_date', d, 'order_nr', order_nr, 'placed', order_date,
             'units', units, 'packs', round(units / NULLIF(ps, 0), 2)) ORDER BY d, order_nr) AS drops
    FROM pl GROUP BY 1, 2
  ),
  rc AS MATERIALIZED (   -- MATERIALIZED: inlined, it re-ran once per line (2.2 M probes, 13 s at 80175)
    SELECT p.product_code, p.promo_nr, sum(m.qty) AS units, max(m.movement_date) AS last_receipt
    FROM per_line p
    JOIN public.sigma_movements m
      ON m.store_code = %1$L AND m.product_code = p.product_code
     AND m.module = 'DIWAREPR' AND m.qty > 0 AND m.movement_date >= p.first_drop
    GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'store_code', %1$L,
    'ledger_watermark', (SELECT max(movement_date) FROM public.sigma_movements WHERE store_code = %1$L),
    'link_basis', 'proxy: document mapped to the promotion holding most of its lines (A1 open)',
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'product_code', p.product_code, 'promo_nr', p.promo_nr, 'suffix', h.suffix,
        'promo_start', h.start_date, 'promo_end', h.end_date,
        'first_drop', p.first_drop, 'ordered_units', p.units,
        'ordered_packs', round(p.units / NULLIF(p.ps, 0), 2),
        'drops', p.drops,
        'received_units_since_first_drop', COALESCE(r.units, 0),
        'last_receipt', r.last_receipt))
      FROM per_line p
      JOIN hdr h ON h.promo_nr = p.promo_nr
      LEFT JOIN rc r ON r.product_code = p.product_code AND r.promo_nr = p.promo_nr), '[]'::jsonb)
  )
  $q$, p_store_code) INTO v;
  RETURN v;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_promo_preorders(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_promo_preorders(text) TO anon, authenticated, service_role;
