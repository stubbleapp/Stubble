#!/bin/bash
set -euo pipefail

# ─── Publish a Stubble update via Sparkle + GitHub Releases ────
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
#   - Build appcast.xml manually (no code signing required)
#   - Create a GitHub Release and upload both files
# ─────────────────────────────────────────────────────────────────

GITHUB_REPO="samattias/stubble-releases"

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$BUILD_DIR/build"
UPDATES_DIR="$BUILD_DIR/build/updates"
APP_BUNDLE="$OUTPUT_DIR/Stubble.app"

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
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "14.0")
TAG="v$VERSION"
echo "📦 Publishing Stubble $TAG"

# ─── Create signed zip ──────────────────────────────────────────
mkdir -p "$UPDATES_DIR"

# Clean old archives for this version
rm -f "$UPDATES_DIR/Stubble-$VERSION.zip"

ZIP_NAME="Stubble-$VERSION.zip"
ZIP_PATH="$UPDATES_DIR/$ZIP_NAME"
echo "🗜  Creating $ZIP_NAME..."
cd "$OUTPUT_DIR" && zip -r -q "$ZIP_PATH" "Stubble.app"

echo "🔏 Signing update with EdDSA..."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$ZIP_PATH" 2>&1)
echo "   $SIGN_OUTPUT"

# Parse signature and length from sign_update output
# Format: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
ZIP_LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ -z "$ED_SIGNATURE" ]; then
    echo "❌ Failed to extract EdDSA signature"
    exit 1
fi

if [ -z "$ZIP_LENGTH" ]; then
    ZIP_LENGTH=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat --printf="%s" "$ZIP_PATH")
fi

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$ZIP_NAME"
PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

# ─── Build appcast.xml manually ─────────────────────────────────
# We build it by hand because generate_appcast requires Apple code signing
# which we don't have for an unsigned app.
APPCAST_PATH="$UPDATES_DIR/appcast.xml"

echo "📡 Building appcast.xml..."

cat > "$APPCAST_PATH" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Stubble Updates</title>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 sparkle:edSignature="$ED_SIGNATURE"
                 length="$ZIP_LENGTH" />
    </item>
  </channel>
</rss>
APPCAST_EOF

echo ""
echo "── Generated files ─────────────────────────────────────────"
ls -lh "$UPDATES_DIR/$ZIP_NAME" "$APPCAST_PATH"
echo ""

# ─── Create GitHub Release ──────────────────────────────────────
echo "🚀 Creating GitHub Release $TAG..."

# Collect assets to upload
UPLOAD_ASSETS=("$ZIP_PATH" "$APPCAST_PATH")

# Include DMG if it exists (for website distribution)
# Upload both versioned (Stubble-1.3.0.dmg) and stable (Stubble.dmg) names
# so the website can use a permanent link: /latest/download/Stubble.dmg
DMG_PATH="$OUTPUT_DIR/Stubble-$VERSION.dmg"
STABLE_DMG_PATH="$OUTPUT_DIR/Stubble.dmg"
if [ -f "$DMG_PATH" ]; then
    cp "$DMG_PATH" "$STABLE_DMG_PATH"
    UPLOAD_ASSETS+=("$DMG_PATH" "$STABLE_DMG_PATH")
    echo "   Including DMG for website distribution"
fi

# Check if release already exists
if gh release view "$TAG" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "   Release $TAG already exists — uploading assets (overwriting)..."
    gh release upload "$TAG" \
        "${UPLOAD_ASSETS[@]}" \
        --repo "$GITHUB_REPO" \
        --clobber
else
    gh release create "$TAG" \
        "${UPLOAD_ASSETS[@]}" \
        --repo "$GITHUB_REPO" \
        --title "Stubble $TAG" \
        --notes "Stubble $VERSION

Download **Stubble-$VERSION.dmg** and drag to Applications.

Right-click → Open the first time to bypass Gatekeeper." \
        --latest
fi

echo ""
echo "✅ Published!"
echo ""
echo "   Release:  https://github.com/$GITHUB_REPO/releases/tag/$TAG"
echo "   Appcast:  https://github.com/$GITHUB_REPO/releases/download/$TAG/appcast.xml"
echo "   Archive:  $DOWNLOAD_URL"
if [ -f "$DMG_PATH" ]; then
echo "   DMG:      https://github.com/$GITHUB_REPO/releases/download/$TAG/Stubble-$VERSION.dmg"
echo "   DMG (stable): https://github.com/$GITHUB_REPO/releases/latest/download/Stubble.dmg"
fi
echo ""
echo "   Sparkle will find updates via SUFeedURL in Info.plist:"
echo "   https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
echo ""
