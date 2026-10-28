#!/bin/bash
# CLI only: production callback/monitor isolation and generated-audio recovery.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-all}"
case "$MODE" in all|session|recovery) ;; *) echo '仅支持 all、session、recovery' >&2; exit 2;; esac
if [[ $# -gt 1 ]]; then echo '只接受一个测试范围参数' >&2; exit 2; fi
TEST_STAGE=$(mktemp -d /private/tmp/GaoJieTuRecordingTargeted.XXXXXX)
trap 'rm -rf "$TEST_STAGE"' EXIT
cat > "$TEST_STAGE/RecordingTargetedMain.swift" <<'SWIFT'
import Foundation
@main
struct RecordingTargetedMain {
    static func main() async {
        do {
            let mode = CommandLine.arguments.dropFirst().first ?? "all"
            if mode == "all" || mode == "session" { try await runRecordingSessionIsolationTests() }
            if mode == "all" || mode == "recovery" { try await runRecordingAudioRecoveryTests() }
        } catch {
            fputs("Recording targeted tests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }
}
SWIFT
mkdir -p /private/tmp/GaoJieTuModuleCache
xcrun swiftc -Xfrontend -disable-sandbox -D RECORDING_SESSION_TESTS -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path /private/tmp/GaoJieTuModuleCache \
  Sources/Recording/*.swift Tests/RecordingSessionIsolationTests.swift Tests/RecordingAudioRecoveryTests.swift \
  "$TEST_STAGE/RecordingTargetedMain.swift" -o "$TEST_STAGE/RecordingTargetedTests"
"$TEST_STAGE/RecordingTargetedTests" "$MODE"
