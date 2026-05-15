#!/usr/bin/env bash
set -euo pipefail

# Build the Stubble MCPB extension for Claude Desktop
# This creates a .mcpb file that users can double-click to install

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$PROJECT_DIR/build"
MCPB_DIR="$BUILD_DIR/mcpb-staging"
MCPB_RESOURCES="$PROJECT_DIR/Resources/MCPB"
OUTPUT_FILE="$BUILD_DIR/Stubble.mcpb"

# Get version from built app or default
if [ -f "$BUILD_DIR/Stubble.app/Contents/Info.plist" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILD_DIR/Stubble.app/Contents/Info.plist")
else
    VERSION="1.0.0"
fi

echo "📦 Building Stubble.mcpb v$VERSION"

# Ensure stubble-mcp binary exists
STUBBLE_MCP="$BUILD_DIR/Stubble.app/Contents/MacOS/stubble-mcp"
if [ ! -f "$STUBBLE_MCP" ]; then
    echo "❌ Error: stubble-mcp binary not found at $STUBBLE_MCP"
    echo "   Run 'bash scripts/build-app.sh' first"
    exit 1
fi

# Clean and create staging directory
rm -rf "$MCPB_DIR"
mkdir -p "$MCPB_DIR"

# Copy manifest and update version
cp "$MCPB_RESOURCES/manifest.json" "$MCPB_DIR/"
# Update version in manifest
if command -v jq &> /dev/null; then
    jq --arg v "$VERSION" '.version = $v' "$MCPB_DIR/manifest.json" > "$MCPB_DIR/manifest.tmp" && mv "$MCPB_DIR/manifest.tmp" "$MCPB_DIR/manifest.json"
else
    # Fallback: use sed if jq not available
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$MCPB_DIR/manifest.json"
fi

# Copy icons
cp "$MCPB_RESOURCES/icon.png" "$MCPB_DIR/"
cp "$MCPB_RESOURCES/icon-32.png" "$MCPB_DIR/"
cp "$MCPB_RESOURCES/icon-128.png" "$MCPB_DIR/"
cp "$MCPB_RESOURCES/icon-512.png" "$MCPB_DIR/"

# Copy the stubble-mcp binary
cp "$STUBBLE_MCP" "$MCPB_DIR/stubble-mcp"
chmod +x "$MCPB_DIR/stubble-mcp"

# Create the .mcpb file (it's just a ZIP archive)
rm -f "$OUTPUT_FILE"
cd "$MCPB_DIR"
zip -r "$OUTPUT_FILE" . -x "*.DS_Store"

# Cleanup
rm -rf "$MCPB_DIR"

# Show result
echo "✅ Created: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"

echo ""
echo "── Installation ────────────────────────────────────────"
echo "   Users can double-click the .mcpb file to install in Claude Desktop"
echo "   Or: Settings > Extensions > Advanced > Install Extension..."
