import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

struct UserError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone = "麦克风"
    case system = "电脑声音"
    var id: String { rawValue }
    var symbol: String { self == .microphone ? "mic.fill" : "speaker.wave.2.fill" }
}

// Accessed by the audio callback queues and by the main thread on stop.
final class AudioWriter {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failure: Error?
    private var closed = false
    let url: URL
    var onLevel: ((Float) -> Void)?
    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, failure == nil, buffer.frameLength > 0 else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            if let data = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var power: Float = 0
                for i in 0..<count { power += data[i] * data[i] }
                let rms = sqrt(power / Float(count))
                onLevel?(min(1, max(0, (20 * log10(max(rms, 0.0001)) + 55) / 55)))
            }
        } catch { failure = error }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file = nil // Finalize the CAF header before another process reads it.
        if let failure { throw failure }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UserError("没有收到音频。请检查录音来源、音量和录音权限。")
        }
    }
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var writer: AudioWriter?
    private let queue = DispatchQueue(label: "local.voiceprint.audio")
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(writer: AudioWriter? = nil) {
        self.writer = writer
        super.init()
    }

    func start(source: AudioSource, url: URL) async throws {
        let writer = AudioWriter(url: url)
        writer.onLevel = onLevel
        self.writer = writer
        if source == .microphone {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else {
                self.writer = nil
                throw UserError("麦克风权限未开启。请到「系统设置 → 隐私与安全性 → 麦克风」允许声纹对比。")
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.writer = nil
                throw UserError("没有可用的麦克风，请先连接或在系统设置中选择输入设备。")
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                writer.append(buffer)
            }
            engine.prepare()
            do { try engine.start(); self.engine = engine }
            catch { input.removeTap(onBus: 0); self.writer = nil; throw error }
        } else {
            do {
                // ScreenCaptureKit requests macOS consent only after the record button is clicked.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw UserError("没有找到可采集音频的显示器。") }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 16000
                config.channelCount = 1
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3
                let capture = SCStream(filter: filter, configuration: config, delegate: self)
                // Deliberately register only an audio output: no video is saved or processed.
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                self.stream = capture
                try await capture.startCapture()
            } catch {
                self.stream = nil
                self.writer = nil
                let nativeError = error as NSError
                if nativeError.domain == SCStreamErrorDomain && nativeError.code == -3801 {
                    throw UserError("电脑声音录制权限尚未允许。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中开启声纹对比，然后退出并重新打开程序。")
                }
                throw UserError("无法录制电脑声音：\(error.localizedDescription)\n请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中允许声纹对比；授权后可退出并重新打开程序。")
            }
        }
    }

    func stop() async throws {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        var stopError: Error?
        if let stream {
            do { try await stream.stopCapture() } catch { stopError = error }
            self.stream = nil
        }
        queue.sync {} // Drain pending system-audio callbacks before finalizing the file.
        let writer = self.writer
        self.writer = nil
        try writer?.finish()
        if let stopError { throw stopError }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(UserError("系统音频录制已中断：\(error.localizedDescription)"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        consume(sample)
    }

    func consume(_ sample: CMSampleBuffer) {
        guard sample.isValid,
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var required = 0
        var retained: CMBlockBuffer?
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &required,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: flags, blockBufferOut: nil)
        guard required > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: flags, blockBufferOut: &retained)
        guard status == noErr,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
        withExtendedLifetime(retained) { writer?.append(pcm) }
    }
}
