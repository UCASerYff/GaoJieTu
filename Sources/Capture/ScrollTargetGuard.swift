import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

/// Metadata only: no window title or captured content enters the target guard.
struct ScrollWindowMetadata {
    let windowID: CGWindowID
    let processID: pid_t?
    let frame: CGRect?
    var layer: Int? = 0
    var alpha: Double? = 1
    var bundleID: String? = nil
    var ownerName = ""

    var isEligible: Bool {
        CaptureWindowEligibility.allows(layer: layer, alpha: alpha, processID: processID,
                                        bundleID: bundleID, ownerName: ownerName, frame: frame)
    }
}

/// CFEqual compares the remote Accessibility element's identity, rather than Swift wrapper identity.
struct ScrollFocusIdentity: Equatable {
    private let value: CFTypeRef

    init(element: AXUIElement) { value = element }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }

    #if SCROLL_TARGET_GUARD_TESTS
    /// A CF value stands in for identity only; tests never create or query an AX element.
    init(testToken: Int) { value = NSNumber(value: testToken) }
    #endif
}

enum ScrollFocusEvidence {
    case accessibilityUnavailable
    case accessibilityQueryFailed
    case accessibility(processID: pid_t, frame: CGRect, identity: ScrollFocusIdentity)
}

struct ScrollTargetSnapshot {
    let frontmostPID: pid_t?
    let windows: [ScrollWindowMetadata]
    let focus: ScrollFocusEvidence
    /// A probe checks the foreground again after its metadata queries.
    var foregroundStayedConsistent = true
}

enum ScrollTargetCheckStage: String {
    case preCapture, postCapture, preScroll, postScroll
}

struct ScrollTargetDiagnostic: Equatable, CustomStringConvertible {
    static let unknown: Int64 = -1
    let stage: ScrollTargetCheckStage
    let expectedPID: Int64
    let actualPID: Int64
    let expectedWindowID: Int64
    let actualWindowID: Int64

    var description: String {
        "\(stage.rawValue) expectedPID=\(expectedPID) actualPID=\(actualPID) expectedWindowID=\(expectedWindowID) actualWindowID=\(actualWindowID)"
    }

    func recordFailure() {
        #if !SCROLL_TARGET_GUARD_TESTS
        // This failure-only record contains a stage and numeric identities, never titles or images.
        Logger(subsystem: "com.gaoseries.GaoJieTu", category: "LongCaptureTarget").error("\(description, privacy: .public)")
        #endif
    }
}

enum ScrollTargetFailureReason: Equatable {
    case foregroundChanged, selectedWindowUnavailable, geometryChanged, invalidRegion
    case focusUnavailable, focusQueryFailed, focusAmbiguous, focusChanged

    var message: String {
        switch self {
        case .foregroundChanged, .focusChanged:
            return "目标焦点或窗口改变，请回到原窗口后重试。"
        case .selectedWindowUnavailable:
            return "所选目标窗口已消失或不再可捕获，请重新选择。"
        case .geometryChanged:
            return "目标窗口位置或大小改变，已停止捕获，请重新选择内容范围。"
        case .invalidRegion:
            return "长截图内容范围不再完整位于所选窗口内，请重新选择。"
        case .focusUnavailable:
            return "无法继续确认原目标焦点，已暂停并保留已有帧；请检查辅助功能权限后重试。"
        case .focusQueryFailed:
            return "无法读取目标焦点，已暂停并保留已有帧，请回到原窗口后重试。"
        case .focusAmbiguous:
            return "无法唯一确认目标窗口，已暂停并保留已有帧；未授权辅助功能时，仅支持目标应用只有一个可捕获窗口的手动长截图。"
        }
    }
}

struct ScrollTargetValidationFailure: Error {
    let reason: ScrollTargetFailureReason
    let actualPID: pid_t?
    let actualWindowID: CGWindowID?
}

/// Stateful identity binding with pure metadata inputs. The live adapter is the only AX/CG caller.
final class ScrollTargetGuard {
    private let target: ScrollTargetIdentity
    private var initialFrame: CGRect?
    private var focusedIdentity: ScrollFocusIdentity?
    var boundAccessibilityIdentity: ScrollFocusIdentity? { focusedIdentity }

    init(target: ScrollTargetIdentity) { self.target = target; initialFrame = target.frame }

    /// Only the AX-to-CG bridge permits subpoint rounding; frozen CG bounds remain exact.
    private func matchesAXFrame(_ ax: CGRect, _ cg: CGRect) -> Bool {
        abs(ax.minX - cg.minX) <= 0.5 && abs(ax.minY - cg.minY) <= 0.5
            && abs(ax.width - cg.width) <= 0.5 && abs(ax.height - cg.height) <= 0.5
    }

