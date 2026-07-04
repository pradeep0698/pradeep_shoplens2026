#!/usr/bin/env bash
# Run the ShopLens Postman collections with Newman and save HTML reports.
# Run from the repo root.
#
# Usage:
#   bash scripts/run-postman-tests.sh                       # main collection vs cookshop-dev-rajan-prod
#   bash scripts/run-postman-tests.sh --env shoplens-dev     # main collection vs shoplens-dev
#   bash scripts/run-postman-tests.sh --with-perf            # also run the ai-analyzer perf collection
#   bash scripts/run-postman-tests.sh --perf-only            # only run the perf collection
#
# Reports are written to docs/postman/test-results/<yyyy-mm-dd-hh-mm>-<suite>.html

set -euo pipefail

ENV_NAME="cookshop-dev-rajan-prod"
RUN_MAIN=1
RUN_PERF=0

for arg in "$@"; do
  case "$arg" in
    --env)
      ;; # next arg carries the value, matched below
    shoplens-dev|cookshop-dev-rajan-prod)
      ENV_NAME="$arg"
      ;;
    --with-perf)
      RUN_PERF=1
      ;;
    --perf-only)
      RUN_MAIN=0
      RUN_PERF=1
      ;;
    *)
      ;;
  esac
done

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}▶${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

# ── repo root guard ────────────────────────────────────────────────────────────
if [ ! -d "docs/postman" ]; then
  err "Run this script from the repo root (shoplens/), not from scripts/."
  exit 1
fi

# ── dependency check ───────────────────────────────────────────────────────────
if ! command -v newman >/dev/null 2>&1; then
  err "newman not found. Install it with: npm install -g newman"
  exit 1
fi
if ! npm ls -g newman-reporter-htmlextra >/dev/null 2>&1; then
  info "newman-reporter-htmlextra not found — installing..."
  npm install -g newman-reporter-htmlextra
fi

mkdir -p docs/postman/test-results
TS="$(date +"%Y-%m-%d-%H-%M")"

MAIN_ENV_FILE="docs/postman/${ENV_NAME}.postman_environment.json"
if [ ! -f "$MAIN_ENV_FILE" ]; then
  err "No environment file found at $MAIN_ENV_FILE"
  exit 1
fi

FAIL_COUNT=0

if [ "$RUN_MAIN" = "1" ]; then
  MAIN_REPORT="docs/postman/test-results/${TS}-all-services.html"
  info "Running ShopLens - All Services against $ENV_NAME ..."
  if newman run docs/postman/shoplens-all-services.postman_collection.json \
    -e "$MAIN_ENV_FILE" \
    --timeout-request 60000 \
    --reporters cli,htmlextra \
    --reporter-htmlextra-export "$MAIN_REPORT" \
    --reporter-htmlextra-title "ShopLens All Services - $ENV_NAME"; then
    ok "All Services suite passed -> $MAIN_REPORT"
  else
    err "All Services suite had failures -> $MAIN_REPORT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

if [ "$RUN_PERF" = "1" ]; then
  PERF_REPORT="docs/postman/test-results/${TS}-analyze-perf.html"
  info "Running ShopLens Analyze API - Performance Testing ..."
  if newman run postman/shoplens-analyze-perf.postman_collection.json \
    -e postman/shoplens-dev-cloud.postman_environment.json \
    --timeout-request 60000 \
    --reporters cli,htmlextra \
    --reporter-htmlextra-export "$PERF_REPORT" \
    --reporter-htmlextra-title "ShopLens Analyze Perf"; then
    ok "Analyze Perf suite passed -> $PERF_REPORT"
  else
    err "Analyze Perf suite had failures -> $PERF_REPORT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  ok "All requested suites passed."
else
  err "$FAIL_COUNT suite(s) had failures — open the HTML report(s) above for details."
  exit 1
fi
