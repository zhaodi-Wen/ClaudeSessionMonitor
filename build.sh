#!/bin/bash
set -e

# Claude Session Monitor — One-click build script
# Usage: ./build.sh [--dmg]

APP_NAME="Claude Session Monitor"
BUNDLE_ID="com.claude.session-monitor"
VERSION="1.9.0"

echo "🔨 Building ClaudeSessionMonitor v${VERSION}..."

# Build release binary
swift build -c release

# Create .app bundle
APP_DIR="${APP_NAME}.app"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp .build/release/ClaudeSessionMonitor "${APP_DIR}/Contents/MacOS/ClaudeSessionMonitor"

# Generate Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeSessionMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

# Copy icon if exists
if [ -f "Resources/AppIcon.png" ]; then
    cp Resources/AppIcon.png "${APP_DIR}/Contents/Resources/"
fi
if [ -f "Resources/MenuBarIcon.png" ]; then
    cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "${APP_DIR}/Contents/Resources/" 2>/dev/null
fi

echo "✅ Built: ${APP_DIR}"

# Create DMG if --dmg flag passed
if [ "$1" = "--dmg" ]; then
    DMG_NAME="ClaudeSessionMonitor-${VERSION}"
    DMG_DIR="/tmp/${DMG_NAME}"
    DMG_FILE="release/${DMG_NAME}.dmg"

    echo "📦 Creating DMG..."

    mkdir -p release
    rm -rf "${DMG_DIR}" "/tmp/${DMG_NAME}.dmg"
    mkdir -p "${DMG_DIR}"
    cp -R "${APP_DIR}" "${DMG_DIR}/"
    ln -s /Applications "${DMG_DIR}/Applications"

    hdiutil create -volname "${DMG_NAME}" -srcfolder "${DMG_DIR}" -ov -format UDZO "/tmp/${DMG_NAME}.dmg"

    # Remove old DMGs and copy new one
    rm -f release/ClaudeSessionMonitor-*.dmg
    cp "/tmp/${DMG_NAME}.dmg" "${DMG_FILE}"

    echo "✅ DMG: ${DMG_FILE}"
fi

echo ""
echo "🚀 To launch: open \"${APP_DIR}\""
