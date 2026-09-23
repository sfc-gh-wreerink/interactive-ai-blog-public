/*
================================================================================
  10_create_observability_mv.sql
  Replaces AGENT_TRACES_IT (Interactive Table, TARGET_LAG = '1 hour') with a
  MATERIALIZED VIEW over SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS, carrying the
  same flattening transforms and the same clustering key.

  SUPERSEDES setup/07_create_observability_pipeline.sql.

  WHY A MATERIALIZED VIEW BEATS THE INTERACTIVE TABLE HERE
  Verified live 2026-08-14, immediately after a 10-call agent run:
    AGENT_TRACES_MV        2119 rows / 164 traces   <- matches base table exactly
    AGENT_TRACES_IT        2011 rows / 154 traces   <- 10 traces STALE
    base table (filtered)  2119 rows / 164 traces
  The Interactive Table returned ZERO rows for 2026-08-14 even when queried with
  ORDER BY event_date DESC -- the whole day was missing, because TARGET_LAG had
  not fired. MVs are maintained automatically by Snowflake and are ALWAYS
  current: if a micro-partition is stale, Snowflake reads through to the base
  table rather than serving stale data. For an observability dashboard, where the
  entire point is seeing what the agent just did, a 1-hour lag is a defect.

  It also drops a dependency: no TARGET_LAG means RETAIL_REFRESH_WH is no longer
  needed by this object.

  MV LIMITATIONS -- all satisfied by this definition, but check before editing:
    - single table only, no joins           -> OK, one base table
    - no window functions, no HAVING/ORDER BY/LIMIT, no nested subqueries
    - no UDFs
    - functions must be DETERMINISTIC       -> no CURRENT_TIMESTAMP etc. The
      WHERE clause uses literal equality only, deliberately. Do NOT add a
      "last N days" filter here -- CURRENT_DATE is non-deterministic and will be
      rejected. Filter by date in the QUERY, not in the MV.
    - CLUSTER BY requires an explicit column_list  -> hence the 34-column list
    - avoid SELECT *: new base-table columns are NOT picked up automatically
  Docs: https://docs.snowflake.com/en/user-guide/views-materialized

  ATTACHING TO THE INTERACTIVE WAREHOUSE
  A plain MV CAN be attached with ALTER WAREHOUSE ... ADD TABLES (verified), and
  queries against it then run on the Interactive Warehouse. But measured on
  RETAIL_AI_WH, warm, same query:
    AGENT_TRACES_IT   60 ms total /  11 ms exec / 0.76 MB
    AGENT_TRACES_MV  367 ms total / 107 ms exec / 2.26 MB
  So attaching a plain MV makes it QUERYABLE on an Interactive Warehouse but does
  not appear to give it interactive-grade caching -- ~7-10x slower execution,
  consistent across runs. At 2119 rows the absolute numbers are trivial; at scale
  they would not be.

  If you want both freshness AND interactive-grade caching, use
  CREATE INTERACTIVE MATERIALIZED VIEW instead and attach BOTH the MV and its
  base table. Note the docs say an interactive MV "must be based on a single
  interactive table" and "can't be created on a standard table" -- but under
  zero-copy, CREATE INTERACTIVE MATERIALIZED VIEW over the plain
  SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS base table SUCCEEDED on 2026-08-14.
  That path is unmeasured; benchmark it before relying on it.

  GOTCHA: CREATE cannot run on an Interactive Warehouse at all --
  "Cannot run statement type 'CREATE_TABLE_AS_SELECT' on an interactive
  warehouse." Use a standard warehouse for this file.

  Run on: a STANDARD warehouse, as ACCOUNTADMIN or AI_OBSERVABILITY_READER.
================================================================================
*/

USE DATABASE RETAIL_DEMO;
USE SCHEMA APP;

--------------------------------------------------------------------------------
-- Clustering matches the Interactive Table's key exactly, and for the same
-- reasons (see setup/07 for the full rationale):
--   event_date -- every dashboard query filters or orders on recency
--   span_name  -- highly selective, separates SQL spans from planning spans
--   trace_id   -- the per-turn aggregation join key
--------------------------------------------------------------------------------
CREATE OR REPLACE MATERIALIZED VIEW RETAIL_DEMO.APP.AGENT_TRACES_MV
  (
    record_id, trace_id, span_name, record_type, start_ts, end_ts, event_date,
    duration_ms, user_name, thread_id, message_id, parent_message_id,
    agent_name, agent_type, database_name,
    question, response_text, status, status_description,
    sql_status, sql_error, query_id, final_sql, sql_warehouse, sql_num_rows,
    verified_query_used, validation_error,
    model, planning_step, tokens_total, tokens_input, tokens_output, tokens_cache_read,
    chart_status
  )
  CLUSTER BY (event_date, span_name, trace_id)
  COMMENT = 'Flattened AI_OBSERVABILITY_EVENTS for RETAIL_OPS_AGENT. Always-current MV; replaces AGENT_TRACES_IT and its 1-hour TARGET_LAG.'
