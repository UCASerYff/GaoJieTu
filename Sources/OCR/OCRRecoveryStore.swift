import Foundation

struct OCRRecoverySource: Codable, Sendable {
    let sourceID: UUID
    let sourceItemID: String
    let sourceSHA256: String
}

/// Local recovery data is not an unrequested outgoing attachment and contains no source file URL.
struct OCRRecoverySnapshot: Codable, Sendable {
    var schemaVersion = 1
    let requestID: String
    let createdAt: Date
    let document: OCRDocument
    let sources: [OCRRecoverySource]
}

enum OCRRecoveryStore {
    static let maximumBytes: Int64 = 64 * 1024 * 1024

    @discardableResult
    static func save(document: OCRDocument, requestID: String, sources: [OCRRecoverySource], to destination: URL) throws -> OCRRecoverySnapshot {
        let snapshot = OCRRecoverySnapshot(requestID: requestID, createdAt: Date(), document: document, sources: sources)
        try validate(snapshot)
        _ = try GaoPrivateIO.directory(destination.deletingLastPathComponent(), requirePrivate: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw OCRError.resourceLimit("OCR 恢复资料超过64MiB，请保留原件并分批处理。") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw OCRError.outputExists }
        try data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let checked = try read(from: destination)
        guard checked.requestID == requestID, checked.document.id == document.id else { throw OCRError.validation("OCR 恢复资料重新读取不一致。") }
        return checked
    }

    static func read(from url: URL) throws -> OCRRecoverySnapshot {
        let bytes = try GaoPrivateIO.read(GaoPrivateIO.regularURL(url), maximum: maximumBytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(OCRRecoverySnapshot.self, from: bytes)
        try validate(value)
        return value
    }

    private static func validate(_ value: OCRRecoverySnapshot) throws {
        guard value.schemaVersion == 1, value.document.schemaVersion == 1, UUID(uuidString: value.requestID) != nil,
              value.sources.count == value.document.sources.count,
              Set(value.sources.map(\.sourceID)).count == value.sources.count,
              Set(value.sources.map(\.sourceItemID)).count == value.sources.count,
              Set(value.sources.map(\.sourceID)) == Set(value.document.sources.map(\.id)) else { throw OCRError.invalidDocument }
        for source in value.sources {
            guard !source.sourceItemID.isEmpty, GaoActionContract.validSHA(source.sourceSHA256),
                  let original = value.document.sources.first(where: { $0.id == source.sourceID }),
                  original.sha256.isEmpty || original.sha256 == source.sourceSHA256 else { throw OCRError.validation("OCR 恢复资料的原件关联不一致。") }
        }
    }
}
