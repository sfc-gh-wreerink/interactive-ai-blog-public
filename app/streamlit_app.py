"""
AI Observability Dashboard -- Streamlit app over RETAIL_DEMO.APP.AGENT_TRACES_IT,
queried through RETAIL_AI_WH (the same Interactive Warehouse that runs the
retail app's own generated SQL).

This is the demo's core point made concrete: the same infrastructure that
executes an AI agent's SQL is also the backend for monitoring that agent.

Four tabs:
  1. Burst & Latency  -- fan-out, concurrency, where turn time actually goes
  2. Reliability      -- the 100%-turn-success vs 67%-SQL-success contrast
  3. Cost & Tokens    -- 11M+ tokens, cache hit rate, most expensive turns
  4. Trace Explorer   -- one turn, fully unpacked (waterfall + generated SQL)

Works both as a Streamlit-in-Snowflake app (active Snowpark session) and as a
local `streamlit run` against the named connection.

Run locally:
    streamlit run app/streamlit_app.py
"""

import pandas as pd
import streamlit as st

import observability_queries as oq

st.set_page_config(page_title="AI Observability Dashboard", layout="wide")


@st.cache_resource
def get_connection():
    """Snowpark session (SiS) if available, else a direct connector
    connection (local dev). Both expose .cursor() the same way."""
    try:
        from snowflake.snowpark.context import get_active_session

        session = get_active_session()
        session.sql(f"USE WAREHOUSE {oq.WAREHOUSE}").collect()
        return session.connection
    except Exception:
        return oq._connect()


con = get_connection()

st.title("AI Observability Dashboard")
st.caption(
    "RETAIL_OPS_AGENT traces from AGENT_TRACES_IT (an Interactive Table), queried "
    "through RETAIL_AI_WH -- the same warehouse that executes the agent's own SQL."
)

# --- staleness caption + manual refresh (TARGET_LAG is 1 hour) --------------
refresh_info = oq.table_refresh_status(con)
head_left, head_right = st.columns([5, 1])
with head_left:
    if refresh_info.get("latest_data_timestamp"):
        st.caption(
            f"Data as of **{refresh_info['latest_data_timestamp']}** "
            f"(target lag {refresh_info.get('target_lag', '1 hour')}). Refreshes hourly; "
            "not a live feed."
        )
with head_right:
    if st.button("Refresh now"):
        try:
            con.cursor().execute("ALTER DYNAMIC TABLE RETAIL_DEMO.APP.AGENT_TRACES_IT REFRESH")
            st.success("Refresh triggered.")
        except Exception as exc:
            st.warning(f"Manual refresh unavailable ({exc}); table refreshes hourly.")

since_days = st.sidebar.selectbox(
    "Time range", [1, 3, 7, 14, 30, 60, 9999], index=6,
    format_func=lambda d: "All time" if d >= 9999 else f"Last {d} days"
)
st.sidebar.caption("Applies to every tab except the trace explorer's own picker.")

tab_burst, tab_reliability, tab_cost, tab_trace = st.tabs(
    ["Burst & Latency", "Reliability", "Cost & Tokens", "Trace Explorer"]
)

# ===========================================================================
# TAB 1 -- Burst & Latency
# ===========================================================================
with tab_burst:
    duration = oq.turn_duration_percentiles(con, since_days)
    fanout = oq.sql_fanout_distribution(con, since_days)
    p50_s, p95_s, max_s, _ = duration if duration and duration[0] is not None else (None, None, None, 0)

    total_traces = sum(ct for _, ct in fanout) or 1
    avg_sql_calls = sum(calls * ct for calls, ct in fanout) / total_traces
    max_sql_calls = max((calls for calls, _ in fanout), default=0)

    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Turns", total_traces)
    k2.metric("Turn duration p50 / p95", f"{p50_s}s / {p95_s}s" if p50_s is not None else "n/a")
    k3.metric("Avg SQL calls per turn", f"{avg_sql_calls:.1f}")
    k4.metric("Worst-case fan-out", f"{max_sql_calls} queries")

    st.subheader("How many SQL queries does one question really trigger?")
    st.caption("The burst claim, measured. One natural-language question, N SQL statements.")
    fanout_df = pd.DataFrame(fanout, columns=["sql_calls", "traces"])
    if not fanout_df.empty:
        st.bar_chart(fanout_df.set_index("sql_calls"), height=260)

    st.subheader("Where does the time actually go?")
    breakdown = oq.latency_breakdown(con, since_days)
    if breakdown and breakdown[0] is not None:
        agent_ms, sql_ms, other_ms, n_turns = breakdown
        sql_share = sql_ms / agent_ms * 100 if agent_ms else 0
        c1, c2 = st.columns([1, 2])
        with c1:
            st.metric("Median turn", f"{agent_ms/1000:.1f}s")
            st.metric("...spent on SQL", f"{sql_ms/1000:.1f}s", f"{sql_share:.1f}% of turn")
            st.metric("...spent on orchestration", f"{other_ms/1000:.1f}s")
        with c2:
            st.bar_chart(
                pd.DataFrame(
                    {"seconds": [sql_ms / 1000.0, other_ms / 1000.0]},
                    index=["SQL execution", "Orchestration (planning + LLM)"],
                ),
                height=260,
            )
        st.caption(
            f"Across {n_turns} turns. The warehouse is not the bottleneck; the model is. "
            "A faster query engine would not move the top number."
        )

    st.subheader("Concurrency: SQL starts per second")
    st.caption("Seconds where more than one SQL statement began. This is the burst hitting the warehouse.")
    conc = oq.concurrency_timeline(con, since_days)
    conc_df = pd.DataFrame(conc, columns=["second", "sql_starts"])
    if not conc_df.empty:
        peak = int(conc_df["sql_starts"].max())
        st.metric("Peak concurrent SQL starts in one second", peak)
        st.bar_chart(conc_df.set_index("second").sort_index(), height=220)
    else:
        st.write("No multi-query seconds in this range.")

    left, right = st.columns(2)
    with left:
        st.subheader("Turns per day")
        tpd = pd.DataFrame(oq.turns_per_day(con, since_days), columns=["event_date", "turns"])
        if not tpd.empty:
            st.bar_chart(tpd.set_index("event_date"), height=220)
    with right:
        st.subheader("Planning steps per turn")
        psd = pd.DataFrame(
            oq.planning_steps_distribution(con, since_days), columns=["planning_steps", "traces"]
        )
        if not psd.empty:
            st.bar_chart(psd.set_index("planning_steps"), height=220)

