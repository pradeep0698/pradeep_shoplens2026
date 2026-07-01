#!/usr/bin/env bash
# ShopLens 2026-Dev Platform Setup
# Project ID:     project-b1a5dd5a-69e6-4db3-9d7
# Project Number: 115535290381
# Owner:          suryarao.r@gmail.com
# Region:         us-central1
#
# Usage:
#   Run sections interactively, or run the whole script:
#     bash scripts/shoplens2026-dev-setup.sh
#
#   To run only specific sections:
#     SECTIONS="1 2 3" bash scripts/shoplens2026-dev-setup.sh
#
# Prerequisites: gcloud CLI, firebase-tools (npm install -g firebase-tools), jq, curl

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID="project-b1a5dd5a-69e6-4db3-9d7"
PROJECT_NUMBER="115535290381"
REGION="us-central1"
SA_EMAIL="shoplens-runner@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
GITHUB_REPO="shoplensai-coder/shoplens"
HLS_BUCKET="shoplens2026-dev-hls-segments"
LENS_BUCKET="shoplens2026-dev-lens-tmp"
ARTIFACT_REPO="shoplens"
WIF_POOL="github-pool"
WIF_PROVIDER="github-provider"

# Set to space-separated list to run only specific sections, e.g. "1 2 6"
# Leave empty to run all sections.
SECTIONS="${SECTIONS:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[setup]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

should_run() {
  local section="$1"
  [[ -z "$SECTIONS" ]] && return 0
  [[ " $SECTIONS " == *" $section "* ]] && return 0
  return 1
}

section() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Section $1 — $2${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

check_prereqs() {
  log "Checking prerequisites..."
  command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
  command -v firebase >/dev/null 2>&1 || warn "firebase CLI not found — Firebase sections will require manual steps"
  command -v curl >/dev/null 2>&1    || warn "curl not found — smoke tests will be skipped"
  command -v jq >/dev/null 2>&1      || warn "jq not found — smoke test output will be raw JSON"
  ok "Prerequisites checked"
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}ShopLens 2026-Dev Setup${NC}"
echo -e "Project: ${PROJECT_ID}"
echo -e "Number:  ${PROJECT_NUMBER}"
echo -e "Region:  ${REGION}"
echo ""

check_prereqs

# ─────────────────────────────────────────────────────────────────────────────
# Section 1 — Project Initialization
# ─────────────────────────────────────────────────────────────────────────────
if should_run 1; then
  section 1 "Project Initialization"

  log "Authenticating..."
  gcloud auth login suryarao.r@gmail.com --no-launch-browser || true
  gcloud config set account suryarao.r@gmail.com
  gcloud config set project "$PROJECT_ID"

  log "Verifying owner access..."
  gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:suryarao.r@gmail.com" \
    --format="table(bindings.role)"

  ok "Section 1 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 2 — Enable APIs
# ─────────────────────────────────────────────────────────────────────────────
if should_run 2; then
  section 2 "Enable All Required APIs"

  log "Enabling 20 APIs (this takes ~2 minutes)..."
  gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    firestore.googleapis.com \
    pubsub.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    storage.googleapis.com \
    livestream.googleapis.com \
    aiplatform.googleapis.com \
    firebase.googleapis.com \
    firebaserules.googleapis.com \
    speech.googleapis.com \
    vision.googleapis.com \
    secretmanager.googleapis.com \
    eventarc.googleapis.com \
    cloudresourcemanager.googleapis.com \
    sts.googleapis.com \
    identitytoolkit.googleapis.com \
    --project="$PROJECT_ID"

  log "Verifying enabled APIs..."
  gcloud services list --enabled --project="$PROJECT_ID" \
    --filter="name:(run OR firestore OR pubsub OR aiplatform OR livestream OR artifactregistry OR firebase OR secretmanager)" \
    --format="table(name)"

  ok "Section 2 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 3 — Firebase Setup
# ─────────────────────────────────────────────────────────────────────────────
if should_run 3; then
  section 3 "Firebase Setup"

  log "Adding Firebase to GCP project..."
  if command -v firebase >/dev/null 2>&1; then
    firebase projects:addfirebase "$PROJECT_ID" || warn "Firebase may already be added — continuing"
  else
    warn "firebase CLI not found. Manually add Firebase:"
    warn "  https://console.firebase.google.com → Add project → Add Firebase to a Google Cloud project → $PROJECT_ID"
  fi

  log "Creating Firestore database (Native mode, us-central1)..."
  gcloud firestore databases create \
    --location=us-central1 \
    --type=firestore-native \
    --project="$PROJECT_ID" || warn "Firestore database may already exist — continuing"

  if command -v firebase >/dev/null 2>&1; then
    log "Deploying Firestore security rules..."
    (cd frontend && firebase deploy --only firestore:rules --project "$PROJECT_ID")

    log "Deploying Firebase Hosting..."
    (cd frontend && firebase deploy --only hosting --project "$PROJECT_ID")
  else
    warn "Skipping Firebase rule/hosting deploy — firebase CLI not installed"
  fi

  echo ""
  warn "MANUAL STEPS required in Firebase Console (https://console.firebase.google.com/project/${PROJECT_ID}):"
  warn "  1. Authentication → Get started → enable Email/Password provider"
  warn "  2. Storage → Get started → choose us-central1"
  warn "  3. Project Settings → Your apps → Add app → Web → copy config to frontend/.env.shoplens2026-dev"
  warn "  4. Project Settings → Your apps → Add app → Android → download google-services.json"
  warn "     Save as: mobile/android/app/google-services.shoplens2026-dev.json"
  warn "  5. Project Settings → Your apps → Add app → Apple → download GoogleService-Info.plist"
  warn "     Save as: mobile/ios/Runner/GoogleService-Info.shoplens2026-dev.plist"

  ok "Section 3 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 4 — Cloud Storage Buckets
# ─────────────────────────────────────────────────────────────────────────────
if should_run 4; then
  section 4 "Cloud Storage Buckets"

  log "Creating HLS segments bucket..."
  gcloud storage buckets create "gs://${HLS_BUCKET}" \
    --location=us-central1 \
    --project="$PROJECT_ID" || warn "Bucket gs://${HLS_BUCKET} may already exist"

  log "Setting public read on HLS bucket..."
  gcloud storage buckets add-iam-policy-binding "gs://${HLS_BUCKET}" \
    --member="allUsers" \
    --role="roles/storage.objectViewer"

  log "Enabling uniform bucket-level access on HLS bucket..."
  gcloud storage buckets update "gs://${HLS_BUCKET}" \
    --uniform-bucket-level-access

  log "Creating lens-tmp bucket..."
  gcloud storage buckets create "gs://${LENS_BUCKET}" \
    --location=us-central1 \
    --project="$PROJECT_ID" || warn "Bucket gs://${LENS_BUCKET} may already exist"

  log "Setting public read on lens-tmp bucket..."
  gcloud storage buckets add-iam-policy-binding "gs://${LENS_BUCKET}" \
    --member="allUsers" \
    --role="roles/storage.objectViewer"

  log "Setting 1-day lifecycle delete on lens-tmp bucket..."
  LIFECYCLE_TMP="${TMPDIR:-/tmp}/shoplens-lifecycle-$$.json"
  echo '{"lifecycle":{"rule":[{"action":{"type":"Delete"},"condition":{"age":1}}]}}' > "$LIFECYCLE_TMP"
  gcloud storage buckets update "gs://${LENS_BUCKET}" --lifecycle-file="$LIFECYCLE_TMP"
  rm -f "$LIFECYCLE_TMP"

  log "Verifying buckets..."
  gcloud storage buckets list --project="$PROJECT_ID" \
    --filter="name:(${HLS_BUCKET} OR ${LENS_BUCKET})" \
    --format="table(name, location, storageClass)"

  ok "Section 4 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 5 — Artifact Registry
# ─────────────────────────────────────────────────────────────────────────────
if should_run 5; then
  section 5 "Artifact Registry"

  log "Creating Docker repository..."
  gcloud artifacts repositories create "$ARTIFACT_REPO" \
    --repository-format=docker \
    --location=us-central1 \
    --description="ShopLens 2026-dev Docker images" \
    --project="$PROJECT_ID" || warn "Repository may already exist — continuing"

  log "Configuring Docker auth for us-central1-docker.pkg.dev..."
  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

  ok "Section 5 complete"
  echo "  Image base path: us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/<service>"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 6 — Service Account & IAM
# ─────────────────────────────────────────────────────────────────────────────
if should_run 6; then
  section 6 "Service Account & IAM"

  log "Creating shoplens-runner service account..."
  gcloud iam service-accounts create shoplens-runner \
    --display-name="ShopLens Runtime Service Account" \
    --description="Used by Cloud Run services and GitHub Actions CI/CD" \
    --project="$PROJECT_ID" || warn "Service account may already exist — continuing"

  log "Granting IAM roles to ${SA_EMAIL}..."

  ROLES=(
    "roles/run.admin"
    "roles/run.invoker"
    "roles/pubsub.publisher"
    "roles/pubsub.subscriber"
    "roles/datastore.user"
    "roles/aiplatform.user"
    "roles/storage.objectAdmin"
    "roles/livestream.admin"
    "roles/secretmanager.secretAccessor"
    "roles/artifactregistry.writer"
    "roles/cloudbuild.builds.editor"
  )

  for ROLE in "${ROLES[@]}"; do
    log "  Granting ${ROLE}..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$ROLE" \
      --quiet
  done

  log "Granting self-impersonation (iam.serviceAccountUser) on SA..."
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID"

  log "Granting Cloud Build SA permissions..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BUILD_SA}" \
    --role="roles/run.admin" \
    --quiet

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BUILD_SA}" \
    --role="roles/artifactregistry.writer" \
    --quiet

  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="serviceAccount:${BUILD_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID"

  log "Verifying roles granted to shoplens-runner..."
  gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:shoplens-runner" \
    --format="table(bindings.role)"

  ok "Section 6 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 7 — Workload Identity Federation
