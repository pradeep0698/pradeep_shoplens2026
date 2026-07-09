# Issues From Logs — ai-analyzer (shoplens2026-dev)

Platform: **shoplens2026-dev** (active dev — see the `cookshop-dev` counterpart at
`docs/issues/issues-from-logs.cookshop-dev.md` for Rajan's weekly-release prod).

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`)
from Cloud Run logs for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7

Each entry's **First seen / Last seen / Occurrences** fields are maintained by the skill —
don't hand-edit those. Free-form notes you add under an entry are preserved across runs.

Last checked: 2026-07-08T01:47:06Z — 1 new log line, 1 new issue (429 misrouting now also seen on /analyze/stream)

## Open

### Live-video `/analyze` always fails Gemini with 400 INVALID_ARGUMENT — ERROR
- First seen: 2026-07-03T14:52:34Z
- Last seen: 2026-07-06T01:24:55Z
- Occurrences: 12 (every live-video `/analyze` call seen since first detected has failed this way)
- Endpoint/source: `POST /analyze` (live-video path) → `analyzer.py:analyze_media` → `client.models.generate_content` at `analyzer.py:984`
- Sample: `req=17d763ef | gcs_uri=gs://shoplens-dev-hls-segments/live/segment001.ts` →
  `google.genai.errors.ClientError: 400 INVALID_ARGUMENT. {'message': 'Request contains an invalid argument.'}`
- Likely cause: the live-video branch of `analyze_media` (`analyzer.py:980-991`) builds the Gemini
  part with `types.Part.from_uri(file_uri=gcs_video_uri, mime_type="video/mp4")` — the mime type is
  hardcoded regardless of the actual object. Every failing call points at
  `gs://shoplens-dev-hls-segments/live/segment001.ts`, i.e. an MPEG-TS (`.ts`) HLS segment declared to
  Gemini as `video/mp4`. That mismatch is a very plausible reason Gemini rejects the request outright.
  Every occurrence so far is this exact same fixed object, immediately preceded by a small
  (`image_data_b64_len=860`) `/analyze` call — looks like a recurring test/health-check flow (possibly
  the Postman perf/flow collection) rather than live end-user traffic, but the code path itself is
  what all real live-scan requests would hit too, so this isn't test-only risk.
- Suggested fix: derive the mime type from the actual segment format instead of hardcoding
  `video/mp4` in `analyzer.py:982` (e.g. `video/mp2t` for `.ts`, or transcode/remux segments to mp4
  before handing them to Gemini) — confirm which one Gemini actually accepts for HLS segments, then
  fix the one call site.

### Gemini 429 RESOURCE_EXHAUSTED surfaces to clients as 500 instead of 502 — ERROR
- First seen: 2026-07-03T12:14:34Z
- Last seen: 2026-07-03T12:14:34Z
- Occurrences: 1
- Endpoint/source: `POST /analyze` → `analyzer.py:classify_exception` (`analyzer.py:802-812`)
- Sample: `google.genai.errors.ClientError: 429 RESOURCE_EXHAUSTED. {'message': 'Resource exhausted. Please try again later.'}` → client received `500 INTERNAL_ERROR`
- Likely cause: `classify_exception` only maps to `502 UPSTREAM_ERROR` when the exception's *message*
  contains a timeout/connection keyword, or when `type(exc).__name__` contains `"google"`, `"api"`,
  `"grpc"`, `"rpc"`, or `"transport"` (`analyzer.py:806-811`). `google.genai.errors.ClientError`'s
  `__name__` is just `"ClientError"` — none of those substrings match — so it falls through to the
  generic `500 INTERNAL_ERROR` branch even though this is a transient, retryable upstream condition,
  not an internal bug.
- Suggested fix: add a check for `google.genai.errors` exception types (or the module name, e.g.
  `type(exc).__module__`) in `classify_exception` so `ClientError`/`ServerError` from the Gemini SDK
  map to `502 UPSTREAM_ERROR` (or a dedicated `429`/`503` passthrough) instead of `500`.

### Gemini 429 RESOURCE_EXHAUSTED surfaces to clients as 500 instead of 502 (analyze/stream path) — ERROR
- First seen: 2026-07-08T01:47:06Z
- Last seen: 2026-07-08T01:47:06Z
- Occurrences: 1
- Endpoint/source: `POST /analyze/stream` → `main.py:_produce` → `analyzer.py:analyze_media_stream` (`analyzer.py:1404`, `generate_content` call) → `analyzer.py:classify_exception` (`analyzer.py:876-886`)
- Sample: `req` producer thread → traceback through `main.py:404` → `analyzer.py:1404` → `google.genai.errors.ClientError: 429 RESOURCE_EXHAUSTED. {'message': 'Resource exhausted. Please try again later.'}` → emitted to the client as `{"type": "error", "error_code": "INTERNAL_ERROR"}`
- Likely cause: same root cause as the non-stream entry above — `classify_exception` (`analyzer.py:876-886`) only maps to `502 UPSTREAM_ERROR` when the exception message contains a timeout/connection keyword or `type(exc).__name__` contains `google`/`api`/`grpc`/`rpc`/`transport`. `google.genai.errors.ClientError` matches none of those, so it falls to the generic `500`/`INTERNAL_ERROR` branch. This call site is `analyze_media_stream`'s Gemini detection call (`analyzer.py:1404`), which is used by **both** the mobile app's live-scan "Scan All" button and its gallery-image-upload "Scan Image" button (`mobile/lib/domain/usecases/analyze_image_usecase.dart` — both call `analyzeStream`/`/analyze/stream`). Note this bug is compounded client-side: `mobile/lib/data/models/analyzer_error.dart`'s `displayMessage`/`isRetryable` switches have no case for `AnalyzerErrorCode.internalError`, so it falls to the generic default (`'Something went wrong — please try again.'`, `isRetryable: false`) instead of a friendly "AI is busy, retry" message. Also note the client-side codes `GEMINI_QUOTA_EXCEEDED`/`GEMINI_UNAVAILABLE`/`GEMINI_TIMEOUT`/`GEMINI_AUTH_ERROR`/`GEMINI_INVALID_INPUT`/`GEMINI_ERROR` are never actually emitted by the backend (only `INVALID_REQUEST`/`UPSTREAM_ERROR`/`INTERNAL_ERROR` exist in `classify_exception`), and `UPSTREAM_ERROR` itself isn't in the client's `AnalyzerErrorCode.fromWire` switch either — so even fixing the backend to emit `502 UPSTREAM_ERROR` would still land on `AnalyzerErrorCode.unknown` client-side today, not a friendly/retryable state.
- Suggested fix: two-part. (1) Backend — in `classify_exception` (`analyzer.py:876-886`), check `type(exc).__module__` (or import `google.genai.errors` and `isinstance` check) so `ClientError`/`ServerError` map to `502` with a specific `error_code` (e.g. `GEMINI_QUOTA_EXCEEDED` for 429, `GEMINI_UNAVAILABLE` for 503) instead of the generic `500`/`INTERNAL_ERROR`. (2) Client — add `UPSTREAM_ERROR` to `AnalyzerErrorCode.fromWire` in `mobile/lib/data/models/analyzer_error.dart:20-33`, and make sure `displayMessage`/`isRetryable` (lines 80-101) have explicit cases for whatever codes the backend actually sends, rather than relying on the default branch.

## Resolved

_None yet._
