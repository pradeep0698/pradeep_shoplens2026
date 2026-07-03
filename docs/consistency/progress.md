# Profile Consistency — Progress

Branch: `feature/consistency`
Goal: integrate user profile (country, preferences, shopping categories) into the
analyze pipeline's context/prompt, default region to `us` and derive currency from
country when not set, and improve result relevance by fine-tuning the context/prompt
and the item-selection logic that decides what gets searched under the SerpAPI quota cap.

## What to test (for QA / Business)

Plain-language functional requirements — use this section to test the feature without
needing to read code. Environment: **shoplens2026-dev** backend is live, and an Android
test build (.apk) pointed at it is ready — see below for the install file.

### ✅ Ready to test now

**FR-1 — New users (or anyone without a country set) default to the US**
- What changed: if a shopper's profile has no country selected, search now behaves as if
  "United States" were selected — instead of behaving inconsistently or unpredictably.
- How to test: use/create a profile with no country chosen (or clear an existing one), scan
  or search for a product, confirm you get normal results (US retailers/pricing), not an
  error or empty result.
- Pass/fail: no crashes, no blank results, results look like a normal US search.

**FR-2 — Currency shown matches the shopper's country**
- What changed: the app now reports a currency (USD, GBP, EUR, INR, JPY, etc.) that matches
  whatever country is set on the shopper's profile. No country set → USD.
- How to test: set the profile's country to a few different countries (US, UK, Germany,
  India, Japan) one at a time, run a scan/search each time, confirm the currency reported
  matches that country (USD / GBP / EUR / INR / JPY respectively).
- Known limitation (see "In design/planning"): this is a currency **label** only — the
  price number itself is not converted, so don't test/expect converted prices yet.

**FR-3 — Personalized results: preferred categories/brands get priority**
- What changed: if a shopper has set "Preferred Categories" (e.g. Electronics, Furniture)
  or free-text style/brand preferences on their profile, and a scan finds more items than
  the app can look up in one go, the app now looks up the shopper's preferred items first
  instead of picking arbitrarily.
- How to test:
  1. Set a profile's preferred category to, say, "Electronics" and add a preference term
     like "Nike."
  2. Lower "max searches per scan" in the profile to a small number (1–2).
  3. Scan/upload a photo with a mix of preferred and non-preferred items (e.g. electronics
     next to furniture, or a Nike item next to a plain item).
- Pass/fail: results favor the preferred category/brand item(s); a non-preferred item may
  be skipped if the search budget runs out, but a preferred one should not be skipped in
  favor of a non-preferred one.

**FR-4 — Backup ("fallback") search also respects the shopper's country**
- What changed: previously, if the camera-based visual search didn't find a match, the
  app's backup text search always searched as if the shopper were in the US — regardless of
  their real profile country. That's fixed now.
- How to test: set profile country to a non-US country, scan an item likely to need the
  fallback search (something generic/unusual that the visual search may miss), and check
  results look consistent with that region.
- Note: this is the hardest one to eyeball from the UI alone — if a tester can't tell
  whether it worked, flag it here and engineering can confirm via backend logs.

**Install build**
- Android test APK (points at `shoplens2026-dev`): `mobile/build/app/outputs/flutter-apk/app-release.apk`
  (~96 MB), rebuilt 2026-07-02 from this branch **with a blank-screen bug fixed** (see below).
  Side-load onto a test device to run FR-1 through FR-4 above.
- **If you already installed an earlier copy of this APK and got a blank screen instead of the
  login screen, uninstall/reinstall with this rebuilt one** — that was a real bug (not a test
  failure), now fixed. See "Bug found during testing" below for details.

### 🐛 Bug found during testing (fixed)

**Symptom:** opening the first Android test APK showed a blank screen instead of the login
screen — reported by a tester 2026-07-02.

