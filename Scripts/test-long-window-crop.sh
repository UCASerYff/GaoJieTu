#!/bin/bash
# Synthetic in-memory crop geometry, pixel ownership and retained-buffer budget checks only.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
mkdir -p .build.noindex
LONG_WINDOW_CROP_STAGE=$(mktemp -d "$PWD/.build.noindex/GaoJieTu-window-crop-tests.XXXXXX")
trap 'rm -rf "$LONG_WINDOW_CROP_STAGE"' EXIT
LONG_WINDOW_CROP_FLAGS=(-Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0
  -module-cache-path "$LONG_WINDOW_CROP_STAGE/ModuleCache.noindex")
xcrun swiftc "${LONG_WINDOW_CROP_FLAGS[@]}" -D LONG_CAPTURE_WINDOW_CROP_TESTS \
  Sources/Capture/CaptureService.swift Sources/Capture/LongCaptureWindowCrop.swift \
  Tests/LongCaptureWindowCropTests.swift -o "$LONG_WINDOW_CROP_STAGE/WindowCropTests"
"$LONG_WINDOW_CROP_STAGE/WindowCropTests"
xcrun swiftc "${LONG_WINDOW_CROP_FLAGS[@]}" -D LONG_CAPTURE_BACKING_BUDGET_TESTS \
  Sources/Capture/CaptureService.swift Sources/Capture/LongCaptureWindowCrop.swift \
  Sources/Capture/ScrollTargetGuard.swift Sources/Capture/ScrollVisibilityPlan.swift \
  Sources/Capture/ScrollInputPolicy.swift Sources/Capture/ScrollPixelEventBundle.swift \
  Sources/Capture/LongScreenshotSession.swift Tests/LongCaptureBackingBudgetTests.swift \
  -o "$LONG_WINDOW_CROP_STAGE/BackingBudgetTests"
"$LONG_WINDOW_CROP_STAGE/BackingBudgetTests"
