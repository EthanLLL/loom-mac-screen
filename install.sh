#!/bin/sh
# Builds loom-mac-screen, wraps it as LoomMacScreen.app signed with this Mac's
# Apple Development identity (a stable signature is what lets macOS keep its
# Screen Recording and Accessibility grants across rebuilds), puts it in
# ~/Applications, and has launchd start it whenever something connects to
# 127.0.0.1:5960. Run on the Mac, from this directory. Again after a change.
set -eu

label=cloud.loom.mac-screen
app="$HOME/Applications/LoomMacScreen.app"
plist="$HOME/Library/LaunchAgents/$label.plist"
identity=${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "no Apple Development identity in the keychain" >&2; exit 1; }

swift build -c release
bin=$(swift build -c release --show-bin-path)/loom-mac-screen

stage=$(mktemp -d)
mkdir -p "$stage/LoomMacScreen.app/Contents/MacOS"
cp "$bin" "$stage/LoomMacScreen.app/Contents/MacOS/loom-mac-screen"
cat > "$stage/LoomMacScreen.app/Contents/Info.plist" <<PLIST
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
codesign --force --options runtime --sign "$identity" "$stage/LoomMacScreen.app"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$app"
mv "$stage/LoomMacScreen.app" "$app"
rmdir "$stage"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/loom-mac-screen</string></array>
  <key>Sockets</key><dict>
    <key>Listeners</key><dict>
      <key>SockNodeName</key><string>127.0.0.1</string>
      <key>SockServiceName</key><string>5960</string>
      <key>SockType</key><string>stream</string>
      <key>SockFamily</key><string>IPv4</string>
    </dict>
  </dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/loom-mac-screen.log</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed $app ($(codesign -dv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)); listening on 127.0.0.1:5960"
