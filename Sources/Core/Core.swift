import AppKit
import CryptoKit
import Darwin
import ImageIO

enum FileSafety {
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func digestFile(_ url: URL) throws -> String {
        let fd = try GaoPrivateIO.regularURL(url)
        let before = try fd.statValue()
        var hasher = SHA256(); var buffer = [UInt8](repeating:0,count:65536)
        while true {
            let n = Darwin.read(fd.value,&buffer,buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw AppIssue.message("文件读取失败。") }
            hasher.update(data:Data(buffer.prefix(n)))
        }
        guard GaoPrivateIO.unchanged(before,try fd.statValue()) else { throw AppIssue.message("文件在读取时改变。") }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
enum AppIssue: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
struct CaptureAsset: Codable, Identifiable {
    var id = UUID(); var createdAt = Date(); var source: String
    var pixelWidth: Int; var pixelHeight: Int; var colorSpace: String; var scale: Double
    var outputPath: String; var sha256: String; var editVersion = 0
}
struct AppSettings: Codable {
    var schemaVersion = 1
    var historyEnabled = false; var historyDays = 7; var historyCapacityMB = 512
    var captureStrategy = "标注"; var saveDirectory: String?; var editorPath: String?
    var languages = ["zh-Hans","en-US"]; var silentOCRCopies = true
    var pins: [String] = []
}
struct HistoryEnvelope: Codable { var schemaVersion = 1; var assets: [CaptureAsset] = [] }

@MainActor final class LocalStore: ObservableObject {
    let root: URL; let backupRoot: URL
    @Published var settings = AppSettings()
    @Published var assets: [CaptureAsset] = []
    @Published var issue: String?
    private var settingsDigest: String?; private var historyDigest: String?
    var writable = false
    var exchange: URL { root.appendingPathComponent("Exchange",isDirectory:true) }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoJieTu")
        backupRoot = self.root.deletingLastPathComponent().appendingPathComponent("GaoJieTu-Backups")
        do {
            _ = try GaoPrivateIO.directory(self.root,create:true,requirePrivate:true)
            let settingsURL = self.root.appendingPathComponent("Settings.json")
            if FileManager.default.fileExists(atPath:settingsURL.path) {
                let data = try GaoPrivateIO.read(GaoPrivateIO.regularURL(settingsURL),maximum:1_048_576)
                settings = try JSONDecoder().decode(AppSettings.self,from:data)
                guard settings.schemaVersion == 1, (1...3650).contains(settings.historyDays), (16...16384).contains(settings.historyCapacityMB) else { throw AppIssue.message("设置格式过新或损坏，已保留资料并停止写入。") }
                settingsDigest = FileSafety.digest(data)
            } else {
                let existing=try FileManager.default.contentsOfDirectory(at:self.root,includingPropertiesForKeys:nil)
                guard existing.isEmpty else{throw AppIssue.message("已有资料但设置主记录缺失，已停止写入，不能当作新用户覆盖。")}
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                let bytes=try encoder.encode(settings);try GaoPrivateIO.atomicJSON(bytes,directory:GaoPrivateIO.directory(self.root),name:"Settings.json");settingsDigest=FileSafety.digest(bytes)
            }
            let historyURL = self.root.appendingPathComponent("History.json")
            if FileManager.default.fileExists(atPath:historyURL.path) {
                let data = try GaoPrivateIO.read(GaoPrivateIO.regularURL(historyURL),maximum:16_777_216)
                let envelope = try JSONDecoder().decode(HistoryEnvelope.self,from:data)
                guard envelope.schemaVersion == 1 else { throw AppIssue.message("历史版本过新，已停止写入。") }
                assets = envelope.assets; historyDigest = FileSafety.digest(data)
                for asset in assets {
                    guard asset.outputPath.hasPrefix("History/"), !asset.outputPath.contains("..") else { throw AppIssue.message("历史路径损坏，已停止写入。") }
                    let url = self.root.appendingPathComponent(asset.outputPath)
                    guard try FileSafety.digestFile(url) == asset.sha256 else { throw AppIssue.message("历史附件缺失或摘要不符，原记录已保留。") }
                }
            } else if FileManager.default.fileExists(atPath:self.root.appendingPathComponent("History").path) {
                throw AppIssue.message("历史目录存在但主记录缺失，已保护现有附件。")
            }
            writable = true
        } catch { issue = error.localizedDescription }
    }
    func saveSettings() throws {
        guard writable else { throw AppIssue.message(issue ?? "资料只读。") }
        settingsDigest = try persist(settings,name:"Settings.json",previous:settingsDigest)
    }
    private func persist<T:Encodable>(_ value: T, name: String, previous: String?) throws -> String {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:url.path) {
            guard try FileSafety.digestFile(url) == previous else { throw AppIssue.message("资料已在其他地方修改，停止覆盖，请重新打开。") }
        } else if previous != nil { throw AppIssue.message("资料记录消失，停止覆盖。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(value)
        try GaoPrivateIO.atomicJSON(data,directory:GaoPrivateIO.directory(root),name:name)
        return FileSafety.digest(data)
    }
    func remember(image: CGImage, source: String, scale: Double) throws {
        guard settings.historyEnabled else { return }
        guard writable else { throw AppIssue.message("资料保护模式下不能保存历史。") }
        try pruneExpiredHistory()
        let bytes = try pngData(image)
        let used = try assets.reduce(Int64(0)) { n,a in n + Int64((try root.appendingPathComponent(a.outputPath).resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0) }
        guard used + Int64(bytes.count) <= Int64(settings.historyCapacityMB)*1_048_576 else { throw AppIssue.message("历史达到容量上限，请先导出或删除。") }
        let directory = root.appendingPathComponent("History"); _ = try GaoPrivateIO.directory(directory,create:true,requirePrivate:true)
        let name = UUID().uuidString + ".png"; let url = directory.appendingPathComponent(name)
        try bytes.write(to:url,options:.withoutOverwriting); _ = chmod(url.path,0o600)
        let asset = CaptureAsset(source:source,pixelWidth:image.width,pixelHeight:image.height,colorSpace:image.colorSpace?.name as String? ?? "unknown",scale:scale,outputPath:"History/"+name,sha256:FileSafety.digest(bytes))
        var next = assets; next.insert(asset,at:0)
        do { historyDigest = try persist(HistoryEnvelope(assets:next),name:"History.json",previous:historyDigest); assets = next }
        catch { try? FileManager.default.removeItem(at:url); throw error }
    }
    func deleteHistory() throws {
        guard writable else { throw AppIssue.message("资料保护模式下不能删除历史。") }
        let trash = root.appendingPathComponent("DeletedHistory/"+UUID().uuidString)
        _ = try GaoPrivateIO.directory(trash,create:true,requirePrivate:true)
        // A recovery copy is retained before changing the index. No original user file is removed.
        for asset in assets { try FileManager.default.copyItem(at:root.appendingPathComponent(asset.outputPath),to:trash.appendingPathComponent(URL(fileURLWithPath:asset.outputPath).lastPathComponent)) }
        historyDigest = try persist(HistoryEnvelope(),name:"History.json",previous:historyDigest)
        for asset in assets { try FileManager.default.removeItem(at:root.appendingPathComponent(asset.outputPath)) }
        assets = []
    }
    func pruneExpiredHistory() throws {
        guard writable,settings.historyEnabled else{return}
        let cutoff=Date().addingTimeInterval(-Double(settings.historyDays)*86400)
        let expired=assets.filter{$0.createdAt<cutoff}
        guard !expired.isEmpty else{return}
        let recovery=root.appendingPathComponent("DeletedHistory/Expired-"+UUID().uuidString)
        _ = try GaoPrivateIO.directory(recovery,create:true,requirePrivate:true)
        for asset in expired{try FileManager.default.copyItem(at:root.appendingPathComponent(asset.outputPath),to:recovery.appendingPathComponent(URL(fileURLWithPath:asset.outputPath).lastPathComponent))}
        let next=assets.filter{$0.createdAt>=cutoff}
        historyDigest=try persist(HistoryEnvelope(assets:next),name:"History.json",previous:historyDigest);assets=next
        for asset in expired{try FileManager.default.removeItem(at:root.appendingPathComponent(asset.outputPath))}
    }
}
func pngData(_ image: CGImage) throws -> Data {
    guard let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw AppIssue.message("PNG 编码失败。") }; return data
}
func readImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL,nil), let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 30000, h <= 30000, Int64(w)*Int64(h) <= 100_000_000, let image = CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw AppIssue.message("图像无法解码或超过 1 亿像素安全预算。") }; return image
}
