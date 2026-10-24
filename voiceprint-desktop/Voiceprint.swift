import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import UniformTypeIdentifiers

private let ink = Color(red: 0.12, green: 0.18, blue: 0.25)
private let accent = Color(red: 0.23, green: 0.35, blue: 0.94)
private let muted = Color(red: 0.47, green: 0.51, blue: 0.59)
private let paper = Color(red: 0.965, green: 0.97, blue: 0.99)

struct Clip {
    var url: URL
    var duration: Double
    var label: String
    var source: String
}

struct Runtime: Decodable { var python: String; var model: String; var worker: String }
struct Comparison: Decodable {
    var ok: Bool
    var score: Double?
    var durations: [Double]?
    var elapsed: Double?
    var error: String?
}

func runComparison(a: URL, b: URL) throws -> Comparison {
    guard let resource = Bundle.main.url(forResource: "runtime", withExtension: "json") else {
        throw UserError("程序资源不完整，请重新运行安装脚本。")
    }
    let runtime = try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: resource))
    guard FileManager.default.isExecutableFile(atPath: runtime.python) else {
        throw UserError("本地 Python 环境不存在，请重新运行安装脚本。")
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: runtime.python)
    task.arguments = ["-I", runtime.worker]
    task.currentDirectoryURL = URL(fileURLWithPath: runtime.worker).deletingLastPathComponent()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    task.standardInput = input
    task.standardOutput = output
    task.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PYTHONUNBUFFERED"] = "1"
    task.environment = environment
    // Drain stderr concurrently so an unexpected library error cannot fill the pipe.
    errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    try task.run()
    let request: [String: String] = ["model": runtime.model, "audio_a": a.path, "audio_b": b.path]
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
    try input.fileHandleForWriting.close()
    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    timeout.cancel()
    errors.fileHandleForReading.readabilityHandler = nil
    guard !data.isEmpty else { throw UserError("本地声纹引擎没有返回结果，或运行超时。请重新尝试。") }
    let result = try JSONDecoder().decode(Comparison.self, from: data)
    guard result.ok else { throw UserError(result.error ?? "声纹对比失败，请重新录音。") }
    return result
}

@MainActor final class AppState: ObservableObject {
    @Published var clips: [Clip?] = [nil, nil]
    @Published var sources: [AudioSource] = [.microphone, .system]
    @Published var active: Int?
    @Published var pending: Int?
    @Published var elapsed: Double = 0
    @Published var level: Float = 0
    @Published var busy = false
    @Published var result: Comparison?
    @Published var error: String?
    @Published var threshold: Double = 0.6
    @Published var playing: Int?
    @Published var finalizing = false
    var changedRecording: ((Bool) -> Void)?
    private let capture = AudioCapture()
    private var timer: Timer?
    private var startDate: Date?
    private var recordingURL: URL?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    let storage: URL