    func validate(_ snapshot: ScrollTargetSnapshot, requiresAccessibility: Bool = false) throws -> CGRect {
        let qualified = snapshot.windows.filter { $0.processID == target.processID && $0.isEligible }
        let focusedMatches: [ScrollWindowMetadata]
        let observedPID: pid_t?
        switch snapshot.focus {
        case .accessibility(let pid, let frame, _):
            observedPID = pid
            focusedMatches = qualified.filter { $0.processID == pid && $0.frame.map { matchesAXFrame(frame, $0) } == true }
        case .accessibilityUnavailable:
            observedPID = snapshot.frontmostPID
            focusedMatches = focusedIdentity == nil && !requiresAccessibility && qualified.count == 1 ? qualified : []
        case .accessibilityQueryFailed:
            observedPID = snapshot.frontmostPID
            focusedMatches = []
        }
        let observedID = focusedMatches.count == 1 ? focusedMatches[0].windowID : nil
        func fail(_ reason: ScrollTargetFailureReason, pid: pid_t? = nil, id: CGWindowID? = nil) throws -> Never {
            throw ScrollTargetValidationFailure(reason: reason, actualPID: pid ?? observedPID, actualWindowID: id ?? observedID)
        }

        guard snapshot.foregroundStayedConsistent, snapshot.frontmostPID == target.processID else {
            throw ScrollTargetValidationFailure(reason: .foregroundChanged, actualPID: snapshot.frontmostPID, actualWindowID: nil)
        }
        // Lookup the exact selected identity; list order never substitutes for window identity.
        let selected = qualified.filter { $0.windowID == target.windowID }
        guard selected.count == 1, let bounds = selected[0].frame else { try fail(.selectedWindowUnavailable) }
        if let initialFrame, bounds != initialFrame { try fail(.geometryChanged, id: target.windowID) }
        do { _ = try ScrollCaptureGeometry.scrollAnchor(windowBounds: bounds, selectedRegion: target.scrollRegion) }
        catch { try fail(.invalidRegion, id: target.windowID) }

        switch snapshot.focus {
        case .accessibilityUnavailable:
            // Revocation after an AX binding must not silently weaken the evidence.
            guard focusedIdentity == nil, !requiresAccessibility else { try fail(.focusUnavailable) }
            guard qualified.count == 1 else { try fail(.focusAmbiguous) }
        case .accessibilityQueryFailed:
            try fail(.focusQueryFailed)
        case .accessibility(let pid, let frame, let identity):
            guard pid == target.processID, CaptureWindowEligibility.validFrame(frame) else { try fail(.focusChanged) }
            guard focusedMatches.count == 1 else { try fail(.focusAmbiguous) }
            guard observedID == target.windowID else { try fail(.focusChanged) }
            if let focusedIdentity, focusedIdentity != identity { try fail(.focusChanged) }
            focusedIdentity = identity
        }
        if initialFrame == nil { initialFrame = bounds }
        return bounds
    }
}

@MainActor
protocol ScrollTargetProbing: AnyObject {
    func sample(target: ScrollTargetIdentity) -> ScrollTargetSnapshot
}

/// Reads only window metadata and public focused-window identity/geometry; never requests permission.
@MainActor
final class LiveScrollTargetProbe: ScrollTargetProbing {
    func sample(target: ScrollTargetIdentity) -> ScrollTargetSnapshot {
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let properties = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let application = NSRunningApplication(processIdentifier: target.processID)
        let windows = properties.compactMap { info -> ScrollWindowMetadata? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid == target.processID, let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return ScrollWindowMetadata(windowID: id, processID: pid, frame: bounds,
                                        layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                                        alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                                        bundleID: application?.bundleIdentifier,
                                        ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "")
        }
        let focus = AXIsProcessTrusted() ? focusedWindow(processID: target.processID) : .accessibilityUnavailable
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return ScrollTargetSnapshot(frontmostPID: frontmostAfter, windows: windows, focus: focus,
                                    foregroundStayedConsistent: frontmostBefore == frontmostAfter)
    }

