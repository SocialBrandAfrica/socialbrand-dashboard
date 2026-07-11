-- create_rpc_bloom_order_status.sql
-- SB-RA-BLOOM-001 section 7 Phase 1: order history status transitions
-- (confirm/export/deliver/cancel). SECURITY DEFINER, role-gated per
-- section 12. Legal path: draft -> confirmed -> exported -> delivered;
-- cancelled reachable from draft/confirmed/exported only (never from
-- delivered -- a delivered order is a physical fact, not reversible here).

DROP FUNCTION IF EXISTS public.rpc_bloom_order_status(uuid,text,text);

CREATE FUNCTION public.rpc_bloom_order_status(
  p_order_id uuid,
  p_new_status text,
  p_reason text DEFAULT NULL
)
RETURNS TABLE(order_id uuid, status text, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_own_store text;
  v_order public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT role, store_code INTO v_role, v_own_store
  FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no user_profiles row for this account';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;

  IF v_role = 'branch_manager' AND v_own_store IS DISTINCT FROM v_order.store_code THEN
    RAISE EXCEPTION 'branch_manager % is not assigned to store %', v_uid, v_order.store_code;
  END IF;

  IF p_new_status NOT IN ('confirmed','exported','delivered','cancelled') THEN
    RAISE EXCEPTION 'invalid target status %', p_new_status;
  END IF;

  -- legal transition check
  IF NOT (
    (v_order.status = 'draft' AND p_new_status IN ('confirmed','cancelled'))
    OR (v_order.status = 'confirmed' AND p_new_status IN ('exported','cancelled'))
    OR (v_order.status = 'exported' AND p_new_status IN ('delivered','cancelled'))
  ) THEN
    RAISE EXCEPTION 'illegal transition % -> %', v_order.status, p_new_status;
  END IF;

  -- role check per transition
  IF p_new_status = 'confirmed' AND v_role NOT IN ('admin','town_manager') THEN
    RAISE EXCEPTION 'only admin/town_manager may confirm a draft order';
  END IF;
  IF p_new_status = 'cancelled' AND v_role = 'branch_manager'
     AND NOT (v_order.status = 'draft' AND v_order.submitted_by = v_uid) THEN
    RAISE EXCEPTION 'branch_manager may only cancel their own draft orders';
  END IF;
  -- export/deliver: branch_manager (own store, already checked above) or admin/town_manager -- always allowed here

  UPDATE public.orders SET
    status = p_new_status,
    confirmed_by = CASE WHEN p_new_status = 'confirmed' THEN v_uid ELSE confirmed_by END,
    confirmed_at = CASE WHEN p_new_status = 'confirmed' THEN now() ELSE confirmed_at END,
    cancelled_reason = CASE WHEN p_new_status = 'cancelled' THEN p_reason ELSE cancelled_reason END,
    updated_at = now()
  WHERE id = p_order_id;

  RETURN QUERY SELECT p_order_id, p_new_status, now();
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_status(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_status(uuid,text,text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_status(uuid,text,text) FROM anon;
