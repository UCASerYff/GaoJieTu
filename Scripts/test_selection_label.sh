#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build.noindex /private/tmp/GaoJieTuModuleCache
LABEL_TEST_STAGE=$(mktemp -d "$PWD/.build.noindex/GaoJieTu-label-tests.XXXXXX")
trap 'rm -rf "$LABEL_TEST_STAGE"' EXIT
cat > "$LABEL_TEST_STAGE/SelectionLabelTestMain.swift" <<'SWIFT'
import Foundation
@main struct SelectionLabelTestMain {
    static func main() throws { try runCaptureSelectionLabelRegressionTests() }
}
SWIFT
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache \
    Sources/Capture/CaptureService.swift Sources/Capture/LongScreenshotSession.swift \
    Sources/PinnedImage/PinnedImageController.swift Sources/SelectionOverlay/CaptureSelectionController.swift \
    Tests/CaptureRegressionTests.swift "$LABEL_TEST_STAGE/SelectionLabelTestMain.swift" -o "$LABEL_TEST_STAGE/SelectionLabelTests"
"$LABEL_TEST_STAGE/SelectionLabelTests"
