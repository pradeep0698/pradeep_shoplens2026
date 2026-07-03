# Profile Consistency Initiative — Status Report

*Last updated: 2026-07-03*

## Summary

Shopping results now reflect who the shopper actually is: their region, their stated
preferences, and their preferred categories — instead of every scan being treated as an
anonymous, US-only, preference-blind request. This closes a real gap where the app already
*collected* a shopper's preferences but never *used* them when deciding what to search for,
and fixes two silent regional-consistency bugs along the way.

**Where this stands right now:** the core feature is live on the `shoplens2026-dev`
environment and has been validated against real devices and real backend logs. Testing
surfaced two genuine bugs — both found and fixed. One is already deployed; the other is
implemented and tested but intentionally **held back** to ship as part of the next release
batch rather than as a one-line patch.

## What This Means for Shoppers — Real Scenarios

These are the actual situations this work changes, told the way a shopper would experience
them. QA can use these as ready-made test scenarios (step-by-step scripts are in the
Appendix); for a client demo, these are the story to tell instead of "we added region-aware
preference logic to the backend."

**Scenario 1 — A brand-new shopper who hasn't set a country yet** *(FR-1)*
Alex just installed the app and hasn't touched profile settings yet. They scan a pair of
headphones on a store shelf. Before this work, an unset region was a real edge case that could
have produced broken or empty results. Now the app quietly defaults to US-style results — Alex
never hits a dead end just because they skipped a setup step.
**Status: ✅ Done**

**Scenario 2 — A shopper outside the US sees prices in their own currency** *(FR-2)*
Priya, in Mumbai, has set her country to India. She scans a blender. The result card now shows
"₹2,499" instead of "$2,499" — the currency label matches where she actually is, instead of
defaulting to USD for every shopper regardless of region.
**Demo carefully — important caveat:** this is a currency *label* fix, not live conversion.
The number itself is the same number the search returned; only the currency symbol changed to
match her region. A "₹2,499" result is not necessarily what that item actually costs in
rupees today. Real conversion is an open business decision, not yet built — see "Decisions
Needed" below.
**Status: ✅ Done (label only — see caveat)**

**Scenario 3 — A shopper's stated preferences actually influence what gets checked** *(FR-3)*
Diego told the app he's especially interested in "Electronics" and specifically searches for
"Nike" gear. He scans a cluttered desk — a laptop, a coffee mug, a notebook, a pair of
sneakers. The app can only afford to run a couple of searches per scan (a cost/speed
tradeoff), so *which* items get checked matters. Before this work, Diego's preferences were
collected at signup but never actually used — the app checked items in whatever order it
happened to notice them. Now it prioritizes the laptop and sneakers first, because those match
what Diego said he cares about.
**What testing caught:** a tester added a specific preference, "Smart watch," on top of a
broader "Electronics" category preference and scanned a desk with a smart watch on it. The
smart watch was never picked — a generic "Electronics" match on an unrelated laptop always
won, no matter how specifically the shopper had asked for something else. A shopper's explicit
ask should never lose to a generic category match. That's fixed: an item's category match and
its preference-term matches now both count toward a combined score, instead of category
blindly overriding preference. Fix is tested (38/38) and queued for the next release batch —
**not live yet.**
**Status: 🟡 In progress — fix built and tested, deploying with the next release batch**

**Scenario 4 — The backup search path treats shoppers consistently, too** *(FR-4)*
Sometimes the camera-based search can't confidently identify an item, and the app falls back
to a text-based search instead. Before this work, that fallback path silently ignored the
shopper's region — a UK shopper could fall back to a US-flavored search with no indication
anything had changed. Now the fallback path respects the same region logic as the primary
path, so a shopper never notices the app switched search strategies underneath them.
**Status: ✅ Done**

| # | Scenario | Status |
|---|---|---|
| FR-1 | New shopper, no region set → sensible US default | ✅ Done |
| FR-2 | Currency label matches shopper's region | ✅ Done (label only) |
| FR-3 | Preferences/categories prioritized under a tight search budget | 🟡 In progress (fix built, not yet deployed) |
| FR-4 | Fallback search also respects region | ✅ Done |