**Cause:** this was a build-configuration bug in the local test-build setup, not a bug in
this branch's feature code. The file that tells the Android build which Firebase project to
connect to was missing several required values, so the built app ended up with a mismatched
identity (new project ID, but old project's credentials) — the app's Firebase login system
fails to start at all in that state, before the login screen ever gets a chance to draw. Same
root file was also pointing the app's backend URLs at the wrong project name, so even past a
Firebase fix it wouldn't have talked to the right servers.

**Fix:** corrected the build configuration, documented the correct values so this doesn't
recur for future test builds, and rebuilt/verified the APK. This did **not** require any
change to the profile-consistency feature itself (FR-1 through FR-4) — it was purely a local
test-build setup issue, now resolved. Engineering detail in the collapsible section below.

### 🔧 In development (not ready to test yet)

- **iOS test build** — not started for this branch.

### 📋 In design / planning (needs a product decision before it's built)

- **Real currency conversion** — today the currency label (FR-2) is correct, but the actual
  price number shown is NOT converted into that currency — it's whatever number the search
  provider returns for that region. Needs a decision: is a currency label sufficient for
  now, or does this need real price conversion before it's customer-facing?
- **Web app (internal admin/demo tool)** — FR-1 through FR-4 only apply to the mobile app.
  The internal web tool does not send profile info to search yet, so none of this is
  testable there.
- **Internal API test collection** — the Postman collection used for API-level QA hasn't
  been updated with the new fields yet. Doesn't affect what a tester sees in the app, but
  matters if QA is testing directly against the API instead of through the app.

<details>
<summary>Engineering deploy details (click to expand)</summary>

- Backend deployed to `shoplens2026-dev`: `ai-analyzer` (revision `ai-analyzer-00002-v6g`)
  and `product-matcher` (revision `product-matcher-00005-s9m`), both serving 100% traffic,
  deployed via `gcloud run deploy --source` on 2026-07-02 (not through the GitHub Actions
  workflow — see the `gh api` note in the Log). `SERPAPI_KEY`/`GCS_LENS_BUCKET`/`PROJECT_ID`
  confirmed live and non-placeholder on both. `state-manager`, `voice-assistant`,
  `pubsub-worker` were not redeployed — untouched by this branch.
- Android build: `flutter build apk --release --dart-define-from-file=.dart_define/shoplens2026-dev.json`
  with `google-services.shoplens2026-dev.json` swapped in for `google-services.json`
  (restored from `.bak` afterward, confirmed clean via `git status`). Completed 2026-07-02.
  Output: `mobile/build/app/outputs/flutter-apk/app-release.apk` (~96 MB, rebuilt after the
  bug fix below — first build was ~92 MB and had the blank-screen bug).
- **Blank-screen bug root cause**: `mobile/.dart_define/shoplens2026-dev.json` (gitignored,
  `mobile/.gitignore:52` excludes all of `.dart_define/` — not tracked in git, must be created
  locally per the setup doc) only set `FIREBASE_PROJECT_ID`. `lib/firebase_options.dart` reads
  4 more keys (`FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID`,
  `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET`) via `String.fromEnvironment`, and
  falls back to hardcoded defaults for the *old* `shoplens-dev-499700` project when a dart-define
  key isn't supplied — so the built app had `FIREBASE_PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7`
  paired with an API key/App ID/sender ID belonging to a different project. `Firebase.initializeApp()`
  in `lib/main.dart:main()` throws on that mismatch, before `runApp()` — hence blank screen, no
  error UI (release build). Separately, the file used `AI_ANALYZER_URL`/`PRODUCT_MATCHER_URL`/etc.,
  but `lib/core/constants/api_constants.dart` actually reads `ANALYZER_API_URL`/`MATCHER_API_URL`/etc.
  — those overrides were silently ignored and the app would have fallen back to the old project's
  URLs baked into the bundled `mobile/.env`.
- **Fix**: corrected `mobile/.dart_define/shoplens2026-dev.json` locally (sourced the 4 missing
  Firebase values from `mobile/android/app/google-services.shoplens2026-dev.json`, renamed the 4
  URL keys), and — since that file is gitignored and this doc (`docs/shoplens2026-dev-setup.md`
  Section 14) is the actual source of truth anyone would copy from — fixed the same bug at its
  source in that doc so it can't recur for the next person/build. Rebuilt and reverified the APK.
- Full engineering task breakdown: see "Todo" below.

</details>

## Scope decisions

- **Currency**: no stored `currency` field. Derive it from `country` via a static
  lookup table (matches the 19-country dropdown in `profile_form.dart`), defaulting
  to `USD`. Confirmed via SerpAPI docs that neither `google_shopping` nor
  `google_lens` engines accept a `currency` param — pricing is implicitly driven by
  `gl` (country) already, so this is a labeling/consistency concern, not a live
  conversion feature.
- **Rollout surfaces**: ai-analyzer, product-matcher, and mobile app wiring are in
  scope. Frontend (Next.js admin/test UI) is out of scope for this pass — it's an
  internal tool, not the consumer app; noted as a follow-up.

## Key findings (baseline, before this branch)

1. `AnalyzeRequest.country` already defaults correctly today: mobile sends `null`
   when `profile.country` is empty, `includeIfNull: false` drops the key, and
   ai-analyzer's Pydantic default (`"us"`) fills in. **Not a bug** — kept as-is,
   just made more defensive (empty-string guard) for robustness.
2. `profile.preferenceTerms` and `profile.shoppingCategories` are collected in the
   profile form and already used for **client-side re-ranking** of results
   (`product_ranker.dart`) — but are **never sent to the backend**. Gemini's
   detection prompt and the SerpAPI-quota item-selection cap have zero awareness of
   user preferences. This is the actual "profile → analyze API context" gap.
3. `services/product-matcher/matcher.py`'s `_shopping_search()` never passes SerpAPI's
   `gl` (country) param at all — real consistency bug. The client-side fallback path
   (`/match`, used when Lens finds nothing) is region-blind regardless of the user's
   profile, while the primary ai-analyzer path is region-aware. Same for `/search`.
4. No `currency` concept exists anywhere in the codebase; pricing is implicitly USD
   everywhere (`product-matcher/main.py` docstring says so explicitly).
5. When Gemini detects more items than `max_searches` allows, both `analyze_media`
   and `analyze_media_stream` truncate with a blind `items_raw[:search_limit]` —
   no prioritization by user preference. Quota gets spent on whatever Gemini listed
   first, not what the user is likely to want.

## Todo

### services/ai-analyzer — DONE
- [x] Add `_COUNTRY_CURRENCY` lookup + `currency_for_country()` / `normalize_country()` helpers in `analyzer.py`
- [x] `AnalyzeRequest` (main.py): add `preference_terms`, `shopping_categories` fields
- [x] Treat empty-string `country` as unset (defensive normalize, not just Pydantic default)
- [x] Build a preference/category context block (mirrors `_build_ignore_block`) and inject into `_PROMPT`
- [x] Prioritize items matching preference_terms/shopping_categories before truncating to `max_searches` (both `analyze_media` and `analyze_media_stream`)
- [x] Thread `preference_terms`/`shopping_categories` through `analyze_media`, `analyze_media_stream` signatures
- [x] Include derived `currency` in `/analyze`, `/analyze/stream` (done event), `/identify` responses
- [x] Log profile context (country/currency/preferences/categories) per request, same pattern as existing `MLKIT |` log line
- [x] Add unit tests for the new pure helpers (currency lookup, prioritization ordering) — `test_analyzer.py`, 9 tests, all pass
- [x] Manual e2e check with mocked Gemini/GCS/Lens: empty country → `us`/`USD`, preference-based prioritization confirmed under `max_searches` cap

### services/product-matcher — DONE
- [x] Add `country` (default `us`) to `MatchRequest` and `SearchRequest`
- [x] Add `preference_terms`/`shopping_categories` to `MatchRequest` for consistent prioritized truncation
- [x] Thread `country` through `matcher.py` (`_shopping_search`, `_search_product`, `match_products`, `search_products`) → SerpAPI `gl` param — fixed the region-blind bug (it never sent `gl` at all before this)
- [x] Prioritize items by preference before truncating to `max_searches` in `match_products` (mirrors ai-analyzer)
- [x] Derive + return `currency` in `/match` and `/search` responses
- [x] Fixed `_search_product`/`search_products` caches to key on country too (were silently country-blind — a GB search could return a cached US result)
- [x] Updated `test_matcher.py`: fixed signature for the monkeypatched `search_products` lambda, added 7 new tests, fixed a pre-existing unrelated test bug (`max_results=99` violated the endpoint's own `le=20` bound before ever reaching the clamp logic — changed to 15). 20/20 pass.

### Mobile app wiring — DONE
- [x] `analyze_request.dart` (+ regenerated `.g.dart` via build_runner): added `preference_terms`, `shopping_categories` fields, now sent to the backend (previously computed for client-side ranking only, never transmitted)
- [x] `match_request.dart` (+ regenerated `.g.dart`): added `country`, `preference_terms`, `shopping_categories`
- [x] `analyze_image_usecase.dart`: sends preference/category fields on `AnalyzeRequest`; `country` now threaded through `execute()` → `_matchInBackground` → `MatchRequest` (previously silently dropped on the product-matcher fallback path)
- [x] `tap_identify_usecase.dart`: sends preference/category fields on `AnalyzeRequest`
- [x] `pipeline_provider.dart`: no change needed — it already passed `country` into `execute()`; the fix was inside `execute()` forwarding it onward
- [x] `flutter pub run build_runner build --delete-conflicting-outputs` — clean regen, diffs match expectations
- [x] `flutter analyze` — no new errors/warnings introduced (1 pre-existing unrelated error in `test/widget_test.dart`, pre-dates this branch)
- [x] `flutter test test/core/utils/product_ranker_test.dart` — 11/11 pass, unaffected

### Docs / verification — DONE
- [x] Ran `update-api-specs` skill: patched `enrich_ai_analyzer()`/`enrich_product_matcher()` in `docs/postman/generate_api_specs_detailed.py` (new response fields `country`/`currency` on `AnalyzeResponse`/`IdentifyResponse`/`MatchResponse`/`SearchResponse` + the stream `done` event; new request examples with `preference_terms`/`shopping_categories`), regenerated `docs/postman/apiSpecs/*.openapi.json` and `docs/api-specs/*.openapi.json`, validated both with `openapi-spec-validator` — OK
- [x] Run product-matcher pytest suite — 20/20 pass
- [x] Run ai-analyzer pytest suite (new) — 9/9 pass
- [x] Run mobile `flutter test` (ranking/unit tests unaffected, confirmed) — 11/11 pass
- [x] Update this file as a running log

**Not done / explicitly out of scope for this pass:**
- Postman collection (`docs/postman/shoplens-all-services.postman_collection.json`) request bodies weren't updated with the new fields — no endpoints were added/removed, only fields on existing bodies, and the collection didn't have `country` in its example bodies even before this branch. Low-priority follow-up.
- Frontend (Next.js) — descoped per the rollout-scope decision above; still sends no `country`/profile context to `/analyze` or `/identify`.
- Currency conversion / mobile-side price formatting — descoped per the currency-scope decision above; `currency` is a response label only, prices are whatever SerpAPI returns for the `country`/`gl` region.

## Summary of changes

**Real bugs fixed** (not just new features):
1. `product-matcher`'s `_shopping_search()` never passed SerpAPI's `gl` (country) param — every `/match`/`/search` call was region-blind regardless of the user's profile, while ai-analyzer's Lens/Shopping calls were already region-aware. Now fixed.
2. `product-matcher`'s SerpAPI response cache (`_search_product`, `search_products`) was keyed without country — a US search and a GB search for the same item name could return each other's cached result. Now keyed on country too.
3. `profile.country` was dropped entirely on the mobile app's product-matcher fallback path (`_matchInBackground`) — now threaded through.

**New capability:**
4. `profile.preferenceTerms`/`profile.shoppingCategories` were collected and used for client-side re-ranking only — Gemini's detection prompt and both services' SerpAPI-quota item-selection caps had zero awareness of them. Now: (a) Gemini's prompt is biased to list preferred items first, and (b) when there are more detected items than `max_searches` allows, both `ai-analyzer` and `product-matcher` prioritize preference/category matches before truncating, instead of an arbitrary cutoff.
5. Currency is now derived from country (lookup table, no new stored field) and returned on every analyze/match/search response for consistency — defaults to USD when country is unset, matching the existing country default.

## Follow-up backlog — broader UX/performance research (2026-07-02)

This branch's scope was profile→context wiring (country/currency/preferences into the prompt
and item-selection truncation). A broader pass across the full pipeline (camera → Gemini →
SerpAPI → ranked results) surfaced further opportunities — not started, listed here so the
next branch can pick up at the top. Prioritized by value-for-effort, not by discovery order.

### Tier 1 — quick wins (small effort, do next)

- [ ] **Unify `_CATEGORY_KEYWORDS`** — duplicated verbatim in `services/ai-analyzer/analyzer.py`,
  `services/product-matcher/matcher.py`, and `mobile/lib/core/utils/product_ranker.dart`. The
  mobile copy has already drifted (missing keywords the backend copies have, e.g. "bed frame",
  "bakeware", "throw"). Same class of bug this branch already fixed twice (missing `gl` param,
  country-blind cache key) — extract to one source of truth.
- [ ] **Weight preference matches by count, not hit/miss** — `_item_priority`/`_prioritize_items`
  in both `analyzer.py` and `matcher.py` use a binary sort key; an item matching 3 preference
  terms ranks identically to one matching 1. Small change to the sort-key tuple.
- [ ] **Aggregate the existing `TIMING |` log lines into real metrics** (Cloud Monitoring custom
  metrics or similar) — no dashboard/p50/p95 exists today. A prior perf doc's latency claims
  were admittedly "inferred from code structure," not measured. This unlocks knowing whether
  any other item on this list is actually worth doing.
- [ ] **Confirm `/analyze/stream` results render incrementally on mobile**, not just at the
  `done` event — the NDJSON streaming plumbing already exists end-to-end; if the UI isn't
  consuming it progressively yet, this is the cheapest "feels faster" win available and may
  just be a UI fix.

### Tier 2 — medium investment (real value, real effort)

- [ ] **Shared cross-request cache (Redis/Memorystore)** replacing product-matcher's in-memory
  `TTLCache(maxsize=500, ttl=1800)` — Cloud Run scale-to-zero wipes the current per-instance
  cache constantly, so real hit-rate across users is near zero in practice. Directly cuts
  SerpAPI spend and reduces `SERP_QUOTA_EXCEEDED` frequency. Tradeoff: new infra dependency.
- [ ] **Add a `price_range` profile field**, fold into the preference/context block — profile
  currently has no budget/brand-affinity signal at all, only category/preference/ignore terms.
- [ ] **Have Gemini return a confidence/salience score per item** — gives the item-selection
  truncation a real fallback sort key (vs. raw Gemini listing order) when nothing matches the
  user's preferences.
- [ ] **Graceful degradation on `SERP_QUOTA_EXCEEDED`** — today it's a warning + blank results;
  a pre-computed "popular items per category" cache could serve as a fallback instead.
- [ ] **Persist `ignore_terms` across sessions** (rolling "last N ignored" per user) instead of
  resetting every scan — compounds over time instead of starting from zero each time.

### Tier 3 — larger investment (strategic, sequence-dependent)

- [ ] **A/B testing scaffolding for prompt/ranking changes** — nothing today measures whether a
  prompt tweak actually helped. Makes every future Tier 1/2 prompt change measurable instead of
  eyeballed. Depends on Tier 1's latency-metrics work landing first.
- [ ] **Category-specific SerpAPI query templates** (electronics → model numbers, clothing →
  brand+size, vs. today's one-size-fits-all name template) — likely valuable, but only
  testable once A/B scaffolding exists above.
- [ ] **Embedding-based near-dup matching** for the fallback path, so near-identical Gemini item
  names (e.g. "white ceramic mug" vs. "cream stoneware mug") share a cache entry instead of
  each cold-querying SerpAPI.
- [ ] **Feedback loop**: log tap/click-through events (product_id, rank position, tapped) and
  periodically re-weight `_CATEGORY_KEYWORDS`/preference terms from real usage instead of a
  static list. Needs an event pipeline + a retraining/re-weighting job — the largest item here.
- [ ] **Pre-warm/batch common category searches** during idle time — depends on the Tier 2
  shared cache existing first.

**Recommended sequencing:** (1) latency metrics — everything else is a guess without it; (2)
shared cross-request cache — cheapest infra win, biggest cost/reliability payoff; (3) unify
`_CATEGORY_KEYWORDS` — small, contained, same bug class already fixed twice on this branch;
(4) the rest, roughly in tier order, since each Tier 3 item's prerequisite (metrics, cache,
A/B infra) needs to land first.

## Log

- 2026-07-02: Branch created, exploration complete, plan written above.
- 2026-07-02: All 4 workstreams complete (ai-analyzer, product-matcher, mobile, docs/verification). Full test suite green: ai-analyzer 9/9, product-matcher 20/20, mobile flutter test 11/11, flutter analyze clean (no new issues), OpenAPI specs regenerated and validated.
- 2026-07-02: Committed feature work (`eba6091`) and pushed `feature/consistency` to origin. Confirmed `origin/main` unchanged (`7c3e828`) and already an ancestor of this branch — nothing to merge.
- 2026-07-02: Deployed `ai-analyzer` + `product-matcher` to `shoplens2026-dev` via `gcloud run deploy --source` (GitHub Actions path blocked by the `gh api` 404 issue). Verified `SERPAPI_KEY` present/non-placeholder on both without printing the value. Started release APK build pointed at `shoplens2026-dev`.
- 2026-07-02: Release APK build finished (`mobile/build/app/outputs/flutter-apk/app-release.apk`, ~92 MB). Restored original `google-services.json` from backup, confirmed clean working tree. Ready for testers — moved from "In development" to "Ready to test" above.
- 2026-07-02: Researched broader end-to-end pipeline performance/consistency opportunities beyond this branch's profile-context scope (latency visibility, caching, ranking signal quality, architectural options). Added as a prioritized "Follow-up backlog" section above for the next branch — nothing in it implemented yet.
- 2026-07-02: Tester reported blank screen instead of login screen on the first Android APK. Root-caused to an incomplete/wrong `mobile/.dart_define/shoplens2026-dev.json` (mismatched Firebase project identity + wrong backend URL variable names) — not a bug in this branch's feature code. Fixed the local dart-define file and its documented source (`docs/shoplens2026-dev-setup.md` Section 14) so it can't recur, rebuilt the APK (~96 MB), restored `google-services.json` again, confirmed clean working tree.
