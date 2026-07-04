# ai-analyzer Performance Review — Last 2 Days

**Window:** 2026-07-02 ~00:00 UTC → 2026-07-04 00:20 UTC (Cloud Run `freshness=2d` at the time this
was pulled). **Source:** [Cloud Run logs, `ai-analyzer`, `us-central1`](https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7).
**Method:** pulled the `run.googleapis.com/requests` access log (per-request status/latency),
the app's `TIMING` log lines (per-request phase breakdown), and `severity>=WARNING` entries
(tracebacks/failures), then joined them by the app's own `[req=XXXX]` request-id tag. Raw JSON and
the parsing scripts used are in this session's scratchpad, not committed (reproducible by re-running
the same `gcloud logging read` queries against this window).

This is a one-off deep-dive report, separate from the recurring `check-ai-analyzer-logs` skill
(`docs/issues/issues-from-logs.md`), which only watches `severity>=WARNING` going forward. This
report also covers normal-latency `INFO`-level traffic, which that skill intentionally ignores.

## Traffic overview

232 requests total. The three search endpoints account for 176 of them; the rest is health checks,
config polls, and stray non-API hits (`/`, `/favicon.ico` from browsers/WhatsApp link previews).

| Path | 200 | Other | Notes |
|---|---|---|---|
| `/identify` | 64 | 8× `400` | All 8 `400`s are `PostmanRuntime` — validation-level rejections (e.g. missing image), not app bugs |
| `/analyze/stream` | 50 | — | Real traffic mix: Dart mobile app (15), Chrome web client (28), Postman (7) |
| `/analyze` | 43 | 8×`500`, 2×`400`, 1×`422` | All Postman-driven (perf test + a couple of validation calls) |
| `/health` | 26 | — | Uptime checks (curl, PowerShell, Postman) |
| `/config` | 20 | — | Config polls (Postman, curl) |
| `/`, `/favicon.ico` | — | 7×`404` | Not real API usage (browser favicon requests, WhatsApp link-preview bot) |
| `/analyze/health` | — | 3×`404` | Client hitting a path that doesn't exist — see Recommendations |

**159 of the 176 search calls carry a `[req=]` id** with either a full timing breakdown or a logged
outcome (the other 17 are `/identify` `400`s rejected by request validation before a request id is
even assigned — not app-level events). Of those 159: **150 succeeded, 9 failed** (~5.7% error rate
on search endpoints this window) — see **Bugs found** below for all 9.

## Latency summary (successful requests only)

| Endpoint | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| `/identify` | 64 | 0.00s | 8.24s | 29.74s | 78.76s | 12.97s |
| `/analyze` | 43 | 1.05s | 8.42s | 55.28s | 59.93s | 21.89s |
| `/analyze/stream` | 43 | 1.62s | 26.78s | 57.92s | 93.38s | 28.69s |

`/analyze`'s p50/p95 here are dominated by a single 20-call perf-test burst (see below) — the
non-test p50 for `/analyze` is closer to 4-8s (see the full table). `/analyze/stream`'s p50 being
~3x `/analyze`'s isn't a stream-specific regression: both use the same `ThreadPoolExecutor(10)`
concurrency for per-item search (`analyzer.py:1139`, `:1323`); the difference is traffic mix —
`/analyze/stream`'s calls this window are real Dart/Chrome client traffic with real (slower) Lens
matches, while `/analyze`'s slow calls are almost all one repeatable perf-test fixture.

## Key findings

