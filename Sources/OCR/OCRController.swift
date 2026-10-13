import Foundation
import Combine
import AppKit

@MainActor
final class OCRController: ObservableObject {
    @Published private(set) var document: OCRDocument?
    @Published private(set) var progress: OCRProgress?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var supportedLanguages: [String] = []
    private var cancellation = OCRCancellationToken()
    private var task: Task<Void, Never>?
    private var sourceURLs: [UUID: URL] = [:]
    private var generation = UUID()
    private var ownedInputDirectories: [URL] = []
    private let service = OCRService()

    init() { supportedLanguages = (try? OCRService.supportedLanguages()) ?? [] }
    func updateLanguages(for level: OCRRecognitionLevel) { supportedLanguages = (try? OCRService.supportedLanguages(level: level)) ?? [] }

    func start(urls: [URL], options: OCROptions = OCROptions()) {
        guard !isRunning else { return }
        cancellation = OCRCancellationToken(); let token = cancellation
        generation = UUID(); let currentGeneration = generation
        isRunning = true; errorMessage = nil; progress = nil
        task = Task { [self] in
            do {
                let result = try await service.recognize(urls: urls, options: options, cancellation: token) { [weak self] value in Task { @MainActor in if self?.generation == currentGeneration { self?.progress = value } } }
                document = result
                sourceURLs = Dictionary(uniqueKeysWithValues: zip(result.sources, urls).map { ($0.0.id, $0.1) })
                let used = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
                for directory in ownedInputDirectories where !used.contains(directory.standardizedFileURL) { try? FileManager.default.removeItem(at: directory) }
                ownedInputDirectories.removeAll { !used.contains($0.standardizedFileURL) }
            } catch { errorMessage = error.localizedDescription }
            isRunning = false
        }
    }
    func cancel() { cancellation.cancel() }
    func retryFailed() {
        guard !isRunning, let current = document, !current.retryablePages.isEmpty else { return }
        cancellation = OCRCancellationToken(); let token = cancellation
        generation = UUID(); let currentGeneration = generation
        isRunning = true; errorMessage = nil
        task = Task { [self] in
            do { document = try await service.retryFailed(document: current, urlsBySourceID: sourceURLs, cancellation: token) { [weak self] value in Task { @MainActor in if self?.generation == currentGeneration { self?.progress = value } } } }
            catch { errorMessage = error.localizedDescription }
            isRunning = false
        }
    }
    func sourceURL(for id: UUID) -> URL? { sourceURLs[id] }
    func correctLine(id: UUID, text: String) throws {
        guard !isRunning, var updated = document else { throw OCRError.invalidInput("请等待识别任务完成后校正。") }
        guard text.count <= 10_000, !text.contains("\n"), !text.contains("\r") else { throw OCRError.invalidInput("每行校正文限10,000字符，不能将多行内容放入一个坐标框。") }
        for pageIndex in updated.pages.indices {
            guard let lineIndex = updated.pages[pageIndex].lines.firstIndex(where: { $0.id == id }) else { continue }
            var line = updated.pages[pageIndex].lines[lineIndex]
            if line.originalText == nil { line.originalText = line.text }
            line.text = text; line.userEdited = text != line.originalText
            updated.pages[pageIndex].lines[lineIndex] = line
            document = updated
            return
        }
        throw OCRError.invalidInput("识别批次已经变化，请重新打开校正窗口。")
    }
    func startImageData(_ data: Data, options: OCROptions = OCROptions()) {
        guard !isRunning else { return }
        do {
            guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw OCRError.resourceLimit("图片输入超过64MiB，请选择文件处理。") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoJieTu-OCR-Input-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("input-image")
            do { try data.write(to: url, options: .withoutOverwriting); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            ownedInputDirectories.append(directory)
            start(urls: [url], options: options)
        } catch { errorMessage = error.localizedDescription }
    }
    deinit { cancellation.cancel(); for directory in ownedInputDirectories { try? FileManager.default.removeItem(at: directory) } }
}
