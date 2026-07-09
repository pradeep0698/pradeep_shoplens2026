# ai-analyzer Performance Metrics (cookshop-dev)

Platform: **cookshop-dev** (Rajan's weekly-release prod — see the `shoplens2026-dev`
counterpart at `docs/issues/ai-analyzer-metrics.shoplens2026-dev.md` for active dev).

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`) from Cloud Run `TIMING` log lines for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=cookshop-dev-prj

This doc has two tables: an overall **Summary** (one row per endpoint, recomputed from all samples currently in the detail table below) and a single **All Samples** table merging every sample across all three endpoints (`analyze`, `analyze/stream`, `identify`), sorted newest-first.

Each sample gets a permanent `#` id assigned in chronological order (oldest = 1) the first time it's written — ids never change or get reused, so you can always refer back to a row by its number even after newer rows are prepended above it. New samples get the next id after the current max and are prepended at the top. Each endpoint still keeps a rolling window of its most recent 100 completed requests — once an endpoint exceeds that, its oldest rows drop out of the table (leaving a gap in the id sequence), but surviving rows keep their original ids.

Timestamps are US Central Time (source Cloud Run logs are UTC; converted at UTC-5 CDT for these dates — adjust to UTC-6 CST for entries falling in the Nov-Mar standard-time window).

Last updated: 2026-07-09T07:01:23 CDT — +32 analyze/stream, +29 identify samples (first batch for this platform)

## Summary (from current samples below)

| Endpoint | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| `analyze` | 0 | - | - | - | - | - |
| `analyze/stream` | 32 | 9.41s | 28.25s | 68.50s | 116.37s | 34.69s |
| `identify` | 29 | 4.22s | 9.97s | 57.11s | 91.63s | 15.83s |

## Analysis

