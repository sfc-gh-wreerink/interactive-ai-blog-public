/*
================================================================================
  01_create_raw_tables.sql
  Generates synthetic retail operations data at REALISTIC scale (25M+ rows)
  with skewed distributions, correlated dimensions, and promotional spikes.

  Run on: XLARGE standard warehouse
  Expected runtime: ~5-10 minutes on XLARGE

  Realism features:
    - Store performance tiers (Flagship / Average / Underperforming) with
      per-store annual growth/decline trends
    - Zipfian product popularity (a few bestsellers drive disproportionate
      volume; long tail of slow movers)
    - 17-date promo calendar with volume spikes + extra discount
      (two "Black Friday"-style events, back-to-school, flash sales, etc.)
    - Weekday effect (Fri/Sat/Sun higher volume)
    - Inventory correlated with product popularity (bestsellers run leaner
      stock — more realistic stockout risk) and store tier
    - Staffing correlated with store performance tier
    - Sales targets scaled to store tier baseline (believable 60-140%
      attainment range, not wildly over/under)

  Table dependency order:
    1. stores (50 rows, performance tiers + trends)
    2. products (500 rows, Zipfian popularity)
    3. promo_calendar (17 rows)
    4. sales_targets (1,200 rows, scaled to store tier)
    5. staff_shifts (~219K rows, correlated with store tier)
    6. daily_sales (~25M rows, THE BIG ONE — all effects combined)
    7. inventory (~2.6M rows, correlated with product popularity)
================================================================================
*/

CREATE DATABASE IF NOT EXISTS RETAIL_DEMO;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEMO.RAW;
USE DATABASE RETAIL_DEMO;
USE SCHEMA RAW;

--------------------------------------------------------------------------------
-- STORES (50 rows) — performance tiers + annual trend
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.STORES AS
WITH seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 50))
),
tiered AS (
    SELECT
        rn,
        CASE
            WHEN rn <= 5  THEN 'Flagship'          -- 10%
            WHEN rn <= 15 THEN 'Underperforming'   -- 20%
            ELSE 'Average'                          -- 70%
        END AS performance_tier
    FROM seq
)
SELECT
    t.rn AS store_id,
    'STORE-' || LPAD(t.rn::VARCHAR, 3, '0') AS store_name,
    CASE MOD(t.rn - 1, 5)
        WHEN 0 THEN 'West'
        WHEN 1 THEN 'Northeast'
        WHEN 2 THEN 'Midwest'
        WHEN 3 THEN 'South'
        WHEN 4 THEN 'Southwest'
    END AS region,
    CASE MOD(t.rn - 1, 5)
        WHEN 0 THEN 1.20
        WHEN 1 THEN 1.15
        WHEN 2 THEN 1.00
        WHEN 3 THEN 1.00
        WHEN 4 THEN 1.05
    END AS region_weight,
    CASE MOD(FLOOR((t.rn - 1) / 5), 5)
        WHEN 0 THEN 'Urban'
        WHEN 1 THEN 'Suburban'
        WHEN 2 THEN 'Mall'
        WHEN 3 THEN 'Outlet'
        WHEN 4 THEN 'Rural'
    END AS store_type,
    UNIFORM(8000, 45000, RANDOM()) AS sq_ft,
    DATEADD('day', -UNIFORM(365, 3650, RANDOM()), CURRENT_DATE()) AS opened_date,
    t.performance_tier,
    CASE t.performance_tier
        WHEN 'Flagship'        THEN ROUND(UNIFORM(2.2::FLOAT, 3.2::FLOAT, RANDOM()), 2)
        WHEN 'Underperforming' THEN ROUND(UNIFORM(0.4::FLOAT, 0.7::FLOAT, RANDOM()), 2)
        ELSE                        ROUND(UNIFORM(0.85::FLOAT, 1.35::FLOAT, RANDOM()), 2)
    END AS performance_multiplier,
    ROUND(UNIFORM(-12.0::FLOAT, 18.0::FLOAT, RANDOM()), 1) AS annual_trend_pct
FROM tiered t;

