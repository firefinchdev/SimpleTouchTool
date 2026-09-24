#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) build/SimpleTouchTool.app
# and a zipped copy for releases at build/SimpleTouchTool.zip.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SimpleTouchTool.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 \
        -target "$arch-apple-macos13.0" \
        -import-objc-header Sources/Bridge.h \
        Sources/main.swift \
        -o "build/SimpleTouchTool-$arch"
done
lipo -create build/SimpleTouchTool-arm64 build/SimpleTouchTool-x86_64 \
    -output "$APP/Contents/MacOS/SimpleTouchTool"
rm build/SimpleTouchTool-arm64 build/SimpleTouchTool-x86_64

codesign --force --sign - --identifier com.firefinchdev.SimpleTouchTool "$APP"
ditto -c -k --keepParent "$APP" build/SimpleTouchTool.zip
echo "Built $APP and build/SimpleTouchTool.zip"
