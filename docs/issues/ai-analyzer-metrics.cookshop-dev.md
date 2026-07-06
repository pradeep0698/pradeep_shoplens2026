# ai-analyzer Performance Metrics (cookshop-dev)

Platform: **cookshop-dev** (Rajan's weekly-release prod — see the `shoplens2026-dev`
counterpart at `docs/issues/ai-analyzer-metrics.shoplens2026-dev.md` for active dev).

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`) from Cloud Run `TIMING` log lines for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=cookshop-dev-prj

This doc has two tables: an overall **Summary** (one row per endpoint, recomputed from all samples currently in the detail table below) and a single **All Samples** table merging every sample across all three endpoints (`analyze`, `analyze/stream`, `identify`), sorted newest-first.

Each sample gets a permanent `#` id assigned in chronological order (oldest = 1) the first time it's written — ids never change or get reused, so you can always refer back to a row by its number even after newer rows are prepended above it. New samples get the next id after the current max and are prepended at the top. Each endpoint still keeps a rolling window of its most recent 100 completed requests — once an endpoint exceeds that, its oldest rows drop out of the table (leaving a gap in the id sequence), but surviving rows keep their original ids.

Timestamps are US Central Time (source Cloud Run logs are UTC; converted at UTC-5 CDT for these dates — adjust to UTC-6 CST for entries falling in the Nov-Mar standard-time window).

Last updated: 2026-07-06T10:44:37 CDT — no new log entries

## Summary (from current samples below)

| Endpoint | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| `analyze` | 0 | - | - | - | - | - |
| `analyze/stream` | 0 | - | - | - | - | - |
| `identify` | 0 | - | - | - | - | - |

## Analysis

_No samples yet — analysis will be filled in once the first batch lands._

## All Samples (newest first)

| # | API | Time (Central) | req | Duration | Breakdown | Notes |
|---|---|---|---|---|---|---|
