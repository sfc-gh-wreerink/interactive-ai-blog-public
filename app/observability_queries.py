"""
Observability dashboard queries against RETAIL_DEMO.APP.AGENT_TRACES_IT,
run through RETAIL_AI_WH (Interactive Warehouse) with real bind variables.

UPDATE (2026-08-13): question/response/status ARE now flattened -- turned out
NOT to need VALUE parsing at all. They live directly in RECORD_ATTRIBUTES on
the AgentV2RequestResponseInfo span specifically:
  snow.ai.observability.agent.messages    -> current turn's question
  snow.ai.observability.agent.response    -> assistant's response text
  snow.ai.observability.agent.status      -> 'SUCCESS' / (presumably 'FAILURE' etc.)
  snow.ai.observability.agent.status.description -> e.g. 'SLOW' -- a built-in
    slow-turn flag from Snowflake's own instrumentation, worth surfacing.
This replaces the earlier assumption that top_questions/success_rate needed
VALUE flattening -- they didn't; RECORD_ATTRIBUTES had it all along.

query_id IS flattened, and the QUERY_HISTORY join works. CORRECTION
(2026-08-13): an earlier version of this docstring claimed query_id "lives
inside VALUE on response.tool_result content and needs more testing before
flattening." That was wrong. It is flat in RECORD_ATTRIBUTES at
snow.ai.observability.agent.tool.sql_execution.query_id (716 occurrences) and
joins cleanly to ACCOUNT_USAGE.QUERY_HISTORY -- verified 358 matched queries,
58.3% partition pruning, 11.2 GB scanned. See warehouse_truth().

All queries use real bind variables (cur.execute(sql, params)), not string
interpolation. Verified this session that bind variables don't measurably
change Snowflake's own compile time (that earlier claim was a test-ordering
artifact, not a bind-variable effect) -- they're used here for correctness
and injection-safety, not as a performance claim.

GOTCHA (found live in Streamlit-in-Snowflake, 2026-08-13): use `?` (qmark),
not `%s` (pyformat), for placeholders. Snowpark's Session sets the connector's
module-level `paramstyle` global to 'qmark' internally when it establishes
its own connection -- and paramstyle is process-global, not per-connection,
so it silently overrides whatever this module would otherwise default to.
With `%s` placeholders under a forced 'qmark' paramstyle, the connector never
substitutes them: `%s` gets forwarded to Snowflake literally, which fails
compilation on the bare `%` character. Setting `sc.paramstyle = "qmark"`
explicitly here keeps local dev (plain snowflake.connector, no Snowpark
session) and SiS (Snowpark-forced qmark) consistent -- both use `?`.
"""

import os
import tomllib
from datetime import date, timedelta

import snowflake.connector as sc

sc.paramstyle = "qmark"

CONNECTION = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "default")
WAREHOUSE = "RETAIL_AI_WH"
# Standard warehouse, needed only for ACCOUNT_USAGE lookups -- an Interactive
# Warehouse cannot query the ACCOUNT_USAGE secure views (see warehouse_truth).
STANDARD_WAREHOUSE = "RETAIL_REFRESH_WH"
TABLE = "RETAIL_DEMO.APP.AGENT_TRACES_IT"


def _connect():
    con = sc.connect(connection_name=CONNECTION)
    con.cursor().execute(f"USE WAREHOUSE {WAREHOUSE}")
    return con


