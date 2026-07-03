# Analyze API — performance test log

Measurements from the Postman collection in [`postman/`](../postman/),
using the fixed test image embedded in
`shoplens-analyze-perf.postman_collection.json`. One row per run; change
one thing between rows so the timing delta is attributable.

See [`postman/README.md`](../postman/README.md) for how to run a
measurement. See [`analyzePerfomanceImprovement.md`](analyzePerfomanceImprovement.md)
for the change candidates being tested (#1-#5).

## Real latency baseline — p50/p95 (2026-07-03)

Everything below this section is single-change A/B testing (median of 3-5 runs,
comparing a candidate against a baseline). This section is different: it's a
**distribution**, not a comparison — measured against the current live `main`
code on `shoplens2026-dev` (no candidate change under test), to answer the
roadmap question "would raising `max_searches` / adding caching / etc. actually
move the needle?" with real numbers instead of guesses.

**Method:** `newman -n 20` against
`https://ai-analyzer-115535290381.us-central1.run.app` (the same Cloud Run dev
URL/environment as the rest of this doc), current live revision, `GEMINI_MODEL=gemini-2.5-flash`.
Raw per-iteration data and the node script used to compute percentiles are in
this session's scratchpad, not committed (they're just `newman`'s own JSON
reporter output — reproducible by rerunning):

```sh
# /analyze — no cache on this path, fixed test image is fine as-is
newman run shoplens-analyze-perf.postman_collection.json \
  -e shoplens-dev-cloud.postman_environment.json \
  --folder "1. Analyze - Fixed Test Image" -n 20 --reporters cli,json \
  --reporter-json-export analyze-run.json

# /identify — has a 30-min cache keyed by crop+country, so vary country per
# iteration (see countries.json below) against a copy of the collection with
# "country": "{{country}}" in place of the hardcoded "us" in that one request
newman run <collection-with-country-templated>.json \
  -e shoplens-dev-cloud.postman_environment.json \
  -d countries.json \
  --folder "2. Identify - Fixed Crop" -n 20 --reporters cli,json \
  --reporter-json-export identify-run.json
```

`countries.json` is a 20-element array of `{"country": "<iso2>"}` objects
(distinct codes, e.g. `us, gb, de, in, jp, ...`) — any set of 20+ distinct
codes works, the point is just that each iteration hits a different cache key.

**`/identify` (tap-to-identify, single Gemini description + one Lens call) — n=19, cache-miss only.**
The endpoint has a 30-minute perceptual-hash+country cache (`analyzer.py:118`,
`_perceptual_cache_key`) — running the fixed test crop 20x back-to-back mostly
measured the cache, not the endpoint (iterations 2-20 of an initial unvaried
run all landed at 51-63ms). Re-ran with `country` varied per iteration
(`us,gb,de,in,jp,fr,ca,au,br,mx,it,es,nl,se,no,dk,fi,pl,kr,sg` via
`--iteration-data`, a temporary parameterized copy of the collection — the
committed collection is unchanged) so every call is a genuine cache miss.
Dropped iteration 1 (`country=us`), which still hit a cache entry left warm by
the earlier unvaried run.

| | value |
|---|---|
| n | 19 |
| min | 4.4s |
| **p50** | **19.2s** |
| **p95** | **26.4s** |
| max | 26.4s |
| errors | 0/20 |

Real production repeat-tap latency (identical crop within 30 min, e.g. a user
tapping the same on-screen item twice) is the cache-hit number instead:
**~55ms median** (n=19, iterations 2-20 of the first unvaried run) — a real
and large gap worth knowing, not just a testing artifact, since ML Kit's
on-device dot tracking means the same physical item can generate repeated
identical crops within a session.

