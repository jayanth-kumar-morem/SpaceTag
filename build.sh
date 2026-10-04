#!/bin/bash
# Builds SpaceTag.app with swiftc only -- no Xcode required.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/SpaceTag.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf build
mkdir -p "$MACOS" "$RES"

echo "==> Compiling"
# main.swift must come last: swiftc requires top-level code in a file named
# main.swift, and ordering keeps the driver from treating others as entry points.
swiftc \
  -O \
  -target arm64-apple-macosx14.4 \
  -framework Cocoa \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$MACOS/SpaceTag" \
  Sources/SkyLight.swift \
  Sources/SpaceModel.swift \
  Sources/NameStore.swift \
  Sources/Hotkey.swift \
  Sources/MissionControlAX.swift \
  Sources/MissionControlOverlay.swift \
  Sources/RenamePanel.swift \
  Sources/AppDelegate.swift \
  Sources/main.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
# Ad-hoc signature gives the bundle a stable identity so macOS keeps the
# login-item registration and does not re-prompt on every launch.
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
