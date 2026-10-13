import SwiftUI
import AppKit
import AVFoundation

struct SettingsView:View {
    @ObservedObject var model:AppModel
    @ObservedObject private var store:LocalStore
    init(model:AppModel){self.model=model;store=model.store}
    var body:some View{Form{Section("截图后"){Picker("默认动作",selection:$store.settings.captureStrategy){Text("进入标注").tag("标注");Text("复制").tag("复制");Text("保存到所选目录").tag("保存")};HStack{Text(store.settings.saveDirectory == nil ? "保存目录未选择":"已选择保存目录");Button("选择目录…"){chooseDirectory()}};HStack{Text(store.settings.editorPath == nil ? "编辑 App 未选择":"已选择编辑 App");Button("选择 App…"){chooseEditor()}}};Section("OCR 与私密资料"){TextField("语言（逗号分隔）",text:Binding(get:{store.settings.languages.joined(separator:",")},set:{store.settings.languages=$0.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}}));Toggle("静默截图 OCR 完成后复制文字",isOn:$store.settings.silentOCRCopies);Toggle("主动启用截图历史",isOn:$store.settings.historyEnabled);Stepper("历史保留 \(store.settings.historyDays) 天",value:$store.settings.historyDays,in:1...3650);Stepper("历史容量 \(store.settings.historyCapacityMB) MiB",value:$store.settings.historyCapacityMB,in:16...16384,step:16);Button("删除截图历史…",role:.destructive){deleteHistory()}};Section("权限"){Text("屏幕捕获：\(CGPreflightScreenCaptureAccess() ? "已获权":"未获权")；麦克风：\(microphoneStatus)");Button("打开屏幕录制设置"){model.screenSettings()};Text("辅助功能只用于用户触发的长截图滚动；全局快捷键使用系统注册，无划词监听。").font(.caption)};HStack{Button("保存设置"){do{try store.saveSettings();model.message="设置已保存。"}catch{model.fail(error)}}.disabled(!store.writable);Spacer();Text("V1.00 / build 1 · 本地签名，未公证").font(.caption).foregroundStyle(.secondary)}}.formStyle(.grouped).padding()}
    var microphoneStatus:String{switch PermissionService.microphoneStatus{case .authorized:return "已获权";case .denied:return "拒绝";case .restricted:return "受限";default:return "未申请"}}
    func chooseDirectory(){let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;if p.runModal() == .OK{store.settings.saveDirectory=p.url?.path}}
    func chooseEditor(){let p=NSOpenPanel();p.allowedContentTypes=[.application];if p.runModal() == .OK{store.settings.editorPath=p.url?.path}}
    func deleteHistory(){let a=NSAlert();a.messageText="删除本应用保存的截图历史？";a.informativeText="原用户文件不受影响；内部恢复副本会保留在 DeletedHistory。";a.addButton(withTitle:"删除历史");a.addButton(withTitle:"取消");if a.runModal() == .alertFirstButtonReturn{do{try store.deleteHistory()}catch{model.fail(error)}}}
}
