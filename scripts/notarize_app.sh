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
SUBMISSION_ROOT="${NOTARY_SUBMISSION_DIR:-$PROJECT_DIR/.build/notary-submissions}"
SUBMISSION_DIR="$SUBMISSION_ROOT/$$-${RANDOM}"
SUBMISSION_ZIP="$SUBMISSION_DIR/OpenWritr.zip"

cleanup() {
  rm -f -- "$SUBMISSION_ZIP"
  rmdir -- "$SUBMISSION_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

rm -f -- "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$(dirname "$ZIP_PATH")" "$SUBMISSION_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
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

  set +x
  xcrun notarytool submit "$SUBMISSION_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(
  cd "$(dirname "$ZIP_PATH")"
  zip_name="$(basename "$ZIP_PATH")"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"
  shasum -a 256 -c "$zip_name.sha256"
)

echo "App notarization complete: $APP_PATH"
echo "ZIP created: $ZIP_PATH"
echo "Checksum created: $ZIP_PATH.sha256"