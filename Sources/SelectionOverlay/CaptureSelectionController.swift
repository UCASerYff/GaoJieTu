import AppKit
import CoreGraphics

struct CaptureRegionSelection {
    /// Top-left desktop coordinate system, logical points. May intersect several displays.
    let desktopRect: CGRect
    let displayIDs: [CGDirectDisplayID]
}

enum CaptureSelectionGeometry {
    static func screenPoint(eventLocationInWindow: CGPoint, convertToScreen: (CGPoint) -> CGPoint) -> CGPoint {
        convertToScreen(eventLocationInWindow)
    }

    static func desktopPoint(appKitScreenPoint: CGPoint, mainDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: appKitScreenPoint.x, y: mainDisplayTop - appKitScreenPoint.y)
    }

    static func selectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

@MainActor
final class CaptureSelectionController {
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<CaptureRegionSelection?, Never>?
    private var selection: CGRect = .zero
    private var dragOrigin: CGPoint?
    private var mainTop: CGFloat = 0
    private var localMonitor: Any?
    private var highlightedWindows: [CaptureWindow] = []
    private var windowPicked: ((CGWindowID?) -> Void)?
    private var latestScreenPoint: CGPoint?

    /// User-visible selection only. No screenshot is taken while panels exist; completion closes every panel first.
    func selectRegion() async -> CaptureRegionSelection? {
        cancel()
        return await withCheckedContinuation { completion in
            continuation = completion
            present(windows: [])
        }
    }

    /// Mouse hover highlights catalog windows; Escape cancels. Catalog is supplied by CaptureService.
    func selectWindow(from windows: [CaptureWindow]) async -> CGWindowID? {
        cancel()
        guard !windows.isEmpty else { return nil }
        return await withCheckedContinuation { completion in
            windowPicked = { completion.resume(returning: $0) }
            present(windows: windows)
        }
    }

    func cancel() { finish(cancelled: true) }

