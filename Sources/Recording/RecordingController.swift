import AppKit
import AVFoundation
import ScreenCaptureKit
import Combine
import CoreAudio

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var statusMessage = "录制仅在你点击开始后进行"
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var recoveryURL: URL?
    @Published private(set) var sources: [RecordingSource] = []
    @Published private(set) var metrics = RecordingMetrics()
    @Published private(set) var microphonePowerDB: Float = -160
    private var machine = RecordingStateMachine()
    private var pipeline: RecordingPipeline?
    private var stream: SCStream?
    private var audioRecorder: AVAudioRecorder?
    private var filePlan: RecordingFilePlan?
    private var activeConfiguration: RecordingConfiguration?
    private var timer: Timer?
    private var monitorTask: Task<Void, Never>?
    private var selectedMicrophoneID: String?
    private var selectedOutputDeviceID: AudioDeviceID?
    private var startedAt: Date?

    var isActive: Bool { [.preparing, .recording, .paused, .stopping].contains(state) }

    /// Explicit button action only; start() itself never opens permission dialogs.
    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func refreshSources() async {
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "列出屏幕和窗口需要屏幕录制权限；仅麦克风录音不需要此权限"
            sources = []
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var options = content.displays.map { RecordingSource(kind: .display, displayID: $0.displayID,
                name: "屏幕 \($0.displayID)（\($0.width) × \($0.height)）") }
            options += content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 1 && $0.frame.height > 1 }
                .map { RecordingSource(kind: .window, windowID: $0.windowID, processID: $0.owningApplication?.processID,
                    name: "\($0.owningApplication?.applicationName ?? "窗口") — \($0.title ?? "未命名窗口")") }
            sources = options
            statusMessage = "已读取可捕获源；受保护内容可能拒绝输出"
        } catch { statusMessage = error.localizedDescription }
    }

    func start(configuration: RecordingConfiguration) async {
        guard state == .idle || state == .failed else { return }
        do {
            try configuration.validate()
            if configuration.needsScreenPermission && !CGPreflightScreenCaptureAccess() {
                throw RecordingError.permission("屏幕录制权限未获准。请在系统设置授权后重试。")
            }
            if configuration.microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                throw RecordingError.permission("麦克风权限未获准。请点击麦克风授权按钮后重试。")
            }
            if configuration.microphone && !configuration.isMicrophoneOnly {
                guard #available(macOS 15.0, *) else { throw RecordingError.unsupported("录屏伴麦克风/系统音与麦克风组合需要 macOS 15；macOS 14 可独立录麦克风。") }
            }
            if configuration.highlightsMouseClicks {
                guard #available(macOS 15.0, *) else { throw RecordingError.unsupported("原生鼠标点击高亮需要 macOS 15") }
            }
            try changeState(.preparing)
            elapsed = 0; metrics = RecordingMetrics(); lastOutputURL = nil
            activeConfiguration = configuration
            let plan = try RecordingFilePlan(outputURL: configuration.outputURL)
            filePlan = plan; recoveryURL = plan.journalURL
            selectedMicrophoneID = configuration.microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            selectedOutputDeviceID = configuration.systemAudio ? RecordingAudioRoute.currentOutputDeviceID() : nil
            if configuration.microphone && selectedMicrophoneID == nil { throw RecordingError.sourceUnavailable("没有可用麦克风") }
            if configuration.isMicrophoneOnly {
                if let requested = configuration.microphoneDeviceID, requested != AVCaptureDevice.default(for: .audio)?.uniqueID {
                    throw RecordingError.unsupported("独立麦克风录音使用系统当前输入设备；请先在系统声音设置选择该设备。")
                }
                let recorder = try AVAudioRecorder(url: plan.partialURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                recorder.delegate = self
                recorder.isMeteringEnabled = true
                audioRecorder = recorder
                try writeMicrophoneJournal(state: .preparing)
                guard recorder.prepareToRecord(), recorder.record() else { throw RecordingError.writing("麦克风录音器无法启动") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.partialURL.path)
            } else {
                let (filter, captureConfiguration) = try await makeCapture(configuration)
                let writer = try RecordingPipeline(configuration: configuration, plan: plan,
                    width: captureConfiguration.width, height: captureConfiguration.height)
                writer.onFailure = { [weak self] error in Task { @MainActor in await self?.stop(failure: error) } }
                pipeline = writer
                let stream = SCStream(filter: filter, configuration: captureConfiguration, delegate: writer)
                self.stream = stream
                if configuration.mode == .video { try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue) }
                if configuration.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
                if configuration.microphone {
                    if #available(macOS 15.0, *) { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
                }
                try await stream.startCapture()
            }
            startedAt = Date()
            try changeState(.recording)
            statusMessage = configuration.mode == .audioOnly ? "● 正在仅录音；未创建屏幕视频轨" : "● 正在录屏；可随时暂停或停止"
            startMonitoring()
        } catch {
            if let stream { try? await stream.stopCapture() }
            stream = nil
            audioRecorder?.stop(); audioRecorder = nil
            if let pipeline { _ = try? await pipeline.finish(failure: error) }
            pipeline = nil
            if state != .preparing { try? changeState(.preparing) }
            try? changeState(.failed)
            statusMessage = error.localizedDescription
            stopMonitoring()
        }
    }

    func pause() {
        guard state == .recording else { return }
        pipeline?.setPaused(true)
        audioRecorder?.pause()
        try? changeState(.paused)
        try? writeMicrophoneJournal(state: .paused)
        statusMessage = "⏸ 已暂停；暂停时段不会写入输出时长"
    }

    func resume() {
        guard state == .paused else { return }
        if let recorder = audioRecorder, !recorder.record() {
            Task { await stop(failure: RecordingError.sourceUnavailable("麦克风无法恢复录音")) }; return
        }
        pipeline?.setPaused(false)
        try? changeState(.recording)
        try? writeMicrophoneJournal(state: .recording)
        statusMessage = "● 已继续录制"
    }

    func stop() async { await stop(failure: nil) }
    func cancel() async { await stop(failure: RecordingError.cancelled) }

    private func stop(failure: Error?) async {
        guard state == .recording || state == .paused || state == .preparing else { return }
        try? changeState(.stopping)
        let stoppedAtHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        stopMonitoring()
        statusMessage = "正在完成媒体容器，请稍候"
        var captureError = failure
        if let stream {
            do { try await stream.stopCapture() }
            catch { if captureError == nil { captureError = error } }
        }
        stream = nil
        do {
            guard let plan = filePlan, let config = activeConfiguration else { throw RecordingError.noSamples }
            if let recorder = audioRecorder {
                metrics.durationSeconds = recorder.currentTime
                recorder.stop()
                audioRecorder = nil
                if let captureError { try? writeMicrophoneJournal(state: .failed, failure: captureError); throw captureError }
                let asset = AVURLAsset(url: plan.partialURL)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration)
                guard tracks.count == 1, duration.isNumeric, duration.seconds > 0 else { throw RecordingError.noSamples }
                metrics.durationSeconds = duration.seconds
            } else if let pipeline {
                metrics = try await pipeline.finish(failure: captureError, atHostTime: stoppedAtHostTime)
                let asset = AVURLAsset(url: plan.partialURL)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let expectedAudio = (config.systemAudio ? 1 : 0) + (config.microphone ? 1 : 0)
                guard videoTracks.count == (config.mode == .video ? 1 : 0), audioTracks.count == expectedAudio else {
                    throw RecordingError.writing("导出轨道核对失败；中间文件已保留")
                }
            } else { throw captureError ?? RecordingError.noSamples }
            try plan.commit()
            lastOutputURL = plan.finalURL; recoveryURL = nil; elapsed = metrics.durationSeconds
            try changeState(.idle)
            statusMessage = config.mode == .audioOnly ? "已保存仅音频文件（无视频轨）；请回放核对音源" : "已保存录屏；请回放核对画面与音画同步"
        } catch {
            try? writeMicrophoneJournal(state: .failed, failure: error)
            try? changeState(.failed)
            statusMessage = "\(error.localizedDescription) 中间文件与恢复说明保留在所选输出目录。"
        }
        pipeline = nil; audioRecorder = nil
    }

    private func changeState(_ next: RecordingState) throws {
        try machine.transition(to: next); state = next
    }

    private func makeCapture(_ configuration: RecordingConfiguration) async throws -> (SCContentFilter, SCStreamConfiguration) {
        guard let source = configuration.source else { throw RecordingError.sourceUnavailable("没有选定捕获源") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        var rect: CGRect
        if source.kind == .window {
            guard let window = content.windows.first(where: { $0.windowID == source.windowID && $0.owningApplication?.processID == source.processID }) else {
                throw RecordingError.sourceUnavailable("选定窗口已关闭或身份发生变化")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            rect = CGRect(origin: .zero, size: window.frame.size)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else { throw RecordingError.sourceUnavailable("选定屏幕已断开") }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            rect = source.kind == .region ? (source.region ?? .null) : bounds
            guard bounds.contains(rect), !rect.isEmpty else { throw RecordingError.sourceUnavailable("区域超出选定屏幕，请重新选择") }
        }
        let config = SCStreamConfiguration()
        if configuration.mode == .video {
            let scale = Double(filter.pointPixelScale)
            let fullWidth = rect.width * scale, fullHeight = rect.height * scale
            let ratio = min(1, Double(configuration.maximumPixelDimension) / max(fullWidth, fullHeight))
            config.width = max(2, Int(fullWidth * ratio) / 2 * 2)
            config.height = max(2, Int(fullHeight * ratio) / 2 * 2)
            config.sourceRect = rect
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        } else {
            // No .screen output is registered, and no AVAssetWriter video input is constructed.
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        }
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = configuration.mode == .video && configuration.showsCursor
        config.capturesAudio = configuration.systemAudio
        config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        config.streamName = "搞截图 — 用户主动录制"
        if #available(macOS 15.0, *) {
            config.captureMicrophone = configuration.microphone
            config.microphoneCaptureDeviceID = selectedMicrophoneID
            config.showMouseClicks = configuration.highlightsMouseClicks
        }
        return (filter, config)
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let pipeline = self.pipeline { self.metrics = pipeline.snapshot(); self.elapsed = self.metrics.durationSeconds }
                if let recorder = self.audioRecorder {
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters(); self.microphonePowerDB = recorder.averagePower(forChannel: 0)
                    self.metrics.durationSeconds = self.elapsed
                }
            }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.state == .recording || self.state == .paused else { return }
                do { try await self.checkSources(); try self.writeMicrophoneJournal(state: self.state) }
                catch { await self.stop(failure: error); return }
            }
        }
    }

    private func stopMonitoring() { timer?.invalidate(); timer = nil; monitorTask?.cancel(); monitorTask = nil }

    private func checkSources() async throws {
        guard let config = activeConfiguration else { return }
        if let plan = filePlan,
           let free = RecordingDiskSpace.available(at: plan.finalURL.deletingLastPathComponent()),
           free < 8 * 1024 * 1024 { throw RecordingError.lowDiskSpace }
        if config.microphone {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw RecordingError.permission("麦克风权限已撤销") }
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            guard devices.contains(where: { $0.uniqueID == selectedMicrophoneID && $0.isConnected }) else { throw RecordingError.sourceUnavailable("选定麦克风已断开；未切换到其他音源") }
            if config.isMicrophoneOnly && AVCaptureDevice.default(for: .audio)?.uniqueID != selectedMicrophoneID {
                throw RecordingError.sourceUnavailable("系统输入设备发生变化；已停止以免悄悄切换音源")
            }
        }
        if config.systemAudio, let previous = selectedOutputDeviceID {
            guard let current = RecordingAudioRoute.currentOutputDeviceID() else {
                throw RecordingError.sourceUnavailable("系统音频输出设备不可用；已停止以便核对音源")
            }
            if current != previous {
                selectedOutputDeviceID = current
                if state == .recording { pause() }
                statusMessage = "耳机或系统音频输出设备发生变化，已暂停。请核对新音源后点击继续。"
            }
        }
        if config.needsScreenPermission {
            guard CGPreflightScreenCaptureAccess() else { throw RecordingError.permission("屏幕录制权限已撤销") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if config.source?.kind == .window {
                guard content.windows.contains(where: { $0.windowID == config.source?.windowID && $0.owningApplication?.processID == config.source?.processID }) else {
                    throw RecordingError.sourceUnavailable("选定窗口已关闭或进程已变化")
                }
            } else if !content.displays.contains(where: { $0.displayID == config.source?.displayID }) {
                throw RecordingError.sourceUnavailable("选定屏幕已断开；未切换到其他屏幕")
            }
        }
    }

    private func writeMicrophoneJournal(state: RecordingState, failure: Error? = nil) throws {
        guard let config = activeConfiguration, config.isMicrophoneOnly, let plan = filePlan else { return }
        let now = Date()
        let record = RecordingRecoveryRecord(sessionID: plan.id, createdAt: startedAt ?? now, updatedAt: now, state: state,
            mode: .audioOnly, sourceDescription: "系统当前麦克风", partialFileName: plan.partialURL.lastPathComponent,
            requestedFileName: plan.finalURL.lastPathComponent, systemAudio: false, microphone: true,
            metrics: metrics, failure: failure?.localizedDescription)
        try plan.writeJournal(record)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in await self?.stop(failure: error ?? RecordingError.writing("麦克风编码器失败")) }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor [weak self] in await self?.stop(failure: RecordingError.writing("麦克风录音意外停止")) }
    }
}

private enum RecordingAudioRoute {
    static func currentOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}
