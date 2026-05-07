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

"$SCRIPT_DIR/build-app.sh"
DMG_PATH="$DMG_PATH" "$SCRIPT_DIR/make_dmg.sh"

if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]]; then
  DMG_PATH="$DMG_PATH" "$SCRIPT_DIR/notarize_dmg.sh"
else
  echo "Skipping notarization because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi

echo "Release artifacts are in $PROJECT_DIR/dist/."
