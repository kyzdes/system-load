#!/bin/bash
# Fast CLI build without Xcode — compiles SystemLoad.app with swiftc.
# (For development use the Xcode project: open SystemLoad.xcodeproj.)
set -euo pipefail

APP="SystemLoad"
BUNDLE_ID="com.vkuznetsov.systemload"
DISPLAY="System Load"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
CONTENTS="$BUILD/$APP.app/Contents"

rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "→ Compiling…"
swiftc -O -whole-module-optimization \
    -o "$CONTENTS/MacOS/$APP" \
    "$DIR/SystemLoad/main.swift" \
    -framework AppKit

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY</string>
    <key>CFBundleExecutable</key>      <string>$APP</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "→ Ad-hoc signing…"
codesign --force --sign - "$BUILD/$APP.app" >/dev/null 2>&1 || echo "  (signing skipped)"

echo "✓ Done: $BUILD/$APP.app"
echo "  Run:    open \"$BUILD/$APP.app\""
