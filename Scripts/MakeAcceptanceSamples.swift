import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import CryptoKit

// Offline sample authoring only: no app launch, screen capture, network, audio playback or registration.
// Output is deliberately restricted to this project's ignored TestResults/Acceptance directory.
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectDirectory = scriptDirectory.deletingLastPathComponent()
let output = projectDirectory.appendingPathComponent("TestResults/Acceptance", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
enum SampleError: Error { case failed(String) }

let title = "搞截图本地验收样本"
let subtitle = "LOCAL SAMPLE - only synthetic test content"
let left = [
    "第一列：中文与数字",
    "这是一张自建的截图与文字识别样本。",
    "屏幕坐标使用点，图像尺寸使用像素。",
    "截图前应排除本应用的选择遮罩。",
    "请核对中文、英文、数字与阅读顺序。",
    "固定页眉和侧栏可能影响长截图拼接。",
    "只有明确确认后才处理跨应用请求。",
    "文件保存后重新读取并核验内容。",
    "本地识别不会默认上传图片或文字。",
    "测试编号：20261013，校验数字：0123456789。",
    "白底黑字，两个独立列区，未含个人资料。",
    "中文结束。"
]
let right = [
    "Column Two: English and Numbers",
    "Capture only the selected test window.",
    "Keep points and physical pixels separate.",
    "The original image must remain unchanged.",
    "Pause when the target window changes.",
    "Repeated content needs a seam preview.",
    "Local OCR runs without a network upload.",
    "Read the exported file again to verify it.",
    "Sample ID: GAO-CAPTURE-001.",
    "Digits: 0123456789; RGB: 119,119,119.",
    "Only built-in display and trackpad assumed.",
    "English column ends here."
]
let expected = ([title, subtitle] + left + right).joined(separator: "\n") + "\n"
try expected.write(to: output.appendingPathComponent("known-text.expected.txt"), atomically: true, encoding: .utf8)
let normalization = expected.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
try normalization.write(to: output.appendingPathComponent("known-text.expected.normalized.txt"), atomically: true, encoding: .utf8)
let sampleText = """
搞截图本地验收文本
This file is synthetic and contains no user information.
任务：区域截图、窗口截图、滚动拼接、取色、OCR、录屏及录音。
Verification digits: 0123456789
Color reference: #777777; RGB 119,119,119; sRGB.

"""
try sampleText.write(to: output.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)

func text(_ value: String, at point: CGPoint, size: CGFloat, bold: Bool = false, context: CGContext) {
    let base = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    let attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): base,
                                                                   NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1)])
    context.textMatrix = .identity; context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
}
let width = 1600, height = 1100
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SampleError.failed("Image context") }
context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
text(title, at: CGPoint(x: 72, y: 1004), size: 48, bold: true, context: context)
text(subtitle, at: CGPoint(x: 74, y: 947), size: 28, context: context)
for (index, line) in left.enumerated() { text(line, at: CGPoint(x: 74, y: 858 - index * 57), size: index == 0 ? 34 : 28, bold: index == 0, context: context) }
for (index, line) in right.enumerated() { text(line, at: CGPoint(x: 838, y: 858 - index * 57), size: index == 0 ? 32 : 28, bold: index == 0, context: context) }
guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("known-text.png") as CFURL, "public.png" as CFString, 1, nil) else { throw SampleError.failed("PNG encode") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { throw SampleError.failed("PNG write") }

// Author pages with explicit non-zero boxes. Page 2's content is counter-rotated,
// then its /Rotate is set to 90, so a conforming PDF renderer displays upright text.
let rawPDF = NSMutableData()
guard let consumer = CGDataConsumer(data: rawPDF), let pdfContext = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "GaoJieTu synthetic acceptance generator", kCGPDFContextTitle: "Synthetic OCR page boxes and rotation"] as CFDictionary) else { throw SampleError.failed("PDF context") }
let pageBoxes: [(CGRect, CGRect, Int)] = [
    (CGRect(x: 31, y: 47, width: 760, height: 1000), CGRect(x: 61, y: 87, width: 700, height: 920), 0),
    (CGRect(x: 29, y: 43, width: 1000, height: 760), CGRect(x: 69, y: 83, width: 920, height: 680), 90)
]
func rectData(_ rect: CGRect) -> CFData { var copy = rect; return withUnsafeBytes(of: &copy) { Data($0) } as CFData }
for (media, crop, rotation) in pageBoxes {
    pdfContext.beginPDFPage([kCGPDFContextMediaBox: rectData(media), kCGPDFContextCropBox: rectData(crop)] as CFDictionary)
    pdfContext.setFillColor(CGColor(gray: 1, alpha: 1)); pdfContext.fill(media)
    pdfContext.saveGState(); pdfContext.translateBy(x: crop.midX, y: crop.midY)
    if rotation == 90 { pdfContext.rotate(by: .pi / 2) }
    let viewerWidth = rotation == 90 ? crop.height : crop.width
    let viewerHeight = rotation == 90 ? crop.width : crop.height
    let factor = min((viewerWidth - 44) / CGFloat(width), (viewerHeight - 44) / CGFloat(height))
    let drawWidth = CGFloat(width) * factor, drawHeight = CGFloat(height) * factor
    pdfContext.interpolationQuality = .high
    pdfContext.draw(image, in: CGRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
    pdfContext.restoreGState(); pdfContext.endPDFPage()
}
pdfContext.closePDF()
guard let document = PDFDocument(data: rawPDF as Data), document.pageCount == 2 else { throw SampleError.failed("PDF readback") }
document.page(at: 1)?.rotation = 90
let fixedDate = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "搞截图自建双页样本", PDFDocumentAttribute.authorAttribute: "GaoJieTu acceptance fixture", PDFDocumentAttribute.creationDateAttribute: fixedDate, PDFDocumentAttribute.modificationDateAttribute: fixedDate]
let pdfURL = output.appendingPathComponent("two-pages.pdf")
guard document.write(to: pdfURL), let reloaded = PDFDocument(url: pdfURL), reloaded.pageCount == 2 else { throw SampleError.failed("PDF write") }
var expectedPages: [[String: Any]] = []
for index in 0..<2 {
    guard let page = reloaded.page(at: index) else { throw SampleError.failed("PDF page missing") }
    let media = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
    guard media.minX != 0, media.minY != 0, crop.minX != 0, crop.minY != 0, page.rotation == pageBoxes[index].2,
          (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SampleError.failed("PDF boxes/rotation changed or an unexpected text layer exists") }
    expectedPages.append(["page": index + 1, "text": expected, "rotation": page.rotation,
                          "mediaBox": [media.minX, media.minY, media.width, media.height], "cropBox": [crop.minX, crop.minY, crop.width, crop.height],
                          "content": "raster only; no pre-existing searchable text layer"])
}
try JSONSerialization.data(withJSONObject: ["pages": expectedPages], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("two-pages.expected.json"))