AS SELECT
  RECORD_ATTRIBUTES:"ai.observability.record_id"::STRING,
  TRACE:trace_id::STRING,
  RECORD:name::STRING,
  RECORD_TYPE::STRING,
  START_TIMESTAMP,
  TIMESTAMP,
  DATE(TIMESTAMP),
  -- No native DURATION_MS on this event schema. Always derive it.
  DATEDIFF('millisecond', START_TIMESTAMP, TIMESTAMP),
  RESOURCE_ATTRIBUTES:"snow.user.name"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.thread_id"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.message_id"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.parent_message_id"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.object.name"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.object.type"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.database.name"::STRING,
  -- question/response/status are flat on RECORD_ATTRIBUTES for the
  -- AgentV2RequestResponseInfo span only (NULL on all other spans).
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.messages"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.response"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.status"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.status.description"::STRING,
  -- SQL execution tool fields. sql_status is the one that matters: turn-level
  -- status hides SQL failures because the agent retries and self-corrects.
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.status"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.status.description"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.query_id"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.final_sql"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.warehouse"::STRING,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.result.num_rows"::STRING AS NUMBER),
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.verified_query_used"::STRING,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.validation_error.0.message"::STRING,
  -- Planning / LLM fields (ReasoningAgentStepPlanning-N spans)
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.model"::STRING,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.step_number"::STRING AS NUMBER),
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.total"::STRING AS NUMBER),
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.input"::STRING AS NUMBER),
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.output"::STRING AS NUMBER),
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.cache_read_input"::STRING AS NUMBER),
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.chart_generation.status"::STRING
FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
WHERE RECORD_ATTRIBUTES:"snow.ai.observability.database.name" = 'RETAIL_DEMO'
  AND RECORD_ATTRIBUTES:"snow.ai.observability.object.name" = 'RETAIL_OPS_AGENT'
  AND RECORD_ATTRIBUTES:"snow.ai.observability.object.type" = 'Cortex Agent';

--------------------------------------------------------------------------------
-- Attach to the Interactive Warehouse that runs the app's own SQL.
-- Unlike CREATE OR REPLACE INTERACTIVE TABLE, this does not need re-running
-- after every redefinition -- but verify with SHOW WAREHOUSES after any
-- CREATE OR REPLACE on the MV, because that does drop and recreate the object.
--------------------------------------------------------------------------------
ALTER WAREHOUSE RETAIL_AI_WH ADD TABLES (RETAIL_DEMO.APP.AGENT_TRACES_MV);

--------------------------------------------------------------------------------
-- VERIFICATION
--------------------------------------------------------------------------------
-- Freshness vs the base table -- these must match exactly, with no lag:
-- SELECT 'mv' src, COUNT(*) n, COUNT(DISTINCT trace_id) t FROM RETAIL_DEMO.APP.AGENT_TRACES_MV
-- UNION ALL SELECT 'base', COUNT(*), COUNT(DISTINCT TRACE:trace_id::STRING)
-- FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
-- WHERE RECORD_ATTRIBUTES:"snow.ai.observability.database.name" = 'RETAIL_DEMO'
--   AND RECORD_ATTRIBUTES:"snow.ai.observability.object.name" = 'RETAIL_OPS_AGENT'
--   AND RECORD_ATTRIBUTES:"snow.ai.observability.object.type" = 'Cortex Agent';
--
-- Maintenance lag and validity:
-- SHOW MATERIALIZED VIEWS LIKE 'AGENT_TRACES_MV' IN SCHEMA RETAIL_DEMO.APP;
--   -> check BEHIND_BY, REFRESHED_ON, INVALID, INVALID_REASON
--
-- Maintenance cost (MVs consume serverless credits on every base-table change;
-- AI_OBSERVABILITY_EVENTS grows with every agent call, so this is not free):
-- SELECT TO_DATE(start_time) d, table_name, SUM(credits_used) c
-- FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
-- WHERE table_name = 'AGENT_TRACES_MV' GROUP BY 1,2 ORDER BY 1 DESC;
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- CLEANUP once the dashboard is repointed at AGENT_TRACES_MV
-- (app/observability_queries.py still references AGENT_TRACES_IT)
--------------------------------------------------------------------------------
-- ALTER WAREHOUSE RETAIL_AI_WH DROP TABLES (RETAIL_DEMO.APP.AGENT_TRACES_IT);
-- DROP TABLE RETAIL_DEMO.APP.AGENT_TRACES_IT;
