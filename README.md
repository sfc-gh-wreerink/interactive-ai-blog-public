# Interactive AI Blog — Code Companion

Demonstrates a retail analytics Cortex Agent backed by Interactive Tables, an Interactive Warehouse, and a self-contained observability pipeline — all sharing the same compute layer.

## Prerequisites

- Snowflake account with Cortex Agent and Interactive Table access
- `snow` CLI or Snowsight for running SQL scripts
- Python 3.11+ for traffic simulation / latency testing

## Setup (run in order)

```
setup/01_create_raw_tables.sql        # Generate 25M rows of synthetic retail data
setup/02_create_semantic_view.sql     # Semantic View for the Cortex Agent
setup/03_create_interactive_tables.sql # Interactive Tables + Interactive Warehouse
setup/04_create_agent.sql             # Cortex Agent (RETAIL_OPS_AGENT)
setup/07_create_observability_pipeline.sql # Observability event pipeline
```

Optional zero-copy variant (eliminates the Interactive Table copy layer):

```
setup/08_create_semantic_view_raw.sql  # Semantic View over raw tables
setup/09_cluster_raw_tables.sql        # Add clustering to raw tables
setup/10_create_observability_mv.sql   # MV-based observability (fresher)
```

## Configuration

The setup/test scripts connect using a named profile from `~/.snowflake/connections.toml`. Set `SNOWFLAKE_CONNECTION_NAME` to your own profile name (defaults to `default`); the REST hostname is derived from that profile's `account` field automatically.

## Testing

```bash
SNOWFLAKE_CONNECTION_NAME=myconnection python setup/06_simulate_traffic.py --qps 5 --duration 60
SNOWFLAKE_CONNECTION_NAME=myconnection python setup/agent_latency_test.py --label baseline --rounds 20
```

## Streamlit Dashboard

Deploy the observability dashboard:

```bash
snow streamlit deploy --project-dir app/
```

## Structure

```
setup/    SQL scripts + Python test utilities (numbered execution order)
app/      Streamlit-in-Snowflake observability dashboard
```
