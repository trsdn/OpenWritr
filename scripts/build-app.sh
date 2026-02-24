#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP="$BUILD_DIR/OpenWritr.app"

echo "Building OpenWritr..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/OpenWritr" "$APP/Contents/MacOS/OpenWritr"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"

# Add CFBundleExecutable and CFBundleIconFile if not in Info.plist
# The app's Info.plist is used as the bundle's Info.plist with extra keys
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

echo "App bundle created at: $APP"
echo "Size: $(du -sh "$APP" | cut -f1)"
echo ""
echo "To install:  cp -R \"$APP\" /Applications/"
echo "To run:      open /Applications/OpenWritr.app"
