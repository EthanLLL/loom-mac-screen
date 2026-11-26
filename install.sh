#!/bin/sh
# Puts LoomMacScreen.app in ~/Applications and has launchd start it whenever
# something connects to 127.0.0.1:5960. With no argument it builds the app
# first (./build.sh); given an app built on another Mac, it installs that one
# and needs no Xcode. Again after a change.
set -eu

label=cloud.loom.mac-screen
app="$HOME/Applications/LoomMacScreen.app"
plist="$HOME/Library/LaunchAgents/$label.plist"

if [ $# -eq 0 ]; then
  ./build.sh
  set -- build/LoomMacScreen.app
fi
codesign --verify --strict "$1"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$app"
ditto "$1" "$app"

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
echo "installed $app ($(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)); listening on 127.0.0.1:5960"
