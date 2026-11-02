import CoreGraphics

/// Memory-only construction. The caller owns target validation and the single transaction's posts.
struct ScrollPixelEventBundle {
    let prime: CGEvent
    let wheel: CGEvent

    init?(windowID: CGWindowID, anchor: CGPoint, pixels: Int32) {
        guard windowID != kCGNullWindowID, anchor.x.isFinite, anchor.y.isFinite,
              pixels >= 1, pixels <= 240,
              let prime = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: anchor, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -pixels, wheel2: 0, wheel3: 0) else { return nil }
        // Both events exist before either leaves this constructor. Only the mouse prime carries a window ID.
        prime.location = anchor
        prime.flags = []
        prime.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        prime.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                   value: Int64(windowID))
        wheel.location = anchor
        wheel.flags = []
        // The wheel has no mouse-window metadata; its caller must retain the original PID/session guards.
        guard prime.type == .mouseMoved, prime.location == anchor, prime.flags.isEmpty,
              prime.getIntegerValueField(.mouseEventWindowUnderMousePointer) == Int64(windowID),
              prime.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == Int64(windowID),
              wheel.type == .scrollWheel, wheel.location == anchor, wheel.flags.isEmpty,
              wheel.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -Int64(pixels),
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0,
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0 else { return nil }
        self.prime = prime
        self.wheel = wheel
    }
}
