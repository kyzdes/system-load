#!/bin/bash
# Quick local build → build/SystemLoad.app (unsigned / ad-hoc).
#
# Sparkle is pulled in via Swift Package Manager, which the old raw-`swiftc`
# path can't resolve, so this now wraps `xcodebuild`. The Xcode command-line
# tools are required (they were already needed to use the project at all).
# For signed, notarized release artifacts use scripts/release.sh instead.
set -euo pipefail

APP="SystemLoad"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
DD="$BUILD/DerivedData"

command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not installed (brew install xcodegen)"; exit 1; }

echo "→ Generating project…"
( cd "$DIR" && xcodegen generate >/dev/null )

echo "→ Building (Release, unsigned)…"
xcodebuild \
    -project "$DIR/$APP.xcodeproj" \
    -scheme "$APP" \
    -configuration Release \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO \
    build -quiet

APP_SRC="$DD/Build/Products/Release/$APP.app"
rm -rf "$BUILD/$APP.app"
cp -R "$APP_SRC" "$BUILD/$APP.app"

echo "✓ Done: $BUILD/$APP.app"
echo "  Run:    open \"$BUILD/$APP.app\""
