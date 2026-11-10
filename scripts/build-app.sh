#!/bin/sh
# Builds "build/GS Status Bar.app" from the Swift package.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product GSStatusBar
bin="$(swift build -c release --show-bin-path)/GSStatusBar"

app="build/GS Status Bar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/GSStatusBar"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Ad-hoc signature so macOS will run it locally and allow notifications.
codesign --force --sign - "$app"

echo "Built $app"
