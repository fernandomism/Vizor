#!/bin/sh
# Builds build/Vizor.app. Needs only the Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
app=build/Vizor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Universal binary, so the same app runs on Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" Sources/*.swift -o "build/Vizor-$arch"
done
lipo -create build/Vizor-arm64 build/Vizor-x86_64 -output "$app/Contents/MacOS/Vizor"
cp Info.plist "$app/Contents/"
cp -R Models/IrisLandmark.mlpackage "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built $app"
