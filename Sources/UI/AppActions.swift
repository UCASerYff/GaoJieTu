import AppKit
import SwiftUI

extension AppModel {
    func editPinnedImage(_ image:CGImage){guard externalAnnotation==nil else{message="请先完成或取消正在等待的标注交接。";showMain();return};annotation=AnnotationDocument(image:image);tab="标注";showMain()}
    func copyPermissionStatus(){do{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(PermissionService.snapshot());guard let text=String(data:data,encoding:.utf8)else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string);message="已复制本次运行程序的权限与签名状态；没有捕获屏幕或声音。"}catch{fail(error)}}
    func startLongCapture(){guard !busy,!exchange.isExecuting,externalAnnotation==nil else{message="请先完成或取消当前任务。";return};busy=true;hideMain();longPanel.onStatus={[weak self] text in self?.message=text};longPanel.onCancel={[weak self] in self?.busy=false;self?.showMain()};Task{[self] in do{try await longPanel.start(service:capture,selection:selection,options:options){[weak self]image in self?.annotation=AnnotationDocument(image:image);self?.tab="标注";self?.busy=false;self?.showMain()}}catch{busy=false;fail(error)}}}
    func persistPin(){guard let image=try? annotation?.flatten()else{return};pins.persistenceDirectory=store.root;do{_ = try pins.persist(image:image,onEdit:{[weak self]image in self?.editPinnedImage(image)});message="已主动保存持久贴图。"}catch{fail(error)}}
    func restorePins(){pins.persistenceDirectory=store.root;pins.onNotice={[weak self]text in self?.message=text};pins.restorePersistentPins(onEdit:{[weak self]image in self?.editPinnedImage(image)})}
    func backupData(){guard !busy,!ocr.isRunning,!exchange.isExecuting,![.recording,.paused,.preparing,.stopping].contains(recording.state)else{message="请等待当前任务停止后备份。";return};let destination=store.backupRoot.appendingPathComponent("Backup-"+UUID().uuidString);do{let result=try DataBackup.create(root:store.root,destination:destination);message="完整备份与恢复演练已通过。";NSWorkspace.shared.activateFileViewerSelecting([result])}catch{fail(error)}}
}