--------------------------------------------------------------------------------
-- PRODUCTS (500 rows) — Zipfian popularity distribution
-- popularity_rank is shuffled independently of product_id so bestsellers
-- aren't clustered at the start of the ID range.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.PRODUCTS AS
WITH seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 500))
),
categories AS (
    SELECT column1 AS category, column2 AS cat_id FROM VALUES
        ('Apparel', 1), ('Electronics', 2), ('Home', 3), ('Food', 4),
        ('Beauty', 5), ('Sports', 6), ('Toys', 7), ('Office', 8)
),
suppliers AS (
    -- Mix of fast domestic and slow overseas suppliers for supply-chain queries
    SELECT column1 AS supplier, column2 AS supplier_id, column3 AS base_lead_time FROM VALUES
        ('Acme Distribution',      1, 5),
        ('Northeast Wholesale',    2, 4),
        ('FastTrack Logistics',    3, 3),
        ('Premier Brands Inc',     4, 7),
        ('Value Chain Partners',   5, 10),
        ('Pacific Rim Imports',    6, 28),
        ('Global Sourcing Co',     7, 35),
        ('Artisan Supply Co',      8, 18)
),
ranked AS (
    SELECT
        s.rn AS product_id,
        ROW_NUMBER() OVER (ORDER BY UNIFORM(0, 1000000, RANDOM())) AS popularity_rank
    FROM seq s
)
-- Hyperbolic Zipf curve: multiplier = C / (1 + k*(rank-1)), calibrated so
-- multiplier(1) = 3.0 and multiplier(500) = 0.3. A linear min-max rescale of
-- the raw 1/rank^0.85 weight crushes the curve (weight decays too fast before
-- normalization), so this direct hyperbolic form is used instead.
SELECT
    r.product_id,
    'SKU-' || LPAD(r.product_id::VARCHAR, 5, '0') AS sku,
    'Product ' || r.product_id::VARCHAR AS product_name,
    c.category,
    CASE MOD(r.product_id - 1, 4)
        WHEN 0 THEN 'Premium'
        WHEN 1 THEN 'Standard'
        WHEN 2 THEN 'Value'
        WHEN 3 THEN 'Economy'
    END AS subcategory,
    ROUND(UNIFORM(2.0::FLOAT, 80.0::FLOAT, RANDOM()), 2) AS unit_cost,
    ROUND(UNIFORM(2.0::FLOAT, 80.0::FLOAT, RANDOM()) * UNIFORM(1.3::FLOAT, 3.0::FLOAT, RANDOM()), 2) AS unit_price,
    r.popularity_rank,
    ROUND(3.0 / (1 + 0.018036 * (r.popularity_rank - 1)), 3) AS popularity_multiplier,
    sup.supplier,
    GREATEST(1, ROUND(sup.base_lead_time * UNIFORM(0.8::FLOAT, 1.3::FLOAT, RANDOM())))::INT AS lead_time_days
FROM ranked r
JOIN categories c ON c.cat_id = MOD(r.product_id - 1, 8) + 1
JOIN suppliers sup ON sup.supplier_id = MOD(r.product_id - 1, 8) + 1;

--------------------------------------------------------------------------------
-- PROMO_CALENDAR (17 rows) — promotional spike days over the 2-year window
-- day_offset is relative to CURRENT_DATE(), matching daily_sales' date math.
-- Includes two "Black Friday" analogues one year apart.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.PROMO_CALENDAR AS
SELECT
    DATEADD('day', -day_offset, CURRENT_DATE()) AS promo_date,
    promo_name,
    volume_multiplier,
    extra_discount
FROM VALUES
    (18,  'Flash Sale',         2.2, 0.10),
    (45,  'Weekend Blowout',    2.0, 0.08),
    (95,  'Seasonal Clearance', 2.5, 0.15),
    (140, 'Flash Sale',         2.1, 0.10),
    (200, 'Mid-Year Sale',      2.3, 0.12),
    (260, 'Back to School',     2.4, 0.10),
    (330, 'Fall Preview',       2.0, 0.08),
    (355, 'Black Friday',       4.0, 0.25),
    (362, 'Cyber Monday',       3.5, 0.22),
    (385, 'Holiday Sale',       2.8, 0.15),
    (420, 'New Year Clearance', 2.6, 0.20),
    (480, 'Flash Sale',         2.1, 0.10),
    (545, 'Mid-Year Sale',      2.2, 0.12),
    (600, 'Back to School',     2.3, 0.10),
    (620, 'Fall Preview',       2.0, 0.08),
    (715, 'Black Friday',       4.0, 0.25),
    (722, 'Cyber Monday',       3.5, 0.22)
    AS t(day_offset, promo_name, volume_multiplier, extra_discount);

