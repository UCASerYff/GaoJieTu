#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
translation_regression_dir=$(mktemp -d /private/tmp/GaoJieTu-translation-regressions.noindex.XXXXXX)
trap 'rm -rf "$translation_regression_dir"' EXIT
mkdir -p /private/tmp/GaoJieTuModuleCache
cat > "$translation_regression_dir/Main.swift" <<'SWIFT'
import Foundation
@main struct TranslationRegressionMain {
    @MainActor static func main() async {
        do { try await runTranslationRegressionTests() }
        catch { fputs("Translation regression failure: \(error)\n", stderr); exit(1) }
    }
}
SWIFT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache -Xfrontend -disable-sandbox \
    Sources/Translation/TranslationOperation.swift Tests/TranslationRegressionTests.swift \
    "$translation_regression_dir/Main.swift" -o "$translation_regression_dir/TranslationRegressionTests"
"$translation_regression_dir/TranslationRegressionTests"