- This is the first batch of samples for `cookshop-dev` — no `analyze` (non-stream) traffic seen yet, only `analyze/stream` (live-scan "Scan All" + the gallery-image-upload "Scan Image" flow, which calls the same endpoint) and `identify` (live-scan tap-to-identify).
- **`analyze/stream`** samples are almost all real 1-5 item detections — no placeholder/health-check (`items=0`) rows except `#57`. `items_phase` (concurrent Lens/Shopping search) is the dominant cost in most rows. The top two latencies this batch are notable: `#37` (req `201c11ad`, 116.37s, `items_phase=100.98s` for 2 items) and `#47` (req `89e1057e`, 72.18s) — both look like slow real Lens/Shopping searches, not errors, but worth watching if `items_phase` durations like this recur.
- **`identify`** is already on the post-hedge shape (`hedge_triggered=`/`lens_timed_out=`/`quota_exhausted=` fields present in every row — this platform's weekly release has picked up the 2026-07-04 hedge change). Most rows are the fast path (`hedge=False`, `shopping=0.0s` — Lens answered inside the 25s hedge window). A few show the hedge actually triggering: `#31` and `#45` (Lens ran past 25s, Gemini kicked in but never needed Shopping), `#36` (req `b00d4163`, 91.63s — full hedge, Lens ran 91.2s and Shopping ran 63.87s alongside it, the slowest identify call this batch), and `#10` (hedge fired right at the ~25s boundary but Lens returned almost immediately after, so the fallback never accrued time). None hit `quota_exhausted=True` yet.
- No samples in this batch line up with the `Gemini 429 RESOURCE_EXHAUSTED` issue filed today in `issues-from-logs.cookshop-dev.md` — that error came from a separate `/analyze/stream` request that failed outright (no TIMING line emitted for a failed request).

## All Samples (newest first)

| # | API | Time (Central) | req | Duration | Breakdown | Notes |
|---|---|---|---|---|---|---|
| 61 | `analyze/stream` | 2026-07-09 07:01:23 | `d3bb2f81` | 62.12s | gemini=55.23s items_phase=6.78s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 60 | `analyze/stream` | 2026-07-09 07:01:17 | `66c77245` | 55.31s | gemini=50.55s items_phase=4.75s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 59 | `identify` | 2026-07-09 06:27:12 | `ef25ac79` | 7.78s | upload=0.11s lens=7.67s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 58 | `analyze/stream` | 2026-07-09 06:25:20 | `5d3b7c00` | 43.34s | gemini=39.48s items_phase=3.86s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 57 | `analyze/stream` | 2026-07-09 06:24:27 | `474d737d` | 27.30s | gemini=27.30s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 56 | `analyze/stream` | 2026-07-09 06:20:47 | `585cdb46` | 33.32s | gemini=28.25s items_phase=4.52s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 55 | `identify` | 2026-07-08 09:09:26 | `3a9faa0c` | 5.20s | upload=0.12s lens=5.07s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 54 | `analyze/stream` | 2026-07-08 09:08:52 | `14192150` | 14.98s | gemini=8.68s items_phase=5.84s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 53 | `analyze/stream` | 2026-07-08 00:04:00 | `9c393151` | 18.38s | gemini=13.22s items_phase=5.16s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 52 | `analyze/stream` | 2026-07-08 00:03:34 | `4f017d8a` | 9.41s | gemini=9.41s items_phase=0.00s items=0 | Placeholder/health-check image — no items detected, items_phase 0 by design |
| 51 | `analyze/stream` | 2026-07-08 00:03:08 | `fb88734d` | 34.81s | gemini=25.63s items_phase=8.97s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 50 | `analyze/stream` | 2026-07-07 23:39:34 | `f20035be` | 10.50s | gemini=5.64s items_phase=4.37s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 49 | `identify` | 2026-07-07 22:02:23 | `fba902f6` | 4.52s | upload=0.11s lens=4.40s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 48 | `analyze/stream` | 2026-07-07 22:02:04 | `66304053` | 19.38s | gemini=11.80s items_phase=7.15s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 47 | `analyze/stream` | 2026-07-07 15:00:23 | `89e1057e` | 72.18s | gemini=37.10s items_phase=34.67s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 46 | `analyze/stream` | 2026-07-07 15:00:07 | `3fe504c4` | 56.03s | gemini=37.89s items_phase=18.14s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 45 | `identify` | 2026-07-07 08:46:54 | `65fe447b` | 57.11s | upload=0.16s lens=56.95s gemini=1.99s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 44 | `identify` | 2026-07-07 08:34:59 | `f6b2d4c2` | 14.56s | upload=0.13s lens=14.34s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 43 | `analyze/stream` | 2026-07-07 08:34:57 | `032f569f` | 19.56s | gemini=7.17s items_phase=12.03s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 42 | `identify` | 2026-07-07 08:34:08 | `91c38349` | 19.19s | upload=0.34s lens=18.71s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 41 | `analyze/stream` | 2026-07-07 08:14:45 | `b0ec5390` | 28.25s | gemini=13.16s items_phase=15.09s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 40 | `analyze/stream` | 2026-07-07 08:14:01 | `148518cd` | 21.29s | gemini=13.55s items_phase=7.74s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 39 | `analyze/stream` | 2026-07-07 08:13:46 | `d96c6fcc` | 27.38s | gemini=13.08s items_phase=14.31s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 38 | `analyze/stream` | 2026-07-07 08:13:44 | `fd4e6974` | 32.20s | gemini=8.48s items_phase=23.72s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 37 | `analyze/stream` | 2026-07-07 08:13:01 | `201c11ad` | 116.37s | gemini=15.37s items_phase=100.98s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 36 | `identify` | 2026-07-07 08:10:29 | `b00d4163` | 91.63s | upload=0.30s lens=91.20s gemini=2.20s shopping=63.87s hedge=True timed_out=False quota=False | Full hedge — Lens was still slow past the hedge window, Shopping ran alongside it |
| 35 | `identify` | 2026-07-06 23:29:52 | `bece564e` | 9.97s | upload=0.14s lens=9.83s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 34 | `analyze/stream` | 2026-07-06 23:28:59 | `4d430bc2` | 15.34s | gemini=8.49s items_phase=6.85s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 33 | `identify` | 2026-07-06 23:27:59 | `9176fd08` | 4.33s | upload=0.12s lens=4.20s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 32 | `identify` | 2026-07-06 23:27:29 | `727dae47` | 15.14s | upload=0.11s lens=15.03s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 31 | `identify` | 2026-07-06 23:26:48 | `e29b15b0` | 36.02s | upload=0.24s lens=35.75s gemini=3.08s shopping=0.00s hedge=True timed_out=False quota=False | Lens answered mid-hedge — Gemini ran but Shopping was never needed |
| 30 | `analyze/stream` | 2026-07-06 23:20:22 | `e7d8ad6c` | 15.26s | gemini=7.64s items_phase=7.30s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 29 | `identify` | 2026-07-06 23:19:30 | `1f5a9dff` | 6.81s | upload=0.17s lens=6.61s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 28 | `identify` | 2026-07-06 23:18:47 | `0c9c53a1` | 9.69s | upload=0.33s lens=9.24s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 27 | `analyze/stream` | 2026-07-06 16:27:28 | `6a9958ed` | 22.36s | gemini=14.85s items_phase=7.51s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 26 | `identify` | 2026-07-06 16:25:55 | `9b9a2eb5` | 5.76s | upload=0.11s lens=5.65s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 25 | `identify` | 2026-07-06 16:25:31 | `9e6152e8` | 8.22s | upload=0.11s lens=8.10s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 24 | `identify` | 2026-07-06 16:25:05 | `c5f39c05` | 10.03s | upload=0.12s lens=9.91s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 23 | `identify` | 2026-07-06 16:24:37 | `f329bb75` | 4.22s | upload=0.14s lens=4.07s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 22 | `identify` | 2026-07-06 16:24:13 | `f5af1a91` | 6.40s | upload=0.12s lens=6.27s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 21 | `analyze/stream` | 2026-07-06 16:23:46 | `8a753710` | 13.10s | gemini=8.84s items_phase=4.25s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 20 | `analyze/stream` | 2026-07-06 16:23:40 | `210bffc3` | 68.50s | gemini=31.93s items_phase=36.57s items=5 | Five items detected — items_phase covers concurrent Lens/Shopping search for all five |
| 19 | `identify` | 2026-07-06 16:23:10 | `0a12c66e` | 19.87s | upload=0.23s lens=19.61s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 18 | `analyze/stream` | 2026-07-06 16:22:21 | `ddf1a317` | 40.07s | gemini=19.78s items_phase=20.28s items=4 | Four items detected — items_phase covers concurrent Lens/Shopping search for all four |
| 17 | `identify` | 2026-07-06 16:21:58 | `ca268aa4` | 11.17s | upload=0.15s lens=11.01s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 16 | `identify` | 2026-07-06 16:20:52 | `1338964f` | 8.90s | upload=0.13s lens=8.76s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 15 | `analyze/stream` | 2026-07-06 16:19:51 | `635f6698` | 22.80s | gemini=4.92s items_phase=17.78s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 14 | `identify` | 2026-07-06 15:55:03 | `eaec0047` | 5.19s | upload=0.18s lens=4.99s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 13 | `identify` | 2026-07-06 15:54:23 | `b9d11fa8` | 10.50s | upload=0.11s lens=10.39s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 12 | `identify` | 2026-07-06 15:53:52 | `5f21e010` | 17.22s | upload=0.10s lens=17.11s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 11 | `identify` | 2026-07-06 15:53:14 | `dba8639c` | 17.51s | upload=0.17s lens=17.33s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 10 | `identify` | 2026-07-06 15:52:36 | `9081027b` | 25.75s | upload=0.19s lens=25.54s gemini=0.00s shopping=0.00s hedge=True timed_out=False quota=False | Hedge fired right at the ~25s threshold, but Lens returned almost immediately after — the concurrent Gemini/Shopping fallback was cancelled before accruing any time |
| 9 | `analyze/stream` | 2026-07-06 15:51:39 | `d971995c` | 16.04s | gemini=4.72s items_phase=11.31s items=1 | One item detected — items_phase covers the Lens/Shopping search for it |
| 8 | `analyze/stream` | 2026-07-06 15:51:05 | `be7030e1` | 22.99s | gemini=12.25s items_phase=10.61s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 7 | `analyze/stream` | 2026-07-06 15:50:39 | `1fe63ef3` | 56.30s | gemini=15.48s items_phase=40.50s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 6 | `analyze/stream` | 2026-07-06 15:50:30 | `a08f79da` | 47.42s | gemini=18.72s items_phase=28.34s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 5 | `analyze/stream` | 2026-07-06 15:50:18 | `cbdf0390` | 35.98s | gemini=16.12s items_phase=19.54s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 4 | `analyze/stream` | 2026-07-06 15:50:14 | `1d6703ef` | 31.91s | gemini=19.28s items_phase=12.28s items=2 | Two items detected — items_phase covers concurrent Lens/Shopping search for both |
| 3 | `identify` | 2026-07-06 15:30:07 | `74e0d296` | 6.36s | upload=0.46s lens=5.63s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 2 | `identify` | 2026-07-06 12:01:03 | `4f7be33a` | 10.96s | upload=0.19s lens=10.75s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
| 1 | `identify` | 2026-07-06 11:57:47 | `fb1a40dc` | 9.07s | upload=0.12s lens=8.94s gemini=0.00s shopping=0.00s hedge=False timed_out=False quota=False | Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS, default 25s), Gemini never touched |