    private func focusedWindow(processID: pid_t) -> ScrollFocusEvidence {
        let application = AXUIElementCreateApplication(processID)
        guard AXUIElementSetMessagingTimeout(application, 0.2) == .success else { return .accessibilityQueryFailed }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return .accessibilityQueryFailed }
        let focused = focusedValue as! AXUIElement
        guard AXUIElementSetMessagingTimeout(focused, 0.2) == .success else { return .accessibilityQueryFailed }
        var pid: pid_t = 0
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementGetPid(focused, &pid) == .success,
              AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return .accessibilityQueryFailed }
        let position = positionValue as! AXValue, size = sizeValue as! AXValue
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return .accessibilityQueryFailed }
        var focusAfterGeometry: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusAfterGeometry) == .success,
              let focusAfterGeometry, CFGetTypeID(focusAfterGeometry) == AXUIElementGetTypeID(),
              CFEqual(focused, focusAfterGeometry) else { return .accessibilityQueryFailed }
        // AXPosition and AXSize use global desktop points with a top-left origin, just like CG bounds.
        return .accessibility(processID: pid, frame: CGRect(origin: point, size: dimensions), identity: ScrollFocusIdentity(element: focused))
    }
}

@MainActor
enum ScrollAccessibilityAction {
    /// One page action advertised by the original ROI's scroll area.
    /// The source app defines the page size; no pixel distance or overlap is promised.
    static func pageDown(target: ScrollTargetIdentity, anchor: CGPoint,
                         windowIdentity: ScrollFocusIdentity, revalidate: () throws -> Void) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let app = AXUIElementCreateApplication(target.processID)
        let action = "AXScrollDownByPage" as CFString
        let unavailable = CaptureFailure.unsupported("此滚动区域没有可核验的向下翻页动作，请手动滚动后捕获下一帧。")
        func prepare(_ element: AXUIElement) throws {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var pid: pid_t = 0
            guard remaining > 0, AXUIElementSetMessagingTimeout(element, Float(min(0.2, remaining))) == .success,
                  AXUIElementGetPid(element, &pid) == .success, pid == target.processID else { throw unavailable }
        }
        func value(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef {
            try prepare(element)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &raw) == .success, let raw else { throw unavailable }
            return raw
        }
        func elementValue(_ element: AXUIElement, _ name: CFString) throws -> AXUIElement {
            let raw = try value(element, name)
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw unavailable }
            return raw as! AXUIElement
        }
        func sameWindow(_ element: AXUIElement) throws {
            let window = try elementValue(element, kAXWindowAttribute as CFString)
            let topLevel = try elementValue(element, kAXTopLevelUIElementAttribute as CFString)
            try prepare(window); try prepare(topLevel)
            guard ScrollFocusIdentity(element: window) == windowIdentity,
                  ScrollFocusIdentity(element: topLevel) == windowIdentity else { throw unavailable }
        }
        func frame(_ element: AXUIElement) throws -> CGRect {
            let rawPosition = try value(element, kAXPositionAttribute as CFString)
            let rawSize = try value(element, kAXSizeAttribute as CFString)
            guard CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { throw unavailable }
            let position = rawPosition as! AXValue, dimensions = rawSize as! AXValue
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimensions) == .cgSize,
                  AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size) else { throw unavailable }
            let rect = CGRect(origin: point, size: size)
            guard CaptureWindowEligibility.validFrame(rect) else { throw unavailable }
            return rect
        }
        func resolve() throws -> (area: AXUIElement, frame: CGRect) {
            try prepare(app)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(anchor.x), Float(anchor.y), &hit) == .success,
                  var current = hit else { throw unavailable }
            for _ in 0..<24 {
                try prepare(current)
                let role = try value(current, kAXRoleAttribute as CFString) as? String
                if role == kAXWindowRole as String { throw unavailable }
                try sameWindow(current)
                if role == kAXScrollAreaRole as String {
                    guard let roi = target.scrollRegion else { throw unavailable }
                    let areaFrame = try frame(current)
                    // Do not select a larger outer area when the nearest one does not contain the ROI.
                    guard areaFrame.contains(roi) else { throw unavailable }
                    var actions: CFArray?
                    try prepare(current)
                    guard AXUIElementCopyActionNames(current, &actions) == .success,
                          let names = actions as? [String], names.contains(action as String) else { throw unavailable }
                    return (current, areaFrame)
                }
                current = try elementValue(current, kAXParentAttribute as CFString)
            }
            throw unavailable
        }
        let original = try resolve()
        let latest = try resolve()
        guard CFEqual(original.area, latest.area), original.frame == latest.frame else { throw unavailable }
        try prepare(latest.area)
        // Make the unchanged production focus/CG geometry guard the final major read before input.
        try revalidate()
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else { throw unavailable }
        let result = AXUIElementPerformAction(latest.area, action)
        guard result == .success else {
            // A timeout can mean the action already ran. Never retry or fall back to a global event.
            throw CaptureFailure.unsupported("滚动动作结果未确认（AX \(result.rawValue)），未自动重试；请核对原窗口后手动滚动。")
        }
    }
}