let rows = (1...240).map { index in
    "<article class=\"row\"><strong>ROW \(String(format: "%03d", index))</strong><span>第 \(index) 行：自建滚动样本，接缝去重应保留每个编号一次。</span><code>CHECK \(String(format: "%06d", index * 7919 % 1000000))</code><p>Capture sample line \(index). Keep overlap, pause on target changes, and inspect repeated content.</p></article>"
}.joined(separator: "\n")
let html = """
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; media-src 'none'">
<title>搞截图 - 本地滚动验收样本</title><style>
body{font:17px system-ui,sans-serif;margin:0;background:#f5f5f5;color:#171717;padding-top:120px}header{position:fixed;top:0;left:0;right:0;background:#fff;border-bottom:2px solid #777;padding:18px 28px;z-index:2}h1{font-size:23px;margin:0 0 9px}main{max-width:960px;margin:0 auto;padding:16px 28px}.row{margin:0 0 16px;padding:24px;background:white;border-left:8px solid #777;min-height:90px}.row:nth-child(3n){border-color:#286080}.row:nth-child(5n){border-color:#735029}.row strong{display:inline-block;width:110px}.row code{float:right}.row p{font-size:15px;color:#444;margin:16px 0 0}.static-header{padding-top:0}.static-header header{position:static}button{margin-left:12px}footer{padding:32px;background:#fff;font-weight:700}
</style><header><h1>搞截图本地滚动验收 - 240行 - 无网络内容</h1><label><input id="fixed" type="checkbox" checked> 固定页眉</label><label style="margin-left:18px"><input id="animate" type="checkbox"> 动画计数</label><span id="counter" style="margin-left:16px">0</span><button id="top">回到顶部</button></header>
<main>\(rows)<footer>END 240 - 已到滚动边界。请检查 ROW 001 到 ROW 240 每个编号恰好出现一次。</footer></main>
<script>let count=0;document.querySelector('#fixed').onchange=e=>document.body.classList.toggle('static-header',!e.target.checked);document.querySelector('#top').onclick=()=>window.scrollTo({top:0,behavior:'instant'});setInterval(()=>{if(document.querySelector('#animate').checked)document.querySelector('#counter').textContent=String(++count)},100);</script></html>
"""
try html.write(to: output.appendingPathComponent("long-sample.html"), atomically: true, encoding: .utf8)
let guide = """
# 搞截图自建样本使用说明

本目录仅含生成的测试资料，受 TestResults/ 忽略规则保护。生成过程不会打开任何GUI、录制屏幕、播放声音、联网或安装应用。

- known-text.png：1600x1100，白底黑字，中英双栏。期望阅读顺序：标题、副标题、左栏从上到下、右栏从上到下。精确文本见 known-text.expected.txt。
- known-text.expected.normalized.txt：NFKC后去除Unicode空白，供字符错误率核对。CER = Levenshtein编辑距离 / 期望字符数；请分别记录语言组合、accurate/fast、耗时与漏列，不把单次成功当全部场景通过。
- two-pages.pdf：两页仅栅格图像，原本没有可搜索文字层。两页均有非零MediaBox/CropBox，第2页 /Rotate=90，内容已反向绘制使查看器中应当直立。页级文本、边界与旋转见 two-pages.expected.json。导出的可搜索PDF需再检查页数、盒子、旋转及查找/选择位置。
- sample.txt：供TextEdit/Terminal显式打开的合成文字，不含用户资料。
- long-sample.html：只在本机打开，无网络请求，240行唯一编号与校验数；固定页眉可关闭，动画计数默认关闭。手动滚动和自动滚动分别测试，核对每个ROW编号仅出现一次。建议关闭页眉或只选择内容区；保留页眉时应检出低置信度并提示复核。
- AcceptanceSample.app：本项目原生自有测试窗口（如编译成功），bundleID com.gaoseries.GaoJieTu.AcceptanceSample。没有安装到/Applications，没有启动或登记。手动双击后才出现可滚动240行、固定页眉开关、动画计数及“播放440Hz原创测试音”按钮；声音默认关闭，只向选定系统输出设备发声，关闭窗口自动停止。它不请求录屏、麦克风、辅助功能等权限。

真正验收时先协调前台时段并解锁Mac；应用与系统安全权限由用户本人处理。只截取这些自建窗口，不曝光桌面/浏览器/终端中的个人内容。Safari、TextEdit、Terminal、Finder四种实际窗口须分别记录结果。系统内录与麦克风要实际听音分开验收，音频文件存在不能证明声音正确。
"""
try guide.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
var files: [[String: Any]] = []
for name in ["known-text.png", "known-text.expected.txt", "known-text.expected.normalized.txt", "two-pages.pdf", "two-pages.expected.json", "sample.txt", "long-sample.html", "README.md"] {
    let data = try Data(contentsOf: output.appendingPathComponent(name))
    files.append(["name": name, "byteCount": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
}
try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "syntheticOnly": true, "expectedNormalizedCharacters": normalization.count, "files": files], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
for name in ["known-text.png", "known-text.expected.txt", "known-text.expected.normalized.txt", "two-pages.pdf", "two-pages.expected.json", "sample.txt", "long-sample.html", "README.md", "manifest.json"] {
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.appendingPathComponent(name).path)
}
print("Prepared synthetic samples only; known-text=1600x1100, normalized expected characters=\(normalization.count), PDF=2 pages with nonzero boxes and page2 Rotate90, HTML=240 rows.")
