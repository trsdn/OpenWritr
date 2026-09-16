#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${RELEASE_ENV_FILE:-$PROJECT_DIR/.release.env}"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP="$BUILD_DIR/OpenWritr.app"
DEFAULT_BUNDLE_ID="com.openwritr.app"
PREFERRED_IDENTITY="${OPENWRITR_SIGNING_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    . "$ENV_FILE"
    set +a
    PREFERRED_IDENTITY="${OPENWRITR_SIGNING_IDENTITY:-${CODE_SIGN_IDENTITY:-$PREFERRED_IDENTITY}}"
fi

find_signing_identity() {
    if [[ -n "$PREFERRED_IDENTITY" ]]; then
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -v preferred="$PREFERRED_IDENTITY" '
                $2 == preferred || index($0, preferred) { print $2; found = 1; exit }
                END { if (!found) exit 1 }
            '
        return
    fi

    security find-identity -v -p codesigning 2>/dev/null \
        | awk '
            /Developer ID Application:/ { print $2; exit }
            /Apple Development:/ && !apple_dev { apple_dev = $2 }
            END {
                if (apple_dev) {
                    print apple_dev
                } else {
                    exit 1
                }
            }
        '
}

SIGNING_IDENTITY="$(find_signing_identity || true)"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No valid macOS codesigning identity found." >&2
    echo "Install a Developer ID Application or Apple Development certificate, or set OPENWRITR_SIGNING_IDENTITY to a valid fingerprint." >&2
    exit 1
fi

echo "Building OpenWritr..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/OpenWritr" "$APP/Contents/MacOS/OpenWritr"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Sources/OpenWritr/Resources/cleanup-prompt-profiles.json" \
    "$APP/Contents/Resources/cleanup-prompt-profiles.json"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"

# AppUpdater ships its Sigstore/TUF trust roots as a SwiftPM resource bundle;
# it must be present in Contents/Resources for in-app update checks to work.
APP_UPDATER_BUNDLE="$BUILD_DIR/AppUpdater_AppUpdater.bundle"
if [[ -d "$APP_UPDATER_BUNDLE" ]]; then
    cp -R "$APP_UPDATER_BUNDLE" "$APP/Contents/Resources/AppUpdater_AppUpdater.bundle"
else
    echo "Warning: AppUpdater_AppUpdater.bundle not found at $APP_UPDATER_BUNDLE; in-app updates will not work." >&2
fi

python3 -c "
import plistlib, sys
with open('$APP/Contents/Info.plist', 'rb') as f:
    p = plistlib.load(f)
p['CFBundleExecutable'] = 'OpenWritr'
p['CFBundleIconFile'] = 'AppIcon'
p['CFBundlePackageType'] = 'APPL'
p['CFBundleDisplayName'] = 'OpenWritr'
p['NSHighResolutionCapable'] = True
p['LSMinimumSystemVersion'] = '14.0'
with open('$APP/Contents/Info.plist', 'wb') as f:
    plistlib.dump(p, f)
"

# Sign with a stable, trusted identity so TCC permissions survive rebuilds.
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --identifier "$DEFAULT_BUNDLE_ID" \
    --entitlements "$PROJECT_DIR/OpenWritr.entitlements" \
    "$APP"

SIGNATURE_DETAILS=$(codesign -dv "$APP" 2>&1)
if echo "$SIGNATURE_DETAILS" | grep -qi 'Signature=adhoc'; then
    echo "codesign produced an ad-hoc signature; aborting so macOS permissions do not reset." >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "App bundle created at: $APP"
echo "Signed with identity: $SIGNING_IDENTITY"
echo "Size: $(du -sh "$APP" | cut -f1)"
echo ""
echo "To install:  cp -R \"$APP\" /Applications/"
echo "To run:      open /Applications/OpenWritr.app"
