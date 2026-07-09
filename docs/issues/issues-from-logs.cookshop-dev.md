# Issues From Logs — ai-analyzer (cookshop-dev)

Platform: **cookshop-dev** (Rajan's weekly-release prod — see the `shoplens2026-dev`
counterpart at `docs/issues/issues-from-logs.shoplens2026-dev.md` for active dev).

Auto-maintained by the `check-ai-analyzer-logs` skill (`.claude/commands/check-ai-analyzer-logs.md`)
from Cloud Run logs for the `ai-analyzer` service:
https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=cookshop-dev-prj

Each entry's **First seen / Last seen / Occurrences** fields are maintained by the skill —
don't hand-edit those. Free-form notes you add under an entry are preserved across runs.

This is real weekly-release prod traffic, not scripted test traffic — the shoplens2026-dev
doc's "known-benign Postman noise" rule generally won't apply here unless cookshop-dev is
confirmed to also receive Postman-driven test runs.

Last checked: 2026-07-09T11:26:51Z — 1 new log line, 1 new issue

## Open

### Gemini 429 RESOURCE_EXHAUSTED surfaces to clients as 500 instead of 502 (analyze/stream path) — ERROR
- First seen: 2026-07-09T11:26:51Z
- Last seen: 2026-07-09T11:26:51Z
- Occurrences: 1
- Endpoint/source: `POST /analyze/stream` → `main.py:_produce` → `analyzer.py:analyze_media_stream` (`analyzer.py:1404`, `generate_content` call) → `analyzer.py:classify_exception` (`analyzer.py:876-886`)
- Sample: traceback through `main.py:404` → `analyzer.py:1404` → `google.genai.errors.ClientError: 429 RESOURCE_EXHAUSTED. {'message': 'Resource exhausted. Please try again later.'}` → emitted to the client as `{"type": "error", "error_code": "INTERNAL_ERROR"}` (revision `ai-analyzer-00126-h25`)
- Likely cause: identical signature/root cause to the `shoplens2026-dev` entry of the same name (see that doc) — `classify_exception` (`analyzer.py:876-886`) doesn't recognize `google.genai.errors.ClientError` and falls through to generic `500`/`INTERNAL_ERROR` instead of `502`. This is the first time this signature has shown up on `cookshop-dev` — it already exists on `shoplens2026-dev` (first seen there 2026-07-03, now also seen on the `/analyze/stream` call path) and hasn't been fixed yet, so it just reached prod on cookshop-dev's latest weekly release. `/analyze/stream` is the call path used by the mobile app's gallery-image-upload "Scan Image" flow (and live-scan's "Scan All"), so a user uploading an image while Gemini is rate-limited would see a generic non-retryable "Something went wrong" error instead of a "try again in a minute" prompt.
- Suggested fix: same as the `shoplens2026-dev` entry — fix `classify_exception` to recognize `google.genai` exception types and map to `502`/a specific error code, and fix the mobile client's `AnalyzerErrorCode` handling (`mobile/lib/data/models/analyzer_error.dart`) to recognize `UPSTREAM_ERROR` and whatever specific codes the backend ends up sending.

## Resolved

_None yet._
