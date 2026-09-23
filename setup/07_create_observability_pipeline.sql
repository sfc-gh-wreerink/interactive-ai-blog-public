/*
================================================================================
  07_create_observability_pipeline.sql
  Materializes SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS for RETAIL_OPS_AGENT
  into a native TARGET_LAG-refreshing Interactive Table, queryable at
  interactive speed from RETAIL_AI_WH -- the same warehouse that runs the
  retail app's own SQL. This is the "same infrastructure powers the app and
  its own observability" thesis, built for real.

  SUPERSEDES the Task + INSERT OVERWRITE design in
  .snowflake/cortex/plans/phase3-observability-pipeline.plan.md. That plan
  predicted native TARGET_LAG refresh could not source from this table and
  recommended a scheduled Task instead. That prediction was WRONG for a
  direct base-table SELECT (it is correct only for the GET_AI_OBSERVABILITY_
  EVENTS() table-function path, which really can't back a TARGET_LAG table --
  UDTFs are lateral-join-only in dynamic table refresh, and this function
  takes literal args with no row to correlate against).

  Verified live on 2026-08-13:
    - CREATE INTERACTIVE TABLE ... TARGET_LAG = '1 hour' ... AS SELECT
      FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS succeeded on the first try.
    - Resolved DDL shows refresh_mode = 'AUTO', last_completed_refresh_state
      = SUCCEEDED, populated 1,984 rows / 151 traces on creation -- matching
      the direct-table query's row count exactly.
    - No Task needed. No INSERT OVERWRITE needed. Native auto-refresh works.

  ACCESS CONTROL TRADE-OFF (accepted deliberately, not overlooked):
  This queries SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS directly, which per
  Snowflake's docs is "for limited admin use" -- it requires ACCOUNTADMIN or
  the AI_OBSERVABILITY_READER application role, and returns account-wide,
  unscoped events. The WHERE clause below does by hand what
  GET_AI_OBSERVABILITY_EVENTS('RETAIL_DEMO','APP','RETAIL_OPS_AGENT',
  'CORTEX AGENT') would do automatically with built-in MONITOR-privilege
  enforcement. This table is scoped correctly for THIS demo's single agent,
  but that scoping is manual and would need re-verifying for a multi-agent
  account.

  Prerequisites: RETAIL_OPS_AGENT exists and has emitted traces (Phase 1/2).
  Run on: any role with ACCOUNTADMIN or AI_OBSERVABILITY_READER.
================================================================================
*/

USE DATABASE RETAIL_DEMO;
USE SCHEMA APP;

