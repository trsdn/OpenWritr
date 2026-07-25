#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${RELEASE_ENV_FILE:-$PROJECT_DIR/.release.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

APP_NAME="OpenWritr"
APP_PATH="${APP_PATH:-$PROJECT_DIR/.build/release/$APP_NAME.app}"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="${DMG_PATH:-$DIST_DIR/OpenWritr-macos.dmg}"
STAGING_DIR="$PROJECT_DIR/.build/dmg-staging-$$-${RANDOM}"
REQUIRE_NOTARIZED_APP="${REQUIRE_NOTARIZED_APP:-false}"

cleanup() {
  rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  echo "Run scripts/build-app.sh first."
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ "$REQUIRE_NOTARIZED_APP" == true ]]; then
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
elif [[ "$REQUIRE_NOTARIZED_APP" != false ]]; then
  echo "REQUIRE_NOTARIZED_APP must be true or false." >&2
  exit 1
fi

rm -f -- "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$(dirname "$DMG_PATH")"
mkdir -p "$STAGING_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

identity="${CODE_SIGN_IDENTITY:-${OPENWRITR_SIGNING_IDENTITY:-}}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
fi

if [[ -z "$identity" ]]; then
  echo "No Developer ID Application identity found for DMG signing." >&2
  exit 1
fi

codesign --force --sign "$identity" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "DMG created: $DMG_PATH"
