-- =============================================================================
-- create_l2_item_classification.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 2
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 2)
-- Version     : 1.0
-- Date        : 2026-06-08
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Sources     : sigma_articles, sigma_departments, sigma_subdepts,
--               sigma_lifecycle, l2_rate_of_sale, l2_movements_typed
--
-- WHAT THIS IS
--   The keystone Layer 2 classification table. One row per
--   (client_id, store_code, product_code). Every KPI mart and report
--   joins this table to get the article's verdict. No view ever recomputes
--   classification logic inline again (NORTH_STAR principle, SB-CC-L2-001).
--
--   Classes:
--     NORMAL           -- active ranged item. Included in capital tied,
--                         Top 20, slow-mover and reorder counts.
--     PRODUCTION       -- production raw material or input (ingredients,
--                         packaging, production-dept never-sold). Excluded
--                         from capital tied. Shown in l2_ghost_stock with
--                         reason code. Not counted in negative SOH KPI.
--     NON_STOCK        -- no physical inventory to manage (airtime, expenses,
--                         packaging consumables, GL placeholder articles,
--                         dimension orphans). Excluded from all stock KPIs.
--     RECEIPTING_BREAK -- non-scale item with SOH < -1000. Indicates a
--                         receiving or stock-take data integrity failure.
--                         Shown in l2_stock_integrity as Type B.
--
-- SIGNAL STACK (evaluated in priority order; first match wins):
--
--   S1  NON_STOCK_DEPT      -- dept in non-stock list or dept_nr = 99.
--                              Deterministic. confidence = 1.00.
--   S2  DIM_EXCLUDED        -- dept_nr = 0 (DEPT_ZERO_PLACEHOLDER) or
--                              subdept orphan (merch_group_nr absent from
--                              sigma_subdepts). Deterministic. conf = 1.00.
--   S3  PROD_INPUT_SUBDEPT  -- subdept name contains INGREDIENTS, PACKAGING,
--                              or WASTAGE. These subdepts hold raw materials
--                              and internal consumables that never go to POS.
--                              confidence = 0.95.
--   S4  RECEIPTING_BREAK    -- scale_flag = '0' AND SOH < -1000.
--                              Scale items (scale_flag='1') excluded: their
--                              negative SOH is expected depletion, handled
--                              in l2_stock_integrity as Type A.
--                              confidence = 0.90.
--   S5  PROD_DEPT_NEVER_SOLD -- production dept (BAKERY, DELI, BUTCHERY,
--                              HMR, FISH SHOP, PRODUCE, FLOWERS, COFFEE SHOP)
--                              AND last_sale_date = 1990-01-01 (Sigma sentinel
--                              for never-sold). These are raw inputs ranged in
--                              Sigma but never reaching a POS transaction.
--                              Base confidence = 0.80, boosted by S6/S7.
--   S6  PLU_FLAG            -- plu_flag = '1' (SPAR only: Sigma marks
--                              production inputs with this flag; 99 on 10116).
--                              Boosts S5 confidence to 0.88 (+) or 0.92 (+S7).
--   S7  RECEIVED_NEVER_SOLD -- has at least one RECEIPT movement in
--                              l2_movements_typed AND never_sold = TRUE in
--                              l2_rate_of_sale. Buy-and-sell matrix: bought
--                              but never sold at POS is a production raw
--                              material pattern. Boosts S5 confidence to 0.85.
--   NORMAL                  -- no signals fired. confidence = 0.99.
--
-- SCALE FLAG NOTE:
--   scale_flag in sigma_articles maps to cWAG (one A) in Sigma's raw table.
--   On this estate: 0 = 67,024 / 1 = 2,775 (verified 10116, 2026-06-07).
--   Valid and used in S4. Do NOT confuse with cWAAGE (two A's) which reads
--   all zeros on this estate and is not extracted.
--
-- SENTINEL DATE NOTE:
--   1990-01-01 is the Sigma warehouse sentinel meaning "never sold at POS"
--   (64,289 articles on 10116 carry this). sigma_lifecycle.last_sale_date
--   carries this value; sigma_sales never contains this date (extractor
--   filter cPerKz='T' AND cVorKz=1 means only real till transactions land).
--
-- DIMENSION EXCLUSION ALIGNMENT:
--   sigma_dimension_exclusions (v_sigma_merch_articles carve-out) and this
--   classifier apply the same two rules via S1 and S2:
--     DEPT_CODE rule    -> department_nr = 0 -> caught by S2 DIM_EXCLUDED
--     SUBDEPT_ORPHAN rule -> merch_group_nr absent from sigma_subdepts
--                          -> caught by S2 DIM_EXCLUDED (LEFT JOIN = NULL)
--   Net result: articles excluded from v_sigma_merch_articles are always
--   classified NON_STOCK here. The two systems stay in sync without
--   referencing sigma_dimension_exclusions directly (avoiding a dependency
--   on the exclusion config table; config can change without breaking the MV).
--
-- OBSERVED COUNTS (10116, pre-REFRESH, 2026-06-07):
--   sigma_articles:  69,798   | sigma_lifecycle:  89,914
--   plu_flag = '1':      99   | scale_flag = '1':  2,775
--   soh < -1000:         14   | 1990 sentinel: 64,289
--
-- HOW TO RUN:
--   Prerequisites: l2_movements_typed and l2_rate_of_sale must exist.
--   Drop + recreate (Rule 19: no ALTER workarounds on broken definitions).
--   REFRESH MATERIALIZED VIEW l2_item_classification;
--   Run nightly after l2_rate_of_sale refresh.
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP MATERIALIZED VIEW IF EXISTS l2_item_classification CASCADE;


CREATE MATERIALIZED VIEW l2_item_classification AS
WITH

-- Articles joined to department and sub-department names.
-- LEFT JOIN to sigma_subdepts: NULL name = orphan (no sigma_subdepts row
-- for this merch_group_nr on this store). This is the SUBDEPT_ORPHAN signal.
article_dims AS (
    SELECT
        a.client_id,
        a.store_code,
        a.product_code,
        a.department_nr,
        COALESCE(d.name, '')    AS dept_name,
        a.merch_group_nr,
        sd.name                 AS subdept_name,
        a.plu_flag,
        a.scale_flag,
        a.record_stock_qty,
        a.description,
        a.sell_price_incl_vat,
        -- is_virtual (SB-CC-B-REPLACE-002): airtime / data bundle / voucher / non-scan
        -- money-posting = NO physical item on a shelf, so sells_real must NOT rescue it
        -- (a till-selling top-up is not stock). Authentic dept + content signals; the
        -- GS1 barcode does NOT separate virtual from physical (verified live 2026-06-15:
        -- airtime + sales-diff postings carry GS1, the physical FOMO cups do not).
        --   - wholesale-virtual VAS depts: AIRTIME, ONLINE VAS/TRANSACTIONS, NON SCAN SALES
        --   - SPAR MOBILE is MIXED: only the SIM card (description) is physical
        --   - NON SCAN / 14% money-postings anywhere (the sales-difference dept)
        -- Mis-deptted real confectionery in the sales-difference dept has no NON SCAN/14%
        -- in its name, so it stays physical and IS rescued.
        ( COALESCE(d.name,'') IN ('AIRTIME','ONLINE VAS PRODUCTS','ONLINE TRANSACTIONS','NON SCAN SALES')
          OR (COALESCE(d.name,'') = 'SPAR MOBILE' AND COALESCE(a.description,'') !~* '\mSIM\M')
          OR COALESCE(a.description,'') ~* '(NON.?SCAN|[^0-9]14\s*%)'
        )                       AS is_virtual
    FROM sigma_articles a
    LEFT JOIN sigma_departments d
        ON  d.client_id     = a.client_id
        AND d.store_code    = a.store_code
        AND d.department_nr = a.department_nr
    LEFT JOIN sigma_subdepts sd
        ON  sd.client_id      = a.client_id
        AND sd.store_code     = a.store_code
        AND sd.merch_group_nr = a.merch_group_nr
),

-- Current SOH and last-sale sentinel from sigma_lifecycle.
lifecycle AS (
    SELECT
        client_id,
        store_code,
        product_code,
        soh,
        last_sale_date
    FROM sigma_lifecycle
),

-- Has-receipt: article received at least once (RECEIPT movement class).
-- Used for S7 buy-and-sell matrix.
has_receipt AS (
    SELECT DISTINCT client_id, store_code, product_code
    FROM l2_movements_typed
    WHERE movement_class = 'RECEIPT'
),

-- PATCH 2026-07-01 (CC, PM merge-queue directive; CC's own ×5 verify caught
-- this before it shipped). Re-derives l2_stock_position's cost_sanity_flag
-- test INLINE (same source, same formula: sigma_supplier_link list_cost/
-- pack_size vs sigma_articles.sell_price_incl_vat) rather than joining
-- l2_stock_position directly -- l2_stock_position is BUILT FROM this MV
-- (build order: item_classification -> ranging_tier -> stock_position), so
-- joining it here would be circular. Verified live 2026-06-30: without this
-- guard, sells_real rescues 10116 product 266 "250 ML STYRENE FOMO CUPS"
-- (cost_sanity_flag=true, unit_cost R333.33, soh 5129) into Capital Tied at
-- R1,709,649.57 -- fictional capital from a broken Sigma pack-size cost, not
-- real stock value (canon §8.5 cascade line 0b: "a line with a broken cost
-- must have its Sigma cost/pack fixed FIRST -- its capital is fiction").
-- Clean (cost-sane) rescue total is ~R54k across 5 stores; this one line was
-- 97% of the naive total. GENERAL (R21) -- same formula l2_stock_position
-- already uses, just computed at the point sells_real needs it.
best_cost AS (
    SELECT DISTINCT ON (client_id, store_code, product_code)
        client_id, store_code, product_code,
        CASE WHEN pack_size > 0 THEN list_cost / pack_size ELSE NULL END AS unit_cost
    FROM sigma_supplier_link
    WHERE status IS DISTINCT FROM 'I'
    ORDER BY client_id, store_code, product_code,
             valid_from DESC NULLS LAST, pack_size ASC NULLS LAST
),

-- Signal evaluation per article.
signals AS (
    SELECT
        ad.client_id,
        ad.store_code,
        ad.product_code,
        ad.department_nr,
        ad.dept_name,
        ad.subdept_name,
        ad.scale_flag,
        ad.record_stock_qty,
        ad.description,
        COALESCE(lc.soh, 0)            AS soh,
        lc.last_sale_date,

        -- S1: NON_STOCK department (deterministic; dept 99 = Overs/Unders)
        (    ad.dept_name IN (
                 'AIRTIME', 'FRONTEND PACK', 'EXPENSES', 'DORMANT',
                 'NON SCAN SALES', 'ONLINE TRANSACTIONS',
                 'ONLINE VAS PRODUCTS', 'SPAR MOBILE'
             )
          OR ad.department_nr = 99
        )                                           AS sig_non_stock_dept,

        -- S2: Dimension-excluded article
        --   dept_nr = 0  -> DEPT_ZERO_PLACEHOLDER (no sigma_departments row)
        --   subdept NULL -> SUBDEPT_ORPHAN (merch_group_nr absent from subdepts)
        (ad.department_nr = 0 OR ad.subdept_name IS NULL)
                                                    AS sig_dim_excluded,

        -- S3: Production INPUT subdept keywords
        --   INGREDIENTS = raw material input
        --   PACKAGING   = consumable supply (bags, trays, labels)
        --   WASTAGE     = write-off accounting line (no POS depletion path)
        (    ad.subdept_name IS NOT NULL
         AND (    ad.subdept_name LIKE '%INGREDIENTS%'
               OR ad.subdept_name LIKE '%PACKAGING%'
               OR ad.subdept_name LIKE '%WASTAGE%'
             )
        )                                           AS sig_prod_input_subdept,

        -- S4: Receipting break (non-scale, deep negative SOH)
        --   Scale items (scale_flag='1') have expected negative SOH from
        --   auto-depletion and are excluded. They appear in l2_stock_integrity
        --   as Type A, not as RECEIPTING_BREAK.
        (ad.scale_flag = '0' AND COALESCE(lc.soh, 0) < -1000)
                                                    AS sig_receipting_break,

        -- S5: Production dept + 1990 sentinel (never sold at POS)
        (    ad.dept_name IN (
                 'BAKERY', 'DELI', 'BUTCHERY', 'HMR',
                 'FISH SHOP', 'PRODUCE', 'FLOWERS', 'COFFEE SHOP'
             )
         AND COALESCE(lc.last_sale_date, '1900-01-01'::date) = '1990-01-01'::date
        )                                           AS sig_prod_dept_never_sold,

        -- S6: PLU flag (SPAR only; 99 items on 10116)
        (ad.plu_flag = '1')                         AS sig_plu_flag,

        -- S7: Has RECEIPT movement AND never sold at POS
        --   never_sold from l2_rate_of_sale: last_sale_date IS NULL (no row
        --   in sigma_sales for this product) or never_sold boolean = TRUE.
        --   Treats missing ros row (LEFT JOIN miss) as never_sold = TRUE.
        (    hr.product_code IS NOT NULL
         AND COALESCE(ros.never_sold, TRUE) = TRUE
        )                                           AS sig_received_never_sold,

        -- S8 (PATCH 2026-07-01): cost sanity, re-derived inline -- see best_cost
        -- CTE comment above. Gates sells_real so a broken Sigma pack-size cost
        -- can never be rescued into Capital Tied.
        (    bc.unit_cost IS NOT NULL
         AND ad.sell_price_incl_vat > 0
         AND bc.unit_cost > ad.sell_price_incl_vat
        )                                           AS sig_cost_sanity,

        -- B-replacement (SB-CC-DEPOSIT-001 follow-on, revised SB-CC-B-REPLACE-002):
        -- a PHYSICAL stock-tracking line (record_stock_qty=1, NOT is_virtual) that
        -- SOLD AT TILL within the §5 364-day "alive" window is real sellable stock --
        -- presence proven by sales (Glenlivet law / canon §8.5), overriding the
        -- dept/dim NON_STOCK heuristic. The is_virtual guard holds airtime, data
        -- bundles, vouchers and NON SCAN money-postings OUT even when they sell --
        -- a till-selling top-up is not physical stock (the verdict, before any rand).
        -- 1990 sentinel + NULL fail the window, so dormant/expense junk is not rescued.
        -- Rescues only physical: carrier bags, FOMO cups, SIM cards, mis-deptted
        -- confectionery. record_stock_qty=0 still wins (S0). Reconcile 2026-06-15:
        -- 41 physical rescued, 87 virtual held, zero virtual in Capital Tied x5.
        (    ad.record_stock_qty = 1
         AND NOT ad.is_virtual
         AND lc.last_sale_date IS NOT NULL
         AND lc.last_sale_date >= CURRENT_DATE - 364
         AND NOT (    bc.unit_cost IS NOT NULL
                  AND ad.sell_price_incl_vat > 0
                  AND bc.unit_cost > ad.sell_price_incl_vat
                 )
        )                                           AS sells_real

    FROM article_dims ad
    LEFT JOIN lifecycle lc
        ON  lc.client_id    = ad.client_id
        AND lc.store_code   = ad.store_code
        AND lc.product_code = ad.product_code
    LEFT JOIN l2_rate_of_sale ros
        ON  ros.client_id    = ad.client_id
        AND ros.store_code   = ad.store_code
        AND ros.product_code = ad.product_code
    LEFT JOIN has_receipt hr
        ON  hr.client_id    = ad.client_id
        AND hr.store_code   = ad.store_code
        AND hr.product_code = ad.product_code
    LEFT JOIN best_cost bc
        ON  bc.client_id    = ad.client_id
        AND bc.store_code   = ad.store_code
        AND bc.product_code = ad.product_code
)

SELECT
    client_id,
    store_code,
    product_code,

    -- Classification verdict (priority cascade: S0 > S1 > S2 > S3 > S4 > S5 > NORMAL)
    -- S0 RECORD_STOCK_OFF: cBESTANDSFUE=0 = Sigma does NOT track this line's stock
    -- quantity (Pieter's intentional do-not-deplete flag). Authoritative NON_STOCK,
    -- above the dept/merch heuristic (SB-CC-L1-RECSTK-001 step 2). NULL = flag not
    -- captured yet -> falls through to the heuristic. =0 wins above everything (S0).
    -- B-replacement: sells_real (record_stock_qty=1 AND sold-at-till in 364d) OVERRIDES
    -- the dept (S1) and dim-orphan (S2) NON_STOCK heuristic -- a proven seller is real
    -- stock regardless of its dept (canon §8.5, presence-by-sales). It then falls through
    -- to the value cascade -> NORMAL (-> HEALTHY downstream). Rescues carrier bags / FOMO
    -- cups / SIM cards (~128 lines, ~R157k); dormant/expense junk fails the 364d sale test.
    CASE
        WHEN record_stock_qty = 0                THEN 'NON_STOCK'
        WHEN sig_non_stock_dept AND NOT sells_real  THEN 'NON_STOCK'
        WHEN sig_dim_excluded   AND NOT sells_real  THEN 'NON_STOCK'
        WHEN sig_prod_input_subdept              THEN 'PRODUCTION'
        WHEN sig_receipting_break                THEN 'RECEIPTING_BREAK'
        WHEN sig_prod_dept_never_sold            THEN 'PRODUCTION'
        ELSE                                          'NORMAL'
    END::text                                    AS class,

    -- Confidence score (0.00 to 1.00)
    CASE
        WHEN record_stock_qty = 0                                             THEN 1.00
        WHEN sig_non_stock_dept                                               THEN 1.00
        WHEN sig_dim_excluded                                                 THEN 1.00
        WHEN sig_prod_input_subdept                                           THEN 0.95
        WHEN sig_receipting_break                                             THEN 0.90
        WHEN sig_prod_dept_never_sold
             AND sig_plu_flag AND sig_received_never_sold                     THEN 0.92
        WHEN sig_prod_dept_never_sold AND sig_plu_flag                        THEN 0.88
        WHEN sig_prod_dept_never_sold AND sig_received_never_sold             THEN 0.85
        WHEN sig_prod_dept_never_sold                                         THEN 0.80
        ELSE                                                                       0.99
    END::numeric(4,2)                            AS confidence,

    -- Fired signals (for Gate 3 precision audit; stored as text array)
    ARRAY_REMOVE(ARRAY[
        CASE WHEN record_stock_qty = 0     THEN 'RECORD_STOCK_OFF'     END,
        CASE WHEN sig_non_stock_dept       THEN 'NON_STOCK_DEPT'       END,
        CASE WHEN sig_dim_excluded         THEN 'DIM_EXCLUDED'         END,
        CASE WHEN sig_prod_input_subdept   THEN 'PROD_INPUT_SUBDEPT'   END,
        CASE WHEN sig_receipting_break     THEN 'RECEIPTING_BREAK'     END,
        CASE WHEN sig_prod_dept_never_sold THEN 'PROD_DEPT_NEVER_SOLD' END,
        CASE WHEN sig_plu_flag             THEN 'PLU_FLAG'             END,
        CASE WHEN sig_received_never_sold  THEN 'RECEIVED_NEVER_SOLD'  END
    ], NULL)::text[]                             AS signals,

    -- Human-readable reason (feeds Reports "why flagged" column)
    CASE
        WHEN record_stock_qty = 0
            THEN 'Record Stock Qty OFF (cBESTANDSFUE=0) -- Sigma not tracking stock, non-deplete line'
        WHEN sig_non_stock_dept
            THEN 'Dept ' || dept_name
                 || ' -- non-stocked category, no physical inventory'
        WHEN sig_dim_excluded AND department_nr = 0
            THEN 'Dept-zero placeholder -- absent from sigma_departments'
        WHEN sig_dim_excluded
            THEN 'Sub-dept orphan -- merch_group_nr not in sigma_subdepts'
        WHEN sig_prod_input_subdept
            THEN 'Sub-dept ' || subdept_name
                 || ' -- production input (ingredients/packaging/wastage)'
        WHEN sig_receipting_break
            THEN 'SOH ' || ROUND(soh::numeric, 0)::text
                 || ' -- receipting break, non-scale item'
        WHEN sig_prod_dept_never_sold
             AND sig_plu_flag AND sig_received_never_sold
            THEN 'Prod dept ' || dept_name
                 || ' -- PLU flag + received + 1990 sentinel (no POS sale)'
        WHEN sig_prod_dept_never_sold AND sig_plu_flag
            THEN 'Prod dept ' || dept_name
                 || ' -- PLU flag + 1990 sentinel (no POS sale)'
        WHEN sig_prod_dept_never_sold AND sig_received_never_sold
            THEN 'Prod dept ' || dept_name
                 || ' -- received + 1990 sentinel (no POS sale)'
        WHEN sig_prod_dept_never_sold
            THEN 'Prod dept ' || dept_name
                 || ' -- 1990 sentinel (no POS sale ever)'
        ELSE 'Normal ranged item'
    END                                          AS reason,

    -- Refresh timestamp (baked in at REFRESH time)
    CURRENT_TIMESTAMP                            AS classified_at

FROM signals;


-- Indexes for the four primary access patterns:
--   1. KPI join: (client_id, store_code, product_code) -> class
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_class_pk
    ON l2_item_classification (client_id, store_code, product_code);

--   2. Class sweep: all articles of a given class in a store
CREATE INDEX IF NOT EXISTS idx_l2_class_store_class
    ON l2_item_classification (store_code, class);

--   3. Exclusion filter: non-NORMAL articles for ghost stock and reports
CREATE INDEX IF NOT EXISTS idx_l2_class_nonormal
    ON l2_item_classification (store_code, class, confidence DESC)
    WHERE class != 'NORMAL';

--   4. High-confidence non-NORMAL (feeds automated reports without review)
CREATE INDEX IF NOT EXISTS idx_l2_class_highconf
    ON l2_item_classification (store_code, class)
    WHERE class != 'NORMAL' AND confidence >= 0.90;


COMMENT ON MATERIALIZED VIEW l2_item_classification IS
    E'GRADE: VERDICT. What a line IS. NORMAL, PRODUCTION, NON_STOCK or RECEIPTING_BREAK, with its confidence, signals and reason.
'
    'Layer 2 keystone classification table. One row per article per store. '
    'Classes: NORMAL / PRODUCTION / NON_STOCK / RECEIPTING_BREAK. '
    'Signal stack: NON_STOCK_DEPT > DIM_EXCLUDED > PROD_INPUT_SUBDEPT > '
    'RECEIPTING_BREAK > PROD_DEPT_NEVER_SOLD > NORMAL. '
    'Refresh nightly after l2_rate_of_sale. SB-CC-L2-001 step 2.';


-- =============================================================================
-- GATE 3 PRECISION VERIFICATION (run after first REFRESH):
--   Compare counts against SB-AP-004 label CSVs for 10116.
--   Acceptance: PRODUCTION + NON_STOCK counts are within expected range;
--   no article with active recent sales is classified PRODUCTION or NON_STOCK.
-- =============================================================================
-- -- Class distribution per store
-- SELECT store_code, class, COUNT(*) AS cnt,
--        ROUND(AVG(confidence)::numeric, 3) AS avg_confidence
-- FROM l2_item_classification
-- GROUP BY store_code, class
-- ORDER BY store_code, class;
--
-- -- Signal breakdown for PRODUCTION class on 10116
-- SELECT
--     UNNEST(signals) AS signal,
--     COUNT(*) AS cnt
-- FROM l2_item_classification
-- WHERE store_code = '10116' AND class = 'PRODUCTION'
-- GROUP BY 1 ORDER BY cnt DESC;
--
-- -- Sanity: no article with recent sales should be non-NORMAL
-- -- (confidence check: find any PRODUCTION/NON_STOCK that sold in 91d)
-- SELECT c.store_code, c.class, c.reason,
--        r.sales_qty_91d, r.last_sale_date, a.description
-- FROM l2_item_classification c
-- JOIN l2_rate_of_sale r
--     ON  r.client_id    = c.client_id
--     AND r.store_code   = c.store_code
--     AND r.product_code = c.product_code
-- JOIN sigma_articles a
--     ON  a.client_id    = c.client_id
--     AND a.store_code   = c.store_code
--     AND a.product_code = c.product_code
-- WHERE c.class IN ('PRODUCTION', 'NON_STOCK')
--   AND r.sales_qty_91d > 0
--   AND c.store_code = '10116'
-- ORDER BY r.sales_qty_91d DESC
-- LIMIT 20;
-- =============================================================================
