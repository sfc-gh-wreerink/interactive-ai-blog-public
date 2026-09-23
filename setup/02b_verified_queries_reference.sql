/*
================================================================================
  02b_verified_queries_reference.sql
  PRESERVED verified-query block, removed from 02_create_semantic_view.sql.

  WHY REMOVED: RETAIL_OPS_AGENT never uses them. Its measured tool calls are
  system_agentic_semantic_context + system_execute_sql, with zero
  cortex_analyst_text_to_sql events, so verified_query_used was never true
  across 20 measured turns. The block was 8,788 chars = 57% of the semantic
  view DDL, i.e. context cost with no benefit on the agent path.

  WHEN TO RESTORE: a DIRECT Cortex Analyst call (no agent) DOES use verified
  queries, and internal guidance puts a VQR hit at 5-15s vs 15-30s for a
  standard Analyst call. Phase 4's Streamlit Tab 1 calls Analyst directly, so
  restore this block (or create a second VQR-bearing semantic view) before
  building that path.

  TO RESTORE: paste this block back into 02_create_semantic_view.sql
  immediately before the closing ');' of the CREATE SEMANTIC VIEW statement,
  and add a trailing comma to the AI_QUESTION_CATEGORIZATION line above it.
================================================================================
*/

  AI_VERIFIED_QUERIES (
    top_stores_by_revenue AS (
      QUESTION 'Which 10 stores had the highest revenue last month?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT s.store_name, SUM(d.revenue) AS total_revenue
           FROM daily_sales d
           JOIN stores s ON s.store_id = d.store_id
           WHERE d.sale_date >= DATE_TRUNC(''month'', DATEADD(''month'', -1, CURRENT_DATE()))
             AND d.sale_date < DATE_TRUNC(''month'', CURRENT_DATE())
           GROUP BY s.store_name
           ORDER BY total_revenue DESC
           LIMIT 10'
    ),
    inventory_alerts_west AS (
      QUESTION 'Show me inventory alerts for products below reorder point in the West region'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT s.store_name, p.product_name, i.units_on_hand, i.reorder_point
           FROM inventory i
           JOIN stores s ON s.store_id = i.store_id
           JOIN products p ON p.product_id = i.product_id
           WHERE s.region = ''West''
             AND i.units_on_hand < i.reorder_point
             AND i.snapshot_date = (SELECT MAX(snapshot_date) FROM inventory)
           ORDER BY (i.reorder_point - i.units_on_hand) DESC'
    ),
    target_attainment_q4 AS (
      QUESTION 'What is target attainment by region for Q4 2025?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'WITH monthly_actuals AS (
             SELECT store_id, DATE_TRUNC(''month'', sale_date) AS period_month, SUM(revenue) AS actual_revenue
             FROM daily_sales
             WHERE sale_date >= ''2025-10-01'' AND sale_date <= ''2025-12-31''
             GROUP BY store_id, DATE_TRUNC(''month'', sale_date)
           )
           SELECT
             s.region,
             SUM(ma.actual_revenue) AS actual_revenue,
             SUM(t.target_revenue) AS target_revenue,
             ROUND(SUM(ma.actual_revenue) / SUM(t.target_revenue) * 100, 1) AS attainment_pct
           FROM monthly_actuals ma
           JOIN stores s ON s.store_id = ma.store_id
           JOIN sales_targets t
             ON t.store_id = ma.store_id
            AND t.period_month = ma.period_month
           GROUP BY s.region
           ORDER BY attainment_pct DESC'
    ),
    category_wow_drop AS (
      QUESTION 'Which product categories saw the biggest week-over-week revenue drop?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'WITH weekly AS (
             SELECT
               p.category,
               DATE_TRUNC(''week'', d.sale_date) AS week_start,
               SUM(d.revenue) AS revenue
             FROM daily_sales d
             JOIN products p ON p.product_id = d.product_id
             GROUP BY p.category, DATE_TRUNC(''week'', d.sale_date)
           ),
           ranked AS (
             SELECT
               category, week_start, revenue,
               LAG(revenue) OVER (PARTITION BY category ORDER BY week_start) AS prev_week_revenue
             FROM weekly
           )
           SELECT
             category, week_start, revenue, prev_week_revenue,
             ROUND((revenue - prev_week_revenue) / prev_week_revenue * 100, 1) AS wow_change_pct
           FROM ranked
           WHERE prev_week_revenue IS NOT NULL
           ORDER BY wow_change_pct ASC
           LIMIT 10'
    ),
    sales_per_sqft AS (
      QUESTION 'Which stores have the lowest sales per square foot?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT
             s.store_name, s.sq_ft,
             SUM(d.revenue) AS total_revenue,
             ROUND(SUM(d.revenue) / s.sq_ft, 2) AS revenue_per_sqft
           FROM daily_sales d
           JOIN stores s ON s.store_id = d.store_id
           GROUP BY s.store_name, s.sq_ft
           ORDER BY revenue_per_sqft ASC
           LIMIT 10'
    ),
    staffing_vs_revenue AS (
      QUESTION 'Compare staffing hours to revenue per store this quarter'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'WITH quarterly_hours AS (
             SELECT store_id, SUM(hours_worked) AS total_labor_hours
             FROM staff_shifts
             WHERE shift_date >= DATE_TRUNC(''quarter'', CURRENT_DATE())
             GROUP BY store_id
           ),
           quarterly_revenue AS (
             SELECT store_id, SUM(revenue) AS total_revenue
             FROM daily_sales
             WHERE sale_date >= DATE_TRUNC(''quarter'', CURRENT_DATE())
             GROUP BY store_id
           )
           SELECT
             s.store_name,
             COALESCE(qh.total_labor_hours, 0) AS total_labor_hours,
             COALESCE(qr.total_revenue, 0) AS total_revenue,
             ROUND(COALESCE(qr.total_revenue, 0) / NULLIF(qh.total_labor_hours, 0), 2) AS revenue_per_labor_hour
           FROM stores s
           LEFT JOIN quarterly_hours qh ON qh.store_id = s.store_id
           LEFT JOIN quarterly_revenue qr ON qr.store_id = s.store_id
           ORDER BY revenue_per_labor_hour DESC'
    ),
    q4_regional_comparison AS (
      QUESTION 'How did Q4 2025 revenue compare across regions?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT s.region, SUM(d.revenue) AS total_revenue
           FROM daily_sales d
           JOIN stores s ON s.store_id = d.store_id
           WHERE d.sale_date >= ''2025-10-01'' AND d.sale_date <= ''2025-12-31''
           GROUP BY s.region
           ORDER BY total_revenue DESC'
    ),
    top_products_south AS (
      QUESTION 'What are the top 5 products by units sold in the South region?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT p.product_name, p.category, SUM(d.units_sold) AS total_units
           FROM daily_sales d
           JOIN products p ON p.product_id = d.product_id
           JOIN stores s ON s.store_id = d.store_id
           WHERE s.region = ''South''
           GROUP BY p.product_name, p.category
           ORDER BY total_units DESC
           LIMIT 5'
    ),
    online_penetration_by_region AS (
      QUESTION 'What percentage of revenue comes from online vs in-store sales by region?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT
             s.region,
             ROUND(SUM(CASE WHEN d.channel = ''Online'' THEN d.revenue ELSE 0 END) / SUM(d.revenue) * 100, 1) AS online_pct
           FROM daily_sales d
           JOIN stores s ON s.store_id = d.store_id
           GROUP BY s.region
           ORDER BY online_pct DESC'
    ),
    return_rate_by_category AS (
      QUESTION 'Which product categories have the highest return rate?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT
             p.category,
             COUNT(DISTINCT r.return_id) AS return_count,
             COUNT(DISTINCT d.sale_id) AS transaction_count,
             ROUND(COUNT(DISTINCT r.return_id) * 100.0 / COUNT(DISTINCT d.sale_id), 2) AS return_rate_pct
           FROM daily_sales d
           JOIN products p ON p.product_id = d.product_id
           LEFT JOIN returns r ON r.sale_id = d.sale_id
           GROUP BY p.category
           ORDER BY return_rate_pct DESC'
    ),
    labor_cost_pct_of_revenue AS (
      QUESTION 'What is our total labor cost as a percentage of revenue this quarter?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'WITH labor AS (
             SELECT SUM(hours_worked * hourly_wage) AS total_labor_cost
             FROM staff_shifts
             WHERE shift_date >= DATE_TRUNC(''quarter'', CURRENT_DATE())
           ),
           sales AS (
             SELECT SUM(revenue) AS total_revenue
             FROM daily_sales
             WHERE sale_date >= DATE_TRUNC(''quarter'', CURRENT_DATE())
           )
           SELECT
             ROUND(l.total_labor_cost, 2) AS total_labor_cost,
             ROUND(s.total_revenue, 2) AS total_revenue,
             ROUND(l.total_labor_cost / s.total_revenue * 100, 2) AS labor_cost_pct
           FROM labor l, sales s'
    ),
    supplier_lead_time_vs_stockouts AS (
      QUESTION 'Which suppliers have the longest lead times and the most inventory stockouts?'
      VERIFIED_AT 1723334400
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = data_ops_team)'
      SQL 'SELECT
             p.supplier,
             ROUND(AVG(p.lead_time_days), 1) AS avg_lead_time_days,
             COUNT(CASE WHEN i.units_on_hand < i.reorder_point THEN 1 END) AS stockout_count
           FROM inventory i
           JOIN products p ON p.product_id = i.product_id
           WHERE i.snapshot_date = (SELECT MAX(snapshot_date) FROM inventory)
           GROUP BY p.supplier
           ORDER BY avg_lead_time_days DESC'
    )
  );