def turns_per_day(con, since_days: int = 7) -> list[tuple]:
    """Turns (distinct traces) per day over the last N days."""
    sql = f"""
        SELECT event_date, COUNT(DISTINCT trace_id) AS turns
        FROM {TABLE}
        WHERE event_date >= ?
        GROUP BY event_date
        ORDER BY event_date
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days),))
    return cur.fetchall()


def sql_fanout_distribution(con, since_days: int = 7) -> list[tuple]:
    """SQL calls per trace -- the actual burst/fan-out metric, not a guess."""
    sql = f"""
        WITH per_trace AS (
            SELECT trace_id,
                   COUNT(CASE WHEN span_name = ? THEN 1 END) AS sql_calls
            FROM {TABLE}
            WHERE event_date >= ?
            GROUP BY trace_id
        )
        SELECT sql_calls, COUNT(*) AS traces
        FROM per_trace
        GROUP BY sql_calls
        ORDER BY sql_calls
    """
    cur = con.cursor()
    cur.execute(sql, ("SqlExecution_SystemSQL", date.today() - timedelta(days=since_days)))
    return cur.fetchall()


def turn_duration_percentiles(con, since_days: int = 7) -> tuple:
    """p50/p95/max turn duration in seconds, from the top-level 'Agent' span."""
    sql = f"""
        SELECT
            ROUND(MEDIAN(duration_ms) / 1000.0, 1) AS p50_s,
            ROUND(APPROX_PERCENTILE(duration_ms, 0.95) / 1000.0, 1) AS p95_s,
            ROUND(MAX(duration_ms) / 1000.0, 1) AS max_s,
            COUNT(*) AS turns
        FROM {TABLE}
        WHERE span_name = ? AND event_date >= ?
    """
    cur = con.cursor()
    cur.execute(sql, ("Agent", date.today() - timedelta(days=since_days)))
    return cur.fetchone()


def planning_steps_distribution(con, since_days: int = 7) -> list[tuple]:
    """Planning-step count per trace -- proxy for orchestration cost per turn."""
    sql = f"""
        WITH per_trace AS (
            SELECT trace_id,
                   COUNT(CASE WHEN span_name LIKE ? THEN 1 END) AS planning_steps
            FROM {TABLE}
            WHERE event_date >= ?
            GROUP BY trace_id
        )
        SELECT planning_steps, COUNT(*) AS traces
        FROM per_trace
        GROUP BY planning_steps
        ORDER BY planning_steps
    """
    cur = con.cursor()
    cur.execute(sql, ("ReasoningAgentStepPlanning%", date.today() - timedelta(days=since_days)))
    return cur.fetchall()


def multi_turn_threads(con, min_turns: int = 2) -> list[tuple]:
    """Threads with 2+ turns, oldest to newest -- the multi-turn conversations.

    Excludes thread_id = '0': confirmed via live query (99 spans / 99 traces,
    one artifact span per single-shot trace) that '0' is the literal sentinel
    some spans report for non-threaded turns -- matching the REST API's own
    convention that thread_id=0 means "no thread" (POSTing thread_id=0
    explicitly returns "399509 Thread 0 does not exist"). Not a real thread.
    """
    sql = f"""
        SELECT thread_id, COUNT(DISTINCT trace_id) AS turns,
               MIN(start_ts) AS thread_start, MAX(end_ts) AS thread_end
        FROM {TABLE}
        WHERE thread_id IS NOT NULL AND thread_id != ?
        GROUP BY thread_id
        HAVING COUNT(DISTINCT trace_id) >= ?
        ORDER BY thread_start DESC
    """
    cur = con.cursor()
    cur.execute(sql, ("0", min_turns))
    return cur.fetchall()


def span_breakdown(con, target_date: date | None = None) -> list[tuple]:
    """Span-type counts for a given day -- what the agent actually spends time on."""
    sql = f"""
        SELECT span_name, COUNT(*) AS ct, COUNT(DISTINCT trace_id) AS traces
        FROM {TABLE}
        WHERE event_date = ?
        GROUP BY span_name
        ORDER BY ct DESC
    """
    cur = con.cursor()
    cur.execute(sql, (target_date or date.today(),))
    return cur.fetchall()


def top_questions(con, since_days: int = 7, limit: int = 10) -> list[tuple]:
    """Most-asked questions, by exact text match. AgentV2RequestResponseInfo only."""
    sql = f"""
        SELECT question, COUNT(*) AS ct
        FROM {TABLE}
        WHERE span_name = 'AgentV2RequestResponseInfo'
          AND question IS NOT NULL
          AND event_date >= ?
        GROUP BY question
        ORDER BY ct DESC
        LIMIT ?
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days), limit))
    return cur.fetchall()


