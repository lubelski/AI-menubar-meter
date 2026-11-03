#!/usr/bin/env bash
# Builds AI Meter.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use full Xcode for SwiftUI macros without changing the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AIMeter"

APP="build/AI Meter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AIMeter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Meter</string>
  <key>CFBundleDisplayName</key><string>AI Meter</string>
  <key>CFBundleIdentifier</key><string>dev.lubelski.AIMeter</string>
  <key>CFBundleExecutable</key><string>AIMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x AIMeter || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"AI Meter.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"AI Meter.app"
  echo "Installed and launched ~/Applications/AI Meter.app"
fi