--------------------------------------------------------------------------------
-- AGENT_TRACES_IT
--
-- Clustering choice (3 columns, in this order):
--   1. event_date  -- every dashboard query so far filters or orders on
--                      recency ("last 24h", "last 3 days", "top 10 most
--                      recent traces"). Date-first matches the same pattern
--                      used for the retail Interactive Tables.
--   2. span_name    -- nearly every query in this session's testing filtered
--                      or grouped on span type (SqlExecution_SystemSQL vs
--                      ReasoningAgentStepPlanning-N vs Agent, etc.) to
--                      separate SQL-execution spans from planning spans from
--                      turn-level spans. Highly selective, reused constantly.
--   3. trace_id     -- the join key for every per-turn aggregation (SQL call
--                      counts, planning-step counts, turn duration). Third
--                      because most queries filter on date+span_name first,
--                      then group by trace_id -- not filter by it directly.
--------------------------------------------------------------------------------
CREATE OR REPLACE INTERACTIVE TABLE RETAIL_DEMO.APP.AGENT_TRACES_IT
  CLUSTER BY (event_date, span_name, trace_id)
  TARGET_LAG = '1 hour'
  WAREHOUSE = RETAIL_REFRESH_WH  -- pre-existing standard warehouse, purpose-built for Interactive Table refresh
  COMMENT = 'Flattened AI_OBSERVABILITY_EVENTS for RETAIL_OPS_AGENT, natively refreshed hourly, queried via RETAIL_AI_WH'
AS
SELECT
  RECORD_ATTRIBUTES:"ai.observability.record_id"::STRING AS record_id,
  TRACE:trace_id::STRING AS trace_id,
  RECORD:name::STRING AS span_name,
  RECORD_TYPE::STRING AS record_type,
  START_TIMESTAMP AS start_ts,
  TIMESTAMP AS end_ts,
  DATE(TIMESTAMP) AS event_date,
  -- No native DURATION_MS column on this event schema -- confirmed repeatedly
  -- this session. Always derive it, never assume it exists.
  DATEDIFF('millisecond', START_TIMESTAMP, TIMESTAMP) AS duration_ms,
  RESOURCE_ATTRIBUTES:"snow.user.name"::STRING AS user_name,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.thread_id"::STRING AS thread_id,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.message_id"::STRING AS message_id,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.parent_message_id"::STRING AS parent_message_id,
  RECORD_ATTRIBUTES:"snow.ai.observability.object.name"::STRING AS agent_name,
  RECORD_ATTRIBUTES:"snow.ai.observability.object.type"::STRING AS agent_type,
  RECORD_ATTRIBUTES:"snow.ai.observability.database.name"::STRING AS database_name,
  -- question/response/status -- all flat on RECORD_ATTRIBUTES for the
  -- AgentV2RequestResponseInfo span specifically (NULL on all other spans).
  -- Confirmed live 2026-08-13: no VALUE parsing needed for these. Added in a
  -- second CREATE OR REPLACE after the table's initial creation -- see the
  -- ALTER WAREHOUSE gotcha comment below for what that second pass broke.
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.messages"::STRING AS question,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.response"::STRING AS response_text,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.status"::STRING AS status,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.status.description"::STRING AS status_description,
  --------------------------------------------------------------------------
  -- SQL execution tool fields (populated on SqlExecution_SystemSQL and
  -- SystemExecuteSQLTool_system_execute_sql spans only).
  --
  -- IMPORTANT CORRECTION (2026-08-13): query_id is FLAT in RECORD_ATTRIBUTES,
  -- not buried inside VALUE. An earlier note in this project claimed it lived
  -- in VALUE on response.tool_result content and "needed more testing before
  -- flattening" -- that was wrong. It is right here, 716 occurrences, and it
  -- joins cleanly to ACCOUNT_USAGE.QUERY_HISTORY (verified: 358 matched
  -- queries, 58.3% partition pruning, 11.2 GB scanned).
  --
  -- sql_status is the find that matters most: 234 of 718 SQL calls report
  -- ERROR (32.6%) across 62 of 151 turns, while the TURN-level status above
  -- is SUCCESS on all 151. The agent retries and self-corrects, so turn-level
  -- success hides a third of its SQL failing. Almost all are error code
  -- 000904 'invalid identifier' -- hallucinated column names.
  --------------------------------------------------------------------------
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.status"::STRING AS sql_status,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.status.description"::STRING AS sql_error,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.query_id"::STRING AS query_id,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.final_sql"::STRING AS final_sql,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.warehouse"::STRING AS sql_warehouse,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.result.num_rows"::STRING AS NUMBER) AS sql_num_rows,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.verified_query_used"::STRING AS verified_query_used,
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.validation_error.0.message"::STRING AS validation_error,
  --------------------------------------------------------------------------
  -- Planning / LLM fields (ReasoningAgentStepPlanning-N spans).
  -- Token counts are real and substantial: 11,093,086 total across 647
  -- planning spans, of which 8,071,829 are cache reads (73% of input).
  --------------------------------------------------------------------------
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.model"::STRING AS model,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.step_number"::STRING AS NUMBER) AS planning_step,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.total"::STRING AS NUMBER) AS tokens_total,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.input"::STRING AS NUMBER) AS tokens_input,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.output"::STRING AS NUMBER) AS tokens_output,
  TRY_CAST(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.cache_read_input"::STRING AS NUMBER) AS tokens_cache_read,
  -- Other tools
  RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.chart_generation.status"::STRING AS chart_status
FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
WHERE RECORD_ATTRIBUTES:"snow.ai.observability.database.name" = 'RETAIL_DEMO'
  AND RECORD_ATTRIBUTES:"snow.ai.observability.object.name" = 'RETAIL_OPS_AGENT'
  AND RECORD_ATTRIBUTES:"snow.ai.observability.object.type" = 'Cortex Agent';

--------------------------------------------------------------------------------
-- Attach to the SAME Interactive Warehouse that runs the retail app's own
-- SQL. Deliberate choice, not convenience: this is the blog's actual thesis
-- (one Interactive Warehouse powers both the AI app and its observability),
-- not just a spare warehouse to test with.
--
-- GOTCHA (found live, 2026-08-13): CREATE OR REPLACE INTERACTIVE TABLE drops
-- and recreates the table object -- it silently severs this attachment.
-- Confirmed via SHOW WAREHOUSES: after re-running the CREATE OR REPLACE above
-- to add the question/response/status columns, AGENT_TRACES_IT had vanished
-- from RETAIL_AI_WH's tables list with no error or warning. Re-run this
-- ALTER WAREHOUSE statement after ANY CREATE OR REPLACE on this table.
--------------------------------------------------------------------------------
ALTER WAREHOUSE RETAIL_AI_WH ADD TABLES (
  RETAIL_DEMO.APP.AGENT_TRACES_IT,
  SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
);

--------------------------------------------------------------------------------
-- VERIFICATION
--------------------------------------------------------------------------------
-- SHOW INTERACTIVE TABLES LIKE 'AGENT_TRACES_IT' IN SCHEMA RETAIL_DEMO.APP;
-- SELECT COUNT(*) AS row_ct, COUNT(DISTINCT trace_id) AS traces FROM RETAIL_DEMO.APP.AGENT_TRACES_IT;
--   Verified 2026-08-13: 1,984 rows / 151 traces, matching direct-table access exactly.
--------------------------------------------------------------------------------