def success_rate(con, since_days: int = 7) -> tuple:
    """Success rate and the 'SLOW' flag rate -- both are Snowflake's own
    instrumentation (snow.ai.observability.agent.status[.description]),
    not something we compute from span completeness."""
    sql = f"""
        SELECT
            COUNT(*) AS total_turns,
            COUNT(CASE WHEN status = 'SUCCESS' THEN 1 END) AS succeeded,
            COUNT(CASE WHEN status_description = 'SLOW' THEN 1 END) AS flagged_slow,
            ROUND(COUNT(CASE WHEN status = 'SUCCESS' THEN 1 END) * 100.0 / NULLIF(COUNT(*), 0), 1) AS success_pct
        FROM {TABLE}
        WHERE span_name = 'AgentV2RequestResponseInfo'
          AND event_date >= ?
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days),))
    return cur.fetchone()


def failed_turns(con, since_days: int = 7) -> list[tuple]:
    """Turns where status != SUCCESS -- empty today (no failures captured yet),
    but the query is real and will populate correctly if/when they occur."""
    sql = f"""
        SELECT trace_id, question, status, start_ts
        FROM {TABLE}
        WHERE span_name = 'AgentV2RequestResponseInfo'
          AND status != ?
          AND event_date >= ?
        ORDER BY start_ts DESC
    """
    cur = con.cursor()
    cur.execute(sql, ("SUCCESS", date.today() - timedelta(days=since_days)))
    return cur.fetchall()


def latency_breakdown(con, since_days: int = 7) -> tuple:
    """Median split of turn duration: time spent actually executing SQL
    (sum of SqlExecution_SystemSQL span durations per trace) vs. everything
    else (LLM planning/generation). Self-contained on AGENT_TRACES_IT -- no
    query_id/QUERY_HISTORY join needed, since span durations are already
    flattened. This is the compile/exec-dominance point made concrete: most
    of a turn's wall clock is orchestration, not the warehouse."""
    sql = f"""
        WITH agent AS (
            SELECT trace_id, duration_ms AS agent_ms
            FROM {TABLE}
            WHERE span_name = ? AND event_date >= ?
        ), sql_exec AS (
            SELECT trace_id, SUM(duration_ms) AS sql_ms
            FROM {TABLE}
            WHERE span_name = ? AND event_date >= ?
            GROUP BY trace_id
        )
        SELECT
            ROUND(MEDIAN(agent.agent_ms), 0) AS median_agent_ms,
            ROUND(MEDIAN(COALESCE(sql_exec.sql_ms, 0)), 0) AS median_sql_ms,
            ROUND(MEDIAN(agent.agent_ms - COALESCE(sql_exec.sql_ms, 0)), 0) AS median_other_ms,
            COUNT(*) AS turns
        FROM agent LEFT JOIN sql_exec ON agent.trace_id = sql_exec.trace_id
    """
    cur = con.cursor()
    cutoff = date.today() - timedelta(days=since_days)
    cur.execute(sql, ("Agent", cutoff, "SqlExecution_SystemSQL", cutoff))
    return cur.fetchone()


def thread_messages(con, thread_id: str) -> list[tuple]:
    """Ordered turns for one thread -- question, response, status, start_ts.
    Powers the conversation drill-down once a thread_id is picked from
    multi_turn_threads() (which already excludes the '0' sentinel)."""
    sql = f"""
        SELECT start_ts, question, response_text, status, status_description
        FROM {TABLE}
        WHERE span_name = 'AgentV2RequestResponseInfo' AND thread_id = ?
        ORDER BY start_ts
    """
    cur = con.cursor()
    cur.execute(sql, (thread_id,))
    return cur.fetchall()


