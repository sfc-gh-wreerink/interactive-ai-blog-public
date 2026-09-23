"""
Phase 2 traffic simulator: drives RETAIL_OPS_AGENT via the streaming REST
agent:run endpoint using questions from setup/05_question_bank.py.

Multi-turn questions use the Threads API (POST /api/v2/cortex/threads) and
chain parent_message_id from the previous turn's assistant_message_id, per
https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-threads.

Usage:
    python3.13 setup/06_simulate_traffic.py --dry-run --count 50
    python3.13 setup/06_simulate_traffic.py --count 20 --concurrency 5
    python3.13 setup/06_simulate_traffic.py --analyze setup/traffic_log.jsonl
"""

import argparse
import collections
import importlib.util
import json
import os
import time
import tomllib
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Point this at your own connections.toml profile (~/.snowflake/connections.toml).
CONNECTION = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "default")
AGENT_PATH = "/api/v2/databases/RETAIL_DEMO/schemas/APP/agents/RETAIL_OPS_AGENT:run"
THREADS_PATH = "/api/v2/cortex/threads"

_BANK_PATH = Path(__file__).parent / "05_question_bank.py"


def _load_question_bank():
    # Module name starts with a digit -- can't `import 05_question_bank` directly.
    spec = importlib.util.spec_from_file_location("question_bank", _BANK_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def _headers(pat: str) -> dict:
    return {
        "Authorization": f"Bearer {pat}",
        "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN",
        "Content-Type": "application/json",
    }


def create_thread(pat: str, host: str) -> int:
    req = urllib.request.Request(
        f"https://{host}{THREADS_PATH}",
        data=json.dumps({"origin_application": "phase2_sim"}).encode(),
        headers={**_headers(pat), "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())["thread_id"]


def run_turn(
    question: str,
    pat: str,
    host: str,
    thread_id: int | None = None,
    parent_message_id: int | None = None,
    timeout: int = 900,
) -> dict:
    """One agent:run turn. Parses the SSE stream; returns measurements."""
    body = {
        "stream": True,
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
    }
    if thread_id is not None:
        body["thread_id"] = thread_id
        body["parent_message_id"] = parent_message_id if parent_message_id is not None else 0

    req = urllib.request.Request(
        f"https://{host}{AGENT_PATH}",
        data=json.dumps(body).encode(),
        headers={**_headers(pat), "Accept": "text/event-stream"},
        method="POST",
    )

    started = time.time()
    sql_tool_uses = 0
    query_ids: list[str] = []
    vqr_used = False
    answer_chars = 0
    metadata = None
    first_event_s = None
    event_name = None
    error = None
    status = None

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            for raw in resp:
                line = raw.decode("utf-8", "replace").rstrip()
                if line.startswith("event: "):
                    event_name = line[7:]
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
                    # The agent's SQL results arrive here (content[].json.query_id),
                    # NOT via response.table or the analyst.delta path below -- this
                    # agent never invokes cortex_analyst_text_to_sql directly.
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
                    # Must break here: docs say this is the last event, but the
                    # server does not close the connection promptly afterward --
                    # reading to EOF hangs until the timeout (measured: 15 min).
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
            "thread_id": thread_id,
        }

    input_tokens = output_tokens = None
    result_thread_id = thread_id
    assistant_message_id = None
    if metadata:
        consumed = (metadata.get("usage") or {}).get("tokens_consumed") or []
        if consumed:
            input_tokens = (consumed[0].get("input_tokens") or {}).get("total")
            output_tokens = (consumed[0].get("output_tokens") or {}).get("total")
        result_thread_id = metadata.get("thread_id", thread_id)
        assistant_message_id = metadata.get("assistant_message_id")

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
        "thread_id": result_thread_id,
        "assistant_message_id": assistant_message_id,
    }


def run_generated_question(item: dict, pat: str, host: str) -> list[dict]:
    """Runs one generated question (single-turn or a multi-turn thread).
    Returns a list of per-turn result dicts, tagged with question metadata."""
    tag = {"tier": item["tier"], "expected_sql_calls": list(item["expected_sql_calls"]),
           "clause_tables": item["clause_tables"]}

    # Every generated question gets a real thread, even single-turn ones --
    # gives every turn a thread_id/message_id for downstream joins, at the
    # cost of one extra POST /api/v2/cortex/threads call per question.
    try:
        thread_id = create_thread(pat, host)
    except Exception as exc:  # thread creation failed -- fall back to stateless single-shot
        result = run_turn(item["question"], pat, host)
        return [{**result, **tag, "turn_index": 0, "error": f"thread create failed: {exc}"}]

    if item["tier"] != "multi_turn" or not item["followups"]:
        result = run_turn(item["question"], pat, host, thread_id=thread_id, parent_message_id=0)
        return [{**result, **tag, "turn_index": 0}]

    results = []
    result = run_turn(item["question"], pat, host, thread_id=thread_id, parent_message_id=0)
    results.append({**result, **tag, "turn_index": 0})
    parent_id = result.get("assistant_message_id")

    for i, followup in enumerate(item["followups"], start=1):
        if parent_id is None:
            # Per docs: if assistant metadata is missing (failed turn), continue
            # from the last successful assistant message. We have none, so stop.
            break
        result = run_turn(followup, pat, host, thread_id=thread_id, parent_message_id=parent_id)
        results.append({**result, **tag, "turn_index": i})
        parent_id = result.get("assistant_message_id") or parent_id

    return results


def analyze(jsonl_path: str) -> None:
    """Reads the traffic log and prints a ready-to-run SQL query joining
    captured query_ids to QUERY_HISTORY, grouped by tier."""
    records = [json.loads(line) for line in open(jsonl_path) if line.strip()]
    by_tier: dict[str, list[str]] = collections.defaultdict(list)
    for r in records:
        by_tier[r.get("tier", "unknown")].extend(r.get("query_ids") or [])

    all_ids = [qid for ids in by_tier.values() for qid in ids]
    print(f"-- {len(records)} turns logged, {len(all_ids)} query_ids captured")
    for tier, ids in by_tier.items():
        print(f"--   {tier}: {len(ids)} query_ids across its turns")

    if not all_ids:
        print("-- no query_ids captured; nothing to analyze")
        return

    id_list = ",".join(f"'{qid}'" for qid in all_ids)
    print(f"""
WITH captured AS (
  SELECT * FROM TABLE(RETAIL_DEMO.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 1000))
  WHERE query_id IN ({id_list})
)
SELECT
  warehouse_name,
  COUNT(*) AS queries,
  ROUND(AVG(execution_time), 0) AS avg_exec_ms,
  ROUND(MEDIAN(execution_time), 0) AS p50_exec_ms,
  ROUND(APPROX_PERCENTILE(execution_time, 0.95), 0) AS p95_exec_ms,
  SUM(bytes_scanned) AS total_bytes_scanned
FROM captured
GROUP BY warehouse_name
ORDER BY queries DESC;
""")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--concurrency", type=int, default=5)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--out", default="setup/traffic_log.jsonl")
    parser.add_argument("--analyze", help="path to an existing JSONL log; skips everything else")
    args = parser.parse_args()

    if args.analyze:
        analyze(args.analyze)
        return

    bank = _load_question_bank()
    batch = bank.generate_batch(args.count, seed=args.seed)

    tier_counts = collections.Counter(q["tier"] for q in batch)
    print(f"Generated {len(batch)} questions. Tier distribution: {dict(tier_counts)}")

    if args.dry_run:
        for q in batch:
            fu = f" (+{len(q['followups'])} followups)" if q["followups"] else ""
            print(f"[{q['tier']:<11}]{fu}  {q['question']}")
        print("\n--dry-run: no agent calls made.")
        return

    pat, host = load_connection()
    all_results = []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {pool.submit(run_generated_question, q, pat, host): q for q in batch}
        for i, future in enumerate(as_completed(futures), start=1):
            turns = future.result()
            all_results.extend(turns)
            head = turns[0]
            print(
                f"[{i}/{len(batch)}] {head['tier']:<11} {head.get('total_s')}s "
                f"sql={sum(t.get('sql_tool_uses') or 0 for t in turns)} "
                f"turns={len(turns)} status={head.get('http_status')}",
                flush=True,
            )

    elapsed = round(time.time() - t0, 1)
    ok = [r for r in all_results if r.get("http_status") == 200 and not r.get("error")]
    total_sql = sum(r.get("sql_tool_uses") or 0 for r in ok)
    print(f"\nBatch done in {elapsed}s. {len(ok)}/{len(all_results)} turns succeeded. "
          f"Total SQL calls: {total_sql}.")

    with open(args.out, "w") as fh:
        for r in all_results:
            fh.write(json.dumps(r) + "\n")
    print(f"wrote {args.out} ({len(all_results)} turn records)")
    print(f"Run `python3.13 setup/06_simulate_traffic.py --analyze {args.out}` "
          f"for a QUERY_HISTORY join.")


if __name__ == "__main__":
    main()
