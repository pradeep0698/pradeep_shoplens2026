# ai-analyzer Performance Metrics

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`) from Cloud Run `TIMING` log lines for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7

This doc has two tables: an overall **Summary** (one row per endpoint, recomputed from all samples currently in the detail table below) and a single **All Samples** table merging every sample across all three endpoints (`analyze`, `analyze/stream`, `identify`), sorted newest-first.

Each sample gets a permanent `#` id assigned in chronological order (oldest = 1) the first time it's written — ids never change or get reused, so you can always refer back to a row by its number even after newer rows are prepended above it. New samples get the next id after the current max and are prepended at the top. Each endpoint still keeps a rolling window of its most recent 100 completed requests — once an endpoint exceeds that, its oldest rows drop out of the table (leaving a gap in the id sequence), but surviving rows keep their original ids.

Timestamps are US Central Time (source Cloud Run logs are UTC; converted at UTC-5 CDT for these dates — adjust to UTC-6 CST for entries falling in the Nov-Mar standard-time window).

Last updated: 2026-07-04T06:15:13 CDT — +1 identify sample

## Summary (from current samples below)

| Endpoint | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| `analyze` | 43 | 1.05s | 8.42s | 55.28s | 59.93s | 21.89s |
| `analyze/stream` | 45 | 1.62s | 26.78s | 78.47s | 93.38s | 29.43s |
| `identify` | 45 | 0.33s | 19.16s | 49.00s | 78.76s | 19.90s |

## Analysis

- **`analyze`** is bimodal: most calls (`items=0`) are Postman placeholder smoke-tests — Gemini runs but finds nothing, so `items_phase` is 0 by design and total latency is just Gemini's 1-14s response time. A separate `n=20` perf-test burst (`items=5`, documented in `docs/analyze-perf-test-results.md`) against a real product photo drives the 20-60s tail — both Gemini detection and real Lens/Shopping search work are slow there.
- **`analyze/stream`** samples are almost all real 1-2 item detections (the live-scan flow), where `items_phase` (concurrent Lens/Shopping search per item) typically accounts for 40-75% of total latency — this is the dominant cost, not Gemini. A handful of `items=0` rows are fast health-check pings.
- **`identify`** splits into three regimes: (1) calls with `shopping=0.0s` resolve via Lens alone, with latency scaling directly with Lens response time (anywhere from <1s to 60s+); (2) a large recurring cluster has `lens` pinned almost exactly to ~12.0-12.1s with `shopping` varying 1.6-10.0s — consistent with a fixed test fixture/image hitting both steps; (3) two separate requests (`#113`, `#111`) both hit `lens=60.1s` exactly, paired with a capped `shopping=10.0s` — the repeated identical value across two different requests suggests a ~60s timeout ceiling on the Lens call rather than organic slowness. Worth flagging if `lens=60.1s` recurs.

## All Samples (newest first)

| # | API | Time (Central) | req | Duration | Breakdown | Notes |
|---|---|---|---|---|---|---|
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