# ─────────────────────────────────────────────────────────────────────────────
if should_run 7; then
  section 7 "Workload Identity Federation (GitHub Actions)"

  log "Creating Workload Identity Pool: ${WIF_POOL}..."
  gcloud iam workload-identity-pools create "$WIF_POOL" \
    --location=global \
    --display-name="GitHub Actions Pool" \
    --description="Workload Identity Pool for GitHub Actions CI/CD" \
    --project="$PROJECT_ID" || warn "Pool may already exist — continuing"

  log "Creating OIDC Provider: ${WIF_PROVIDER} (locked to repo ${GITHUB_REPO})..."
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --display-name="GitHub Actions Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
    --project="$PROJECT_ID" || warn "Provider may already exist — continuing"

  log "Binding SA to Workload Identity Pool..."
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}" \
    --project="$PROJECT_ID"

  echo ""
  log "WIF Provider resource name (add this as GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER_2026_DEV):"
  gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --project="$PROJECT_ID" \
    --format="value(name)"

  ok "Section 7 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 8 — GitHub Actions Secrets reminder
# ─────────────────────────────────────────────────────────────────────────────
if should_run 8; then
  section 8 "GitHub Actions Secrets (Manual)"

  WIF_PROVIDER_FULL="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

  echo ""
  warn "Add the following secrets to GitHub repo → Settings → Secrets and variables → Actions:"
  echo ""
  printf "  %-45s = %s\n" "GCP_PROJECT_ID_2026_DEV"                    "$PROJECT_ID"
  printf "  %-45s = %s\n" "GCP_PROJECT_NUMBER_2026_DEV"                 "$PROJECT_NUMBER"
  printf "  %-45s = %s\n" "GCP_WORKLOAD_IDENTITY_PROVIDER_2026_DEV"    "$WIF_PROVIDER_FULL"
  printf "  %-45s = %s\n" "GCP_SERVICE_ACCOUNT_2026_DEV"                "$SA_EMAIL"
  printf "  %-45s = %s\n" "SERPAPI_KEY"                                  "<your-serpapi-key>"
  echo ""

  ok "Section 8 complete (manual steps noted above)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 9 — Pub/Sub
