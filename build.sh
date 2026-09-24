#!/bin/zsh
# Builds "Bird Game.app" next to this script (universal: Apple Silicon + Intel).
# The version shown in the app comes from Info.plist (CFBundleShortVersionString).
set -e
cd "$(dirname "$0")"
APP="Bird Game.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 \
    -framework AppKit -framework SceneKit -framework AVFoundation -framework Vision -framework CoreMedia \
    Sources/*.swift -o "$TMP/BirdGame-$ARCH"
done
lipo -create "$TMP"/BirdGame-* -output "$APP/Contents/MacOS/BirdGame"
cp Info.plist "$APP/Contents/Info.plist"
# App icon (Icon Composer file) -> Assets.car + AppIcon.icns
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$TMP/icon.plist" >/dev/null
# World screenshots for the shop (regenerate with: BirdGame --world-shots Resources/worlds)
cp -R Resources/worlds "$APP/Contents/Resources/worlds"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $PWD/$APP (version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist))"
