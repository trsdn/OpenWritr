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

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [v]VERSION" >&2
  exit 1
fi

version_input="${1:-${RELEASE_VERSION:-}}"
if [[ -z "$version_input" ]]; then
  version_input="$(git -C "$PROJECT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
fi
if [[ -z "$version_input" ]]; then
  version_input="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
fi

version="${version_input#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release version: $version_input" >&2
  echo "Usage: $0 [v]VERSION" >&2
  exit 1
fi

DIST_DIR="$PROJECT_DIR/dist"
ASSET_BASE="$DIST_DIR/OpenWritr-v${version}-macOS-arm64"
DMG_PATH="$ASSET_BASE.dmg"
APP_PATH="${APP_PATH:-$PROJECT_DIR/.build/release/OpenWritr.app}"
ZIP_PATH="$ASSET_BASE.zip"
CAN_NOTARIZE=false

if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]]; then
  CAN_NOTARIZE=true
fi

mkdir -p "$DIST_DIR"
rm -f -- "$ZIP_PATH" "$ZIP_PATH.sha256" "$DMG_PATH" "$DMG_PATH.sha256"

"$SCRIPT_DIR/build-app.sh"

if [[ "$CAN_NOTARIZE" == true ]]; then
  APP_PATH="$APP_PATH" ZIP_PATH="$ZIP_PATH" "$SCRIPT_DIR/notarize_app.sh"
else
  echo "Skipping app notarization and ZIP packaging because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi

APP_PATH="$APP_PATH" DMG_PATH="$DMG_PATH" REQUIRE_NOTARIZED_APP="$CAN_NOTARIZE" "$SCRIPT_DIR/make_dmg.sh"

if [[ "$CAN_NOTARIZE" == true ]]; then
  DMG_PATH="$DMG_PATH" "$SCRIPT_DIR/notarize_dmg.sh"
else
  echo "Skipping DMG notarization because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
  (
    cd "$DIST_DIR"
    dmg_name="$(basename "$DMG_PATH")"
    shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
    shasum -a 256 -c "$dmg_name.sha256"
  )
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
hdiutil verify "$DMG_PATH"

expected_artifacts=("$DMG_PATH" "$DMG_PATH.sha256")
if [[ "$CAN_NOTARIZE" == true ]]; then
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  expected_artifacts+=("$ZIP_PATH" "$ZIP_PATH.sha256")
fi

for artifact in "${expected_artifacts[@]}"; do
  if [[ ! -f "$artifact" ]]; then
    echo "Expected release artifact is missing: $artifact" >&2
    exit 1
  fi
done

(
  cd "$DIST_DIR"
  shasum -a 256 -c "$(basename "$DMG_PATH").sha256"
  if [[ "$CAN_NOTARIZE" == true ]]; then
    shasum -a 256 -c "$(basename "$ZIP_PATH").sha256"
  fi
)

echo "Release artifacts for v${version} are in $DIST_DIR/."
