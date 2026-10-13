import SwiftUI
import AppKit
import Carbon
import AVFoundation
import UniformTypeIdentifiers
import Combine

@main struct GaoJieTuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        WindowGroup("搞截图 V1.00") { MainView(model:model).frame(minWidth:980,minHeight:680) }
        .commands {
            CommandGroup(replacing:.newItem) { Button("区域截图") { model.captureRegion() }.keyboardShortcut("2",modifiers:[.command,.option,.control]); Button("打开图像或 PDF…"){model.openFiles()}.keyboardShortcut("o") }
            CommandGroup(after:.pasteboard) { Button("识别剪贴板图片"){model.ocrClipboard()};Button("翻译剪贴板文字"){model.translateClipboard()} }
            CommandGroup(replacing:.undoRedo) { Button("撤销"){model.annotation?.undo()}.keyboardShortcut("z");Button("重做"){model.annotation?.redo()}.keyboardShortcut("z",modifiers:[.command,.shift]) }
        }
        Settings { SettingsView(model:model).frame(width:600,height:540) }
        MenuBarExtra("搞截图",systemImage: [.recording,.paused].contains(model.recording.state) ? "record.circle.fill":"viewfinder") {
            Button("区域截图 ⌃⌥⌘2"){model.captureRegion()}
            Button("窗口截图"){model.captureWindow()}
            Button("静默截图 OCR ⌃⌥⌘3"){model.captureRegion(silentOCR:true)}
            Button("打开工作台"){model.showMain()}
            Divider();Button("停止录制"){Task{await model.recording.stop()}}.disabled(![.recording,.paused].contains(model.recording.state))
            Button("退出搞截图"){NSApp.terminate(nil)}
        }
    }
}
@MainActor final class AppDelegate: NSObject,NSApplicationDelegate {
    private var hotkeys: [EventHotKeyRef] = []
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.servicesProvider=self
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,_ in
            guard let event else{return OSStatus(eventNotHandledErr)}
            var id=EventHotKeyID();GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            Task{@MainActor in AppModel.shared.captureRegion(silentOCR:id.id==2)}
            return noErr
        },1,[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))],nil,nil)
        for (id,key) in [(UInt32(1),UInt32(kVK_ANSI_2)),(UInt32(2),UInt32(kVK_ANSI_3))] {
            var ref:EventHotKeyRef?;let status=RegisterEventHotKey(key,UInt32(cmdKey|optionKey|controlKey),EventHotKeyID(signature:0x474a5455,id:id),GetApplicationEventTarget(),0,&ref)
            if status==noErr,let ref{hotkeys.append(ref)}else{AppModel.shared.message="快捷键注册失败（\(status)），可用菜单触发。"}
        }
    }
    func application(_ application:NSApplication,open urls:[URL]){Task{await AppModel.shared.receive(urls)}}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if [.recording,.paused,.preparing,.stopping].contains(AppModel.shared.recording.state) || AppModel.shared.ocr.isRunning || AppModel.shared.exchange.isExecuting || AppModel.shared.busy{AppModel.shared.message="正在处理，请先停止录制或取消 OCR 后退出。";AppModel.shared.showMain();return .terminateCancel};try? FileManager.default.removeItem(at:AppModel.shared.sessionTemporaryDirectory);return .terminateNow
    }
    @objc func translateSelection(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text=pasteboard.string(forType:.string),!text.isEmpty else{return};AppModel.shared.translationText=text;AppModel.shared.tab="翻译";AppModel.shared.showMain()
    }
}
@MainActor final class AppModel: ObservableObject {
    static let shared=AppModel()
    let store=LocalStore();let capture=CaptureService();let selection=CaptureSelectionController();let pins=PinnedImageController()
    let recording=RecordingController();let ocr=OCRController()
    @Published var tab="截图";@Published var annotation:AnnotationDocument?;@Published var message="选择一个动作开始，屏幕与剪贴板不会自动采集。"
    @Published var busy=false;@Published var delay=0.0;@Published var cursor=false;@Published var shadow=false
    @Published var translationText="";@Published var translationSource="auto";@Published var translationTarget="en"
    @Published var captureCatalog:CaptureCatalog?;@Published var chooser=false;@Published var chooserMode="屏幕";@Published var selectedWindows:Set<CGWindowID>=[]
    @Published var pendingResults:[PendingActionResult]=[]
    let sessionTemporaryDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("GaoJieTu-session-"+UUID().uuidString)
    @Published var exportQuality=0.9;@Published var exportMaximumDimension=0
    let longPanel=LongCapturePanelController()
    var captureTask:Task<Void,Never>?
    var captureCancellation=OCRCancellationToken()
    var choiceContinuation:CheckedContinuation<CaptureSource?,Never>?
    var externalAnnotation:GaoValidatedPackage?;var externalTranslation:GaoValidatedPackage?
    lazy var exchange=ExchangeController(model:self)
    @Published var longSession:LongScreenshotSession?;var longSource:CaptureSource?
    private var subscriptions=Set<AnyCancellable>()
    init(){pins.persistenceDirectory=store.root;pins.onNotice={[weak self]text in self?.message=text}
        recording.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
        ocr.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
        store.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
    }
    var options:CaptureOptions { var o=CaptureOptions();o.delaySeconds=delay;o.showsCursor=cursor;o.includesShadow=shadow;return o }
    func showMain(){NSApp.activate(ignoringOtherApps:true);NSApp.windows.first(where:{$0.title.hasPrefix("搞截图")})?.makeKeyAndOrderFront(nil)}
    func hideMain(){NSApp.windows.filter{$0.title.hasPrefix("搞截图")}.forEach{$0.orderOut(nil)}}
    func fail(_ error:Error){message=error.localizedDescription;showMain()}
    func requestScreen(){_ = CGRequestScreenCaptureAccess();message=CGPreflightScreenCaptureAccess() ? "当前程序已取得屏幕录制权限。":"请在系统设置中允许搞截图的屏幕与系统音频录制，然后重新打开应用。"}
    func screenSettings(){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
    func openFiles(){guard externalAnnotation==nil else{message="请先完成或取消正在等待的标注交接。";return};let p=NSOpenPanel();p.allowedContentTypes=[.image,.pdf];p.allowsMultipleSelection=true;if p.runModal() == .OK{Task{await receive(p.urls)}}}
    func receive(_ urls:[URL]) async {
        for url in urls {
            if url.pathExtension=="gaoaction"{await exchange.receive(url);continue}
            if externalAnnotation != nil{message="请先完成或取消正在等待的标注交接。";continue}
            if url.pathExtension=="gaoannotation" {do{annotation=try AnnotationDocument.loadEditable(url);tab="标注"}catch{fail(error)};continue}
            if url.pathExtension.lowercased()=="pdf" || urls.count>1 { tab="OCR";ocr.start(urls:urls,options:ocrOptions);break }
            do{annotation=AnnotationDocument(image:try readImage(url));tab="标注"}catch{fail(error)}
        };showMain()
    }
    var ocrOptions:OCROptions{var o=OCROptions();o.languages=store.settings.languages;return o}
    func adopt(_ frame:CapturedFrame) throws {
        annotation=AnnotationDocument(image:frame.image)
        message="\(frame.image.width) × \(frame.image.height) px · \(frame.colorSpaceName) · 首帧 \(Int(frame.elapsedMilliseconds)) ms"
        try store.remember(image:frame.image,source:frame.sourceDescription,scale:Double(frame.scale))
        switch store.settings.captureStrategy {
        case "复制":NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([NSImage(cgImage:frame.image,size:.zero)])
        case "保存":if let path=store.settings.saveDirectory {let url=URL(fileURLWithPath:path).appendingPathComponent("截图-"+UUID().uuidString+".png");try CaptureImageExport.write(frame.image,to:url);message="已保存到所选目录。"}else{tab="标注";message+="；先在设置选择保存目录。"}
        default:tab="标注"
        };showMain()
    }
    func captureRegion(silentOCR:Bool=false,translateOCR:Bool=false){
        guard !busy,!exchange.isExecuting,externalAnnotation==nil,(!translateOCR || externalTranslation==nil)else{return}
        busy=true;captureCancellation=OCRCancellationToken();let cancellation=captureCancellation
        captureTask=Task { [self] in
            defer{busy=false;captureTask=nil}
            do {
                guard let frame=try await performCapture("capture.region")else{message="已取消截图。";showMain();return}
                try Task.checkCancellation()
                if silentOCR || translateOCR {
                    _ = try GaoPrivateIO.directory(sessionTemporaryDirectory,create:true,requirePrivate:true)
                    let url=sessionTemporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
                    try pngData(frame.image).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                    defer{try? FileManager.default.removeItem(at:url)}
                    let document=try await OCRService().recognize(urls:[url],options:ocrOptions,cancellation:cancellation,progress:{[weak self]progress in Task{@MainActor in self?.message="截图 OCR：\(progress.completedPages)/\(progress.totalPages) 页"}})
                    try Task.checkCancellation()
                    guard !cancellation.isCancelled,document.successfulPages>0 else{throw AppIssue.message("截图 OCR 已取消或没有可用结果。")}
                    if translateOCR{translationText=document.text;tab="翻译";message="截图 OCR 完成，请选择本机翻译语言并开始。";showMain()}
                    else{if store.settings.silentOCRCopies{NSPasteboard.general.clearContents();NSPasteboard.general.setString(document.text,forType:.string)};message="截图 OCR 完成，\(document.text.count) 字。";NSSound.beep()}
                } else {try adopt(frame)}
            }catch{fail(error)}
        }
    }
    func cancelCaptureWork(){captureCancellation.cancel();captureTask?.cancel();selection.cancel()}
    func captureWindow(){captureAction("capture.window")}
    func captureDisplay(){captureAction("capture.display")}
    func captureAction(_ action:String){guard !busy,!exchange.isExecuting,externalAnnotation==nil else{return};busy=true;captureTask=Task{defer{busy=false;captureTask=nil};do{if let frame=try await performCapture(action){try Task.checkCancellation();try adopt(frame)}else{message="已取消。";showMain()}}catch{fail(error)}}}
    func performCapture(_ action:String) async throws -> CapturedFrame? {
        guard CGPreflightScreenCaptureAccess()else{throw CaptureFailure.permissionRequired}
        if action=="capture.region"{hideMain();guard let region=await selection.selectRegion()else{return nil};return try await capture.captureDesktopRegion(region.desktopRect,options:options)}
        if action=="capture.window"{let catalog=try await capture.refreshCatalog();hideMain();guard let id=await selection.selectWindow(from:catalog.windows)else{return nil};return try await capture.capture(.window(id),options:options)}
        let catalog=try await capture.refreshCatalog()
        if catalog.displays.count==1,let d=catalog.displays.first{hideMain();return try await capture.capture(.display(d.id),options:options)}
        captureCatalog=catalog;chooserMode="屏幕";showMain();let source=await withCheckedContinuation{choiceContinuation=$0;chooser=true};guard let source else{return nil};hideMain();return try await capture.capture(source,options:options)
    }
    func choose(_ source:CaptureSource?){chooser=false;choiceContinuation?.resume(returning:source);choiceContinuation=nil}
    func multiWindow(){guard !busy,!exchange.isExecuting,externalAnnotation==nil else{return};Task{do{captureCatalog=try await capture.refreshCatalog();chooserMode="多窗口";selectedWindows=[];chooser=true}catch{fail(error)}}}
    func finishMulti(){chooser=false;Task{do{hideMain();let frame=try await capture.captureWindows(Array(selectedWindows),options:options);try adopt(frame)}catch{fail(error)}}}
    func ocrClipboard(){guard let data=NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff),let image=NSImage(data:data)?.cgImage(forProposedRect:nil,context:nil,hints:nil)else{message="剪贴板没有可识别图像。";return};ocrImage(image)}
    func ocrImage(_ image:CGImage){do{let dir=sessionTemporaryDirectory;_ = try GaoPrivateIO.directory(dir,create:true,requirePrivate:true);let url=dir.appendingPathComponent(UUID().uuidString+".png");try pngData(image).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);tab="OCR";ocr.start(urls:[url],options:ocrOptions);showMain()}catch{fail(error)}}
    func translateClipboard(){guard externalTranslation==nil else{message="请先完成或取消正在等待的翻译交接。";return};translationText=NSPasteboard.general.string(forType:.string) ?? "";tab="翻译";showMain()}
    func copyImage(){guard let image=try? annotation?.flatten()else{return};NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([NSImage(cgImage:image,size:.zero)]);message="已复制最终栅格图像。"}
    func pinImage(){guard let image=try? annotation?.flatten()else{return};pins.show(image:image,onEdit:{[weak self]image in self?.annotation=AnnotationDocument(image:image);self?.tab="标注";self?.showMain()})}
    func saveAnnotation(editable:Bool=false,framed:Bool=false,wallpaper:Bool=false,shell:Bool=true,openEditor:Bool=false){guard let doc=annotation else{return};let p=NSSavePanel();p.nameFieldStringValue=editable ? "标注.gaoannotation":"截图.png";p.allowedContentTypes=editable ? []:[.png,.jpeg,.tiff,.heic];guard p.runModal() == .OK,let url=p.url else{return};do{if editable{try doc.saveEditable(to:url)}else{let image=try doc.flatten();var backdrop:CGImage?;if wallpaper{guard let screen=NSScreen.main,let path=NSWorkspace.shared.desktopImageURL(for:screen)else{throw AppIssue.message("当前桌面壁纸不可读取，请改用普通带壳导出。")};backdrop=try readImage(path)};let final=framed ? try CaptureImageExport.framed(image,wallpaper:backdrop,shell:shell):image;let ext=url.pathExtension.lowercased();let format=CaptureImageExport.Format(rawValue:ext=="jpg" ? "jpeg":ext=="tif" ? "tiff":ext) ?? .png;try CaptureImageExport.write(final,to:url,format:format,quality:exportQuality,maximumDimension:exportMaximumDimension>0 ? exportMaximumDimension:nil);if let request=externalAnnotation{externalAnnotation=nil;try exchange.completeAnnotation(request,url:url)};if openEditor{guard let path=store.settings.editorPath else{throw AppIssue.message("请先在设置选择默认编辑 App。")};NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration(),completionHandler:{_,_ in})}};message="已导出并回读校验。"}catch{fail(error)}}
    func sampleColor(){Task{if let color=await CaptureColorSampler.sampleSystemColor(),let rgb=color.usingColorSpace(.sRGB){message=String(format:"sRGB  #%02X%02X%02X · RGB %d %d %d",Int(round(rgb.redComponent*255)),Int(round(rgb.greenComponent*255)),Int(round(rgb.blueComponent*255)),Int(round(rgb.redComponent*255)),Int(round(rgb.greenComponent*255)),Int(round(rgb.blueComponent*255)));showMain()}}}
}
