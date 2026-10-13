import Foundation
import Darwin

enum DataBackup {
    struct Entry:Codable,Equatable{var bytes:Int64;var sha256:String}
    struct Report:Codable{var schemaVersion=1;var createdAt=ISO8601DateFormatter().string(from:Date());var sourceExisted:Bool;var inventory:[String:Entry];var restoreRehearsal:Bool=true;var keychain="untouched"}
    static func inventory(_ root:URL) throws -> [String:Entry] {
        var status=stat()
        if lstat(root.path,&status) != 0 {guard errno==ENOENT else{throw AppIssue.message("资料目录状态不可读取，停止备份。")} ;return [:]}
        _ = try GaoPrivateIO.directory(root)
        var files:[String:Entry]=[:]
        var traversalError:Error?
        guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey],options:[],errorHandler:{_,error in traversalError=error;return false})else{throw AppIssue.message("资料目录无法遍历。")}
        for case let url as URL in e {
            let r=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey])
            guard r.isSymbolicLink != true,r.isRegularFile==true || r.isDirectory==true else{throw AppIssue.message("资料中存在链接或特殊文件，已停止备份。")}
            if r.isRegularFile==true{let s=try GaoPrivateIO.regularURL(url).statValue();files[String(url.path.dropFirst(root.path.count+1))]=Entry(bytes:Int64(s.st_size),sha256:try FileSafety.digestFile(url))}
        }
        if let traversalError{throw traversalError};return files
    }
    @MainActor static func create(root:URL,destination:URL) throws -> URL {
        guard !destination.path.hasPrefix(root.path+"/"),!FileManager.default.fileExists(atPath:destination.path)else{throw AppIssue.message("备份目标必须是资料外的新目录。")}
        let existed=FileManager.default.fileExists(atPath:root.path),before=try inventory(root)
        if existed {
            let state=LocalStore(root:root);guard state.writable else{throw AppIssue.message(state.issue ?? "资料格式无法校验。")}
            _ = try PinnedImagePersistence.read(root:root)
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("Exchange/ProcessedRequests.json").path){_ = try GaoProcessedRequestStore(root:root.appendingPathComponent("Exchange"))}
        }
        _ = try GaoPrivateIO.directory(destination,create:true,requirePrivate:true)
        let data=destination.appendingPathComponent("Data")
        if existed{try FileManager.default.copyItem(at:root,to:data)}else{_ = try GaoPrivateIO.directory(data,create:true,requirePrivate:true)}
        guard try inventory(data)==before,try inventory(root)==before else{throw AppIssue.message("备份校验失败，原资料未改动。")}
        let rehearsal=destination.appendingPathComponent("RestoreRehearsal")
        try FileManager.default.copyItem(at:data,to:rehearsal)
        guard try inventory(rehearsal)==before else{throw AppIssue.message("恢复演练摘要核验失败。")}
        try FileManager.default.removeItem(at:rehearsal)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(Report(sourceExisted:existed,inventory:before)).write(to:destination.appendingPathComponent("Verification.json"),options:.withoutOverwriting)
        return destination
    }
    static func verify(_ directory:URL) throws -> Report {
        let data=try GaoPrivateIO.read(GaoPrivateIO.regularURL(directory.appendingPathComponent("Verification.json")),maximum:16_777_216)
        let report=try JSONDecoder().decode(Report.self,from:data)
        _ = try GaoPrivateIO.directory(directory.appendingPathComponent("Data"))
        guard report.schemaVersion==1,report.restoreRehearsal,try inventory(directory.appendingPathComponent("Data"))==report.inventory else{throw AppIssue.message("备份格式或摘要校验失败。")};return report
    }
}
