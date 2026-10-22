#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if test -n "$(git status --porcelain --untracked-files=all)"; then echo '发布前须提交全部审核源码，禁止源码包与程序不一致。' >&2; exit 1; fi
Scripts/build.sh
if test -n "$(git status --porcelain --untracked-files=all)"; then echo '构建期间源码发生变化，停止发行。' >&2; exit 1; fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
mkdir -p Release
ditto --norsrc --noextattr --noqtn -c -k --keepParent '.build.noindex/搞截图.app' "Release/GaoJieTu-V${VERSION}-build${BUILD}-macOS-arm64.zip"
git archive --format=zip -o "Release/GaoJieTu-V${VERSION}-Source.zip" HEAD
shasum -a 256 "Release/GaoJieTu-V${VERSION}-build${BUILD}-macOS-arm64.zip" "Release/GaoJieTu-V${VERSION}-Source.zip" > Release/SHA256SUMS.txt
python3 Scripts/verify_release.py --app-zip "Release/GaoJieTu-V${VERSION}-build${BUILD}-macOS-arm64.zip" --source-zip "Release/GaoJieTu-V${VERSION}-Source.zip" --checksums Release/SHA256SUMS.txt
