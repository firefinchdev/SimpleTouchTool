#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SimpleTouchTool.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

swiftc -O -swift-version 5 \
    -import-objc-header Sources/Bridge.h \
    Sources/main.swift \
    -o "$APP/Contents/MacOS/SimpleTouchTool"

codesign --force --sign - --identifier com.firefinchdev.SimpleTouchTool "$APP"
echo "Built $APP"
