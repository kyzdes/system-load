#!/bin/bash
set -euo pipefail

#───────────────────────────────────────────────────────────
# System Load — Release Script
#
# Builds, Developer ID signs, notarizes, staples, creates a DMG, and
# Sparkle-signs the ZIP, then prints the appcast <item> for publish.sh.
#
# One-time setup:
#   1. "Developer ID Application" cert in the login Keychain.
#   2. Notarization profile — reuses the existing "CCUsageViewer" profile (a notary
#      profile is just stored Apple-account credentials; Apple notarizes per
#      developer account, not per app, so sharing one across apps is fine).
#      If it's missing, create one:
#        xcrun notarytool store-credentials "CCUsageViewer" \
#          --apple-id "kyzdes5@gmail.com" --team-id "XDQ47DMXMK" \
#          --password "<app-specific-password>"
#   3. Sparkle EdDSA key: generated via `generate_keys --account SystemLoad`.
#
# Usage: ./scripts/release.sh
#───────────────────────────────────────────────────────────

APP_NAME="SystemLoad"
TEAM_ID="XDQ47DMXMK"
SIGN_IDENTITY="Developer ID Application: Viacheslav Kuznetsov (${TEAM_ID})"
NOTARY_PROFILE="CCUsageViewer"   # shared notary creds (per-account, not per-app)
SPARKLE_ACCOUNT="SystemLoad"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
ICNS_PATH="${PROJECT_DIR}/SystemLoad/Resources/AppIcon.icns"

# Sparkle tools (from SPM DerivedData — populated after an Xcode/xcodebuild build).
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/sparkle/Sparkle/bin/sign_update" -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -1)

VERSION=$(grep "MARKETING_VERSION" "${PROJECT_DIR}/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
BUILD=$(grep "CURRENT_PROJECT_VERSION" "${PROJECT_DIR}/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')

echo "============================================"
echo "  System Load v${VERSION} (${BUILD})"
echo "============================================"

#───── Step 1: Generate project & build archive ─────
echo "[1/7] Building archive..."
( cd "$PROJECT_DIR" && xcodegen generate >/dev/null )
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    -quiet

#───── Step 2: Export the signed .app ─────
echo "[2/7] Exporting app..."
cat > "${BUILD_DIR}/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>developer-id</string>
    <key>teamID</key>            <string>${TEAM_ID}</string>
    <key>signingStyle</key>      <string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "${BUILD_DIR}/export.plist" \
    -exportPath "$BUILD_DIR" \
    -quiet

#───── Step 3: Notarize + staple the app ─────
echo "[3/7] Notarizing app..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

#───── Step 4: Create + notarize the DMG ─────
echo "[4/7] Creating DMG..."
rm -f "$DMG_PATH"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
rm -rf "$DMG_STAGING"; mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"

if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$ICNS_PATH" \
        --window-pos 200 120 \
        --window-size 500 320 \
        --icon-size 96 \
        --icon "${APP_NAME}.app" 130 150 \
        --app-drop-link 370 150 \
        --hide-extension "${APP_NAME}.app" \
        --no-internet-enable \
        "$DMG_PATH" "$DMG_STAGING"
else
    echo "  (brew install create-dmg for a styled DMG; using hdiutil)"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
fi
rm -rf "$DMG_STAGING"

codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
echo "   Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

#───── Step 5: Sign the ZIP for Sparkle ─────
echo "[5/7] Signing ZIP for Sparkle..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"   # re-zip the stapled app
[ -n "$SPARKLE_BIN" ] || { echo "ERROR: sign_update not found — build the app in Xcode first."; exit 1; }
SPARKLE_SIG=$("$SPARKLE_BIN" --account "$SPARKLE_ACCOUNT" "$ZIP_PATH")
echo "   $SPARKLE_SIG"

#───── Step 6: Artifact sizes ─────
echo "[6/7] Artifacts:"
echo "   ZIP: $(du -h "$ZIP_PATH" | cut -f1)"
echo "   DMG: $(du -h "$DMG_PATH" | cut -f1)"

#───── Step 7: Publish instructions ─────
echo ""
echo "[7/7] Publish:"
echo "   ${SCRIPT_DIR}/publish.sh ${VERSION} [--notes-file <notes.html>]"
echo ""
echo "   Appcast item (publish.sh inserts this automatically):"
# sign_update already emits length="…" — do NOT add another length attribute.
cat <<APPCAST
        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <description><![CDATA[<ul><li>What's new in v${VERSION}</li></ul>]]></description>
            <pubDate>$(date -R)</pubDate>
            <enclosure
                url="https://github.com/kyzdes/system-load/releases/download/v${VERSION}/${APP_NAME}.zip"
                type="application/octet-stream"
                ${SPARKLE_SIG}
            />
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
        </item>
APPCAST
echo ""
echo "Done."
