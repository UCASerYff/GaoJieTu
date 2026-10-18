import AppKit
import CoreGraphics

struct ScrollTargetIdentity: Equatable {
    let processID: pid_t
    let windowID: CGWindowID
    var frame: CGRect? = nil
    /// User-selected scroll content in the top-left desktop point coordinate system.
    var scrollRegion: CGRect? = nil
}

enum ScrollCaptureGeometry {
    static func scrollAnchor(windowBounds: CGRect, selectedRegion: CGRect?) throws -> CGPoint {
        func valid(_ rect: CGRect) -> Bool { rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0 }
        guard valid(windowBounds) else { throw CaptureFailure.invalidRegion }
        let region = selectedRegion ?? windowBounds
        guard valid(region), windowBounds.contains(region) else { throw CaptureFailure.invalidRegion }
        return CGPoint(x: region.midX, y: region.midY)
    }
}

enum ScrollCaptureState: Equatable {
    case idle, capturing, awaitingSeam, paused(String), cancelled, completed, failed(String)
}

struct ScrollCaptureBudget {
    var maximumPixels = 60_000_000
    var maximumHeight = 40_000
    /// Input images, working pixels and output are all charged conservatively to this budget.
    var maximumMemoryBytes = 512 * 1024 * 1024
    var maximumFrames = 80
    var fixedTopPixels = 0
    var fixedBottomPixels = 0
}

struct ScrollSeamEstimate {
    let overlapPixels: Int
    let confidence: Double
    let meanAbsoluteError: Double
    let duplicate: Bool
    let warnings: [String]
    let previousPreview: CGImage
    let currentPreview: CGImage
}

struct ScrollSeamPreview {
    let previousImage: CGImage
    let currentImage: CGImage
    let previousRect: CGRect
    let currentRect: CGRect
}

enum ScrollSeamPreviewRenderer {
    /// Both strips show the same end of the proposed overlap, including when overlap exceeds the preview limit.
    /// For a zero overlap there are no common rows: show the two adjoining edges instead.
    static func make(previous: CGImage, current: CGImage, overlapPixels: Int, maximumHeight: Int = 320) throws -> ScrollSeamPreview {
        guard previous.width == current.width, overlapPixels >= 0, overlapPixels <= min(previous.height, current.height), maximumHeight > 0 else { throw CaptureFailure.invalidRegion }
        let height = min(maximumHeight, overlapPixels > 0 ? overlapPixels : min(previous.height, current.height))
        guard height > 0 else { throw CaptureFailure.invalidRegion }
        let previousRect = CGRect(x: 0, y: previous.height - height, width: previous.width, height: height)
        let currentRect = CGRect(x: 0, y: overlapPixels > 0 ? overlapPixels - height : 0, width: current.width, height: height)
        guard let previousImage = previous.cropping(to: previousRect), let currentImage = current.cropping(to: currentRect) else { throw CaptureFailure.emptyImage }
        return ScrollSeamPreview(previousImage: previousImage, currentImage: currentImage, previousRect: previousRect, currentRect: currentRect)
    }
}

private struct ScrollFrameSegment {
    let image: CGImage
    let overlap: Int
}

/// In-memory bounded scroll stitching. Exceeding the budget stops before allocation; this implementation
/// does not claim unbounded/disk-tiled output. Every low-confidence seam requires explicit acceptance.
@MainActor
final class LongScreenshotSession {
    let target: ScrollTargetIdentity?
    let budget: ScrollCaptureBudget
    private(set) var state: ScrollCaptureState = .idle
    private(set) var seams: [ScrollSeamEstimate] = []
    private(set) var pendingSeam: ScrollSeamEstimate?
    private(set) var capturedFrameCount = 0
    private(set) var outputHeight = 0
    private(set) var estimatedPeakMemoryBytes = 0
    private var segments: [ScrollFrameSegment] = []
    private var pendingImage: CGImage?
    var pendingFrameHeight: Int? { pendingImage?.height }

