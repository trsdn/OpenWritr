#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP="$BUILD_DIR/OpenWritr.app"

# ── Signing keychain (persistent, lives in .build/) ──
KC="$PROJECT_DIR/.build/signing.keychain-db"
KC_PASS="openwritr"
CERT_NAME="OpenWritr Dev"

if ! security find-certificate -c "$CERT_NAME" "$KC" > /dev/null 2>&1; then
    echo "Creating signing keychain + certificate..."
    security delete-keychain "$KC" 2>/dev/null || true
    security create-keychain -p "$KC_PASS" "$KC"
    TMPD=$(mktemp -d)
    cat > "$TMPD/cert.cfg" <<'CERTEOF'
[ req ]
default_bits = 2048
distinguished_name = dn
x509_extensions = codesign
prompt = no
[ dn ]
CN = OpenWritr Dev
[ codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CERTEOF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" \
        -days 3650 -config "$TMPD/cert.cfg" 2>/dev/null
    openssl pkcs12 -export -out "$TMPD/cert.p12" \
        -inkey "$TMPD/key.pem" -in "$TMPD/cert.pem" \
        -passout pass:temp -legacy 2>/dev/null
    security unlock-keychain -p "$KC_PASS" "$KC"
    security import "$TMPD/cert.p12" -k "$KC" -T /usr/bin/codesign -P "temp"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC"
    rm -rf "$TMPD"
    echo "Certificate '$CERT_NAME' created."
fi

# Ensure keychain is unlocked and in search list
security unlock-keychain -p "$KC_PASS" "$KC"
EXISTING=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
if ! echo "$EXISTING" | grep -q "signing.keychain-db"; then
    security list-keychains -d user -s $EXISTING "$KC"
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

# Sign with persistent certificate from project keychain
codesign --force --sign "$CERT_NAME" --keychain "$KC" \
    --identifier com.openwritr.app \
    --entitlements "$PROJECT_DIR/OpenWritr.entitlements" \
    "$APP"

echo "App bundle created at: $APP"
echo "Signed with: $CERT_NAME"
echo "Size: $(du -sh "$APP" | cut -f1)"
echo ""
echo "To install:  cp -R \"$APP\" /Applications/"
echo "To run:      open /Applications/OpenWritr.app"
