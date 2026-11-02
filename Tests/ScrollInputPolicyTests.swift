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
        try expect(pixel.pixels == 240, "The single wheel keeps the existing pixel ceiling")
        passed.append("singleWheelPixelCeiling")
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

        var successful = ScrollInputPolicy.Attempt()
        var simulatedPrimeCount = 0, simulatedWheelCount = 0
        try expect(successful.state == .unused, "A logical attempt starts unused")
        try successful.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
        simulatedPrimeCount += 1
        try expect(successful.state == .ownPrimed, "Begin must consume the attempt before posting a prime")
        try successful.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
        simulatedWheelCount += 1
        try expect(successful.state == .wheelAttempted && simulatedPrimeCount == 1 && simulatedWheelCount == 1,
                   "Success allows one prime and one wheel in a single logical transaction")
        passed.append("singleLogicalPrimeThenWheel")
        try rejectPolicy(.inputAlreadyAttempted) {
            try successful.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
            simulatedWheelCount += 1
        }
        try expect(successful.state == .refused && simulatedWheelCount == 1, "A second wheel permanently refuses the transaction")
        passed.append("secondWheelNeverPosted")
        try rejectPolicy(.inputAlreadyAttempted) {
            try successful.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
            simulatedPrimeCount += 1
        }
        try expect(simulatedPrimeCount == 1 && successful.state == .refused, "A consumed attempt cannot be reset")
        passed.append("refusedTransactionCannotRestart")

        var wheelBeforePrime = ScrollInputPolicy.Attempt()
        try rejectPolicy(.inputAlreadyAttempted) {
            try wheelBeforePrime.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
        }
        try expect(wheelBeforePrime.state == .refused, "A wheel without a prime must refuse")
        passed.append("wheelRequiresOwnPrime")

        var duplicatePrime = ScrollInputPolicy.Attempt()
        try duplicatePrime.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
        try rejectPolicy(.inputAlreadyAttempted) {
            try duplicatePrime.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
        }
        try expect(duplicatePrime.state == .refused, "A second prime is forbidden")
        passed.append("primeCannotRepeat")

        var nativeAttempt = ScrollInputPolicy.Attempt()
        try nativeAttempt.begin(decision: native, freshCapability: .advertised, postingAvailable: false)
        try expect(nativeAttempt.state == .nativeAttempted, "Native input needs no CG posting grant")
        passed.append("nativeConsumesAttemptWithoutPostingGrant")
        try rejectPolicy(.inputAlreadyAttempted) {
            try nativeAttempt.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
        }
        try expect(nativeAttempt.state == .refused, "A native attempt cannot fall back to a prime")
        passed.append("nativeAttemptPreventsPixelPrime")
        try rejectPolicy(.inputAlreadyAttempted) {
            try nativeAttempt.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
        }
        passed.append("nativeAttemptPreventsPixelWheel")

        for (name, capability, grant, expected) in [
            ("initialUnknownAllowsZeroEvents", ScrollInputPolicy.Capability.unknown, true, ScrollInputPolicy.Failure.capabilityChanged),
            ("initialMissingGrantAllowsZeroEvents", .absent, false, .postingUnavailable),
            ("initialChangedCapabilityAllowsZeroEvents", .advertised, true, .capabilityChanged)
        ] {
            var attempt = ScrollInputPolicy.Attempt()
            var primeCount = 0, wheelCount = 0
            try rejectPolicy(expected) {
                try attempt.begin(decision: pixel, freshCapability: capability, postingAvailable: grant)
                primeCount += 1
            }
            try rejectPolicy(.inputAlreadyAttempted) {
                try attempt.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
                wheelCount += 1
            }
            try expect(attempt.state == .refused && primeCount == 0 && wheelCount == 0, "Initial refusal must allow no simulated events")
            passed.append(name)
        }

        for (name, capability, grant, expected) in [
            ("unknownAfterPrimeAllowsZeroWheels", ScrollInputPolicy.Capability.unknown, true, ScrollInputPolicy.Failure.capabilityChanged),
            ("nativeCapabilityAfterPrimeDoesNotSwitch", .advertised, true, .capabilityChanged),
            ("postingGrantLostAfterPrimeAllowsZeroWheels", .absent, false, .postingUnavailable)
        ] {
            var attempt = ScrollInputPolicy.Attempt()
            var wheelCount = 0
            try attempt.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
            try rejectPolicy(expected) {
                try attempt.beginWheel(decision: pixel, freshCapability: capability, postingAvailable: grant)
                wheelCount += 1
            }
            try expect(attempt.state == .refused && wheelCount == 0, "Revalidation refusal consumes prime without a wheel")
            try rejectPolicy(.inputAlreadyAttempted) {
                try attempt.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
                wheelCount += 1
            }
            try expect(wheelCount == 0, "Restoring capability or permission cannot retry the refused transaction")
            passed.append(name)
        }

        for (name, changedDecision) in [
            ("primedCandidateCannotChange", ScrollInputPolicy.Decision(index: pixel.index + 1, strategy: .pixel, pixels: pixel.pixels)),
            ("primedPixelBudgetCannotChange", .init(index: pixel.index, strategy: .pixel, pixels: pixel.pixels - 1)),
            ("primedStrategyCannotChange", .init(index: pixel.index, strategy: .native, pixels: 0))
        ] {
            var attempt = ScrollInputPolicy.Attempt()
            try attempt.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
            try rejectPolicy(.capabilityChanged) {
                try attempt.beginWheel(decision: changedDecision, freshCapability: .absent, postingAvailable: true)
            }
            try expect(attempt.state == .refused, "Original decision remains frozen across the prime")
            passed.append(name)
        }

        // These fixtures model the live adapter refusing after its existing source guards fail.
        // They exercise attempt consumption only; they make no claim about real AX metadata.
        for reason in ["regionChanged", "sourceIdentityChanged", "cancelled", "deadlineExpired", "parentChanged", "markerChanged", "targetChanged"] {
            var attempt = ScrollInputPolicy.Attempt()
            var wheelCount = 0
            try attempt.begin(decision: pixel, freshCapability: .absent, postingAvailable: true)
            attempt.refuse()
            try rejectPolicy(.inputAlreadyAttempted) {
                try attempt.beginWheel(decision: pixel, freshCapability: .absent, postingAvailable: true)
                wheelCount += 1
            }
            try expect(attempt.state == .refused && wheelCount == 0, "Failed source guard cannot lead to a wheel")
            passed.append("\(reason)AfterPrimeAllowsZeroWheels")
        }
        let result: [String: Any] = ["result": "PURE_POLICY_ATTEMPT_AND_MOVEMENT_FIXTURE_PASS", "caseCount": passed.count, "cases": passed, "realInputsOrAXOrCapture": false, "scope": "Pure input decision, logical-attempt accounting and unchanged geometry verification; simulated event counters only, no live delivery or full capture pipeline claim"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

#endif
