"""
Parameterized question generator for Phase 2 traffic simulation.

Replaces a static question list with template + slot generation over the
RETAIL_OPS_SV semantic view's actual enum dimensions. Tiers are weighted
toward compound/comparative phrasing, which is the documented mechanism for
getting a Cortex Agent to split one NL question into multiple SQL calls
(comparisons and multi-part asks -> subtasks -> multiple tool calls; a single
self-contained question typically does not).

Deliberately reuses a small set of phrasing skeletons rather than maximizing
question uniqueness: prompt caching absorbed ~80% of input tokens in
measurement (111K of 136K), and maximizing uniqueness defeats that cache.
Only slot VALUES vary widely; sentence structure stays small and fixed.

NOTE: after the agent-latency-optimization pass, RETAIL_OPS_AGENT does not use
verified queries at all (confirmed: zero cortex_analyst_text_to_sql tool
calls), and removing VQRs cut measured SQL calls per batch from 25 to 15.
Expected-SQL-call ranges below are the pre-optimization estimates from the
plan; treat them as upper bounds, not current guarantees.

Usage:
    python3.13 setup/05_question_bank.py --sample 30
    python3.13 setup/05_question_bank.py --sample 30 --seed 42
"""

import argparse
import datetime
import json
import random

# ---------------------------------------------------------------------------
# Data window
# ---------------------------------------------------------------------------
# Verified via SQL (2026-08-10): MIN(sale_date)=2024-08-11, MAX(sale_date)=2026-08-10.
# The raw tables were generated once with DATEADD(..., CURRENT_DATE()) at build
# time -- the window does NOT advance with real calendar time. If the data is
# ever regenerated, refresh DATA_MAX_DATE via:
#   SELECT MAX(sale_date) FROM RETAIL_DEMO.APP.DAILY_SALES_IT
DATA_MAX_DATE = datetime.date(2026, 8, 10)
DATA_WINDOW_DAYS = 729
DATA_MIN_DATE = DATA_MAX_DATE - datetime.timedelta(days=DATA_WINDOW_DAYS)

# Relative periods are evergreen as long as real "today" stays close to
# DATA_MAX_DATE (Cortex Analyst resolves these against Snowflake's real
# CURRENT_DATE(), not this script's clock).
RELATIVE_PERIODS = [
    "last month", "this month", "last quarter", "this quarter",
    "last 7 days", "last 30 days", "year to date", "last week",
]


def _quarters_in_window() -> list[str]:
    """Calendar quarters ('Q3 2024' style) that fall inside the verified data window."""
    quarters = []
    y, q = DATA_MIN_DATE.year, (DATA_MIN_DATE.month - 1) // 3 + 1
    end_y, end_q = DATA_MAX_DATE.year, (DATA_MAX_DATE.month - 1) // 3 + 1
    while (y, q) <= (end_y, end_q):
        quarters.append(f"Q{q} {y}")
        q += 1
        if q > 4:
            q = 1
            y += 1
    return quarters


TIME_PERIODS = RELATIVE_PERIODS + _quarters_in_window()

# ---------------------------------------------------------------------------
# Parameter pools -- from RETAIL_OPS_SV's actual enum dimensions
# (setup/02_create_semantic_view.sql SAMPLE_VALUES)
# ---------------------------------------------------------------------------
REGIONS = ["West", "Northeast", "Midwest", "South", "Southwest"]
STORE_TYPES = ["Urban", "Suburban", "Mall", "Outlet", "Rural"]
PERFORMANCE_TIERS = ["Flagship", "Average", "Underperforming"]
CATEGORIES = ["Apparel", "Electronics", "Home", "Food", "Beauty", "Sports", "Toys", "Office"]
SUBCATEGORIES = ["Premium", "Standard", "Value", "Economy"]
CHANNELS = ["Online", "In-Store"]
SHIFT_TYPES = ["Morning", "Afternoon", "Evening"]
RETURN_REASONS = ["Wrong Size", "Defective", "Changed Mind", "Not as Described", "Other"]

# Business-facing dimension names usable in "by <dimension>" phrasing, scoped
# to what each clause's logical table can actually group by.
REVENUE_DIMS = ["region", "store type", "category", "channel", "performance tier"]
TARGET_DIMS = ["region", "store type"]
TOP_N_CHOICES = [3, 5, 10]

STARTERS_PLAIN = ["Show me", "Show", "Pull up", "Give me", "I need to see", "I'd like to know"]
STARTERS_VARIED = ["Can you get me", "Can you show me", "Could you pull up", "Can you tell me about"]
MID_FRAMES = ["can you get me", "can you also show me", "what about", "can you also pull up"]
COMPARE_CONNECTORS = ["compared to", "versus", "against"]
COMPOUND_CONNECTORS = [
    "Also,", "Separately,", "In addition,", "One more thing —", "And can you also tell me:",
]