# ===========================================================================
# TAB 2 -- Reliability
# ===========================================================================
with tab_reliability:
    rel = oq.sql_reliability(con, since_days)
    success = oq.success_rate(con, since_days)
    turn_total, turn_ok, flagged_slow, turn_pct = success if success else (0, 0, 0, 0)

    st.subheader("Turn-level success hides SQL-level failure")
    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Turn success rate", f"{turn_pct}%", help=f"{turn_ok}/{turn_total} turns reported SUCCESS")
    k2.metric(
        "SQL success rate",
        f"{rel['sql_success_pct']}%" if rel["sql_success_pct"] is not None else "n/a",
        f"-{rel['sql_err']} failed calls",
        delta_color="inverse",
        help=f"{rel['sql_ok']}/{rel['sql_calls']} individual SQL statements succeeded",
    )
    k3.metric("Turns containing a failure", f"{rel['turns_with_error_pct']}%",
              help=f"{rel['turns_with_error']} of {rel['total_turns']} turns")
    k4.metric("Flagged SLOW by Snowflake", flagged_slow)

    if rel["sql_err"]:
        st.error(
            f"**{rel['sql_err']} of {rel['sql_calls']} SQL statements failed "
            f"({100 - rel['sql_success_pct']:.1f}%)**, across {rel['turns_with_error']} turns "
            f"({rel['turns_with_error_pct']}%). Every turn still reported SUCCESS, because the "
            "agent retries and self-corrects. This is the gap you cannot see without tracing."
        )

    st.subheader("Columns the agent invented")
    st.caption(
        "Parsed from 'invalid identifier' errors. Each row is a semantic-model gap you can "
        "actually go fix -- a name the model expected to exist but does not."
    )
    hall = pd.DataFrame(
        oq.hallucinated_columns(con, since_days),
        columns=["invented_identifier", "occurrences", "turns_affected"],
    )
    if not hall.empty:
        c1, c2 = st.columns([2, 3])
        with c1:
            st.dataframe(hall, width="stretch", hide_index=True)
        with c2:
            st.bar_chart(hall.set_index("invented_identifier")["occurrences"], height=300)
    else:
        st.write("No invalid-identifier errors in this range.")

    left, right = st.columns(2)
    with left:
        st.subheader("Error taxonomy")
        st.caption("By Snowflake error code. 000904 is 'invalid identifier'.")
        tax = pd.DataFrame(
            oq.error_taxonomy(con, since_days), columns=["error_code", "occurrences", "turns_affected"]
        )
        if not tax.empty:
            st.dataframe(tax, width="stretch", hide_index=True)
    with right:
        st.subheader("Self-correction")
        st.caption("Failed SQL calls per turn, and how many of those turns still produced a good query.")
        sc = pd.DataFrame(
            oq.self_correction(con, since_days), columns=["failures_in_turn", "turns", "recovered"]
        )
        if not sc.empty:
            sc["never_recovered"] = sc["turns"] - sc["recovered"]
            st.dataframe(sc, width="stretch", hide_index=True)
            never = int(sc["never_recovered"].sum())
            if never:
                st.caption(
                    f"{never} turn(s) never produced a successful SQL statement at all, yet still "
                    "reported turn status SUCCESS."
                )

    st.subheader("Verified query usage")
    st.caption(
        "This agent authors SQL itself via system_execute_sql rather than calling the Cortex "
        "Analyst text2sql tool, so verified queries are never hit. Confirmed here rather than assumed."
    )
    vq = pd.DataFrame(
        oq.span_breakdown(con), columns=["span_name", "count", "traces"]
    )
    st.dataframe(vq.head(12), width="stretch", hide_index=True)

