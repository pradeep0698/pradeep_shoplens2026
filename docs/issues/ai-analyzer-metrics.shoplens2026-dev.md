# ai-analyzer Performance Metrics (shoplens2026-dev)

Platform: **shoplens2026-dev** (active dev — see the `cookshop-dev` counterpart at
`docs/issues/ai-analyzer-metrics.cookshop-dev.md` for Rajan's weekly-release prod).

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`) from Cloud Run `TIMING` log lines for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7

This doc has two tables: an overall **Summary** (one row per endpoint, recomputed from all samples currently in the detail table below) and a single **All Samples** table merging every sample across all three endpoints (`analyze`, `analyze/stream`, `identify`), sorted newest-first.

Each sample gets a permanent `#` id assigned in chronological order (oldest = 1) the first time it's written — ids never change or get reused, so you can always refer back to a row by its number even after newer rows are prepended above it. New samples get the next id after the current max and are prepended at the top. Each endpoint still keeps a rolling window of its most recent 100 completed requests — once an endpoint exceeds that, its oldest rows drop out of the table (leaving a gap in the id sequence), but surviving rows keep their original ids.

Timestamps are US Central Time (source Cloud Run logs are UTC; converted at UTC-5 CDT for these dates — adjust to UTC-6 CST for entries falling in the Nov-Mar standard-time window).

Last updated: 2026-07-07T21:16:30 CDT — +18 analyze/stream, +11 identify samples

## Summary (from current samples below)

| Endpoint | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| `analyze` | 62 | 1.05s | 8.08s | 54.54s | 59.93s | 17.15s |
| `analyze/stream` | 76 | 1.62s | 23.07s | 58.70s | 101.70s | 26.53s |
| `identify` | 68 | 0.33s | 17.01s | 46.61s | 78.76s | 18.37s |

## Analysis

- **`analyze`** is bimodal: most calls (`items=0`) are Postman placeholder smoke-tests — Gemini runs but finds nothing, so `items_phase` is 0 by design and total latency is just Gemini's 1-14s response time. A separate `n=20` perf-test burst (`items=5`, documented in `docs/analyze-perf-test-results.md`) against a real product photo drives the 20-60s tail — both Gemini detection and real Lens/Shopping search work are slow there. No new `analyze` (non-stream) samples this run.
- **`analyze/stream`** samples are almost all real 1-2 item detections (the live-scan flow, plus the gallery-image-upload "Scan Image" flow, which also calls this same endpoint), where `items_phase` (concurrent Lens/Shopping search per item) typically accounts for 40-75% of total latency — this is the dominant cost, not Gemini. A handful of `items=0` rows are fast health-check pings. New sample `#178` (req `6c0f6f1a`, 101.70s) is the new max for this endpoint, driven by a slow `items_phase` (68.34s) across 2 items — not itself an error, just a slow real search.
- **`identify`** splits into three regimes: (1) calls with `shopping=0.0s` resolve via Lens alone, with latency scaling directly with Lens response time (anywhere from <1s to 60s+); (2) a large recurring cluster has `lens` pinned almost exactly to ~12.0-12.1s with `shopping` varying 1.6-10.0s — consistent with a fixed test fixture/image hitting both steps; (3) two separate requests (`#113`, `#111`) both hit `lens=60.1s` exactly, paired with a capped `shopping=10.0s` — the repeated identical value across two different requests suggests a ~60s timeout ceiling on the Lens call rather than organic slowness. Worth flagging if `lens=60.1s` recurs. Starting 2026-07-04T19:35 UTC (`#142` onward), the Lens/Gemini/Shopping hedge shipped (see `ecdae19`). Contrary to the previous note here, the hedge **has now started triggering** — this run added several `hedge_triggered=True` samples (`#179`, `#180`, `#190`, `#203`), all with `gemini>0` and `shopping=0.0s`, i.e. Lens ran past the hedge window so Gemini kicked in but still beat Shopping to an answer. None have hit `quota_exhausted=True` yet — worth watching once one does. This tail is also why `identify`'s `p95` jumped from 29.74s to 46.61s this run.

## All Samples (newest first)

| # | API | Time (Central) | req | Duration | Breakdown | Notes |
|---|---|---|---|---|---|---|
| 206 | `identify` | 2026-07-07 21:16:30 | `0dce4811` | 4.41s | upload=0.10s lens=4.31s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 205 | `analyze/stream` | 2026-07-07 21:15:50 | `d2231118` | 49.89s | gemini=5.08s items_phase=44.81s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 204 | `analyze/stream` | 2026-07-07 21:02:11 | `c6d93b03` | 38.15s | gemini=10.27s items_phase=27.88s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 203 | `identify` | 2026-07-07 20:47:56 | `fb5526cb` | 31.67s | upload=0.08s lens=31.58s gemini=2.39s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 202 | `analyze/stream` | 2026-07-07 20:45:33 | `1f7fff15` | 5.71s | gemini=5.71s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 201 | `analyze/stream` | 2026-07-07 20:45:15 | `c3ebf274` | 34.23s | gemini=15.37s items_phase=18.85s items=5 | Five items detected — items_phase covers concurrent Lens/Shopping search for all five |
| 200 | `identify` | 2026-07-07 20:45:08 | `711fc5bc` | 13.06s | upload=0.09s lens=12.96s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 199 | `analyze/stream` | 2026-07-07 20:44:47 | `502e542a` | 3.35s | gemini=3.35s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 198 | `analyze/stream` | 2026-07-07 20:44:10 | `fce0fec1` | 3.41s | gemini=3.41s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 197 | `analyze/stream` | 2026-07-07 20:43:51 | `41ac74a0` | 5.19s | gemini=5.18s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 196 | `analyze/stream` | 2026-07-07 20:43:37 | `5561fb01` | 22.37s | gemini=7.84s items_phase=14.52s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 195 | `identify` | 2026-07-07 20:43:32 | `25a0e9d7` | 18.15s | upload=0.09s lens=18.05s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 194 | `analyze/stream` | 2026-07-07 20:42:53 | `3b5af935` | 44.09s | gemini=29.30s items_phase=14.79s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 193 | `analyze/stream` | 2026-07-07 20:42:47 | `35b8c8e7` | 30.46s | gemini=14.52s items_phase=15.94s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 192 | `identify` | 2026-07-07 20:41:40 | `3349eef8` | 6.68s | upload=0.07s lens=6.60s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 191 | `analyze/stream` | 2026-07-07 20:41:33 | `fa65aa0d` | 2.26s | gemini=2.25s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 190 | `identify` | 2026-07-07 20:40:49 | `01e69734` | 42.67s | upload=0.09s lens=42.58s gemini=2.63s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 189 | `identify` | 2026-07-07 20:40:16 | `1462f5ff` | 10.61s | upload=0.08s lens=10.52s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 188 | `analyze/stream` | 2026-07-07 20:39:58 | `6137dc79` | 4.60s | gemini=4.60s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 187 | `analyze/stream` | 2026-07-07 20:39:44 | `c56757ed` | 3.27s | gemini=3.27s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 186 | `analyze/stream` | 2026-07-07 20:39:29 | `6cef4857` | 3.38s | gemini=3.38s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 185 | `identify` | 2026-07-07 20:37:50 | `acbdbe2b` | 6.80s | upload=0.13s lens=6.66s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 184 | `analyze/stream` | 2026-07-07 20:37:14 | `4406abce` | 32.17s | gemini=12.25s items_phase=19.91s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 183 | `identify` | 2026-07-07 20:36:21 | `3b946ff8` | 17.13s | upload=0.15s lens=16.98s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 182 | `analyze/stream` | 2026-07-07 20:32:54 | `3d9a8d76` | 23.88s | gemini=8.13s items_phase=15.75s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 181 | `analyze/stream` | 2026-07-07 20:29:23 | `06812dbb` | 23.07s | gemini=9.35s items_phase=13.71s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 180 | `identify` | 2026-07-07 20:25:34 | `5a6075f4` | 40.65s | upload=0.24s lens=40.27s gemini=4.93s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 179 | `identify` | 2026-07-06 12:17:28 | `96d84237` | 46.61s | upload=0.13s lens=46.48s gemini=3.46s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 178 | `analyze/stream` | 2026-07-06 12:13:54 | `6c0f6f1a` | 101.70s | gemini=32.92s items_phase=68.34s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both — new max for this endpoint |
| 177 | `analyze` | 2026-07-05 20:25:43 | `4bc0932e` | 7.85s | gemini=7.19s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 176 | `identify` | 2026-07-05 20:25:22 | `fd414190` | 16.85s | upload=0.16s lens=16.69s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 175 | `analyze/stream` | 2026-07-05 20:25:05 | `cc86b71f` | 9.24s | gemini=8.57s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 174 | `analyze` | 2026-07-05 20:24:53 | `12b0d071` | 2.48s | gemini=2.47s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 173 | `analyze` | 2026-07-05 20:24:51 | `d7de2088` | 11.01s | gemini=10.04s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 172 | `analyze/stream` | 2026-07-04 20:22:41 | `24a6e3cb` | 14.71s | gemini=6.31s items_phase=8.02s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 171 | `analyze/stream` | 2026-07-04 20:05:50 | `b83ce67f` | 38.50s | gemini=27.47s items_phase=11.03s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 170 | `analyze/stream` | 2026-07-04 20:04:55 | `b2789705` | 33.34s | gemini=25.62s items_phase=7.72s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 169 | `identify` | 2026-07-04 20:04:00 | `5415309b` | 3.86s | upload=0.13s lens=3.73s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 168 | `analyze` | 2026-07-04 19:57:07 | `a9024e72` | 6.80s | gemini=6.16s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 167 | `identify` | 2026-07-04 19:56:55 | `fc25c64a` | 12.72s | upload=0.15s lens=12.56s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 166 | `analyze/stream` | 2026-07-04 19:56:42 | `9e5c207b` | 8.90s | gemini=8.22s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 165 | `analyze` | 2026-07-04 19:56:31 | `5b4ff242` | 2.58s | gemini=2.58s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 164 | `analyze` | 2026-07-04 19:56:28 | `5fdcc3b2` | 8.85s | gemini=8.21s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 163 | `analyze` | 2026-07-04 19:54:56 | `a8172037` | 7.42s | gemini=6.71s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 162 | `analyze` | 2026-07-04 19:09:32 | `fb2a5538` | 8.48s | gemini=7.87s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 161 | `analyze/stream` | 2026-07-04 19:09:21 | `4a4df8f9` | 9.18s | gemini=8.53s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 160 | `analyze` | 2026-07-04 19:09:10 | `a527735f` | 1.65s | gemini=1.65s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 159 | `analyze` | 2026-07-04 19:09:08 | `157c017f` | 10.22s | gemini=9.56s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 158 | `analyze` | 2026-07-04 19:07:10 | `d54db56b` | 10.88s | gemini=10.26s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 157 | `analyze` | 2026-07-04 19:04:52 | `7f14c24b` | 5.92s | gemini=5.27s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 156 | `analyze/stream` | 2026-07-04 19:04:39 | `7c76a579` | 12.52s | gemini=11.89s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 155 | `analyze` | 2026-07-04 19:04:24 | `0e8f6098` | 1.73s | gemini=1.73s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 154 | `analyze` | 2026-07-04 19:04:22 | `93fa40cb` | 9.82s | gemini=9.16s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 153 | `identify` | 2026-07-04 18:59:15 | `735a892e` | 18.06s | upload=0.10s lens=17.95s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 152 | `analyze/stream` | 2026-07-04 18:58:45 | `c0e605fa` | 6.63s | gemini=5.99s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 151 | `analyze` | 2026-07-04 18:57:39 | `d9c6275d` | 2.10s | gemini=2.10s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 150 | `analyze` | 2026-07-04 18:57:28 | `2fd3c914` | 9.32s | gemini=8.68s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 149 | `analyze` | 2026-07-04 18:48:48 | `b2afa084` | 3.06s | gemini=3.06s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 148 | `analyze` | 2026-07-04 18:46:26 | `17686854` | 1.58s | gemini=1.58s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 147 | `identify` | 2026-07-04 18:46:26 | `16dee318` | 7.84s | upload=0.14s lens=7.69s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 146 | `analyze` | 2026-07-04 18:46:14 | `9c5b2065` | 10.43s | gemini=9.56s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 145 | `identify` | 2026-07-04 15:29:32 | `d564a8f6` | 5.78s | upload=0.10s lens=5.66s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 144 | `identify` | 2026-07-04 15:29:10 | `51fc03cf` | 12.39s | upload=0.24s lens=12.09s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 143 | `identify` | 2026-07-04 14:55:18 | `f0f20901` | 9.55s | upload=0.20s lens=9.28s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 142 | `identify` | 2026-07-04 14:35:22 | `55180956` | 6.97s | upload=0.25s lens=6.65s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 141 | `analyze/stream` | 2026-07-04 13:24:27 | `f9cabfe0` | 58.70s | gemini=9.90s items_phase=48.80s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 140 | `analyze/stream` | 2026-07-04 13:22:55 | `c5c19ee8` | 22.93s | gemini=8.28s items_phase=14.18s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 139 | `analyze/stream` | 2026-07-04 07:46:13 | `46b976c7` | 13.70s | gemini=6.49s items_phase=7.22s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 138 | `identify` | 2026-07-04 07:45:40 | `45dd9829` | 4.06s | describe_and_upload=0.08s lens=3.96s shopping=0.00s | No Shopping search triggered — resolved via Lens alone |
| 137 | `analyze/stream` | 2026-07-04 07:44:45 | `8d75ee12` | 20.98s | gemini=4.88s items_phase=16.10s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 136 | `identify` | 2026-07-04 07:40:08 | `1fcb1045` | 12.53s | describe_and_upload=0.08s lens=12.44s shopping=0.00s | No Shopping search triggered — resolved via Lens alone |
| 135 | `analyze/stream` | 2026-07-04 07:39:02 | `a8b10208` | 11.61s | gemini=5.67s items_phase=5.60s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 134 | `identify` | 2026-07-04 07:36:35 | `3a2ae041` | 4.53s | describe_and_upload=0.28s lens=4.12s shopping=0.00s | No Shopping search triggered — resolved via Lens alone |
| 133 | `identify` | 2026-07-04 06:05:47 | `6488662f` | 14.31s | describe_and_upload=0.11s lens=14.19s shopping=0.00s | No Shopping search triggered — resolved via Lens alone |
| 132 | `identify` | 2026-07-04 05:51:16 | `b4b5263f` | 24.16s | describe_and_upload=0.22s lens=23.91s shopping=0.00s | No Shopping search triggered — resolved via Lens alone |
| 131 | `analyze/stream` | 2026-07-04 05:50:06 | `97909e86` | 12.31s | gemini=11.78s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 130 | `identify` | 2026-07-03 21:20:34 | `07fb1a9e` | 26.70s | describe_and_upload=0.3s lens=26.3s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 129 | `analyze/stream` | 2026-07-03 20:58:51 | `aa950043` | 78.47s | gemini=14.2s items_phase=63.8s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 128 | `analyze/stream` | 2026-07-03 19:19:07 | `9694ed68` | 92.70s | gemini=22.4s items_phase=70.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 127 | `analyze/stream` | 2026-07-03 19:06:31 | `987034d6` | 34.07s | gemini=7.2s items_phase=26.8s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 126 | `analyze/stream` | 2026-07-03 19:01:18 | `ba104fdc` | 50.38s | gemini=18.3s items_phase=31.7s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 125 | `analyze` | 2026-07-03 18:52:07 | `961f8b7c` | 7.74s | gemini=7.0s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 124 | `analyze/stream` | 2026-07-03 18:47:19 | `f960bf1f` | 93.38s | gemini=22.8s items_phase=70.5s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 123 | `analyze` | 2026-07-03 18:45:07 | `25330be5` | 13.90s | gemini=12.8s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 122 | `analyze/stream` | 2026-07-03 18:28:40 | `48346858` | 57.92s | gemini=16.7s items_phase=41.1s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 121 | `analyze` | 2026-07-03 18:28:35 | `03f0c8d7` | 13.94s | gemini=13.3s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 120 | `analyze` | 2026-07-03 18:27:17 | `050c3864` | 4.07s | gemini=3.4s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 119 | `identify` | 2026-07-03 18:26:43 | `d4aa580a` | 49.00s | describe_and_upload=0.1s lens=48.9s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 118 | `analyze/stream` | 2026-07-03 18:25:54 | `bf6f5c7c` | 5.83s | gemini=5.1s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 117 | `analyze` | 2026-07-03 18:25:46 | `e5b60ebf` | 1.09s | gemini=1.1s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 116 | `analyze` | 2026-07-03 18:25:45 | `554c0d20` | 3.17s | gemini=2.2s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 115 | `identify` | 2026-07-03 18:25:09 | `4d109e2c` | 19.07s | describe_and_upload=0.2s lens=18.6s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 114 | `analyze` | 2026-07-03 18:06:29 | `12122af4` | 4.33s | gemini=3.6s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 113 | `identify` | 2026-07-03 17:46:03 | `0840d923` | 72.98s | describe_and_upload=2.7s lens=60.1s shopping=10.0s | Lens hit a ~60s ceiling — worth watching if this recurs (possible timeout cap) |
| 112 | `analyze` | 2026-07-03 17:43:41 | `77e60e4f` | 5.46s | gemini=4.8s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 111 | `identify` | 2026-07-03 17:40:58 | `d68a4205` | 78.76s | describe_and_upload=8.6s lens=60.1s shopping=10.0s | Lens hit a ~60s ceiling — worth watching if this recurs (possible timeout cap) |
| 110 | `analyze/stream` | 2026-07-03 17:39:39 | `bc96c033` | 1.89s | gemini=1.6s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 109 | `analyze` | 2026-07-03 17:39:35 | `09efa69b` | 2.01s | gemini=2.0s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 108 | `analyze` | 2026-07-03 17:39:33 | `4f230ff4` | 4.22s | gemini=3.1s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 107 | `identify` | 2026-07-03 13:33:24 | `c4f73d41` | 21.03s | describe_and_upload=3.5s lens=12.1s shopping=5.3s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 5.3s |
| 106 | `identify` | 2026-07-03 13:21:22 | `11b72056` | 26.32s | describe_and_upload=4.1s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 105 | `identify` | 2026-07-03 13:08:07 | `b5e7b770` | 24.92s | describe_and_upload=2.7s lens=12.0s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 104 | `identify` | 2026-07-03 13:04:47 | `c0537b6a` | 5.52s | describe_and_upload=0.1s lens=5.4s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 103 | `identify` | 2026-07-03 13:02:33 | `51388a20` | 28.00s | describe_and_upload=4.8s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 102 | `analyze/stream` | 2026-07-03 12:08:43 | `5480350a` | 41.37s | gemini=18.9s items_phase=22.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 101 | `identify` | 2026-07-03 12:04:16 | `3b838276` | 25.88s | describe_and_upload=4.8s lens=12.1s shopping=8.7s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 8.7s |
| 100 | `analyze/stream` | 2026-07-03 11:45:09 | `84b5e898` | 1.79s | gemini=1.6s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 99 | `analyze` | 2026-07-03 11:45:05 | `e316bc87` | 2.41s | gemini=2.4s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 98 | `analyze` | 2026-07-03 11:45:03 | `e324ee00` | 4.59s | gemini=4.0s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 97 | `analyze/stream` | 2026-07-03 11:40:06 | `8d9e5757` | 1.98s | gemini=1.8s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 96 | `analyze` | 2026-07-03 11:40:02 | `9a3d7ef0` | 1.05s | gemini=1.1s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 95 | `analyze` | 2026-07-03 11:40:01 | `120ef7d4` | 3.34s | gemini=2.8s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 94 | `analyze/stream` | 2026-07-03 11:39:33 | `aad881bb` | 28.85s | gemini=6.6s items_phase=22.2s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 93 | `analyze/stream` | 2026-07-03 11:38:39 | `f9b43981` | 26.78s | gemini=4.5s items_phase=22.2s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 92 | `identify` | 2026-07-03 11:34:08 | `830f856a` | 29.74s | describe_and_upload=7.5s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 91 | `analyze/stream` | 2026-07-03 11:33:38 | `544215af` | 1.68s | gemini=1.5s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 90 | `analyze` | 2026-07-03 11:33:34 | `bfa61cbd` | 2.26s | gemini=2.3s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 89 | `analyze` | 2026-07-03 11:33:32 | `ef87d8cf` | 8.08s | gemini=7.5s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 88 | `identify` | 2026-07-03 11:22:31 | `b6101303` | 17.01s | describe_and_upload=2.8s lens=12.0s shopping=2.1s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 2.1s |
| 87 | `identify` | 2026-07-03 11:20:04 | `434ee437` | 21.89s | describe_and_upload=3.5s lens=12.1s shopping=6.2s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 6.2s |
| 86 | `analyze/stream` | 2026-07-03 11:05:14 | `934df1ec` | 36.84s | gemini=14.6s items_phase=22.2s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 85 | `analyze/stream` | 2026-07-03 11:05:11 | `933abcb1` | 25.17s | gemini=2.8s items_phase=22.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 84 | `analyze` | 2026-07-03 10:59:09 | `d2535af2` | 8.42s | gemini=7.7s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 83 | `analyze/stream` | 2026-07-03 10:57:48 | `a99c6a3b` | 39.64s | gemini=16.9s items_phase=22.4s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 82 | `analyze/stream` | 2026-07-03 10:40:36 | `ab17468d` | 8.18s | gemini=7.8s items_phase=0.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 81 | `analyze/stream` | 2026-07-03 10:40:05 | `9c0bbdf8` | 14.32s | gemini=14.0s items_phase=0.3s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 80 | `analyze` | 2026-07-03 10:34:24 | `d3314f36` | 1.85s | gemini=1.7s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 79 | `identify` | 2026-07-03 10:20:36 | `ab514135` | 0.36s | describe_and_upload=0.2s lens=0.1s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 78 | `analyze/stream` | 2026-07-03 10:20:35 | `73ef16f9` | 1.62s | gemini=1.4s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 77 | `analyze` | 2026-07-03 10:20:31 | `9092583d` | 2.05s | gemini=2.0s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 76 | `analyze` | 2026-07-03 10:20:29 | `68d641f4` | 2.47s | gemini=1.8s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 75 | `identify` | 2026-07-03 09:52:45 | `55a8cea9` | 0.33s | describe_and_upload=0.2s lens=0.1s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 74 | `analyze/stream` | 2026-07-03 09:52:44 | `65803738` | 9.62s | gemini=9.4s items_phase=0.0s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 73 | `analyze` | 2026-07-03 09:52:32 | `8aafbc53` | 2.08s | gemini=2.1s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 72 | `analyze` | 2026-07-03 09:52:30 | `22a56df4` | 3.89s | gemini=3.3s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 71 | `analyze` | 2026-07-03 07:21:36 | `46ab547b` | 55.28s | gemini=54.9s items_phase=0.3s items=5 | n=20 perf-test burst, real image — this run's Gemini call itself was the slow part |
| 70 | `analyze` | 2026-07-03 07:20:40 | `dc8385a0` | 25.35s | gemini=25.0s items_phase=0.3s items=5 | n=20 perf-test burst, real image |
| 69 | `analyze` | 2026-07-03 07:20:14 | `ffe60d6c` | 40.59s | gemini=40.2s items_phase=0.3s items=5 | n=20 perf-test burst, real image — slow Gemini call |
| 68 | `analyze` | 2026-07-03 07:19:34 | `27045ff2` | 23.84s | gemini=23.5s items_phase=0.3s items=5 | n=20 perf-test burst, real image |
| 67 | `analyze` | 2026-07-03 07:19:10 | `570ca8ed` | 8.35s | gemini=8.0s items_phase=0.4s items=5 | n=20 perf-test burst, real image |
| 66 | `analyze` | 2026-07-03 07:19:01 | `d1b111af` | 27.27s | gemini=26.9s items_phase=0.3s items=5 | n=20 perf-test burst, real image |
| 65 | `analyze` | 2026-07-03 07:18:33 | `2b99ebe7` | 46.02s | gemini=45.7s items_phase=0.3s items=5 | n=20 perf-test burst, real image — slow Gemini call |
| 64 | `analyze` | 2026-07-03 07:17:46 | `47551710` | 43.20s | gemini=30.9s items_phase=12.3s items=5 | n=20 perf-test burst, real image — real Lens/Shopping search work in items_phase |
| 63 | `analyze` | 2026-07-03 07:17:03 | `cda2ce0e` | 49.10s | gemini=26.8s items_phase=22.3s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 62 | `analyze` | 2026-07-03 07:16:14 | `b537251a` | 42.77s | gemini=26.0s items_phase=16.8s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 61 | `analyze` | 2026-07-03 07:15:31 | `0143ce80` | 56.26s | gemini=33.9s items_phase=22.3s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 60 | `analyze` | 2026-07-03 07:14:03 | `e6839fd4` | 54.54s | gemini=32.2s items_phase=22.3s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 59 | `analyze` | 2026-07-03 07:13:08 | `1145916c` | 51.93s | gemini=29.6s items_phase=22.3s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 58 | `analyze` | 2026-07-03 07:12:16 | `8c4a283d` | 37.88s | gemini=15.6s items_phase=22.2s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 57 | `analyze` | 2026-07-03 07:11:38 | `13c6482f` | 43.77s | gemini=25.9s items_phase=17.8s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 56 | `analyze` | 2026-07-03 07:10:54 | `aa9095d2` | 49.33s | gemini=27.1s items_phase=22.2s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 55 | `analyze` | 2026-07-03 07:10:04 | `a9551e6d` | 35.54s | gemini=13.3s items_phase=22.3s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 54 | `analyze` | 2026-07-03 07:09:28 | `2342bb5f` | 46.03s | gemini=25.3s items_phase=20.8s items=5 | n=20 perf-test burst, real image — real search work in items_phase |
| 53 | `analyze` | 2026-07-03 07:08:42 | `689961d9` | 59.93s | gemini=37.1s items_phase=22.4s items=5 | n=20 perf-test burst, real image — slowest run this window (both gemini and items_phase high) |
| 52 | `identify` | 2026-07-03 07:07:15 | `ffd7e352` | 10.69s | describe_and_upload=0.1s lens=10.6s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 51 | `identify` | 2026-07-03 07:07:04 | `27006dc8` | 24.44s | describe_and_upload=2.2s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 50 | `identify` | 2026-07-03 07:06:39 | `85cd8853` | 25.07s | describe_and_upload=2.9s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 49 | `identify` | 2026-07-03 07:06:14 | `69e0e541` | 25.70s | describe_and_upload=3.6s lens=12.0s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 48 | `identify` | 2026-07-03 07:05:48 | `8002b694` | 17.23s | describe_and_upload=3.4s lens=12.0s shopping=1.7s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 1.7s |
| 47 | `identify` | 2026-07-03 07:05:31 | `42a5b9db` | 19.67s | describe_and_upload=2.5s lens=12.0s shopping=5.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 5.0s |
| 46 | `identify` | 2026-07-03 07:05:11 | `07cb7eca` | 7.46s | describe_and_upload=0.1s lens=7.4s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 45 | `identify` | 2026-07-03 07:05:04 | `a219a980` | 24.35s | describe_and_upload=2.2s lens=12.0s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 44 | `identify` | 2026-07-03 07:04:39 | `78090dfe` | 4.36s | describe_and_upload=0.1s lens=4.3s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 43 | `identify` | 2026-07-03 07:04:35 | `b8a29827` | 23.20s | describe_and_upload=2.5s lens=12.0s shopping=8.6s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 8.6s |
| 42 | `identify` | 2026-07-03 07:04:12 | `9f977fee` | 11.40s | describe_and_upload=0.1s lens=11.3s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 41 | `identify` | 2026-07-03 07:04:00 | `f9c84827` | 12.08s | describe_and_upload=0.1s lens=12.0s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 40 | `identify` | 2026-07-03 07:03:48 | `10d3e0ed` | 4.88s | describe_and_upload=0.1s lens=4.8s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 39 | `identify` | 2026-07-03 07:03:43 | `22eda1ab` | 10.85s | describe_and_upload=0.1s lens=10.8s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 38 | `identify` | 2026-07-03 07:03:32 | `d0e6647c` | 26.36s | describe_and_upload=4.2s lens=12.0s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 37 | `identify` | 2026-07-03 07:03:06 | `40fdcc90` | 19.16s | describe_and_upload=1.7s lens=12.0s shopping=5.3s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 5.3s |
| 36 | `identify` | 2026-07-03 07:02:46 | `70d0a20f` | 22.78s | describe_and_upload=2.8s lens=12.0s shopping=7.9s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 7.9s |
| 35 | `identify` | 2026-07-03 07:02:23 | `d5177539` | 17.52s | describe_and_upload=3.7s lens=12.1s shopping=1.6s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 1.6s |
| 34 | `identify` | 2026-07-03 07:02:06 | `e8fbb54f` | 23.91s | describe_and_upload=1.8s lens=12.0s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 33 | `identify` | 2026-07-03 06:59:34 | `b8fdcfd6` | 8.11s | describe_and_upload=0.1s lens=8.0s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 32 | `identify` | 2026-07-03 06:57:58 | `b313d530` | 29.05s | describe_and_upload=6.7s lens=12.1s shopping=10.0s | Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping search ran 10.0s |
| 31 | `analyze/stream` | 2026-07-02 23:53:48 | `4f2f99e1` | 38.36s | gemini=16.9s items_phase=21.4s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 30 | `analyze/stream` | 2026-07-02 23:47:35 | `3f859e1f` | 53.37s | gemini=30.8s items_phase=22.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 29 | `identify` | 2026-07-02 23:39:52 | `65b84cd2` | 2.99s | describe_and_upload=0.1s lens=2.8s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 28 | `identify` | 2026-07-02 23:25:18 | `b14b6313` | 8.24s | describe_and_upload=0.1s lens=8.1s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 27 | `identify` | 2026-07-02 23:24:58 | `ee8e829d` | 11.68s | describe_and_upload=0.1s lens=11.6s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 26 | `identify` | 2026-07-02 23:24:24 | `2ba0e704` | 2.81s | describe_and_upload=0.2s lens=2.4s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 25 | `analyze/stream` | 2026-07-02 20:05:46 | `8c4718e1` | 27.03s | gemini=5.4s items_phase=21.6s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 24 | `analyze/stream` | 2026-07-02 20:04:42 | `2e1832f9` | 20.56s | gemini=8.9s items_phase=11.6s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 23 | `analyze/stream` | 2026-07-02 20:03:38 | `c8367619` | 33.10s | gemini=16.4s items_phase=15.7s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 22 | `identify` | 2026-07-02 19:05:09 | `d79f9c43` | 5.63s | describe_and_upload=0.1s lens=5.5s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
| 21 | `analyze` | 2026-07-02 19:05:03 | `28627c0f` | 37.72s | gemini=16.4s items_phase=21.1s items=5 | Isolated real-image call (same fixture as the burst above, run separately — not part of the documented n=20) |
| 20 | `analyze` | 2026-07-02 18:15:28 | `8bacaa83` | 4.23s | gemini=4.1s items_phase=0.0s items=0 | Placeholder smoke-test image — no items to search, by design |
| 19 | `analyze/stream` | 2026-07-02 18:01:10 | `41275a51` | 30.02s | gemini=7.9s items_phase=22.1s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 18 | `analyze/stream` | 2026-07-02 18:00:22 | `b464f151` | 21.33s | gemini=13.2s items_phase=8.1s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 17 | `analyze/stream` | 2026-07-02 17:59:54 | `9ee730db` | 25.98s | gemini=3.8s items_phase=22.1s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 16 | `analyze/stream` | 2026-07-02 17:59:21 | `56663ed8` | 17.74s | gemini=8.5s items_phase=9.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 15 | `analyze/stream` | 2026-07-02 17:58:52 | `5255419e` | 27.18s | gemini=15.4s items_phase=11.8s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 14 | `analyze/stream` | 2026-07-02 17:58:20 | `ac818a48` | 41.46s | gemini=24.9s items_phase=16.5s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 13 | `analyze/stream` | 2026-07-02 17:57:29 | `f64b7753` | 22.82s | gemini=12.4s items_phase=10.4s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 12 | `analyze/stream` | 2026-07-02 17:53:11 | `d7737020` | 36.63s | gemini=19.2s items_phase=17.4s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 11 | `analyze/stream` | 2026-07-02 17:52:42 | `96fbd811` | 44.96s | gemini=23.6s items_phase=20.5s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 10 | `analyze/stream` | 2026-07-02 17:52:27 | `66061bec` | 29.63s | gemini=12.4s items_phase=16.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 9 | `analyze/stream` | 2026-07-01 21:49:48 | `75b994b7` | 33.62s | gemini=21.4s items_phase=12.2s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 8 | `analyze/stream` | 2026-07-01 21:49:01 | `71a18548` | 16.79s | gemini=8.8s items_phase=8.0s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 7 | `analyze/stream` | 2026-07-01 21:48:15 | `9156f7ff` | 25.17s | gemini=11.0s items_phase=14.2s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 6 | `analyze/stream` | 2026-07-01 21:42:58 | `f29c204e` | 32.71s | gemini=10.4s items_phase=22.3s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 5 | `analyze/stream` | 2026-07-01 21:35:50 | `26df5f82` | 20.65s | gemini=9.8s items_phase=10.4s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 4 | `analyze/stream` | 2026-07-01 21:34:25 | `63a663d3` | 18.42s | gemini=4.8s items_phase=13.6s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 3 | `analyze/stream` | 2026-07-01 21:22:21 | `305ed1d2` | 21.56s | gemini=4.0s items_phase=17.5s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 2 | `analyze/stream` | 2026-07-01 21:21:21 | `fe2ad874` | 20.65s | gemini=2.4s items_phase=17.7s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 1 | `identify` | 2026-07-01 21:21:10 | `fdd4d511` | 9.71s | describe_and_upload=0.6s lens=8.8s shopping=0.0s | No Shopping search triggered — resolved via Lens alone |
