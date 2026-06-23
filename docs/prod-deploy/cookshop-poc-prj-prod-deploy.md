# Deploying the new repo's code to the existing prod project (`cookshop-poc-prj`)

Context: this code was manually copied into a new GitHub repo on a separate GitHub/GCP
account (used for **dev**). Production stays on the original GCP account, project
**`cookshop-poc-prj`**. This doc is everything needed to run prod deploys to that
project from the new repo, using your personal Google account logged in via `gcloud`/`firebase`
CLI (no CI/CD, no service-account key file).

---

## 0. Security issues found while compiling this — fix before going further

1. **Leaked SerpAPI key.** [services/product-matcher/.env.example](services/product-matcher/.env.example)
   contains a real-looking SerpAPI key (`77f052a8...`), not a placeholder — and it's tracked in
   git history (confirmed via `git ls-files`). Every other `.env.example` in the repo uses a
   placeholder like `your_serpapi_key_here`; this one doesn't. **Rotate this key in the SerpAPI
   dashboard** and replace it with a placeholder. Scrubbing it from git history is a separate,
   more invasive step — ask if you want that done too.
2. **Stale local service-account key.** [infra/cookshop-poc-a59b1ce4ecba.json](infra/cookshop-poc-a59b1ce4ecba.json)
   is a real GCP service-account key (`cookshop-runner@cookshop-poc.iam.gserviceaccount.com`) sitting
   on disk. It's `.gitignore`'d (never committed — confirmed via `git check-ignore`), and it's for
   the **old, superseded** `cookshop-poc` project (see §1), not current prod. Low risk since it's
   untracked, but consider deleting it locally and revoking it in the old project if unused.

---

## 1. Naming gotcha: two different "cookshop-poc" projects exist

Don't confuse these — they are separate GCP projects with separate project numbers:

| | Project ID | Project # | Status |
|---|---|---|---|
| **Current prod (target)** | `cookshop-poc-prj` | `645158438988` | **Live** — this is what `.firebaserc`, `deploy-cloudrun.yml`, and `deploy-firebase.yml` in this repo all point at. |
| Old/superseded | `cookshop-poc` | `1017419148960` | Referenced only in `docs/archive/GCP_SETUP.md` and `infra/infra_status.txt` (both stale, last verified 2026-05-04). Do not deploy here. |

Everything below targets `cookshop-poc-prj`.

---

## 2. Confirmed resource inventory (`cookshop-poc-prj`)

Pulled live via `gcloud` against `cookshop-poc-prj` during this session:

- **Region:** `us-central1`
- **Deploy service account:** `cookshop-runner@cookshop-poc-prj.iam.gserviceaccount.com`
- **Artifact Registry:** Docker repo `cookshop` in `us-central1` (`us-central1-docker.pkg.dev/cookshop-poc-prj/cookshop`)
- **Cloud Run services (all 4 running, last deployed 2026-06-15 by the SA above):**

  | Service | URL |
  |---|---|
  | `state-manager` | `https://state-manager-645158438988.us-central1.run.app` |
  | `product-matcher` | `https://product-matcher-645158438988.us-central1.run.app` |
  | `ai-analyzer` | `https://ai-analyzer-645158438988.us-central1.run.app` |
  | `pubsub-worker` | `https://pubsub-worker-645158438988.us-central1.run.app` |

- **Firebase Hosting:** live at `cookshop-poc-prj.web.app`, `.firebaserc`'s `prod` alias
- **Pub/Sub:** topic `video-segments-topic`, push subscription `video-segments-sub`

**Not directly queryable right now** (the cached `cookshop-runner` SA token expired mid-session,
and none of the 3 Google accounts logged in on this machine — `shoplens.ai@gmail.com`,
`aistreamscan@gmail.com`, plus that SA — currently have IAM access to `cookshop-poc-prj`). Once
you've logged in with an account that has access (§3), pull these before your first deploy —
they're GitHub Environment variables in the *old* repo that you won't have access to from the new
repo/account:

```bash
# Ground-truth source: the currently-deployed revisions. This avoids guessing at
# values like BUCKET_NAME, SESSION_ID, GCS_LENS_BUCKET, FIRESTORE_PROJECT_ID.
for svc in state-manager product-matcher ai-analyzer pubsub-worker; do
  echo "=== $svc ==="
  gcloud run services describe "$svc" \
    --project=cookshop-poc-prj --region=us-central1 \
    --format="yaml(spec.template.spec.containers[0].env)"
done

# GCS buckets actually in the project (HLS segments bucket, lens/reverse-image bucket)
gcloud storage buckets list --project=cookshop-poc-prj --format="value(name)"
```

---

## 3. One-time setup: grant your personal Google account access

You said you'll deploy by logging in with your own Google account (no service-account key, no
CI/WIF reconfiguration). Whoever currently administers `cookshop-poc-prj` (Owner/IAM Admin) needs
to grant your account these roles once:

```bash
PROJECT=cookshop-poc-prj
YOUR_EMAIL=you@example.com   # the account you'll run `gcloud auth login` with

for role in roles/run.admin roles/artifactregistry.writer roles/iam.serviceAccountUser \
            roles/firebasehosting.admin roles/pubsub.editor roles/storage.admin \
            roles/datastore.user roles/secretmanager.admin; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="user:$YOUR_EMAIL" --role="$role"
done
```

- `roles/iam.serviceAccountUser` is required to deploy Cloud Run revisions *as*
  `cookshop-runner@cookshop-poc-prj.iam.gserviceaccount.com` (the `--service-account` flag in every
  `gcloud run deploy` below needs this).
- If you'd rather have all of Editor instead of the itemized list, that also works but is broader
  than needed.

Then on your machine:

```bash
gcloud auth login                       # browser login as YOUR_EMAIL
gcloud config set project cookshop-poc-prj
firebase login                          # separate browser login for Firebase CLI
firebase use --add cookshop-poc-prj     # add as an alias inside mobile/ if not already there
```

Verify access:

```bash
gcloud projects describe cookshop-poc-prj   # should return project metadata, not a permission error
```

---

## 4. Deploying the 4 Cloud Run services

This mirrors [.github/workflows/deploy-cloudrun.yml](.github/workflows/deploy-cloudrun.yml) exactly,
just run locally instead of from GitHub Actions. Run from the repo root.

```bash
PROJECT_ID=cookshop-poc-prj
REGION=us-central1
REGISTRY=us-central1-docker.pkg.dev
REPO=cookshop
SA_EMAIL=cookshop-runner@cookshop-poc-prj.iam.gserviceaccount.com
TAG=$(git rev-parse --short HEAD)   # or any tag you like

gcloud auth configure-docker $REGISTRY

# ---- Build & push all 4 images ----
for svc in state-manager product-matcher ai-analyzer pubsub-worker; do
  docker build -t "$REGISTRY/$PROJECT_ID/$REPO/$svc:$TAG" "./services/$svc"
  docker push "$REGISTRY/$PROJECT_ID/$REPO/$svc:$TAG"
done
```

### 4a. state-manager

```bash
gcloud run deploy state-manager \
  --image "$REGISTRY/$PROJECT_ID/$REPO/state-manager:$TAG" \
  --platform managed --region "$REGION" --project "$PROJECT_ID" \
  --service-account "$SA_EMAIL" \
  --allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 \
  --min-instances 0 --max-instances 10 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,FIRESTORE_PROJECT_ID=$PROJECT_ID"
  # ^ confirm FIRESTORE_PROJECT_ID with the §2 describe command — assumed same as PROJECT_ID
```

### 4b. product-matcher

```bash
SERPAPI_KEY=<rotated key from §0>

gcloud run deploy product-matcher \
  --image "$REGISTRY/$PROJECT_ID/$REPO/product-matcher:$TAG" \
  --platform managed --region "$REGION" --project "$PROJECT_ID" \
  --service-account "$SA_EMAIL" \
  --allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 \
  --min-instances 0 --max-instances 10 \
  --set-env-vars "SERPAPI_KEY=$SERPAPI_KEY"
```

### 4c. ai-analyzer

```bash
GCS_LENS_BUCKET=<from §2 describe command>

gcloud run deploy ai-analyzer \
  --image "$REGISTRY/$PROJECT_ID/$REPO/ai-analyzer:$TAG" \
  --platform managed --region "$REGION" --project "$PROJECT_ID" \
  --service-account "$SA_EMAIL" \
  --allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 \
  --min-instances 0 --max-instances 10 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,LOCATION=$REGION,GCS_LENS_BUCKET=$GCS_LENS_BUCKET,SERPAPI_KEY=$SERPAPI_KEY"
```

> The old archived setup guide ([docs/archive/GCP_SETUP.md](docs/archive/GCP_SETUP.md)) deployed
> `ai-analyzer` with `2Gi`/`2 CPU`/`120s timeout` on the old project — the current workflow uses
> `512Mi`/`1 CPU`/default timeout. Bump back up with `--memory 2Gi --cpu 2 --timeout 120` if you see
> timeouts or OOM kills on real video segments.

### 4d. Collect URLs, then deploy pubsub-worker (depends on the other 3 URLs)

```bash
STATE_URL=$(gcloud run services describe state-manager --region "$REGION" --project "$PROJECT_ID" --format 'value(status.url)')
MATCHER_URL=$(gcloud run services describe product-matcher --region "$REGION" --project "$PROJECT_ID" --format 'value(status.url)')
AI_URL=$(gcloud run services describe ai-analyzer --region "$REGION" --project "$PROJECT_ID" --format 'value(status.url)')

BUCKET_NAME=<from §2 — GCS bucket list>
SESSION_ID=<from §2 describe command, e.g. live-session-001>

gcloud run deploy pubsub-worker \
  --image "$REGISTRY/$PROJECT_ID/$REPO/pubsub-worker:$TAG" \
  --platform managed --region "$REGION" --project "$PROJECT_ID" \
  --service-account "$SA_EMAIL" \
  --allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 \
  --min-instances 0 --max-instances 10 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=$BUCKET_NAME,SESSION_ID=$SESSION_ID,AI_ANALYZER_URL=$AI_URL,PRODUCT_MATCHER_URL=$MATCHER_URL,STATE_MANAGER_URL=$STATE_URL"
```