    func pendingPreview(overlapPixels: Int) throws -> ScrollSeamPreview? {
        guard let previous = segments.last?.image, let current = pendingImage else { return nil }
        guard overlapPixels >= 0, overlapPixels < current.height else { throw CaptureFailure.invalidRegion }
        return try ScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: overlapPixels)
    }

    init(target: ScrollTargetIdentity? = nil, budget: ScrollCaptureBudget = .init()) {
        self.target = target; self.budget = budget
    }

    /// Manual frames from the same view are supported without Accessibility permission.
    /// The caller can generate synthetic frames for isolated tests; only captureNext performs real capture.
    @discardableResult
    func addFrame(_ frame: CGImage) throws -> ScrollSeamEstimate? {
        guard state != .cancelled, state != .completed else { throw CaptureFailure.cancelled }
        guard pendingSeam == nil else { throw CaptureFailure.unsupported("请先预览并确认或拒绝上一条接缝。") }
        let image = try normalized(frame)
        guard segments.count < budget.maximumFrames else { throw CaptureFailure.budgetExceeded }
        if let previous = segments.last?.image {
            guard previous.width == image.width, previous.height == image.height else {
                state = .paused("窗口尺寸或截图范围改变，请重新开始长截图。")
                throw CaptureFailure.unsupported("前后帧尺寸不同，已暂停，未拼接错位画面。")
            }
            state = .capturing
            let estimate = try ScrollOverlapMatcher.estimate(previous: previous, current: image)
            if estimate.duplicate { state = .paused("画面没有移动，可能已到边界；当前帧未重复追加。"); return estimate }
            try checkBudget(adding: image, overlap: estimate.overlapPixels)
            if estimate.confidence < 0.88 || !estimate.warnings.isEmpty {
                pendingImage = image; pendingSeam = estimate; state = .awaitingSeam
            } else { append(image, estimate: estimate) }
            return estimate
        }
        try checkBudget(adding: image, overlap: 0)
        segments.append(ScrollFrameSegment(image: image, overlap: 0)); capturedFrameCount = 1
        outputHeight = image.height; state = .capturing; return nil
    }

    /// Explicit manual seam correction is bounded to the common frame height.
    func acceptPending(overlapPixels: Int? = nil) throws {
        guard let image = pendingImage, let estimate = pendingSeam else { return }
        let overlap = overlapPixels ?? estimate.overlapPixels
        guard overlap >= 0, overlap < image.height else { throw CaptureFailure.invalidRegion }
        try checkBudget(adding: image, overlap: overlap)
        let accepted = ScrollSeamEstimate(overlapPixels: overlap, confidence: estimate.confidence, meanAbsoluteError: estimate.meanAbsoluteError, duplicate: false, warnings: estimate.warnings + ["用户已预览并确认接缝"], previousPreview: estimate.previousPreview, currentPreview: estimate.currentPreview)
        pendingImage = nil; pendingSeam = nil; append(image, estimate: accepted)
    }

    func rejectPending() { pendingImage = nil; pendingSeam = nil; state = .paused("已拒绝接缝，可手动调整目标滚动位置后重试。") }
    func pause(_ reason: String = "用户暂停") { if state != .cancelled && state != .completed { state = .paused(reason) } }
    func cancel() { state = .cancelled; pendingImage = nil; pendingSeam = nil; segments.removeAll(); seams.removeAll(); outputHeight = 0; capturedFrameCount = 0 }

    /// Real capture verifies the foreground PID and selected window before and after every frame.
    @discardableResult
    func captureNext(using service: CaptureService, source: CaptureSource, options: CaptureOptions = .init()) async throws -> ScrollSeamEstimate? {
        try validateCurrentTarget()
        let frame = try await service.capture(source, options: options)
        try validateCurrentTarget()
        return try addFrame(frame.image)
    }

    /// A single explicit scroll action, never a hidden global loop. A changed target immediately pauses.
    @discardableResult
    func scrollAndCapture(using service: CaptureService, source: CaptureSource, downwardPoints: Int32 = 240, options: CaptureOptions = .init()) async throws -> ScrollSeamEstimate? {
        guard let target else { throw CaptureFailure.unsupported("自动滚动需要明确的目标窗口；无目标时请手动滚动。") }
        guard AXIsProcessTrusted() else { throw CaptureFailure.unsupported("辅助功能权限未授权，仍可使用手动滚动逐帧拼接。") }
        guard downwardPoints <= 2_000, downwardPoints > 0 else { throw CaptureFailure.invalidRegion }
        try validateCurrentTarget()
        guard let info = currentTargetWindow(), let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -downwardPoints, wheel2: 0, wheel3: 0) else { throw CaptureFailure.sourceMissing }
        event.location = try ScrollCaptureGeometry.scrollAnchor(windowBounds: bounds, selectedRegion: target.scrollRegion)
        event.postToPid(target.processID)
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation(); try validateCurrentTarget()
        return try await captureNext(using: service, source: source, options: options)
    }

    func finish() throws -> CGImage {
        guard state != .cancelled else { throw CaptureFailure.cancelled }
        guard pendingSeam == nil else { throw CaptureFailure.unsupported("尚有待确认接缝，请预览后再导出。") }
        guard let first = segments.first else { throw CaptureFailure.emptyImage }
        try CaptureGeometry.validateBudget(width: first.image.width, height: outputHeight, maximumPixels: budget.maximumPixels, maximumBytes: budget.maximumMemoryBytes)
        guard let context = CGContext(data: nil, width: first.image.width, height: outputHeight, bitsPerComponent: 8, bytesPerRow: first.image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.budgetExceeded }
        var top = 0
        for segment in segments {
            let remaining = segment.image.height - segment.overlap
            guard let crop = segment.image.cropping(to: CGRect(x: 0, y: segment.overlap, width: segment.image.width, height: remaining)) else { throw CaptureFailure.emptyImage }
            context.draw(crop, in: CGRect(x: 0, y: outputHeight - top - remaining, width: crop.width, height: remaining))
            top += remaining
        }
        guard let output = context.makeImage(), top == outputHeight else { throw CaptureFailure.emptyImage }
        state = .completed
        return output
    }

    /// Testable target guard, also called with live metadata by validateCurrentTarget().
    func validateTarget(frontmostPID: pid_t?, activeWindowID: CGWindowID?, activeWindowFrame: CGRect? = nil) throws {
        guard let target else { return }
        guard frontmostPID == target.processID, activeWindowID == target.windowID else {
            state = .paused("目标焦点或窗口改变，已停止滚动和捕获。")
            throw CaptureFailure.unsupported("目标焦点或窗口改变，请回到原窗口后重试。")
        }
        if let expected = target.frame, activeWindowFrame != expected {
            state = .paused("目标窗口位置或大小改变，请重新选择内容范围。")
            throw CaptureFailure.unsupported("目标窗口位置或大小改变，已停止捕获，避免截取错误范围。")
        }
    }

    private func currentTargetWindow() -> [String: Any]? {
        guard let target else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // The first normal window owned by the target is the active candidate; modal/other windows pause us.
        return windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
    }

    private func validateCurrentTarget() throws {
        let current = currentTargetWindow()
        let id = (current?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        let frame = (current?[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        try validateTarget(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, activeWindowID: id, activeWindowFrame: frame)
    }

    private func normalized(_ image: CGImage) throws -> CGImage {
        let top = budget.fixedTopPixels, bottom = budget.fixedBottomPixels
        guard top >= 0, bottom >= 0, top < image.height, bottom < image.height - top,
              image.width >= 8, image.height - top - bottom >= 32,
              let crop = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom)) else { throw CaptureFailure.invalidRegion }
        return crop
    }

    private func checkBudget(adding image: CGImage, overlap: Int) throws {
        let proposedHeight = outputHeight + image.height - overlap
        guard proposedHeight <= budget.maximumHeight else { throw CaptureFailure.budgetExceeded }
        try CaptureGeometry.validateBudget(width: image.width, height: proposedHeight, maximumPixels: budget.maximumPixels, maximumBytes: budget.maximumMemoryBytes)
        // Retained frames + full output + two working normalized bitmaps + pending seam previews.
        let retained = segments.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        let peak = retained + image.bytesPerRow * image.height * 3 + image.width * proposedHeight * 4
        guard peak <= budget.maximumMemoryBytes else { throw CaptureFailure.budgetExceeded }
        estimatedPeakMemoryBytes = max(estimatedPeakMemoryBytes, peak)
    }

    private func append(_ image: CGImage, estimate: ScrollSeamEstimate) {
        segments.append(ScrollFrameSegment(image: image, overlap: estimate.overlapPixels)); seams.append(estimate)
        capturedFrameCount += 1; outputHeight += image.height - estimate.overlapPixels; state = .capturing
    }
}