--------------------------------------------------------------------------------
-- SALES_TARGETS (1,200 rows: 50 stores x 24 months)
-- Scaled to store performance tier so attainment lands in a believable
-- 60-140% range rather than wildly over/under-shooting.
-- Range calibrated empirically from actual per-tier monthly revenue
-- (Flagship ~$27.7M/mo, Average ~$10.3M/mo, Underperforming ~$4.8M/mo,
-- implying ~$9.3M per multiplier point) -- NOT the original $150K-250K
-- baseline, which was off by two orders of magnitude vs. actual revenue.
--------------------------------------------------------------------------------
-- period_month is relative to CURRENT_DATE() (rolling 24 months ending this
-- month), matching daily_sales' rolling 2-year window. A hardcoded start date
-- ('2024-01-01') drifted out of sync with daily_sales as time passed, leaving
-- recent months (e.g. current quarter) with zero target rows.
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.SALES_TARGETS AS
WITH months AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY seq4()) AS m_num,
        DATEADD('month', ROW_NUMBER() OVER (ORDER BY seq4()) - 24, DATE_TRUNC('month', CURRENT_DATE())) AS period_month
    FROM TABLE(GENERATOR(ROWCOUNT => 24))
)
SELECT
    s.store_id,
    m.period_month,
    ROUND(s.performance_multiplier * UNIFORM(7500000.0::FLOAT, 11000000.0::FLOAT, RANDOM()), 2) AS target_revenue,
    ROUND(s.performance_multiplier * UNIFORM(95000.0::FLOAT, 150000.0::FLOAT, RANDOM()))::INT AS target_units
FROM RETAIL_DEMO.RAW.STORES s
CROSS JOIN months m;

--------------------------------------------------------------------------------
-- STAFF_SHIFTS (~219K rows) — headcount/hours correlated with store tier
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.STAFF_SHIFTS AS
WITH seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 219000))
),
base AS (
    SELECT
        rn,
        MOD(rn - 1, 50) + 1 AS store_id,
        DATEADD('day', -MOD(FLOOR((rn - 1) / 50), 730), CURRENT_DATE()) AS shift_date,
        CASE MOD(FLOOR((rn - 1) / (50 * 730)), 3)
            WHEN 0 THEN 'Morning'
            WHEN 1 THEN 'Afternoon'
            WHEN 2 THEN 'Evening'
        END AS shift_type
    FROM seq
)
SELECT
    UUID_STRING() AS shift_id,
    b.store_id,
    b.shift_date,
    b.shift_type,
    GREATEST(3, ROUND(
        (CASE WHEN DAYOFWEEK(b.shift_date) IN (5, 6, 0) THEN UNIFORM(8, 18, RANDOM()) ELSE UNIFORM(5, 14, RANDOM()) END)
        * SQRT(s.performance_multiplier)
    ))::INT AS headcount,
    GREATEST(20, ROUND(
        (CASE WHEN DAYOFWEEK(b.shift_date) IN (5, 6, 0) THEN UNIFORM(48, 144, RANDOM()) ELSE UNIFORM(40, 112, RANDOM()) END)
        * SQRT(s.performance_multiplier)
    ))::INT AS hours_worked,
    -- Regional wage variance: West/Northeast run higher cost-of-living wages
    ROUND(
        CASE s.region
            WHEN 'West'      THEN UNIFORM(22.0::FLOAT, 26.0::FLOAT, RANDOM())
            WHEN 'Northeast' THEN UNIFORM(21.0::FLOAT, 25.0::FLOAT, RANDOM())
            ELSE                  UNIFORM(16.0::FLOAT, 20.0::FLOAT, RANDOM())
        END
    , 2) AS hourly_wage
FROM base b
JOIN RETAIL_DEMO.RAW.STORES s ON s.store_id = b.store_id;

