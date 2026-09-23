/*
================================================================================
  04_create_agent.sql
  Creates a Cortex Agent with cortex_analyst_text_to_sql tool.
  
  This agent wraps Cortex Analyst and routes SQL execution through the
  Interactive Warehouse (RETAIL_AI_WH). Every call to this agent generates
  spans in SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS — the foundation for
  the observability dashboard.

  ZERO-COPY REWORK (2026-08-14): repointed from RETAIL_OPS_SV (backed by the
  *_IT Interactive Tables) to RETAIL_OPS_SV_RAW (backed by RETAIL_DEMO.RAW.*
  base tables). The *_IT layer is gone -- zero-copy Interactive lets plain base
  tables attach straight to an Interactive Warehouse, so RETAIL_AI_WH now holds
  the 7 RAW tables directly.

  Note the semantic view itself is NOT attached to the warehouse -- it cannot be
  (ALTER WAREHOUSE ADD TABLES resolves table objects only, and an SV has no
  storage to cache-warm). Attaching the base tables is sufficient: the SV
  expands to SQL over them, so Analyst-generated SQL lands on the Interactive
  Warehouse automatically.

  Prerequisites:
    - 08_create_semantic_view_raw.sql (RETAIL_OPS_SV_RAW exists)
    - 09_cluster_raw_tables.sql (RAW tables clustered -- without this you lose
      pruning: 2248 MB scanned unclustered vs 54 MB clustered on the same query)
    - RETAIL_AI_WH exists with the 7 RAW tables attached

  Run on: Any warehouse (fast metadata operation).
================================================================================
*/

USE DATABASE RETAIL_DEMO;
USE SCHEMA APP;

--------------------------------------------------------------------------------
-- Create the Cortex Agent
-- - claude-haiku-4-5: fastest Anthropic tier available for orchestration
-- - Single tool: cortex_analyst_text_to_sql pointing to semantic view
-- - SQL execution routed to Interactive Warehouse for sub-second performance
--
-- LATENCY TUNING (measured, see setup/latency_baseline.json):
--   budget.tokens 16000 -> 8000
--     budget.tokens caps OUTPUT tokens only, not input/cache.
--     Measured output was 457-3698 tokens, so 8000 leaves headroom while
--     capping runaway response generation.
--   budget.seconds 30 -> 90
--     RAISED, not lowered. Budgets are stop limits, not speed controls, and an
--     expiry mid-loop yields excessive replanning with no final answer.
--     Real turns measured 10-36s, with outliers to 169s.
--   instructions trimmed: every planning step re-reads the full input context
--     before emitting a token, so instruction verbosity is paid per step.
--
-- NOT settable here: tool_choice is rejected in CREATE AGENT ("unrecognized
-- field tool_choice") - it is an agent:run REQUEST BODY field only. To force
-- deterministic tool use, send this in the REST request instead:
--   "tool_choice": {"type": "required", "name": ["RetailAnalyst"]}
--------------------------------------------------------------------------------
CREATE OR REPLACE AGENT RETAIL_DEMO.APP.RETAIL_OPS_AGENT
  COMMENT = 'Retail operations agent powered by Cortex Analyst over zero-copy Interactive base tables'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-haiku-4-5

  orchestration:
    budget:
      seconds: 90
      tokens: 8000

  instructions:
    response: "Answer concisely. State the time period. Use commas in monetary values and one decimal place for percentages."
    orchestration: "Use RetailAnalyst for every data question. Do not answer data questions without it."
    sample_questions:
      - question: "Which 10 stores had the highest revenue last month?"
      - question: "Show me inventory alerts in the West region"
      - question: "What is target attainment by region for Q4 2025?"
      - question: "Which product categories saw the biggest week-over-week revenue drop?"
      - question: "Compare staffing hours to revenue per store this quarter"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "RetailAnalyst"
        description: "Retail store performance, inventory, sales targets, staffing, and product data for 50 stores over 2 years"

  tool_resources:
    RetailAnalyst:
      semantic_view: "RETAIL_DEMO.APP.RETAIL_OPS_SV_RAW"
      execution_environment:
        type: warehouse
        warehouse: "RETAIL_AI_WH"
  $$;

--------------------------------------------------------------------------------
-- Grant access for the demo role
-- Adjust <demo_role> to your actual role name
--------------------------------------------------------------------------------

-- Required: MONITOR on the agent (for observability queries)
-- GRANT MONITOR ON AGENT RETAIL_DEMO.APP.RETAIL_OPS_AGENT TO ROLE <demo_role>;

-- Required: CORTEX_USER database role (for calling the agent API)
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <demo_role>;

-- Required: USAGE on the Interactive Warehouse (for SQL execution)
-- GRANT USAGE ON WAREHOUSE RETAIL_AI_WH TO ROLE <demo_role>;

-- Required: USAGE on the fallback warehouse (for queries > 5 seconds)
-- GRANT USAGE ON WAREHOUSE RETAIL_FALLBACK_WH TO ROLE <demo_role>;

-- Required: SELECT on the semantic view (for Cortex Analyst)
-- GRANT REFERENCES, SELECT ON SEMANTIC VIEW RETAIL_DEMO.APP.RETAIL_OPS_SV_RAW TO ROLE <demo_role>;

--------------------------------------------------------------------------------
-- VERIFICATION
-- Test the agent from Snowsight:
--   1. Navigate to AI & ML > Agents
--   2. Select RETAIL_OPS_AGENT
--   3. Enter a test question in the playground
--
-- Or test via SQL:
-- SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
--   'RETAIL_DEMO.APP.RETAIL_OPS_AGENT',
--   'Which 10 stores had the highest revenue last month?'
-- );
--
-- After testing, verify AI_OBSERVABILITY_EVENTS has data:
-- SELECT COUNT(*)
-- FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
--   'RETAIL_DEMO', 'APP', 'RETAIL_OPS_AGENT', 'CORTEX AGENT'
-- ));
-- -- Expected: > 0 (one trace per agent call, ~4 spans per trace)
--------------------------------------------------------------------------------
