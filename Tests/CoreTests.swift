import AppKit
import Darwin

func require(_ condition:@autoclosure () throws -> Bool,_ message:String) throws {if try !condition(){throw AppIssue.message("TEST: "+message)}}
func testImage(width:Int=80,height:Int=60) throws -> CGImage {
    let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(srgbRed:0.2,green:0.5,blue:0.8,alpha:0.7));c.fill(CGRect(x:0,y:0,width:width,height:height));return c.makeImage()!
}
@MainActor func runCoreTests(in root:URL) throws {
    let data=root.appendingPathComponent("Data");let store=LocalStore(root:data)
    try require(store.writable,"fresh store writable")
    try store.saveSettings();let settingsData=try Data(contentsOf:data.appendingPathComponent("Settings.json"))
    let image=try testImage();try store.remember(image:image,source:"self generated",scale:2)
    try require(store.assets.isEmpty,"history opt-in respected")
    store.settings.historyEnabled=true;try store.saveSettings();try store.remember(image:image,source:"self generated",scale:2)
    try require(store.assets.count==1,"history opt-in creates attachment")
    let backup=try DataBackup.create(root:data,destination:root.appendingPathComponent("Backup"));let report=try DataBackup.verify(backup)
    try require(report.inventory.count==3,"backup all settings history attachments")
    try require(LocalStore(root:data).assets.count==1,"store reload and digest")
    let missing=data.appendingPathComponent(store.assets[0].outputPath);try FileManager.default.removeItem(at:missing)
    let protected=LocalStore(root:data);try require(!protected.writable,"missing asset must protect state")
    try require(try Data(contentsOf:data.appendingPathComponent("History.json")).count>0,"missing attachment leaves index")
    let future=root.appendingPathComponent("Future");_ = try GaoPrivateIO.directory(future,create:true)
    let bytes=Data(String(data:settingsData,encoding:.utf8)!.replacingOccurrences(of:"\"schemaVersion\" : 1",with:"\"schemaVersion\" : 2").utf8);try bytes.write(to:future.appendingPathComponent("Settings.json"))
    try require(!LocalStore(root:future).writable,"future schema refused")
    let doc=AnnotationDocument(image:image)
    doc.add(AnnotationLayer(tool:.redact,points:[CGPoint(x:10,y:10),CGPoint(x:30,y:30)],red:0,green:0,blue:0,width:4))
    let redacted=try doc.flatten();let pixel=try CaptureColorSampler.pixel(in:redacted,at:CGPoint(x:20,y:20));try require(pixel.red==0 && pixel.green==0 && pixel.blue==0,"solid redaction flattened")
    doc.undo();try require(doc.state.layers.isEmpty,"undo")
    doc.redo();try require(doc.state.layers.count==1,"redo")
    doc.add(AnnotationLayer(tool:.crop,points:[CGPoint(x:0,y:0),CGPoint(x:40,y:30)]));doc.rotate();let rotated=try doc.flatten();try require(rotated.width==30 && rotated.height==40,"crop rotation dims")
    let exported=root.appendingPathComponent("export.png");try doc.export(to:exported);let reloaded=try readImage(exported);try require(reloaded.width==30 && reloaded.height==40,"reloaded export")
    let editable=root.appendingPathComponent("edit.gaoannotation");try doc.saveEditable(to:editable);let opened=try AnnotationDocument.loadEditable(editable)
    try require(opened.state==doc.state && opened.originalSHA256==doc.originalSHA256,"editable original layers roundtrip")
    try require(try pngData(image)==pngData(doc.original),"original unchanged")
    print("Core/Annotation/Backup: PASS")
}