# ---------------------------------------------------------------------------
# Atomic clauses -- one per logical table, each a single self-contained ask.
# Each returns (question_text, logical_table_name).
# ---------------------------------------------------------------------------

def clause_revenue(rng: random.Random) -> tuple[str, str]:
    dim = rng.choice(REVENUE_DIMS)
    period = rng.choice(TIME_PERIODS)
    return f"revenue by {dim} for {period}", "daily_sales"


def clause_inventory(rng: random.Random) -> tuple[str, str]:
    region = rng.choice(REGIONS)
    return f"inventory alerts in the {region} region", "inventory"


def clause_targets(rng: random.Random) -> tuple[str, str]:
    dim = rng.choice(TARGET_DIMS)
    period = rng.choice(TIME_PERIODS)
    return f"target attainment by {dim} for {period}", "sales_targets"


def clause_staffing(rng: random.Random) -> tuple[str, str]:
    period = rng.choice(TIME_PERIODS)
    return f"staffing hours compared to revenue by store for {period}", "staff_shifts"


def clause_returns(rng: random.Random) -> tuple[str, str]:
    if rng.random() < 0.5:
        cat = rng.choice(CATEGORIES)
        return f"the return rate for {cat}", "returns"
    reason = rng.choice(RETURN_REASONS)
    return f"how many returns were due to '{reason.lower()}'", "returns"


def clause_products(rng: random.Random) -> tuple[str, str]:
    n = rng.choice(TOP_N_CHOICES)
    region = rng.choice(REGIONS)
    return f"the top {n} products by units sold in the {region} region", "products"


def clause_suppliers(rng: random.Random) -> tuple[str, str]:
    return "which suppliers have the longest average lead time", "products"


CLAUSES = [
    clause_revenue, clause_inventory, clause_targets,
    clause_staffing, clause_returns, clause_products, clause_suppliers,
]

# Clauses with a single dominant categorical slot, suitable for a comparative
# ("X vs Y") composition -- reuses the same clause fn with two draws.
COMPARABLE_CLAUSES = [clause_revenue, clause_inventory, clause_targets, clause_returns]

AMBIGUOUS_QUESTIONS = [
    "How are we doing?",
    "What's going on with sales?",
    "Tell me about the West region.",
    "Any issues I should know about?",
    "How's inventory looking?",
    "What about staffing?",
    "Give me an update.",
    "How's this quarter shaping up?",
    "What should I be worried about?",
    "Anything interesting in the data?",
]


def _capitalize(s: str) -> str:
    return s[0].upper() + s[1:] if s else s


# ---------------------------------------------------------------------------
# Tier assemblers
# ---------------------------------------------------------------------------

def _tier_simple(rng: random.Random) -> dict:
    clause_fn = rng.choice(CLAUSES)
    text, table = clause_fn(rng)
    if rng.random() < 0.5:
        question = f"{rng.choice(STARTERS_PLAIN)} {text}."
    else:
        question = f"{rng.choice(STARTERS_VARIED)} {text}?"
    return {
        "question": _capitalize(question),
        "tier": "simple",
        "expected_sql_calls": (1, 4),
        "clause_tables": [table],
        "followups": [],
    }


def _tier_medium(rng: random.Random) -> dict:
    clause_fn = rng.choice(CLAUSES)
    text, table = clause_fn(rng)
    question = f"{rng.choice(STARTERS_VARIED)} {text}?"
    return {
        "question": _capitalize(question),
        "tier": "medium",
        "expected_sql_calls": (3, 6),
        "clause_tables": [table],
        "followups": [],
    }


def _tier_comparative(rng: random.Random) -> dict:
    clause_fn = rng.choice(COMPARABLE_CLAUSES)
    text_a, table = clause_fn(rng)
    text_b, _ = clause_fn(rng)
    if text_b == text_a:  # avoid "X versus X" -- redraw once
        text_b, _ = clause_fn(rng)
    connector = rng.choice(COMPARE_CONNECTORS)
    question = f"{rng.choice(STARTERS_VARIED)} {text_a} {connector} {text_b}?"
    return {
        "question": _capitalize(question),
        "tier": "comparative",
        "expected_sql_calls": (4, 8),
        "clause_tables": [table],
        "followups": [],
    }


