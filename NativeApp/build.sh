#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ModuleCache 'dist/WeeWaa Motion.app/Contents/MacOS'
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -module-cache-path .build/ModuleCache \
  NativeApp/Sources/*.swift -o 'dist/WeeWaa Motion.app/Contents/MacOS/WeeWaaMotion' \
  -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Combine
cp NativeApp/Info.plist 'dist/WeeWaa Motion.app/Contents/Info.plist'
codesign --force --sign - 'dist/WeeWaa Motion.app'
echo 'Built dist/WeeWaa Motion.app'
