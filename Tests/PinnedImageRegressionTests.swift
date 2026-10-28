import Foundation
import CoreGraphics

private func pinRegressionRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NSError(domain: "PinnedImageRegressionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Pure layout/restore planning and an in-memory raster. No application, window, data root or capture API.
func runPinnedImageRegressionTests() throws {
    let narrow = CGSize(width: 20, height: 100)
    let scale2x = PinnedImageGeometry.actualPixelScale(backingScale: 2)
    let narrowCanvas = PinnedImageGeometry.windowSize(pixelSize: narrow, scale: scale2x)
    let narrowRect = PinnedImageGeometry.imageRect(pixelSize: narrow, scale: scale2x, in: CGRect(origin: .zero, size: narrowCanvas))
    try pinRegressionRequire(narrowCanvas == CGSize(width: 24, height: 50), "A narrow pin must retain an operable canvas")
    try pinRegressionRequire(narrowRect == CGRect(x: 7, y: 0, width: 10, height: 50), "20x100 pixels on Retina must draw at 10x50 points, centred without stretching")

    let cases: [(CGSize, CGFloat, CGSize, CGRect)] = [
        (narrow, 1, CGSize(width: 24, height: 100), CGRect(x: 2, y: 0, width: 20, height: 100)),
        (CGSize(width: 100, height: 20), 0.5, CGSize(width: 50, height: 24), CGRect(x: 0, y: 7, width: 50, height: 10)),
        (CGSize(width: 2, height: 2), 0.5, CGSize(width: 24, height: 24), CGRect(x: 11.5, y: 11.5, width: 1, height: 1)),
        (narrow, 0.6, CGSize(width: 24, height: 60), CGRect(x: 6, y: 0, width: 12, height: 60)),
        (CGSize(width: 1000, height: 400), 0.5, CGSize(width: 500, height: 200), CGRect(x: 0, y: 0, width: 500, height: 200))
    ]
    for (pixels, scale, canvas, rect) in cases {
        let actualSize = PinnedImageGeometry.windowSize(pixelSize: pixels, scale: scale)
        let actualRect = PinnedImageGeometry.imageRect(pixelSize: pixels, scale: scale, in: CGRect(origin: .zero, size: actualSize))
        try pinRegressionRequire(actualSize == canvas && actualRect == rect, "Tiny, horizontal, zoomed and ordinary pins must preserve their intended image dimensions")
        try pinRegressionRequire(abs(actualRect.width / actualRect.height - pixels.width / pixels.height) < 0.000001, "A pin must keep the source aspect ratio")
    }
    let movedBounds = CGRect(x: -10, y: 3, width: 24, height: 50)
    try pinRegressionRequire(PinnedImageGeometry.imageRect(pixelSize: narrow, scale: scale2x, in: movedBounds) == CGRect(x: -3, y: 3, width: 10, height: 50), "Image centring must respect the canvas origin")

    // Draw with the production image rectangle into a physical 2x canvas. The extra width must stay transparent.
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let source = CGContext(data: nil, width: 20, height: 100, bitsPerComponent: 8, bytesPerRow: 80, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "PinnedImageRegressionTests", code: 2) }
    source.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1))
    source.fill(CGRect(x: 0, y: 0, width: 20, height: 100))
    guard let image = source.makeImage() else { throw NSError(domain: "PinnedImageRegressionTests", code: 3) }
    var output = [UInt8](repeating: 0, count: 48 * 100 * 4)
    let rendered = output.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: 48, height: 100, bitsPerComponent: 8, bytesPerRow: 48 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.scaleBy(x: 2, y: 2)
        context.draw(image, in: narrowRect)
        return true
    }
    try pinRegressionRequire(rendered, "The isolated raster must render")
    for y in 0..<100 {
        for x in 0..<48 {
            let expectedAlpha: UInt8 = (14..<34).contains(x) ? 255 : 0
            try pinRegressionRequire(output[(y * 48 + x) * 4 + 3] == expectedAlpha, "Physical image footprint must be exactly 20x100 pixels with transparent interaction padding")
        }
    }

    func record(_ path: String) -> PinnedImageRecord { PinnedImageRecord(imagePath: path, windowFrame: "{{10, 10}, {24, 50}}", imageScale: 0.5, opacity: 0.8) }
    let first = record("/private/tmp/GaoJieTu-pin-plan/Pins/first.png")
    let second = record("/private/tmp/GaoJieTu-pin-plan/Pins/second.png")
    let duplicate = record("/private/tmp/GaoJieTu-pin-plan/Pins/./first.png")
    let records = [first, second, duplicate]
    let initial = PinnedImageRestorePlan.missing(records: records, activePersistentPaths: [])
    try pinRegressionRequire(initial.map(\.imagePath) == [first.imagePath, second.imagePath], "One restore must create each persistent identity once, in order")
    let repeated = PinnedImageRestorePlan.missing(records: records, activePersistentPaths: initial.map(\.imagePath))
    try pinRegressionRequire(repeated.isEmpty, "Repeated restore must create no duplicate persistent windows")
    let afterClosingSecond = PinnedImageRestorePlan.missing(records: records, activePersistentPaths: [first.imagePath])
    try pinRegressionRequire(afterClosingSecond.map(\.imagePath) == [second.imagePath], "Closing one persistent window must let the next restore recreate only that window")
    let normalizedActive = PinnedImageRestorePlan.missing(records: records, activePersistentPaths: [duplicate.imagePath])
    try pinRegressionRequire(normalizedActive.map(\.imagePath) == [second.imagePath], "Equivalent path spellings must identify the same persistent pin")
    let independentCopies = PinnedImageRestorePlan.missing(records: [first, second], activePersistentPaths: [])
    try pinRegressionRequire(independentCopies.count == 2, "Distinct explicitly saved image paths remain independent even when image bytes could match")
    try runPinnedImageRestoreLayoutRegressionTests()
    print("PASS PinnedImage: tiny/narrow/horizontal/1x/2x/zoom layout, exact 20x100 physical raster with transparent margins, idempotent persistent restore and closed-pin recovery; no GUI, capture, or real data access.")
}