def _tier_compound(rng: random.Random) -> dict:
    n_clauses = rng.choice([2, 2, 3, 3, 4])  # bias toward 2-3, cap at 4 (context-window headroom)
    chosen = rng.sample(CLAUSES, k=n_clauses)
    parts = []
    tables = []
    for i, clause_fn in enumerate(chosen):
        text, table = clause_fn(rng)
        tables.append(table)
        if i == 0:
            parts.append(_capitalize(f"{rng.choice(STARTERS_PLAIN)} {text}."))
        else:
            connector = rng.choice(COMPOUND_CONNECTORS)
            if connector.endswith(":"):
                # This connector already reads as a full frame ("...tell me:") --
                # appending another frame doubles up ("tell me: can you also...").
                parts.append(f"{connector} {text}?")
            else:
                frame = rng.choice(MID_FRAMES)
                parts.append(f"{connector} {frame} {text}?")
    question = " ".join(parts)
    return {
        "question": question,
        "tier": "compound",
        "expected_sql_calls": (max(2, n_clauses), n_clauses * 3),
        "clause_tables": tables,
        "followups": [],
    }


def _tier_multi_turn(rng: random.Random) -> dict:
    n_followups = rng.choice([1, 1, 2, 3])
    base_fn = rng.choice(CLAUSES)
    base_text, base_table = base_fn(rng)
    base_question = _capitalize(f"{rng.choice(STARTERS_VARIED)} {base_text}?")

    followups = []
    tables = [base_table]
    remaining = [c for c in CLAUSES if c is not base_fn]
    for clause_fn in rng.sample(remaining, k=min(n_followups, len(remaining))):
        text, table = clause_fn(rng)
        tables.append(table)
        followups.append(_capitalize(f"{rng.choice(STARTERS_PLAIN)} {text}."))

    return {
        "question": base_question,
        "tier": "multi_turn",
        "expected_sql_calls": (2 + len(followups), 4 * (1 + len(followups))),
        "clause_tables": tables,
        "followups": followups,
    }


def _tier_ambiguous(rng: random.Random) -> dict:
    return {
        "question": rng.choice(AMBIGUOUS_QUESTIONS),
        "tier": "ambiguous",
        "expected_sql_calls": (0, 0),
        "clause_tables": [],
        "followups": [],
    }


TIER_ASSEMBLERS = {
    "simple": _tier_simple,
    "medium": _tier_medium,
    "comparative": _tier_comparative,
    "compound": _tier_compound,
    "multi_turn": _tier_multi_turn,
    "ambiguous": _tier_ambiguous,
}

TIER_WEIGHTS = {
    "simple": 0.05,
    "medium": 0.12,
    "comparative": 0.20,
    "compound": 0.45,
    "multi_turn": 0.15,
    "ambiguous": 0.03,
}


def generate_question(rng: random.Random | None = None) -> dict:
    """One generated question: {question, tier, expected_sql_calls, clause_tables, followups}."""
    rng = rng or random.Random()
    tier = rng.choices(list(TIER_WEIGHTS.keys()), weights=list(TIER_WEIGHTS.values()), k=1)[0]
    return TIER_ASSEMBLERS[tier](rng)


def generate_batch(n: int, seed: int | None = None) -> list[dict]:
    """n independently parameterized questions. Retries on exact-text duplicates."""
    rng = random.Random(seed)
    batch = []
    seen = set()
    attempts = 0
    while len(batch) < n and attempts < n * 20:
        attempts += 1
        q = generate_question(rng)
        if q["question"] in seen:
            continue
        seen.add(q["question"])
        batch.append(q)
    while len(batch) < n:  # pool exhausted at this n -- allow duplicates rather than hang
        batch.append(generate_question(rng))
    return batch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", type=int, default=20)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--json", action="store_true", help="print full JSON instead of a summary line")
    args = parser.parse_args()

    print(f"Data window: {DATA_MIN_DATE} .. {DATA_MAX_DATE} ({DATA_WINDOW_DAYS} days)")
    print(f"Time periods pool ({len(TIME_PERIODS)}): {TIME_PERIODS}\n")

    batch = generate_batch(args.sample, seed=args.seed)
    tier_counts: dict[str, int] = {}
    for q in batch:
        tier_counts[q["tier"]] = tier_counts.get(q["tier"], 0) + 1
        if args.json:
            print(json.dumps(q))
        else:
            lo, hi = q["expected_sql_calls"]
            fu = f" (+{len(q['followups'])} followups)" if q["followups"] else ""
            print(f"[{q['tier']:<11}] sql~{lo}-{hi}{fu}  {q['question']}")
            for f in q["followups"]:
                print(f"              -> {f}")

    print(f"\nTier distribution: {tier_counts}")


if __name__ == "__main__":
    main()
