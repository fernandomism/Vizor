#!/bin/sh
# Builds build/Vizor.app. Needs only the Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
app=build/Vizor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" Sources/*.swift -o "$app/Contents/MacOS/Vizor"
cp Info.plist "$app/Contents/"
cp -R Models/IrisLandmark.mlpackage "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built $app"
