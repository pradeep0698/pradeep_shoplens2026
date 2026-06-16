# Branching Strategy

## Branch Structure

| Branch | Deploys to | Purpose |
|---|---|---|
| `main` | **dev** | Integration branch — single dev platform |
| `develop` | **dev** | Feature integration branch |
| `feature/<id>-name` | — | New work, branched from `develop` |
| `hotfix/<name>` | — | Urgent fixes, branched from `main` |

## Flow

```
feature/xyz  ──► develop ──► main
                                │
                           auto-deploys to dev
```

1. **Feature**: branch from `develop` → PR to `develop` → CI runs → merge → auto-deploys to dev
2. **Hotfix**: branch from `main` → PR to `main` → deploys to dev → also merge back to `develop`

## CI/CD Workflows

| Workflow | Trigger | Action |
|---|---|---|
| [ci.yml](.github/workflows/ci.yml) | Push to `feature/**`, `hotfix/**`; PRs to `develop`/`main` | Lint, build smoke-check, Docker validation for all 4 services |
| [deploy-cloudrun.yml](.github/workflows/deploy-cloudrun.yml) | Push to `develop`, `main` | Builds and deploys all Cloud Run services to dev |
| [deploy-firebase.yml](.github/workflows/deploy-firebase.yml) | Push to `develop`, `main` | Builds Next.js and deploys Firebase Hosting + Firestore rules |

Branch → GitHub Environment mapping:

```
develop  →  dev  (shoplens-dev-prj)
main     →  dev  (shoplens-dev-prj)
```

Both deploy workflows also support `workflow_dispatch` with a manual environment selector for on-demand deploys.

## GitHub Environment Configuration

One environment in **Settings → Environments**: `dev`.

### Secrets (encrypted)

| Secret | dev |
|---|---|
| `WIF_PROVIDER` | `projects/YOUR_PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| `SA_EMAIL` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| `NEXT_PUBLIC_FIREBASE_API_KEY` | Firebase web API key |
| `SERPAPI_KEY` | SerpApi key (Google Lens visual matching) |

### Variables (plaintext)

| Variable | dev |
|---|---|
| `PROJECT_ID` | `shoplens-dev-prj` |
| `FIREBASE_PROJECT_ID` | `shoplens-dev-prj` |
| `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | `shoplens-dev-prj` |
| `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | `shoplens-dev-prj.firebaseapp.com` |
| `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | `shoplens-dev-prj.firebasestorage.app` |
| `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | *(from Firebase Console)* |
| `NEXT_PUBLIC_FIREBASE_APP_ID` | *(from Firebase Console)* |
| `SESSION_ID` | `live-session-001` |
| `BUCKET_NAME` | `shoplens-dev-hls-segments` |
| `HLS_STREAM_URL` | HLS stream URL (fill after Live Stream setup) |
| `AI_ANALYZER_URL` | populate after first deploy |
| `PRODUCT_MATCHER_URL` | populate after first deploy |
| `STATE_MANAGER_URL` | populate after first deploy |
| `GCS_LENS_BUCKET` | `shoplens-dev-lens-tmp` |

### `GCS_LENS_BUCKET` setup (one-time, per project)

`ai-analyzer` uploads a temp JPEG to this bucket and passes a public
`storage.googleapis.com/<bucket>/<object>` URL to SerpApi's Google Lens
endpoint, then deletes the object. This requires:

```bash
# 1. Create the bucket
gcloud storage buckets create gs://<bucket-name> \
  --project=shoplens-dev-prj --location=us-central1 --uniform-bucket-level-access

# 2. Allow public read on objects (SerpApi must be able to fetch the image)
gcloud storage buckets add-iam-policy-binding gs://<bucket-name> \
  --member=allUsers --role=roles/storage.objectViewer

# 3. Let the Cloud Run runtime SA write/delete temp objects
gcloud storage buckets add-iam-policy-binding gs://<bucket-name> \
  --member="serviceAccount:shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com" \
  --role=roles/storage.objectAdmin

# 4. (Optional) auto-expire anything _delete_gcs missed
echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":1,"matchesPrefix":["lens-tmp/"]}}]}' > lifecycle.json
gcloud storage buckets update gs://<bucket-name> --lifecycle-file=lifecycle.json
```

Then add `GCS_LENS_BUCKET=shoplens-dev-lens-tmp` as a GitHub Environment Variable
(Settings → Environments → dev → Variables). If missing, `vars.GCS_LENS_BUCKET`
silently resolves to an empty string (no workflow error) and `ai-analyzer` logs
`GCS_LENS_BUCKET or SERPAPI_KEY not set — visual matching disabled`.

## Branch Protection Rules

Configure in **Settings → Branches** for `main`:

- Require a pull request before merging
- Require CI (`CI – Build & Lint`) to pass before merging
- Require at least 1 approving review
- Do not allow bypassing the above settings
