import Foundation
import CoreText
import CoreGraphics
import ImageIO
import CryptoKit

// Reproducible, native vector composition for the Gao series wordmark system.
// Usage: swift -module-cache-path /private/tmp/GaoJieTuModuleCache Scripts/GenerateIcon.swift [font.ttf] [AppIcon.png]
// Font registration has process scope only. No font is installed or changed on the user's Mac.
// Font: unmodified Ma Shan Zheng, SIL Open Font License 1.1. See Scripts/Fonts/OFL.txt.
enum GaoIconError: Error { case invalid(String) }
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectDirectory = scriptDirectory.deletingLastPathComponent()
let fontURL = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : scriptDirectory.appendingPathComponent("Fonts/MaShanZheng-Regular.ttf")
let outputURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : projectDirectory.appendingPathComponent("Assets/AppIcon.png")
let expectedFontSHA256 = "6d2546bb189c732a8ca29af9e22457b152387d158aa459e4ac2ce1e51788b7fb"
let fontData = try Data(contentsOf: fontURL)
let fontSHA256 = SHA256.hash(data: fontData).map { String(format: "%02x", $0) }.joined()
guard fontSHA256 == expectedFontSHA256 else { throw GaoIconError.invalid("Font hash differs from the pinned upstream revision.") }
var fontError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError),
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
      let descriptor = descriptors.first else { throw GaoIconError.invalid("Unable to register the licensed font in this process.") }
defer { CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, nil) }
let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
guard CTFontCopyPostScriptName(font) as String == "MaShanZheng-Regular" else { throw GaoIconError.invalid("Unexpected font face.") }
let originalPaths: [CGPath] = try ["截", "图"].map { text in
    var characters = Array(text.utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1), glyphs[0] != 0,
          let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { throw GaoIconError.invalid("Missing requested Chinese glyph.") }
    return path
}
// Compensate the denser 截/图 pair's stroke weight in vector space. Font data stays unchanged.
// This is a boolean subtraction of a narrow contour, with actual bounds measured afterward.
let paths = originalPaths.map { path in
    path.subtracting(path.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 2), using: .winding)
}
let bounds = paths.map(\.boundingBoxOfPath)
// Measurements use actual glyph outlines, never em boxes or padded raster canvases.
// Existing GaoWenJian's visible wordmark is about 298 x 602 px and centered at (512, 512).
let inkWidth: CGFloat = 298, inkHeight: CGFloat = 602
let glyphScaleX = inkWidth / (bounds.map(\.width).max() ?? 1)
let naturalGap: CGFloat = 50
let glyphScaleY = inkHeight / (bounds.reduce(0) { $0 + $1.height } + naturalGap)
let interGlyphGap = naturalGap * glyphScaleY
let canvasSize = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8,
                              bytesPerRow: canvasSize * 4, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GaoIconError.invalid("Unable to create RGBA icon.") }
context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
context.setFillColor(CGColor(colorSpace: colorSpace, components: [119.0/255, 119.0/255, 119.0/255, 1])!)
context.addPath(CGPath(roundedRect: CGRect(x: 82, y: 82, width: 860, height: 860), cornerWidth: 189, cornerHeight: 189, transform: nil))
context.fillPath()
context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
var nextTop = CGFloat(canvasSize) / 2 + inkHeight / 2
for (index, path) in paths.enumerated() {
    let box = bounds[index]
    let drawnWidth = box.width * glyphScaleX, drawnHeight = box.height * glyphScaleY
    var transform = CGAffineTransform(a: glyphScaleX, b: 0, c: 0, d: glyphScaleY,
                                     tx: 512 - drawnWidth / 2 - box.minX * glyphScaleX,
                                     ty: nextTop - drawnHeight - box.minY * glyphScaleY)
    guard let transformed = path.copy(using: &transform) else { throw GaoIconError.invalid("Unable to transform glyph outline.") }
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.addPath(transformed); context.fillPath()
    nextTop -= drawnHeight + interGlyphGap
}
guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else { throw GaoIconError.invalid("Unable to encode icon PNG.") }
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
      let reloaded = CGImageSourceCreateImageAtIndex(source, 0, nil), reloaded.width == 1024, reloaded.height == 1024 else { throw GaoIconError.invalid("Encoded icon failed readback.") }
print("Generated 1024px transparent icon; background=#777777 860x860 r189; actual outline=298x602 with vector stroke compensation; fontSHA256=\(fontSHA256).")