    init() {
        storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceprintDesktop/Recordings", isDirectory: true)
        do { try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true) }
        catch { self.error = "无法创建录音目录：\(error.localizedDescription)" }
        capture.onLevel = { [weak self] value in
            DispatchQueue.main.async { if self?.active != nil { self?.level = value } }
        }
        capture.onFailure = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.active != nil, !self.finalizing else { return }
                await self.stopRecording()
                self.error = failure.localizedDescription
            }
        }
    }

    var locked: Bool { busy || active != nil || pending != nil || finalizing }
    var canCompare: Bool { !locked && clips[0] != nil && clips[1] != nil }

    func record(_ index: Int) {
        if active == index { Task { await stopRecording() }; return }
        guard !locked else { return }
        stopPlayback()
        error = nil
        pending = index
        let source = sources[index]
        let url = storage.appendingPathComponent("\(UUID().uuidString).caf")
        Task { [self] in
            do {
                try await capture.start(source: source, url: url)
                pending = nil
                active = index
                recordingURL = url
                startDate = Date()
                elapsed = 0
                level = 0
                result = nil
                changedRecording?(true)
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let started = self.startDate, !self.finalizing else { return }
                        self.elapsed = Date().timeIntervalSince(started)
                        if self.elapsed >= 45 { await self.stopRecording() }
                    }
                }
            } catch {
                pending = nil
                self.error = error.localizedDescription
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func stopRecording() async {
        guard let index = active, !finalizing else { return }
        finalizing = true
        timer?.invalidate()
        timer = nil
        do {
            try await capture.stop()
            if let url = recordingURL {
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                guard duration >= 1 else { throw UserError("录音不足 1 秒，请录制至少 5 秒清晰讲话。") }
                replace(index, with: Clip(url: url, duration: duration,
                        label: "录音 \(index == 0 ? "A" : "B")", source: sources[index].rawValue))
            }
        } catch {
            self.error = error.localizedDescription
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        }
        active = nil
        recordingURL = nil
        startDate = nil
        level = 0
        finalizing = false
        changedRecording?(false)
    }

    func replace(_ index: Int, with clip: Clip?) {
        stopPlayback()
        if let old = clips[index], old.url.deletingLastPathComponent() == storage {
            try? FileManager.default.removeItem(at: old.url)
        }
        clips[index] = clip
        result = nil
    }

    func importFile(_ index: Int) {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.title = "选择录音 \(index == 0 ? "A" : "B")"
        panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3, .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let audio = try AVAudioFile(forReading: url)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration >= 1, duration <= 60 else { throw UserError("请选择 1–60 秒的录音，建议 5–15 秒。") }
            // Convert imports to CAF so the Python audio reader supports MP3/M4A too.
            let copy = storage.appendingPathComponent("\(UUID().uuidString).caf")
            do {
                let writer = try AVAudioFile(forWriting: copy, settings: audio.processingFormat.settings)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192) else {
                    throw UserError("无法分配音频缓冲区。")
                }
                while audio.framePosition < audio.length {
                    try audio.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    try writer.write(from: buffer)
                }
                replace(index, with: Clip(url: copy, duration: duration, label: url.lastPathComponent, source: "导入文件"))
                error = nil
            } catch { try? FileManager.default.removeItem(at: copy); throw error }
        } catch { self.error = "无法导入音频：\(error.localizedDescription)" }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        playing = nil
    }

    func play(_ index: Int) {
        guard !locked, let clip = clips[index] else { return }
        if playing == index { stopPlayback(); return }
        stopPlayback()
        do {
            player = try AVAudioPlayer(contentsOf: clip.url)
            guard player?.play() == true else { throw UserError("无法播放这段录音。") }
            playing = index
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in if self?.player?.isPlaying == false { self?.stopPlayback() } }
            }
        } catch { self.error = error.localizedDescription }
    }

    func compare() {
        guard canCompare, let a = clips[0], let b = clips[1] else { return }
        stopPlayback()
        busy = true
        error = nil
        result = nil
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) { try runComparison(a: a.url, b: b.url) }.value
                result = value
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func showPermissions(_ source: AudioSource = .system) {
        let pane = source == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct WaveMark: View {
    var color: Color = .white
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array([12.0, 23, 34, 19, 29, 12].enumerated()), id: \.offset) { _, h in
                Capsule().fill(color).frame(width: 4, height: h)
            }
        }
    }
}

struct MeterView: View {
    var live: Bool
    var level: Float
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<55, id: \.self) { i in
                    let shape = (sin(Double(i) * 1.8) + cos(Double(i) * 0.43) + 2) / 4
                    let height = live ? 5 + Double(level) * (10 + shape * 33) : 4 + shape * 8
                    Capsule().fill(live ? Color(red: 0.92, green: 0.33, blue: 0.38) : accent.opacity(0.2))
                        .frame(width: max(2, (geometry.size.width - 162) / 55), height: height)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: 42).animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel(live ? "实时录音音量" : "音频预览区域")
    }
}

