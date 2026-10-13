import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO
import CoreImage

enum OCRExportFormat: String, CaseIterable { case text, markdown, json }

struct OCRPDFValidation {
    var pageCount: Int
    var verifiedTextLines: Int
    var preservedPageGeometry: Bool
}

enum OCRExporter {
    static func export(document: OCRDocument, format: OCRExportFormat, to destination: URL) throws {
        guard document.schemaVersion == 1 else { throw OCRError.invalidDocument }
        let data: Data
        switch format {
        case .text: data = Data(document.text.utf8)
        case .markdown:
            var output = "# OCR 结果\n\n引擎：\(document.engine)，revision \(document.engineRevision)\n\n"
            for source in document.sources {
                output += "## \(source.displayName.replacingOccurrences(of: "\n", with: " "))\n\n原件 SHA-256：`\(source.sha256)`\n\n"
                for page in document.pages where page.sourceID == source.id {
                    output += "### 第 \(page.pageNumber) 页（\(page.status.rawValue)）\n\n"
                    output += page.status == .completed ? page.text + "\n\n" : (page.failureReason ?? "未完成") + "\n\n"
                }
            }
            data = Data(output.utf8)
        case .json:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(document)
        }
        try writeNew(data, destination: destination)
        guard try Data(contentsOf: destination) == data else { throw OCRError.validation("重新读取导出内容不一致。") }
    }

