#!/bin/bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
APP_NAME="TaskMiner"
BUNDLE_ID="com.samattias.taskminer"
VERSION="1.0.0"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$BUILD_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME (both dashboard + daemon)..."
cd "$BUILD_DIR"

# Build both products in release mode
swift build -c release 2>&1

DASHBOARD_BINARY="$BUILD_DIR/.build/release/TaskMinerDashboard"
DAEMON_BINARY="$BUILD_DIR/.build/release/TaskMiner"

if [ ! -f "$DASHBOARD_BINARY" ]; then
    echo "❌ Dashboard build failed — binary not found"
    exit 1
fi
if [ ! -f "$DAEMON_BINARY" ]; then
    echo "❌ Daemon build failed — binary not found"
    exit 1
fi

echo "📦 Creating $APP_NAME.app bundle..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create .app directory structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy both binaries
cp "$DASHBOARD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$DAEMON_BINARY" "$APP_BUNDLE/Contents/MacOS/TaskMinerDaemon"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>TaskMiner needs to observe which apps you use to track your activity.</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "✅ Built: $APP_BUNDLE"
echo "   Dashboard: $(du -sh "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1)"
echo "   Daemon:    $(du -sh "$APP_BUNDLE/Contents/MacOS/TaskMinerDaemon" | cut -f1)"
echo "   Total:     $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "To share: zip it —"
echo "   cd $OUTPUT_DIR && zip -r $APP_NAME.zip $APP_NAME.app"
echo ""
echo "⚠️  Note: Your friend will need to:"
echo "   1. Right-click → Open the first time (Gatekeeper)"
echo "   2. Grant Accessibility permission (System Settings → Privacy → Accessibility)"
echo "   3. Grant Screen Recording permission (System Settings → Privacy → Screen Recording)"
echo "   4. Set their Gemini API key in Settings"
