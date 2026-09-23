"""
Measures Cortex Agent latency over the streaming REST agent:run endpoint.

Runs a fixed set of questions twice each (the first call is not representative
because prompt caching absorbs most of the input tokens on the second) and
records per-turn latency, token usage, SQL fan-out, and VQR hits.

Usage:
    python3.13 setup/agent_latency_test.py --label baseline
    python3.13 setup/agent_latency_test.py --label optimized

Requires python3.13 (the interpreter that has the Snowflake packages); this
script itself only needs the stdlib.
"""

import argparse
import collections
import json
import os
import statistics
import time
import tomllib
import urllib.error
import urllib.request

# Point this at your own connections.toml profile (~/.snowflake/connections.toml).
CONNECTION = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "default")
AGENT_PATH = "/api/v2/databases/RETAIL_DEMO/schemas/APP/agents/RETAIL_OPS_AGENT:run"

# The 5 Phase 1 exit questions. They map onto verified queries, so they also
# measure VQR hit rate.
QUESTIONS = [
    "Which 10 stores had the highest revenue last month?",
    "Show inventory alerts in the West region",
    "Target attainment by region for Q4 2025",
    "Which product categories saw the biggest week-over-week revenue drop?",
    "Compare staffing hours to revenue per store this quarter",
]


def load_connection() -> tuple[str, str]:
    """Returns (pat, host). Host is derived from the connection profile's
    account field unless SNOWFLAKE_HOST overrides it (e.g. PrivateLink)."""
    path = os.path.expanduser("~/.snowflake/connections.toml")
    with open(path, "rb") as fh:
        profile = tomllib.load(fh)[CONNECTION]
    host = os.environ.get("SNOWFLAKE_HOST")
    if not host:
        # Account underscores become hyphens in the REST hostname, or TLS
        # fails with a certificate hostname mismatch.
        host = f"{profile['account'].replace('_', '-')}.snowflakecomputing.com"
    return profile["token"], host


def run_question(question: str, pat: str, host: str, timeout: int = 900) -> dict:
    """One agent:run turn. Parses the SSE stream and returns measurements."""
    body = {
        "stream": True,
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
    }
    req = urllib.request.Request(
        f"https://{host}{AGENT_PATH}",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {pat}",
            "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        method="POST",
    )

    started = time.time()
    events = collections.Counter()
    sql_tool_uses = 0
    query_ids = []
    vqr_used = False
    answer_chars = 0
    metadata = None
    first_event_s = None
    event_name = None
    error = None

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            for raw in resp:
                line = raw.decode("utf-8", "replace").rstrip()
                if line.startswith("event: "):
                    event_name = line[7:]
                    events[event_name] += 1
                    continue
                if not line.startswith("data: "):
                    continue
                if first_event_s is None:
                    first_event_s = round(time.time() - started, 2)
                try:
                    data = json.loads(line[6:])
                except json.JSONDecodeError:
                    continue

                if event_name == "response.tool_use" and data.get("type") == "system_execute_sql":
                    sql_tool_uses += 1
                elif event_name == "response.tool_result" and data.get("type") == "system_execute_sql":
                    for item in data.get("content") or []:
                        qid = (item.get("json") or {}).get("query_id")
                        if qid:
                            query_ids.append(qid)
                elif event_name == "response.table" and data.get("query_id"):
                    query_ids.append(data["query_id"])
                elif event_name == "response.tool_result.analyst.delta":
                    delta = data.get("delta") or {}
                    if delta.get("query_id"):
                        query_ids.append(delta["query_id"])
                    if delta.get("verified_query_used"):
                        vqr_used = True
                elif event_name == "response.text":
                    answer_chars += len(data.get("text") or "")
                elif event_name == "response":
                    # Docs: "The last event sent by the API is a response event."
                    # Must break here -- the server does not close the connection
                    # promptly afterwards, so reading to EOF hangs until timeout.
                    metadata = data.get("metadata")
                    break
                elif event_name == "error":
                    error = data.get("message")
                    break
    except urllib.error.HTTPError as exc:
        return {
            "question": question,
            "http_status": exc.code,
            "error": exc.read().decode("utf-8", "replace")[:300],
            "total_s": round(time.time() - started, 1),
        }

    input_tokens = output_tokens = None
    if metadata:
        consumed = (metadata.get("usage") or {}).get("tokens_consumed") or []
        if consumed:
            input_tokens = (consumed[0].get("input_tokens") or {}).get("total")
            output_tokens = (consumed[0].get("output_tokens") or {}).get("total")

    return {
        "question": question,
        "http_status": status,
        "error": error,
        "total_s": round(time.time() - started, 1),
        "first_event_s": first_event_s,
        "sql_tool_uses": sql_tool_uses,
        "query_ids": list(dict.fromkeys(query_ids)),
        "verified_query_used": vqr_used,
        "answer_chars": answer_chars,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        # response.status events are a proxy for orchestration planning steps.
        "status_events": events.get("response.status", 0),
        "thinking_deltas": events.get("response.thinking.delta", 0),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True, help="e.g. baseline or optimized")
    parser.add_argument("--runs", type=int, default=2, help="runs per question")
    parser.add_argument("--out", default="setup/latency_baseline.json")
    args = parser.parse_args()

    pat, host = load_connection()
    results = []

    for run_idx in range(1, args.runs + 1):
        for question in QUESTIONS:
            result = run_question(question, pat, host)
            result["label"] = args.label
            result["run"] = run_idx
            results.append(result)
            print(
                f"[{args.label} run{run_idx}] {result['total_s']:>6}s "
                f"first={result.get('first_event_s')}s "
                f"sql={result.get('sql_tool_uses')} "
                f"vqr={result.get('verified_query_used')} "
                f"in={result.get('input_tokens')} out={result.get('output_tokens')} "
                f"| {question[:52]}",
                flush=True,
            )

    ok = [r for r in results if r.get("http_status") == 200 and not r.get("error")]
    second = [r for r in ok if r["run"] > 1] or ok
    summary = {
        "label": args.label,
        "calls": len(results),
        "succeeded": len(ok),
        "median_total_s": round(statistics.median([r["total_s"] for r in second]), 1) if second else None,
        "median_first_event_s": round(
            statistics.median([r["first_event_s"] for r in second if r.get("first_event_s")]), 2
        ) if second else None,
        "median_input_tokens": int(
            statistics.median([r["input_tokens"] for r in second if r.get("input_tokens")])
        ) if second else None,
        "median_output_tokens": int(
            statistics.median([r["output_tokens"] for r in second if r.get("output_tokens")])
        ) if second else None,
        "total_sql_calls": sum(r.get("sql_tool_uses") or 0 for r in ok),
        "vqr_hits": sum(1 for r in ok if r.get("verified_query_used")),
        "empty_answers": sum(1 for r in ok if not r.get("answer_chars")),
    }
    print("\nSUMMARY", json.dumps(summary, indent=2))

    # Append so baseline and optimized runs accumulate in one file.
    existing = []
    if os.path.exists(args.out):
        with open(args.out) as fh:
            existing = json.load(fh)
    with open(args.out, "w") as fh:
        json.dump(existing + [{"summary": summary, "results": results}], fh, indent=2)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
