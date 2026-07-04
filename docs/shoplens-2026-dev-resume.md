# ShopLens 2026-Dev Setup — Resume Checkpoint

**Last updated:** 2026-07-02
**Project ID:** `project-b1a5dd5a-69e6-4db3-9d7`
**Project Number:** `115535290381`
**Owner:** `suryarao.r@gmail.com`
**Region:** `us-central1`
**CI/CD repo:** `github.com/shoplens2026ai/shoplens2026` (transferred 2026-07-02 from `suryaraor/shoplens2026`, which itself moved 2026-06-30 from the unreachable `shoplensai-coder/shoplens`)

---

## Completed (Sections 1–8, 10, 12–14)

| Section | What was done |
|---|---|
| 1 — Auth | Authenticated as `suryarao.r@gmail.com`, project set |
| 2 — APIs | All required APIs enabled |
| 3 — Firebase | Firestore DB created, security rules deployed, Hosting deployed → `https://project-b1a5dd5a-69e6-4db3-9d7.web.app`. Auth Email/Password already enabled. Web app created via `firebase apps:create WEB`. Android app recreated with the correct package name (see Known Issues below). iOS app confirmed correct (`com.shoplens.app`). |
| 4 — Storage | `gs://shoplens2026-dev-hls-segments` and `gs://shoplens2026-dev-lens-tmp` created. Firebase Storage default bucket (`project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app`, us-central1) provisioned via console 2026-07-01. |
| 5 — Artifact Registry | `shoplens` Docker repo created |
| 6 — IAM | `shoplens-runner` SA created with all roles + Cloud Build SA permissions. Additionally granted `roles/storage.objectViewer`, `roles/artifactregistry.writer`, `roles/logging.logWriter` to the **Compute Engine default SA** (`115535290381-compute@developer.gserviceaccount.com`) — required for `gcloud run deploy --source` builds; not documented in the original setup guide. |
| 7 — WIF | `github-pool` + `github-provider` created; repointed 2026-06-30 to `suryaraor/shoplens2026`, then again 2026-07-02 to `shoplens2026ai/shoplens2026` |
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

None remaining. Firebase Storage was provisioned via console on 2026-07-01. All 4 GitHub Actions secrets were pushed manually by the user, first to `suryaraor/shoplens2026` (2026-06-30), then re-added to `shoplens2026ai/shoplens2026` after the org transfer (2026-07-02) — both times manually, since the auto-mode classifier's exfiltration guard blocks in-session automation from writing secrets to an external repo regardless of consent.

---

## GitHub Org Migration — complete (2026-07-02)

**Goal:** move the repo from personal account `suryaraor/shoplens2026` to org-owned `shoplens2026ai/shoplens2026`, per `docs/github-org.md` Option A (fresh org, not the old `shoplens2026ai-source` personal-account idea, which was a dead end — that name is a personal user account, not an org).

**What happened, for future reference:**
- Org `shoplens2026ai` was created and is owned by the `shoplens2026ai-source` account — not `suryaraor`, the account that owned the repo being transferred in.
- First transfer attempts failed because `suryaraor` had zero membership in `shoplens2026ai` (API transfer → 403; web UI transfer → "already exists" / "no permission to create private repositories" — both symptoms of the same missing-membership root cause).
- Fix: `shoplens2026ai-source` invited `suryaraor` as **Owner** of the org; `suryaraor` accepted; the web UI transfer then succeeded.
- **Known quirk (unresolved, informational only):** even after the transfer, this session's `gh`/API tokens (both the fine-grained PAT and the classic OAuth token, with the "GitHub CLI" OAuth app explicitly granted org access) could not see the repo via `gh api` or `gh secret` — persistent 404s, empty `orgs/.../repos` listings, empty search results. Plain `git` operations (`git ls-remote`, fetch) worked fine and matched expected history, so this is isolated to GitHub's REST API layer for this token/org combo, not an actual access problem. Root cause never fully identified; work around it by using plain `git` commands and the browser UI instead of `gh api`/`gh secret` for this repo.

**Post-transfer updates completed:**
- WIF provider attribute condition repointed to `assertion.repository=='shoplens2026ai/shoplens2026'`
- `shoplens-runner` SA rebound to the new principal; old `suryaraor/shoplens2026` binding removed
- 4 Actions secrets re-added under `shoplens2026ai/shoplens2026` (manual, browser)
- `.github/workflows/deploy-shoplens2026-dev.yml` comment updated to new repo path
- Local git remote renamed `suryaraor-shoplens2026` → `shoplens2026ai`, URL updated to `https://github.com/shoplens2026ai/shoplens2026.git`; branch tracking followed automatically

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
| WIF Provider | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` (trusts `shoplens2026ai/shoplens2026`) |
| iOS Bundle ID | `com.shoplens.app` |
| Android Package | `com.shoplens.app` |
| Firebase Web App ID | `1:115535290381:web:2874f83aa9285e2698b544` |
| Firebase Android App ID | `1:115535290381:android:a69e0d2e5c92081298b544` |
| Firebase iOS App ID | `1:115535290381:ios:8b1cd372db43caec98b544` |
| Full setup doc | `docs/shoplens2026-dev-setup.md` |
| Setup script | `scripts/shoplens2026-dev-setup.sh` |
| Deploy workflow | `.github/workflows/deploy-shoplens2026-dev.yml` |
