/*
================================================================================
  02_create_semantic_view.sql
  Creates a Semantic View over the retail operations Interactive Tables for
  Cortex Analyst.

  CRITICAL: All logical tables point at RETAIL_DEMO.APP.*_IT (Interactive
  Tables), NOT the RAW tables. This is what allows Cortex Analyst's generated
  SQL to execute on the Interactive Warehouse (RETAIL_AI_WH) — an Interactive
  Warehouse can only query Interactive Tables.

  Uses CREATE SEMANTIC VIEW DDL (recommended approach; not YAML on stage).

  Prerequisites: Run 03_create_interactive_tables.sql first.
  Run on: any standard warehouse (fast; metadata operation)
================================================================================
*/

USE DATABASE RETAIL_DEMO;
USE SCHEMA APP;

CREATE OR REPLACE SEMANTIC VIEW RETAIL_DEMO.APP.RETAIL_OPS_SV

  TABLES (
    daily_sales AS RETAIL_DEMO.APP.DAILY_SALES_IT
      PRIMARY KEY (sale_id)
      WITH SYNONYMS ('sales', 'transactions', 'orders')
      COMMENT = 'Daily sales transactions by store and product',
    stores AS RETAIL_DEMO.APP.STORES_IT
      PRIMARY KEY (store_id)
      WITH SYNONYMS ('locations', 'branches'),
    products AS RETAIL_DEMO.APP.PRODUCTS_IT
      PRIMARY KEY (product_id)
      WITH SYNONYMS ('items', 'skus'),
    sales_targets AS RETAIL_DEMO.APP.SALES_TARGETS_IT
      PRIMARY KEY (store_id, period_month)
      WITH SYNONYMS ('targets', 'quotas', 'goals')
      COMMENT = 'Monthly revenue and unit targets by store',
    inventory AS RETAIL_DEMO.APP.INVENTORY_IT
      PRIMARY KEY (snapshot_id)
      WITH SYNONYMS ('stock', 'stock levels')
      COMMENT = 'Weekly inventory snapshots by store and product',
    staff_shifts AS RETAIL_DEMO.APP.STAFF_SHIFTS_IT
      PRIMARY KEY (shift_id)
      WITH SYNONYMS ('staffing', 'labor', 'shifts')
      COMMENT = 'Daily staffing shifts by store',
    returns AS RETAIL_DEMO.APP.RETURNS_IT
      PRIMARY KEY (return_id)
      WITH SYNONYMS ('refunds', 'returned items')
      COMMENT = 'Product returns with reason and refund amount'
  )

  RELATIONSHIPS (
    daily_sales_to_stores AS
      daily_sales (store_id) REFERENCES stores (store_id),
    daily_sales_to_products AS
      daily_sales (product_id) REFERENCES products (product_id),
    targets_to_stores AS
      sales_targets (store_id) REFERENCES stores (store_id),
    inventory_to_stores AS
      inventory (store_id) REFERENCES stores (store_id),
    inventory_to_products AS
      inventory (product_id) REFERENCES products (product_id),
    shifts_to_stores AS
      staff_shifts (store_id) REFERENCES stores (store_id),
    returns_to_stores AS
      returns (store_id) REFERENCES stores (store_id),
    returns_to_products AS
      returns (product_id) REFERENCES products (product_id),
    returns_to_daily_sales AS
      returns (sale_id) REFERENCES daily_sales (sale_id)
  )

  FACTS (
    daily_sales.units_sold_fact AS units_sold,
    daily_sales.revenue_fact AS revenue
      COMMENT = 'Revenue per transaction, after discount',
    daily_sales.discount_pct_fact AS discount_pct,
    inventory.units_on_hand_fact AS units_on_hand,
    inventory.reorder_point_fact AS reorder_point
      COMMENT = 'Reorder threshold for the product at this store',
    inventory.units_on_order_fact AS units_on_order
      COMMENT = 'Units on order from supplier, pending replenishment',
    staff_shifts.headcount_fact AS headcount,
    staff_shifts.hours_worked_fact AS hours_worked,
    staff_shifts.wage_fact AS hourly_wage,
    products.lead_time_fact AS lead_time_days
      COMMENT = 'Supplier lead time in days',
    returns.refund_amount_fact AS refund_amount,
    -- Added 2026-08-13 after measuring hallucinated-column errors in
    -- AI_OBSERVABILITY_EVENTS. sales_targets was the ONLY measure table with
    -- no registered facts, and its metric aggregated the bare physical column
    -- (SUM(target_revenue)). Because Cortex builds __table CTEs that project
    -- the registered fact alias, sales_targets' CTE projected the raw physical
    -- name while every other table's projected a _fact alias. The agent, having
    -- learned the _fact pattern from the other six tables, had no matching
    -- landing spot here and fell back to the METRIC name inside its CTE.
    -- Result: 'invalid identifier ST.TOTAL_TARGET_REVENUE' and variants,
    -- 90 failed SQL calls across 21 turns (39% of all identifier errors),
    -- and one attempt at ST.TARGET_REVENUE_FACT -- the convention that did
    -- not exist here until now. Registering both facts makes this table
    -- structurally identical to the other six.
    sales_targets.target_revenue_fact AS target_revenue
      COMMENT = 'Monthly revenue target for this store',
    sales_targets.target_units_fact AS target_units
      COMMENT = 'Monthly unit-sales target for this store'
  )

  DIMENSIONS (
    stores.region AS region
      WITH SYNONYMS = ('area', 'territory')
      SAMPLE_VALUES ('West', 'Northeast', 'Midwest', 'South', 'Southwest')
      IS_ENUM,
    stores.store_type AS store_type
      WITH SYNONYMS = ('format', 'store format')
      SAMPLE_VALUES ('Urban', 'Suburban', 'Mall', 'Outlet', 'Rural')
      IS_ENUM,
    stores.performance_tier AS performance_tier
      WITH SYNONYMS = ('store tier')
      SAMPLE_VALUES ('Flagship', 'Average', 'Underperforming')
      IS_ENUM,
    stores.store_name AS store_name,
    products.category AS category
      WITH SYNONYMS = ('department')
      SAMPLE_VALUES ('Apparel', 'Electronics', 'Home', 'Food', 'Beauty', 'Sports', 'Toys', 'Office')
      IS_ENUM,
    products.subcategory AS subcategory
      COMMENT = 'Product price tier, not a product type'
      SAMPLE_VALUES ('Premium', 'Standard', 'Value', 'Economy')
      IS_ENUM,
    products.supplier AS supplier
      WITH SYNONYMS = ('vendor', 'manufacturer'),
    daily_sales.sale_date AS sale_date
      WITH SYNONYMS = ('transaction date', 'order date'),
    daily_sales.channel AS channel
      SAMPLE_VALUES ('Online', 'In-Store')
      IS_ENUM,
    daily_sales.promo_name AS promo_name
      WITH SYNONYMS = ('promotion', 'sale event')
      COMMENT = 'Promotional event active on this sale date (e.g. Black Friday); NULL on non-promo days',
    sales_targets.period_month AS period_month,
    inventory.snapshot_date AS snapshot_date,
    staff_shifts.shift_date AS shift_date,
    staff_shifts.shift_type AS shift_type
      SAMPLE_VALUES ('Morning', 'Afternoon', 'Evening')
      IS_ENUM,
    returns.return_date AS return_date,
    returns.return_reason AS return_reason
      SAMPLE_VALUES ('Wrong Size', 'Defective', 'Changed Mind', 'Not as Described', 'Other')
      IS_ENUM
  )

  METRICS (
    daily_sales.total_revenue AS SUM(revenue_fact)
      WITH SYNONYMS = ('total sales', 'gross revenue'),
    daily_sales.total_units_sold AS SUM(units_sold_fact)
      WITH SYNONYMS = ('units sold'),
    daily_sales.transaction_count AS COUNT(*)
      WITH SYNONYMS = ('number of transactions', 'sales count'),
    daily_sales.avg_discount_pct AS AVG(discount_pct_fact),
    daily_sales.avg_order_value AS AVG(revenue_fact)
      WITH SYNONYMS = ('AOV'),
    daily_sales.online_revenue_pct AS SUM(CASE WHEN channel = 'Online' THEN revenue_fact ELSE 0 END) / NULLIF(SUM(revenue_fact), 0) * 100
      WITH SYNONYMS = ('online penetration', 'online share'),
    inventory.avg_units_on_hand AS AVG(units_on_hand_fact),
    inventory.inventory_alert_count AS COUNT(CASE WHEN units_on_hand_fact < reorder_point_fact THEN 1 END)
      WITH SYNONYMS = ('stockout risk', 'low stock count'),
    inventory.total_units_on_order AS SUM(units_on_order_fact)
      WITH SYNONYMS = ('incoming replenishment'),
    staff_shifts.total_headcount AS SUM(headcount_fact),
    staff_shifts.total_labor_hours AS SUM(hours_worked_fact),
    staff_shifts.total_labor_cost AS SUM(hours_worked_fact * wage_fact)
      WITH SYNONYMS = ('labor cost', 'staffing cost'),
    sales_targets.total_target_revenue AS SUM(target_revenue_fact),
    products.avg_lead_time_days AS AVG(lead_time_fact)
      WITH SYNONYMS = ('supplier lead time'),
    returns.return_count AS COUNT(*),
    returns.total_refund_amount AS SUM(refund_amount_fact)
      WITH SYNONYMS = ('total refunds'),
    return_rate_pct AS returns.return_count / NULLIF(daily_sales.transaction_count, 0) * 100
      WITH SYNONYMS = ('return rate')
  )

  COMMENT = 'Retail operations: sales, inventory, staffing, targets, returns'

  AI_SQL_GENERATION 'Every raw per-row column is registered as a fact suffixed _fact, and must always be wrapped in an aggregate. Reference facts by their _fact name, not the underlying physical column name. METRICS are valid only in the outermost aggregated SELECT -- never inside a CTE or JOIN condition; aggregate the underlying fact directly there instead (e.g. SUM(target_revenue_fact), not total_target_revenue). Join returns to daily_sales directly on sale_id rather than bridging through a shared dimension, to avoid duplicate counting. When combining tables at different grains (e.g. daily transactions vs monthly targets), aggregate each to the shared grain in its own CTE first, then join the CTEs 1:1.'

  AI_QUESTION_CATEGORIZATION 'Reject questions about individual customer identities, PII, or employee personal data; this view holds only aggregate store-level operations data.';

-- NOTE: the AI_VERIFIED_QUERIES block was removed and preserved in
-- setup/02b_verified_queries_reference.sql. RETAIL_OPS_AGENT never used it
-- (zero cortex_analyst_text_to_sql events across 20 measured turns), and it was
-- 57% of the semantic view DDL. Restore it before building any DIRECT Cortex
-- Analyst path, which does benefit from verified queries.


--------------------------------------------------------------------------------
-- VERIFICATION
--------------------------------------------------------------------------------
-- DESCRIBE SEMANTIC VIEW RETAIL_DEMO.APP.RETAIL_OPS_SV;
-- SHOW SEMANTIC VIEWS IN SCHEMA RETAIL_DEMO.APP;
-- SELECT GET_DDL('SEMANTIC_VIEW', 'RETAIL_DEMO.APP.RETAIL_OPS_SV', TRUE);

-- Grant access for demo role (update role name as needed):
-- GRANT REFERENCES, SELECT ON SEMANTIC VIEW RETAIL_DEMO.APP.RETAIL_OPS_SV TO ROLE <demo_role>;
