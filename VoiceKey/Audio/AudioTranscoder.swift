import AVFoundation
import Foundation

/// 音频后处理：切片与压缩上传。
///
/// 为什么不是 Opus：Typeless 端上编 Opus（16 kHz / 32 kbps）是因为**服务端是它自己的**，
/// 可以解自定义的 Ogg-Opus 流；我们直连第三方 ASR，只能交它认得的容器。
/// 这里用 iOS 原生就能编的 AAC/m4a：16 kHz 单声道 32 kbps 时体积约为 WAV 的 1/20。
enum AudioTranscoder {
    /// 按秒把 PCM16 切片（用于长录音分段识别）。
    static func chunks(pcm16: Data, seconds: Double, sampleRate: Double = AudioRecorder.targetSampleRate) -> [Data] {
        let bytesPerChunk = Int(seconds * sampleRate) * 2
        guard bytesPerChunk > 0, pcm16.count > bytesPerChunk else { return pcm16.isEmpty ? [] : [pcm16] }
        var result: [Data] = []
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + bytesPerChunk, pcm16.count)
            result.append(pcm16.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    /// PCM16 16 kHz 单声道 → AAC（m4a 容器）。
    static func encodeAAC(pcm16: Data, sampleRate: Double = AudioRecorder.targetSampleRate, bitRate: Int = 32_000) throws -> Data {
        let frames = pcm16.count / 2
        guard frames > 0 else { throw TranscoderError.empty }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw TranscoderError.format
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let destination = buffer.int16ChannelData?[0] else { return }
            memcpy(destination, base, pcm16.count)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vk-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings,
                                                 commonFormat: .pcmFormatInt16, interleaved: true)
        try file?.write(from: buffer)
        file = nil                      // 关闭文件后才能读回完整 moov
        return try Data(contentsOf: url)
    }

    enum TranscoderError: LocalizedError {
        case empty, format

        var errorDescription: String? {
            switch self {
            case .empty: "没有音频数据可压缩。"
            case .format: "无法创建 AAC 编码器。"
            }
        }
    }
}
