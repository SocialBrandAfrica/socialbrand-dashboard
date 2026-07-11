-- create_rpc_bloom_submit_order.sql
-- SB-RA-BLOOM-001 section 7 Phase 1: order header + lines JSON -> orders +
-- order_items, returns order id. Status by role (section 12): branch_manager
-- drafts, admin/town_manager self-confirm on submit. SECURITY DEFINER --
-- the only write path into orders/order_items (R30 addendum 2). Only
-- qty_packs>0 lines persist (matches the app's own CSV-export convention);
-- line_count/total_value are recomputed from what actually inserted, not
-- from the raw input array, so a caller passing zero-qty lines can never
-- misreport the count (R22 -- a returned figure must match the row it
-- describes).

DROP FUNCTION IF EXISTS public.rpc_bloom_submit_order(text,text,date,date,text,text,jsonb);

CREATE FUNCTION public.rpc_bloom_submit_order(
  p_store_code text,
  p_route_key text,
  p_delivery_date date,
  p_next_delivery_date date DEFAULT NULL,
  p_source text DEFAULT 'dc',
  p_preset text DEFAULT NULL,
  p_lines jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE(order_id uuid, status text, total_value numeric, line_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_own_store text;
  v_status text;
  v_order_id uuid;
  v_total numeric := 0;
  v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT role, store_code INTO v_role, v_own_store
  FROM public.user_profiles WHERE id = v_uid;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no user_profiles row for this account';
  END IF;

  IF v_role = 'branch_manager' THEN
    IF v_own_store IS DISTINCT FROM p_store_code THEN
      RAISE EXCEPTION 'branch_manager % is not assigned to store %', v_uid, p_store_code;
    END IF;
    v_status := 'draft';
  ELSIF v_role IN ('admin','town_manager') THEN
    v_status := 'confirmed';
  ELSE
    RAISE EXCEPTION 'unrecognised role %', v_role;
  END IF;

  IF jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'p_lines is empty -- an order needs at least one line';
  END IF;

  INSERT INTO public.orders (
    store_code, route_key, source, preset, delivery_date, next_delivery_date,
    status, submitted_by, confirmed_by, confirmed_at
  ) VALUES (
    p_store_code, p_route_key, p_source, p_preset, p_delivery_date, p_next_delivery_date,
    v_status, v_uid,
    CASE WHEN v_status = 'confirmed' THEN v_uid ELSE NULL END,
    CASE WHEN v_status = 'confirmed' THEN now() ELSE NULL END
  )
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (
    order_id, product_code, ean, description, pack_size, pack_cost,
    qty_packs, line_value, kvi_band, mode, tier, story
  )
  SELECT
    v_order_id,
    (l->>'product_code')::bigint,
    l->>'ean',
    l->>'description',
    (l->>'pack_size')::smallint,
    (l->>'pack_cost')::numeric,
    (l->>'qty_packs')::integer,
    (l->>'qty_packs')::numeric * coalesce((l->>'pack_cost')::numeric, 0),
    l->>'kvi_band',
    l->>'mode',
    l->>'tier',
    l->>'story'
  FROM jsonb_array_elements(p_lines) AS l
  WHERE (l->>'qty_packs')::integer > 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'no lines with qty_packs > 0 -- nothing to order';
  END IF;

  SELECT coalesce(sum(line_value), 0) INTO v_total
  FROM public.order_items WHERE order_items.order_id = v_order_id;

  UPDATE public.orders SET total_value = v_total, line_count = v_count
  WHERE id = v_order_id;

  RETURN QUERY SELECT v_order_id, v_status, v_total, v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_bloom_submit_order(text,text,date,date,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_submit_order(text,text,date,date,text,text,jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_submit_order(text,text,date,date,text,text,jsonb) FROM anon;
