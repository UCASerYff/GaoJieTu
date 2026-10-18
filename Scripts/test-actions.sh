#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
regression_build_dir=$(mktemp -d /private/tmp/GaoJieTu-action-regressions.XXXXXX)
trap 'rm -rf "$regression_build_dir"' EXIT
mkdir -p /private/tmp/GaoJieTuModuleCache
cat > "$regression_build_dir/Main.swift" <<'SWIFT'
import Foundation
@main struct ActionRegressionMain {
    @MainActor static func main() async {
        let directory = URL(fileURLWithPath: "/private/tmp/GaoJieTu-action-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try await runActionRegressionTests(in: directory) }
        catch { fputs("Action regression failure: \(error)\n", stderr); exit(1) }
    }
}
SWIFT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache -Xfrontend -disable-sandbox \
    Sources/Core/Core.swift Sources/Exchange/*.swift Sources/OCR/OCRModels.swift Sources/OCR/OCRService.swift \
    Sources/OCR/OCRExporter.swift Sources/OCR/OCRRecoveryStore.swift Sources/Translation/TranslationOperation.swift \
    Tests/ActionRegressionTests.swift "$regression_build_dir/Main.swift" -o "$regression_build_dir/ActionRegressionTests"
"$regression_build_dir/ActionRegressionTests"
