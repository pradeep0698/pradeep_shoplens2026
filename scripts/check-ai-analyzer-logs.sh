#!/usr/bin/env bash
# Fetch new Cloud Run logs for the ai-analyzer service across BOTH shoplens deploy
# platforms since each platform's own last checkpoint: severity WARNING+ entries (for
# issue tracking) and TIMING summary lines (for perf metrics). Prints one pair of JSON
# arrays per platform to stdout, each preceded by a platform-tagged marker line. Used by
# the check-ai-analyzer-logs skill. Run from repo root. Requires `gcloud` authenticated
# against both projects below.
#
# Usage:
#   bash scripts/check-ai-analyzer-logs.sh                  # both platforms, since each's last checkpoint (or last 15m on first run); advances checkpoints
#   bash scripts/check-ai-analyzer-logs.sh --since-minutes 60   # ad-hoc lookback window for both platforms; does NOT touch checkpoints
#
# Consoles:
#   shoplens2026-dev: https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=project-b1a5dd5a-69e6-4db3-9d7
#   cookshop-dev:      https://console.cloud.google.com/run/detail/us-central1/ai-analyzer/observability/logs?project=cookshop-dev-prj

set -euo pipefail

SERVICE="ai-analyzer"
STATE_DIR=".claude/state"
OVERLAP_SECONDS=60
FIRST_RUN_LOOKBACK_MINUTES=15

# platform-name:project-id pairs — both are checked on every run.
PLATFORMS=(
  "shoplens2026-dev:project-b1a5dd5a-69e6-4db3-9d7"
  "cookshop-dev:cookshop-dev-prj"
)

if [ ! -d "docs" ]; then
  echo "Run this script from the repo root (shoplens/), not from scripts/." >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

SINCE_MINUTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since-minutes)
      SINCE_MINUTES="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for entry in "${PLATFORMS[@]}"; do
  PLATFORM="${entry%%:*}"
  PROJECT="${entry##*:}"

  CHECKPOINT_FILE="$STATE_DIR/ai-analyzer-logs-checkpoint.${PLATFORM}.txt"
  ADVANCE_CHECKPOINT=1

  if [ -n "$SINCE_MINUTES" ]; then
    START_TS="$(date -u -d "-${SINCE_MINUTES} minutes" +"%Y-%m-%dT%H:%M:%SZ")"
    ADVANCE_CHECKPOINT=0
  elif [ -f "$CHECKPOINT_FILE" ]; then
    LAST="$(cat "$CHECKPOINT_FILE")"
    START_TS="$(date -u -d "$LAST -${OVERLAP_SECONDS} seconds" +"%Y-%m-%dT%H:%M:%SZ")"
  else
    START_TS="$(date -u -d "-${FIRST_RUN_LOOKBACK_MINUTES} minutes" +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  WARN_FILTER="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${SERVICE}\" AND severity>=WARNING AND timestamp>\"${START_TS}\""
  TIMING_FILTER="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${SERVICE}\" AND textPayload:\"TIMING\" AND timestamp>\"${START_TS}\""

  echo "Fetching $SERVICE logs for $PLATFORM (project=$PROJECT) since $START_TS ..." >&2

  echo "=== WARNINGS $PLATFORM (severity>=WARNING) ==="
  gcloud logging read "$WARN_FILTER" \
    --project="$PROJECT" \
    --format=json \
    --order=asc \
    --limit=2000

  echo "=== TIMING $PLATFORM (perf metrics) ==="
  gcloud logging read "$TIMING_FILTER" \
    --project="$PROJECT" \
    --format=json \
    --order=asc \
    --limit=2000

  if [ "$ADVANCE_CHECKPOINT" = "1" ]; then
    echo "$NOW_ISO" > "$CHECKPOINT_FILE"
    echo "Checkpoint for $PLATFORM advanced to $NOW_ISO" >&2
  fi
done
