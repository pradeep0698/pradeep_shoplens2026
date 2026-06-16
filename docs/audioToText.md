# Voice-to-Preferences: Audio Transcription → Personalization → Product Shortlisting

**Use case:** User speaks (e.g. "I'm looking for a birthday gift for my mom — she likes minimalist home decor in earthy tones, nothing floral, budget under $50"). The app transcribes the audio to text, lets the user review/edit/accept it, converts the accepted text into structured **personalization preferences**, and uses those preferences to shortlist products in the existing tap-to-identify and image-upload flows.

**Current stack:** Flutter app (`mobile/`) on Riverpod + GoRouter + Dio, Firebase Auth/Firestore, talking to three Cloud Run services (`ai-analyzer`, `product-matcher`, `state-manager`). `ai-analyzer` already runs Gemini (`google-genai>=1.0.0`, default `gemini-2.5-pro`) for image item-detection and crop description.

**Research date:** 2026-06-14 | Status: **research/design only — no code written**

---

## TL;DR Recommendation

1. **Transcription (on-device, MVP):** Use the Flutter [`speech_to_text`](https://pub.dev/packages/speech_to_text) package (v7.4.0, wraps Android `SpeechRecognizer` / iOS `SFSpeechRecognizer`). Free, no new backend dependency, live partial-transcript captions while recording, audio never leaves the device.
2. **Review step:** Show the transcript in an editable text field with "Try again / Edit / Use this" — standard voice-dictation review pattern. This is the gate that turns noisy STT output into a trustworthy input for the next step.
3. **Preference extraction:** Send the *accepted text* (not audio) to a new lightweight endpoint on the existing `ai-analyzer` service (`POST /preferences/extract`). Use Gemini **structured output** (`response_schema` with a Pydantic model — already supported by the `google-genai` SDK version pinned in `requirements.txt`) to turn free text into a typed `PreferenceExtraction` object: shopping categories (subset of the existing 8), preference terms, ignore terms, optional price ceiling, and a human-readable summary.
4. **Second review step:** Show the extracted preferences as editable chips (reuse `ProfileForm`'s existing category-checkbox/term-chip styling) so the user edits/accepts the *structured* result too — this is the "personalization settings" step.
5. **Persistence:** Merge into the **existing** `UserProfile` Firestore document (`UserProfiles/{uid}` → `shopping_categories`, `preference_terms`, `ignore_terms`). No new collection, no schema fork.
6. **Shortlisting integration is mostly free**: `ignore_terms` already flows into the Gemini item-detection prompt's exclusion block, and `shopping_categories` already drives `rankProducts()`/`isPreferred()` for both the gallery-upload and tap-to-identify flows. **One real gap found**: `preferenceTerms` is currently passed into `rankProducts()` as if it were a list of category names, which it isn't — so free-text preference terms (style/brand/material words, which is what voice input will mostly produce) are largely **inert for ranking today**. This should be fixed as part of (or just before) this feature, otherwise voice-derived style/brand preferences won't visibly affect the shortlist.

---

## 1. Goals & Non-Goals

**Goals**
- Let a user state shopping preferences by voice instead of (or in addition to) the manual comma-separated fields in `ProfileForm`.
- Make the transcript reviewable/editable before it's used for anything (correct STT errors, add detail).
- Convert the reviewed text into the *same* structured personalization fields the app already understands (`shoppingCategories`, `preferenceTerms`, `ignoreTerms`, optionally a price ceiling).
- Make those preferences influence what's shown when the user **taps an object** in Live Scan or **uploads an image/photo** — i.e. the existing `/analyze` and `/identify` pipelines.

**Non-goals (for this research)**
- No code changes — this document is a design/research artifact.
- No always-listening / continuous-dictation mode (out of scope; `speech_to_text` itself isn't designed for that).
- No multi-turn conversational preference interview (single utterance → single review cycle, for MVP).

---

## 2. Current State (what already exists)

This is the part of the codebase the new feature must slot into. (See also `[[project_video_feature]]`-style file maps in memory for the architecture conventions used in this repo.)

### 2.1 User personalization today
- **Model**: `mobile/lib/data/models/user_profile.dart` — Freezed `UserProfile` with `shoppingCategories: List<String>`, `preferenceTerms: List<String>`, `ignoreTerms: List<String>`, `country`, etc.
- **Storage**: Firestore `UserProfiles/{uid}`, snake_case fields (`shopping_categories`, `preference_terms`, `ignore_terms`), read/written via `FirestoreSource.watchProfile()` / `saveProfile()`.
- **UI**: `mobile/lib/presentation/widgets/profile_form.dart` — 8 fixed category checkboxes (`Furniture`, `Clothing`, `Kitchen & Cookware`, `Accessories`, `Electronics`, `Home Decor`, `Sports & Outdoors`, `Books & Stationery`) plus two free-text comma-separated fields for `ignoreTerms` ("Hidden from analysis and matching") and `preferenceTerms` ("These matches float to the top").

### 2.2 Image → product shortlisting today
Two entry points, both ending at the same ranking/session-save logic:

| Entry point | File | Backend call | Notes |
|---|---|---|---|
| Gallery pick / Live Scan "Identify" (full frame) | `mobile/lib/domain/usecases/analyze_image_usecase.dart` via `pipeline_provider.dart` | `POST /analyze` (ai-analyzer) → optional `POST /match` (product-matcher) | Gemini detects items + (if Lens enabled) returns visual matches directly |
| Tap an object in Live Scan (crop) | `mobile/lib/domain/usecases/tap_identify_usecase.dart` | `POST /identify` (ai-analyzer) | Skips Gemini re-detection on the crop, goes straight to Lens via GCS |

Both call `rankProducts(products, preferenceTerms, isExactMatchSource: ...)` from `mobile/lib/core/utils/product_ranker.dart` before saving to `LiveShoppingSessions/{sessionId}`.

### 2.3 How preferences currently reach the backend/ranking

| Field | Sent to backend? | Used server-side? | Used client-side? |
|---|---|---|---|
| `ignoreTerms` | ✅ `AnalyzeRequest.ignore_terms` | ✅ folded into Gemini's "STRICTLY EXCLUDE" block via `_build_ignore_block()` in `services/ai-analyzer/analyzer.py` | also passed to `_matchInBackground` for the matcher fallback |
| `shoppingCategories` | ❌ never sent | ❌ | ✅ `main_screen.dart:222` calls `rankProducts(products, shoppingCategories, ...)` → `isPreferred()` matches `product.category` against this list. Also used directly in `product_card.dart` to badge "preferred" products. |
| `preferenceTerms` | ❌ never sent | ❌ | ⚠️ Passed into `rankProducts()` **as the `shoppingCategories` parameter** inside `analyze_image_usecase.dart` and `tap_identify_usecase.dart`. Since `rankProducts`/`isPreferred` only matches against the 8 fixed category names (or their hardcoded fallback keyword lists), free-text preference terms like "minimalist" or "Nike" essentially never match → **no ranking effect**. |
| `transcript` | ✅ `AnalyzeRequest.transcript` (Dart) → `AnalyzeRequest.transcript` (FastAPI) → `analyze_media(transcript=...)` | ❌ accepted but **never read** inside `analyze_media` — `_PROMPT.format()` only injects `ignore_block` | ❌ always sent as `''` today |

**Implication**: there is already an end-to-end-plumbed-but-unused `transcript` string field on the analyze pipeline. It's effectively a half-built hook for "send some natural-language context alongside the image."

### 2.4 Gemini integration in `ai-analyzer`
- `services/ai-analyzer/analyzer.py` — `_get_client()` returns a `google.genai` client; `_active_model` defaults to `gemini-2.5-pro` (overridable via `/config`).
- Already does prompt-based JSON extraction today: `_PROMPT` (item detection, returns a JSON array) and `_IDENTIFY_PROMPT` (`_describe_crop`, returns a short text description) — both use `client.models.generate_content(...)`.
- `requirements.txt` pins `google-genai>=1.0.0`, which supports `GenerateContentConfig(response_mime_type="application/json", response_schema=<Pydantic model>)` and `response.parsed` for typed structured output.
- Per `[[project_analyzer_reliability]]`, the service already has per-request correlation IDs, timing, and exception-type logging conventions — a new endpoint should follow the same pattern.

### 2.5 What's missing for voice input
- No audio/speech packages in `pubspec.yaml` (`speech_to_text`, `record`, `permission_handler` — none present).
- No microphone permissions declared:
  - Android (`mobile/android/app/src/main/AndroidManifest.xml`) currently declares `INTERNET`, `CAMERA`, `READ_EXTERNAL_STORAGE`, `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS` — no `RECORD_AUDIO`.
  - iOS (`mobile/ios/Runner/Info.plist`) declares `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` — no `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`.
- No "Settings"/voice entry point — preferences live entirely inside `ProfileScreen` → `ProfileForm`.

---

## 3. Step-by-Step Design

```
 ┌──────────────┐   ┌────────────────────┐   ┌──────────────────────┐   ┌───────────────────────┐   ┌──────────────────────────┐
 │ 1. Record    │──▶│ 2. Live transcript  │──▶│ 3. Review & edit text │──▶│ 4. Extract preferences │──▶│ 5. Review & edit chips    │
 │  (mic tap)   │   │  (on-device STT)    │   │  (accept / re-record) │   │  (Gemini structured    │   │  (categories/terms/price) │
 └──────────────┘   └────────────────────┘   └──────────────────────┘   │   output, text-only)   │   └─────────────┬─────────────┘
                                                                          └────────────────────────┘                 │
                                                                                                                       ▼
                                                                                                       ┌───────────────────────────────┐
                                                                                                       │ 6. Save → UserProfile          │
                                                                                                       │  (merge shoppingCategories /   │
                                                                                                       │   preferenceTerms / ignoreTerms│
                                                                                                       │   [+ priceCeiling])            │
                                                                                                       └───────────────┬─────────────────┘
                                                                                                                        │
                          Later: user taps an object or uploads/picks an image                                        │
                                                                                                                        ▼
                                              ┌─────────────────────────────────────────────────────────────────────────────┐
                                              │ /analyze or /identify (ai-analyzer)                                          │
                                              │  - ignoreTerms      → Gemini "STRICTLY EXCLUDE" block (server, existing)     │
                                              │  - transcript/notes → NEW: personalization context in detection prompt      │
                                              │  - shoppingCategories + preferenceTerms → rankProducts() (client, FIXED)     │
                                              │  - priceCeiling     → NEW: client-side post-filter                          │
                                              └─────────────────────────────────────────────────────────────────────────────┘
```

### Step 1–2: Record + live transcript

**Options considered for transcription:**

| Approach | Mechanism | Pros | Cons | Cost |
|---|---|---|---|---|
| **On-device STT — `speech_to_text` (recommended)** | Wraps Android `SpeechRecognizer` / iOS `SFSpeechRecognizer`; streams partial + final results | Free; instant live captions while speaking; audio stays on-device (privacy); fits existing Riverpod `AsyncNotifier` pattern with no new infra | Designed for short utterances — iOS hard-caps ~60s, Android recognizer stops after ~5s of silence; accuracy varies by device/OS locale support; needs `RECORD_AUDIO` (Android) + speech-recognition usage strings (iOS) | $0 |
| Google Cloud Speech-to-Text v2 (streaming) | App records audio (e.g. `record` package), streams to Cloud STT gRPC/REST | Higher/more consistent accuracy across accents/languages; longer utterances; tunable models | New GCP API + IAM to wire up; new recording dependency; raw audio leaves device; added latency | ~$0.016/min (model/region-dependent) |
| Gemini multimodal audio (`generate_content` with an audio `Part`, or Live API) | Send recorded clip directly to the existing Gemini client; could transcribe **and** extract preferences in one call via `response_schema` | One round trip for both transcription + extraction; reuses existing Gemini client/config; strong multilingual handling; can resolve ambiguity ("under fifty bucks" → `price_ceiling: 50`) directly | Audio leaves device; no live captions (user waits for the whole call); higher latency/token cost than dedicated STT; native-audio preview models have open transcription-return issues ([googleapis/python-genai#1279](https://github.com/googleapis/python-genai/issues/1279)) and the `-09-2025` preview is slated for deprecation March 2026 | Gemini audio-token pricing |

**Recommendation**: `speech_to_text` for MVP. It's free, gives the "live caption while you talk" feel users expect from voice UIs, and needs no backend changes for transcription itself. Treat Gemini-native-audio as a v2 option (§6, Phase 4) once the Live API/native-audio models are out of preview and only if multilingual coverage becomes a priority over latency/cost.

### Step 3: Review & edit the transcript

This is the literal "show the text once user edits or accepts" requirement. Pattern (consistent with voice-UX best practice — live waveform during recording, then an editable text surface for correction before any downstream action):

- On stop, populate an editable multi-line `TextField` (style consistent with `ProfileForm`'s `_textArea`) with the final transcript.
- Actions: **Try again** (discard, re-record), **Edit** (just focus the field — STT errors are common and need fixing before they become "permanent" preferences), **Use this** (proceed to extraction).
- Empty/low-confidence result → inline hint ("Didn't catch that — try again or type instead") with manual typing always available as a fallback (accessibility, noisy environments, unsupported locales).

### Step 4: Convert text → structured preferences (Gemini structured output)

New backend endpoint on `ai-analyzer` (same service that already has the Gemini client, GCP creds, logging conventions):

```
POST /preferences/extract
{
  "transcript": "birthday gift for my mom, minimalist home decor, earthy tones, no floral, under $50",
  "existing_profile": {                 // optional — enables incremental "also avoid leather" style follow-ups
    "shopping_categories": ["Home Decor"],
    "preference_terms": ["wood"],
    "ignore_terms": []
  }
}
```

Response — a Pydantic model passed as `response_schema` to `GenerateContentConfig(response_mime_type="application/json", response_schema=PreferenceExtraction)`, read back via `response.parsed`:

```python
class PreferenceExtraction(BaseModel):
    shopping_categories: list[CategoryEnum]   # subset of the existing 8 — guarantees valid checkbox values
    preference_terms: list[str]               # style/material/brand/color boost words, e.g. "minimalist", "earthy tones"
    ignore_terms: list[str]                   # exclusions, e.g. "floral", "leather"
    price_ceiling: float | None               # parsed from "under $50" etc.
    summary: str                              # human-readable confirmation, e.g. "Minimalist home decor in earthy
                                               # tones, no floral, budget under $50"
```

Notes:
- Use `CategoryEnum` = the exact 8 strings from `profile_form.dart`'s `_categoryOptions`, so extracted categories are always valid for the existing checkbox UI — no new vocabulary to keep in sync.
- Prefer `gemini-2.5-flash` over the image pipeline's `gemini-2.5-pro` for this call — it's a short text-classification/extraction task, cheaper and faster, and `_active_model` is a shared mutable global for the *image* pipeline so this should be its own constant, not reuse/override `_active_model`.
- Per Gemini structured-output best practice ([ai.google.dev/gemini-api/docs/structured-output](https://ai.google.dev/gemini-api/docs/structured-output)), give every field a docstring with an example, and avoid generic field names — both already satisfied by the schema above.
- Passing `existing_profile` lets the model merge intelligently (e.g. recognize "also avoid leather" as additive) rather than the client having to guess merge semantics — but the client still does the final union/de-dup before saving (see Step 6).

### Step 5: Review & edit the extracted preferences

Second "edit or accept" gate — this time over *structured* data, which is the actual "personalization settings" the user is confirming:

- Show `summary` at the top ("Here's what we heard: ...").
- Category chips — reuse `ProfileForm._categorySection()`'s `Wrap`/`GestureDetector` chip styling, pre-toggled from `shopping_categories`.
- "You're into" removable chips for `preference_terms`, "Avoid" removable chips for `ignore_terms`, both with a "+ add" affordance for manual additions — same comma-list semantics as `ProfileForm`'s existing text areas, just chip-rendered.
- Optional numeric field for `price_ceiling`, pre-filled.
- **Save preferences** → Step 6.

### Step 6: Persist into `UserProfile`

- **No new Firestore collection.** Merge into the existing `UserProfiles/{uid}` document via the existing `profileRepositoryProvider.save(uid, profile)` / `FirestoreSource.saveProfile()`.
- Merge strategy (client-side, before save):
  - `shopping_categories` → set union with existing `shoppingCategories`.
  - `preference_terms` / `ignore_terms` → case-insensitive de-duplicated union/append, never silent overwrite of manually-curated entries.
  - Flag (don't auto-resolve) any term that appears in *both* the new `ignore_terms` and the existing `preferenceTerms` (or vice versa) — surface as a conflict for the user to pick a side on the review screen.
- Optional new field: `priceCeiling: double?` (Firestore `price_ceiling`) if budget-based shortlisting (§3, Step pipeline) is in scope for MVP. If not, fold budget language into `preference_terms` as free text for now and revisit.

### Step 7: Shortlisting integration (tap object / upload image)

This is the "use that preference to shortlist the specific products" requirement. Mapped onto the *existing* `/analyze` and `/identify` pipelines (§2.2–2.3):

| Voice-derived field | Integration point | Change needed? |
|---|---|---|
| `ignore_terms` (merged into `UserProfile.ignoreTerms`) | Already sent as `AnalyzeRequest.ignore_terms` → folds into Gemini's exclusion prompt server-side, AND already passed to matcher fallback | **None** — works today once `ignoreTerms` contains voice-derived terms |
| `shopping_categories` (merged into `UserProfile.shoppingCategories`) | Already drives `rankProducts()`/`isPreferred()` in `main_screen.dart` (surfaces preferred-category products first) and the "preferred" badge in `product_card.dart` | **None** |
| `preference_terms` (merged into `UserProfile.preferenceTerms`) | Currently passed into `rankProducts()` as the category-name list inside `AnalyzeImageUseCase`/`TapIdentifyUseCase` — but `rankProducts`/`isPreferred` only matches the 8 fixed category names, so free-text terms (which is what voice will mostly produce — "minimalist", "Nike", "earthy tones") rarely match anything | **Fix needed** — extend `product_ranker.dart` with a generic keyword pass that boosts products whose `product.name` contains any `preferenceTerms` word, independent of the category-matching path. Without this, voice-derived style/brand preferences extracted in Step 4 will be saved correctly but have **no visible effect** on the shortlist. |
| `summary` / raw preference text | The already-plumbed-but-unused `transcript` field on `AnalyzeRequest` → `analyze_media(transcript=...)` | **Enhancement** — extend `_PROMPT` in `services/ai-analyzer/analyzer.py` to optionally include a short personalization line (e.g. *"The shopper's stated preferences: {transcript}. When multiple qualifying items are present, favor ones matching this."*) when `transcript` is non-empty. Backend-only change; mobile already sends this field (currently as `''`). |
| `price_ceiling` | No existing hook — Lens/Shopping APIs don't support hard price filtering | **New, v2** — recommend a client-side post-filter in `rankProducts`/UI (e.g. visually de-emphasize or move below-the-fold products priced above `price_ceiling`, with a "show all" toggle), since Lens results' price field is already known to be unreliable (see `[[analyzerAPIResearch]]`-style findings: `visual_matches` often lacks price). |

**Net effect**: for the two preference types voice input will most naturally produce — *category* ("Home Decor") and *exclusions* ("no floral") — shortlisting already works end-to-end with **zero pipeline changes**. The one fix that *is* needed (`preferenceTerms` → `rankProducts` keyword boost) is small, pre-existing, and benefits the manual `ProfileForm` flow too, not just voice input.

---

## 4. Proposed Component Map (for a future implementation pass — not built now)

**New (mobile)**
- `mobile/lib/presentation/providers/voice_preference_provider.dart` — `AsyncNotifier` state machine: `idle → recording → reviewingTranscript → extracting → reviewingPreferences → saving → done/error`.
- `mobile/lib/presentation/screens/voice_preferences_screen.dart` — record UI, transcript review, preference-chip review (could be one screen with steps, or a 2-step bottom sheet).
- `mobile/lib/data/models/preference_extraction.dart` — `PreferenceExtractRequest`/`PreferenceExtractResponse`, `@JsonSerializable` like `MatchRequest`/`MatchResponse`.
- `mobile/lib/data/sources/remote/preferences_api.dart` — Dio call to `POST /preferences/extract`, reusing `analyzerDioProvider`'s base URL.

**Modified (mobile)**
- `mobile/pubspec.yaml` — add `speech_to_text`, `permission_handler`.
- `mobile/android/app/src/main/AndroidManifest.xml` — add `android.permission.RECORD_AUDIO`.
- `mobile/ios/Runner/Info.plist` — add `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- `mobile/lib/core/utils/product_ranker.dart` — add `preferenceTerms` keyword-boost pass (the fix from §3, Step 7).
- `mobile/lib/data/models/user_profile.dart` — optional `priceCeiling` field + Firestore mapping (if in scope).
- `mobile/lib/presentation/screens/profile_screen.dart` — entry point ("Set preferences by voice").
- `mobile/lib/app.dart` — new route, e.g. `/voice-preferences`.

**New/Modified (backend `services/ai-analyzer`)**
- `services/ai-analyzer/analyzer.py` — new `extract_preferences(transcript, existing_profile)` using a Pydantic `response_schema`; optionally extend `_PROMPT`/`analyze_media` to consume `transcript` as personalization context.
- `services/ai-analyzer/main.py` — new `POST /preferences/extract` route + request/response models, following the existing correlation-id/logging pattern from `[[project_analyzer_reliability]]`.

---

## 5. Permissions & Privacy

- **Android**: add `<uses-permission android:name="android.permission.RECORD_AUDIO" />` alongside the existing `CAMERA` permission.
- **iOS**: add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to `Info.plist`, following the tone of the existing `NSCameraUsageDescription` ("ShopLens uses your camera to scan and identify products in real time.").
- With on-device STT, **raw audio never leaves the device** — only the user-approved text transcript is sent to `/preferences/extract`. This keeps the privacy surface of this feature smaller than the existing image-analysis pipeline (which already uploads images to GCS for Lens).
- `/preferences/extract` is text-only and doesn't need image/GCS access — smaller IAM surface than `/analyze`.
- Consider a "Clear voice-derived preferences" action in `ProfileScreen` for users who want to reset without manually editing the comma-list fields.

---

## 6. Cost & Latency

- On-device STT: **$0**, near-instant partial results.
- `/preferences/extract`: one short text-only Gemini call (`gemini-2.5-flash` recommended) — small prompt + small transcript, much cheaper/faster than the existing image-based `/analyze` call (no image tokens, no Lens/SerpAPI cost).
- Shortlisting itself adds **no new cost** — it reuses the existing `/analyze` / `/identify` / `/match` calls; only their *inputs* (`ignoreTerms`, `shoppingCategories`, `preferenceTerms`, optionally `transcript`) change.

---

## 7. Phased Rollout

1. **Phase 1 (MVP)** — `speech_to_text` → editable transcript → `/preferences/extract` (Gemini structured output) → chip-based review → merge into existing `UserProfile` fields (`shoppingCategories`, `preferenceTerms`, `ignoreTerms`). Entry point from `ProfileScreen`. **No changes to `/analyze`/`/identify`.**
2. **Phase 2** — Fix `product_ranker.dart` so `preferenceTerms` actually boosts matching products by name/category (currently inert, §2.3/§3). This benefits both voice-derived and manually-entered preference terms.
3. **Phase 3** — Wire the already-plumbed `transcript` field into `_PROMPT` in `services/ai-analyzer/analyzer.py` so Gemini's item-detection itself is biased by stated preferences (server-side personalization); add `priceCeiling` as a client-side shortlist post-filter.
4. **Phase 4 (optional/future)** — Re-evaluate Gemini native-audio/Live API once GA and transcription-return issues are resolved; consider collapsing record→transcribe→extract into a single multimodal call for locales where on-device STT is weak, while keeping on-device STT as the default/fallback.

---

## 8. Open Questions

- **Utterance length**: on-device STT realistically caps near ~60s on iOS. Is one short statement enough, or should the UX support "anything else?" follow-up turns that each go through their own extract-and-merge cycle?
- **Entry point**: `ProfileScreen` only, or also surfaced during onboarding / from `MainScreen` alongside the existing Gallery/Live Scan/Video buttons?
- **Conflict handling**: if voice extraction returns an `ignore_terms` entry that collides with an existing `preferenceTerms` entry (or vice versa), the review screen should surface this explicitly rather than silently picking a winner.
- **Locale coverage**: `speech_to_text` quality depends on the device's installed recognizer locales (`locales` property). The extraction prompt should be robust to transcripts in languages other than English — needs validation once a target market list is known.
- **Re-run semantics**: does running the voice flow again *add to* or *replace* existing preferences? Recommendation in §3/Step 6 is always-merge-with-review, but worth confirming against product expectations.

---

## Sources

- [speech_to_text | Flutter package (pub.dev)](https://pub.dev/packages/speech_to_text) — version, platform support, permission requirements, "short utterance" design target
- [csdcorp/speech_to_text (GitHub)](https://github.com/csdcorp/speech_to_text)
- [Picovoice: Simplifying Speech Recognition in Flutter](https://picovoice.ai/blog/simplifying-speech-recognition-in-flutter/)
- [Picovoice: Real-Time Transcription for Flutter](https://picovoice.ai/blog/streaming-speech-to-text-in-flutter/)
- [Gemini API: structured outputs (ai.google.dev)](https://ai.google.dev/gemini-api/docs/structured-output)
- [Gemini API: audio (ai.google.dev)](https://ai.google.dev/gemini-api/docs/audio)
- [Gemini 2.5 Flash Native Audio Preview docs](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash-native-audio-preview-12-2025)
- [googleapis/python-genai issue #1279 — audio transcription not returned](https://github.com/googleapis/python-genai/issues/1279)
- [Gemini 2.5 Native Audio upgrade announcement (blog.google)](https://blog.google/products-and-platforms/products/gemini/gemini-audio-model-updates/)
- [DeepWiki: python-genai structured outputs & response schemas](https://deepwiki.com/googleapis/python-genai/3.5-structured-outputs-and-response-schemas)
- [Structured Output with Gemini Models (Medium / Google Cloud Community)](https://medium.com/google-cloud/structured-output-with-gemini-models-begging-borrowing-and-json-ing-f70ffd60eae6)
- [Voice UI Design: Best Practices, Examples & Inspiration (2026) — Eleken](https://www.eleken.co/blog-posts/voice-ui-design)
- [Voice User Interface Design Best Practices — Lollypop Studio](https://lollypop.design/blog/2025/august/voice-user-interface-design-best-practices/)
