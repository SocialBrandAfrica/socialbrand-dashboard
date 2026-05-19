-- =============================================================================
-- Grant EXECUTE on all new RPCs to the anon and authenticated roles.
-- Run once in the Supabase SQL Editor after creating the functions.
-- Without these grants the dashboard API key (anon) cannot call the functions.
-- =============================================================================

GRANT EXECUTE ON FUNCTION rpc_focus_top5(text[], text[], text, text)           TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_focus_chart(text[], text[], text[])               TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_search_products(text[], text, text, text[], text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_product_detail(text, text[], text[])              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_subdepts(text[], text[], text[])                  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_all_rows(text[], text[], int, int)                TO anon, authenticated;
