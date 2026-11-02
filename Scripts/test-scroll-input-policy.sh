#!/bin/bash
# Only pure input-choice and motion-verification cases; no UI, AX calls or CG event creation.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
mkdir -p .build.noindex TestResults
SCROLL_INPUT_STAGE=$(mktemp -d "$PWD/.build.noindex/ScrollInputTests.XXXXXX")
trap 'rm -rf "$SCROLL_INPUT_STAGE"' EXIT
xcrun swiftc -Xfrontend -disable-sandbox -D SCROLL_INPUT_POLICY_TESTS -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path "$SCROLL_INPUT_STAGE/ModuleCache" \
  Sources/Capture/ScrollVisibilityPlan.swift Sources/Capture/ScrollInputPolicy.swift Tests/ScrollInputPolicyTests.swift \
  -o "$SCROLL_INPUT_STAGE/ScrollInputPolicyTests"
"$SCROLL_INPUT_STAGE/ScrollInputPolicyTests" | tee TestResults/scroll-input-policy-tests.json