struct ClipCard: View {
    @ObservedObject var state: AppState
    let index: Int
    var recording: Bool { state.active == index }
    var clip: Clip? { state.clips[index] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(index == 0 ? "A" : "B").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(accent).frame(width: 28, height: 28).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                Text(index == 0 ? "参考录音" : "待比对录音").font(.system(size: 14, weight: .semibold))
                Spacer()
                if recording {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.red)
                } else if let clip {
                    Text(String(format: "%.1f 秒", clip.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                }
            }
            HStack {
                Picker("录音来源", selection: $state.sources[index]) {
                    ForEach(AudioSource.allCases) { source in Label(source.rawValue, systemImage: source.symbol).tag(source) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 222).disabled(state.locked)
                Spacer()
                if clip != nil && !state.locked {
                    Button { state.play(index) } label: {
                        Image(systemName: state.playing == index ? "stop.fill" : "play.fill").font(.system(size: 11))
                    }.buttonStyle(.plain).help("试听录音").accessibilityLabel("试听录音\(index == 0 ? "A" : "B")")
                    Button { state.replace(index, with: nil) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(muted).padding(.leading, 8).help("清除录音")
                }
            }
            MeterView(live: recording, level: recording ? state.level : 0)
            HStack(spacing: 10) {
                Button { state.record(index) } label: {
                    HStack(spacing: 6) {
                        if state.pending == index || (recording && state.finalizing) {
                            ProgressView().controlSize(.mini)
                        } else { Image(systemName: recording ? "stop.fill" : "record.circle") }
                        Text(state.pending == index ? "正在获取权限…" : (recording ? (state.finalizing ? "正在保存…" : "停止录音") : (clip == nil ? "开始录音" : "重新录音")))
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(height: 31)
                    .foregroundStyle(recording ? Color.red : accent)
                    .background(recording ? Color.red.opacity(0.08) : accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(state.pending != nil || state.busy || state.finalizing || (state.active != nil && !recording))
                    .accessibilityLabel("\(recording ? "停止" : "录制")录音\(index == 0 ? "A" : "B")")
                Button("导入音频") { state.importFile(index) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(muted).disabled(state.locked)
                Spacer()
                Text(recording ? "最多 45 秒 · 只录一人" : (clip?.label ?? "建议录制 5–15 秒清晰讲话"))
                    .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
            }
        }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(recording ? Color.red.opacity(0.4) : Color.black.opacity(0.06), lineWidth: 1))
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    var collapse: () -> Void
    var verdict: String {
        guard let score = state.result?.score else { return "等待两段录音" }
        if abs(score - state.threshold) < 0.08 { return "接近判断阈值，建议复录" }
        return score >= state.threshold ? "较可能为同一说话人" : "较可能为不同说话人"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    WaveMark().scaleEffect(0.65).frame(width: 43, height: 43)
                        .background(LinearGradient(colors: [accent, Color(red: 0.43, green: 0.34, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("声纹对比").font(.system(size: 23, weight: .bold))
                        Text("听见声音，也识别声音。 ").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    HStack(spacing: 5) { Circle().fill(Color.green).frame(width: 5, height: 5); Text("本地运行") }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(muted).padding(8)
                        .background(.white, in: Capsule())
                }.padding(.top, 4)
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").foregroundStyle(accent)
                    Text("音频与声纹分析均留在这台 Mac，不上传云端。")
                }.font(.system(size: 11)).foregroundStyle(muted)

                ClipCard(state: state, index: 0)
                ClipCard(state: state, index: 1)

                if let error = state.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("麦克风权限") { state.showPermissions(.microphone) }
                            Button("系统音频权限") { state.showPermissions(.system) }
                            Spacer()
                            Button("关闭提示") { state.error = nil }
                        }.font(.system(size: 10)).buttonStyle(.plain)
                    }.foregroundStyle(Color(red: 0.62, green: 0.29, blue: 0.16)).padding(12)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                Button { state.compare() } label: {
                    HStack(spacing: 8) {
                        if state.busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "waveform.path") }
                        Text(state.busy ? "正在分析两段声纹…" : "开始声纹对比").font(.system(size: 14, weight: .semibold))
                    }.frame(maxWidth: .infinity).frame(height: 45).foregroundStyle(.white)
                        .background(state.canCompare || state.busy ? accent : accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(!state.canCompare).keyboardShortcut(.return, modifiers: .command)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(verdict).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if let score = state.result?.score {
                            Text(String(format: "%.3f", score)).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(accent)
                        } else { Text("—").font(.system(size: 25)).foregroundStyle(muted) }
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(accent.opacity(0.08))
                            Capsule().fill(accent).frame(width: geometry.size.width * max(0, min(1, state.result?.score ?? 0)))
                            Rectangle().fill(ink.opacity(0.5)).frame(width: 2, height: 14).offset(x: geometry.size.width * state.threshold)
                        }
                    }.frame(height: 6)
                    HStack {
                        Text("判断阈值").font(.system(size: 10)).foregroundStyle(muted)
                        Slider(value: $state.threshold, in: 0.3...0.85, step: 0.01).controlSize(.mini).tint(accent)
                            .accessibilityLabel("判断阈值")
                        Text(String(format: "%.2f", state.threshold)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    }
                    Text("相似度不是身份概率。噪声、多人混音与变声会影响结果；阈值需用实际录音校准。")
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    if let elapsed = state.result?.elapsed {
                        Text(String(format: "ERes2NetV2 · 本次分析 %.2f 秒", elapsed)).font(.system(size: 10)).foregroundStyle(muted)
                    }
                }.padding(16).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))

                HStack {
                    Button { NSWorkspace.shared.open(state.storage) } label: { Label("录音文件夹", systemImage: "folder") }
                    Spacer()
                    Button("收起到悬浮球", action: collapse)
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted)
            }.padding(24)
        }.background(paper).foregroundStyle(ink).frame(minWidth: 560, minHeight: 670)
            .preferredColorScheme(.light)
    }
}

