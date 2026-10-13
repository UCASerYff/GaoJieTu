import Foundation
import CoreGraphics
import ImageIO

// Pixel statistics of the native output and an optional read-only series reference.
enum IconValidationError: Error { case failed(String) }
struct Statistics {
    let width: Int, height: Int, strokeBounds: CGRect, whitePixels: Int, equivalentInkArea: Double, grayPixels: Int, invalidGrayPixels: Int, nonTransparentBounds: CGRect
}
func stats(_ path: String) throws -> Statistics {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 1024, image.height == 1024 else { throw IconValidationError.failed("Invalid 1024px PNG") }
    var bytes = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
    let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)); return true
    }
    guard drew else { throw IconValidationError.failed("RGBA decode failed") }
    var minX = 1024, minY = 1024, maxX = -1, maxY = -1, white = 0, ink = 0.0, gray = 0, invalid = 0
    var alphaMinX = 1024, alphaMinY = 1024, alphaMaxX = -1, alphaMaxY = -1
    for y in 0..<1024 { for x in 0..<1024 {
        let index = (y * 1024 + x) * 4
        let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2]), a = Int(bytes[index + 3])
        if a > 0 { alphaMinX = min(alphaMinX, x); alphaMinY = min(alphaMinY, y); alphaMaxX = max(alphaMaxX, x); alphaMaxY = max(alphaMaxY, y) }
        if a == 255 && min(r, min(g, b)) >= 225 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); white += 1
        }
        if a == 255 { ink += max(0, Double(min(r, min(g, b)) - 119) / 136) }
        if a == 255 && r == 119 && g == 119 && b == 119 { gray += 1 }
        // These side bands are entirely outside the lettermark and inside the solid gray rounded square.
        if (300..<700).contains(y) && ((90..<240).contains(x) || (810..<930).contains(x)) && (r != 119 || g != 119 || b != 119 || a != 255) { invalid += 1 }
    } }
    return Statistics(width: image.width, height: image.height, strokeBounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), whitePixels: white, equivalentInkArea: ink, grayPixels: gray, invalidGrayPixels: invalid, nonTransparentBounds: CGRect(x: alphaMinX, y: alphaMinY, width: alphaMaxX - alphaMinX + 1, height: alphaMaxY - alphaMinY + 1))
}
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { throw IconValidationError.failed("Usage: VerifyIcon.swift AppIcon.png [reference.png]") }
let icon = try stats(arguments[1])
guard icon.invalidGrayPixels == 0, icon.grayPixels > 500_000, icon.nonTransparentBounds == CGRect(x: 82, y: 82, width: 860, height: 860),
      (294...300).contains(Int(icon.strokeBounds.width)), (598...604).contains(Int(icon.strokeBounds.height)),
      abs(icon.strokeBounds.midX - 512) < 2, abs(icon.strokeBounds.midY - 512) < 2 else { throw IconValidationError.failed("Icon geometry or pure gray validation failed: \(icon)") }
print("PASS: \(icon)")
if arguments.count > 2 {
    let reference = try stats(arguments[2])
    let ratio = icon.equivalentInkArea / reference.equivalentInkArea
    guard (0.95...1.05).contains(ratio) else { throw IconValidationError.failed("Visible ink area differs by more than 5% from the explicit series reference.") }
    print("Read-only reference: \(reference)")
    print(String(format: "Ink area ratio to reference: %.4f", ratio))
}