# ─────────────────────────────────────────────────────────────────────────────
if should_run 9; then
  section 9 "Pub/Sub (Live Video Pipeline)"

  log "Creating Pub/Sub topic: video-segments-topic..."
  gcloud pubsub topics create video-segments-topic \
    --project="$PROJECT_ID" || warn "Topic may already exist — continuing"

  log "Creating GCS notification on HLS bucket → topic..."
  gcloud storage buckets notifications create "gs://${HLS_BUCKET}" \
    --topic=video-segments-topic \
    --event-types=OBJECT_FINALIZE \
    --project="$PROJECT_ID" || warn "Notification may already exist — continuing"

  warn "Pub/Sub push subscription (video-segments-sub) must be created AFTER pubsub-worker is deployed."
  warn "Run this after Section 10.5:"
  warn "  gcloud pubsub subscriptions create video-segments-sub \\"
  warn "    --topic=video-segments-topic \\"
  warn "    --push-endpoint=https://pubsub-worker-${PROJECT_NUMBER}.us-central1.run.app/pubsub \\"
  warn "    --ack-deadline=60 \\"
  warn "    --project=${PROJECT_ID}"

  ok "Section 9 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 10 — Cloud Run Services
# ─────────────────────────────────────────────────────────────────────────────
if should_run 10; then
  section 10 "Cloud Run Services"

  DEPLOY_BASE="--region=${REGION} --service-account=${SA_EMAIL} --project=${PROJECT_ID} --quiet"

  # Prompt for SERPAPI_KEY if not set
  if [[ -z "${SERPAPI_KEY:-}" ]]; then
    echo -n "Enter your SERPAPI_KEY: "
    read -rs SERPAPI_KEY
    echo ""
    [[ -z "$SERPAPI_KEY" ]] && die "SERPAPI_KEY is required for ai-analyzer and product-matcher"
  fi

  # 10.1 — ai-analyzer
  log "Deploying ai-analyzer..."
  (cd services/ai-analyzer && gcloud run deploy ai-analyzer \
    --source=. \
    --allow-unauthenticated \
    --port=8080 \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},LOCATION=${REGION},GEMINI_MODEL=gemini-2.5-flash,GCS_LENS_BUCKET=${LENS_BUCKET},SERPAPI_KEY=${SERPAPI_KEY}" \
    $DEPLOY_BASE)

  # 10.2 — product-matcher
  log "Deploying product-matcher..."
  (cd services/product-matcher && gcloud run deploy product-matcher \
    --source=. \
    --allow-unauthenticated \
    --port=8080 \
    --set-env-vars="SERPAPI_KEY=${SERPAPI_KEY}" \
    $DEPLOY_BASE)

  # 10.3 — state-manager
  log "Deploying state-manager..."
  (cd services/state-manager && gcloud run deploy state-manager \
    --source=. \
    --allow-unauthenticated \
    --port=8080 \
    --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
    $DEPLOY_BASE)

  # 10.4 — voice-assistant
  log "Fetching product-matcher URL..."
  PRODUCT_MATCHER_URL=$(gcloud run services describe product-matcher \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(status.url)")
  log "  product-matcher URL: ${PRODUCT_MATCHER_URL}"

  log "Deploying voice-assistant..."
  (cd services/voice-assistant && gcloud run deploy voice-assistant \
    --source=. \
    --no-allow-unauthenticated \
    --port=8080 \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},LOCATION=${REGION},VOICE_MODEL=gemini-live-2.5-flash-native-audio,EXTRACTION_MODEL=gemini-2.5-flash,VOICE_NAME=Puck,SESSION_MAX_SECONDS=300,INACTIVITY_NUDGE_SECONDS=30,INACTIVITY_CLOSE_GRACE_SECONDS=10,SESSION_CONTEXT_WINDOW_TOKENS=8000,PRODUCT_MATCHER_URL=${PRODUCT_MATCHER_URL}" \
    $DEPLOY_BASE)

  # Grant authenticated users invoke access on voice-assistant
  log "Granting allAuthenticatedUsers invoke on voice-assistant..."
  gcloud run services add-iam-policy-binding voice-assistant \
    --region="${REGION}" \
    --member="allAuthenticatedUsers" \
    --role="roles/run.invoker" \
    --project="${PROJECT_ID}"

  # 10.5 — pubsub-worker
  log "Fetching ai-analyzer and state-manager URLs..."
  AI_ANALYZER_URL=$(gcloud run services describe ai-analyzer \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(status.url)")
  STATE_MANAGER_URL=$(gcloud run services describe state-manager \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(status.url)")

  log "Deploying pubsub-worker..."
  (cd services/pubsub-worker && gcloud run deploy pubsub-worker \
    --source=. \
    --no-allow-unauthenticated \
    --port=8080 \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=${HLS_BUCKET},AI_ANALYZER_URL=${AI_ANALYZER_URL},STATE_MANAGER_URL=${STATE_MANAGER_URL}" \
    $DEPLOY_BASE)

  # Allow Pub/Sub SA to invoke pubsub-worker
  log "Granting Pub/Sub SA invoke on pubsub-worker..."
  gcloud run services add-iam-policy-binding pubsub-worker \
    --region="${REGION}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
    --role="roles/run.invoker" \
    --project="${PROJECT_ID}"

  # Now create Pub/Sub push subscription (depends on pubsub-worker being deployed)
  log "Creating Pub/Sub push subscription pointing at pubsub-worker..."
  gcloud pubsub subscriptions create video-segments-sub \
    --topic=video-segments-topic \
    --push-endpoint="https://pubsub-worker-${PROJECT_NUMBER}.${REGION}.run.app/pubsub" \
    --ack-deadline=60 \
    --project="$PROJECT_ID" || warn "Subscription may already exist — continuing"

  log "All Cloud Run services deployed. Listing..."
  gcloud run services list \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="table(metadata.name, status.url)"

  ok "Section 10 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 11 — Cloud Live Stream
# ─────────────────────────────────────────────────────────────────────────────
if should_run 11; then
  section 11 "Cloud Live Stream Setup"

  if [[ -f "services/live-ingest/setup_live_stream.py" ]]; then
    log "Running live stream setup script..."
    PROJECT_ID="$PROJECT_ID" \
    LOCATION="${REGION}" \
    BUCKET_NAME="${HLS_BUCKET}" \
    CHANNEL_ID="shoplens2026-channel" \
    INPUT_ID="shoplens2026-input" \
    python services/live-ingest/setup_live_stream.py
    warn "Note the RTMP ingest endpoint above — configure this in OBS or your encoder."
  else
    warn "services/live-ingest/setup_live_stream.py not found — skipping"
  fi

  ok "Section 11 complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 12 — Generate .env files
# ─────────────────────────────────────────────────────────────────────────────
if should_run 12; then
  section 12 "Generate Environment Variable Files"

  AI_ANALYZER_URL="https://ai-analyzer-${PROJECT_NUMBER}.${REGION}.run.app"
  PRODUCT_MATCHER_URL="https://product-matcher-${PROJECT_NUMBER}.${REGION}.run.app"
  STATE_MANAGER_URL="https://state-manager-${PROJECT_NUMBER}.${REGION}.run.app"
  VOICE_ASSISTANT_URL="https://voice-assistant-${PROJECT_NUMBER}.${REGION}.run.app"

  log "Writing services/ai-analyzer/.env.shoplens2026-dev..."
  cat > services/ai-analyzer/.env.shoplens2026-dev <<EOF
PROJECT_ID=${PROJECT_ID}
LOCATION=${REGION}
GEMINI_MODEL=gemini-2.5-flash
GCS_LENS_BUCKET=${LENS_BUCKET}
SERPAPI_KEY=<your-serpapi-key>
EOF

  log "Writing services/product-matcher/.env.shoplens2026-dev..."
  cat > services/product-matcher/.env.shoplens2026-dev <<EOF
SERPAPI_KEY=<your-serpapi-key>
EOF

  log "Writing services/state-manager/.env.shoplens2026-dev..."
  cat > services/state-manager/.env.shoplens2026-dev <<EOF
PROJECT_ID=${PROJECT_ID}
# FIRESTORE_PROJECT_ID=<only if Firestore is in a separate project>
EOF

  log "Writing services/voice-assistant/.env.shoplens2026-dev..."
  cat > services/voice-assistant/.env.shoplens2026-dev <<EOF
PROJECT_ID=${PROJECT_ID}
LOCATION=${REGION}
VOICE_MODEL=gemini-live-2.5-flash-native-audio
EXTRACTION_MODEL=gemini-2.5-flash
VOICE_NAME=Puck
SESSION_MAX_SECONDS=300
INACTIVITY_NUDGE_SECONDS=30
INACTIVITY_CLOSE_GRACE_SECONDS=10
SESSION_CONTEXT_WINDOW_TOKENS=8000
PRODUCT_MATCHER_URL=${PRODUCT_MATCHER_URL}
# FIRESTORE_PROJECT_ID=<only if Firestore is in a separate project>
EOF

  log "Writing services/pubsub-worker/.env.shoplens2026-dev..."
  cat > services/pubsub-worker/.env.shoplens2026-dev <<EOF
PROJECT_ID=${PROJECT_ID}
TOPIC_ID=video-segments-topic
SUBSCRIPTION_ID=video-segments-sub
BUCKET_NAME=${HLS_BUCKET}
AI_ANALYZER_URL=${AI_ANALYZER_URL}
STATE_MANAGER_URL=${STATE_MANAGER_URL}
SESSION_ID=dev-session-001
EOF

  log "Writing frontend/.env.shoplens2026-dev..."
  cat > frontend/.env.shoplens2026-dev <<EOF
# Get FIREBASE_API_KEY and FIREBASE_APP_ID from Firebase Console → Project Settings → Your apps → Web
NEXT_PUBLIC_FIREBASE_API_KEY=<from-firebase-console>
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=${PROJECT_ID}.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=${PROJECT_ID}
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=${PROJECT_ID}.firebasestorage.app
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=${PROJECT_NUMBER}
NEXT_PUBLIC_FIREBASE_APP_ID=<from-firebase-console>
NEXT_PUBLIC_AI_ANALYZER_URL=${AI_ANALYZER_URL}
NEXT_PUBLIC_PRODUCT_MATCHER_URL=${PRODUCT_MATCHER_URL}
NEXT_PUBLIC_STATE_MANAGER_URL=${STATE_MANAGER_URL}
NEXT_PUBLIC_VOICE_ASSISTANT_URL=${VOICE_ASSISTANT_URL}
EOF

  log "Writing mobile/.dart_define/shoplens2026-dev.json..."
  mkdir -p mobile/.dart_define
  cat > mobile/.dart_define/shoplens2026-dev.json <<EOF
{
  "FIREBASE_PROJECT_ID": "${PROJECT_ID}",
  "AI_ANALYZER_URL": "${AI_ANALYZER_URL}",
  "PRODUCT_MATCHER_URL": "${PRODUCT_MATCHER_URL}",
  "STATE_MANAGER_URL": "${STATE_MANAGER_URL}",
  "VOICE_ASSISTANT_URL": "${VOICE_ASSISTANT_URL}"
}
EOF

  warn "Fill in SERPAPI_KEY and Firebase API key/app ID in the generated .env files before deploying."
  ok "Section 12 complete — .env files written"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 13 — Mobile APK Build
# ─────────────────────────────────────────────────────────────────────────────
if should_run 13; then
  section 13 "Mobile APK Build"

  GOOGLE_SERVICES_SRC="mobile/android/app/google-services.shoplens2026-dev.json"
  GOOGLE_SERVICES_DST="mobile/android/app/google-services.json"
  GOOGLE_SERVICES_BAK="mobile/android/app/google-services.original.json"

  if [[ ! -f "$GOOGLE_SERVICES_SRC" ]]; then
    die "Missing ${GOOGLE_SERVICES_SRC} — download from Firebase Console first (Section 3.7)"
  fi

  log "Swapping in shoplens2026-dev Firebase config..."
  cp "$GOOGLE_SERVICES_DST" "$GOOGLE_SERVICES_BAK"
  cp "$GOOGLE_SERVICES_SRC" "$GOOGLE_SERVICES_DST"

  log "Building release APK..."
  (cd mobile && flutter build apk --release \
    --dart-define-from-file=.dart_define/shoplens2026-dev.json)

  log "Restoring original Firebase config..."
  cp "$GOOGLE_SERVICES_BAK" "$GOOGLE_SERVICES_DST"
  rm "$GOOGLE_SERVICES_BAK"

  ok "Section 13 complete"
  echo "  APK: mobile/build/app/outputs/flutter-apk/app-release.apk"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 14 — Verification
# ─────────────────────────────────────────────────────────────────────────────
if should_run 14; then
  section 14 "Verification Checklist"

  PASS=0; FAIL=0

  check() {
    local label="$1"; shift
    if eval "$@" &>/dev/null; then
      echo -e "  ${GREEN}PASS${NC}  $label"
      PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}  $label"
      FAIL=$((FAIL+1))
    fi
  }

  log "Running checks..."

  check "APIs: Cloud Run enabled" \
    "gcloud services list --enabled --project='$PROJECT_ID' | grep -q 'run.googleapis.com'"

  check "APIs: Firestore enabled" \
    "gcloud services list --enabled --project='$PROJECT_ID' | grep -q 'firestore.googleapis.com'"

  check "APIs: Vertex AI enabled" \
    "gcloud services list --enabled --project='$PROJECT_ID' | grep -q 'aiplatform.googleapis.com'"

  check "IAM: shoplens-runner SA exists" \
    "gcloud iam service-accounts describe '${SA_EMAIL}' --project='$PROJECT_ID'"

  check "WIF: github-pool exists" \
    "gcloud iam workload-identity-pools describe '${WIF_POOL}' --location=global --project='$PROJECT_ID'"

  check "Storage: HLS bucket exists" \
    "gcloud storage buckets describe 'gs://${HLS_BUCKET}'"

  check "Storage: lens-tmp bucket exists" \
    "gcloud storage buckets describe 'gs://${LENS_BUCKET}'"

  check "Artifact Registry: shoplens repo exists" \
    "gcloud artifacts repositories describe '${ARTIFACT_REPO}' --location=us-central1 --project='$PROJECT_ID'"

  check "Pub/Sub: video-segments-topic exists" \
    "gcloud pubsub topics describe video-segments-topic --project='$PROJECT_ID'"

  check "Firestore: database exists" \
    "gcloud firestore databases list --project='$PROJECT_ID' | grep -q 'projects'"

  check "Cloud Run: ai-analyzer deployed" \
    "gcloud run services describe ai-analyzer --region='$REGION' --project='$PROJECT_ID'"

  check "Cloud Run: product-matcher deployed" \
    "gcloud run services describe product-matcher --region='$REGION' --project='$PROJECT_ID'"

  check "Cloud Run: state-manager deployed" \
    "gcloud run services describe state-manager --region='$REGION' --project='$PROJECT_ID'"

  check "Cloud Run: voice-assistant deployed" \
    "gcloud run services describe voice-assistant --region='$REGION' --project='$PROJECT_ID'"

  check "Cloud Run: pubsub-worker deployed" \
    "gcloud run services describe pubsub-worker --region='$REGION' --project='$PROJECT_ID'"

  # HTTP smoke tests
  if command -v curl >/dev/null 2>&1; then
    AI_URL="https://ai-analyzer-${PROJECT_NUMBER}.${REGION}.run.app/health"
    PM_URL="https://product-matcher-${PROJECT_NUMBER}.${REGION}.run.app/health"

    check "Smoke: ai-analyzer /health responds 200" \
      "curl -sf '$AI_URL' -o /dev/null"

    check "Smoke: product-matcher /health responds 200" \
      "curl -sf '$PM_URL' -o /dev/null"
  fi

  echo ""
  echo -e "Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
  [[ $FAIL -eq 0 ]] && ok "All checks passed — shoplens2026-dev is ready!" \
                     || warn "Some checks failed — review output above"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Setup complete — Quick Reference${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
printf "  %-30s %s\n" "Project ID:"       "$PROJECT_ID"
printf "  %-30s %s\n" "Project Number:"   "$PROJECT_NUMBER"
printf "  %-30s %s\n" "Region:"           "$REGION"
printf "  %-30s %s\n" "Service Account:"  "$SA_EMAIL"
printf "  %-30s %s\n" "HLS Bucket:"       "gs://${HLS_BUCKET}"
printf "  %-30s %s\n" "Lens Tmp Bucket:"  "gs://${LENS_BUCKET}"
printf "  %-30s %s\n" "Artifact Registry:" "us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}"
echo ""
