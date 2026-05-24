-- =============================================================================
-- SB-SCH-001 Block 8 Step 7 -- Create orders shell
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 1
--
-- Empty shell only. No ordering logic, no Sigma API integration.
-- Purpose: name the node now so FKs can reference it without retrofitting
-- into an 18M+ row ecosystem later.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Confirm table does not already exist
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'orders';
-- Expected: 0 rows. If 1 row returned, stop and review before proceeding.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Create shell table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        uuid        NOT NULL REFERENCES clients(client_id),
    store_code       text        NOT NULL,
    ean              text        NOT NULL,
    quantity_ordered int         NOT NULL,
    order_date       date        NOT NULL,
    status           text        NOT NULL DEFAULT 'pending'
                                 CHECK (status IN ('pending', 'submitted', 'cancelled', 'fulfilled')),
    created_at       timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_orders_client_store
    ON public.orders (client_id, store_code);

CREATE INDEX IF NOT EXISTS idx_orders_ean
    ON public.orders (ean);

CREATE INDEX IF NOT EXISTS idx_orders_order_date
    ON public.orders (store_code, order_date);


-- ---------------------------------------------------------------------------
-- STEP 4 -- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'orders' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON public.orders
            FOR SELECT USING (true);
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'orders'
ORDER  BY ordinal_position;
-- Expected: id, client_id, store_code, ean, quantity_ordered, order_date, status, created_at

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'orders';
-- Expected: 1 row
