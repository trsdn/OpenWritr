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

APP_PATH="${APP_PATH:-$PROJECT_DIR/.build/release/OpenWritr.app}"
ZIP_PATH="${ZIP_PATH:-$PROJECT_DIR/dist/OpenWritr-macos.zip}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$APP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
else
  missing=()
  for variable in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!variable:-}" ]]; then
      missing+=("$variable")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Set NOTARY_PROFILE or provide APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD."
    exit 1
  fi

  xcrun notarytool submit "$APP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$(dirname "$ZIP_PATH")"

# Keep the app bundle parent directory in the archive to preserve drag-and-drop install UX.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "App notarization complete: $APP_PATH"
echo "ZIP created: $ZIP_PATH"
echo "Checksum created: $ZIP_PATH.sha256"