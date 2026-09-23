/*
================================================================================
  03_create_interactive_tables.sql
  Wraps raw retail tables in Interactive Tables and creates the Interactive
  Warehouse with auto-scaling and fallback. Runs BEFORE the semantic view —
  the semantic view must reference these Interactive Tables so that Cortex
  Analyst's generated SQL executes on the Interactive Warehouse.

  Prerequisites: Run 01_create_raw_tables.sql first (all 8 RAW tables).
  Run on: MEDIUM standard warehouse (for CTAS operations during table creation).

  DDL ordering (per docs):
    1. CREATE INTERACTIVE TABLE (using standard warehouse for TARGET_LAG refresh)
    2. CREATE INTERACTIVE WAREHOUSE
    3. RESUME warehouse
    4. ADD TABLES (triggers cache warming)
    5. SET FALLBACK_WAREHOUSE
    6. ADD SEARCH OPTIMIZATION on UUID columns for point lookups

  Clustering keys are date-first, multi-column, matched to actual verified-query
  filter patterns (date range dominant; store/product usually GROUP BY targets).
  Clustering on random UUIDs gives no pruning benefit — search optimization is
  the correct mechanism for point lookups (WHERE id = X).
================================================================================
*/

USE DATABASE RETAIL_DEMO;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEMO.APP;
USE SCHEMA APP;

--------------------------------------------------------------------------------
-- Step 0: Create the standard warehouses needed for refresh and fallback
--------------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS RETAIL_REFRESH_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  COMMENT = 'Standard warehouse for Interactive Table refresh (TARGET_LAG)';

CREATE WAREHOUSE IF NOT EXISTS RETAIL_FALLBACK_WH
  WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  COMMENT = 'Fallback warehouse for queries exceeding 5-second Interactive timeout';

USE WAREHOUSE RETAIL_REFRESH_WH;

--------------------------------------------------------------------------------
-- Step 1: Create Interactive Tables (standard warehouse required for CTAS)
--------------------------------------------------------------------------------

-- daily_sales: main fact table (25M rows)
-- Date-first: almost every verified query filters/ranges on sale_date
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.DAILY_SALES_IT
  CLUSTER BY (sale_date, store_id, product_id)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for daily sales transactions'
AS SELECT * FROM RETAIL_DEMO.RAW.DAILY_SALES;

-- inventory: large dimension (2.6M rows)
-- Date-first: "most recent snapshot" is the dominant alert-query filter
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.INVENTORY_IT
  CLUSTER BY (snapshot_date, store_id, product_id)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for weekly inventory snapshots'
AS SELECT * FROM RETAIL_DEMO.RAW.INVENTORY;

-- returns: (~1.68M rows)
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.RETURNS_IT
  CLUSTER BY (return_date, store_id)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for product returns'
AS SELECT * FROM RETAIL_DEMO.RAW.RETURNS;

-- staff_shifts: medium table (219K rows)
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.STAFF_SHIFTS_IT
  CLUSTER BY (shift_date, store_id)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for daily staffing shifts'
AS SELECT * FROM RETAIL_DEMO.RAW.STAFF_SHIFTS;

-- sales_targets: small table (1,200 rows)
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.SALES_TARGETS_IT
  CLUSTER BY (period_month, store_id)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for monthly sales targets'
AS SELECT * FROM RETAIL_DEMO.RAW.SALES_TARGETS;

-- stores: dimension table (50 rows)
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.STORES_IT
  CLUSTER BY (region)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for store dimension data'
AS SELECT * FROM RETAIL_DEMO.RAW.STORES;

-- products: dimension table (500 rows)
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.PRODUCTS_IT
  CLUSTER BY (category)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = RETAIL_REFRESH_WH
  COMMENT = 'Interactive table for product catalog'
AS SELECT * FROM RETAIL_DEMO.RAW.PRODUCTS;

-- Note: promo_calendar (17 rows) intentionally stays a standard table —
-- too small to warrant Interactive, and only referenced during data generation,
-- not by agent queries.

--------------------------------------------------------------------------------
-- Step 2: Create the Interactive Warehouse
-- MEDIUM size; multi-cluster 1-3 for auto-scaling under burst load
--------------------------------------------------------------------------------
CREATE OR REPLACE INTERACTIVE WAREHOUSE RETAIL_AI_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  AUTO_RESUME = TRUE
  COMMENT = 'Interactive warehouse for AI app query execution — sub-second on 25M rows';

--------------------------------------------------------------------------------
-- Step 3: Resume the warehouse
--------------------------------------------------------------------------------
ALTER WAREHOUSE RETAIL_AI_WH RESUME;

--------------------------------------------------------------------------------
-- Step 4: Add Interactive Tables and observability events to the warehouse (triggers cache warming)
-- 8 tables total — under the 10-table proactive-warming limit.
--------------------------------------------------------------------------------
ALTER WAREHOUSE RETAIL_AI_WH ADD TABLES (
  RETAIL_DEMO.APP.DAILY_SALES_IT,
  RETAIL_DEMO.APP.INVENTORY_IT,
  RETAIL_DEMO.APP.RETURNS_IT,
  RETAIL_DEMO.APP.STAFF_SHIFTS_IT,
  RETAIL_DEMO.APP.SALES_TARGETS_IT,
  RETAIL_DEMO.APP.STORES_IT,
  RETAIL_DEMO.APP.PRODUCTS_IT,
  SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
);

--------------------------------------------------------------------------------
-- Step 5: Set fallback warehouse
--------------------------------------------------------------------------------
ALTER WAREHOUSE RETAIL_AI_WH SET FALLBACK_WAREHOUSE = RETAIL_FALLBACK_WH;

--------------------------------------------------------------------------------
-- Step 6: Search optimization on UUID point-lookup columns
-- Clustering on random UUIDs gives no pruning benefit — this is the correct
-- mechanism for WHERE id = X style lookups.
--------------------------------------------------------------------------------
ALTER TABLE RETAIL_DEMO.APP.DAILY_SALES_IT  ADD SEARCH OPTIMIZATION ON EQUALITY(sale_id);
ALTER TABLE RETAIL_DEMO.APP.INVENTORY_IT    ADD SEARCH OPTIMIZATION ON EQUALITY(snapshot_id);
ALTER TABLE RETAIL_DEMO.APP.RETURNS_IT      ADD SEARCH OPTIMIZATION ON EQUALITY(return_id, sale_id);
ALTER TABLE RETAIL_DEMO.APP.STAFF_SHIFTS_IT ADD SEARCH OPTIMIZATION ON EQUALITY(shift_id);

--------------------------------------------------------------------------------
-- VERIFICATION
-- After cache warming completes, test query performance:
--
-- USE WAREHOUSE RETAIL_AI_WH;
-- SELECT s.region, SUM(ds.revenue) AS total_revenue
-- FROM RETAIL_DEMO.APP.DAILY_SALES_IT ds
-- JOIN RETAIL_DEMO.APP.STORES_IT s ON s.store_id = ds.store_id
-- WHERE ds.sale_date >= DATEADD('day', -30, CURRENT_DATE())
-- GROUP BY s.region
-- ORDER BY total_revenue DESC;
-- -- Expected: sub-second execution after cache is warm, 0% remote read
--------------------------------------------------------------------------------