def table_refresh_status(con) -> dict:
    """Last completed / next scheduled refresh for AGENT_TRACES_IT, for the
    dashboard's staleness caption -- TARGET_LAG is 1 hour, so this is not a
    live feed of the reader's own activity."""
    cur = con.cursor()
    cur.execute("SHOW INTERACTIVE TABLES LIKE 'AGENT_TRACES_IT' IN SCHEMA RETAIL_DEMO.APP")
    row = cur.fetchone()
    if not row:
        return {}
    cols = [c[0] for c in cur.description]
    return dict(zip(cols, row))


# ---------------------------------------------------------------------------
# Reliability: the headline finding.
#
# Turn-level status is SUCCESS on 151/151 turns. SQL-level status is ERROR on
# roughly a third of SQL calls. The agent retries and self-corrects, so a
# turn-level success rate of 100% conceals it. Showing both side by side is
# the whole point.
#
# COUNTING GOTCHA (found 2026-08-13): every SQL call emits TWO spans that both
# carry the sql_execution.* attributes -- SystemExecuteSQLTool_system_execute_sql
# (the tool invocation) and SqlExecution_SystemSQL (the execution itself).
# Counting rows WHERE sql_status IS NOT NULL therefore double-counts every
# statement. An earlier version of these queries reported "718 SQL calls, 234
# errors"; the real figures are ~361 and ~116. The RATE was unaffected (both
# numerator and denominator doubled) but the absolute counts were wrong.
# Every query below pins span_name = 'SqlExecution_SystemSQL' -- one row per
# executed statement, matching sql_fanout_distribution().
# ---------------------------------------------------------------------------

SQL_SPAN = "SqlExecution_SystemSQL"


def sql_reliability(con, since_days: int = 7) -> dict:
    """Turn-level vs SQL-level success, side by side."""
    cutoff = date.today() - timedelta(days=since_days)
    cur = con.cursor()

    cur.execute(
        f"""
        SELECT sql_status, COUNT(*) AS calls, COUNT(DISTINCT trace_id) AS traces
        FROM {TABLE}
        WHERE span_name = ? AND sql_status IS NOT NULL AND event_date >= ?
        GROUP BY sql_status
        """,
        (SQL_SPAN, cutoff),
    )
    by_status = {r[0]: {"calls": r[1], "traces": r[2]} for r in cur.fetchall()}

    cur.execute(
        f"""
        SELECT
            COUNT(DISTINCT trace_id) AS total_turns,
            COUNT(DISTINCT CASE WHEN sql_status = 'ERROR' THEN trace_id END) AS turns_with_error
        FROM {TABLE}
        WHERE event_date >= ?
        """,
        (cutoff,),
    )
    total_turns, turns_with_error = cur.fetchone()

    ok = by_status.get("SUCCESS", {}).get("calls", 0)
    err = by_status.get("ERROR", {}).get("calls", 0)
    total_calls = ok + err
    return {
        "sql_calls": total_calls,
        "sql_ok": ok,
        "sql_err": err,
        "sql_success_pct": round(ok * 100.0 / total_calls, 1) if total_calls else None,
        "total_turns": total_turns,
        "turns_with_error": turns_with_error,
        "turns_with_error_pct": round(turns_with_error * 100.0 / total_turns, 1) if total_turns else None,
    }