### 4e. Re-point the Pub/Sub push subscription at the new pubsub-worker revision

```bash
WORKER_URL=$(gcloud run services describe pubsub-worker --region "$REGION" --project "$PROJECT_ID" --format 'value(status.url)')
ACCESS_TOKEN=$(gcloud auth print-access-token)

curl -sf -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "https://pubsub.googleapis.com/v1/projects/$PROJECT_ID/subscriptions/video-segments-sub:modifyPushConfig" \
  -d "{\"pushConfig\":{\"pushEndpoint\":\"$WORKER_URL/pubsub\",\"oidcToken\":{\"serviceAccountEmail\":\"$SA_EMAIL\"}}}"
```

---

## 5. Deploying Firebase Hosting (Flutter web, mobile/)

Mirrors [.github/workflows/deploy-firebase.yml](.github/workflows/deploy-firebase.yml)'s `main`/prod
path. The `mobile/.firebaserc` already maps `prod` → `cookshop-poc-prj`, so no edits needed there.

```bash
cd mobile
flutter config --enable-web
flutter pub get

cat > .env <<EOF
ANALYZER_API_URL=https://ai-analyzer-645158438988.us-central1.run.app
MATCHER_API_URL=https://product-matcher-645158438988.us-central1.run.app
STATE_API_URL=https://state-manager-645158438988.us-central1.run.app
EOF

# prod build must override the dev Firebase web config baked into
# mobile/lib/firebase_options.dart (defaults point at cookshop-dev-prj-bd7e2).
# Get these 6 values from: Firebase Console → cookshop-poc-prj → Project settings
# → General → Your apps → Web app, OR: firebase apps:sdkconfig WEB <APP_ID> --project cookshop-poc-prj
flutter build web --release \
  --dart-define=FIREBASE_WEB_API_KEY=<prod Firebase web API key> \
  --dart-define=FIREBASE_WEB_APP_ID=<prod Firebase web app ID> \
  --dart-define=FIREBASE_WEB_MESSAGING_SENDER_ID=<prod sender ID> \
  --dart-define=FIREBASE_WEB_PROJECT_ID=cookshop-poc-prj \
  --dart-define=FIREBASE_WEB_STORAGE_BUCKET=cookshop-poc-prj.firebasestorage.app \
  --dart-define=FIREBASE_WEB_AUTH_DOMAIN=cookshop-poc-prj.firebaseapp.com

firebase deploy --only hosting --project prod   # "prod" alias resolves to cookshop-poc-prj
```

Live at `https://cookshop-poc-prj.web.app` once done.

---

## 6. Smoke test after deploy

```bash
curl https://state-manager-645158438988.us-central1.run.app/health     # {"status":"ok"}
curl https://product-matcher-645158438988.us-central1.run.app/health   # {"status":"ok"}
curl https://ai-analyzer-645158438988.us-central1.run.app/healthz      # {"status":"ok"}
curl https://pubsub-worker-645158438988.us-central1.run.app/health     # {"status":"ok"}

# Firestore round-trip (replace SESSION_ID with the value from §2)
curl -X POST https://state-manager-645158438988.us-central1.run.app/session/<SESSION_ID>/products \
  -H "Content-Type: application/json" \
  -d '{"products":[{"product_id":"p001","name":"Roma Tomatoes","price":2.99,"image_url":"https://placehold.co/200x200?text=Tomato"}]}'
# Expect: {"status":"updated","session_id":"<SESSION_ID>"}, and the Firebase Hosting site's
# shopping list should reflect it within 1-2s without a refresh.
```

---

## 7. If you later want CI/CD instead of manual deploys

The repo already has working GitHub Actions workflows
([deploy-cloudrun.yml](.github/workflows/deploy-cloudrun.yml),
[deploy-firebase.yml](.github/workflows/deploy-firebase.yml)) gated on Workload Identity
Federation (`WIF_PROVIDER` / `WIF_SERVICE_ACCOUNT` secrets) plus a `prod` GitHub Environment with
`PROJECT_ID`, `BUCKET_NAME`, `SESSION_ID`, etc. as variables. To make these work from the *new*
GitHub repo, the WIF provider on `cookshop-poc-prj` needs its attribute-condition/IAM binding
updated to trust the new repo's `repository`/`repository_owner` OIDC claim (WIF trust is based on
the GitHub OIDC issuer claims, not the GitHub account billing/org — cross-account is fine once the
binding is updated). That's a separate task from this doc; flag it if you want it set up.
