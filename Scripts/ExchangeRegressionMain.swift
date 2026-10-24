import Foundation
import CoreGraphics
import Darwin

/// CLI-only protocol fixtures. A synthetic result exercises transport, not OCR.
@main struct ExchangeRegressionMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw AppIssue.message("Expected isolated fixture root and optional Research fixture executable.") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            _ = try GaoPrivateIO.directory(root, create: true, requirePrivate: true)
            try GaoActionTests.run(in: root.appendingPathComponent("LocalTransport", isDirectory: true))
            if !CommandLine.arguments[2].isEmpty {
                try researchInterop(executable: URL(fileURLWithPath: CommandLine.arguments[2]),
                                    root: root.appendingPathComponent("ResearchInterop", isDirectory: true))
            } else {
                print("Research transport compatibility: NOT RUN (--without-research)")
            }
            print("ISOLATED EXCHANGE CHECKS PASSED (protocol only; no actual OCR or GUI)")
        } catch {
            fputs("Exchange regression failure: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func researchInterop(executable: URL, root: URL) throws {
        _ = try GaoPrivateIO.directory(root, create: true, requirePrivate: true)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw AppIssue.message("Research protocol compatibility: " + message) }
            checks += 1
        }
        let sourceURL = root.appendingPathComponent("public-synthetic.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                      bytesPerRow: 8, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppIssue.message("Cannot create a synthetic PNG protocol fixture.")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { throw AppIssue.message("Cannot encode the synthetic PNG.") }
        let sourceBytes = try pngData(image)
        try sourceBytes.write(to: sourceURL, options: .withoutOverwriting)
        guard chmod(sourceURL.path, 0o600) == 0 else { throw AppIssue.message("Cannot protect synthetic PNG permissions.") }
        try check(try readImage(sourceURL).width == 2, "source is a real decodable PNG")

        let summary = try runResearch(executable, arguments: ["make-request", sourceURL.path,
                                      root.appendingPathComponent("ResearchOutgoing", isDirectory: true).path])
        guard let requestPath = summary["packagePath"] as? String,
              let requestID = summary["requestID"] as? String,
              let sourceID = summary["sourceItemID"] as? String,
              let sourceSHA = summary["sourceSHA256"] as? String else {
            throw AppIssue.message("Research writer returned an incomplete fixture summary.")
        }
        let requestURL = URL(fileURLWithPath: requestPath, isDirectory: true)
        let received = try GaoActionTransport.receive(packageURL: requestURL,
                          exchangeRoot: root.appendingPathComponent("ScreenshotExchange", isDirectory: true))
        let request = received.manifest
        try check(request.kind == "request" && request.action == "ocr.files" && request.requestID == requestID,
                  "Research writer request identity and action survive the actual screenshot reader")
        try check(request.sourceBundleID == "com.academic-achievement.manager" && request.targetBundleID == GaoActionContract.bundleID,
                  "request bundle declarations are unchanged")
        try check(request.items.count == 1 && request.items[0].relativePath == "payload/" + sourceID + ".png",
                  "Research production writer uses a package-root payload path")
        try check(received.stagedItems.count == 1 && (try Data(contentsOf: received.stagedItems[0].url)) == sourceBytes,
                  "screenshot production reader stages exact Research PNG bytes")
        try check(request.items[0].id == sourceID && request.items[0].byteCount == Int64(sourceBytes.count)
                  && request.items[0].sha256 == sourceSHA && sourceSHA == FileSafety.digest(sourceBytes),
                  "source item ID, size and SHA256 remain linked")
        try check(received.manifestSHA256 == FileSafety.digest(try Data(contentsOf: requestURL.appendingPathComponent("manifest.json"))),
                  "validated request manifest digest binds the exact original bytes")

        let outputURL = root.appendingPathComponent("synthetic-protocol-result.txt")
        let outputBytes = Data("Protocol fixture only; no OCR was executed.\n公开协议样本\n".utf8)
        try outputBytes.write(to: outputURL, options: .withoutOverwriting)
        guard chmod(outputURL.path, 0o600) == 0 else { throw AppIssue.message("Cannot protect synthetic result permissions.") }
        let resultItemID = "synthetic-protocol-text"
        let resultURL = try GaoActionWriter.writeResult(inReplyTo: request, status: "completed",
                          items: [.init(url: outputURL, uti: "public.utf8-plain-text", id: resultItemID)],
                          provenance: ["workflowState": .string("completed"), "protocolFixtureOnly": .bool(true),
                                       "actualOCRPerformed": .bool(false), "sourceItemID": .string(sourceID),
                                       "sourceSHA256": .string(sourceSHA), "resultItemID": .string(resultItemID)],
                          exchangeRoot: root.appendingPathComponent("ScreenshotExchange", isDirectory: true))
        let result = try GaoActionTransport.decodeManifest(Data(contentsOf: resultURL.appendingPathComponent("manifest.json")))
        try check(result.items.count == 1 && result.items[0].relativePath.hasPrefix("payload/")
                  && result.items[0].relativePath.split(separator: "/").count == 2,
                  "screenshot writer selects Research-compatible result path spelling")
        try check(result.inReplyTo == requestID && result.requestID != requestID && result.nonce != request.nonce,
                  "result has a fresh UUID/nonce and the original request linkage")
        let verified = try runResearch(executable, arguments: ["check-result", requestURL.path, resultURL.path,
                                       root.appendingPathComponent("ResearchResultStaging", isDirectory: true).path,
                                       outputURL.path, resultItemID])
        try check(verified["validated"] as? Bool == true && verified["inReplyTo"] as? String == requestID
                  && verified["resultID"] as? String == result.requestID
                  && verified["sha256"] as? String == FileSafety.digest(outputBytes)
                  && (verified["byteCount"] as? NSNumber)?.int64Value == Int64(outputBytes.count),
                  "Research real receiver validates exact synthetic result bytes and linkage")

        let legacyRequest = try GaoActionWriter.writeRequest(action: "documents.newText",
                                items: [.init(url: outputURL, uti: "public.utf8-plain-text")],
                                sourceBundleID: "com.gaoseries.ProtocolFixture", targetBundleID: "com.gaoseries.GaoCaoZuo",
                                exchangeRoot: root.appendingPathComponent("OtherTargetExchange", isDirectory: true))
        let legacy = try GaoActionTransport.decodeManifest(Data(contentsOf: legacyRequest.appendingPathComponent("manifest.json")))
        try check(legacy.items.count == 1 && !legacy.items[0].relativePath.contains("/"),
                  "other target request writers retain filename-only paths")
        let otherResult = try GaoActionWriter.writeResult(inReplyTo: legacy, status: "completed",
                              items: [.init(url: outputURL, uti: "public.utf8-plain-text")],
                              provenance: ["protocolFixtureOnly": .bool(true), "actualOCRPerformed": .bool(false)],
                              exchangeRoot: root.appendingPathComponent("OtherTargetExchange", isDirectory: true))
        let other = try GaoActionTransport.decodeManifest(Data(contentsOf: otherResult.appendingPathComponent("manifest.json")))
        try check(other.items.count == 1 && !other.items[0].relativePath.contains("/"),
                  "other target result writers retain filename-only paths")
        let otherReadback = try GaoActionTransport.receive(packageURL: otherResult,
                                exchangeRoot: root.appendingPathComponent("OtherTargetReadback", isDirectory: true),
                                expectedTargetBundleID: legacy.sourceBundleID)
        try check(try Data(contentsOf: otherReadback.stagedItems[0].url) == outputBytes,
                  "filename-only result readback preserves exact bytes")
        try check(try Data(contentsOf: sourceURL) == sourceBytes && Data(contentsOf: outputURL) == outputBytes,
                  "all original public fixture bytes remain unchanged")
        print("Research real writer → screenshot real reader/writer → Research real validator: PASS (\(checks) checks; synthetic protocol only, no OCR)")
    }

    private static func runResearch(_ executable: URL, arguments: [String]) throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let summary = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw AppIssue.message("Research production transport fixture failed.")
        }
        return summary
    }
}