def hallucinated_columns(con, since_days: int = 7, limit: int = 15) -> list[tuple]:
    """Column names the agent invented, parsed out of 'invalid identifier'
    errors. Each one is an actionable semantic-model gap, not random noise."""
    sql = f"""
        SELECT
            REGEXP_SUBSTR(sql_error, 'invalid identifier ''([^'']+)''', 1, 1, 'e', 1) AS bad_identifier,
            COUNT(*) AS occurrences,
            COUNT(DISTINCT trace_id) AS turns_affected
        FROM {TABLE}
        WHERE span_name = ?
          AND sql_status = 'ERROR'
          AND sql_error ILIKE '%invalid identifier%'
          AND event_date >= ?
        GROUP BY 1
        HAVING bad_identifier IS NOT NULL
        ORDER BY occurrences DESC
        LIMIT ?
    """
    cur = con.cursor()
    cur.execute(sql, (SQL_SPAN, date.today() - timedelta(days=since_days), limit))
    return cur.fetchall()


def error_taxonomy(con, since_days: int = 7) -> list[tuple]:
    """SQL errors grouped by Snowflake error code."""
    sql = f"""
        SELECT
            COALESCE(REGEXP_SUBSTR(sql_error, 'error code (\\\\d+)', 1, 1, 'e', 1), 'other') AS error_code,
            COUNT(*) AS occurrences,
            COUNT(DISTINCT trace_id) AS turns_affected
        FROM {TABLE}
        WHERE span_name = ? AND sql_status = 'ERROR' AND event_date >= ?
        GROUP BY 1
        ORDER BY occurrences DESC
    """
    cur = con.cursor()
    cur.execute(sql, (SQL_SPAN, date.today() - timedelta(days=since_days)))
    return cur.fetchall()


def self_correction(con, since_days: int = 7) -> list[tuple]:
    """Per-turn retry pattern: how many SQL calls failed before the turn
    ultimately succeeded. Shows the recovery the turn-level status hides."""
    sql = f"""
        WITH per_trace AS (
            SELECT
                trace_id,
                COUNT(CASE WHEN sql_status = 'ERROR' THEN 1 END) AS failures,
                COUNT(CASE WHEN sql_status = 'SUCCESS' THEN 1 END) AS successes
            FROM {TABLE}
            WHERE span_name = ? AND sql_status IS NOT NULL AND event_date >= ?
            GROUP BY trace_id
        )
        SELECT
            failures,
            COUNT(*) AS turns,
            COUNT(CASE WHEN successes > 0 THEN 1 END) AS recovered
        FROM per_trace
        GROUP BY failures
        ORDER BY failures
    """
    cur = con.cursor()
    cur.execute(sql, (SQL_SPAN, date.today() - timedelta(days=since_days)))
    return cur.fetchall()


# ---------------------------------------------------------------------------
# Cost / tokens
# ---------------------------------------------------------------------------


