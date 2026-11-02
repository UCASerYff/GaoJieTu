#if SCROLL_INPUT_POLICY_TESTS
import Foundation
import CoreGraphics

// Pure fixture only: no AX, event, app/window, permission, screen or audio API.
private struct FixtureFailure: Error { let message: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw FixtureFailure(message: message) }
}
private func rejectPolicy(_ expected: ScrollInputPolicy.Failure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected policy rejection: \(expected)") }
    catch let error as ScrollInputPolicy.Failure { try expect(error == expected, "Wrong policy rejection") }
}
private func rejectMotion(_ expected: ScrollVisibilityPlan.Failure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected movement rejection: \(expected)") }
    catch let error as ScrollVisibilityPlan.Failure { try expect(error == expected, "Wrong movement rejection") }
}
private func plan(minimum: CGFloat = 50, roiHeight: CGFloat = 960, requested: CGFloat = 240) throws -> ScrollVisibilityPlan {
    try ScrollVisibilityPlan.makePlan(viewport: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        roi: CGRect(x: 20, y: 20, width: 960, height: roiHeight),
        marker: CGRect(x: 0, y: 100, width: 1000, height: 90),
        target: CGRect(x: 0, y: 1000, width: 1000, height: minimum), requestedPoints: requested)
}
@main struct ScrollInputPolicyTests {
    static func main() throws {
        var passed: [String] = []
        let small = try plan(minimum: 50), large = try plan(minimum: 150)
        let mixed = try ScrollInputPolicy.select([.init(plan: small, capability: .absent), .init(plan: large, capability: .advertised)], requestedPoints: 240)
        try expect(mixed.index == 1 && mixed.strategy == .native && mixed.pixels == 0, "Native must win over cheaper absent candidate")
        passed.append("nativePreferredOverCheaperPixel")
        let native = try ScrollInputPolicy.select([.init(plan: large, capability: .advertised), .init(plan: small, capability: .advertised)], requestedPoints: 240)
        try expect(native.index == 1 && native.strategy == .native, "Choose smallest valid native target")
        passed.append("smallestNativeCandidate")
        let mixedUnknown = try ScrollInputPolicy.select([.init(plan: small, capability: .unknown), .init(plan: large, capability: .advertised)], requestedPoints: 240)
        try expect(mixedUnknown.index == 1 && mixedUnknown.strategy == .native && mixedUnknown.pixels == 0, "Verified native must win despite unrelated unknown")
        passed.append("verifiedNativeWinsOverUnknown")
        let reverseMixedUnknown = try ScrollInputPolicy.select([.init(plan: small, capability: .advertised), .init(plan: large, capability: .unknown)], requestedPoints: 240)
        try expect(reverseMixedUnknown.index == 0 && reverseMixedUnknown.strategy == .native, "Candidate order must not suppress verified native")
        passed.append("nativePriorityIndependentOfUnknownOrder")
        try ScrollInputPolicy.requireReady(mixedUnknown, freshCapability: .advertised, inputAlreadyAttempted: false, postingAvailable: false)
        passed.append("verifiedNativeDoesNotNeedCGPostingGrant")
        try rejectPolicy(.capabilityChanged) { try ScrollInputPolicy.requireReady(mixedUnknown, freshCapability: .unknown, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("selectedNativeMustRemainKnownAdvertised")
        try rejectPolicy(.unknownCapability) { _ = try ScrollInputPolicy.select([.init(plan: small, capability: .unknown)], requestedPoints: 240) }
        passed.append("unknownNeverMeansAbsent")
        try rejectPolicy(.unknownCapability) { _ = try ScrollInputPolicy.select([.init(plan: small, capability: .absent), .init(plan: large, capability: .unknown)], requestedPoints: 240) }
        passed.append("partlyUnknownCannotAuthorizePixel")
        let fractional = try ScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: 60.9)
        try expect(fractional.pixels == 60 && fractional.strategy == .pixel, "Respect smaller request and floor")
        passed.append("smallerRequestAndFloor")
        let tiny = try plan(minimum: 0.2, requested: 0.9)
        try rejectPolicy(.invalidPixelBudget) { _ = try ScrollInputPolicy.select([.init(plan: tiny, capability: .absent)], requestedPoints: 0.9) }
        passed.append("zeroRoundedPixelRefused")
        let clipped = try plan(minimum: 60.5, requested: 60.9)
        try rejectPolicy(.invalidPixelBudget) { _ = try ScrollInputPolicy.select([.init(plan: clipped, capability: .absent)], requestedPoints: 60.9) }
        passed.append("roundedPixelMustCoverMinimum")
        let lowROI = try plan(minimum: 80, roiHeight: 201, requested: 240)
        let bounded = try ScrollInputPolicy.select([.init(plan: lowROI, capability: .absent)], requestedPoints: 240)
        try expect(bounded.pixels == 100, "ROI half-height floor must apply")
        passed.append("halfROIFloor")
        let pixel = try ScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: 500)
        try expect(pixel.pixels == 240, "Global one-event pixel ceiling")
        passed.append("singlePixelEventCeiling")
        try rejectPolicy(.invalidPixelBudget) { _ = try ScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: .nan) }
        passed.append("nonfiniteRequestRefused")
        try rejectPolicy(.capabilityChanged) { try ScrollInputPolicy.requireReady(pixel, freshCapability: .advertised, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("newNativeCapabilityDoesNotSwitchMidFlight")
        try rejectPolicy(.capabilityChanged) { try ScrollInputPolicy.requireReady(pixel, freshCapability: .unknown, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("selectedPixelMustRemainKnownAbsent")
        try rejectPolicy(.capabilityChanged) { try ScrollInputPolicy.requireReady(native, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("lostNativeDoesNotFallBack")
        try rejectPolicy(.postingUnavailable) { try ScrollInputPolicy.requireReady(pixel, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: false) }
        passed.append("missingPostingGrantRefused")
        try rejectPolicy(.inputAlreadyAttempted) { try ScrollInputPolicy.requireReady(pixel, freshCapability: .absent, inputAlreadyAttempted: true, postingAvailable: true) }
        passed.append("priorAXOrCGAttemptPreventsPixel")
        try rejectPolicy(.inputAlreadyAttempted) { try ScrollInputPolicy.requireReady(native, freshCapability: .advertised, inputAlreadyAttempted: true, postingAvailable: true) }
        passed.append("priorAttemptPreventsNativeRetry")
        try ScrollInputPolicy.requireReady(pixel, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: true)
        passed.append("freshExplicitAbsenceAllowsOnePixelRoute")
        let p = small
        func shifted(_ rect: CGRect, _ delta: CGFloat) -> CGRect { rect.offsetBy(dx: 0, dy: -delta) }
        try expect(try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) == 100, "Consistent verified motion")
        passed.append("actualConsistentMotionRequired")
        try rejectMotion(.noForwardMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: p.marker, targetAfter: p.target) }
        passed.append("postedButNoMotionRejected")
        try rejectMotion(.noForwardMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, -1), targetAfter: shifted(p.target, -1)) }
        passed.append("reverseMotionRejected")
        try rejectMotion(.excessiveMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 769), targetAfter: shifted(p.target, 769)) }
        passed.append("excessiveMotionRejected")
        try rejectMotion(.inconsistentMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 90)) }
        passed.append("inconsistentMotionRejected")
        try rejectMotion(.targetNotVisible) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 49), targetAfter: shifted(p.target, 49)) }
        passed.append("insufficientMotionRejected")
        try rejectMotion(.viewportChanged) { _ = try p.verify(viewportAfter: p.viewport.offsetBy(dx: 1, dy: 0), roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) }
        passed.append("originalAreaGeometryRequired")
        try rejectMotion(.regionChanged) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi.offsetBy(dx: 1, dy: 0), markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) }
        passed.append("originalROIRequired")
        let result: [String: Any] = ["result": "PURE_POLICY_AND_MOVEMENT_FIXTURE_PASS", "caseCount": passed.count, "cases": passed, "realInputsOrAXOrCapture": false, "scope": "Input decision and unchanged geometry verification only; no live delivery or full capture pipeline claim"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

#endif