    /// Rebuilds each page from its original PDF drawing, then draws invisible text at its real line position.
    /// Failed pages retain original visuals; only successful pages receive new text. Never overwrites the source.
    @discardableResult
    static func exportSearchablePDF(document: OCRDocument, sourceID: UUID, sourceURL: URL, to destination: URL, cancellation: OCRCancellationToken = OCRCancellationToken(), progress: @escaping @Sendable (OCRPDFExportProgress) -> Void = { _ in }) throws -> OCRPDFValidation {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard document.schemaVersion == 1, let source = document.sources.first(where: { $0.id == sourceID }), !source.sha256.isEmpty else { throw OCRError.invalidDocument }
        guard sourceURL.standardizedFileURL != destination.standardizedFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw OCRError.outputExists }
        guard try OCRService.sha256(url: sourceURL, limit: document.options.maxFileBytes) == source.sha256 else { throw OCRError.validation("原件摘要变化；原件未覆盖。") }
        guard (1...document.options.maxPages).contains(source.pageCount), source.byteCount <= document.options.maxFileBytes else { throw OCRError.resourceLimit("导出原件页数或大小超限。") }
        let original = try OCRService.readVerifiedData(sourceURL, source: source)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".gaojietu-ocr-\(UUID().uuidString).pdf")
        let rotatedTemp = destination.deletingLastPathComponent().appendingPathComponent(".gaojietu-ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp); try? FileManager.default.removeItem(at: rotatedTemp) }
        var defaultBox = document.pages.first(where: { $0.sourceID == sourceID && $0.status == .completed })?.mediaBox ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: temp as CFURL), let context = CGContext(consumer: consumer, mediaBox: &defaultBox, [kCGPDFContextCreator as String: "搞截图 · Apple Vision 本地 OCR"] as CFDictionary) else { throw OCRError.invalidInput("输出目录不可写。") }
        var contextClosed = false
        defer { if !contextClosed { context.closePDF() } }
        var originalPDF: CGPDFDocument?
        var image: CGImage?
        if source.isPDF {
            guard let provider = CGDataProvider(data: original as CFData), let pdf = CGPDFDocument(provider) else { throw OCRError.invalidInput("PDF 原件无法读取。") }
            originalPDF = pdf
        } else {
            guard let imageSource = CGImageSourceCreateWithData(original as CFData, nil), let raw = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw OCRError.invalidInput("图像原件无法读取。") }
            let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = props?[kCGImagePropertyOrientation] as? Int32 ?? 1
            let ci = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
            image = orientation == 1 ? raw : CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]).createCGImage(ci, from: ci.extent)
        }
        var geometry: [(CGRect, CGRect, Int)] = []
        let originalPDFKit = source.isPDF ? PDFDocument(data: original) : nil
        progress(OCRPDFExportProgress(phase: .writing, completedPages: 0, totalPages: source.pageCount))
        for number in 1...source.pageCount {
            guard !cancellation.isCancelled else { throw CancellationError() }
            let page = document.pages.first { $0.sourceID == sourceID && $0.pageNumber == number }
            let rawPage = originalPDF?.page(at: number)
            let media = rawPage?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: image?.width ?? 1, height: image?.height ?? 1)
            let crop = rawPage?.getBoxRect(.cropBox) ?? media
            let rotation = rawPage.map { ((Int($0.rotationAngle) % 360) + 360) % 360 } ?? 0
            let nativeText = originalPDFKit?.page(at: number - 1)?.string
            let hasNativeText = nativeText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let correctedNativePage = hasNativeText && page?.lines.contains(where: { $0.userEdited }) == true
            var pageInfo: [String: Any] = [kCGPDFContextMediaBox as String: rectData(media), kCGPDFContextCropBox as String: rectData(crop)]
            if let rawPage {
                pageInfo[kCGPDFContextBleedBox as String] = rectData(rawPage.getBoxRect(.bleedBox))
                pageInfo[kCGPDFContextTrimBox as String] = rectData(rawPage.getBoxRect(.trimBox))
                pageInfo[kCGPDFContextArtBox as String] = rectData(rawPage.getBoxRect(.artBox))
            }
            context.beginPDFPage(pageInfo as CFDictionary)
            if let rawPage {
                if correctedNativePage { try drawRasterizedOriginal(rawPage, media: media, maxPixels: document.options.maxPixelsPerPage, to: context) }
                else { context.drawPDFPage(rawPage) }
            }
            else if let image { context.draw(image, in: media) }
            if let page, page.status == .completed {
                // Keep existing native PDF text instead of creating duplicate text layers.
                if !hasNativeText || correctedNativePage {
                    for line in page.lines { guard !cancellation.isCancelled else { throw CancellationError() }; drawInvisible(line: line, context: context) }
                }
            }
            context.endPDFPage(); geometry.append((media, crop, rotation))
            progress(OCRPDFExportProgress(phase: .writing, completedPages: number, totalPages: source.pageCount))
        }
        context.closePDF(); contextClosed = true
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let pdf = PDFDocument(url: temp), pdf.pageCount == source.pageCount else { throw OCRError.validation("PDF 页数不一致。") }
        for (index, boxes) in geometry.enumerated() {
            guard let page = pdf.page(at: index) else { throw OCRError.validation("PDF 页面缺失。") }
            page.rotation = boxes.2
            page.setBounds(boxes.0, for: .mediaBox); page.setBounds(boxes.1, for: .cropBox)
        }
        guard pdf.write(to: rotatedTemp) else { throw OCRError.validation("PDF 写入失败。") }
        let validation = try validatePDF(at: rotatedTemp, sourceID: sourceID, document: document, geometry: geometry, cancellation: cancellation, progress: progress)
        guard !cancellation.isCancelled else { throw CancellationError() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedTemp.path)
        try FileManager.default.moveItem(at: rotatedTemp, to: destination)
        progress(OCRPDFExportProgress(phase: .finished, completedPages: source.pageCount, totalPages: source.pageCount))
        return validation
    }

    private static func drawInvisible(line: OCRLine, context: CGContext) {
        guard line.pageQuadrilateral.count == 4, !line.text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
        let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let glyph = CTLineGetBoundsWithOptions(ctLine, [.useGlyphPathBounds])
        guard glyph.width > 0, glyph.height > 0 else { return }
        let ll = line.pageQuadrilateral[0], lr = line.pageQuadrilateral[1], ul = line.pageQuadrilateral[3]
        let a = (lr.x - ll.x) / glyph.width, b = (lr.y - ll.y) / glyph.width
        let c = (ul.x - ll.x) / glyph.height, d = (ul.y - ll.y) / glyph.height
        context.saveGState()
        context.concatenate(CGAffineTransform(a: a, b: b, c: c, d: d, tx: ll.x - glyph.minX * a - glyph.minY * c, ty: ll.y - glyph.minX * b - glyph.minY * d))
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setTextDrawingMode(.invisible)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    /// Corrected native-PDF pages become original visual pixels + one corrected text layer.
    /// This avoids retaining a conflicting old native text layer beneath the new OCR text.
    private static func drawRasterizedOriginal(_ page: CGPDFPage, media: CGRect, maxPixels: Int, to output: CGContext) throws {
        let scale = min(2, sqrt(Double(maxPixels) / (media.width * media.height)), 12_000 / max(media.width, media.height))
        let width = max(1, Int(media.width * scale)), height = max(1, Int(media.height * scale))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OCRError.resourceLimit("校正PDF页面缓冲分配失败。") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(width) / media.width, y: CGFloat(height) / media.height); bitmap.translateBy(x: -media.minX, y: -media.minY)
        bitmap.drawPDFPage(page)
        guard let image = bitmap.makeImage() else { throw OCRError.invalidInput("校正PDF原页渲染失败。") }
        output.draw(image, in: media)
    }

    private static func validatePDF(at url: URL, sourceID: UUID, document: OCRDocument, geometry: [(CGRect, CGRect, Int)], cancellation: OCRCancellationToken, progress: @escaping @Sendable (OCRPDFExportProgress) -> Void) throws -> OCRPDFValidation {
        guard let pdf = PDFDocument(url: url), pdf.pageCount == geometry.count else { throw OCRError.validation("重新读取 PDF 失败。") }
        var verified = 0
        progress(OCRPDFExportProgress(phase: .validating, completedPages: 0, totalPages: geometry.count))
        for (index, expected) in geometry.enumerated() {
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard let page = pdf.page(at: index), approximatelyEqual(page.bounds(for: .mediaBox), expected.0), approximatelyEqual(page.bounds(for: .cropBox), expected.1), page.rotation == expected.2 else { throw OCRError.validation("页面框或旋转没有保留。") }
            if let ocrPage = document.pages.first(where: { $0.sourceID == sourceID && $0.pageNumber == index + 1 && $0.status == .completed }) {
                for line in ocrPage.lines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    let token = searchToken(line.text)
                    guard !token.isEmpty else { continue }
                    guard let selection = page.selection(for: line.pageBoundingBox.insetBy(dx: -1, dy: -1)), selection.string?.localizedCaseInsensitiveContains(token) == true else { throw OCRError.validation("第 \(index + 1) 页文本层选取位置不一致。") }
                    guard pdf.findString(token, withOptions: [.caseInsensitive]).contains(where: { $0.pages.contains(page) }) else { throw OCRError.validation("第 \(index + 1) 页文本层不可检索。") }
                    verified += 1
                }
            }
            progress(OCRPDFExportProgress(phase: .validating, completedPages: index + 1, totalPages: geometry.count))
        }
        return OCRPDFValidation(pageCount: pdf.pageCount, verifiedTextLines: verified, preservedPageGeometry: true)
    }

    private static func searchToken(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        return words.first(where: { $0.count >= 2 }) ?? words.first ?? ""
    }
    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 0.1 && abs(a.minY - b.minY) < 0.1 && abs(a.width - b.width) < 0.1 && abs(a.height - b.height) < 0.1 }
    private static func rectData(_ rect: CGRect) -> Data { var rect = rect; return Data(bytes: &rect, count: MemoryLayout<CGRect>.size) }
    private static func writeNew(_ data: Data, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw OCRError.outputExists }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".gaojietu-ocr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
