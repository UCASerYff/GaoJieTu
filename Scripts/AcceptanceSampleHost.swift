import AppKit
import AVFoundation

// Synthetic test app only. Compiled into ignored TestResults by make_samples.sh; never part of GaoJieTu.app.
private final class FlippedSampleDocument: NSView { override var isFlipped: Bool { true } }
@MainActor
final class AcceptanceSampleDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let content = NSStackView()
    private let header = NSTextField(labelWithString: "自建滚动样本 - 240行 - 固定页眉")
    private let counter = NSTextField(labelWithString: "动画计数：关闭")
    private var timer: Timer?
    private var tick = 0
    private var engine: AVAudioEngine?
    private var toneButton: NSButton!
    private var fixedHeader: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "退出自建验收样本", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: CGRect(x: 160, y: 120, width: 1000, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "搞截图自建验收样本 - 非个人资料"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        header.font = .boldSystemFont(ofSize: 24); root.addArrangedSubview(header)
        fixedHeader = NSButton(checkboxWithTitle: "固定页眉", target: self, action: #selector(changeHeader)); fixedHeader.state = .on
        let animate = NSButton(checkboxWithTitle: "启用动画计数", target: self, action: #selector(changeAnimation))
        toneButton = NSButton(title: "播放440Hz原创测试音", target: self, action: #selector(toggleTone))
        let controls = NSStackView(views: [fixedHeader, animate, counter, toneButton]); controls.orientation = .horizontal; controls.spacing = 18; root.addArrangedSubview(controls)
        let note = NSTextField(wrappingLabelWithString: "只有本窗口的合成文字。音频默认关闭，按钮开启后以约-26 dBFS播放440Hz正弦波；停止/退出即静音。长截图请核对ROW 001至240不重复不缺行。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; root.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 0; content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedSampleDocument(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document
        for index in 1...240 {
            let line = NSTextField(wrappingLabelWithString: String(format: "ROW %03d | 第%d行：这是自建滚动样本。\nCapture synthetic line %d. CHECK %06d. Keep overlap and inspect the seam.", index, index, index, index * 7919 % 1_000_000))
            line.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
            line.maximumNumberOfLines = 3; line.backgroundColor = index % 2 == 0 ? NSColor(white: 0.94, alpha: 1) : .white
            line.drawsBackground = true; line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 90).isActive = true
            content.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let end = NSTextField(labelWithString: "END 240 - 滚动边界"); end.font = .boldSystemFont(ofSize: 22); content.addArrangedSubview(end)
        root.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func changeHeader() { header.isHidden = fixedHeader.state != .on }
    @objc private func changeAnimation(_ sender: NSButton) {
        timer?.invalidate(); timer = nil
        if sender.state == .on { timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.tick += 1; self.counter.stringValue = "动画计数：\(self.tick)" } } }
        else { counter.stringValue = "动画计数：关闭" }
    }
    @objc private func toggleTone() {
        if engine != nil { stopTone(); return }
        do {
            let newEngine = AVAudioEngine(); let sampleRate: Double = 48000
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            // Phase belongs only to AVAudioEngine's serial render callback. No captured microphone/audio.
            var phase = 0.0
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    let value = Float(sin(phase) * 0.05); phase += 2 * .pi * 440 / sampleRate
                    if phase >= 2 * .pi { phase -= 2 * .pi }
                    for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value }
                }
                return noErr
            }
            newEngine.attach(source); newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
            try newEngine.start(); engine = newEngine; toneButton.title = "停止440Hz测试音"
        } catch { counter.stringValue = "音频输出失败：\(error.localizedDescription)"; stopTone() }
    }
    private func stopTone() { engine?.stop(); engine = nil; toneButton?.title = "播放440Hz原创测试音" }
    func windowWillClose(_ notification: Notification) { stopTone(); timer?.invalidate(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { stopTone(); timer?.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct AcceptanceSampleMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AcceptanceSampleDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