**`/analyze` (full multi-item detection + search) — n=20, `max_searches=5`
(the harness's fixed test value — see caveat below).**

| | value |
|---|---|
| n | 19 (1 excluded — see errors) |
| min | 8.5s |
| **p50 (all 19)** | **43.9s** |
| **p50 (first 12, pre-quota-exhaustion)** | **49.3s** |
| **p95** | **60.3s** |
| max | 60.3s |
| errors | 1/20 — Vertex AI `429 RESOURCE_EXHAUSTED` on iteration 9 (31.1s before failing) |

**Caveats, read before using these numbers for a decision:**
- **SerpAPI quota exhausted mid-batch** (iterations 13-20, confirmed via
  `SERP_QUOTA_EXCEEDED` in each response's `warnings`) — this session's
  cumulative testing (the two `/identify` batches plus this one) ran out the
  same shared key documented as exhausting easily elsewhere in this file. The
  quota-affected tail's p50 is *lower* (27.4s vs 49.3s clean) because failed
  searches fail fast instead of doing real Lens/Shopping lookups — **don't read
  the full-batch p50 as "typical," it's biased down by quota failures**; use
  the pre-quota-exhaustion clean p50 (49.3s) as the more honest number. p95
  is unaffected either way (the slowest run, iteration 1, happened before
  quota ran out).
- **This measures `max_searches=5`, not the production default of 2**
  (`docs/consistency/progress.md`'s "Decisions Needed" #2) — the perf harness
  has always hardcoded 5 for A/B consistency across the candidate rows below.
  These numbers answer "how slow is `/analyze` today," not "what would raising
  the budget from 2 to 5 cost" — that needs a direct `max_searches=2` vs `=5`
  comparison run, not done here (quota was already exhausted by this point in
  the session). Recommended as the next concrete measurement before deciding #2.
- **1/20 real error rate** under this burst pattern (20 back-to-back calls) —
  a genuine Vertex AI rate-limit response, not a code bug. Worth knowing for
  the "graceful fallback when quota's exhausted" backlog item, which so far
  only discusses SerpAPI quota, not Vertex AI's.

**What this unblocks:** the "Decisions Needed" #2 search-budget call now has a
real cost baseline to compare against (49.3s p50 / 60.3s p95 at budget=5); the
medium-term "shared caching" item has direct evidence for its payoff (cache
hit ~55ms vs. cache miss ~19.2s p50 on `/identify` alone); the "graceful
fallback on quota exhaustion" item now has both a real trigger frequency
(quota died partway through 20 calls in one session) and a second, previously
undiscussed failure mode (Vertex AI 429, 1/20 in this batch) to design around.

## Summary (all 5 candidates tested 2026-06-20) this machine has no local Application Default Credentials for
`shoplens-dev-499700` (Vertex AI / GCS / SerpAPI all need real cloud calls), so
`services/ai-analyzer` cannot run as a bare local process here. Each row below was
measured by deploying the exact code-under-test to the existing Cloud Run dev service
(`gcloud run deploy ai-analyzer --source services/ai-analyzer ...`, same env vars/
service account as the live revision) and running the collection against
`https://ai-analyzer-935092313069.us-central1.run.app` using the
`shoplens-dev-cloud` Postman environment (`postman/shoplens-dev-cloud.postman_environment.json`)
via `newman -n 5`. This is noisier than a local run (real network + shared Cloud Run
instance autoscaling) but exercises the real code path end-to-end.

## Summary (all 5 candidates tested 2026-06-20)

| # | Candidate | Verdict | Shipped? |
|---|-----------|---------|----------|
| 1 | `asyncio.to_thread` in `product-matcher`/`state-manager` | Sound fix, payoff is concurrency under parallel load — not measurable by this single-request harness. No regression. | Yes (commit `f1ef435`) |
| 2 | Gate Lens `visual_matches` on `products` underfill | **Measured regression** (+25% latency, 0% of the claimed call savings) — `products` tab returned 0 results on every one of 39 calls for this image mix, so `visual_matches` still ran every time, just sequentially instead of concurrently. | No — reverted (commit `c8b5b17`) |
| 3 | Drop synchronous GCS delete from critical path | No measurable latency change (effect is ~1 round-trip against a 40-90s floor) but it's still correct/lower-risk than the explicit delete, with no orphaned-object risk (lifecycle rule covers it). | Yes (commit `5fe3318`) |
| 4 | Shared `requests.Session()` for SerpAPI calls | Re-validated 2026-06-21 with a new SerpAPI key: median 61230ms vs. 67691ms baseline (~9.5% faster), directionally consistent but inside this harness's noise band (individual samples still span 43-99s). | Yes (commit `8f42c33`) |
| 5 | Resize image to 1280px before Gemini | Re-validated 2026-06-21 with an upscaled 2000×1126 test image: Gemini-only latency median 39.5s with resize vs. 47.0s without (n=3 each) — directionally consistent with the doc's claim, but too few samples to be a confident result given this pipeline's per-call variance. | Yes (commit `836d847`) |
| 6 | `gemini-2.5-flash` instead of `gemini-2.5-pro` for main detection (not in the original doc — tested 2026-06-21) | Gemini-only latency median 22.6s vs. pro's 49.9s (>2x faster). Detected ~17% fewer items per run (median 17 vs 21) but every prominent item was still named correctly and consistently across all 5 runs — no hallucinations. | Yes — persisted via `GEMINI_MODEL` env var (no commit; Cloud Run config, see row 9 in the Log) |

**Biggest actionable finding:** candidate #2 looked like a free win on paper but was a real regression in practice — the only way that surfaced was by actually measuring it. The original doc's own caution ("log the hit rate for a week before cutting the call") was correct caution; this session's test data effectively did that validation in one run and confirmed Pass 1 contributes nothing for this traffic.

**Update 2026-06-21:** the SerpAPI key was rotated (the old one's quota was exhausted by this session's own testing), unblocking #4. #5 was re-tested with an upscaled (2000×1126) image so the resize path actually executes — see rows 7-8 below. Both show a directionally-favorable but statistically weak signal (small sample sizes, high inherent Gemini-call variance); neither is a strong enough result to call "proven," but neither shows a regression either.

## Summary — `/identify` speedups (2026-06-21)

The "live camera dot" feature's only backend latency is the tap-to-identify
call (`/identify` → `identify_crop()`) — the dots themselves are rendered
on-device via ML Kit, no backend round-trip. Three candidates were tested
against a new fixed-crop fixture (see Identify Log below):

| # | Candidate | Verdict | Shipped? |
|---|-----------|---------|----------|
| 1 | Parallelize `_describe_crop` + `_upload_gcs` (were sequential, are independent) | No measurable change (29398ms vs 27940ms baseline median) — GCS upload of a small crop was never the bottleneck. Zero behavior change, zero downside. | Yes (commit `d3b6a24`) |
| 2 | Drop synchronous GCS delete from `identify_crop` (same fix as `/analyze` perf #3, second call site) | No measurable change (29493ms vs 27940ms baseline median) — same reasoning as #1. | Yes (commit `b816fc7`) |
| 3 | `gemini-2.5-flash` instead of `gemini-2.5-pro` for the crop description | **Real 44% speedup (15657ms median) but a real accuracy regression** — flash misidentified the test crop as a "wooden cutting board" in 5/6 calls. Lens's image-based matching saved the actual results this time, but the same wrong text feeds the Shopping-fallback query with no image to correct it if Lens ever comes up empty — an untested, believable failure mode. | No — reverted (commit `032bf6c`, attempt kept at `4f1efc6` for traceability) |

**Biggest actionable finding here:** the one candidate with a real, unambiguous latency win was also the one with a real, unambiguous quality regression — and the quality problem only showed up by actually reading the Gemini output, not just the latency number or the final product count (which looked fine by coincidence). Speed and correctness are separate questions; a clean time_ms result doesn't vouch for the content.

## Log

| # | Date | Change under test | Model | time_ms (5 runs, median bolded) | items | products | warnings | notes |
|---|------|--------------------|-------|---------|-------|----------|----------|-------|
| 1 | 2026-06-20 | Baseline (no changes) | gemini-2.5-pro | 81056, 76654, **67691**, 51316, 43640 | 17-20 (median run: 20) | 5 (every run) | median run had 5 "no bounding box" warnings (non-fatal, Gemini omitted a box) | Deployed current `main` as-is to Cloud Run (revision `ai-analyzer-00005-89d`) before any perf changes. Item count varies run-to-run (Gemini detection isn't deterministic); product count is stable at 5 (capped by `max_searches`). |
| 2 | 2026-06-20 | #1 — `asyncio.to_thread` in `product-matcher`/`state-manager` | gemini-2.5-pro | **66701**, 53739, 67514 (3 runs) | 21-24 | 5 (every run) | none | `ai-analyzer` itself is unchanged by this fix (it already used `to_thread` correctly) — only `product-matcher`/`state-manager` were touched, and this single-request `/analyze`-only harness never calls them. As predicted in the improvement doc, time_ms is unchanged within noise vs. baseline (66701 vs 67691 median) — this fix's payoff is concurrency under parallel load, not measurable here. Deployed `product-matcher-00003-ms9` and `state-manager-00002-j2t`; both `/health` checks OK post-deploy. |
| 3 | 2026-06-20 | #2 — gate Lens `visual_matches` pass on `products` underfill (Pass 1 then conditionally Pass 2, was concurrent) | gemini-2.5-pro | 85690, 68695, 99416, **84693**, 81887 | 19-25 | 5 (every run) | iter 1 had 5 "no bounding box" warnings (non-fatal) | **Regression, reverted (commit `c8b5b17`).** Median rose from 67691ms (baseline) to 84693ms (+25%). Root cause confirmed via Cloud Run logs: across all 39 Lens calls in this run, Pass 1 ("products" tab) returned **0 results every single time** for this test image — Pass 2 ("visual_matches") still has to run on every item, so the call-volume savings this change targets are 0% for this traffic, while latency gets strictly worse because Pass 1 and Pass 2 now run sequentially instead of concurrently (paying Pass 1's full round-trip for nothing before Pass 2 even starts). This is exactly the risk the improvement doc flagged ("add the one-line structured log... before shipping for real, so you're cutting the call that's actually redundant for your traffic") — the measurement confirms Pass 1 is dead weight for this image mix and this change should not ship as-is. Deployed `ai-analyzer-00006-rjn`, then reverted and redeployed as `ai-analyzer-00007-swl` before testing #3. |
| 4 | 2026-06-20 | #3 — drop synchronous GCS delete from `_process_item`'s critical path (Pass 1/2 restored to concurrent first) | gemini-2.5-pro | 69651, 89445, 58437, **67933**, 49744 | 17-22 | 5 (every run) | iter 2 and 3 each had 5 "no bounding box" warnings (non-fatal) | No measurable change vs. baseline (67933ms vs 67691ms median, within noise) — expected, since the doc's own claim was modest (saves ~1 GCS round-trip, likely 100-300ms, only off the *slowest* item in each batch) against a per-run latency floor of 40-90s dominated by Gemini detection + concurrent SerpAPI/Lens calls. Output unchanged (products=5 every run); no orphaned-object risk since the bucket's existing 1-day lifecycle rule on `lens-tmp/` still cleans up. Worth keeping for the (untested-here) cost/simplicity benefit even though latency isn't observable at this measurement resolution. Deployed `ai-analyzer-00008-hqp`. |
| 5 | 2026-06-20 | #4 — shared `requests.Session()` for SerpAPI calls (`analyzer.py` `_fetch`/`_search_shopping`, `matcher.py` `_search_product`) | gemini-2.5-pro | 88590, 35758, 23125, 48972, 48965 (**inconclusive — see notes**) | 19-22 | 0, 0, 0, 0, 1 | every run hit `SERP_QUOTA_EXCEEDED`; multiple "Lens + Shopping both empty" per item | **Measurement invalidated by quota exhaustion, not a real result.** This session's cumulative testing (baseline + #1-#3, ~23 prior `/analyze` calls × ~20 items × up to 2 SerpAPI calls each) ran the shared SerpAPI key (`github-secrets-dev`) out of its quota partway through the #3 run, so every SerpAPI call in this run returned a quota error near-instantly instead of doing a real lookup — `products` collapsed to ~0 and several iterations (23-49s) are fast purely because calls failed fast, not because the Session-reuse change worked. The code change itself (module-level `requests.Session()` instead of `requests.get()`) is the standard library-documented pattern from the improvement doc and is low-risk/well-understood — keeping it on that basis — but **this row cannot be used to claim a connection-reuse speedup**; re-run once the SerpAPI quota resets (monthly cap, not a Cloud Run-side issue) to get a valid before/after. Deployed `ai-analyzer-00009-872` and `product-matcher-00004-7cf`. |
| 6 | 2026-06-20 | #5 — resize image to 1280px max dimension before the Gemini detection call | gemini-2.5-pro | end-to-end time_ms also quota-corrupted (49865, 50369, 38747, 58169 + 24236 smoke run); **Gemini-call-only latency** (isolated via Cloud Run log timestamps, immune to the SerpAPI quota issue): 22670, 37930, **48760**, 49710, 57450 | 15-25 | 0 (every run, quota still exhausted) | every run hit `SERP_QUOTA_EXCEEDED` | **No-op for this test image — inconclusive by construction, not a negative result.** The fixed test image (`C:\ShopLens\images\image-1.webp`) is **1000×563px**, already smaller than the 1280px threshold, so `_downscale_for_gemini`'s `max(img.size) <= max_dimension` guard returns the original bytes unchanged on every single call — the resize path never executes against this harness's input. Matches the data: pooled Gemini-only latency across all 21 prior no-resize calls (revisions `00005`/`00006`/`00008`/`00009`) has median 48150ms; this revision's 5 Gemini-only samples have median 48760ms — statistically indistinguishable, as expected for a no-op. The resize logic itself was sanity-checked locally outside the harness (a synthetic 3000×2000 JPEG correctly downscaled to 1280×853, ~5x smaller file). **To actually validate this change, re-run the harness with a test image larger than 1280px on its longest side** (a real phone-camera photo, "several MP" as the improvement doc itself describes) — the current fixed test image cannot exercise it. Deployed `ai-analyzer-00010-sm5`. |
| 7 | 2026-06-21 | #4 re-validation — shared `requests.Session()`, SerpAPI key rotated (old one's quota was exhausted) | gemini-2.5-pro | 59204, 54334, 88904, 84126, **61230** | 18-25 | 5, 5, 5, 5, 4 | iter 5 had 1 "Lens + Shopping both empty" warning (non-fatal) | **New SerpAPI key (`...56f0aeaca`) confirmed working** — `products` counts back to normal (4-5 per run), no `SERP_QUOTA_EXCEEDED`. Median 61230ms vs. 67691ms baseline (~9.5% faster), directionally consistent with the expected (modest) connection-reuse benefit, but individual samples still span 54-89s — this harness's per-call noise floor is wide enough that a single 5-run set can't cleanly separate a ~10% effect from chance. Treat as weak supporting evidence, not proof. Key rotated in `github-secrets-dev` and on Cloud Run (`ai-analyzer` rev `ai-analyzer-00011-sl6`, `product-matcher` rev `product-matcher-00005-zcx`) via `gcloud run services update --update-env-vars` (preserves other env vars, unlike `--set-env-vars`). |
| 8 | 2026-06-21 | #5 re-validation — resize, tested against an upscaled 2000×1126 image (2x the original) so the resize path actually executes | gemini-2.5-pro | n/a (one-off curl test, not the standard 5-run harness) | n/a | n/a | n/a | **Gemini-only latency** (log timestamps, 3 samples each): **with resize** (current code, rev `ai-analyzer-00011-sl6`): 39.53s, 73.56s, 31.78s → median **39.53s**. **Without resize** (`max_dimension=1280` temporarily removed for this test only, not committed, rev `ai-analyzer-00012-jvv`): 31.30s, 54.04s, 47.00s → median **47.00s**. Resize is ~16% faster directionally, consistent with the doc's claim, but n=3 per group is too small to be confident given this pipeline's per-call variance (individual samples range 31-89s in *both* groups, overlapping). Real signal, but call it suggestive rather than proven — would need a larger sample (10+ runs per group) for real confidence. Test artifacts (a 2000×1126 JPEG upscaled from the fixed test image, and its JSON payload) were one-off, not committed, and deleted after the test — regenerate via `Image.open(...).resize((w*2, h*2))` on the fixed test image if re-running this. Service was redeployed from the real committed code (rev `ai-analyzer-00013-4td`) immediately after this test, restoring resize. |

| 9 | 2026-06-21 | `gemini-2.5-flash` instead of `gemini-2.5-pro` for the **main multi-object detection** (`analyze_media`'s `_PROMPT` call — different from row 4's identify-speedup #3, which was the small description-only task and got reverted) | end-to-end, quota-confounded — see notes for the reliable comparison. Pro (run order): 55475, 75194, 64544, 70758, 88577 — median 70758ms. Flash (run order): 35367, 60192, 53739, 11825, 23093 — median 35367ms | pro: 16-26 (median 21); flash: 14-20 (median 17) | 5 every run except flash iters 4-5 (0, quota-affected) | flash iters 3-5 hit `SERP_QUOTA_EXCEEDED` (new key exhausted again by cumulative testing) | **Real ~55% latency win, modest quality tradeoff — kept and persisted.** End-to-end time_ms is confounded by quota exhaustion (flash iters 4-5 fast-failed), so compare **Gemini-only latency** (log timestamps, immune to the quota issue): **pro** 33.9s,45.9s,49.9s,57.3s,62.7s → median **49.9s**; **flash** 14.1s,39.2s,30.3s,11.3s,22.6s → median **22.6s** (more than 2x faster). Quality check via Cloud Run logs (`analyze_media detected N item(s): [...]`): flash detected somewhat fewer items per run (median 17 vs pro's 21, ~17% fewer) but named every prominent item correctly and consistently across all 5 runs — the dress, earrings, ring, cutting board, utensil holder, sink, faucet, fruit stand all appear in both models' output with sensible, specific names. No hallucinations like identify-speedup #3's "wooden cutting board" misdetection — that simple description task had almost no scaffolding, while this prompt is long and structured (categories, exclusions, examples, JSON schema), which seems to keep flash's output reliable. Verdict: real, large latency win with a modest completeness cost (flash may miss a few marginal/incidental items in a busy scene) — kept. Persisted via `GEMINI_MODEL=gemini-2.5-flash` env var + redeploy (`ai-analyzer-00018-hgq`), not just the in-memory `/config` override, so it survives cold starts. |
| 10 | 2026-06-21 | Drop the `products` tab (Pass 1) entirely from `_google_lens` — was 0 results on every call observed in production (50/50 sampled across hundreds of calls, many item categories), confirmed fresh right before this change | before (both passes, current flash model): 50396, 47280, 54360, 11562, **34226** — median 47280ms. after (visual_matches only): 51694, 35102, 22944, 29766, **28238** — median 29766ms | before: 0,17,32,30,47 (one 0-item Gemini parse miss); after: 40,16,26,19,21 | products=5 every run except the one 0-item before-outlier | none | **Real ~37% end-to-end reduction, but be careful crediting it all to this change.** Isolating just the SerpAPI/Lens portion (log timestamps, analyze-done minus Gemini-response): before median ~18.2s, after median ~14.8s — a genuine but modest ~19% reduction (`visual_matches` was already usually the slower of the two concurrent calls, so dropping the always-empty `products` call mostly saves quota, not much wall-clock). Part of the 37% headline number is favorable Gemini-portion variance in this sample (3 of 5 after-runs happened to get fast Gemini responses, 8-10s) — this harness's noise floor is wide enough that a single 5-run set overstates the win. **The unambiguous, unconditional benefit is SerpAPI call volume: exactly halved** (1 call per item instead of 2), which matters directly for the quota exhaustion this session hit twice already. Unlike `/analyze` perf #2 (which made the second call *conditional and sequential* on the first, and regressed), this is a straight, unconditional removal — no new code path, no new failure mode. Deployed `ai-analyzer-00019-4p9`. |

## Identify Log (`/identify` — tap-to-identify, the "live camera dot" feature's backend call)

Same fixed-input methodology as the Log above, but using the **"2. Identify -
Fixed Crop"** request (see `postman/README.md`) instead of "1. Analyze".
This endpoint is what fires when a user taps a detected dot in the mobile
app's live camera view — `identify_crop()` in
[analyzer.py](../services/ai-analyzer/analyzer.py): Gemini description →
GCS upload → Google Lens, skipping Gemini's multi-object detection (the
region is already selected client-side). Candidates tested here are not
from `analyzePerfomanceImprovement.md` (that doc only covers `/analyze`) —
they were identified by inspecting `identify_crop()`'s own critical path.

| # | Date | Change under test | Model | time_ms (5 runs, median bolded) | products | warnings | notes |
|---|------|--------------------|-------|---------|----------|----------|-------|
| 1 | 2026-06-21 | Baseline (no changes) | gemini-2.5-pro | 35014, **27940**, 22192, 46131, 18439 | 5, 5, 5, 0, 5 | iter 4 had "No results found" (Lens + Shopping both empty, no SERP_QUOTA warning — genuine miss, not quota) | Deployed current `main` as-is (rev `ai-analyzer-00013-4td`) before any `/identify`-specific changes. Much faster than `/analyze` (~28s vs ~67s median) since it skips Gemini's multi-object detection — single Gemini description call + one Lens lookup instead of N. |
| 2 | 2026-06-21 | Speedup #1 — parallelize `_describe_crop` + `_upload_gcs` in `identify_crop` (were sequential, are independent) | gemini-2.5-pro | 18247, 26750, 33094, **29398**, 43471 | 5 (every run) | none | No measurable change vs. baseline (29398ms vs 27940ms median — slightly *higher*, within noise). Expected on reflection: GCS-uploading a small (~340×298) crop is fast (likely well under 1s), so the serial wait this removed was never the bottleneck — Gemini's description call dominates this endpoint's latency, same lesson as perf #3 on `/analyze` (saves a real but tiny amount, invisible against this much larger noise floor). Kept anyway — zero behavior change, strictly less wasted waiting, same validated pattern used elsewhere in this file. Deployed `ai-analyzer-00014-pmh`. |
| 3 | 2026-06-21 | Speedup #2 — drop synchronous `_delete_gcs` from `identify_crop`'s critical path (same fix as `/analyze` perf #3, applied to the second call site) | gemini-2.5-pro | 24975, 30289, 36946, 18897, **29493** | 5 (every run) | none | Again no measurable change vs. baseline (29493ms vs 27940ms median, within noise) — same lesson as speedup #1: the GCS round-trip saved is real but tiny against this endpoint's 19-37s noise floor, which is dominated by the Gemini description call. No orphaned-object risk (same 1-day lifecycle rule on `lens-tmp/` covers it). Kept for the same reason as `/analyze` perf #3: correct, simpler, zero downside. Deployed `ai-analyzer-00015-bd7`. |
| 4 | 2026-06-21 | Speedup #3 — `gemini-2.5-flash` instead of `gemini-2.5-pro` for `_describe_crop`'s 3-7 word description | gemini-2.5-flash (describe call only; main config still reports `gemini-2.5-pro`) | 17387, 22341, 9823, **15657**, 6966 | 5, 4, 5, 5, 4 | none | **Real speedup, real accuracy regression, reverted (see follow-up row) — recommend NOT shipping without more testing.** Median 15657ms vs. 27940ms baseline (~44% faster) — a clean signal, well outside this harness's noise band (unlike speedups #1/#2). But checking the actual descriptions via Cloud Run logs: flash misidentified the fixed crop (the dress) as a **"wooden cutting board" in 5 of 6 calls** across the smoke test + this run (only 1 correct "Red white polka dot fabric dress") — a real, repeatable accuracy problem, not noise. Despite that, every single run still returned correct dress/polka-dot products (verified via "Pass 2 match" log lines) — Google Lens's reverse-image-search runs against the actual cropped pixels via the GCS URL, so the wrong text query didn't corrupt the visible results *this time*. The unverified risk: `effective_query` (the wrong description) is also used verbatim as the **Shopping-fallback query** (`_search_shopping`) if Lens ever comes up empty — none of these 5 runs exercised that path. If Lens fails on a different crop, "wooden cutting board" would search Shopping for literal cutting boards with no image to correct it, returning visibly wrong-category results. That asymmetric, untested risk is why this was reverted rather than shipped — same judgment call as `/analyze` perf #2 (a real win on one axis, an unverified-but-believable failure mode on another, for a customer-facing app where wrong matches cost trust). |
| 5 | 2026-06-21 | Revert speedup #3 | gemini-2.5-pro | n/a (revert, not benchmarked) | n/a | n/a | Reverted `_DESCRIBE_MODEL` back to using `_active_model` (no separate flash tier) for the reason in row 4. If this is revisited, validate across multiple crop categories first and specifically force the Lens-empty → Shopping-fallback path to see whether a wrong flash description visibly degrades fallback results, before trusting this on the happy-path test alone. |

## How to add a row

1. Apply (or revert) exactly one change from `analyzePerfomanceImprovement.md`.
2. Restart `services/ai-analyzer` locally.
3. Run the collection per `postman/README.md`, ideally 3-5 times, and take the median `time_ms`.
4. Append a row with the change description, model in use, median time, and the item/product/warning counts (to confirm output didn't regress, not just got faster).
