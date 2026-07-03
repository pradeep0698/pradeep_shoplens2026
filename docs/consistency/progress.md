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
surfaced two genuine bugs — both found, fixed, and one already deployed. A second fix is
implemented and tested but intentionally **held back** to be bundled with additional changes
into the next push, rather than shipped as a one-line patch.

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
**Status: ✅ Confirmed**

**Scenario 2 — A shopper outside the US sees prices in their own currency** *(FR-2)*
Priya, in Mumbai, has set her country to India. She scans a blender. The result card now shows
"₹2,499" instead of "$2,499" — the currency label matches where she actually is, instead of
defaulting to USD for every shopper regardless of region.
**Demo carefully — important caveat:** this is a currency *label* fix, not live conversion.
The number itself is the same number the search returned; only the currency symbol changed to
match her region. A "₹2,499" result is not necessarily what that item actually costs in
rupees today. Real conversion is an open business decision, not yet built — see "Decisions
Needed" below.
**Status: ✅ Confirmed (label only — see caveat)**

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
**Status: ⚠️ Confirmed working as designed — but the real-device test above exposed a
fairness bug. Fix ready, not yet deployed.**

**Scenario 4 — The backup search path treats shoppers consistently, too** *(FR-4)*
Sometimes the camera-based search can't confidently identify an item, and the app falls back
to a text-based search instead. Before this work, that fallback path silently ignored the
shopper's region — a UK shopper could fall back to a US-flavored search with no indication
anything had changed. Now the fallback path respects the same region logic as the primary
path, so a shopper never notices the app switched search strategies underneath them.
**Status: ✅ Confirmed**

| # | Scenario | Status |
|---|---|---|
| FR-1 | New shopper, no region set → sensible US default | ✅ Confirmed |
| FR-2 | Currency label matches shopper's region | ✅ Confirmed (label only) |
| FR-3 | Preferences/categories prioritized under a tight search budget | ⚠️ Working, fix for exposed bug queued |
| FR-4 | Fallback search also respects region | ✅ Confirmed |

## Status at a Glance

| Component | Status | Notes |
|---|---|---|
| Backend logic (region, currency, preference-aware search) | 🟢 Live on `shoplens2026-dev` | Deployed, validated against real logs |
| Android test build | 🟢 Available | Points at `shoplens2026-dev`; one startup bug found & fixed |
| iOS test build | ⚪ Not started | No blockers, just not prioritized yet |
| Ranking-fairness fix (bug #2, Scenario 3) | 🟡 Ready, held for next batch | Tested (38/38), not yet pushed — see "Next Release Batch" |
| Production rollout | ⚪ Not started | Still confined to the dev/test environment by design |

## Next Release Batch (accumulating — not yet pushed)

Per your direction, this isn't going out as a standalone hotfix — it's the first item in a
batch. Add more items here as they're decided; nothing in this section ships until the whole
batch is committed and deployed together.

1. **✅ Ranking-fairness fix** — done and tested locally. A shopper's explicit preference
   (e.g. typing "Smart watch") was being unfairly overridden by a broader category match
   (e.g. "Electronics" catching a laptop) no matter what — found via real-device testing, not
   theoretical. Also fixed: preference terms typed in plural ("laptops") weren't matching
   singular item names ("laptop"). 38/38 tests pass. *(Engineering detail in Appendix.)*
2. *(open — add the next item here)*

**When this batch is ready to ship:** commit → push to `main` → redeploy `ai-analyzer` +
`product-matcher` to `shoplens2026-dev` (backend-only, no new APK needed for item 1) →
re-validate Scenario 3 / FR-3 with the tester's original scenario.

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
   to raise it, and the cost/latency tradeoff of doing so.
3. **Rollout scope.** This currently covers the mobile app only. The internal web
   demo/admin tool does not send region/preference data to search at all — low priority
   unless that tool needs to demo this feature to anyone.

## Plan of Action

One prioritized roadmap — everything the team knows about, ordered by what unblocks the most
value for the least cost. Items are drawn both from this initiative and from a broader
end-to-end pipeline review (camera → detection → search → ranked results) done alongside it.

### Immediate — this release
- Ship the "Next Release Batch" above once it's finalized.
- Re-validate Scenario 3 / FR-3 with the original tester's scenario after redeploy.

### Near-term — next few cycles
Suggested order: latency metrics first (several items below are just guesses without it),
then shared caching (cheapest win, biggest cost/reliability payoff), then the keyword-list
unification (small, contained, and the same class of bug already hit twice).
- ✅ **Real latency numbers (p50/p95)** — measured 2026-07-03 against the live
  `shoplens2026-dev` deploy (20-run load test per endpoint, not estimates). Full
  methodology, caveats, and raw numbers in the "Real latency baseline" section of
  [`docs/analyze-perf-test-results.md`](../analyze-perf-test-results.md).
  Headline: `/analyze` p50 **49.3s** / p95 **60.3s** (at `max_searches=5`, the
  harness's fixed value — production defaults to 2, so this isn't yet a direct
  answer to the search-budget decision below, just the current-code cost
  baseline); `/identify` p50 **19.2s** / p95 **26.4s** on a cache miss, but
  **~55ms** on a cache hit (30-min repeat-crop cache — real production
  repeat-tap latency). Also surfaced two real reliability data points along
  the way: a 1/20 Vertex AI `429 RESOURCE_EXHAUSTED` under burst load, and the
  shared SerpAPI key exhausting mid-batch purely from this measurement
  session's own traffic — both feed the "graceful fallback on quota
  exhaustion" item below.
- Resolve the two "Decisions Needed" items above (currency conversion, search budget) — the
  budget half of #2 still needs a direct `max_searches=2` vs `=5` A/B latency run (not done in
  this pass; SerpAPI quota was already exhausted by the time latency measurement finished).
- Unify the category-keyword list, currently duplicated (and already drifting) across three
  separate files in the backend and mobile app.
- Confirm search results actually render incrementally on mobile as they stream in, not just
  all at once at the end — the plumbing exists, may just need a UI fix.
- Extend region/preference awareness to the internal web tool, if/when needed.

### Medium-term
- Shared caching across users/instances (today's cache resets constantly because the backend
  scales to zero) — directly reduces search-provider costs and quota errors.
- Let Gemini return a confidence score per detected item, so item selection has a smarter
  fallback signal than just "what a shopper happened to type."
- Graceful fallback when the search provider's quota is exhausted, instead of returning
  nothing.
- A budget/price-range preference field.
- Persist "ignored" items across sessions instead of resetting every scan.

### Long-term / strategic bets
- A/B testing infrastructure so future ranking/prompt changes can be measured, not eyeballed.
- A feedback loop that learns preference weighting from what shoppers actually tap, instead
  of a fixed keyword list.
- Category-specific search strategies (e.g. electronics search by model number, clothing by
  brand+size) instead of one generic template for everything.
- Near-duplicate item matching to reduce redundant searches.
- Pre-warming common category searches during idle time.

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
  (now folded into "Plan of Action" above).
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

</details>
