#!/bin/bash
set -euo pipefail

# ─── Publish a TaskMiner update via Sparkle + GitHub Releases ────
#
# Usage:
#   ./scripts/publish-update.sh
#
# Prerequisites:
#   1. Run `generate_keys` once to create your EdDSA keypair:
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys
#      Stores the private key in your Keychain, prints the public key.
#      Put the public key in SPARKLE_ED_KEY in build-app.sh.
#
#   2. Build the app first:
#        ./scripts/build-app.sh 1.2.0
#
#   3. Have `gh` (GitHub CLI) authenticated:
#        gh auth login
#
# This script will:
#   - Create a signed .zip of the app bundle
#   - Generate the appcast.xml with Sparkle's tools
#   - Patch download URLs to point to GitHub Releases
#   - Create a GitHub Release and upload both files
# ─────────────────────────────────────────────────────────────────

GITHUB_REPO="samattias/TM"

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$BUILD_DIR/build"
UPDATES_DIR="$BUILD_DIR/build/updates"
APP_BUNDLE="$OUTPUT_DIR/TaskMiner.app"

# ─── Locate Sparkle tools ───────────────────────────────────────
SPARKLE_BIN=""
for candidate in \
    "$BUILD_DIR/.build/artifacts/sparkle/Sparkle/bin" \
    "$BUILD_DIR/.build/artifacts/Sparkle/bin" \
    "$BUILD_DIR/.build/artifacts/sparkle/bin"; do
    if [ -d "$candidate" ]; then
        SPARKLE_BIN="$candidate"
        break
    fi
done

if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Run 'swift build' first to download the Sparkle package."
    exit 1
fi

SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"

# ─── Verify prerequisites ───────────────────────────────────────
if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    echo "❌ App bundle not found. Run ./scripts/build-app.sh <version> first."
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI (gh) not found. Install it: brew install gh"
    exit 1
fi

# ─── Read version from built app ────────────────────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
TAG="v$VERSION"
echo "📦 Publishing TaskMiner $TAG"

# ─── Create signed zip ──────────────────────────────────────────
mkdir -p "$UPDATES_DIR"

# Clean old archives for this version
rm -f "$UPDATES_DIR/TaskMiner-$VERSION.zip"

ZIP_NAME="TaskMiner-$VERSION.zip"
ZIP_PATH="$UPDATES_DIR/$ZIP_NAME"
echo "🗜  Creating $ZIP_NAME..."
cd "$OUTPUT_DIR" && zip -r -q "$ZIP_PATH" "TaskMiner.app"

echo "🔏 Signing update with EdDSA..."
SIGNATURE=$("$SIGN_UPDATE" "$ZIP_PATH" 2>&1)
echo "   $SIGNATURE"

# ─── Generate appcast ───────────────────────────────────────────
# Sparkle's generate_appcast reads all zips in the folder and builds the XML.
# We need to tell it the download URL prefix so links point to GitHub Releases.
DOWNLOAD_URL_PREFIX="https://github.com/$GITHUB_REPO/releases/download/$TAG"

echo "📡 Generating appcast.xml..."
"$GENERATE_APPCAST" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX/" \
    "$UPDATES_DIR"

APPCAST_PATH="$UPDATES_DIR/appcast.xml"
if [ ! -f "$APPCAST_PATH" ]; then
    echo "❌ appcast.xml was not generated"
    exit 1
fi

echo ""
echo "── Generated files ─────────────────────────────────────────"
ls -lh "$UPDATES_DIR/$ZIP_NAME" "$APPCAST_PATH"
echo ""

# ─── Create GitHub Release ──────────────────────────────────────
echo "🚀 Creating GitHub Release $TAG..."

# Check if release already exists
if gh release view "$TAG" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "   Release $TAG already exists — uploading assets (overwriting)..."
    gh release upload "$TAG" \
        "$ZIP_PATH" \
        "$APPCAST_PATH" \
        --repo "$GITHUB_REPO" \
        --clobber
else
    gh release create "$TAG" \
        "$ZIP_PATH" \
        "$APPCAST_PATH" \
        --repo "$GITHUB_REPO" \
        --title "TaskMiner $TAG" \
        --notes "TaskMiner $VERSION

Download **$ZIP_NAME**, unzip, and drag to Applications.

Right-click → Open the first time to bypass Gatekeeper." \
        --latest
fi

echo ""
echo "✅ Published!"
echo ""
echo "   Release: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
echo "   Appcast: https://github.com/$GITHUB_REPO/releases/download/$TAG/appcast.xml"
echo "   Archive: https://github.com/$GITHUB_REPO/releases/download/$TAG/$ZIP_NAME"
echo ""
echo "   Sparkle will find updates via SUFeedURL in Info.plist:"
echo "   https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
echo ""
