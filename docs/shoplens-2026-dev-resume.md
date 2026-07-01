# ShopLens 2026-Dev Setup — Resume Checkpoint

**Date:** 2026-06-29  
**Project ID:** `project-b1a5dd5a-69e6-4db3-9d7`  
**Project Number:** `115535290381`  
**Owner:** `suryarao.r@gmail.com`  
**Region:** `us-central1`

---

## Completed (Sections 1–7)

| Section | What was done |
|---|---|
| 1 — Auth | Already authenticated as `suryarao.r@gmail.com`, project set |
| 2 — APIs | All 20 APIs enabled |
| 3 — Firebase | Firestore DB created, security rules deployed, Hosting deployed → `https://project-b1a5dd5a-69e6-4db3-9d7.web.app` |
| 4 — Storage | `gs://shoplens2026-dev-hls-segments` (public read, uniform access) and `gs://shoplens2026-dev-lens-tmp` (public read, 1-day lifecycle) created |
| 5 — Artifact Registry | `shoplens` Docker repo created at `us-central1-docker.pkg.dev/project-b1a5dd5a-69e6-4db3-9d7/shoplens` |
| 6 — IAM | `shoplens-runner` SA created with all 11 roles + Cloud Build SA permissions |
| 7 — WIF | `github-pool` + `github-provider` created, SA bound to `suryaraor/shoplens2026` (repointed 2026-06-30 after moving CI target repo) |

---

## Pending Manual Steps (Firebase Console)

Go to: https://console.firebase.google.com/project/project-b1a5dd5a-69e6-4db3-9d7

- [x] **Authentication** → Email/Password provider already enabled (verified via Identity Toolkit API — `signIn.email.enabled: true`)
- [ ] **Storage** → Get started → choose **us-central1** — confirmed NOT done (default bucket `project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app` returns 404). This is the one step that genuinely requires the console click; the `.firebasestorage.app` domain is Firebase-managed and can't be created via `gcloud storage buckets create` or a plain REST call (tried both, both rejected).
- [x] **Project Settings → Your apps** → Web app created via `firebase apps:create WEB shoplens2026-dev` (no console needed). Config fetched via `firebase apps:sdkconfig WEB 1:115535290381:web:2874f83aa9285e2698b544` — apiKey `AIzaSyBj8i4zQQubbwMCXiAbN8rphiRb9qTmt9s`.
- [x] **Project Settings → Your apps** → Android app already existed (App ID `1:115535290381:android:739a876965f4c43898b544`); config was pre-downloaded to `config/firebase/shoplens2026-dev/android/google-services.json` and copied to `mobile/android/app/google-services.shoplens2026-dev.json`
- [x] **Project Settings → Your apps** → Apple app already existed (App ID `1:115535290381:ios:8b1cd372db43caec98b544`); config was pre-downloaded to `config/firebase/shoplens2026-dev/apple/GoogleService-Info.plist` and copied to `mobile/ios/Runner/GoogleService-Info.shoplens2026-dev.plist`

---

## Pending Script Sections

### Section 8 — GitHub Actions Secrets
Add these in GitHub repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `GCP_PROJECT_ID_2026_DEV` | `project-b1a5dd5a-69e6-4db3-9d7` |
| `GCP_PROJECT_NUMBER_2026_DEV` | `115535290381` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER_2026_DEV` | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SERVICE_ACCOUNT_2026_DEV` | `shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com` |
| `SERPAPI_KEY` | `<your SerpAPI key>` |

### Section 9 — Pub/Sub
Pub/Sub topic created. Push subscription must be created **after** Section 10 (pubsub-worker deployed):
```bash
SECTIONS="9" bash scripts/shoplens2026-dev-setup.sh
```

### Section 10 — Cloud Run Services
Requires `SERPAPI_KEY` env var:
```bash
SERPAPI_KEY="<your-key>" SECTIONS="10" bash scripts/shoplens2026-dev-setup.sh
```

Services to be deployed:
- [ ] ai-analyzer
- [ ] product-matcher
- [ ] state-manager
- [ ] voice-assistant
- [ ] pubsub-worker

### Section 11 — Cloud Live Stream
```bash
SECTIONS="11" bash scripts/shoplens2026-dev-setup.sh
```

### Section 12 — Generate .env files
```bash
SECTIONS="12" bash scripts/shoplens2026-dev-setup.sh
```

### Section 13 — Mobile APK Build
Requires `google-services.shoplens2026-dev.json` from Firebase Console (step above):
```bash
SECTIONS="13" bash scripts/shoplens2026-dev-setup.sh
```

### Section 14 — Verification
```bash
SECTIONS="14" bash scripts/shoplens2026-dev-setup.sh
```

---

## Expected Cloud Run URLs (after Section 10)

| Service | URL |
|---|---|
| ai-analyzer | `https://ai-analyzer-115535290381.us-central1.run.app` |
| product-matcher | `https://product-matcher-115535290381.us-central1.run.app` |
| state-manager | `https://state-manager-115535290381.us-central1.run.app` |
| voice-assistant | `https://voice-assistant-115535290381.us-central1.run.app` |
| pubsub-worker | `https://pubsub-worker-115535290381.us-central1.run.app` |

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
| WIF Provider | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| iOS Bundle ID | `com.shoplens.app` |
| Android Package | `com.shoplens.app` |
| Full setup doc | `docs/shoplens2026-dev-setup.md` |
| Setup script | `scripts/shoplens2026-dev-setup.sh` |
