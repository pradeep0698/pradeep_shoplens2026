#!/usr/bin/env bash
# Deploy cloud services + frontend to shoplens2026-dev.
# Run from the repo root.
#
# Usage:
#   bash scripts/deploy-shoplens2026-dev.sh              # auto-detect changed services
#   bash scripts/deploy-shoplens2026-dev.sh --all        # force-deploy everything
#   bash scripts/deploy-shoplens2026-dev.sh ai-analyzer voice-assistant  # specific services
#   bash scripts/deploy-shoplens2026-dev.sh --frontend   # frontend only
#
# Deploys directly via `gcloud run deploy --source`, using the local
# .env.shoplens2026-dev vault files per service. This is a separate path from
# .github/workflows/deploy-shoplens2026-dev.yml (which pulls env vars from
# GitHub Secrets via Workload Identity Federation) — use whichever fits;
# this script is for deploying straight from a local checkout without
# needing GitHub Actions access.

set -euo pipefail

PROJECT=project-b1a5dd5a-69e6-4db3-9d7
REGION=us-central1
ALL_SERVICES=(ai-analyzer product-matcher state-manager voice-assistant pubsub-worker)
SHA_FILE=".shoplens2026-dev-last-deploy"

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
skip() { echo -e "  ⊘ $*"; }
info() { echo -e "${YELLOW}▶${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

# ── repo root guard ────────────────────────────────────────────────────────────
if [ ! -f "services/ai-analyzer/.env.shoplens2026-dev" ]; then
  err "Run this script from the repo root (shoplens/), not from scripts/."
  exit 1
fi

# ── vault file checks ──────────────────────────────────────────────────────────
missing=0
for svc in "${ALL_SERVICES[@]}"; do
  if [ ! -f "services/$svc/.env.shoplens2026-dev" ]; then
    err "Missing vault file: services/$svc/.env.shoplens2026-dev"
    missing=1
  fi
done
if [ ! -f "frontend/.env.shoplens2026-dev" ]; then
  err "Missing vault file: frontend/.env.shoplens2026-dev"
  missing=1
fi
[ "$missing" -eq 1 ] && exit 1

# ── change detection ───────────────────────────────────────────────────────────
CURRENT_SHA=$(git rev-parse HEAD)

changed_since_last() {
  local path=$1
  if [ ! -f "$SHA_FILE" ]; then
    return 0  # no record → treat as changed
  fi
  local last_sha
  last_sha=$(cat "$SHA_FILE")
  if [ "$last_sha" = "$CURRENT_SHA" ]; then
    return 1  # nothing new since last deploy
  fi
  git diff --name-only "$last_sha"..HEAD -- "$path" | grep -q .
}

# ── arg parsing ────────────────────────────────────────────────────────────────
DEPLOY_ALL=0
FRONTEND_ONLY=0
EXPLICIT_SERVICES=()

for arg in "$@"; do
  case "$arg" in
    --all)      DEPLOY_ALL=1 ;;
    --frontend) FRONTEND_ONLY=1 ;;
    *)          EXPLICIT_SERVICES+=("$arg") ;;
  esac
done

# ── deploy a single service ────────────────────────────────────────────────────
deploy_service() {
  local svc=$1
  local env_file="services/$svc/.env.shoplens2026-dev"
  info "Deploying $svc..."
  local vars
  vars=$(grep -v '^#' "$env_file" | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//')
  gcloud run deploy "$svc" \
    --project "$PROJECT" \
    --region  "$REGION" \
    --source  "services/$svc" \
    --set-env-vars "$vars" \
    --quiet
  ok "$svc deployed"
}

# ── deploy frontend ────────────────────────────────────────────────────────────
deploy_frontend() {
  info "Deploying frontend..."
  cp frontend/.env.shoplens2026-dev frontend/.env.local
  (cd frontend && npm run build --silent && firebase deploy --only hosting --project "$PROJECT" --non-interactive)
  ok "Frontend deployed"
}

# ── main ───────────────────────────────────────────────────────────────────────
echo ""
echo "shoplens2026-dev deploy  •  $(git log -1 --format='%h %s')"
echo "──────────────────────────────────────────────────────"

deployed=0
skipped=0

if [ "$FRONTEND_ONLY" -eq 1 ]; then
  deploy_frontend
  deployed=$((deployed + 1))
else
  # Backend services
  for svc in "${ALL_SERVICES[@]}"; do
    if [ "$DEPLOY_ALL" -eq 1 ] || [[ " ${EXPLICIT_SERVICES[*]} " =~ " $svc " ]]; then
      deploy_service "$svc"
      deployed=$((deployed + 1))
    elif [ "${#EXPLICIT_SERVICES[@]}" -eq 0 ] && changed_since_last "services/$svc"; then
      deploy_service "$svc"
      deployed=$((deployed + 1))
    else
      skip "$svc — no changes, skipping"
      skipped=$((skipped + 1))
    fi
  done

  # Frontend
  if [ "$DEPLOY_ALL" -eq 1 ] || ([ "${#EXPLICIT_SERVICES[@]}" -eq 0 ] && changed_since_last "frontend"); then
    deploy_frontend
    deployed=$((deployed + 1))
  else
    skip "frontend — no changes, skipping"
    skipped=$((skipped + 1))
  fi
fi

# ── save SHA ───────────────────────────────────────────────────────────────────
echo "$CURRENT_SHA" > "$SHA_FILE"

echo "──────────────────────────────────────────────────────"
ok "Done. $deployed deployed, $skipped skipped.  SHA: ${CURRENT_SHA:0:7}"
echo ""
