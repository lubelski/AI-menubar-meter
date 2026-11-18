#!/usr/bin/env bash
# Builds AI Meter.app into ./build. Pass --install to copy it to ~/Applications and launch it.
#
# Environment, all optional:
#   AIMETER_VERSION     The version to show, such as 1.2.0. Defaults to the latest v* tag.
#   AIMETER_FEED_URL    The Sparkle feed. Set by scripts/release.sh, together with
#   AIMETER_PUBLIC_KEY  the public key that updates are signed with. A build without
#                       these two never updates itself.
#   CODESIGN_IDENTITY   The signing identity. Defaults to a Developer ID Application
#                       certificate in the Keychain, or an ad-hoc signature without one.
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/AIMeter"

# Sparkle, the updater. SwiftPM builds it next to the binary but doesn't know about
# app bundles, so copy it in and tell the binary where to find it.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/AIMeter"

# Record the SDK that the app was compiled against. SwiftPM's default build engine
# writes the deployment target (15.0) into the SDK field of the binary instead. macOS
# reads that field to choose between its current behavior and a compatibility mode for
# older apps, and the menu bar panel does not resize correctly in the compatibility mode.
# See docs/investigations/2026-11-09-panel-glass-bands.md.
MIN_OS=15.0
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/AIMeter" "$APP/Contents/MacOS/AIMeter"
STAMPED="$(xcrun vtool -show-build "$APP/Contents/MacOS/AIMeter" | awk '$1 == "sdk" { print $2 }')"
if [[ "$STAMPED" != "$SDK_VERSION" ]]; then
  echo "error: the binary is stamped with SDK '$STAMPED', expected '$SDK_VERSION'" >&2
  exit 1
fi

# Record the commit the app was built from, so the About tab can identify the build.
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi

# The version comes from the latest release tag. The build number is the number of
# commits, which only grows on main; Sparkle compares build numbers to find a newer build.
LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${AIMETER_VERSION:-${LATEST_TAG#v}}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

UPDATER_KEYS=""
if [[ -n "${AIMETER_FEED_URL:-}" && -n "${AIMETER_PUBLIC_KEY:-}" ]]; then
  UPDATER_KEYS="<key>SUFeedURL</key><string>$AIMETER_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$AIMETER_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
fi

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>AIMeterGitCommit</key><string>$GIT_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $UPDATER_KEYS
</dict>
</plist>
PLIST

# Sign with a Developer ID when the Keychain has one, so macOS on another Mac opens the
# app and the Keychain keeps trusting it from one build to the next. Otherwise sign ad hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  SIGN+=(--options runtime --timestamp)
fi

# Sparkle's helpers are signed one at a time, innermost first, as its documentation says.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP, version $VERSION ($BUILD_NUMBER), signed with: $IDENTITY"

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
