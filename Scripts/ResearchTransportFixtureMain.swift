import Foundation
import CryptoKit
import Darwin

/// Linked only into a separate CLI binary with the unmodified Research transport.
/// It does not load Research App/UI code or access any installed business data.
@main struct ResearchTransportFixtureMain {
    static let researchBundleID = "com.academic-achievement.manager"
    static let screenshotBundleID = "com.gaoseries.GaoJieTu"

    static func main() {
        do {
            let args = CommandLine.arguments
            let summary: [String: Any]
            if args.count == 4 && args[1] == "make-request" {
                summary = try makeRequest(source: URL(fileURLWithPath: args[2]),
                                          outgoingRoot: URL(fileURLWithPath: args[3], isDirectory: true))
            } else if args.count == 7 && args[1] == "check-result" {
                summary = try checkResult(requestURL: URL(fileURLWithPath: args[2], isDirectory: true),
                                          resultURL: URL(fileURLWithPath: args[3], isDirectory: true),
                                          stagingRoot: URL(fileURLWithPath: args[4], isDirectory: true),
                                          expectedOutputURL: URL(fileURLWithPath: args[5]), resultItemID: args[6])
            } else {
                throw GaoActionError.invalidParameters
            }
            let bytes = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            fputs("Research isolated protocol fixture failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func makeRequest(source: URL, outgoingRoot: URL) throws -> [String: Any] {
        let fingerprint = try GaoActionFileAccess.fingerprint(at: source)
        let itemID = UUID().uuidString
        let template = GaoActionManifest(sourceBundleID: researchBundleID, targetBundleID: screenshotBundleID,
                         action: "ocr.files", items: [.init(id: itemID, relativePath: "payload/" + itemID + ".png",
                                                           uti: "public.png", byteCount: fingerprint.byteCount,
                                                           sha256: fingerprint.sha256)],
                         parameters: ["outputs": .array([.string("text")])])
        let packageURL = try GaoActionPackageWriter().write(manifest: template, files: [itemID: source], outgoingRoot: outgoingRoot)
        let manifestBytes = try GaoActionFileAccess.readPrivateData(at: packageURL.appendingPathComponent("manifest.json"))
        let written = try GaoActionPackageValidator(expectedTargetBundleID: screenshotBundleID).validateManifestData(manifestBytes)
        guard written.items.count == 1, written.items[0].id == itemID,
              written.items[0].byteCount == fingerprint.byteCount, written.items[0].sha256 == fingerprint.sha256 else {
            throw GaoActionError.invalidManifest
        }
        return ["packagePath": packageURL.path, "requestID": written.requestID, "sourceItemID": itemID,
                "sourceSHA256": fingerprint.sha256, "sourceByteCount": fingerprint.byteCount,
                "protocolFixtureOnly": true, "actualOCRPerformed": false]
    }

    static func checkResult(requestURL: URL, resultURL: URL, stagingRoot: URL,
                            expectedOutputURL: URL, resultItemID: String) throws -> [String: Any] {
        let requestData = try GaoActionFileAccess.readPrivateData(at: requestURL.appendingPathComponent("manifest.json"))
        let request = try GaoActionPackageValidator(expectedTargetBundleID: screenshotBundleID).validateManifestData(requestData)
        let received = try GaoActionPackageValidator(expectedTargetBundleID: researchBundleID)
            .stagePackage(at: resultURL, stagingRoot: stagingRoot)
        let result = received.manifest
        guard request.kind == "request", request.action == "ocr.files", request.items.count == 1,
              result.kind == "result", result.action == request.action, result.inReplyTo == request.requestID,
              result.requestID != request.requestID, result.nonce != request.nonce,
              result.sourceBundleID == request.targetBundleID, result.targetBundleID == request.sourceBundleID,
              result.status == "completed", result.parameters.isEmpty, received.stagedItems.count == 1,
              let provenance = result.provenance,
              provenance["protocolFixtureOnly"] == .bool(true), provenance["actualOCRPerformed"] == .bool(false),
              provenance["sourceItemID"] == .string(request.items[0].id),
              provenance["sourceSHA256"] == .string(request.items[0].sha256),
              provenance["resultItemID"] == .string(resultItemID) else { throw GaoActionError.invalidManifest }
        let output = received.stagedItems[0]
        let expected = try GaoActionFileAccess.readPrivateData(at: expectedOutputURL)
        let actual = try GaoActionFileAccess.readPrivateData(at: output.url)
        let checksum = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
        guard output.item.id == resultItemID, actual == expected, output.item.byteCount == Int64(actual.count),
              output.item.sha256 == checksum else { throw GaoActionError.checksumMismatch }
        return ["validated": true, "resultID": result.requestID, "inReplyTo": result.inReplyTo!,
                "byteCount": actual.count, "sha256": checksum,
                "protocolFixtureOnly": true, "actualOCRPerformed": false]
    }
}
