#!/bin/bash
# Construct two events and read their fields in memory only. No posts, pointer queries, UI or AX.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
mkdir -p .build.noindex TestResults
SCROLL_EVENT_STAGE=$(mktemp -d "$PWD/.build.noindex/ScrollPixelEvents.XXXXXX")
trap 'rm -rf "$SCROLL_EVENT_STAGE"' EXIT
xcrun swiftc -Xfrontend -disable-sandbox -D SCROLL_PIXEL_EVENT_BUNDLE_TESTS -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path "$SCROLL_EVENT_STAGE/ModuleCache" \
  Sources/Capture/ScrollPixelEventBundle.swift Tests/ScrollPixelEventBundleTests.swift \
  -o "$SCROLL_EVENT_STAGE/ScrollPixelEventBundleTests"
"$SCROLL_EVENT_STAGE/ScrollPixelEventBundleTests" | tee TestResults/scroll-pixel-event-bundle-tests.json
