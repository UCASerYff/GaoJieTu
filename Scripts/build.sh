#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build /private/tmp/GaoJieTuModuleCache
APP="$PWD/.build/搞截图.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache -O "${SOURCES[@]}" -o "$APP/Contents/MacOS/GaoJieTu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/GaoCapabilities.json "$APP/Contents/Resources/GaoCapabilities.json"
codesign --force --sign - --identifier com.gaoseries.GaoJieTu "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
