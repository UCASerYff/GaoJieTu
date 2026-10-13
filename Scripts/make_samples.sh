#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p TestResults/Acceptance /private/tmp/GaoJieTuModuleCache
xcrun swift -module-cache-path /private/tmp/GaoJieTuModuleCache Scripts/MakeAcceptanceSamples.swift
SAMPLE_APP="TestResults/Acceptance/AcceptanceSample.app"
mkdir -p "$SAMPLE_APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache Scripts/AcceptanceSampleHost.swift -o "$SAMPLE_APP/Contents/MacOS/AcceptanceSample"
cat > "$SAMPLE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gaoseries.GaoJieTu.AcceptanceSample</string>
<key>CFBundleName</key><string>搞截图自建验收样本</string><key>CFBundleDisplayName</key><string>搞截图自建验收样本</string>
<key>CFBundleExecutable</key><string>AcceptanceSample</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
chmod 700 "$SAMPLE_APP/Contents/MacOS/AcceptanceSample"
/usr/bin/codesign --force --sign - "$SAMPLE_APP"
/usr/bin/codesign --verify --strict "$SAMPLE_APP"
echo 'Prepared AcceptanceSample.app without launching, installing or registering it.'
