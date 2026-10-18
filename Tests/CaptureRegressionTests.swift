import Foundation
import CoreGraphics

private func captureRegressionCheck(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try condition() else { throw NSError(domain: "CaptureRegressionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}

private func captureRegressionRows(height: Int, offset: Int = 0, period: Int? = nil) throws -> CGImage {
    let width = 8
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let row = period.map { (y + offset) % $0 } ?? (y + offset)
        for x in 0..<width {
            let index = (y * width + x) * 4
            if period != nil {
                pixels[index] = UInt8(row * 13); pixels[index + 1] = pixels[index]; pixels[index + 2] = pixels[index]
            } else {
                pixels[index] = UInt8(truncatingIfNeeded: row)
                pixels[index + 1] = UInt8(truncatingIfNeeded: row >> 8)
                pixels[index + 2] = UInt8(truncatingIfNeeded: row * 31 + x)
            }
            pixels[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptureFailure.emptyImage }
    return image
}

/// Only new regressions from the 2026-10-18 audit. No NSApplication, NSPanel, device, permission or capture calls.
@MainActor
func runCaptureRegressionTests() throws {
    let ranks = CaptureWindowHitTesting.ranks(frontToBackIDs: [11, 12, 11, 13])
    try captureRegressionCheck(ranks[11] == 0 && ranks[12] == 1, "WindowServer rank should preserve the first occurrence")
    let front = CaptureWindow(id: 11, title: "Synthetic front", applicationName: "Fixture", processID: 1,
                              frame: CGRect(x: 0, y: 0, width: 1000, height: 800), isOnScreen: true, zOrder: ranks[11])
    let hidden = CaptureWindow(id: 12, title: "Synthetic hidden", applicationName: "Fixture", processID: 2,
                               frame: CGRect(x: 100, y: 100, width: 200, height: 200), isOnScreen: true, zOrder: ranks[12])
    try captureRegressionCheck(CaptureWindowHitTesting.frontmost(at: CGPoint(x: 150, y: 150), windows: [hidden, front])?.id == 11, "A fully covered small window must not replace the visible front window")
    let protruding = CaptureWindow(id: 13, title: "Synthetic partial", applicationName: "Fixture", processID: 3,
                                   frame: CGRect(x: 900, y: 100, width: 200, height: 200), isOnScreen: true, zOrder: 2)
    try captureRegressionCheck(CaptureWindowHitTesting.frontmost(at: CGPoint(x: 1050, y: 150), windows: [front, protruding])?.id == 13, "The visible protruding part remains selectable")
    let unknown = CaptureWindow(id: 14, title: "Unknown order", applicationName: "Fixture", processID: 4,
                                frame: hidden.frame, isOnScreen: true)
    try captureRegressionCheck(CaptureWindowHitTesting.frontmost(at: CGPoint(x: 150, y: 150), windows: [unknown]) == nil, "Unknown z-order must not be guessed from area")

    let target = CGRect(x: -200, y: 100, width: 1200, height: 800)
    let content = CGRect(x: 600, y: 200, width: 200, height: 400)
    try captureRegressionCheck(try ScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: content) == CGPoint(x: 700, y: 400), "A right-side pane must receive the scroll instead of the window centre")
    try captureRegressionCheck(try ScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: nil) == CGPoint(x: 400, y: 500), "An explicit whole-window target may use its centre")
    do {
        _ = try ScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: CGRect(x: 990, y: 200, width: 50, height: 20))
        throw NSError(domain: "CaptureRegressionTests", code: 2)
    } catch CaptureFailure.invalidRegion {}

    let previous = try captureRegressionRows(height: 1400)
    let current = try captureRegressionRows(height: 1400, offset: 400)
    let preview = try ScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 1000)
    try captureRegressionCheck(preview.previousRect.minY == 1080 && preview.currentRect.minY == 680 && preview.currentImage.height == 320, "Large overlaps must preview corresponding rows at the end of the overlap")
    for y in [0, 159, 319] {
        let a = try CaptureColorSampler.pixel(in: preview.previousImage, at: CGPoint(x: 3, y: y))
        let b = try CaptureColorSampler.pixel(in: preview.currentImage, at: CGPoint(x: 3, y: y))
        try captureRegressionCheck(a.hex == b.hex, "Preview strips should show identical source rows for a true 1000px overlap")
    }
    let small = try ScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 16)
    try captureRegressionCheck(small.currentImage.height == 16 && small.currentRect.minY == 0, "Small overlaps must not include unmatched rows")
    let direct = try ScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 0)
    try captureRegressionCheck(direct.currentRect.minY == 0 && direct.previousRect.minY == 1080, "A zero overlap previews directly adjoining edges")

    let pending = LongScreenshotSession()
    _ = try pending.addFrame(captureRegressionRows(height: 1400, period: 16))
    _ = try pending.addFrame(captureRegressionRows(height: 1400, offset: 6, period: 16))
    try captureRegressionCheck(pending.pendingSeam != nil, "A repeated pattern should provide a pending seam for preview adjustment")
    let proposed = try pending.pendingPreview(overlapPixels: 1000)
    let adjusted = try pending.pendingPreview(overlapPixels: 800)
    try captureRegressionCheck(proposed?.currentRect.minY == 680 && adjusted?.currentRect.minY == 480, "Changing the proposed overlap must change the preview crop used by the slider")

    let fractional = try CaptureGeometry.normalizedRegion(CGRect(x: 0.25, y: 2.5, width: 11.5, height: 5), displaySize: CGSize(width: 100, height: 100), scale: 2)
    try captureRegressionCheck(fractional.pixelRect == CGRect(x: 0, y: 5, width: 24, height: 10), "Fractional Retina origin and max edge both round outward")
    try captureRegressionCheck(fractional.sourceRect == CGRect(x: 0, y: 2.5, width: 12, height: 5) && fractional.sourceRect.width * 2 == fractional.pixelRect.width, "SCK source rectangle and output width must describe the same physical pixels")
    let clipped = try CaptureGeometry.normalizedRegion(CGRect(x: -0.25, y: 99.25, width: 4, height: 4), displaySize: CGSize(width: 100, height: 100), scale: 2)
    try captureRegressionCheck(clipped.sourceRect == CGRect(x: 0, y: 99, width: 4, height: 1) && clipped.pixelRect.height == 2, "Outward snapping must remain inside the display at both outer edges")
    let regular = try CaptureGeometry.normalizedRegion(CGRect(x: 1.2, y: 2.3, width: 2.4, height: 3.4), displaySize: CGSize(width: 100, height: 100), scale: 1)
    try captureRegressionCheck(regular.sourceRect == CGRect(x: 1, y: 2, width: 3, height: 4), "Fractional 1x source edges should round outward")
    do {
        _ = try CaptureGeometry.normalizedRegion(CGRect(x: 120, y: 120, width: 10, height: 10), displaySize: CGSize(width: 100, height: 100), scale: 2)
        throw NSError(domain: "CaptureRegressionTests", code: 3)
    } catch CaptureFailure.invalidRegion {}

    try captureRegressionCheck(PinnedImageGeometry.actualPixelScale(backingScale: 1) == 1, "A 1x screen uses one point per image pixel")
    try captureRegressionCheck(PinnedImageGeometry.actualPixelScale(backingScale: 2) == 0.5, "A 2x screen uses half a point per image pixel")
    try captureRegressionCheck(400 * PinnedImageGeometry.actualPixelScale(backingScale: 2) * 2 == 400, "1:1 on Retina must keep physical pixel count unchanged")
    print("PASS Capture regressions: front-to-back hit, selected scroll anchor, corresponding seam previews and adjustment, fractional 1x/2x region snapping, current-screen pin scale (no GUI/capture).")
}