### 1. The Lens timeout raise (12s → 60s, deployed 2026-07-03 18:51 UTC, `ee8b251`/`bdbfbc9`) changed the shape of worst-case latency mid-window
Before the deploy, when Google Lens didn't answer in time, `/identify` failed fast at the old ~12s
ceiling, then spent up to 10s more on the Shopping fallback (~22-30s worst case — 23 of 38
pre-deploy calls hit that old ~12s wall). After the deploy, the same failure mode waits the new
~60s ceiling before falling back (2 of 4 post-deploy calls hit it) — pushing worst-case `/identify`
latency from ~30s to **78.76s** (`req=d68a4205`) and **72.98s** (`req=0840d923`). The same pattern
shows up in `/analyze/stream`'s two slowest calls, **93.38s** (`req=f960bf1f`) and **92.70s**
(`req=9694ed68`) — both have one item's search phase land at ~70s (60s Lens timeout + 10s Shopping
fallback), well after the same deploy.

This is a known, deliberate trade-off (raising the timeout reduces *failed* Lens fetches — that was
the point of `ee8b251`), not a bug — but it's worth being deliberate about, since it triples the
worst-case wait exactly when Lens is already struggling. **This is the same tradeoff already being
discussed in `docs/consistency/action-item-todo.md`** ("Idea: Real-Time Progress Visibility During
Scans"), which was written the same day off a very similar log walkthrough — that doc's options
D/E/F (staged/streamed progress messaging so a 60-90s wait doesn't read as "frozen") are the
relevant next step here, not reverting the timeout.

### 2. The perceptual-hash cache is working as designed
Two clean cache-hit examples this window (`req=ab514135`, `req=55a8cea9`) at 0.33-0.36s vs. a normal
8-30s cache-miss `/identify` call — consistent with the ~55ms cache-hit number already measured in
`docs/analyze-perf-test-results.md`. Also visible: a burst of 17 back-to-back `/identify` calls at
`2026-07-03 11:59:34-37` all returning in 0.00s with no Gemini/Lens work at all — almost certainly a
repeat-tap cache-hit test (same crop hit 17x in ~3 seconds), not evidence of a problem.

### 3. Most of `/analyze`'s slow tail is one already-documented perf-test run, not organic traffic
20 of `/analyze`'s calls, all `2026-07-03 12:08-12:21`, `items=5`, Postman user-agent — this is the
exact `n=20, max_searches=5` benchmark run already written up in
`docs/analyze-perf-test-results.md` (same iteration count, same one `429 RESOURCE_EXHAUSTED` failure
documented there as "iteration 9"). That doc's conclusion still holds: **44-60s p95** on live Gemini
+ Lens is real for a 5-item request, and the mid-batch SerpAPI quota exhaustion documented there is
why several of these calls show a fast (~0.3s) `items_phase` — searches were failing fast on
exhausted quota, not actually completing quickly.

## Bugs found (9 failures this window)

| # | Time (UTC) | req | Endpoint | Duration | Cause | Status |
|---|---|---|---|---|---|---|
| 1 | 07-03 14:52 → 23:25 (7×) | `24c54cd6`, `e48f7ba8`, `d347f485`, `f0a1db17`, `17d763ef`, `2fa06e1a`, `fdcec5a3` | `/analyze` (live-video) | 1.4-2.0s | Gemini `400 INVALID_ARGUMENT` — `analyzer.py:982` hardcodes `mime_type="video/mp4"` for a `gs://.../segment001.ts` (MPEG-TS) object | **Already filed** — `docs/issues/issues-from-logs.md` #1 |
| 2 | 07-03 12:14:34 | `565ce95a` | `/analyze` | 30.96s | Gemini `429 RESOURCE_EXHAUSTED` misclassified as `500` instead of `502` — `classify_exception` (`analyzer.py:802`) doesn't recognize `google.genai.errors.ClientError` | **Already filed** — `docs/issues/issues-from-logs.md` #2 |
| 3 | 07-02 23:15:49 | `6beab01c` | `/analyze` | 0.00s | `Error: Incorrect padding` — malformed base64 in `image_data`, correctly rejected `400 INVALID_REQUEST` | **Not a bug** — client sent bad data, server handled it correctly. One-off, not recurring; not filed. |

Issues #1 and #2 were already caught and are tracked with root cause + suggested fix in
`docs/issues/issues-from-logs.md`; this 2-day window doesn't change their status (7 and 1
occurrences respectively, consistent with what's already filed there).

## Recommendations

- **Fix the two already-filed bugs** (`docs/issues/issues-from-logs.md` #1, #2) — #1 in particular
  means *every* live-video `/analyze` call is currently broken, not just the ones caught here.
- **Decide on a mitigation for finding #1 above** (the 60s Lens timeout's worst-case latency) before
  it surfaces as a user complaint — `docs/consistency/action-item-todo.md` already has concrete,
  scoped options (D/E/F) for this exact problem.
- **`/analyze/health` (3× `404`)** — something is polling a path that doesn't exist (the real health
  path is `/health`, not `/analyze/health`). Cheap to fix on whichever caller is doing this (looks
  like a Postman collection issue, not a server bug).
- No action needed on the `429`/perf-test/cache-hit findings above — they're either already
  understood (perf-test doc) or working as intended (cache).

## Full per-search detail

Every search-endpoint call this window with a resolvable outcome, grouped by endpoint and sorted
slowest-first. `Notes` is populated for anything notable; a plain `-` means a normal, unremarkable
call — its duration is still shown, just nothing more to add.

### `analyze` -- 52 requests, sorted slowest first

| Time (UTC) | req | Duration | gemini | items_phase | items | Notes |
|---|---|---|---|---|---|---|
| 2026-07-03 12:08:42 | `689961d9` | 59.93s | 37.1s | 22.4s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:15:31 | `0143ce80` | 56.26s | 33.9s | 22.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:21:36 | `46ab547b` | 55.28s | 54.9s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:14:03 | `e6839fd4` | 54.54s | 32.2s | 22.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:13:08 | `1145916c` | 51.93s | 29.6s | 22.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:10:54 | `aa9095d2` | 49.33s | 27.1s | 22.2s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:17:03 | `cda2ce0e` | 49.10s | 26.8s | 22.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:09:28 | `2342bb5f` | 46.03s | 25.3s | 20.8s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:18:33 | `2b99ebe7` | 46.02s | 45.7s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:11:38 | `13c6482f` | 43.77s | 25.9s | 17.8s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:17:46 | `47551710` | 43.20s | 30.9s | 12.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:16:14 | `b537251a` | 42.77s | 26.0s | 16.8s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:20:14 | `ffe60d6c` | 40.59s | 40.2s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:12:16 | `8c4a283d` | 37.88s | 15.6s | 22.2s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 00:05:03 | `28627c0f` | 37.72s | 16.4s | 21.1s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:10:04 | `a9551e6d` | 35.54s | 13.3s | 22.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:14:34 | `565ce95a` | 30.96s (500) | - | - | - | **Known bug** — Gemini 429 misclassified as 500 (see Bugs found #2) |
| 2026-07-03 12:19:01 | `d1b111af` | 27.27s | 26.9s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:20:40 | `dc8385a0` | 25.35s | 25.0s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 12:19:34 | `27045ff2` | 23.84s | 23.5s | 0.3s | 5 | Perf-test burst (n=20, max_searches=5) — see analyze-perf-test-results.md |
| 2026-07-03 23:28:35 | `03f0c8d7` | 13.94s | 13.3s | 0.0s | 0 | - |
| 2026-07-03 23:45:07 | `25330be5` | 13.90s | 12.8s | 0.0s | 0 | - |
| 2026-07-03 15:59:09 | `d2535af2` | 8.42s | 7.7s | 0.0s | 0 | - |
| 2026-07-03 12:19:10 | `570ca8ed` | 8.35s | 8.0s | 0.4s | 5 | - |
| 2026-07-03 16:33:32 | `ef87d8cf` | 8.08s | 7.5s | 0.0s | 0 | - |
| 2026-07-03 23:52:07 | `961f8b7c` | 7.74s | 7.0s | 0.0s | 0 | - |
| 2026-07-03 22:43:41 | `77e60e4f` | 5.46s | 4.8s | 0.0s | 0 | - |
| 2026-07-03 16:45:03 | `e324ee00` | 4.59s | 4.0s | 0.0s | 0 | - |
| 2026-07-03 23:06:29 | `12122af4` | 4.33s | 3.6s | 0.0s | 0 | - |
| 2026-07-02 23:15:28 | `8bacaa83` | 4.23s | 4.1s | 0.0s | 0 | - |
| 2026-07-03 22:39:33 | `4f230ff4` | 4.22s | 3.1s | 0.0s | 0 | - |
| 2026-07-03 23:27:17 | `050c3864` | 4.07s | 3.4s | 0.0s | 0 | - |
| 2026-07-03 14:52:30 | `22a56df4` | 3.89s | 3.3s | 0.0s | 0 | - |
| 2026-07-03 16:40:01 | `120ef7d4` | 3.34s | 2.8s | 0.0s | 0 | - |
| 2026-07-03 23:25:45 | `554c0d20` | 3.17s | 2.2s | 0.0s | 0 | - |
| 2026-07-03 15:20:29 | `68d641f4` | 2.47s | 1.8s | 0.0s | 0 | - |
| 2026-07-03 16:45:05 | `e316bc87` | 2.41s | 2.4s | 0.0s | 0 | - |
| 2026-07-03 16:33:34 | `bfa61cbd` | 2.26s | 2.3s | 0.0s | 0 | - |
| 2026-07-03 14:52:32 | `8aafbc53` | 2.08s | 2.1s | 0.0s | 0 | - |
| 2026-07-03 15:20:31 | `9092583d` | 2.05s | 2.0s | 0.0s | 0 | - |
| 2026-07-03 16:40:04 | `f0a1db17` | 2.02s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 22:39:35 | `09efa69b` | 2.01s | 2.0s | 0.0s | 0 | - |
| 2026-07-03 15:34:24 | `d3314f36` | 1.85s | 1.7s | 0.0s | 0 | - |
| 2026-07-03 15:20:33 | `e48f7ba8` | 1.84s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 14:52:34 | `24c54cd6` | 1.75s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 16:45:07 | `17d763ef` | 1.64s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 16:33:36 | `d347f485` | 1.43s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 22:39:37 | `2fa06e1a` | 1.42s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 23:25:48 | `fdcec5a3` | 1.40s (500) | - | - | - | **Known bug** — live-video mime-type mismatch (see Bugs found #1) |
| 2026-07-03 23:25:46 | `e5b60ebf` | 1.09s | 1.1s | 0.0s | 0 | - |
| 2026-07-03 16:40:02 | `9a3d7ef0` | 1.05s | 1.1s | 0.0s | 0 | - |
| 2026-07-02 23:15:49 | `6beab01c` | 0.00s (400) | - | - | - | Malformed base64 in request — correctly rejected 400, client-side issue |

### `analyze/stream` -- 43 requests, sorted slowest first

| Time (UTC) | req | Duration | gemini | items_phase | items | Notes |
|---|---|---|---|---|---|---|
| 2026-07-03 23:47:19 | `f960bf1f` | 93.38s | 22.8s | 70.5s | 2 | **Lens hit new 60s timeout** (post-deploy) + 10s Shopping fallback, on one of 2 items |
| 2026-07-04 00:19:07 | `9694ed68` | 92.70s | 22.4s | 70.3s | 2 | **Lens hit new 60s timeout** (post-deploy) + 10s Shopping fallback, on one of 2 items |
| 2026-07-03 23:28:40 | `48346858` | 57.92s | 16.7s | 41.1s | 2 | - |
| 2026-07-03 04:47:35 | `3f859e1f` | 53.37s | 30.8s | 22.3s | 2 | - |
| 2026-07-04 00:01:18 | `ba104fdc` | 50.38s | 18.3s | 31.7s | 2 | - |
| 2026-07-02 22:52:42 | `96fbd811` | 44.96s | 23.6s | 20.5s | 2 | - |
| 2026-07-02 22:58:20 | `ac818a48` | 41.46s | 24.9s | 16.5s | 2 | - |
| 2026-07-03 17:08:43 | `5480350a` | 41.37s | 18.9s | 22.3s | 2 | - |
| 2026-07-03 15:57:48 | `a99c6a3b` | 39.64s | 16.9s | 22.4s | 2 | - |
| 2026-07-03 04:53:48 | `4f2f99e1` | 38.36s | 16.9s | 21.4s | 2 | - |
| 2026-07-03 16:05:14 | `934df1ec` | 36.84s | 14.6s | 22.2s | 2 | - |
| 2026-07-02 22:53:11 | `d7737020` | 36.63s | 19.2s | 17.4s | 2 | - |
| 2026-07-04 00:06:31 | `987034d6` | 34.07s | 7.2s | 26.8s | 2 | - |
| 2026-07-02 02:49:48 | `75b994b7` | 33.62s | 21.4s | 12.2s | 2 | - |
| 2026-07-03 01:03:38 | `c8367619` | 33.10s | 16.4s | 15.7s | 2 | - |
| 2026-07-02 02:42:58 | `f29c204e` | 32.71s | 10.4s | 22.3s | 2 | - |
| 2026-07-02 23:01:10 | `41275a51` | 30.02s | 7.9s | 22.1s | 2 | - |
| 2026-07-02 22:52:27 | `66061bec` | 29.63s | 12.4s | 16.3s | 2 | - |
| 2026-07-03 16:39:33 | `aad881bb` | 28.85s | 6.6s | 22.2s | 2 | - |
| 2026-07-02 22:58:52 | `5255419e` | 27.18s | 15.4s | 11.8s | 2 | - |
| 2026-07-03 01:05:46 | `8c4718e1` | 27.03s | 5.4s | 21.6s | 2 | - |
| 2026-07-03 16:38:39 | `f9b43981` | 26.78s | 4.5s | 22.2s | 1 | - |
| 2026-07-02 22:59:54 | `9ee730db` | 25.98s | 3.8s | 22.1s | 2 | - |
| 2026-07-02 02:48:15 | `9156f7ff` | 25.17s | 11.0s | 14.2s | 2 | - |
| 2026-07-03 16:05:11 | `933abcb1` | 25.17s | 2.8s | 22.3s | 2 | - |
| 2026-07-02 22:57:29 | `f64b7753` | 22.82s | 12.4s | 10.4s | 2 | - |
| 2026-07-02 02:22:21 | `305ed1d2` | 21.56s | 4.0s | 17.5s | 2 | - |
| 2026-07-02 23:00:22 | `b464f151` | 21.33s | 13.2s | 8.1s | 2 | - |
| 2026-07-02 02:21:21 | `fe2ad874` | 20.65s | 2.4s | 17.7s | 2 | - |
| 2026-07-02 02:35:50 | `26df5f82` | 20.65s | 9.8s | 10.4s | 2 | - |
| 2026-07-03 01:04:42 | `2e1832f9` | 20.56s | 8.9s | 11.6s | 2 | - |
| 2026-07-02 02:34:25 | `63a663d3` | 18.42s | 4.8s | 13.6s | 2 | - |
| 2026-07-02 22:59:21 | `56663ed8` | 17.74s | 8.5s | 9.3s | 2 | - |
| 2026-07-02 02:49:01 | `71a18548` | 16.79s | 8.8s | 8.0s | 2 | - |
| 2026-07-03 15:40:05 | `9c0bbdf8` | 14.32s | 14.0s | 0.3s | 1 | - |
| 2026-07-03 14:52:44 | `65803738` | 9.62s | 9.4s | 0.0s | 0 | - |
| 2026-07-03 15:40:36 | `ab17468d` | 8.18s | 7.8s | 0.3s | 2 | - |
| 2026-07-03 23:25:54 | `bf6f5c7c` | 5.83s | 5.1s | 0.0s | 0 | - |
| 2026-07-03 16:40:06 | `8d9e5757` | 1.98s | 1.8s | 0.0s | 0 | - |
| 2026-07-03 22:39:39 | `bc96c033` | 1.89s | 1.6s | 0.0s | 0 | - |
| 2026-07-03 16:45:09 | `84b5e898` | 1.79s | 1.6s | 0.0s | 0 | - |
| 2026-07-03 16:33:38 | `544215af` | 1.68s | 1.5s | 0.0s | 0 | - |
| 2026-07-03 15:20:35 | `73ef16f9` | 1.62s | 1.4s | 0.0s | 0 | - |

### `identify` -- 64 requests, sorted slowest first

| Time (UTC) | req | Duration | describe+upload | lens | shopping | Notes |
|---|---|---|---|---|---|---|
| 2026-07-03 22:40:58 | `d68a4205` | 78.76s | 8.6s | 60.1s | 10.0s | **Lens hit new 60s timeout** (post 07-03 18:51 UTC deploy) + 10s Shopping fallback |
| 2026-07-03 22:46:03 | `0840d923` | 72.98s | 2.7s | 60.1s | 10.0s | **Lens hit new 60s timeout** (post 07-03 18:51 UTC deploy) + 10s Shopping fallback |
| 2026-07-03 23:26:43 | `d4aa580a` | 49.00s | 0.1s | 48.9s | 0.0s | - |
| 2026-07-03 16:34:08 | `830f856a` | 29.74s | 7.5s | 12.1s | 10.0s | - |
| 2026-07-03 11:57:58 | `b313d530` | 29.05s | 6.7s | 12.1s | 10.0s | - |
| 2026-07-03 18:02:33 | `51388a20` | 28.00s | 4.8s | 12.1s | 10.0s | - |
| 2026-07-03 12:03:32 | `d0e6647c` | 26.36s | 4.2s | 12.0s | 10.0s | - |
| 2026-07-03 18:21:22 | `11b72056` | 26.32s | 4.1s | 12.1s | 10.0s | - |
| 2026-07-03 17:04:16 | `3b838276` | 25.88s | 4.8s | 12.1s | 8.7s | - |
| 2026-07-03 12:06:14 | `69e0e541` | 25.70s | 3.6s | 12.0s | 10.0s | - |
| 2026-07-03 12:06:39 | `85cd8853` | 25.07s | 2.9s | 12.1s | 10.0s | - |
| 2026-07-03 18:08:07 | `b5e7b770` | 24.92s | 2.7s | 12.0s | 10.0s | - |
| 2026-07-03 12:07:04 | `27006dc8` | 24.44s | 2.2s | 12.1s | 10.0s | - |
| 2026-07-03 12:05:04 | `a219a980` | 24.35s | 2.2s | 12.0s | 10.0s | - |
| 2026-07-03 12:02:06 | `e8fbb54f` | 23.91s | 1.8s | 12.0s | 10.0s | - |
| 2026-07-03 12:04:35 | `b8a29827` | 23.20s | 2.5s | 12.0s | 8.6s | - |
| 2026-07-03 12:02:46 | `70d0a20f` | 22.78s | 2.8s | 12.0s | 7.9s | - |
| 2026-07-03 16:20:04 | `434ee437` | 21.89s | 3.5s | 12.1s | 6.2s | - |
| 2026-07-03 18:33:24 | `c4f73d41` | 21.03s | 3.5s | 12.1s | 5.3s | - |
| 2026-07-03 12:05:31 | `42a5b9db` | 19.67s | 2.5s | 12.0s | 5.0s | - |
| 2026-07-03 12:03:06 | `40fdcc90` | 19.16s | 1.7s | 12.0s | 5.3s | - |
| 2026-07-03 23:25:09 | `4d109e2c` | 19.07s | 0.2s | 18.6s | 0.0s | - |
| 2026-07-03 12:02:23 | `d5177539` | 17.52s | 3.7s | 12.1s | 1.6s | - |
| 2026-07-03 12:05:48 | `8002b694` | 17.23s | 3.4s | 12.0s | 1.7s | - |
| 2026-07-03 16:22:31 | `b6101303` | 17.01s | 2.8s | 12.0s | 2.1s | - |
| 2026-07-03 12:04:00 | `f9c84827` | 12.08s | 0.1s | 12.0s | 0.0s | - |
| 2026-07-03 04:24:58 | `ee8e829d` | 11.68s | 0.1s | 11.6s | 0.0s | - |
| 2026-07-03 12:04:12 | `9f977fee` | 11.40s | 0.1s | 11.3s | 0.0s | - |
| 2026-07-03 12:03:43 | `22eda1ab` | 10.85s | 0.1s | 10.8s | 0.0s | - |
| 2026-07-03 12:07:15 | `ffd7e352` | 10.69s | 0.1s | 10.6s | 0.0s | - |
| 2026-07-02 02:21:10 | `fdd4d511` | 9.71s | 0.6s | 8.8s | 0.0s | - |
| 2026-07-03 04:25:18 | `b14b6313` | 8.24s | 0.1s | 8.1s | 0.0s | - |
| 2026-07-03 11:59:34 | `b8fdcfd6` | 8.11s | 0.1s | 8.0s | 0.0s | - |
| 2026-07-03 12:05:11 | `07cb7eca` | 7.46s | 0.1s | 7.4s | 0.0s | - |
| 2026-07-03 00:05:09 | `d79f9c43` | 5.63s | 0.1s | 5.5s | 0.0s | - |
| 2026-07-03 18:04:47 | `c0537b6a` | 5.52s | 0.1s | 5.4s | 0.0s | - |
| 2026-07-03 12:03:48 | `10d3e0ed` | 4.88s | 0.1s | 4.8s | 0.0s | - |
| 2026-07-03 12:04:39 | `78090dfe` | 4.36s | 0.1s | 4.3s | 0.0s | - |
| 2026-07-03 04:39:52 | `65b84cd2` | 2.99s | 0.1s | 2.8s | 0.0s | - |
| 2026-07-03 04:24:24 | `2ba0e704` | 2.81s | 0.2s | 2.4s | 0.0s | - |
| 2026-07-03 15:20:36 | `ab514135` | 0.36s | 0.2s | 0.1s | 0.0s | Perceptual-hash cache hit (~30min TTL) — instant, no Gemini/Lens call |
| 2026-07-03 14:52:45 | `55a8cea9` | 0.33s | 0.2s | 0.1s | 0.0s | Perceptual-hash cache hit (~30min TTL) — instant, no Gemini/Lens call |
| 2026-07-03 11:59:34 | `fa486d59` | 0.00s | - | - | - | Perceptual-hash cache hit — part of a 17-call repeat-tap burst, 11:59:34-37 |
| 2026-07-03 11:59:34 | `0ebda8ca` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `11bdd1b8` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `5da123c2` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `1c095426` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `8ebac7b1` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `04e1ab1b` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `beee90f8` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:35 | `61aaf7ea` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `db3c3c6b` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `07253caf` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `868d61cf` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `39990d05` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `63396cfa` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:36 | `0b5ad078` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:37 | `ca271630` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:37 | `4ee13d29` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:37 | `52395e83` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 11:59:37 | `9dbefb7f` | 0.00s | - | - | - | Perceptual-hash cache hit — part of the same burst |
| 2026-07-03 12:01:42 | `404d566f` | 0.00s | - | - | - | Perceptual-hash cache hit (isolated) |
| 2026-07-03 16:40:06 | `68e1aa09` | 0.00s | - | - | - | Perceptual-hash cache hit (isolated) |
| 2026-07-03 16:45:09 | `9530fee0` | 0.00s | - | - | - | Perceptual-hash cache hit (isolated) |