def token_economics(con, since_days: int = 7) -> tuple:
    """Total/input/output/cache-read tokens plus per-turn averages. Cache
    reads were 73% of input on the measured dataset, which is the interesting
    part -- most of the input is being served from cache, not reprocessed."""
    sql = f"""
        SELECT
            SUM(tokens_total) AS total_tokens,
            SUM(tokens_input) AS input_tokens,
            SUM(tokens_output) AS output_tokens,
            SUM(tokens_cache_read) AS cache_read_tokens,
            ROUND(SUM(tokens_cache_read) * 100.0 / NULLIF(SUM(tokens_input), 0), 1) AS cache_pct,
            COUNT(DISTINCT trace_id) AS turns,
            ROUND(SUM(tokens_total) / NULLIF(COUNT(DISTINCT trace_id), 0), 0) AS tokens_per_turn,
            MAX(tokens_total) AS max_span_tokens
        FROM {TABLE}
        WHERE tokens_total IS NOT NULL AND event_date >= ?
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days),))
    return cur.fetchone()


def tokens_per_turn(con, since_days: int = 7, limit: int = 15) -> list[tuple]:
    """Most expensive turns by token spend, with the question that caused it."""
    sql = f"""
        WITH per_trace AS (
            SELECT trace_id, SUM(tokens_total) AS tokens, SUM(tokens_output) AS out_tokens
            FROM {TABLE}
            WHERE tokens_total IS NOT NULL AND event_date >= ?
            GROUP BY trace_id
        ), questions AS (
            SELECT trace_id, MAX(question) AS question
            FROM {TABLE}
            WHERE span_name = 'AgentV2RequestResponseInfo' AND event_date >= ?
            GROUP BY trace_id
        )
        SELECT p.tokens, p.out_tokens, LEFT(COALESCE(q.question, '(unknown)'), 90) AS question
        FROM per_trace p LEFT JOIN questions q ON p.trace_id = q.trace_id
        ORDER BY p.tokens DESC
        LIMIT ?
    """
    cur = con.cursor()
    cutoff = date.today() - timedelta(days=since_days)
    cur.execute(sql, (cutoff, cutoff, limit))
    return cur.fetchall()


# ---------------------------------------------------------------------------
# Warehouse truth -- the QUERY_HISTORY join, via the flattened query_id
# ---------------------------------------------------------------------------


def warehouse_truth(con, since_days: int = 7, max_ids: int = 1000) -> tuple:
    """Joins the agent's own query_ids to ACCOUNT_USAGE.QUERY_HISTORY for real
    warehouse metrics: compile vs execute, bytes scanned, partition pruning.

    Runs in TWO steps on TWO warehouses, deliberately. An Interactive
    Warehouse can only query interactive tables, so joining AGENT_TRACES_IT
    directly to ACCOUNT_USAGE.QUERY_HISTORY on RETAIL_AI_WH fails with
    '010403 (42601): Error in secure object' -- ACCOUNT_USAGE is a set of
    secure views over standard tables. So: collect query_ids on the
    Interactive Warehouse, then switch to a standard warehouse for the
    QUERY_HISTORY lookup, then switch back.

    Note ACCOUNT_USAGE latency is up to ~45min, so the most recent turns may
    not have landed yet -- matched_queries below can trail the id count.
    """
    cur = con.cursor()
    cur.execute(
        f"""
        SELECT DISTINCT query_id
        FROM {TABLE}
        WHERE query_id IS NOT NULL AND event_date >= ?
        LIMIT ?
        """,
        (date.today() - timedelta(days=since_days), max_ids),
    )
    ids = [r[0] for r in cur.fetchall()]
    if not ids:
        return (0, None, None, None, None, None, None)

    placeholders = ",".join(["?"] * len(ids))
    try:
        cur.execute(f"USE WAREHOUSE {STANDARD_WAREHOUSE}")
        cur.execute(
            f"""
            SELECT
                COUNT(*) AS matched_queries,
                ROUND(AVG(compilation_time), 0) AS avg_compile_ms,
                ROUND(AVG(execution_time), 0) AS avg_exec_ms,
                ROUND(SUM(bytes_scanned) / POWER(1024, 3), 2) AS gb_scanned,
                ROUND(100 - (SUM(partitions_scanned) * 100.0 / NULLIF(SUM(partitions_total), 0)), 1) AS pct_pruned,
                SUM(rows_produced) AS rows_produced,
                COUNT(DISTINCT warehouse_name) AS warehouses
            FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
            WHERE query_id IN ({placeholders})
            """,
            tuple(ids),
        )
        return cur.fetchone()
    finally:
        cur.execute(f"USE WAREHOUSE {WAREHOUSE}")


def concurrency_timeline(con, since_days: int = 7) -> list[tuple]:
    """SQL starts per second -- the burst, measured. Peak was 8/sec on the
    50-question batch with 20-way client concurrency."""
    sql = f"""
        SELECT
            DATE_TRUNC('second', start_ts) AS sec,
            COUNT(*) AS sql_starts
        FROM {TABLE}
        WHERE span_name = 'SqlExecution_SystemSQL' AND event_date >= ?
        GROUP BY 1
        HAVING COUNT(*) > 1
        ORDER BY sql_starts DESC, sec
        LIMIT 200
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days),))
    return cur.fetchall()


