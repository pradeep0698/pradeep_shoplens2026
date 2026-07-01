# ShopLens 2026-Dev Setup — Resume Checkpoint

**Last updated:** 2026-06-30
**Project ID:** `project-b1a5dd5a-69e6-4db3-9d7`
**Project Number:** `115535290381`
**Owner:** `suryarao.r@gmail.com`
**Region:** `us-central1`
**CI/CD repo:** `github.com/suryaraor/shoplens2026` (moved 2026-06-30 — original `shoplensai-coder/shoplens` wasn't reachable with the working GitHub credentials)

---

## Completed (Sections 1–8, 10, 12–14)

| Section | What was done |
|---|---|
| 1 — Auth | Authenticated as `suryarao.r@gmail.com`, project set |
| 2 — APIs | All required APIs enabled |
| 3 — Firebase | Firestore DB created, security rules deployed, Hosting deployed → `https://project-b1a5dd5a-69e6-4db3-9d7.web.app`. Auth Email/Password already enabled. Web app created via `firebase apps:create WEB`. Android app recreated with the correct package name (see Known Issues below). iOS app confirmed correct (`com.shoplens.app`). |
| 4 — Storage | `gs://shoplens2026-dev-hls-segments` and `gs://shoplens2026-dev-lens-tmp` created. **Firebase Storage default bucket is still NOT provisioned** — see Pending Manual Steps. |
| 5 — Artifact Registry | `shoplens` Docker repo created |
| 6 — IAM | `shoplens-runner` SA created with all roles + Cloud Build SA permissions. Additionally granted `roles/storage.objectViewer`, `roles/artifactregistry.writer`, `roles/logging.logWriter` to the **Compute Engine default SA** (`115535290381-compute@developer.gserviceaccount.com`) — required for `gcloud run deploy --source` builds; not documented in the original setup guide. |
| 7 — WIF | `github-pool` + `github-provider` created and repointed to `suryaraor/shoplens2026` |
| 8 — GitHub Secrets | Workflow created; **secrets not yet pushed** — see Pending below |
| 9 — Pub/Sub | **Intentionally skipped.** Confirmed via `docs/sunday-prod-install.md:95` and the C2 container diagram that the live-video/Pub/Sub pipeline is unused in the real product (cookshop-dev prod skips it too). No topic/subscription exists. |
| 10 — Cloud Run | All 5 services deployed and smoke-tested: ai-analyzer, product-matcher, state-manager (all public, 200 OK), voice-assistant and pubsub-worker (both `--no-allow-unauthenticated`, 403 as expected). `pubsub-worker` is deployed but unused/idle by choice — costs nothing at zero traffic. |
| 11 — Cloud Live Stream | **Intentionally skipped** — same reasoning as Section 9. |
| 12 — Env files | Generated for all services + frontend. `frontend/.env.shoplens2026-dev` has real Firebase Web values filled in (script only writes placeholders for these two fields). |
| 13 — Mobile APK | Built successfully after fixing the Android package name bug: `mobile/build/app/outputs/flutter-apk/app-release.apk` (91.8MB) |
| 14 — Verification | 16/17 checks pass (only Pub/Sub topic fails, expected since Section 9 was skipped) |

---

## Known issue found & fixed: wrong Android package name

The Android Firebase app was originally registered with package name `com.company.appname` (a leftover placeholder) instead of `com.shoplens.app`, which broke the APK build (`No matching client found for package name 'com.shoplens.app'`). Fixed by:
1. Creating a new Android app: `firebase apps:create ANDROID shoplens2026-dev --package-name com.shoplens.app`
2. Deleting the stale app (`1:115535290381:android:739a876965f4c43898b544`) via the Firebase Management API (no `firebase apps:delete` CLI command exists)
3. Re-downloading `mobile/android/app/google-services.shoplens2026-dev.json`

New Android App ID: `1:115535290381:android:a69e0d2e5c92081298b544`

---

## Pending Manual Steps

- [ ] **Firebase Console → Storage → Get started → choose us-central1.** This is the one remaining step that genuinely can't be done via CLI/API — the `.firebasestorage.app` domain is Firebase-managed; both `gcloud storage buckets create` and a direct Firebase Storage REST call were rejected. The frontend (`frontend/src/lib/storage.ts`) actively uses `getStorage()`, so this blocks any upload-to-Firebase-Storage feature until done.
- [ ] **Push the 4 GitHub Actions secrets** to `suryaraor/shoplens2026` (Settings → Secrets and variables → Actions), each set to the full contents of the matching file:
  - `SHOPLENS2026DEV_AI_ANALYZER_ENV` ← `services/ai-analyzer/.env.shoplens2026-dev`
  - `SHOPLENS2026DEV_PRODUCT_MATCHER_ENV` ← `services/product-matcher/.env.shoplens2026-dev`
  - `SHOPLENS2026DEV_STATE_MANAGER_ENV` ← `services/state-manager/.env.shoplens2026-dev`
  - `SHOPLENS2026DEV_VOICE_ASSISTANT_ENV` ← `services/voice-assistant/.env.shoplens2026-dev`

  (Could not be pushed via `gh secret set` in-session — the auto-mode classifier hard-blocks pushing these values to the external repo even with explicit user consent.)

---

## Cloud Run URLs (live)

| Service | URL |
|---|---|
| ai-analyzer | `https://ai-analyzer-115535290381.us-central1.run.app` |
| product-matcher | `https://product-matcher-115535290381.us-central1.run.app` |
| state-manager | `https://state-manager-115535290381.us-central1.run.app` |
| voice-assistant | `https://voice-assistant-115535290381.us-central1.run.app` (auth required) |
| pubsub-worker | `https://pubsub-worker-115535290381.us-central1.run.app` (auth required, unused) |

---

## Key Resource Reference

| Resource | Value |
|---|---|
| Firebase Hosting | `https://project-b1a5dd5a-69e6-4db3-9d7.web.app` |
| Firebase Console | `https://console.firebase.google.com/project/project-b1a5dd5a-69e6-4db3-9d7` |
| Service Account | `shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com` |
| Artifact Registry | `us-central1-docker.pkg.dev/project-b1a5dd5a-69e6-4db3-9d7/shoplens` |
| HLS Bucket | `gs://shoplens2026-dev-hls-segments` |
| Lens Tmp Bucket | `gs://shoplens2026-dev-lens-tmp` |
| WIF Provider | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` (trusts `suryaraor/shoplens2026`) |
| iOS Bundle ID | `com.shoplens.app` |
| Android Package | `com.shoplens.app` |
| Firebase Web App ID | `1:115535290381:web:2874f83aa9285e2698b544` |
| Firebase Android App ID | `1:115535290381:android:a69e0d2e5c92081298b544` |
| Firebase iOS App ID | `1:115535290381:ios:8b1cd372db43caec98b544` |
| Full setup doc | `docs/shoplens2026-dev-setup.md` |
| Setup script | `scripts/shoplens2026-dev-setup.sh` |
| Deploy workflow | `.github/workflows/deploy-shoplens2026-dev.yml` |
