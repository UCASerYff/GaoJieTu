#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]] || [[ $# -eq 1 && "${1:-}" != "--restore-layout" ]]; then echo '用法：Scripts/test_pinned_image.sh [--restore-layout]' >&2; exit 2; fi
mkdir -p .build.noindex /private/tmp/GaoJieTuModuleCache
PIN_TEST_STAGE=$(mktemp -d "$PWD/.build.noindex/GaoJieTu-pin-tests.XXXXXX")
trap 'rm -rf "$PIN_TEST_STAGE"' EXIT
cat > "$PIN_TEST_STAGE/PinnedImageTestMain.swift" <<'SWIFT'
import Foundation
@main struct PinnedImageTestMain {
    static func main() throws {
        if CommandLine.arguments.contains("--restore-layout") { try runPinnedImageRestoreLayoutRegressionTests() }
        else { try runPinnedImageRegressionTests() }
    }
}
SWIFT
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache \
    Sources/Capture/CaptureService.swift Sources/PinnedImage/PinnedImageController.swift \
    Tests/PinnedImageRegressionTests.swift "$PIN_TEST_STAGE/PinnedImageTestMain.swift" -o "$PIN_TEST_STAGE/PinnedImageTests"
"$PIN_TEST_STAGE/PinnedImageTests" "$@"
