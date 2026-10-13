#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build TestResults /private/tmp/GaoJieTuModuleCache
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources Tests -name '*.swift' | grep -v '^Sources/UI/' | sort)
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache "${SOURCES[@]}" -o .build/GaoJieTuTests
.build/GaoJieTuTests | tee TestResults/unit-tests.txt