### Proposed Feature — Not Yet Built

**PF-1 — Result count adapts to how cluttered the scan is**
Right now, every detected item gets exactly one result back, whether the shopper scanned a
single mug or a five-item desk — the app never shows more than one option per item, and that
limit isn't configurable today. The proposal: give the existing "Search results per scan"
profile dial (1-5, most shoppers including Diego default to 2) a second job. When a scan finds
**multiple items**, cap results-per-item at that dial's value (e.g. 2), so a busy scan doesn't
flood the shopper with a wall of cards. When a scan finds **exactly one item** — including
every single-tap identify — ignore the dial and show up to a new deployment-level default of
**15** results instead. The reasoning: the cost that matters is the number of *searches* run
(one per item, against a shared, metered SerpAPI quota), not the number of *results* a single
search hands back — so there's no cost reason to starve a shopper down to 1-2 options when only
one search happened anyway.
**Status: 🔵 Proposed — spec finalized 2026-07-03, not yet implemented.** *(Full technical
design in the Appendix.)*

## Status at a Glance

| Component | Status | Notes |
|---|---|---|
| Backend logic (region, currency, preference-aware search) | ✅ Done — live on `shoplens2026-dev` | Deployed, validated against real logs |
| Android test build | ✅ Done | Points at `shoplens2026-dev`; one startup bug found & fixed |
| Ranking-fairness fix (Scenario 3 / FR-3) | 🟡 In progress | Tested (38/38), queued for next release batch |
| iOS test build | ⬜ Pipeline | No blockers, just not prioritized yet |
| Production rollout | ⬜ Pipeline | Still confined to the dev/test environment by design |

---

## ✅ Done

Shipped and live on `shoplens2026-dev` today:

- **Region-aware search everywhere.** Both the primary (camera) and fallback (text) search
  paths now use the shopper's actual region, closing a bug where the fallback path silently
  ignored region and a bug where `product-matcher` never sent region to the search provider at
  all.
- **Currency matches region.** Every search response now returns a currency label derived from
  the shopper's country (USD, GBP, EUR, INR, JPY, defaulting to USD when unset) — label only,
  not live conversion (see Decisions Needed).
- **Preferences actually reach the backend.** Preference terms and preferred categories,
  previously collected at signup and never used, are now sent with every scan and used to bias
  both Gemini's detection prompt and which items get searched under the tight search-budget
  cap.
- **Cache correctness fix.** `product-matcher`'s result cache is now keyed by region, closing a
  bug where a US search and a UK search for the same item could return each other's cached
  result.
- **Android test build fixed.** A blank-screen-on-launch bug (missing Firebase config values in
  the dev test-build config) was found, fixed, and the APK rebuilt and reverified.
- **Real latency baseline measured.** p50/p95 numbers against the live deploy, not estimates —
  see the Performance Ideas section below.

## 🟡 In Progress

**Ranking-fairness fix (Scenario 3 / FR-3)** — built, unit-tested (38/38 passing), and
replayed against the tester's original failing scenario to confirm it now produces a correct,
explainable result. **Deliberately held out of production** per direction, to ship as the
first item in a batched release rather than a standalone hotfix. Engineering detail in the
Appendix.

**Next release batch (accumulating):**
1. ✅ Ranking-fairness fix — ready, described above.
2. *(open — add the next item here before this batch ships)*

**Ship checklist once the batch is finalized:** commit → push to `main` → redeploy
`ai-analyzer` + `product-matcher` to `shoplens2026-dev` (backend-only, no new APK needed for
item 1) → re-validate Scenario 3 / FR-3 with the tester's original scenario.

## ⬜ In Pipeline

Not yet started, roughly ordered by what unblocks the most value next:

- **PF-1 — density-aware per-object result cap.** Fully specified (see "Proposed Feature"
  above and Appendix for the technical design) — not yet started. Touches
  `services/ai-analyzer/analyzer.py`, `services/product-matcher/matcher.py`, both `main.py`
  request/response models, and likely mobile UI work to render more than one result card per
  detected item in the multi-object scan flow, which the app has never had to do before.
- **iOS test build.** No blockers — just not yet prioritized.
- **Search-budget A/B (`max_searches=2` vs. `=5`).** Needed to answer Decision #2 below with
  data instead of a guess; deferred because SerpAPI quota ran out mid-measurement session.
- **Currency conversion decision.** Waiting on a business call — see Decisions Needed.
- **Unify the category-keyword list**, currently duplicated (and already drifting) across
  three separate files in the backend and mobile app — the same class of bug as Bug #2 above,
  just waiting to happen again somewhere else.
- **Confirm incremental result rendering on mobile** — the plumbing to stream results in as
  they arrive exists; unclear if the UI actually takes advantage of it yet or just waits for
  everything at once.
- **Extend region/preference awareness to the internal web tool** — explicitly out of scope so
  far; only worth doing if that tool needs to demo this feature to anyone.
- **Production rollout** — still confined to dev/test by design until the above settles.

## 💡 Ideas to Improve Performance

Thoughts and candidate improvements, roughly ordered by expected cost/benefit — not committed
work, and not sequenced into a release yet.

- **We now have real numbers to work from.** Measured 2026-07-03 against the live
  `shoplens2026-dev` deploy (20-run load test per endpoint): `/analyze` p50 **49.3s** / p95
  **60.3s** (at `max_searches=5`; production currently defaults to 2, so this is a
  current-code cost ceiling, not yet a direct answer to the search-budget question below).
  `/identify` p50 **19.2s** / p95 **26.4s** on a cache miss, but only **~55ms** on a cache hit
  (30-minute repeat-crop cache — this is the real latency a shopper feels on a repeat tap).
  Full methodology and raw numbers: [`docs/analyze-perf-test-results.md`](../analyze-perf-test-results.md).
- **Shared caching across users, not just per-session.** Today's cache resets constantly
  because the backend scales to zero between requests. Sharing it across users/instances would
  directly cut search-provider costs and reduce the quota errors seen during testing — likely
  the single cheapest win available.
- **Raise or tune the search budget (`max_searches`) with data, not guesses.** A lot of the
  "which item should win" ambiguity seen in testing traces back to the tight default budget
  (2) rather than the ranking logic itself. Needs the A/B run above before recommending a
  number.
- **Graceful fallback when the search provider's quota is exhausted**, instead of returning
  nothing. This measurement session itself burned through the shared SerpAPI key mid-batch —
  a real, observed failure mode, not a hypothetical.
- **Let Gemini return a confidence score per detected item**, giving item selection a smarter
  signal than "what a shopper happened to type" when preferences don't clearly point to one
  item.
- **Pre-warm common category searches during idle time** to shave latency off first-scan cold
  starts.
- **Near-duplicate item matching** to avoid redundant searches within the same scan.
- **Category-specific search strategies** (e.g. electronics by model number, clothing by
  brand+size) instead of one generic template for every category.
- **A feedback loop that learns preference weighting from what shoppers actually tap**,
  instead of a fixed keyword list that requires an engineer to update it.
- **A/B testing infrastructure** so future ranking/prompt changes can be measured against a
  baseline instead of eyeballed.
- **A budget/price-range preference field**, and **persisting "ignored" items across sessions**
  instead of resetting every scan — both raised in the broader pipeline review, not yet
  scoped.

Also surfaced along the way (during the 2026-07-03 latency run): a 1-in-20 Vertex AI `429
RESOURCE_EXHAUSTED` under burst load — worth keeping an eye on if traffic grows, feeds into
the graceful-fallback idea above.

## Decisions Needed From Business/Product

These aren't bugs — they're places where the team made a scoping call that a business owner
should sign off on before this goes further:

