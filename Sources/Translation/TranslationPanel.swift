import SwiftUI
import Translation

struct LocalTranslationResult: Codable, Sendable {
    var sourceText: String
    var translatedText: String
    var sourceLanguage: String
    var targetLanguage: String
    var provider = "Apple Translation"
    var contentSentToCloud = false
    var languagePackageDownloadRequested = false
    var networkUsed: Bool { contentSentToCloud || languagePackageDownloadRequested }
    var createdAt = Date()
}

enum LocalTranslationError: LocalizedError {
    case requiresMacOS15, unsupportedPair, packageNotInstalled, emptyText, tooLong
    var errorDescription: String? {
        switch self {
        case .requiresMacOS15: return "本机翻译需要 macOS 15 或更新版本。"
        case .unsupportedPair: return "系统本机翻译不支持这个语言组合。"
        case .packageNotInstalled: return "语言包尚未安装。请在翻译窗口中主动下载后使用。"
        case .emptyText: return "请输入要翻译的文字。"
        case .tooLong: return "单次翻译限 100,000 个字符，请分段。"
        }
    }
}

enum LocalTranslationService {
    /// Headless translation cannot prompt or download. macOS 15–25 use TranslationPanel's managed session.
    @available(macOS 26.0, *)
    static func translateInstalled(text: String, sourceLanguage: String, targetLanguage: String) async throws -> LocalTranslationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationError.emptyText }
        guard text.count <= 100_000 else { throw LocalTranslationError.tooLong }
        let source = Locale.Language(identifier: sourceLanguage), target = Locale.Language(identifier: targetLanguage)
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { throw status == .supported ? LocalTranslationError.packageNotInstalled : LocalTranslationError.unsupportedPair }
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        return LocalTranslationResult(sourceText: response.sourceText, translatedText: response.targetText, sourceLanguage: response.sourceLanguage.minimalIdentifier, targetLanguage: response.targetLanguage.minimalIdentifier)
    }
}

/// Explicit input only: no global selection watcher and no automatic clipboard reads.
struct TranslationPanel: View {
    let initialText: String
    let sourceLanguage: String
    let targetLanguage: String
    let identity: TranslationOperationIdentity
    let onCompletion: (LocalTranslationResult, UUID, String?) -> Void
    let onCancel: (UUID, String?) -> Void
    init(initialText: String = "", sourceLanguage: String = "auto", targetLanguage: String = "en", operationID: UUID, requestID: String? = nil, onCompletion: @escaping (LocalTranslationResult, UUID, String?) -> Void = { _, _, _ in }, onCancel: @escaping (UUID, String?) -> Void = { _, _ in }) {
        self.initialText = initialText; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        identity = TranslationOperationIdentity(operationID: operationID, requestID: requestID)
        self.onCompletion = onCompletion; self.onCancel = onCancel
    }
    var body: some View {
        if #available(macOS 15.0, *) {
            SystemTranslationPanel(initialText: initialText, initialSource: sourceLanguage, initialTarget: targetLanguage, identity: identity, onCompletion: onCompletion, onCancel: onCancel)
        } else {
            VStack(alignment: .leading, spacing: 12) { Text("本机翻译").font(.title2); Text(LocalTranslationError.requiresMacOS15.localizedDescription); Text("OCR 仍可离线使用；本应用不会自动将文字提交到云服务。").foregroundStyle(.secondary) }.padding(24)
        }
    }
}

@available(macOS 15.0, *)
private struct SystemTranslationPanel: View {
    let onCompletion: (LocalTranslationResult, UUID, String?) -> Void
    let onCancel: (UUID, String?) -> Void
    @State private var identity: TranslationOperationIdentity
    @State private var text: String
    @State private var source: String
    @State private var target: String
    @State private var languages: [String] = []
    @State private var availabilityText = "正在查询本机支持语言…"
    @State private var pairStatus: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var translated = ""
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var attempt: TranslationAttempt?
    @State private var currentSession: TranslationSession?
    @State private var availabilityGeneration = UUID()

