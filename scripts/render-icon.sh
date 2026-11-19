#!/usr/bin/env bash
# Redraws the app icon's artwork, Resources/AppIcon.icon/Assets/tanks.png, from the app's
# tank drawing. Run it after changing how tanks look. bundle.sh compiles the icon itself.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build --product AIMeter >/dev/null
BIN="$(swift build --show-bin-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -swift-version 6 -o "$WORK/render-icon" \
  -I "$BIN" "$BIN/AIMeterCore.o" \
  scripts/icon/main.swift Sources/AIMeter/TankDrawing.swift
"$WORK/render-icon" Resources/AppIcon.icon/Assets/tanks.png
