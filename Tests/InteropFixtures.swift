import AppKit
import Foundation

/// Durable synthetic codec fixtures. No screen, audio, clipboard, private inputs or external app launches.
/// Consumers must validate each pair at manifest.createdAt (the fixed test clock), not the current wall clock.
@MainActor
func runInteropFixtureGeneration(directory: URL) async throws {
    let clock = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    let sourceBundle = "com.gaoseries.GaoCaoZuo"
    _ = try GaoPrivateIO.directory(directory, create: true, requirePrivate: true)
    let scratch = directory.appendingPathComponent(".Synthetic-\(UUID().uuidString)", isDirectory: true)
    _ = try GaoPrivateIO.directory(scratch, create: true, requirePrivate: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let exchange = directory.appendingPathComponent("Exchange", isDirectory: true)
    struct Pair: Codable { var name: String; var request: String; var result: String; var expectedStatus: String }
    var pairs: [Pair] = []

    func makeImage(_ name: String, lines: [String]) throws -> (URL, CGImage) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw AppIssue.message("互通样本图像内存分配失败。") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 800).fill()
        for (index, line) in lines.enumerated() { line.draw(at: NSPoint(x: 100, y: 620 - index * 130), withAttributes: [.font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black]) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage, let bytes = rep.representation(using: .png, properties: [:]) else { throw AppIssue.message("互通样本图像编码失败。") }
        let url = scratch.appendingPathComponent(name + ".png"); try bytes.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (url, image)
    }
    func request(_ action: String, files: [GaoOutgoingFile] = [], parameters: [String: GaoJSONValue] = [:]) throws -> (URL, GaoValidatedPackage) {
        let url = try GaoActionWriter.writeRequest(action: action, items: files, parameters: parameters, sourceBundleID: sourceBundle, targetBundleID: GaoActionContract.bundleID, exchangeRoot: exchange, now: clock)
        return (url, try GaoActionTransport.receive(packageURL: url, exchangeRoot: exchange, now: clock))
    }
    func savePair(_ name: String, requestURL: URL, request: GaoValidatedPackage, status: String, files: [GaoOutgoingFile] = [], errorCode: String? = nil, provenance: [String: GaoJSONValue] = [:]) throws {
        var provenance = provenance; provenance["codecFixture"] = .bool(true)
        provenance["fixtureClock"] = .string("2026-10-12T12:00:00Z")
        let resultURL = try GaoActionWriter.writeResult(inReplyTo: request.manifest, status: status, items: files, errorCode: errorCode, provenance: provenance, exchangeRoot: exchange, now: clock)
        let checked = try GaoActionTransport.receive(packageURL: resultURL, exchangeRoot: exchange, expectedTargetBundleID: sourceBundle, now: clock)
        guard checked.manifest.inReplyTo == request.manifest.requestID, checked.manifest.parameters.isEmpty, checked.manifest.status == status else { throw AppIssue.message("互通结果关联校验失败。") }
        let prefix = directory.path + "/"
        pairs.append(Pair(name: name, request: String(requestURL.path.dropFirst(prefix.count)), result: String(resultURL.path.dropFirst(prefix.count)), expectedStatus: status))
        try? FileManager.default.removeItem(at: checked.stagingURL)
        try? FileManager.default.removeItem(at: request.stagingURL)
    }

    let english = try makeImage("known-english", lines: ["Hello OCR 2026", "Synthetic codec fixture"])
    let chinese = try makeImage("known-chinese", lines: ["中文测试 你好世界", "Local OCR only"])
    let broken = scratch.appendingPathComponent("known-broken.png")
    try Data("intentional invalid synthetic image".utf8).write(to: broken, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: broken.path)

    func ocrPair(_ name: String, inputs: [URL], expected: String) async throws {
        let formats = ["text", "markdown", "json", "searchablePDF"]
        let inputFiles = inputs.map { GaoOutgoingFile(url: $0, uti: "public.png") }
        let (url, staged) = try request("ocr.files", files: inputFiles, parameters: ["languages": .array([.string("zh-Hans"), .string("en-US")]), "outputs": .array(formats.map(GaoJSONValue.string))])
        let document = try await OCRService().recognize(urls: staged.stagedItems.map(\.url))
        let actual = document.successfulPages == 0 ? "failed" : document.isPartial ? "partial" : "completed"
        guard actual == expected else { throw AppIssue.message("互通OCR样本实际状态与预期不一致：\(actual)") }
        var outputs: [GaoOutgoingFile] = []
        var provenanceSources: [GaoJSONValue] = []
        var provenanceOutputs: [GaoJSONValue] = []
        for (index, source) in document.sources.enumerated() {
            var part = document; part.sources = [source]; part.pages = document.pages.filter { $0.sourceID == source.id }
            var outputIDs: [GaoJSONValue] = []
            if expected != "failed" {
                for format in formats {
                    if format == "searchablePDF", part.successfulPages == 0 { continue }
                    let ext = format == "searchablePDF" ? "pdf" : format == "markdown" ? "md" : format == "json" ? "json" : "txt"
                    let output = scratch.appendingPathComponent("\(name)-\(index + 1).\(ext)")
                    if format == "searchablePDF" { _ = try OCRExporter.exportSearchablePDF(document: part, sourceID: source.id, sourceURL: staged.stagedItems[index].url, to: output) }
                    else { try OCRExporter.export(document: part, format: OCRExportFormat(rawValue: format)!, to: output) }
                    let item = GaoOutgoingFile(url: output, uti: format == "searchablePDF" ? "com.adobe.pdf" : format == "json" ? "public.json" : format == "markdown" ? "net.daringfireball.markdown" : "public.utf8-plain-text")
                    outputs.append(item); outputIDs.append(.string(item.id))
                    provenanceOutputs.append(.object(["sourceID": .string(source.id.uuidString), "sourceItemID": .string(staged.stagedItems[index].item.id), "sourceSHA256": .string(staged.stagedItems[index].item.sha256), "resultItemID": .string(item.id), "format": .string(format)]))
                }
            }
            provenanceSources.append(.object(["sourceID": .string(source.id.uuidString), "sourceItemID": .string(staged.stagedItems[index].item.id), "sourceSHA256": .string(staged.stagedItems[index].item.sha256), "outputItemIDs": .array(outputIDs), "pages": .array(part.pages.map { .object(["pageNumber": .number(Double($0.pageNumber)), "status": .string($0.status.rawValue), "lineCount": .number(Double($0.lines.count))]) })]))
        }
        try savePair(name, requestURL: url, request: staged, status: actual, files: outputs, errorCode: actual == "completed" ? nil : "pageFailed", provenance: ["engine": .string(document.engine), "engineRevision": .number(Double(document.engineRevision)), "sources": .array(provenanceSources), "outputs": .array(provenanceOutputs), "networkUsed": .bool(false)])
    }
    try await ocrPair("ocr-multiple-inputs-outputs-completed", inputs: [english.0, chinese.0], expected: "completed")
    try await ocrPair("ocr-multiple-inputs-outputs-partial", inputs: [english.0, broken], expected: "partial")
    try await ocrPair("ocr-invalid-input-failed", inputs: [broken], expected: "failed")

    let (pinURL, pin) = try request("images.pin", files: [.init(url: english.0, uti: "public.png")])
    try savePair("pin-source-association", requestURL: pinURL, request: pin, status: "completed", provenance: ["workflowState": .string("opened"), "sourceItemID": .string(pin.manifest.items[0].id), "sourceSHA256": .string(pin.manifest.items[0].sha256)])
    let (annotationURL, annotation) = try request("images.annotate", files: [.init(url: english.0, uti: "public.png")])
    let annotationDocument = AnnotationDocument(image: english.1)
    annotationDocument.add(AnnotationLayer(tool: .rectangle, points: [CGPoint(x: 70, y: 50), CGPoint(x: 1250, y: 700)]))
    let flattened = scratch.appendingPathComponent("actual-flattened-annotation.png"); try annotationDocument.export(to: flattened)
    let annotationOutput = GaoOutgoingFile(url: flattened, uti: "public.png")
    try savePair("annotation-source-association", requestURL: annotationURL, request: annotation, status: "completed", files: [annotationOutput], provenance: ["sourceItemID": .string(annotation.manifest.items[0].id), "sourceSHA256": .string(annotation.manifest.items[0].sha256), "outputItemIDs": .array([.string(annotationOutput.id)]), "flattened": .bool(true)])

    for action in ["capture.region", "capture.window", "capture.display"] {
        let (url, staged) = try request(action, parameters: ["delaySeconds": .number(2)])
        try savePair("delay-\(action)-synthetic-pixels", requestURL: url, request: staged, status: "completed", files: [.init(url: english.0, uti: "public.png")], provenance: ["pixelWidth": .number(Double(english.1.width)), "pixelHeight": .number(Double(english.1.height)), "scale": .number(1), "colorSpace": .string("sRGB"), "source": .string("codecfixture.synthetic-not-screen-capture"), "requestedDelaySeconds": .number(2)])
    }

    let originalText = scratch.appendingPathComponent("translation-input.txt"), translatedText = scratch.appendingPathComponent("translation-fixture.txt")
    try Data("Hello world".utf8).write(to: originalText); try Data("你好世界".utf8).write(to: translatedText)
    let (translationURL, translation) = try request("text.translate", files: [.init(url: originalText, uti: "public.utf8-plain-text")], parameters: ["sourceLanguage": .string("en"), "targetLanguage": .string("zh-Hans")])
    try savePair("translation-network-declaration-codec-only", requestURL: translationURL, request: translation, status: "completed", files: [.init(url: translatedText, uti: "public.utf8-plain-text")], provenance: ["provider": .string("codecfixture.synthetic-translation"), "networkUsed": .bool(false), "sourceItemID": .string(translation.manifest.items[0].id), "sourceSHA256": .string(translation.manifest.items[0].sha256)])
    let (cancelURL, cancelled) = try request("capture.region")
    try savePair("user-cancelled", requestURL: cancelURL, request: cancelled, status: "cancelled", errorCode: "userCancelled", provenance: ["workflowState": .string("cancelled")])

    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(pairs)
    let manifestURL = directory.appendingPathComponent("pairs.json")
    try encoded.write(to: manifestURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    try Data("仅自建协议样本；固定测试时钟2026-10-12T12:00:00Z。消费者以每包manifest.createdAt验证TTL。OCR和标注栅格真实执行；capture/pin/translation结果为明确codecFixture，不能记作屏幕捕获、贴图窗口、实际翻译或GUI端到端验收。\n".utf8).write(to: directory.appendingPathComponent("FIXTURE-NOTICE.txt"), options: .atomic)
    print("Interop fixtures: \(pairs.count) request/result pairs generated and provider-validated; fixed-clock synthetic codec evidence only")
}
