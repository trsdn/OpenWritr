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

DMG_PATH="${DMG_PATH:-$PROJECT_DIR/dist/OpenWritr-macos.dmg}"
APP_PATH="${APP_PATH:-$PROJECT_DIR/.build/release/OpenWritr.app}"
ZIP_PATH="${ZIP_PATH:-$PROJECT_DIR/dist/OpenWritr-macos.zip}"
CAN_NOTARIZE=false

if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]]; then
  CAN_NOTARIZE=true
fi

"$SCRIPT_DIR/build-app.sh"

if [[ "$CAN_NOTARIZE" == true ]]; then
  APP_PATH="$APP_PATH" ZIP_PATH="$ZIP_PATH" "$SCRIPT_DIR/notarize_app.sh"
else
  echo "Skipping app notarization and ZIP packaging because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi

DMG_PATH="$DMG_PATH" "$SCRIPT_DIR/make_dmg.sh"

if [[ "$CAN_NOTARIZE" == true ]]; then
  DMG_PATH="$DMG_PATH" "$SCRIPT_DIR/notarize_dmg.sh"
else
  echo "Skipping DMG notarization because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi

echo "Release artifacts are in $PROJECT_DIR/dist/."
