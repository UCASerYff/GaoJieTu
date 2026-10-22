#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build.noindex /private/tmp/GaoJieTuModuleCache
BUILD_STAGE=$(mktemp -d "$PWD/.build.noindex/GaoJieTu-build.XXXXXX")
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/搞截图.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r -d '' file; do
    case "$file" in *.swift) SOURCES+=("$file");; esac
done < <(git ls-files -z -- Sources)
if [[ ${#SOURCES[@]} -eq 0 ]]; then echo '没有受 Git 管理的 Swift 源码，停止构建。' >&2; exit 1; fi
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache -O "${SOURCES[@]}" -o "$APP/Contents/MacOS/GaoJieTu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/GaoCapabilities.json "$APP/Contents/Resources/GaoCapabilities.json"
python3 - "$APP/Contents/Resources/BuildInfo.json" <<'PY'
import json,pathlib,plistlib,subprocess,sys
info=plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
value={'schemaVersion':1,'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
       'sourceDirty':bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],text=True)),
       'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'architecture':'arm64'}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,indent=2)+'\n')
PY
codesign --force --sign - --identifier com.gaoseries.GaoJieTu "$APP"
codesign --verify --deep --strict "$APP"
DESTINATION="$PWD/.build.noindex/搞截图.app"
if [[ -L "$DESTINATION" ]]; then echo '构建目标为链接，停止替换。' >&2; exit 1; fi
rm -rf "$DESTINATION"
mv "$APP" "$DESTINATION"
echo "$DESTINATION"
