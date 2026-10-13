#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
mkdir -p Release
ditto -c -k --sequesterRsrc --keepParent '.build/搞截图.app' "Release/GaoJieTu-V${VERSION}-build${BUILD}-macOS-arm64.zip"
git archive --format=zip -o "Release/GaoJieTu-V${VERSION}-Source.zip" HEAD
shasum -a 256 "Release/GaoJieTu-V${VERSION}-build${BUILD}-macOS-arm64.zip" "Release/GaoJieTu-V${VERSION}-Source.zip" > Release/SHA256SUMS.txt