# ===========================================================================
# TAB 3 -- Cost & Tokens
# ===========================================================================
with tab_cost:
    tok = oq.token_economics(con, since_days)
    if tok and tok[0]:
        total_t, in_t, out_t, cache_t, cache_pct, turns, per_turn, max_span = tok

        k1, k2, k3, k4 = st.columns(4)
        k1.metric("Total tokens", f"{total_t:,}")
        k2.metric("Tokens per turn", f"{per_turn:,}")
        k3.metric("Served from cache", f"{cache_pct}%", help=f"{cache_t:,} of {in_t:,} input tokens")
        k4.metric("Largest single span", f"{max_span:,}")

        st.subheader("Input vs output")
        st.caption(
            f"Input dominates at {in_t/max(out_t,1):.0f}:1. Agent orchestration is mostly re-reading "
            "context, not generating text, which is why caching matters more than output length."
        )
        st.bar_chart(
            pd.DataFrame(
                {"tokens": [in_t - cache_t, cache_t, out_t]},
                index=["Input (fresh)", "Input (cache read)", "Output"],
            ),
            height=260,
        )

        st.subheader("Most expensive turns")
        st.caption("Token spend per turn, with the question that caused it.")
        exp = pd.DataFrame(
            oq.tokens_per_turn(con, since_days), columns=["tokens", "output_tokens", "question"]
        )
        if not exp.empty:
            st.dataframe(exp, width="stretch", hide_index=True)

        st.subheader("Warehouse truth")
        st.caption(
            "The agent's own query_ids joined to ACCOUNT_USAGE.QUERY_HISTORY. Note this join runs on a "
            "standard warehouse, not the Interactive one -- an Interactive Warehouse cannot read the "
            "ACCOUNT_USAGE secure views."
        )
        wt = oq.warehouse_truth(con, since_days)
        if wt and wt[0]:
            matched, compile_ms, exec_ms, gb, pruned, rows_out, whs = wt
            w1, w2, w3, w4 = st.columns(4)
            w1.metric("Queries matched", f"{matched:,}")
            w2.metric("Avg compile / exec", f"{compile_ms:.0f}ms / {exec_ms:.0f}ms")
            w3.metric("Partitions pruned", f"{pruned}%")
            w4.metric("Data scanned", f"{gb} GB")
            st.caption(
                f"{rows_out:,} rows produced across {matched:,} queries. Compile time is "
                f"{compile_ms/(compile_ms+exec_ms)*100:.0f}% of warehouse time -- execution is the cheap part. "
                "ACCOUNT_USAGE lags up to ~45 minutes, so very recent turns may not appear yet."
            )
    else:
        st.write("No token data in this range.")

# ===========================================================================
# TAB 4 -- Trace Explorer
# ===========================================================================
with tab_trace:
    st.subheader("One turn, fully unpacked")
    turns_list = oq.turn_picker(con, since_days)
    if not turns_list:
        st.write("No turns in this range.")
    else:
        labels = {
            f"{start:%Y-%m-%d %H:%M} ({dur/1000:.1f}s) -- {q}": tid
            for tid, q, start, dur in turns_list
        }
        pick = st.selectbox("Pick a turn", list(labels.keys()))
        trace_id = labels[pick]

        wf = oq.trace_waterfall(con, trace_id)
        if wf:
            wf_df = pd.DataFrame(
                wf, columns=["span_name", "offset_ms", "duration_ms", "sql_status", "tokens"]
            )
            total_ms = int(wf_df["offset_ms"].max() + wf_df["duration_ms"].max())
            st.caption(f"{len(wf_df)} spans, {total_ms/1000:.1f}s wall clock. Offsets are from trace start.")

            # Waterfall: transparent offset bar + visible duration bar
            chart_df = wf_df.copy()
            chart_df["label"] = [f"{i:02d} {n[:38]}" for i, n in enumerate(chart_df["span_name"])]
            chart_df = chart_df.set_index("label")
            st.bar_chart(
                chart_df[["offset_ms", "duration_ms"]],
                horizontal=True,
                stack=True,
                color=["#00000000", "#29B5E8"],
                height=max(300, 26 * len(chart_df)),
            )

            st.dataframe(
                wf_df[["span_name", "offset_ms", "duration_ms", "sql_status", "tokens"]],
                width="stretch",
                hide_index=True,
            )

        st.subheader("The SQL the agent actually wrote")
        gen = oq.generated_sql(con, trace_id)
        if not gen:
            st.write("No SQL was generated for this turn.")
        for i, (sql_text, status, num_rows, qid, err, vq_used) in enumerate(gen, start=1):
            ok = status == "SUCCESS"
            header = f"{'OK' if ok else 'FAILED'} -- statement {i}"
            if num_rows is not None:
                header += f" ({num_rows:,} rows)"
            with st.expander(header, expanded=not ok):
                if not ok and err:
                    st.error(err[:600])
                st.code(sql_text or "(no SQL captured)", language="sql")
                st.caption(f"query_id: `{qid}` | verified_query_used: {vq_used}")
