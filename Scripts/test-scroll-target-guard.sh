#!/bin/bash
# Compile and run only the pure/in-memory long-capture target guard transaction regressions.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
SCROLL_GUARD_STAGE=$(mktemp -d /private/tmp/GaoJieTuScrollTargetGuard.XXXXXX)
trap 'rm -rf "$SCROLL_GUARD_STAGE"' EXIT
mkdir -p TestResults
SCROLL_GUARD_LOG="$PWD/TestResults/scroll-target-guard-tests.txt"
date -u '+Scroll target guard targeted CLI started: %Y-%m-%dT%H:%M:%SZ' | tee "$SCROLL_GUARD_LOG"
xcrun swiftc -Xfrontend -disable-sandbox -D SCROLL_TARGET_GUARD_TESTS -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path "$SCROLL_GUARD_STAGE/ModuleCache" \
  Sources/Capture/CaptureService.swift Sources/Capture/LongCaptureWindowCrop.swift Sources/Capture/ScrollTargetGuard.swift Sources/Capture/ScrollVisibilityPlan.swift Sources/Capture/ScrollInputPolicy.swift Sources/Capture/ScrollPixelEventBundle.swift Sources/Capture/LongScreenshotSession.swift \
  Tests/ScrollTargetGuardTests.swift -o "$SCROLL_GUARD_STAGE/ScrollTargetGuardTests" 2>&1 | tee -a "$SCROLL_GUARD_LOG"
"$SCROLL_GUARD_STAGE/ScrollTargetGuardTests" 2>&1 | tee -a "$SCROLL_GUARD_LOG"
printf 'Output: %s\n' "$SCROLL_GUARD_LOG"
