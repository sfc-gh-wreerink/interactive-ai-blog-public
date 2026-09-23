/*
================================================================================
  09_cluster_raw_tables.sql
  Ports the clustering keys and search optimization from the *_IT Interactive
  Tables (03_create_interactive_tables.sql) onto the RETAIL_DEMO.RAW base
  tables, so the *_IT layer can be retired entirely.

  WHY THIS FILE EXISTS
  Zero-copy Interactive (enabled on this account 2026-08-14) lets a plain base
  table be attached to an Interactive Warehouse directly -- no CREATE
  INTERACTIVE TABLE, no TARGET_LAG. Verified twice:
    - SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS, a table this account does not
      own, attached and queried successfully.
    - All 7 RETAIL_DEMO.RAW.* tables attached to RETAIL_SV_TEST_IWH, and
      RETAIL_OPS_SV_RAW returned results byte-identical to the *_IT-backed
      RETAIL_OPS_SV on RETAIL_AI_WH.

  But zero-copy removes the need for the interactive table OBJECT TYPE, not for
  the CLUSTERING. Measured on the date-filtered heavy query (2026-08-14):
    RAW  (unclustered) -- 2.36 GB scanned
    *_IT (clustered)   --  290 MB scanned   = 8.1x less
  SYSTEM$CLUSTERING_INFORMATION on RAW.DAILY_SALES confirmed the cause:
  average_depth 45.0 across 45 partitions on sale_date -- every partition
  overlaps every other, so a date predicate prunes nothing.

  The *_IT layer was doing three jobs. Only one of them was "be an interactive
  table":
    1. CLUSTER BY            -> ported here, still required
    2. SEARCH OPTIMIZATION   -> ported here, still required
    3. TARGET_LAG = 5 min    -> DELETED. Pure overhead under zero-copy, and it
                                was costing up to 5 minutes of staleness plus
                                RETAIL_REFRESH_WH credits. Base tables are live.

  COST WARNING: the first ALTER on DAILY_SALES (25M rows) and INVENTORY (2.6M)
  triggers automatic reclustering, which runs asynchronously and consumes
  serverless credits. Reclustering is NOT instant -- re-measure pruning only
  after SYSTEM$CLUSTERING_INFORMATION shows average_depth dropping toward 1.

  Run on: ACCOUNTADMIN or owner of RETAIL_DEMO.RAW
================================================================================
*/

USE DATABASE RETAIL_DEMO;
USE SCHEMA RAW;

--------------------------------------------------------------------------------
-- Step 1: Clustering keys -- copied verbatim from the *_IT definitions.
-- Date-first in every case: the verified-query filter patterns are dominated by
-- date ranges, with store/product as GROUP BY targets rather than predicates.
--------------------------------------------------------------------------------
ALTER TABLE RETAIL_DEMO.RAW.DAILY_SALES   CLUSTER BY (sale_date, store_id, product_id);
ALTER TABLE RETAIL_DEMO.RAW.INVENTORY     CLUSTER BY (snapshot_date, store_id, product_id);
ALTER TABLE RETAIL_DEMO.RAW.RETURNS       CLUSTER BY (return_date, store_id);
ALTER TABLE RETAIL_DEMO.RAW.STAFF_SHIFTS  CLUSTER BY (shift_date, store_id);
ALTER TABLE RETAIL_DEMO.RAW.SALES_TARGETS CLUSTER BY (period_month, store_id);

-- STORES (50 rows) and PRODUCTS (500 rows) are included for parity with
-- 03_create_interactive_tables.sql, but note: both fit in a single micro-
-- partition, so clustering them is a metadata no-op with no pruning benefit
-- either way. Harmless, not useful. Kept only so the RAW set is a faithful
-- one-for-one replacement of the *_IT set.
ALTER TABLE RETAIL_DEMO.RAW.STORES        CLUSTER BY (region);
ALTER TABLE RETAIL_DEMO.RAW.PRODUCTS      CLUSTER BY (category);

--------------------------------------------------------------------------------
-- Step 2: Search optimization on the UUID point-lookup columns.
-- Clustering on random UUIDs gives no pruning benefit -- search optimization is
-- the correct mechanism for WHERE id = X. Same four tables as the *_IT set.
--------------------------------------------------------------------------------
ALTER TABLE RETAIL_DEMO.RAW.DAILY_SALES   ADD SEARCH OPTIMIZATION ON EQUALITY(sale_id);
ALTER TABLE RETAIL_DEMO.RAW.INVENTORY     ADD SEARCH OPTIMIZATION ON EQUALITY(snapshot_id);
ALTER TABLE RETAIL_DEMO.RAW.RETURNS       ADD SEARCH OPTIMIZATION ON EQUALITY(return_id, sale_id);
ALTER TABLE RETAIL_DEMO.RAW.STAFF_SHIFTS  ADD SEARCH OPTIMIZATION ON EQUALITY(shift_id);

--------------------------------------------------------------------------------
-- VERIFICATION -- run these AFTER reclustering has had time to progress.
--------------------------------------------------------------------------------
-- Clustering depth should trend toward 1.0; it starts at 45.0 (fully overlapped).
-- SELECT SYSTEM$CLUSTERING_INFORMATION('RETAIL_DEMO.RAW.DAILY_SALES', '(sale_date)');
--
-- Search optimization build progress:
-- SHOW TABLES LIKE 'DAILY_SALES' IN SCHEMA RETAIL_DEMO.RAW;
--   -> check search_optimization / search_optimization_progress columns
--
-- Then re-run the heavy query and compare bytes_scanned against the 290 MB
-- *_IT baseline:
-- USE WAREHOUSE RETAIL_SV_TEST_IWH;
-- SELECT * FROM SEMANTIC_VIEW(
--   RETAIL_DEMO.APP.RETAIL_OPS_SV_RAW
--   DIMENSIONS stores.region, products.category
--   METRICS daily_sales.total_revenue, daily_sales.total_units_sold, daily_sales.avg_order_value
--   WHERE daily_sales.sale_date >= '2026-07-01'
-- ) ORDER BY total_revenue DESC LIMIT 15;
--------------------------------------------------------------------------------
