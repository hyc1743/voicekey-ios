import AVFoundation
import Foundation

/// 16 kHz / 单声道 / 16-bit PCM 采集。
///
/// 与 Typeless 的做法一致（16 kHz 单声道是语音识别的最佳性价比区间），
/// 但这里只产出 WAV，不做 Opus：先保证链路可用，编解码留给后续优化。
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pcm = Data()
    private let lock = NSLock()

    private(set) var isRunning = false
    private(set) var level: Float = 0

    /// 音频线程回调，调用方需自行切回主线程。
    var onLevel: ((Float) -> Void)?

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(pcm.count / 2) / Self.targetSampleRate
    }

    /// 申请麦克风权限（首次调用会弹系统框）。
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1,
                                         interleaved: true) else {
            throw RecorderError.formatUnavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        guard let converter = AVAudioConverter(from: hardware, to: format) else {
            throw RecorderError.formatUnavailable
        }

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        lock.unlock()
        self.converter = converter
        targetFormat = format

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// 读取从 `offset` 字节开始的 PCM 增量，用于边录边识别的分段提交。
    func pcm(from offset: Int) -> (data: Data, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let total = pcm.count
        guard offset >= 0, offset < total else { return (Data(), total) }
        return (pcm.subdata(in: offset..<total), total)
    }

    /// 停止并返回原始 PCM16（16 kHz 单声道）；无有效音频时返回 nil。
    func stop() -> Data? {
        guard isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        converter = nil

        lock.lock()
        let samples = pcm
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()
        guard samples.count > Int(Self.targetSampleRate / 2) else { return nil }   // < 0.25 s 视为误触
        return samples
    }

    func cancel() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        converter = nil
        lock.lock(); pcm.removeAll(); lock.unlock()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var provided = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        guard conversionError == nil, output.frameLength > 0,
              let channel = output.int16ChannelData else { return }

        let count = Int(output.frameLength)
        let bytes = Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size)
        lock.lock()
        // 上限 3 分钟，防止异常情况下无限增长
        if pcm.count < Int(Self.targetSampleRate) * 2 * 180 { pcm.append(bytes) }
        lock.unlock()

        var sum: Double = 0
        for index in 0..<count { let value = Double(channel[0][index]) / 32768.0; sum += value * value }
        let rms = Float((sum / Double(max(count, 1))).squareRoot())
        level = rms
        onLevel?(rms)
    }

    /// 生成 44 字节头 + PCM16 的 WAV。
    static func wav(fromPCM16 samples: Data) -> Data {
        var data = Data(capacity: samples.count + 44)
        let byteRate = UInt32(targetSampleRate) * 2
        let chunkSize = UInt32(samples.count + 36)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(chunkSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))            // fmt chunk size
        append(UInt16(1))             // PCM
        append(UInt16(1))             // mono
        append(UInt32(targetSampleRate))
        append(byteRate)
        append(UInt16(2))             // block align
        append(UInt16(16))            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    enum RecorderError: LocalizedError {
        case formatUnavailable, inputUnavailable

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: "无法创建 16 kHz 音频格式。"
            case .inputUnavailable: "麦克风不可用，请检查权限或是否被其他 App 占用。"
            }
        }
    }
}
