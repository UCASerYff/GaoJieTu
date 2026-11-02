#!/bin/bash
# Pure CLI checks for the production preparation pipeline and cancellation owner.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
LONG_CANCEL_STAGE=$(mktemp -d /private/tmp/GaoJieTuLongCancellation.XXXXXX)
trap 'rm -rf "$LONG_CANCEL_STAGE"' EXIT
mkdir -p TestResults
LONG_CANCEL_LOG="$PWD/TestResults/long-capture-cancellation-tests.txt"
date -u '+Long capture cancellation focused CLI started: %Y-%m-%dT%H:%M:%SZ' | tee "$LONG_CANCEL_LOG"
xcrun swiftc -Xfrontend -disable-sandbox -D LONG_CAPTURE_CANCELLATION_TESTS -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path "$LONG_CANCEL_STAGE/ModuleCache" \
  Sources/Capture/CaptureService.swift Sources/Capture/LongCaptureWindowCrop.swift Sources/Capture/ScrollTargetGuard.swift \
  Sources/Capture/ScrollVisibilityPlan.swift Sources/Capture/ScrollInputPolicy.swift Sources/Capture/ScrollPixelEventBundle.swift \
  Sources/Capture/LongScreenshotSession.swift Sources/Capture/LongCaptureOperation.swift \
  Tests/LongCaptureCancellationTests.swift -o "$LONG_CANCEL_STAGE/LongCaptureCancellationTests" 2>&1 | tee -a "$LONG_CANCEL_LOG"
"$LONG_CANCEL_STAGE/LongCaptureCancellationTests" 2>&1 | tee -a "$LONG_CANCEL_LOG"
