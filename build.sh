#!/bin/sh
# Builds loom-mac-screen and wraps it as build/LoomMacScreen.app, signed with
# this Mac's Apple Development identity. A stable signature is what lets macOS
# keep its Screen Recording and Accessibility grants across rebuilds, on this
# Mac and on any Mac the app is copied to. Run from this directory.
set -eu

label=cloud.loom.mac-screen
out=build/LoomMacScreen.app
identity=${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "no Apple Development identity in the keychain" >&2; exit 1; }

swift build -c release
bin=$(swift build -c release --show-bin-path)/loom-mac-screen

rm -rf "$out"
mkdir -p "$out/Contents/MacOS"
cp "$bin" "$out/Contents/MacOS/loom-mac-screen"
cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>LoomMacScreen</string>
  <key>CFBundleExecutable</key><string>loom-mac-screen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign "$identity" "$out"
echo "built $out ($(codesign -dvv "$out" 2>&1 | sed -n 's/^Authority=//p' | head -1))"
