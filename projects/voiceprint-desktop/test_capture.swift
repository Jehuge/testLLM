// Synthetic audio validates the real ScreenCaptureKit buffer conversion and file
// finalization without accessing the screen or microphone or requesting permissions.
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@main struct CapturePipelineTests {
    static func main() async throws {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3801)
        let failed = NSError(domain: SCStreamErrorDomain, code: -3802)
        guard CaptureErrorMessage.systemAudio(denied).contains("移除旧的"),
              CaptureErrorMessage.systemAudio(failed).contains("不一定是权限问题"),
              !CaptureErrorMessage.systemAudio(failed).contains("移除旧的") else {
            throw UserError("录音错误分类不正确。")
        }
        print("通过：授权失效与其他采集错误分别给出正确处理提示")
        for channels in [1, 2] {
            let rate = channels == 1 ? 16000.0 : 48000.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            pcm.frameLength = AVAudioFrameCount(rate)
            for channel in 0..<channels {
                for frame in 0..<Int(rate) {
                    pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 180 / rate) * 0.1)
                }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                sampleCount: Int(rate), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard created == noErr, let sample else { throw UserError("创建测试音频失败：\(created)") }
            let status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
            guard status == noErr else { throw UserError("设置测试音频数据失败：\(status)") }
            CMSampleBufferSetDataReady(sample)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-test-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: path) }
            let recorder = AudioCapture(writer: AudioWriter(url: path))
            recorder.consume(sample)
            try await recorder.stop()
            let saved = try AVAudioFile(forReading: path)
            guard saved.length == AVAudioFramePosition(rate), saved.processingFormat.channelCount == channels else {
                throw UserError("音频写入长度或声道数不正确。")
            }
            print("通过：\(Int(rate)) Hz / \(channels) 声道，采集缓冲区 → CAF 文件，完整 1 秒")
        }
    }
}
