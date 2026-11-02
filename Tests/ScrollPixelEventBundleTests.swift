#if SCROLL_PIXEL_EVENT_BUNDLE_TESTS
import Foundation
import CoreGraphics
import Darwin

// Event construction and field readback only. Never post, warp, read the pointer, or query an app/window.
private struct FixtureFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FixtureFailure(message: message) }
}

@main struct ScrollPixelEventBundleTests {
    static func main() {
        do { try run() }
        catch {
            let result: [String: Any] = ["result": "IN_MEMORY_EVENT_CONSTRUCTION_FAILED",
                "error": String(describing: error), "eventsPosted": 0,
                "globalPointerReadsOrWarps": 0, "appOrWindowQueries": 0]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(1)
        }
    }

    private static func run() throws {
        var passed: [String] = []
        try expect(CGEventField.mouseEventWindowUnderMousePointer.rawValue == 91,
                   "Expected public window-under-pointer field 91")
        try expect(CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent.rawValue == 92,
                   "Expected public event-handling-window field 92")
        passed.append("typedPublicWindowFields")

        let anchor = CGPoint(x: 651, y: 663.5)
        // Earlier raw failure and refusal fixtures remain archived unchanged. The accepted contract
        // binds only the prime to the original window; the wheel's PID/session binding belongs to its caller.
        guard let bundle = ScrollPixelEventBundle(windowID: 101, anchor: anchor, pixels: 1) else {
            throw FixtureFailure(message: "Expected window-bound prime and bounded wheel construction")
        }
        try expect(bundle.prime.type == .mouseMoved && bundle.prime.location == anchor && bundle.prime.flags.isEmpty,
                   "Prime type, original anchor or empty flags changed")
        try expect(bundle.prime.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 101 &&
                   bundle.prime.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 101,
                   "Prime did not retain both public original-window fields")
        try expect(bundle.wheel.type == .scrollWheel && bundle.wheel.location == anchor && bundle.wheel.flags.isEmpty,
                   "Wheel type, original anchor or empty flags changed")
        try expect(bundle.wheel.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -1 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0,
                   "Wheel must retain one negative vertical pixel with no other axes")
        passed.append("windowBoundPrimeAndBoundedWheelConstructed")
        try expect(ScrollPixelEventBundle(windowID: 0, anchor: anchor, pixels: 100) == nil,
                   "Null original window must be refused")
        passed.append("nullWindowRefused")
        for pixels in [Int32(0), -1, 241, .max, .min] {
            try expect(ScrollPixelEventBundle(windowID: 101, anchor: anchor, pixels: pixels) == nil,
                       "Out-of-budget pixel amount accepted: \(pixels)")
            passed.append("invalidPixels_\(pixels)")
        }
        let invalid: [(String, CGPoint)] = [
            ("nanX", CGPoint(x: CGFloat.nan, y: 1)),
            ("nanY", CGPoint(x: 1, y: CGFloat.nan)),
            ("infiniteX", CGPoint(x: CGFloat.infinity, y: 1)),
            ("infiniteY", CGPoint(x: 1, y: CGFloat.infinity)),
            ("negativeInfiniteX", CGPoint(x: -CGFloat.infinity, y: 1)),
            ("negativeInfiniteY", CGPoint(x: 1, y: -CGFloat.infinity))
        ]
        for (name, point) in invalid {
            try expect(ScrollPixelEventBundle(windowID: 101, anchor: point, pixels: 100) == nil,
                       "Nonfinite anchor accepted: \(name)")
            passed.append(name)
        }
        let result: [String: Any] = [
            "result": "MEMORY_PRIME_WINDOW_BOUND_PID_WHEEL_CONSTRUCTION_ONLY",
            "constructionChecks": "PASS", "deliveryProven": false, "wheelCarriesWindowIDClaim": false,
            "caseCount": passed.count, "cases": passed,
            "eventsPosted": 0, "globalPointerReadsOrWarps": 0, "appOrWindowQueries": 0,
            "earlierRawFailure": "Acceptance-2026-10-28/WindowPrimeConstructionBlocker.noindex/first-failed-raw-output.json",
            "scope": "Memory construction only: prime carries original window metadata; wheel has only bounded pixel data and anchor. Caller must retain original PID/session guards. No delivery or live scrolling claim"
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
#endif
