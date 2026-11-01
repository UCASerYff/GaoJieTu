#!/bin/bash
# Only synthetic CGRect data; no NSApp, AX query, event delivery or real capture.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '本脚本不接受参数' >&2; exit 2; fi
SCROLL_VISIBILITY_STAGE=$(mktemp -d /private/tmp/GaoJieTuScrollVisibility.XXXXXX)
trap 'rm -rf "$SCROLL_VISIBILITY_STAGE"' EXIT
mkdir -p TestResults
SCROLL_VISIBILITY_LOG="$PWD/TestResults/scroll-visibility-plan-tests.txt"
cat > "$SCROLL_VISIBILITY_STAGE/ScrollVisibilityPlanTests.swift" <<'SWIFT'
import Foundation
import CoreGraphics

@main
enum ScrollVisibilityPlanTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }

    static func rejects(_ name: String, _ expected: ScrollVisibilityPlan.Failure,
                        _ body: () throws -> Void) {
        checks += 1
        do {
            try body()
            fatalError("FAIL: \(name) did not reject")
        } catch let error as ScrollVisibilityPlan.Failure {
            guard error == expected else { fatalError("FAIL: \(name) rejected with \(error), expected \(expected)") }
        } catch {
            fatalError("FAIL: \(name) unexpected error \(error)")
        }
    }

    static func main() throws {
        let viewport = CGRect(x: 100, y: 100, width: 500, height: 600)
        let roi = CGRect(x: 120, y: 110, width: 460, height: 580)
        let marker = CGRect(x: 110, y: 300, width: 480, height: 70)
        let target = CGRect(x: 110, y: 680, width: 480, height: 80)
        let plan = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                     target: target, requestedPoints: 240)
        require(plan.expectedMinimumScroll == 60, "minimum derived from target/viewport frames")
        require(plan.stepBudget == 240, "requested step bounds predicted minimum")
        require(abs(plan.maxActualDelta - 464) < 0.0001, "overlap bound derives from selected ROI")
        let movedMarker = marker.offsetBy(dx: 0, dy: -80)
        let movedTarget = target.offsetBy(dx: 0, dy: -80)
        let firstDelta = try plan.verify(viewportAfter: viewport, markerAfter: movedMarker,
                                         targetAfter: movedTarget)
        require(firstDelta == 80, "same-column wider rows may move consistently")
        let halfROI = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                       target: target, requestedPoints: 1_000)
        require(halfROI.stepBudget == 290, "half ROI caps minimum even with larger request")
        let partlyVisibleMarker = CGRect(x: 110, y: 70, width: 480, height: 80)
        _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: partlyVisibleMarker,
                                              target: target, requestedPoints: 240)
        checks += 1

        for bad in [CGFloat.zero, -1, .nan, .infinity, 2_001] {
            rejects("invalid requested budget \(bad)", .invalidBudget) {
                _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                      target: target, requestedPoints: bad)
            }
        }
        rejects("nonfinite source geometry", .invalidGeometry) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi,
                                                  marker: CGRect(x: CGFloat.nan, y: 300, width: 480, height: 70),
                                                  target: target, requestedPoints: 240)
        }
        rejects("empty viewport", .invalidGeometry) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: .zero, roi: roi, marker: marker,
                                                  target: target, requestedPoints: 240)
        }
        rejects("ROI outside measured viewport", .regionOutsideViewport) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi.offsetBy(dx: 40, dy: 0),
                                                  marker: marker, target: target, requestedPoints: 240)
        }
        rejects("unrelated marker column", .markerOutsideRegion) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi,
                                                  marker: CGRect(x: 105, y: 300, width: 100, height: 70),
                                                  target: target, requestedPoints: 240)
        }
        rejects("marker outside selected vertical content", .markerOutsideRegion) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi,
                                                  marker: marker.offsetBy(dx: 0, dy: -400),
                                                  target: target, requestedPoints: 240)
        }
        rejects("target would need horizontal scroll", .targetOutsideColumn) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                  target: target.offsetBy(dx: 20, dy: 0), requestedPoints: 240)
        }
        rejects("neighboring target column", .targetOutsideColumn) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                  target: CGRect(x: 105, y: 680, width: 100, height: 80),
                                                  requestedPoints: 240)
        }
        rejects("target taller than viewport", .targetTooTall) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                  target: CGRect(x: 110, y: 680, width: 480, height: 601),
                                                  requestedPoints: 240)
        }
        rejects("already-visible target", .targetAlreadyVisible) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                  target: target.offsetBy(dx: 0, dy: -70), requestedPoints: 240)
        }
        rejects("predicted minimum over budget", .minimumScrollExceedsBudget) {
            _ = try ScrollVisibilityPlan.makePlan(viewport: viewport, roi: roi, marker: marker,
                                                  target: target.offsetBy(dx: 0, dy: 200), requestedPoints: 240)
        }

        rejects("setter/action success with zero movement", .noForwardMovement) {
            try plan.verify(viewportAfter: viewport, markerAfter: marker, targetAfter: target)
        }
        rejects("backward movement", .noForwardMovement) {
            try plan.verify(viewportAfter: viewport, markerAfter: marker.offsetBy(dx: 0, dy: 10),
                            targetAfter: target.offsetBy(dx: 0, dy: 10))
        }
        rejects("source viewport moved", .viewportChanged) {
            try plan.verify(viewportAfter: viewport.offsetBy(dx: 0, dy: 1),
                            markerAfter: movedMarker, targetAfter: movedTarget)
        }
        rejects("selected region changed", .regionChanged) {
            try plan.verify(viewportAfter: viewport, roiAfter: roi.offsetBy(dx: 0, dy: 1),
                            markerAfter: movedMarker, targetAfter: movedTarget)
        }
        rejects("marker width changed", .elementGeometryChanged) {
            try plan.verify(viewportAfter: viewport,
                            markerAfter: CGRect(x: movedMarker.minX, y: movedMarker.minY,
                                                width: movedMarker.width + 1, height: movedMarker.height),
                            targetAfter: movedTarget)
        }
        rejects("target height changed", .elementGeometryChanged) {
            try plan.verify(viewportAfter: viewport, markerAfter: movedMarker,
                            targetAfter: CGRect(x: movedTarget.minX, y: movedTarget.minY,
                                                width: movedTarget.width, height: movedTarget.height + 1))
        }
        rejects("horizontal layout changed", .elementGeometryChanged) {
            try plan.verify(viewportAfter: viewport, markerAfter: movedMarker.offsetBy(dx: 1, dy: 0),
                            targetAfter: movedTarget.offsetBy(dx: 1, dy: 0))
        }
        rejects("different content deltas despite target being visible", .inconsistentMovement) {
            try plan.verify(viewportAfter: viewport, markerAfter: marker.offsetBy(dx: 0, dy: -70),
                            targetAfter: target.offsetBy(dx: 0, dy: -80))
        }
        rejects("actual scroll would leave insufficient overlap", .excessiveMovement) {
            try plan.verify(viewportAfter: viewport, markerAfter: marker.offsetBy(dx: 0, dy: -465),
                            targetAfter: target.offsetBy(dx: 0, dy: -465))
        }
        rejects("both moved but target still clipped", .targetNotVisible) {
            try plan.verify(viewportAfter: viewport, markerAfter: marker.offsetBy(dx: 0, dy: -30),
                            targetAfter: target.offsetBy(dx: 0, dy: -30))
        }
        rejects("nonfinite post-action target", .invalidGeometry) {
            try plan.verify(viewportAfter: viewport, markerAfter: movedMarker,
                            targetAfter: CGRect(x: movedTarget.minX, y: CGFloat.infinity, width: 480, height: 80))
        }
        let roundedDelta = try plan.verify(viewportAfter: viewport,
                                           markerAfter: movedMarker.offsetBy(dx: 0.25, dy: 0),
                                           targetAfter: movedTarget.offsetBy(dx: 0.25, dy: -0.25))
        require(roundedDelta == 80.25, "subpoint frame rounding remains bounded")
        print("PASS: \(checks) pure scroll-visibility geometry checks; no UI/AX/capture/input")
    }
}
SWIFT
date -u '+Scroll visibility pure checks started: %Y-%m-%dT%H:%M:%SZ' | tee "$SCROLL_VISIBILITY_LOG"
xcrun swiftc -Xfrontend -disable-sandbox -swift-version 5 \
  -target arm64-apple-macos14.0 -module-cache-path "$SCROLL_VISIBILITY_STAGE/ModuleCache" \
  Sources/Capture/ScrollVisibilityPlan.swift "$SCROLL_VISIBILITY_STAGE/ScrollVisibilityPlanTests.swift" \
  -o "$SCROLL_VISIBILITY_STAGE/ScrollVisibilityPlanTests" 2>&1 | tee -a "$SCROLL_VISIBILITY_LOG"
"$SCROLL_VISIBILITY_STAGE/ScrollVisibilityPlanTests" 2>&1 | tee -a "$SCROLL_VISIBILITY_LOG"
printf 'Output: %s\n' "$SCROLL_VISIBILITY_LOG"
