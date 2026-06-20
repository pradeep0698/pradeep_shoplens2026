# Analyze API — performance test log

Measurements from the Postman collection in [`postman/`](../postman/),
using the fixed test image embedded in
`shoplens-analyze-perf.postman_collection.json`. One row per run; change
one thing between rows so the timing delta is attributable.

See [`postman/README.md`](../postman/README.md) for how to run a
measurement. See [`analyzePerfomanceImprovement.md`](analyzePerfomanceImprovement.md)
for the change candidates being tested (#1-#5).

**Environment note:** this machine has no local Application Default Credentials for
`shoplens-dev-499700` (Vertex AI / GCS / SerpAPI all need real cloud calls), so
`services/ai-analyzer` cannot run as a bare local process here. Each row below was
measured by deploying the exact code-under-test to the existing Cloud Run dev service
(`gcloud run deploy ai-analyzer --source services/ai-analyzer ...`, same env vars/
service account as the live revision) and running the collection against
`https://ai-analyzer-935092313069.us-central1.run.app` using the
`shoplens-dev-cloud` Postman environment (`postman/shoplens-dev-cloud.postman_environment.json`)
via `newman -n 5`. This is noisier than a local run (real network + shared Cloud Run
instance autoscaling) but exercises the real code path end-to-end.

## Log

| # | Date | Change under test | Model | time_ms (5 runs, median bolded) | items | products | warnings | notes |
|---|------|--------------------|-------|---------|-------|----------|----------|-------|
| 1 | 2026-06-20 | Baseline (no changes) | gemini-2.5-pro | 81056, 76654, **67691**, 51316, 43640 | 17-20 (median run: 20) | 5 (every run) | median run had 5 "no bounding box" warnings (non-fatal, Gemini omitted a box) | Deployed current `main` as-is to Cloud Run (revision `ai-analyzer-00005-89d`) before any perf changes. Item count varies run-to-run (Gemini detection isn't deterministic); product count is stable at 5 (capped by `max_searches`). |
| 2 | 2026-06-20 | #1 — `asyncio.to_thread` in `product-matcher`/`state-manager` | gemini-2.5-pro | **66701**, 53739, 67514 (3 runs) | 21-24 | 5 (every run) | none | `ai-analyzer` itself is unchanged by this fix (it already used `to_thread` correctly) — only `product-matcher`/`state-manager` were touched, and this single-request `/analyze`-only harness never calls them. As predicted in the improvement doc, time_ms is unchanged within noise vs. baseline (66701 vs 67691 median) — this fix's payoff is concurrency under parallel load, not measurable here. Deployed `product-matcher-00003-ms9` and `state-manager-00002-j2t`; both `/health` checks OK post-deploy. |

## How to add a row

1. Apply (or revert) exactly one change from `analyzePerfomanceImprovement.md`.
2. Restart `services/ai-analyzer` locally.
3. Run the collection per `postman/README.md`, ideally 3-5 times, and take the median `time_ms`.
4. Append a row with the change description, model in use, median time, and the item/product/warning counts (to confirm output didn't regress, not just got faster).