--------------------------------------------------------------------------------
-- DAILY_SALES (~25M rows) — THE BIG ONE
-- Combines: store tier, product popularity, weekday effect, per-store trend
-- over time, and promo calendar spikes.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.DAILY_SALES AS
WITH seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 25000000))
),
base AS (
    SELECT
        rn,
        UUID_STRING() AS sale_id,
        MOD(rn - 1, 50) + 1 AS store_id,
        MOD(FLOOR((rn - 1) / 50), 500) + 1 AS product_id,
        UNIFORM(0, 729, RANDOM()) AS days_ago,
        UNIFORM(1, 12, RANDOM()) AS base_units,
        ROUND(UNIFORM(0.0::FLOAT, 0.20::FLOAT, RANDOM()), 2) AS base_discount_pct,
        UNIFORM(0.0::FLOAT, 1.0::FLOAT, RANDOM()) AS channel_draw
    FROM seq
),
joined AS (
    SELECT
        b.sale_id,
        b.store_id,
        b.product_id,
        DATEADD('day', -b.days_ago, CURRENT_DATE()) AS sale_date,
        (729 - b.days_ago) / 365.0 AS years_elapsed,
        b.base_units,
        b.base_discount_pct,
        b.channel_draw,
        s.performance_multiplier,
        s.annual_trend_pct,
        s.store_type,
        p.popularity_multiplier,
        p.unit_price,
        COALESCE(pc.volume_multiplier, 1.0) AS promo_volume_mult,
        COALESCE(pc.extra_discount, 0.0) AS promo_extra_discount,
        pc.promo_name
    FROM base b
    JOIN RETAIL_DEMO.RAW.STORES   s  ON s.store_id   = b.store_id
    JOIN RETAIL_DEMO.RAW.PRODUCTS p  ON p.product_id = b.product_id
    LEFT JOIN RETAIL_DEMO.RAW.PROMO_CALENDAR pc
      ON pc.promo_date = DATEADD('day', -b.days_ago, CURRENT_DATE())
),
computed AS (
    SELECT
        j.*,
        GREATEST(1, ROUND(
            j.base_units
            * j.performance_multiplier
            * j.popularity_multiplier
            * CASE WHEN DAYOFWEEK(j.sale_date) IN (5, 6, 0) THEN 1.25 ELSE 0.95 END
            * (1 + j.annual_trend_pct / 100.0 * j.years_elapsed)
            * j.promo_volume_mult
        ))::INT AS final_units_sold,
        LEAST(0.60, ROUND(j.base_discount_pct + j.promo_extra_discount, 2)) AS final_discount_pct,
        -- Online penetration: Urban/Mall stores skew more online (click-and-collect),
        -- Rural stores skew less online
        CASE
            WHEN j.store_type IN ('Urban', 'Mall')      AND j.channel_draw < 0.32 THEN 'Online'
            WHEN j.store_type IN ('Suburban', 'Outlet')  AND j.channel_draw < 0.22 THEN 'Online'
            WHEN j.store_type = 'Rural'                  AND j.channel_draw < 0.12 THEN 'Online'
            ELSE 'In-Store'
        END AS channel
    FROM joined j
)
SELECT
    c.sale_id,
    c.store_id,
    c.product_id,
    c.sale_date,
    c.final_units_sold AS units_sold,
    c.final_discount_pct AS discount_pct,
    c.channel,
    c.promo_name,
    ROUND(
        c.final_units_sold
        * c.unit_price
        * (1.0 - c.final_discount_pct)
        * CASE
            WHEN MONTH(c.sale_date) IN (10, 11, 12) THEN 1.15
            WHEN MONTH(c.sale_date) IN (1, 2, 3)    THEN 0.90
            ELSE 1.00
          END
    , 2) AS revenue,
    CURRENT_TIMESTAMP() AS created_at
FROM computed c;

--------------------------------------------------------------------------------
-- INVENTORY (~2.6M rows) — correlated with product popularity + store tier
-- Bestsellers run leaner stock (realistic stockout risk).
-- Flagship stores have higher reorder thresholds (higher throughput).
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.INVENTORY AS
WITH seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 2600000))
),
base AS (
    SELECT
        rn,
        MOD(rn - 1, 50) + 1 AS store_id,
        MOD(FLOOR((rn - 1) / 50), 500) + 1 AS product_id,
        DATEADD('week', -MOD(FLOOR((rn - 1) / 25000), 104), CURRENT_DATE()) AS snapshot_date
    FROM seq
)
SELECT
    UUID_STRING() AS snapshot_id,
    b.store_id,
    b.product_id,
    b.snapshot_date,
    GREATEST(0, ROUND(UNIFORM(0, 500, RANDOM()) / POWER(p.popularity_multiplier, 0.6)))::INT AS units_on_hand,
    ROUND(UNIFORM(20, 80, RANDOM()) * SQRT(s.performance_multiplier))::INT AS reorder_point,
    ROUND(UNIFORM(0.0::FLOAT, 60.0::FLOAT, RANDOM()) / POWER(p.popularity_multiplier, 0.4), 1) AS days_of_supply,
    -- Bestsellers get larger, more frequent replenishment orders
    GREATEST(0, ROUND(UNIFORM(0, 150, RANDOM()) * POWER(p.popularity_multiplier, 0.5)))::INT AS units_on_order,
    CURRENT_TIMESTAMP() AS created_at