    private func present(windows: [CaptureWindow]) {
        highlightedWindows = windows
        mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        selection = .zero
        latestScreenPoint = nil
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
            let view = SelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.selectionOwner = self; view.screenFrame = screen.frame
            panel.contentView = view; panels.append(panel)
            panel.orderFrontRegardless()
        }
        // Local event monitoring belongs only to this explicit selection session, not a global shortcut listener.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        panels.first?.makeKey()
    }

    fileprivate func down(at point: CGPoint) {
        latestScreenPoint = point
        if !highlightedWindows.isEmpty {
            if let id = windowAtPointer()?.id { finish(window: id) }
            return
        }
        dragOrigin = point
        selection = CGRect(origin: point, size: .zero)
        redraw()
    }

    fileprivate func drag(at point: CGPoint) {
        latestScreenPoint = point
        guard let origin = dragOrigin else { return }
        selection = CaptureSelectionGeometry.selectionRect(from: origin, to: point)
        redraw()
    }

    fileprivate func up(at point: CGPoint) {
        if dragOrigin != nil { drag(at: point) } else { latestScreenPoint = point }
        dragOrigin = nil
        // Keep the selection for arrow-key adjustment. Return/double click explicitly confirms.
        redraw()
    }

    fileprivate func move(at point: CGPoint) { latestScreenPoint = point; if !highlightedWindows.isEmpty { redraw() } }
    fileprivate func confirm(at point: CGPoint? = nil) {
        if let point { latestScreenPoint = point }
        if windowPicked != nil {
            if let id = windowAtPointer()?.id { finish(window: id) }
        } else if selection.width >= 1, selection.height >= 1 { finish(cancelled: false) }
    }

    private func windowAtPointer() -> CaptureWindow? {
        guard let latestScreenPoint else { return nil }
        let desktopPoint = CaptureSelectionGeometry.desktopPoint(appKitScreenPoint: latestScreenPoint, mainDisplayTop: mainTop)
        return CaptureWindowHitTesting.frontmost(at: desktopPoint, windows: highlightedWindows)
    }

    fileprivate var appKitSelection: CGRect {
        if let window = windowAtPointer(), !highlightedWindows.isEmpty { return CaptureGeometry.desktopToAppKit(window.frame, mainDisplayTop: mainTop) }
        return selection
    }

    fileprivate var selectionLabel: String {
        if let window = windowAtPointer(), !highlightedWindows.isEmpty { return "\(window.applicationName) · \(window.title)\n单击或 Return 选择 · Esc 取消" }
        if !highlightedWindows.isEmpty { return "此处没有可确认前后顺序的窗口\n移动到目标窗口 · Esc 取消" }
        let desktop = CaptureGeometry.appKitToDesktop(selection, mainDisplayTop: mainTop)
        let screens = NSScreen.screens.filter { $0.frame.intersects(selection) }
        let pixels = screens.map { screen -> String in
            let intersection = screen.frame.intersection(selection)
            return "\(Int(ceil(intersection.width * screen.backingScaleFactor))) × \(Int(ceil(intersection.height * screen.backingScaleFactor))) px @\(Int(screen.backingScaleFactor))x"
        }.joined(separator: "；")
        if selection.width < 1 || selection.height < 1 { return "拖动选择截图区域\nReturn 确认 · Esc 取消" }
        return "\(Int(selection.width)) × \(Int(selection.height)) 点 · (\(Int(desktop.minX)), \(Int(desktop.minY)))\n\(pixels)\n方向键移动 · Option+方向键调尺寸 · Shift 10点 · Return 确认 · Esc 取消"
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { cancel(); return true }
        if event.keyCode == 36 || event.keyCode == 76 { confirm(); return true }
        guard highlightedWindows.isEmpty, selection.width >= 1, selection.height >= 1 else { return false }
        let delta: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var x: CGFloat = 0, y: CGFloat = 0
        switch event.keyCode { case 123: x = -delta; case 124: x = delta; case 125: y = -delta; case 126: y = delta; default: return false }
        if event.modifierFlags.contains(.option) {
            selection.size.width = max(1, selection.width + x)
            selection.size.height = max(1, selection.height + y)
        } else { selection = selection.offsetBy(dx: x, dy: y) }
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        selection = selection.intersection(desktopBounds)
        redraw(); return true
    }

    private func redraw() { panels.forEach { $0.contentView?.needsDisplay = true } }

    private func finish(cancelled: Bool = false, window: CGWindowID? = nil) {
        let selected = selection
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); dragOrigin = nil; highlightedWindows.removeAll(); latestScreenPoint = nil
        if let callback = windowPicked { windowPicked = nil; callback(cancelled ? nil : window) }
        if let completion = continuation {
            continuation = nil
            let ids = NSScreen.screens.filter { $0.frame.intersects(selected) }.compactMap(CaptureGeometry.displayID)
            completion.resume(returning: cancelled || selected.width < 1 || selected.height < 1 ? nil : CaptureRegionSelection(desktopRect: CaptureGeometry.appKitToDesktop(selected, mainDisplayTop: mainTop), displayIDs: ids))
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SelectionCanvas: NSView {
    weak var selectionOwner: CaptureSelectionController?
    var screenFrame: CGRect = .zero
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseDown(with event: NSEvent) {
        guard let point = screenPoint(for: event) else { return }
        if event.clickCount == 2 { selectionOwner?.confirm(at: point) } else { selectionOwner?.down(at: point) }
    }
    override func mouseDragged(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.drag(at: point) } }
    override func mouseUp(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.up(at: point) } }
    override func mouseMoved(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.move(at: point) } }
    private func screenPoint(for event: NSEvent) -> CGPoint? {
        guard let eventWindow = event.window ?? window else { return nil }
        return CaptureSelectionGeometry.screenPoint(eventLocationInWindow: event.locationInWindow, convertToScreen: { eventWindow.convertPoint(toScreen: $0) })
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner = selectionOwner else { return }
        NSColor.black.withAlphaComponent(0.32).setFill(); bounds.fill()
        let local = owner.appKitSelection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        if local.width > 0, local.height > 0 {
            NSGraphicsContext.current?.cgContext.clear(local.intersection(bounds))
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: local); outline.lineWidth = 1; outline.stroke()
            NSColor.systemBlue.setStroke(); let inner = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1)); inner.lineWidth = 1; inner.stroke()
        }
        let label = owner.selectionLabel
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        let box = CGRect(x: max(12, min(bounds.width - labelSize.width - 28, local.minX)), y: max(12, min(bounds.height - labelSize.height - 28, local.minY - labelSize.height - 20)), width: min(bounds.width - 24, labelSize.width + 20), height: labelSize.height + 16)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        (label as NSString).draw(in: box.insetBy(dx: 10, dy: 8), withAttributes: attributes)
    }
}