enum ScrollOverlapMatcher {
    static func estimate(previous: CGImage, current: CGImage) throws -> ScrollSeamEstimate {
        guard previous.width == current.width, previous.height == current.height, previous.height >= 32 else { throw CaptureFailure.invalidRegion }
        let sampleWidth = min(144, previous.width), height = previous.height
        let a = try grayPixels(previous, width: sampleWidth), b = try grayPixels(current, width: sampleWidth)
        func error(overlap: Int) -> Double {
            let stepY = max(1, overlap / 64), stepX = max(1, sampleWidth / 48)
            var total = 0.0, count = 0
            for y in stride(from: 0, to: overlap, by: stepY) {
                let offsetA = (height - overlap + y) * sampleWidth, offsetB = y * sampleWidth
                for x in stride(from: 2, to: sampleWidth - 2, by: stepX) { total += abs(Double(a[offsetA + x]) - Double(b[offsetB + x])); count += 1 }
            }
            return count > 0 ? total / Double(count) / 255 : 1
        }
        let identicalError = error(overlap: height)
        let minOverlap = max(16, height / 12), maxOverlap = height - max(8, height / 40)
        var ranked: [(Int, Double)] = []
        for overlap in minOverlap...maxOverlap { ranked.append((overlap, error(overlap: overlap))) }
        ranked.sort { $0.1 < $1.1 }
        guard let best = ranked.first else { throw CaptureFailure.invalidRegion }
        let second = ranked.first { abs($0.0 - best.0) > max(3, height / 100) }?.1 ?? 1
        var warnings: [String] = []
        let separation = max(0, second - best.1)
        var confidence = min(1, max(0, (1 - best.1 * 5) * min(1, separation / 0.035)))
        if best.1 > 0.08 { warnings.append("重叠差异较大：可能有动画、视频、滚动过快或范围变化。") }
        if separation < 0.018 { warnings.append("内容重复或纹理不足，存在多个相似接缝。") }
        let fixedHeader = sameEdgeRows(a, b, width: sampleWidth, height: height, fromTop: true)
        let fixedFooter = sameEdgeRows(a, b, width: sampleWidth, height: height, fromTop: false)
        if identicalError > 0.005 && (fixedHeader >= 16 || fixedFooter >= 16) {
            warnings.append("检测到固定页眉/页脚或静止区域；请设置排除像素并重新开始，或人工核对接缝。")
            confidence = min(confidence, 0.75)
        }
        if identicalError > 0.005 && (sameEdgeColumns(a, b, width: sampleWidth, height: height, fromLeft: true) >= max(8, sampleWidth / 8) || sameEdgeColumns(a, b, width: sampleWidth, height: height, fromLeft: false) >= max(8, sampleWidth / 8)) {
            warnings.append("检测到固定侧栏；建议重新选择纯滚动内容范围，或人工核对接缝。")
            confidence = min(confidence, 0.75)
        }
        let duplicate = identicalError < 0.003
        let preview = try ScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: duplicate ? height : best.0)
        return ScrollSeamEstimate(overlapPixels: duplicate ? height : best.0, confidence: duplicate ? 1 : confidence, meanAbsoluteError: best.1, duplicate: duplicate, warnings: warnings, previousPreview: preview.previousImage, currentPreview: preview.currentImage)
    }

    private static func grayPixels(_ image: CGImage, width: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * image.height)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height)); return true
        }
        guard success else { throw CaptureFailure.emptyImage }; return pixels
    }

    private static func sameEdgeRows(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, fromTop: Bool) -> Int {
        var matched = 0
        for edgeY in 0..<min(height / 4, 160) {
            let y = fromTop ? edgeY : height - 1 - edgeY
            var sum = 0
            for x in stride(from: 2, to: width - 2, by: max(1, width / 32)) { sum += abs(Int(a[y * width + x]) - Int(b[y * width + x])) }
            if sum > max(1, width / max(1, width / 32)) * 2 { break }
            matched += 1
        }
        return matched
    }

    private static func sameEdgeColumns(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, fromLeft: Bool) -> Int {
        var matched = 0
        for edgeX in 0..<max(1, width / 3) {
            let x = fromLeft ? edgeX : width - 1 - edgeX
            var sum = 0, samples = 0
            for y in stride(from: 4, to: height - 4, by: max(1, height / 48)) { sum += abs(Int(a[y * width + x]) - Int(b[y * width + x])); samples += 1 }
            if sum > samples * 2 { break }; matched += 1
        }
        return matched
    }
}