    init(initialText: String, initialSource: String, initialTarget: String, identity: TranslationOperationIdentity, onCompletion: @escaping (LocalTranslationResult, UUID, String?) -> Void, onCancel: @escaping (UUID, String?) -> Void) {
        _text = State(initialValue: initialText); _source = State(initialValue: initialSource); _target = State(initialValue: initialTarget)
        _identity = State(initialValue: identity)
        self.onCompletion = onCompletion; self.onCancel = onCancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本机翻译").font(.title2)
            Text("文字在本机处理。系统可能先请求下载语言包；不会默认启用云翻译。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("原文", selection: $source) { Text("自动检测").tag("auto"); ForEach(languages, id: \.self) { code in Text(languageName(code)).tag(code) } }
                Picker("译文", selection: $target) { ForEach(languages, id: \.self) { code in Text(languageName(code)).tag(code) } }
            }.disabled(isRunning)
            TextEditor(text: $text).font(.body).frame(minHeight: 120).border(.quaternary).disabled(isRunning)
            Text(availabilityText).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(pairStatus == .supported ? "下载语言包并翻译" : "翻译") { begin() }.disabled(isRunning || pairStatus == .unsupported || pairStatus == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isRunning { ProgressView().controlSize(.small); Button("取消翻译") { cancel(notify: true) } }
                Spacer()
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if !translated.isEmpty { Text("译文").font(.headline); ScrollView { Text(translated).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 100) }
        }
        .padding(20).frame(minWidth: 500, minHeight: 420)
        .task {
            languages = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier).sorted()
            // Preserve a requested unsupported code so that it is explicitly rejected, never silently substituted.
            if !languages.contains(target) { languages.append(target) }
            if source != "auto", !languages.contains(source) { languages.append(source) }
            await refreshAvailability()
        }
        .onChange(of: source) { inputChanged() }
        .onChange(of: target) { inputChanged() }
        .onChange(of: text) { inputChanged() }
        .translationTask(configuration) { session in
            guard let snapshot = attempt else { return }
            currentSession = session
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard attempt?.id == snapshot.id else { return }
                let response = try await session.translate(snapshot.text)
                try Task.checkCancellation()
                guard attempt?.id == snapshot.id else { return }
                var result = LocalTranslationResult(sourceText: response.sourceText, translatedText: response.targetText, sourceLanguage: response.sourceLanguage.minimalIdentifier, targetLanguage: response.targetLanguage.minimalIdentifier)
                result.languagePackageDownloadRequested = snapshot.packageDownloadRequested
                translated = result.translatedText; isRunning = false
                onCompletion(result, snapshot.identity.operationID, snapshot.identity.requestID)
                await refreshAvailability()
            } catch {
                guard attempt?.id == snapshot.id else { return }
                errorMessage = error.localizedDescription; isRunning = false
            }
            if attempt?.id == snapshot.id { currentSession = nil }
        }
        .onDisappear { cancel(notify: false) }
    }

    private func languageName(_ code: String) -> String { "\(Locale.current.localizedString(forIdentifier: code) ?? code)（\(code)）" }
    private func refreshAvailability() async {
        let generation = UUID(); availabilityGeneration = generation
        let result: LanguageAvailability.Status
        do {
            guard text.count <= 100_000 else { pairStatus = nil; availabilityText = LocalTranslationError.tooLong.localizedDescription; return }
            if source == "auto" {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pairStatus = nil; availabilityText = "输入文字后检测语言。"; return }
                result = try await LanguageAvailability().status(for: text, to: Locale.Language(identifier: target))
            } else { result = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) }
            guard generation == availabilityGeneration else { return }
            pairStatus = result
            switch result {
            case .installed: availabilityText = "语言包已安装，可本机离线翻译。"
            case .supported: availabilityText = "系统支持此语言组合，语言包尚未安装；点击后由系统确认下载。"
            case .unsupported: availabilityText = "系统不支持此语言组合。请选择其他语言。"
            @unknown default: pairStatus = nil; availabilityText = "系统返回未知语言状态，暂不可翻译。"
            }
        } catch { guard generation == availabilityGeneration else { return }; pairStatus = nil; availabilityText = "无法识别原文语言，请明确选择：\(error.localizedDescription)" }
    }
    private func begin() {
        guard text.count <= 100_000 else { errorMessage = LocalTranslationError.tooLong.localizedDescription; return }
        guard pairStatus == .installed || pairStatus == .supported, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil; translated = ""; isRunning = true
        attempt = TranslationAttempt(identity: identity, text: text, sourceLanguage: source, targetLanguage: target, packageDownloadRequested: pairStatus == .supported)
        let new = TranslationSession.Configuration(source: source == "auto" ? nil : Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        if configuration?.source == new.source && configuration?.target == new.target { configuration?.invalidate() } else { configuration = new }
    }
    private func inputChanged() {
        pairStatus = nil; translated = ""; availabilityText = "正在检查语言组合…"
        Task { await refreshAvailability() }
    }
    private func cancel(notify: Bool) {
        if #available(macOS 26.0, *) { currentSession?.cancel() }
        attempt = nil; configuration = nil; isRunning = false; currentSession = nil
        if notify { onCancel(identity.operationID, identity.requestID) }
    }
}