1. **Currency: label vs. real conversion.** Today the app correctly *labels* the currency
   (USD, GBP, EUR, etc.) based on region, but does not convert the actual price number (see
   Scenario 2's caveat above). Is a correct label sufficient for the current phase, or does
   this need real conversion before it's shown to real customers?
2. **Search budget size (`max_searches`).** The default cap on how many items get checked per
   scan is small (2). A lot of "which item should win" ambiguity in testing traces back to
   this tight budget rather than the ranking logic itself — worth a business call on whether
   to raise it, and the cost/latency tradeoff of doing so (see Performance Ideas above).
3. **Rollout scope.** This currently covers the mobile app only. The internal web
   demo/admin tool does not send region/preference data to search at all — low priority
   unless that tool needs to demo this feature to anyone.
4. **PF-1's profile copy and multi-result UI.** PF-1 (see above) reuses the "Search results
   per scan" dial for a second purpose it wasn't originally labeled for — worth a copy review
   so the setting still reads clearly once it also controls per-item result count. It also
   means the multi-object scan flow will need to render more than one result card per item for
   the first time (today it's always exactly one) — worth a quick design opinion on whether
   that's a horizontal carousel, stacked cards, or a "show more" expansion before engineering
   commits to one.

## Known Issues Found & Fixed During Testing

Two real bugs were caught by hands-on testing (not by code review) — both are documented in
full in the Appendix, summarized here:

1. **Blank screen instead of login screen** (Android test build) — a test-build
   configuration file was missing required app-identity values, causing the app to crash on
   startup before showing anything. Fixed and redeployed 2026-07-02 — not a bug in the
   feature itself, and does not affect the currently-installed test build.
2. **Preference fairness bug** (Scenario 3 above) — found, fixed, tested, queued for the next
   push.

This track record (two real, non-trivial bugs found and fixed within two days of testing) is
exactly why real-device testing before merging to production is worth the time it takes.

---

## Appendix — Engineering Detail

<details>
<summary><strong>Functional requirement test scripts (click to expand)</strong></summary>

**FR-1 — Defaults to US when no region is set**
- How to test: use/create a profile with no country chosen, scan or search for a product,
  confirm normal US-style results (no crash, no blank/empty result).

**FR-2 — Currency label matches region**
- How to test: set the profile's country to a few different countries (US, UK, Germany,
  India, Japan), run a scan/search each time, confirm currency shown matches (USD / GBP /
  EUR / INR / JPY). Reminder: label only, price number is not converted.

**FR-3 — Preferred categories/brands get priority under a tight search budget**
- How to test: set a preferred category (e.g. "Electronics") and a preference term (e.g.
  "Nike"), lower "max searches per scan" to 1–2, scan a photo with a mix of matching and
  non-matching items, confirm matching items are prioritized. **Re-test after the next
  deploy** — this is what surfaced the fairness bug being fixed in the next release batch.

**FR-4 — Fallback search also respects region**
- How to test: set a non-US country, scan an item likely to need the backup text-search path
  (something the camera-based search may miss), confirm results look region-consistent.
  Hardest to eyeball from the UI alone — engineering can confirm via backend logs if unclear.

**Install build:** `mobile/build/app/outputs/flutter-apk/app-release.apk` (~96 MB), points at
`shoplens2026-dev`, rebuilt 2026-07-02 with the blank-screen bug fixed.

</details>

<details>
<summary><strong>Bug #1 — blank screen instead of login screen (full detail)</strong></summary>

**Symptom:** opening the first Android test APK showed a blank screen instead of the login
screen.

**Cause:** `mobile/.dart_define/shoplens2026-dev.json` (gitignored — not tracked in git,
`docs/shoplens2026-dev-setup.md` Section 14 is its only source of truth) was missing 4 of 5
required Firebase identity values. `lib/firebase_options.dart` silently fell back to a
*different, older* Firebase project's hardcoded defaults for the missing ones — pairing the
new project ID with the old project's API key/App ID/sender ID. `Firebase.initializeApp()`
throws on that mismatch inside `main()`, before any UI renders — hence blank screen, no error
shown (release build). Separately, the same file used the wrong variable names for the
backend URLs, so those overrides were silently ignored too.

**Fix:** corrected the local dart-define file and — since it's gitignored — fixed the same
bug at its actual source, `docs/shoplens2026-dev-setup.md` Section 14, so it can't recur for
future builds. Rebuilt and reverified the APK (~96 MB). Deployed/resolved 2026-07-02.

</details>

<details>
<summary><strong>Bug #2 — preference fairness + plural matching (full detail)</strong></summary>

**Symptom:** a tester added "Smart watch" and "laptops" as explicit preferences on top of an
"Electronics" preferred category, scanned a desk photo, and expected the smart watch to be
favored. It wasn't picked at all, and the "laptops" preference appeared to have no effect.

**Cause (two compounding issues):**
1. The ranking logic checked "does this item match the preferred category?" *before* "does
   it match a preference term?" — any category match, even with zero preference matches,
   unconditionally outranked every item with a preference match but no category match. A
   shopper's specific, explicit preference could never beat a generic category match.
2. Preference terms were matched as exact literal text only — "laptops" (plural, as typed)
   never matched an item named "...laptop" (singular), so that term had zero effect even on
   items it clearly described.

**Fix:** category match and each matching preference term now each contribute a point to a
combined score (additive), instead of category unconditionally overriding preference.
Preference matching now also tolerates simple plurals ("laptops" ↔ "laptop") in either
direction. Replayed the tester's exact scenario against the fix: the items that now win (a
laptop and a laptop stand) do so because "laptops" now correctly matches both, giving them a
stronger *combined* score than the smart watch's single preference-only match — a legitimate,
explainable result instead of the previous blind bug. Added 10 new unit tests (14/14
ai-analyzer, 24/24 product-matcher — 38/38 total).

