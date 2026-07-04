Pull new Cloud Run logs for the `ai-analyzer` service and update both `docs/issues/issues-from-logs.md`
(errors/warnings) and `docs/issues/ai-analyzer-metrics.md` (latency metrics) with anything new.

Source: https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7

## Steps

1. Run `bash scripts/check-ai-analyzer-logs.sh` from the repo root. It prints two JSON arrays since
   the last checkpoint (`.claude/state/ai-analyzer-logs-checkpoint.txt`), each preceded by a marker
   line: `=== WARNINGS (severity>=WARNING) ===` (for the issues doc) and `=== TIMING (perf metrics) ===`
   (every log line containing `TIMING`, for the metrics doc — these are `INFO`-level and would
   otherwise never be fetched, since they don't meet the `severity>=WARNING` bar). It then advances
   the checkpoint to now, so each run only sees genuinely new entries.
   - If you need to look further back without disturbing the checkpoint (e.g. first-ever run, or
     re-checking something), use `bash scripts/check-ai-analyzer-logs.sh --since-minutes N` instead.
2. If **both** arrays are empty: update the `Last checked:` line in `issues-from-logs.md` (UTC, as
   already used there) and the `Last updated:` line in `ai-analyzer-metrics.md` (US Central, per the
   conversion rule in step 8 — `CDT`/`CST` suffix) to now (e.g. `... — no new log entries`), tell the
   user "no new issues, no new metrics", and stop. If only one array is empty, still process the other
   and only touch that one doc (plus update that doc's own timestamp line as normal — don't touch the
   other doc's timestamp if it had nothing new).

## Part A — errors/warnings → `docs/issues/issues-from-logs.md`

Skip this part entirely if the `WARNINGS` array is empty (don't touch the file).

3. Classify each entry into an issue signature:
   - Traceback/exception in `textPayload` → signature = exception type + the last `/app/...` frame
     (e.g. `TimeoutError @ analyzer.py:973`). Read that file/line in the repo to understand what's
     actually happening there before writing the entry — don't just restate the traceback.
   - `httpRequest.status >= 400` → signature = `<status> <path>` (path only, strip host/query from
     `requestUrl`).
   - Anything else with `severity=WARNING`/`ERROR` → signature = a short normalized version of the
     message with IDs/timestamps/numbers stripped out.
   Group entries by signature.
4. Read the current `docs/issues/issues-from-logs.md`.
5. For each signature group from this run:
   - **Known-benign noise — mention, don't file:** 400/401/422 responses whose `httpRequest.userAgent`
     is `PostmanRuntime` are from manual/scripted test runs (see the `run-postman-tests` skill's
     "Known issues to watch for" list), not real user traffic. Call these out in your reply to the
     user but don't add/update a doc entry for them, unless the *same endpoint* also shows failures
     from a non-Postman user-agent in this batch — that's a real regression worth filing.
   - If an existing `### ` entry under **Open** matches this signature, update in place: bump
     `Last seen` to this batch's latest timestamp, add this batch's count to `Occurrences`. Leave
     `First seen` and any notes the user added untouched. Only refresh `Sample` if the new one is more
     informative.
   - If no existing entry matches, append a new one under **Open** with: a short human-readable title,
     Severity, First seen (earliest ts in this batch), Last seen (latest ts), Occurrences, Endpoint/source,
     Sample (one trimmed representative log line or trace — not the whole batch), Likely cause (your
     actual read of the referenced code, not a guess), Suggested fix (concrete, with file:line where
     possible).
   - Never move an entry to **Resolved** yourself. Only do that when the user explicitly confirms a
     fix shipped. An entry that simply didn't recur in this batch stays in Open untouched.
6. Order **Open** entries by severity (ERROR above WARNING), then by most-recent `Last seen` within
   each severity.
7. Update the `Last checked:` line with a one-line summary, e.g.
   `Last checked: 2026-07-03T23:50Z — 14 new log lines, 1 new issue, 2 updated, 3 known-benign (Postman)`.

## Part B — latency metrics → `docs/issues/ai-analyzer-metrics.md`

Skip this part entirely if the `TIMING` array is empty (don't touch the file).

8. Parse each `TIMING` line into `{endpoint, req id, timestamp, total duration, breakdown}`:
   - `analyzer: TIMING (stream) | total=Xs gemini=Ys items_phase=Zs items=N` → endpoint
     `analyze/stream`, breakdown `{gemini, items_phase, items}`.
   - `analyzer: TIMING | total=Xs gemini=Ys items_phase=Zs items=N` (no `(stream)`) → endpoint
     `analyze`, same breakdown shape.
   - `analyzer: TIMING | total=Xs upload=Ys lens=Zs gemini=Vs shopping=Ws hedge_triggered=B1
     lens_timed_out=B2 quota_exhausted=B3` → endpoint `identify`, breakdown
     `{upload, lens, gemini, shopping, hedge_triggered, lens_timed_out, quota_exhausted}`. (Field
     set changed 2026-07-04 when the Lens/Gemini/Shopping hedge shipped — `describe_and_upload`
     split into separate `upload`/`gemini`, and three new flags were added. Older log lines from
     before that change still use the old `describe_and_upload=Ys lens=Zs shopping=Ws` shape; treat
     that as the same `identify` endpoint with `{describe_and_upload, lens, shopping}` breakdown —
     don't try to force old rows into the new field set retroactively.)
   The `[req=XXXX]` tag is the request id; the log entry's own `timestamp` field is the sample time,
   in UTC. **Convert it to US Central Time before writing it anywhere in the doc** — subtract 5 hours
   for dates that fall in daylight saving (roughly second Sunday of March through first Sunday of
   November → CDT, UTC-5), or 6 hours otherwise (CST, UTC-6). All timestamps in
   `ai-analyzer-metrics.md` are Central, not UTC — this doc's `Time (Central)` column headers and the
   note near the top of the file are the record of that convention; don't silently drift back to UTC.
9. `ai-analyzer-metrics.md` has exactly one detail table, **All Samples**, merging every endpoint
   together (columns: `#`, `API`, `Time (Central)`, `req`, `Duration`, `Breakdown`, `Notes`), sorted
   newest-first, plus a per-endpoint **Summary** table above it. Read the current doc, then:
   - **Assign ids.** Find the current max `#` in the table (the top row's id, since it's sorted
     newest-first). Sort this run's new samples across *all* endpoints chronologically (oldest first)
     and assign them `max+1, max+2, ...` in that order, so the newest sample overall gets the highest
     new id. Ids are permanent — never renumber existing rows.
   - **Breakdown column** — format as `key=val key=val ...` matching the endpoint's fields:
     `analyze`/`analyze/stream` → `gemini=Xs items_phase=Ys items=N`; `identify` (post-hedge, 2026-07-04+) →
     `upload=Xs lens=Ys gemini=Vs shopping=Zs hedge=B1 timed_out=B2 quota=B3`; `identify` (pre-hedge,
     older rows) → `describe_and_upload=Xs lens=Ys shopping=Zs`.
   - **Notes column** — fill in for every new row, regardless of endpoint (this is required now, not
     just for `analyze`). Use these templates, consistent with the doc's Analysis section:
     - `analyze`: distinguish placeholder-image smoke-test calls (`items=0`, near-instant
       `items_phase`) from real-image calls (`items>0`, real `items_phase` search work) — don't call a
       jump between the two "faster"/"slower" as if something changed; they're different call types.
       If a new sample's timestamp falls within ~15 minutes of a git commit/deploy that plausibly
       touches `/analyze` (check `git log --since=<24h before oldest new sample>` if unsure), name
       that commit in the note; otherwise describe what's actually different about the call (image
       type, item count) rather than guessing at a fix that didn't happen.
     - `analyze/stream`: `items=0` → "Placeholder/health-check image — no items detected, items_phase
       0 by design"; `items=1` → "One item detected — items_phase covers the Lens/Shopping search for
       it"; `items>=2` → "Two items detected — items_phase covers concurrent Lens/Shopping search for
       both" (adjust wording if item count is ever >2).
     - `identify` (post-hedge rows, i.e. the log line has `hedge_triggered=`): `hedge_triggered=false`
       with `shopping=0.0s` → "Fast path — Lens answered within the hedge window (LENS_HEDGE_DELAY_SECONDS,
       default 25s), Gemini never touched"; `hedge_triggered=false` with `shopping>0` → "Fast path, Lens
       came back empty — sequential Shopping fallback ran using the caller-supplied query" (only
       possible when the request itself carried a non-empty query); `hedge_triggered=true` with
       `gemini>0` and `shopping=0.0s` → "Lens answered mid-hedge — Gemini ran but Shopping was never
       needed"; `hedge_triggered=true` with `shopping>0` → "Full hedge — Lens was still slow past the
       hedge window, Shopping ran alongside it"; `quota_exhausted=true` → "SerpAPI quota exhausted —
       hedge skipped, rode Lens out directly" (regardless of hedge_triggered); anything else → a short
       factual note on what's driving the latency.
     - `identify` (pre-hedge rows, no `hedge_triggered=` field — from before 2026-07-04): `shopping=0.0s`
       → "No Shopping search triggered — resolved via Lens alone"; `lens` in the ~11.9-12.2s band with
       `shopping>0` → "Perf-test fixture pattern — lens pinned ~12.0s (fixed test image), shopping
       search ran {shopping}"; `lens>=55s` → "Lens hit a ~60s ceiling — worth watching if this recurs
       (possible timeout cap)"; anything else → a short factual note on what's driving the latency
       (don't force it into one of the above buckets if it doesn't fit).
   - **Insert and trim.** Prepend the new rows (highest id first) to the top of the All Samples table.
     Each endpoint keeps a rolling window of its 100 most recent samples — if an endpoint's count in
     the table would exceed 100, remove that endpoint's oldest row(s) from the table (only that
     endpoint's rows; leave a gap in the `#` sequence, don't renumber survivors).
   - **Recompute Summary.** For each endpoint that got new samples, recompute its Summary row (`n`,
     `min`, `p50`, `p95`, `max`, `mean`) from that endpoint's current (post-trim) rows in the All
     Samples table, using nearest-rank percentiles (sort ascending, index = `round(p/100 * (n-1))`).
     Endpoints with no new samples this run keep their existing Summary row untouched.
   - If this run's new data meaningfully shifts a pattern described in the **Analysis** section (a new
     recurring cluster, a note template that no longer fits, a ceiling value that's stopped recurring),
     update that section too — don't let it silently go stale.
10. Update the `Last updated:` line with a one-line summary, using Central time with a `CDT`/`CST`
    suffix (matching whichever applies to "now"), e.g. `Last updated: 2026-07-04T20:30:00 CDT —
    +6 analyze, +3 identify, +2 analyze/stream samples`.
11. If a new sample's total duration is notably worse than that endpoint's current `p95` (i.e. it's
    now the new max, or within 10% of it), mention it by its `#` id and req id in your reply — don't
    add it to `issues-from-logs.md` (a single slow-but-successful request isn't a bug), just flag it
    so the user notices if something's trending worse.

## Reporting back

12. Report back to the user in a few lines: new issues filed, existing issues that recurred, any
    known-benign noise skipped, and the metrics sample counts added per endpoint (plus any notably
    slow new sample per #11). Don't paste either doc in full — point at the files.

## Running this on a schedule

This skill can be invoked ad-hoc (`/check-ai-analyzer-logs`) or on a recurring cadence via
`CronCreate` (e.g. every 5 minutes). Cron jobs created that way are session-only — they stop firing
if this Claude Code session ends, only run while the REPL is idle, and auto-expire after 7 days — so
treat it as "keeps checking while I'm working," not a durable background service. For real
always-on monitoring independent of an open session, this would need a real scheduler (Cloud
Scheduler hitting a small Cloud Function/Run job, or Cloud Logging's own alerting) instead.
