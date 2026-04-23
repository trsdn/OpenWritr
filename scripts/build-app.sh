#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP="$BUILD_DIR/OpenWritr.app"
DEFAULT_BUNDLE_ID="com.openwritr.app"
PREFERRED_IDENTITY="${OPENWRITR_SIGNING_IDENTITY:-}"

find_signing_identity() {
    if [[ -n "$PREFERRED_IDENTITY" ]]; then
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -v fingerprint="$PREFERRED_IDENTITY" '$2 == fingerprint { print $2; found = 1; exit } END { if (!found) exit 1 }'
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
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"

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
    --identifier "$DEFAULT_BUNDLE_ID" \
    --entitlements "$PROJECT_DIR/OpenWritr.entitlements" \
    "$APP"

SIGNATURE_DETAILS=$(codesign -dv "$APP" 2>&1)
if echo "$SIGNATURE_DETAILS" | grep -qi 'Signature=adhoc'; then
    echo "codesign produced an ad-hoc signature; aborting so macOS permissions do not reset." >&2
    exit 1
fi

echo "App bundle created at: $APP"
echo "Signed with identity: $SIGNING_IDENTITY"
echo "Size: $(du -sh "$APP" | cut -f1)"
echo ""
echo "To install:  cp -R \"$APP\" /Applications/"
echo "To run:      open /Applications/OpenWritr.app"