**Changed:** `services/ai-analyzer/analyzer.py` (`_preference_sort_key` → `_preference_score`,
additive; added `_term_matches` with plural tolerance), `services/product-matcher/matcher.py`
(same pattern: `_item_priority` → `_item_score`, added `_term_matches`). No mobile/APK change
needed — backend-only. **Status: implemented and tested, held for the next release batch per
your direction — not yet committed or deployed.**

</details>

<details>
<summary><strong>PF-1 — density-aware per-object result cap (technical design, not yet built)</strong></summary>

**What exists today:**
- The "Search results per scan" profile dial is `maxSearchesPerRun` in Dart
  (`mobile/lib/data/models/user_profile.dart`), Firestore key `max_searches_per_run`, sent to
  both backends as `max_searches` (`AnalyzeRequest`/`MatchRequest`). Range 1-5
  (`maxSearchesPerRunCeiling = 5`), default 2 (`defaultMaxSearchesPerRun`). UI: profile
  settings, "Search results per scan," subtitle "How many product searches to run per scan
  (1-5). Lower is faster, higher finds more."
- Today this field has exactly **one** job: capping how many *detected items* get searched at
  all in the multi-item `/analyze` and `/match` flows —
  `services/ai-analyzer/analyzer.py:946-954` (and the streaming variant, `~1147-1150`):
  `items_raw = items_raw[:search_limit]`; mirrored in
  `services/product-matcher/matcher.py:307-311`.
- **Results per item are currently hardcoded to 1** in that same multi-item pipeline —
  `services/ai-analyzer/analyzer.py:993-998` (`_google_lens(..., max_results=1)` /
  `_search_shopping(..., max_results=1)`, duplicated `~1188-1194` in the streaming variant) and
  `services/product-matcher/matcher.py:175-193` (`_search_product` fetches 3 raw results via
  `_shopping_search(item, 3, ...)` but only ever keeps `results[0]`). This cap isn't named or
  configurable anywhere — it's an implicit `1`.