def trace_waterfall(con, trace_id: str) -> list[tuple]:
    """Every span in one trace with its offset from trace start, for a
    Gantt-style view of where a single turn spent its time."""
    sql = f"""
        WITH bounds AS (
            SELECT MIN(start_ts) AS t0 FROM {TABLE} WHERE trace_id = ?
        )
        SELECT
            span_name,
            DATEDIFF('millisecond', b.t0, t.start_ts) AS offset_ms,
            t.duration_ms,
            t.sql_status,
            t.tokens_total
        FROM {TABLE} t CROSS JOIN bounds b
        WHERE t.trace_id = ?
        ORDER BY offset_ms, t.duration_ms DESC
    """
    cur = con.cursor()
    cur.execute(sql, (trace_id, trace_id))
    return cur.fetchall()


def generated_sql(con, trace_id: str) -> list[tuple]:
    """The actual SQL the agent wrote for one turn, with status and row count."""
    sql = f"""
        SELECT final_sql, sql_status, sql_num_rows, query_id, sql_error, verified_query_used
        FROM {TABLE}
        WHERE trace_id = ? AND final_sql IS NOT NULL
        ORDER BY start_ts
    """
    cur = con.cursor()
    cur.execute(sql, (trace_id,))
    return cur.fetchall()


def turn_picker(con, since_days: int = 7, limit: int = 60) -> list[tuple]:
    """Recent turns for the trace explorer dropdown."""
    sql = f"""
        SELECT trace_id, LEFT(question, 80) AS question, start_ts, duration_ms
        FROM {TABLE}
        WHERE span_name = 'AgentV2RequestResponseInfo'
          AND question IS NOT NULL
          AND event_date >= ?
        ORDER BY start_ts DESC
        LIMIT ?
    """
    cur = con.cursor()
    cur.execute(sql, (date.today() - timedelta(days=since_days), limit))
    return cur.fetchall()


if __name__ == "__main__":
    con = _connect()
    print("Turns/day (last 7d):", turns_per_day(con))
    print("SQL fan-out distribution:", sql_fanout_distribution(con))
    print("Turn duration p50/p95/max/n:", turn_duration_percentiles(con))
    print("Planning-step distribution:", planning_steps_distribution(con))
    threads = multi_turn_threads(con)
    print("Multi-turn threads (2+):", threads)
    print("Span breakdown (today):", span_breakdown(con))
    print("Top questions:", top_questions(con))
    print("Success rate (total, succeeded, flagged_slow, pct):", success_rate(con))
    print("Failed turns:", failed_turns(con))
    print("Latency breakdown (median agent_ms, sql_ms, other_ms, turns):", latency_breakdown(con))
    if threads:
        sample_thread_id = threads[0][0]
        print(f"Thread messages for {sample_thread_id}:", thread_messages(con, sample_thread_id))
    print("Table refresh status keys:", sorted(table_refresh_status(con).keys())[:5])

    print("\n--- reliability ---")
    print("SQL reliability:", sql_reliability(con))
    print("Hallucinated columns:", hallucinated_columns(con)[:8])
    print("Error taxonomy:", error_taxonomy(con))
    print("Self-correction:", self_correction(con))

    print("\n--- cost ---")
    print("Token economics:", token_economics(con))
    print("Most expensive turns:", tokens_per_turn(con, limit=3))

    print("\n--- warehouse + burst ---")
    print("Warehouse truth:", warehouse_truth(con))
    print("Concurrency peak rows:", concurrency_timeline(con)[:5])

    print("\n--- trace explorer ---")
    turns = turn_picker(con, limit=3)
    print("Turn picker:", [(t[0], t[1][:40]) for t in turns])
    if turns:
        tid = turns[0][0]
        print(f"Waterfall for {tid}:", trace_waterfall(con, tid)[:6])
        gen = generated_sql(con, tid)
        print(f"Generated SQL count for {tid}: {len(gen)}")
    con.close()
