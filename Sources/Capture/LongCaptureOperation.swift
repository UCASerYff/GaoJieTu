import Foundation
import CoreGraphics

/// Owns the entire long-capture interaction, including the time after preparation returns.
@MainActor
final class LongCaptureOperation {
    private(set) var isActive = true
    private var preparationTask: Task<Void, Never>?

    func checkActive() throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
    }

    func setPreparationTask(_ task: Task<Void, Never>) {
        guard isActive else { task.cancel(); return }
        preparationTask = task
    }

    func preparationFinished() { preparationTask = nil }

    /// Invalidate first: cancellation callbacks and late producers cannot end a later operation.
    @discardableResult
    func finish(cleanup: () -> Void) -> Bool {
        guard isActive else { return false }
        isActive = false
        preparationTask?.cancel(); preparationTask = nil
        cleanup()
        return true
    }
}

struct LongCapturePreparedSource {
    let window: CaptureWindow
    let display: CaptureDisplay
    let region: CGRect
}

/// The production preparation pipeline. Injected effects allow cancellation checks without UI/capture.
@MainActor
enum LongCapturePreparation {
    static func run(operation: LongCaptureOperation,
                    isCurrent: () -> Bool = { true },
                    refreshCatalog: () async throws -> CaptureCatalog,
                    selectWindow: ([CaptureWindow]) async -> CGWindowID?,
                    willSelectRegion: () -> Void,
                    selectRegion: () async -> CGRect?,
                    activate: (CaptureWindow) throws -> Void,
                    settle: () async throws -> Void) async throws -> LongCapturePreparedSource {
        func checkCurrent() throws {
            try operation.checkActive()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let catalog = try await refreshCatalog()
        try checkCurrent()
        let selectedID = await selectWindow(catalog.windows)
        try checkCurrent()
        guard let id = selectedID, let window = catalog.windows.first(where: { $0.id == id }) else { throw CaptureFailure.cancelled }
        willSelectRegion()
        let selectedRegion = await selectRegion()
        try checkCurrent()
        guard let region = selectedRegion else { throw CaptureFailure.cancelled }
        guard let display = catalog.displays.first(where: { $0.frame.contains(region) }),
              window.frame.insetBy(dx: -1, dy: -1).contains(region) else {
            throw CaptureFailure.unsupported("长截图内容区须完整位于所选窗口与一块显示器内，请重新选择。跨屏普通截图仍可使用。")
        }
        try activate(window)
        try await settle()
        try checkCurrent()
        return LongCapturePreparedSource(window: window, display: display, region: region)
    }
}