- The **single-tap `/identify` flow is the one place today that already returns more than one
  result for an item** — `identify_crop` (`analyzer.py:730-736`, called from `main.py:482`)
  returns up to `max_results=clamp_max_searches(request.max_searches)`, i.e. it piggybacks on
  the same 1-5 dial, capped at the ceiling of 5. Mobile further truncates this to 5 via
  `.take(5)` in `tap_identify_usecase.dart:49-52`.

**Proposed change:**
1. Add a new deployment-level env var, `MAX_RESULTS_PER_ITEM` (default `"15"`), read the same
   way other numeric env vars already are in this codebase
   (`_LENS_TIMEOUT = int(os.environ.get("LENS_TIMEOUT_SECONDS", "12"))` is the existing
   pattern to follow) — in both `services/ai-analyzer/analyzer.py` and
   `services/product-matcher/matcher.py`.
2. In the multi-item `/analyze` and `/match` flows: when more than one item is being searched
   this run, replace the hardcoded `max_results=1` (and matcher.py's `results[0]`) with
   `min(clamp_max_searches(request.max_searches), MAX_RESULTS_PER_ITEM)` — e.g. a shopper on
   the default dial value of 2 now gets 2 results per item instead of 1.
3. When exactly one item is being searched this run (a single-object `/analyze` scan, or every
   `/identify` call, which is definitionally single-object) — ignore the dial entirely and use
   `MAX_RESULTS_PER_ITEM` (15) directly. This means `/identify`'s `max_results` changes from
   "derived from `max_searches`, capped at 5" to "always up to the deployment default of 15,"
   and the mobile `.take(5)` in `tap_identify_usecase.dart` should be raised to match (or
   removed, since the server would already be enforcing the real cap).
4. `MAX_SEARCHES_PER_RUN` (the item-count ceiling, currently a hardcoded `= 5` module constant
   in both services) is unrelated to this change and stays as-is — this feature only touches
   results-*per*-item, not how many items get searched.

**Open questions** (see "Decisions Needed" #4): profile-copy wording for the dial's second job,
and how the mobile UI should render >1 result card per item in the multi-object flow, which it
has never had to do before (today's UI structure has always assumed exactly one result per
detected item).

**Status: specified 2026-07-03, not started.** No code changes yet.

</details>

<details>
<summary><strong>What shipped in the current live deploy (click to expand)</strong></summary>

**Real bugs fixed (not just new features):**
1. `product-matcher` never sent the search provider's region parameter at all — `/match` and
   `/search` were region-blind regardless of the shopper's profile, while the primary search
   path was already region-aware.
2. `product-matcher`'s result cache wasn't keyed by region — a US search and a UK search for
   the same item could return each other's cached result.
3. A shopper's region was dropped entirely on the mobile app's backup-search fallback path.

**New capability:**
4. A shopper's preference terms and preferred categories are now sent to the backend at all
   (previously collected but never transmitted) and used to bias both Gemini's detection
   prompt and which items get searched under the search-budget cap.
5. Currency is derived from region (no new stored field) and returned on every search
   response for consistency, defaulting to USD.

**Deploy record:** `ai-analyzer` (revision `ai-analyzer-00002-v6g`) and `product-matcher`
(revision `product-matcher-00005-s9m`) on `shoplens2026-dev`, deployed via
`gcloud run deploy --source` on 2026-07-02 (GitHub Actions deploy path is blocked by an
unrelated, known `gh` CLI API issue against this repo — see `docs/github/github-accounts.md`).
`state-manager`, `voice-assistant`, `pubsub-worker` were not touched by this work.

**Scope decisions made:**
- Currency is a derived label (lookup table from region), not a stored field or a real
  conversion — the search provider has no currency parameter of its own, so this is a
  labeling/consistency fix, not a live-conversion feature.
- Rollout covers ai-analyzer, product-matcher, and the mobile app. The internal web
  admin/demo tool was explicitly descoped.

</details>

<details>
<summary><strong>Original engineering task checklist (click to expand)</strong></summary>

All items below are complete and shipped in the current live deploy unless marked otherwise.

**services/ai-analyzer**
- Region/currency lookup + normalization helpers
- `preference_terms`/`shopping_categories` added to the request model
- Empty region defensively treated as unset
- Preference/category context injected into the Gemini prompt
- Items matching preferences prioritized before truncating to the search-budget cap
- Currency included in all response types
- Profile context logged per request
- 9 unit tests + manual end-to-end check (now 14, see Bug #2)

**services/product-matcher**
- Region + preference/category fields added to request models
- Region threaded through to the search provider call (was the region-blind bug)
- Preference-based prioritization mirrored from ai-analyzer
- Currency derivation + response inclusion
- Cache keys fixed to include region (was the cache bug)
- Test suite updated, 20 tests passing (now 24, see Bug #2)

**Mobile app wiring**
- Request models extended to actually send preference/category/region data
- Both the primary and fallback search paths updated
- Code generation regenerated cleanly, static analysis clean, existing tests unaffected (11/11)

**Docs / verification**
- API specs (OpenAPI, Postman-adjacent) regenerated and validated
- Full test suite green across all three surfaces at time of merge
- Postman collection request bodies *not* updated with new fields (low priority — no
  endpoints changed, only fields on existing bodies)
- Internal web app and real currency conversion explicitly out of scope for this pass

</details>

<details>
<summary><strong>Full activity log (click to expand)</strong></summary>

- 2026-07-02: Branch created, exploration complete, plan written.
- 2026-07-02: All engineering workstreams complete (ai-analyzer, product-matcher, mobile,
  docs/verification). Full test suite green.
- 2026-07-02: Feature work committed and pushed to a feature branch.
- 2026-07-02: Backend deployed to `shoplens2026-dev` directly via `gcloud` (GitHub Actions
  path blocked by a known `gh` CLI API issue). Confirmed the search-provider key was present
  and valid without ever printing its value. Started the Android test build.
- 2026-07-02: Android test build finished (~92 MB).
- 2026-07-02: Broader end-to-end research pass added as a prioritized backlog for future work
  (now folded into "In Pipeline" / "Ideas to Improve Performance" above).
- 2026-07-02: Tester reported blank screen instead of login screen. Root-caused, fixed, APK
  rebuilt (~96 MB) and reverified.
- 2026-07-02: Feature branch merged into `main` (clean fast-forward) and pushed. Live
  `shoplens2026-dev` deploy already matched this code.
- 2026-07-02/03: Walked a tester through two production log excerpts on request, confirming
  the new logic was live and correctly prioritizing category-matching items under the
  search-budget cap.
- 2026-07-03: Tester's expanded preference test surfaced the fairness bug (Bug #2 / Scenario
  3). Found, fixed, tested (38/38), replayed against the original scenario to confirm the new
  result is legitimate. **Held back from deployment** per direction to bundle into the next
  release batch rather than ship as a standalone hotfix.
- 2026-07-03: Doc reorganized — added shopper-facing scenario narratives for QA/client
  visibility, merged the roadmap and research backlog into one "Plan of Action."
- 2026-07-03: Measured real `/analyze` and `/identify` p50/p95 latency against the live
  `shoplens2026-dev` deploy (20-run load test each, cache-busted for `/identify`) — see
  [`docs/analyze-perf-test-results.md`](../analyze-perf-test-results.md).
  Closes the "real latency numbers" near-term roadmap item; the search-budget A/B (2 vs. 5)
  needed to fully answer Decision #2 is still open, deferred after this session's SerpAPI
  quota ran out again.
- 2026-07-03: Doc restructured into Done / In Progress / In Pipeline / Ideas to Improve
  Performance sections for clearer client- and status-at-a-glance reading.
- 2026-07-03: Captured PF-1 (density-aware per-object result cap) as a fully specified,
  not-yet-started feature — reuses the existing "Search results per scan" dial for multi-object
  scans, adds a new `MAX_RESULTS_PER_ITEM` deployment default (15) for single-object scans.
  Raised two open questions (profile copy, multi-result UI) under Decisions Needed.

</details>