FROM base b
JOIN RETAIL_DEMO.RAW.STORES s ON s.store_id = b.store_id
JOIN RETAIL_DEMO.RAW.PRODUCTS p ON p.product_id = b.product_id;

--------------------------------------------------------------------------------
-- RETURNS (~1.5-2M rows, ~6-8% of daily_sales) — return rate varies by
-- category (Apparel/Electronics highest) and channel (Online higher than
-- In-Store). Generated as a filtered sample of daily_sales transactions.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAIL_DEMO.RAW.RETURNS AS
WITH candidates AS (
    SELECT
        d.sale_id,
        d.store_id,
        d.product_id,
        d.sale_date,
        d.channel,
        d.revenue,
        p.category,
        UNIFORM(0.0::FLOAT, 1.0::FLOAT, RANDOM()) AS r
    FROM RETAIL_DEMO.RAW.DAILY_SALES d
    JOIN RETAIL_DEMO.RAW.PRODUCTS p ON p.product_id = d.product_id
),
thresholded AS (
    SELECT
        *,
        (CASE category
            WHEN 'Apparel'     THEN 0.12
            WHEN 'Electronics' THEN 0.10
            WHEN 'Beauty'      THEN 0.06
            WHEN 'Toys'        THEN 0.05
            WHEN 'Sports'      THEN 0.05
            WHEN 'Home'        THEN 0.04
            WHEN 'Office'      THEN 0.03
            WHEN 'Food'        THEN 0.01
         END
         + CASE WHEN channel = 'Online' THEN 0.04 ELSE 0.0 END
        ) AS return_threshold
    FROM candidates
)
SELECT
    UUID_STRING() AS return_id,
    sale_id,
    store_id,
    product_id,
    sale_date,
    DATEADD('day', UNIFORM(1, 14, RANDOM()), sale_date) AS return_date,
    CASE UNIFORM(0, 4, RANDOM())
        WHEN 0 THEN 'Wrong Size'
        WHEN 1 THEN 'Defective'
        WHEN 2 THEN 'Changed Mind'
        WHEN 3 THEN 'Not as Described'
        ELSE 'Other'
    END AS return_reason,
    ROUND(revenue * UNIFORM(0.85::FLOAT, 1.0::FLOAT, RANDOM()), 2) AS refund_amount
FROM thresholded
WHERE r < return_threshold;

--------------------------------------------------------------------------------
-- VERIFICATION QUERIES (run after setup)
--------------------------------------------------------------------------------
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.STORES;           -- expect: 50
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.PRODUCTS;         -- expect: 500
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.PROMO_CALENDAR;   -- expect: 17
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.SALES_TARGETS;    -- expect: 1200
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.STAFF_SHIFTS;     -- expect: 219000
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.DAILY_SALES;      -- expect: 25000000
-- SELECT COUNT(*) FROM RETAIL_DEMO.RAW.INVENTORY;        -- expect: 2600000
--
-- Verify skew: flagship stores should show dramatically higher revenue
-- SELECT s.performance_tier, COUNT(DISTINCT s.store_id) AS n_stores,
--        ROUND(SUM(d.revenue) / COUNT(DISTINCT s.store_id), 0) AS avg_revenue_per_store
-- FROM RETAIL_DEMO.RAW.DAILY_SALES d
-- JOIN RETAIL_DEMO.RAW.STORES s ON s.store_id = d.store_id
-- GROUP BY s.performance_tier ORDER BY avg_revenue_per_store DESC;
--
-- Verify Zipfian product concentration: top 10% of products should drive
-- a disproportionate share of revenue
-- SELECT CASE WHEN p.popularity_rank <= 50 THEN 'Top 10%' ELSE 'Rest' END AS segment,
--        ROUND(SUM(d.revenue), 0) AS total_revenue
-- FROM RETAIL_DEMO.RAW.DAILY_SALES d
-- JOIN RETAIL_DEMO.RAW.PRODUCTS p ON p.product_id = d.product_id
-- GROUP BY segment;
