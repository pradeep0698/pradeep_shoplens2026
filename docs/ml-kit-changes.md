# ML Kit Changes Log

Standup-style log of changes on `feature/ml-kit`, tracked by date.

## 2026-06-24

- **Route confident on-device detections to `/identify`, skip Gemini re-detection** (`ebaf528`)
  - `pipeline_provider.dart`: added `identifyTappedObject()`, calling the new `tapIdentifyUseCaseProvider` (cheap single-item lookup) instead of the full cloud `analyze` pipeline.
  - `live_scan_screen.dart`: added `_kOnDeviceConfidenceThreshold = 0.70`. Tapped objects with ML Kit confidence ≥ threshold route to `identifyTappedObject()` (skips Gemini); low-confidence taps and "Scan All" still go through `analyzeLoaded()` (full cloud detection).
  - Removed the old `_freezeAndIdentifyObject` flow (camera-stream capture + bbox scaling + `TapCropUtils` crop), replaced by the simpler confidence-based branch using the already-captured frame.

- **Fix applicationId mismatch with google-services.json** (`77b9d45`)
  - `mobile/android/app/build.gradle`: `applicationId` changed from `com.cookshop.mvp` → `com.shoplens.app` to match the Firebase config.

- **Log on-device confidence routing decision in live scan** (`64b58d6`)
  - Added `debugPrint` logging in `live_scan_screen.dart` showing which path was taken (`/identify` vs `/analyze`) and the confidence value that triggered the decision.

**Net diff:** 3 files changed (`build.gradle`, `pipeline_provider.dart`, `live_scan_screen.dart`), 50 insertions / 53 deletions vs `main`.