final class OrbView: NSView {
    var activate: (() -> Void)?
    var menuAction: ((NSEvent) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var moved = false
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("声纹对比悬浮球")
        setAccessibilityHelp("点击打开声纹对比；按住拖动可移动；右键退出。")
        toolTip = "点击打开声纹对比 · 拖动移动 · 右键菜单"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityPerformPress() -> Bool { activate?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let colors: [NSColor] = recording
            ? [.systemRed, NSColor(red: 0.75, green: 0.19, blue: 0.35, alpha: 1)]
            : [NSColor(red: 0.38, green: 0.46, blue: 1, alpha: 1), NSColor(red: 0.27, green: 0.24, blue: 0.82, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: circle, angle: -65)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        for (i, height) in [13.0, 23, 32, 19, 27, 12].enumerated() {
            let bar = NSBezierPath(roundedRect: NSRect(x: 20 + Double(i) * 6.5,
                y: (bounds.height - height) / 2, width: 3.5, height: height), xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); bar.fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x - startMouse.x, point.y - startMouse.y) > 3 { moved = true }
        if moved { window?.setFrameOrigin(NSPoint(x: startOrigin.x + point.x - startMouse.x, y: startOrigin.y + point.y - startMouse.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        if moved {
            guard let window else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            var origin = window.frame.origin
            origin.x = min(max(origin.x, visible.minX), visible.maxX - window.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - window.frame.height)
            window.setFrameOrigin(origin)
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "orbPosition")
        } else { activate?() }
    }
    override func rightMouseDown(with event: NSEvent) { menuAction?(event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var state: AppState!
    var orb: NSPanel!
    var panel: NSPanel!
    var orbView: OrbView!
    var statusItem: NSStatusItem!
    var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 780),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "声纹对比"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.minSize = NSSize(width: 560, height: 700)
        panel.contentView = NSHostingView(rootView: ContentView(state: state, collapse: { [weak self] in self?.panel.orderOut(nil) }))
        panel.center()
        orb = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 78, height: 78),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        orb.backgroundColor = .clear
        orb.isOpaque = false
        orb.hasShadow = false
        orb.level = .floating
        orb.hidesOnDeactivate = false
        orb.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
        orbView.activate = { [weak self] in self?.togglePanel() }
        orbView.menuAction = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self.orbView)
        }
        orb.contentView = orbView
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: visible.maxX - 100, y: visible.midY)
        if let saved = UserDefaults.standard.string(forKey: "orbPosition") {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: point, size: NSSize(width: 78, height: 78))) }) { origin = point }
        }
        orb.setFrameOrigin(origin)
        orb.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "声纹对比")
        statusItem.menu = makeMenu()
        state.changedRecording = { [weak self] recording in self?.orbView.recording = recording }
        if ProcessInfo.processInfo.arguments.contains("--show-panel") { togglePanel() }
        if let marker = ProcessInfo.processInfo.arguments.firstIndex(of: "--compare-files"),
           ProcessInfo.processInfo.arguments.count > marker + 2 {
            // Developer smoke test: imports only explicitly supplied files, never records audio.
            for i in 0..<2 {
                let url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[marker + i + 1])
                if let audio = try? AVAudioFile(forReading: url) {
                    state.clips[i] = Clip(url: url, duration: Double(audio.length) / audio.processingFormat.sampleRate,
                                          label: url.lastPathComponent, source: "导入文件")
                }
            }
            showPanel(nil)
            state.compare()
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开声纹对比", action: #selector(showPanel(_:)), keyEquivalent: "")
        open.target = self
        let folder = menu.addItem(withTitle: "打开录音文件夹", action: #selector(showFolder(_:)), keyEquivalent: "")
        folder.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出声纹对比", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        return menu
    }
    func togglePanel() { if panel.isVisible { panel.orderOut(nil) } else { showPanel(nil) } }
    @objc func showPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func showFolder(_ sender: Any?) { NSWorkspace.shared.open(state.storage) }
    @objc func quitApp(_ sender: Any?) { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.pending != nil { state.error = "正在等待系统权限，请先处理权限弹窗再退出。"; showPanel(nil); return .terminateCancel }
        if state.finalizing { state.error = "录音正在保存，请稍候再退出。"; showPanel(nil); return .terminateCancel }
        guard state.active != nil, !terminating else { return .terminateNow }
        terminating = true
        Task { await state.stopRecording(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct VoiceprintApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
