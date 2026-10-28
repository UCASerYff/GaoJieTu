#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
budget_test_dir=$(mktemp -d /private/tmp/GaoJieTu-ocr-export-budget.XXXXXX)
trap 'rm -rf "$budget_test_dir"' EXIT
mkdir -p /private/tmp/GaoJieTuModuleCache
cat > "$budget_test_dir/Main.swift" <<'SWIFT'
import Foundation
@main struct OCRExportBudgetMain {
    static func main() async {
        let directory = URL(fileURLWithPath: "/private/tmp/GaoJieTu-ocr-export-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try await runOCRExportBudgetTests(in: directory) }
        catch { fputs("OCR export budget failure: \(error)\n", stderr); exit(1) }
    }
}
SWIFT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache -Xfrontend -disable-sandbox \
    Sources/OCR/OCRModels.swift Sources/OCR/OCRService.swift Sources/OCR/OCRExporter.swift \
    Tests/OCRExportBudgetTests.swift "$budget_test_dir/Main.swift" -o "$budget_test_dir/OCRExportBudgetTests"
"$budget_test_dir/OCRExportBudgetTests"
