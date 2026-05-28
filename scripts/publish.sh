#!/bin/bash
set -euo pipefail

#───────────────────────────────────────────────────────────
# System Load — release PUBLISH script (single repo)
#
# Takes the artifacts built by scripts/release.sh and publishes them to the
# kyzdes/system-load repo. Order matters for a single repo: push the code +
# tag FIRST, then create the GitHub Release on that tag, so the release tag
# points at the released commit and the live appcast feed (raw main) updates.
# Idempotent — safe to re-run after a partial failure.
#
# Usage:
#   scripts/publish.sh [<version>] [--notes-file <path>] [--title <str>] [--dry-run]
#     <version>     defaults to MARKETING_VERSION in project.yml
#     --notes-file  HTML <li> bullets for the appcast description + gh notes
#     --dry-run     do everything except git push / tag push / gh release / appcast write
#───────────────────────────────────────────────────────────

APP_NAME="SystemLoad"
REPO="kyzdes/system-load"
RAW_FEED="https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
SPARKLE_ACCOUNT="SystemLoad"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPCAST="${REPO_ROOT}/appcast.xml"
PROJECT_YML="${REPO_ROOT}/project.yml"
BUILD_DIR="${REPO_ROOT}/build/release"

VERSION="" ; NOTES_FILE="" ; TITLE="" ; DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --title)      TITLE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -*)           echo "Unknown option: $1" >&2; exit 2 ;;
        *)            VERSION="$1"; shift ;;
    esac
done

[ -z "$VERSION" ] && VERSION=$(grep "MARKETING_VERSION" "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
BUILD=$(grep "CURRENT_PROJECT_VERSION" "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
[ -z "$TITLE" ] && TITLE="System Load v${VERSION}"
TAG="v${VERSION}"

echo "============================================"
echo "  PUBLISH System Load ${TAG} (build ${BUILD})"
$DRY_RUN && echo "  *** DRY RUN ***"
echo "============================================"

run() { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }
top_item_version() { xmllint --xpath 'string(//item[1]/*[local-name()="shortVersionString"])' "$1" 2>/dev/null || true; }

#───── Step 1: Preflight ─────
echo "[1/6] Preflight..."
command -v gh >/dev/null      || { echo "ERROR: gh not installed"; exit 1; }
command -v xmllint >/dev/null || { echo "ERROR: xmllint not installed"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated"; exit 1; }
[ -f "$APPCAST" ] || { echo "ERROR: $APPCAST not found"; exit 1; }

ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
case "$ORIGIN_URL" in
    *kyzdes/system-load*) : ;;
    *) echo "ERROR: origin is '$ORIGIN_URL', expected kyzdes/system-load. Refusing."; exit 1 ;;
esac

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/sparkle/Sparkle/bin/sign_update" -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -1)
if [ ! -f "$ZIP_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    if $DRY_RUN; then
        SPARKLE_SIG='sparkle:edSignature="DRYRUN==" length="0"'
    else
        echo "ERROR: missing artifacts (run release.sh first): $ZIP_PATH / $DMG_PATH"; exit 1
    fi
else
    [ -n "$SPARKLE_BIN" ] || { echo "ERROR: sign_update not found"; exit 1; }
    SPARKLE_SIG=$("$SPARKLE_BIN" --account "$SPARKLE_ACCOUNT" "$ZIP_PATH")
fi

ALREADY_TOP=false
[ "$(top_item_version "$APPCAST")" = "$VERSION" ] && { ALREADY_TOP=true; echo "  appcast already tops at ${VERSION} — prepend skipped."; }
echo "  OK (origin=$ORIGIN_URL)"

#───── Step 2: Prepend appcast item + commit ─────
echo "[2/6] Updating appcast.xml..."
if $ALREADY_TOP; then
    echo "  Skipped (already top item)."
else
    if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
        NOTES_HTML=$(cat "$NOTES_FILE")
    else
        echo "  WARN: no --notes-file; using placeholder notes."
        NOTES_HTML="                    <li>Maintenance release.</li>"
    fi

    ITEM_FILE=$(mktemp)
    cat > "$ITEM_FILE" <<ITEM
        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <description>
                <![CDATA[
                <h2>System Load ${VERSION}</h2>
                <ul>
${NOTES_HTML}
                </ul>
                ]]>
            </description>
            <pubDate>$(date -R)</pubDate>
            <enclosure
                url="https://github.com/${REPO}/releases/download/${TAG}/${APP_NAME}.zip"
                type="application/octet-stream"
                ${SPARKLE_SIG}
            />
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
        </item>
ITEM

    TMP=$(mktemp)
    awk -v itemfile="$ITEM_FILE" '
        /<language>/ && !ins { print; while ((getline l < itemfile) > 0) print l; close(itemfile); ins=1; next }
        { print }
    ' "$APPCAST" > "$TMP"
    rm -f "$ITEM_FILE"
    xmllint --noout "$TMP" || { echo "ERROR: appcast not well-formed after prepend"; rm -f "$TMP"; exit 1; }

    if $DRY_RUN; then
        echo "  [dry-run] would write appcast.xml (new top: $(top_item_version "$TMP")) + commit"
        rm -f "$TMP"
    else
        mv "$TMP" "$APPCAST"
        git -C "$REPO_ROOT" add appcast.xml
        git -C "$REPO_ROOT" commit -q -m "appcast: ${VERSION}" || echo "  (nothing to commit)"
    fi
fi

#───── Step 3: Push code to main (so the live raw feed + release tag are correct) ─────
echo "[3/6] Pushing main..."
run git -C "$REPO_ROOT" push origin HEAD:main

#───── Step 4: Tag + push (release is created on this tag) ─────
echo "[4/6] Tagging ${TAG}..."
if git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  Local tag $TAG exists — ensuring it's pushed."
    run git -C "$REPO_ROOT" push origin "$TAG" || true
else
    run git -C "$REPO_ROOT" tag "$TAG"
    run git -C "$REPO_ROOT" push origin "$TAG"
fi

#───── Step 5: GitHub Release (tag already exists on the remote) ─────
echo "[5/6] GitHub Release on ${REPO}..."
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    run gh release upload "$TAG" --repo "$REPO" --clobber "$DMG_PATH" "$ZIP_PATH"
elif [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    run gh release create "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES_FILE" "$DMG_PATH" "$ZIP_PATH"
else
    run gh release create "$TAG" --repo "$REPO" --title "$TITLE" --notes "Release ${TAG}." "$DMG_PATH" "$ZIP_PATH"
fi

#───── Step 6: Verify ─────
echo "[6/6] Verifying..."
if $DRY_RUN; then
    echo "  [dry-run] skipping live checks"
else
    RAW_TOP=$(curl -fsSL "$RAW_FEED" 2>/dev/null | xmllint --xpath 'string(//item[1]/*[local-name()="shortVersionString"])' - 2>/dev/null || true)
    [ "$RAW_TOP" = "$VERSION" ] && echo "  live feed top == ${VERSION}" || echo "  WARN: live feed top is '${RAW_TOP}' (raw.githubusercontent caches ~5 min)"
    CODE=$(curl -sI -o /dev/null -w '%{http_code}' -L "https://github.com/${REPO}/releases/download/${TAG}/${APP_NAME}.zip")
    [ "$CODE" = "200" ] && echo "  release ZIP asset: HTTP 200" || echo "  WARN: ZIP asset HTTP ${CODE}"
fi

echo ""
echo "Done. ${TAG} published."
if $DRY_RUN; then echo "(dry run — nothing was actually released or pushed)"; fi
