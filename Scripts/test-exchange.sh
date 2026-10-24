#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

# These are isolated transport checks. No App/NSApplication, OCR, capture,
# microphone, clipboard, installed data or system permission API is invoked.
research_source="$(pwd)/../搞研究/Sources/GaoActionV1.swift"
include_research=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --without-research) include_research=0; shift ;;
        --research-source)
            [[ $# -ge 2 ]] || { echo "--research-source requires a Swift source path" >&2; exit 2; }
            research_source="$2"; shift 2 ;;
        *) echo "Usage: Scripts/test-exchange.sh [--without-research] [--research-source path]" >&2; exit 2 ;;
    esac
done
if [[ "$include_research" == 1 && ! -f "$research_source" ]]; then
    echo "Research production transport is unavailable: $research_source" >&2
    echo "Use --research-source with the actual source, or --without-research for local checks only." >&2
    exit 2
fi

exchange_regression_temp=$(mktemp -d /private/tmp/GaoJieTu-exchange-regressions.XXXXXX)
trap 'rm -rf "$exchange_regression_temp"' EXIT
# All executable, fixture App and package copies are beneath a real .noindex
# container. The outer mktemp directory contains nothing else and is removed.
exchange_regression_dir="$exchange_regression_temp/Work.noindex"
mkdir -p "$exchange_regression_dir/ModuleCache" "$exchange_regression_dir/Fixtures"
compiler_flags=(-swift-version 5 -target arm64-apple-macos14.0
    -module-cache-path "$exchange_regression_dir/ModuleCache"
    -Xfrontend -disable-sandbox)

research_binary=""
if [[ "$include_research" == 1 ]]; then
    research_binary="$exchange_regression_dir/ResearchTransportFixture"
    echo "Research production source SHA256: $(shasum -a 256 "$research_source" | cut -d ' ' -f 1)"
    # Separate binary: the two Apps' similarly named transport types never share
    # a module. The sibling source is read in place and never copied or edited.
    xcrun swiftc "${compiler_flags[@]}" "$research_source" \
        Scripts/ResearchTransportFixtureMain.swift -o "$research_binary"
fi

xcrun swiftc "${compiler_flags[@]}" \
    Sources/Core/Core.swift \
    Sources/Exchange/GaoActionModel.swift \
    Sources/Exchange/GaoActionTransport.swift \
    Sources/Exchange/GaoActionState.swift \
    Sources/Exchange/GaoActionCapabilities.swift \
    Tests/GaoActionFixtures.swift Tests/GaoActionTests.swift \
    Scripts/ExchangeRegressionMain.swift \
    -o "$exchange_regression_dir/ExchangeRegressionTests"
"$exchange_regression_dir/ExchangeRegressionTests" "$exchange_regression_dir/Fixtures" "$research_binary"
