import Foundation

/// Input text alone is not an operation identity: two approved requests may contain the same text.
struct TranslationOperationIdentity: Equatable, Sendable {
    let operationID: UUID
    let requestID: String?

    func matches(operationID: UUID, requestID: String?) -> Bool {
        self.operationID == operationID && self.requestID == requestID
    }
}

struct TranslationAttempt: Sendable {
    let id = UUID()
    let identity: TranslationOperationIdentity
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    let packageDownloadRequested: Bool
}

enum TranslationExecutionPhase: String, Sendable {
    case preparing, translating
}

struct TranslationExecutionFailure: LocalizedError {
    let phase: TranslationExecutionPhase
    let underlying: Error

    var errorDescription: String? {
        let stage = phase == .preparing ? "准备本机翻译失败" : "翻译失败"
        let error = underlying as NSError
        return "\(stage)：\(underlying.localizedDescription)（\(error.domain) / \(error.code)）。自动模式无法识别时，请明确选择原文语言。"
    }
}

/// A source-less preparation has no text with which to identify the language.
/// Automatic sessions receive text through translate; the framework owns detection and any language-choice UI.
enum TranslationExecution {
    @MainActor
    static func run<Value>(attempt: TranslationAttempt,
                           isCurrent: () -> Bool,
                           prepare: () async throws -> Void,
                           translate: (String) async throws -> Value) async throws -> Value {
        var phase = TranslationExecutionPhase.translating
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if attempt.sourceLanguage != "auto" {
                phase = .preparing
                try await prepare()
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
            }
            phase = .translating
            let value = try await translate(attempt.text)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            throw TranslationExecutionFailure(phase: phase, underlying: error)
        }
    }
}
