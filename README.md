# sql-recipes

Six SQL patterns I reach for on real data engineering work. Each file is a self-contained DuckDB script with synthetic data and a verification query, so you can run it without any setup beyond installing DuckDB.

## Why these patterns

These are the recipes I keep re-writing across projects. Pulling them out of client codebases and putting them in one place means I stop re-deriving them from scratch every time, and other people can copy them too.

| File | Pattern | Real-world use |
|---|---|---|
| `recipes/01_snapshot_resolution.sql` | Pick the latest version of each (entity, span) across snapshot files | Reconciling daily/monthly enrollment files where the supplier backfills corrections |
| `recipes/02_member_month_expansion.sql` | Expand date spans into per-month rows, omit gap months | Healthcare/insurance member-month rosters, subscription billing rosters |
| `recipes/03_idempotent_ingest.sql` | Content-hash dedup so re-running the same load is a no-op | Pollers, file drops, anything where the source can replay |
| `recipes/04_gaps_and_islands.sql` | Group consecutive runs of events into sessions or streaks | Login session reconstruction, contiguous activity windows, run-length analysis |
| `recipes/05_scd_type_2.sql` | Slowly Changing Dimension Type 2: keep history with valid_from / valid_to | Audit-friendly dimension tables, point-in-time joins |
| `recipes/06_window_essentials.sql` | The four window function patterns I use weekly | Running totals, rolling windows, ranking, lead/lag deltas |

## Run any recipe

Install DuckDB (or use the Python or CLI distribution):

```bash
brew install duckdb           # macOS
# or pip install duckdb       # Python
```

Then pipe a recipe straight to the CLI:

```bash
duckdb < recipes/01_snapshot_resolution.sql
```

Each file ends with a `SELECT` that prints the expected output so you can confirm the recipe works.

## Why DuckDB

DuckDB runs in-process, accepts the same window-function and CTE syntax as Postgres / Snowflake / BigQuery, and supports `READ_CSV` / `READ_PARQUET` directly, so the recipes translate cleanly to your warehouse with at most a few function-name swaps. Comments call out where the syntax differs.

## License

MIT
