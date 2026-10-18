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
