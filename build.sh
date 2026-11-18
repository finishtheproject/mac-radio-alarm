#!/bin/zsh
# Builds RadioAlarm.app and installs it to /Applications.
# The app is built in a temporary folder (deleted afterwards), so the only copy is the one in /Applications.
set -e
cd "$(dirname "$0")"
NAME=RadioAlarm.app
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/$NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon (from AlarmIcon.png)
swift make_icon.swift
iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf AppIcon.iconset

swiftc -O -parse-as-library -target arm64-apple-macosx14.0 RadioAlarm.swift -o "$APP/Contents/MacOS/RadioAlarm"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Radio Alarm</string>
  <key>CFBundleDisplayName</key><string>Radio Alarm</string>
  <key>CFBundleIdentifier</key><string>local.radioalarm</string>
  <key>CFBundleExecutable</key><string>RadioAlarm</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><false/>
  <!-- Many radio streams are plain http -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $NAME"

# Install to /Applications — that copy is the one that opens at login.
# (pkill rather than a normal quit, which would stop at the "Quit Radio Alarm?" question)
pkill -x RadioAlarm || true
while pgrep -x RadioAlarm >/dev/null; do sleep 0.2; done
rm -rf "/Applications/$NAME"
ditto "$APP" "/Applications/$NAME"
echo "Installed /Applications/$NAME"
