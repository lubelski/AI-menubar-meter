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
  DEST=~/Applications/"AI Meter.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

  # Stop the running copy and wait until it has exited. Otherwise the old process can
  # still own the menu bar item when the new one registers its own.
  if pkill -x AIMeter; then
    for _ in {1..50}; do
      pgrep -x AIMeter >/dev/null || break
      sleep 0.1
    done
    pkill -9 -x AIMeter || true
  fi

  mkdir -p ~/Applications
  rm -rf "$DEST"
  # Move the bundle instead of copying it. A second bundle with the same bundle
  # identifier lets LaunchServices and the login item resolve to either one.
  mv "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
