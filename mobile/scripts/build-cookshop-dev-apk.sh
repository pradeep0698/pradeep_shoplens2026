#!/usr/bin/env bash
# Build a release APK pointed at the cookshop-dev GCP environment.
# Usage (from the mobile/ directory):
#   bash scripts/build-cookshop-dev-apk.sh
#
# Prerequisites:
# 1. Fill in the REPLACE_WITH_* values in .dart_define/cookshop-dev.json
#    with the real keys from the cookshop-dev-prj-bd7e2 Firebase console.
#    If testing the direct-connect voice transport, also add a
#    VOICE_DIRECT_CONNECT_ENABLED: "true" entry — it authenticates via an
#    ephemeral token minted by the backend (POST /voice/session/token), not
#    a key baked into the app, so no AI Studio key dart-define is needed here.
# 2. Place the cookshop-dev google-services.json at:
#    android/app/google-services.cookshop-dev.json
#    (download from Firebase console > Project settings > Your apps > Android)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOBILE_DIR="$(dirname "$SCRIPT_DIR")"
GOOGLE_SERVICES="$MOBILE_DIR/android/app/google-services.json"
COOKSHOP_GOOGLE_SERVICES="$MOBILE_DIR/android/app/google-services.cookshop-dev.json"
BUILD_GRADLE="$MOBILE_DIR/android/app/build.gradle"

if [ ! -f "$COOKSHOP_GOOGLE_SERVICES" ]; then
  echo "ERROR: $COOKSHOP_GOOGLE_SERVICES not found."
  echo "Download it from Firebase console > cookshop-dev-prj-bd7e2 > Project settings > Android app."
  exit 1
fi

# Swap in the cookshop-dev google-services.json
cp "$GOOGLE_SERVICES" "$GOOGLE_SERVICES.bak"
cp "$COOKSHOP_GOOGLE_SERVICES" "$GOOGLE_SERVICES"

# Patch applicationId to com.cookshop.mvp (Firebase project registers this package name)
cp "$BUILD_GRADLE" "$BUILD_GRADLE.bak"
sed -i 's/applicationId "com\.shoplens\.app"/applicationId "com.cookshop.mvp"/' "$BUILD_GRADLE"

cleanup() {
  echo "Restoring original google-services.json and build.gradle..."
  cp "$GOOGLE_SERVICES.bak" "$GOOGLE_SERVICES"
  rm "$GOOGLE_SERVICES.bak"
  cp "$BUILD_GRADLE.bak" "$BUILD_GRADLE"
  rm "$BUILD_GRADLE.bak"
}
trap cleanup EXIT

cd "$MOBILE_DIR"
flutter build apk --release \
  --dart-define-from-file=.dart_define/cookshop-dev.json

echo ""
echo "APK built: build/app/outputs/flutter-apk/app-release.apk"
echo "This APK points to cookshop-dev-prj-bd7e2 / 82592393149."
