#!/bin/zsh
# release build，包成 build/SimPilot.app（選單列 app），CLI 放在 build/simpilot。
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=$ROOT/build/SimPilot.app
mkdir -p $APP/Contents/MacOS
cp $BIN/SimPilotMenuBar $APP/Contents/MacOS/SimPilot
cp $BIN/simpilot $ROOT/build/simpilot
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.peter6601.SimPilot</string>
  <key>CFBundleName</key><string>SimPilot</string>
  <key>CFBundleExecutable</key><string>SimPilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP >/dev/null
echo "OK $APP"
echo "OK $ROOT/build/simpilot"