/// Restored layout only: synthetic rectangles do not enumerate or test external displays.
func runPinnedImageRestoreLayoutRegressionTests() throws {
    let pixels = CGSize(width: 20, height: 100)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let fallback = CGRect(x: 80, y: 100, width: 24, height: 50)
    let invalidFrames = [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 80, height: 400), CGRect(x: 5000, y: 5000, width: 80, height: 400)]
    for saved in invalidFrames {
        let frame = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4, savedFrame: saved, fallbackFrame: fallback, visibleFrames: [screen])
        try pinRegressionRequire(frame == CGRect(x: 80, y: 100, width: 80, height: 400), "Invalid/off-screen positions must restore the 4x canvas instead of keeping the default 24x50 canvas")
        let image = PinnedImageGeometry.imageRect(pixelSize: pixels, scale: 4, in: CGRect(origin: .zero, size: frame.size))
        try pinRegressionRequire(image == CGRect(x: 0, y: 0, width: 80, height: 400), "Restored 4x image must fit fully inside its canvas")
    }
    let constrained = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4, savedFrame: .zero,
                                                       fallbackFrame: CGRect(x: 980, y: 780, width: 24, height: 50), visibleFrames: [screen])
    try pinRegressionRequire(constrained == CGRect(x: 920, y: 400, width: 80, height: 400) && screen.contains(constrained), "A grown fallback canvas must be repositioned within the visible area")
    let noPosition = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4, savedFrame: .zero, fallbackFrame: .null, visibleFrames: [screen])
    try pinRegressionRequire(noPosition == CGRect(x: 0, y: 0, width: 80, height: 400), "An invalid fallback must still produce finite visible geometry")

    let valid = CGRect(x: 200, y: 250, width: 80, height: 400)
    try pinRegressionRequire(PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4, savedFrame: valid, fallbackFrame: fallback, visibleFrames: [screen]) == valid, "A valid fitting saved frame must retain its exact placement")
    let undersized = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4,
                                                     savedFrame: CGRect(x: 200, y: 250, width: 24, height: 50), fallbackFrame: fallback, visibleFrames: [screen])
    try pinRegressionRequire(undersized == valid, "A visible legacy frame smaller than the restored image must grow without clipping")

    let small = CGRect(x: 120, y: 120, width: 24, height: 50)
    let restoredSmall = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 0.5, savedFrame: small, fallbackFrame: fallback, visibleFrames: [screen])
    try pinRegressionRequire(restoredSmall == small && PinnedImageGeometry.imageRect(pixelSize: pixels, scale: 0.5, in: CGRect(origin: .zero, size: restoredSmall.size)) == CGRect(x: 7, y: 0, width: 10, height: 50), "Legacy tiny canvases must retain the corrected 1:1 image aspect ratio")
    let ordinary = CGRect(x: 100, y: 100, width: 500, height: 200)
    try pinRegressionRequire(PinnedImageGeometry.restoredFrame(pixelSize: CGSize(width: 1000, height: 400), scale: 0.5, savedFrame: ordinary, fallbackFrame: fallback, visibleFrames: [screen]) == ordinary, "Ordinary saved frames must remain unchanged")
    let padded = CGRect(x: 200, y: 250, width: 100, height: 450)
    let restoredPadded = PinnedImageGeometry.restoredFrame(pixelSize: pixels, scale: 4, savedFrame: padded, fallbackFrame: fallback, visibleFrames: [screen])
    try pinRegressionRequire(restoredPadded == padded && PinnedImageGeometry.imageRect(pixelSize: pixels, scale: 4, in: CGRect(origin: .zero, size: restoredPadded.size)) == CGRect(x: 10, y: 25, width: 80, height: 400), "Existing larger canvases must keep padding without stretching the restored image")
    print("PASS PinnedImage restore layout: invalid/off-screen frames resize for restored scale, safe fallback placement, undersized legacy canvas growth and valid small/ordinary/padded frames; pure geometry, no GUI or device test.")
}
