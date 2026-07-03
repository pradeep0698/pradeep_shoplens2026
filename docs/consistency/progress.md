# Profile Consistency — Progress

Branch: `feature/consistency`
Goal: integrate user profile (country, preferences, shopping categories) into the
analyze pipeline's context/prompt, default region to `us` and derive currency from
country when not set, and improve result relevance by fine-tuning the context/prompt
and the item-selection logic that decides what gets searched under the SerpAPI quota cap.

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

## Log

- 2026-07-02: Branch created, exploration complete, plan written above.
- 2026-07-02: All 4 workstreams complete (ai-analyzer, product-matcher, mobile, docs/verification). Full test suite green: ai-analyzer 9/9, product-matcher 20/20, mobile flutter test 11/11, flutter analyze clean (no new issues), OpenAPI specs regenerated and validated.

## Log

- 2026-07-02: Branch created, exploration complete, plan written above.
