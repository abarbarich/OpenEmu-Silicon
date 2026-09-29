#!/bin/bash
# build-viewer.sh — PROTOTYPE: build "OpenEmu Stream Viewer.app" (the stream-play guest) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/OpenEmu Stream Viewer.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos11.3 StreamViewer.swift -o "$APP/Contents/MacOS/StreamViewer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>StreamViewer</string>
  <key>CFBundleIdentifier</key><string>org.openemu.StreamViewer</string>
  <key>CFBundleName</key><string>OpenEmu Stream Viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.3</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Connects to the Mac running the game.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built: $(pwd)/$APP"
