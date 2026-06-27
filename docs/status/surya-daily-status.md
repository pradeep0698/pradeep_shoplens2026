## TODO

- [x] **Cache `/identify` results** — same crop tapped twice re-runs Gemini + GCS + Lens. Add in-process TTLCache keyed on image hash + country, same pattern as product-matcher's existing `cachetools` cache. Eliminates all three cloud calls on repeat taps. ✓ Done 2026-06-25

---

## 2026-06-26
- Created `docs/ml-kit-flow.md` — end-to-end architecture doc covering the full tap-to-identify and scan-all paths with ASCII flow diagrams, all edge cases tabulated (ML Kit no-label, GCS failure, Gemini parse fail, SerpAPI quota, etc.), component role breakdown, and a log correlation quick reference

## 2026-06-25
- Added `mlkit_context` payload forwarded from live scan to backend API so Cloud Run logs show on-device confidence, labels, object count, and routing decision (identify vs analyze) for every request without needing a debuggable APK
- Built release APK (91.6 MB) with mlkit_context changes
- Removed 0.70 on-device confidence threshold — all taps now always route to `/identify` with the ML Kit crop; only "Scan All" uses `/analyze`. Fixed: ML Kit sometimes returned 0.00 confidence / empty labels, causing taps to fall through to the full Gemini pass unnecessarily
- Added 30-min TTLCache for `/identify` results (SHA-256 of image bytes + country, maxsize=200) — repeat taps on the same object return instantly without re-running Gemini, GCS, or Lens
- Propagated `mlkit_context` through all Flutter layers: `AnalyzeRequest` model, `AnalyzeImageUseCase`, `TapIdentifyUseCase`, `PipelineNotifier`
- Documented `mlkit_context` payload shape and `MLKIT |` backend log line in `automation-regression-notes.md`; added regression note for the confidence-threshold routing fix

## 2026-06-24
- Added ML Kit standup changes log to docs

## 2026-06-23
- Routed high-confidence ML Kit detections (≥0.70) directly to `/identify`, skipping Gemini re-detection
- Added `debugPrint` logging of on-device confidence routing decision in live scan screen
- Fixed applicationId mismatch between build config and google-services.json (`com.cookshop.mvp` → `com.shoplens.app`)
- Set up dual-platform config and cleaned up docs
