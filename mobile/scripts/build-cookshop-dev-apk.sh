#!/usr/bin/env bash
# Build a release APK pointed at the cookshop-dev GCP environment.
# Usage (from the mobile/ directory):
#   bash scripts/build-cookshop-dev-apk.sh
#
# Prerequisites:
# 1. Fill in the REPLACE_WITH_* values in .dart_define/cookshop-dev.json
#    with the real keys from the cookshop-dev-prj-bd7e2 Firebase console.
# 2. Place the cookshop-dev google-services.json at:
#    android/app/google-services.cookshop-dev.json
#    (download from Firebase console > Project settings > Your apps > Android)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOBILE_DIR="$(dirname "$SCRIPT_DIR")"
GOOGLE_SERVICES="$MOBILE_DIR/android/app/google-services.json"
COOKSHOP_GOOGLE_SERVICES="$MOBILE_DIR/android/app/google-services.cookshop-dev.json"

if [ ! -f "$COOKSHOP_GOOGLE_SERVICES" ]; then
  echo "ERROR: $COOKSHOP_GOOGLE_SERVICES not found."
  echo "Download it from Firebase console > cookshop-dev-prj-bd7e2 > Project settings > Android app."
  exit 1
fi

# Swap in the cookshop-dev google-services.json
cp "$GOOGLE_SERVICES" "$GOOGLE_SERVICES.bak"
cp "$COOKSHOP_GOOGLE_SERVICES" "$GOOGLE_SERVICES"

cleanup() {
  echo "Restoring original google-services.json..."
  cp "$GOOGLE_SERVICES.bak" "$GOOGLE_SERVICES"
  rm "$GOOGLE_SERVICES.bak"
}
trap cleanup EXIT

cd "$MOBILE_DIR"
flutter build apk --release \
  --dart-define-from-file=.dart_define/cookshop-dev.json

echo ""
echo "APK built: build/app/outputs/flutter-apk/app-release.apk"
echo "This APK points to cookshop-dev-prj-bd7e2 / 82592393149."
