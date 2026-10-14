import AVFoundation
import Foundation

/// 16 kHz / 单声道 / 16-bit PCM 采集，支持"麦克风常开（warm）"待命。
///
/// 为什么必须支持 warm：iOS 不允许 App 在**后台**把音频会话切到 `.playAndRecord` 并激活，
/// 后台尝试会得到 CoreAudio `'what'`（2003329396）。已验证实现（Voxt-ios）的做法是
/// 在**前台**就 `arm()`：配好 `.playAndRecord` + `setActive(true)` + 装好 input tap，
/// 让 `engine.isRunning == true`；键盘触发时只把 `isCapturing` 翻成 true，不再动会话。
/// 本项目此前只有静音输出/画中画两种待命，它们保住了进程却保不住"能开输入"，因此跨 App 必然失败。
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000
    /// 允许缓存的最长音频（实时通道上限；批量通道由引擎按 300 秒提前停止）。
    /// 540 秒 × 32 KB/s ≈ 17 MB。
    static let maxSeconds: Double = 540

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var tapInstalled = false

    private var pcm = Data()
    private var capturing = false
    private var lastAudioAt = Date.distantPast
    private let lock = NSLock()

    private(set) var level: Float = 0

    /// 音频线程回调（RMS + 本块时长秒），调用方需自行切回主线程。
    var onLevel: ((Float, Double) -> Void)?
    /// 每块转换后的 16 kHz PCM16（音频线程回调）。实时通道直接拿它上行，不再等攒成文件。
    var onPCM: ((Data) -> Void)?

    /// warm = 会话已激活且 engine 在跑（不代表正在采集）。
    var isWarm: Bool { engine.isRunning }
    /// 最近 2.5 秒内真的收到过音频：用来证明"warm 是真的在跑"，而不是僵死状态。
    var hasRecentAudio: Bool { Date().timeIntervalSince(lastAudioAt) < 2.5 }
    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

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

    // MARK: - Warm（待命）

    /// 在前台把录音会话与 engine 准备好。重复调用是幂等的。
    func arm() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // 与已验证实现一致：mode 用 .default（.measurement 会改输入处理链，且与画中画待命更易冲突）。
        // 蓝牙选项用 .allowBluetooth：新版 SDK 里它的替代名是 .allowBluetoothHFP，
        // 但那个符号在 Xcode 16 的 iOS 18 SDK 里不存在，为保证任意 Xcode 都能编过，这里用旧名。
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)

        // 类别/路由变化后重建输入图：旧的 input node 可能还带着上一次的硬件格式。
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: hardware, to: format) else {
            throw RecorderError.formatUnavailable
        }
        self.converter = converter
        targetFormat = format
        lastAudioAt = .distantPast

        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func disarm(deactivateSession: Bool = true) {
        stopEngine()
        converter = nil
        if deactivateSession {
            _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - 采集

    /// 开始采集。必要时自动 arm（前台调用有效；后台调用会拿到 CoreAudio 错误，由上层转成友好提示）。
    func startCapture() throws {
        try arm()
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    /// 停止采集并返回原始 PCM16；无有效音频时返回 nil。
    /// - Parameter keepWarm: true 时保留 engine 与会话（麦克风常开待命），下次可后台直接开录。
    func stopCapture(keepWarm: Bool, deactivateSession: Bool? = nil) -> Data? {
        lock.lock()
        capturing = false
        let samples = pcm
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()

        if !keepWarm { stopEngine() }
        let shouldDeactivate = deactivateSession ?? !keepWarm
        if shouldDeactivate {
            _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        guard samples.count > Int(Self.targetSampleRate / 2) else { return nil }   // < 0.25 s 视为误触
        return samples
    }

    /// 读取从 `offset` 字节开始的 PCM 增量，用于边录边识别的分段提交。
    func pcm(from offset: Int) -> (data: Data, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let total = pcm.count
        guard offset >= 0, offset < total else { return (Data(), total) }
        return (pcm.subdata(in: offset..<total), total)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: - 音频处理

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
        let duration = Double(count) / Self.targetSampleRate
        lastAudioAt = Date()

        lock.lock()
        let isCapturing = capturing
        // 与最长通道上限（540 秒）保持一致，避免"UI 说 9 分钟、实际更早就丢音频"。
        if isCapturing, pcm.count < Int(Self.targetSampleRate) * 2 * Int(Self.maxSeconds) {
            pcm.append(bytes)
        }
        lock.unlock()

        // 只有采集期间才把音频送给上层（warm 待命时静静丢弃，不占用带宽）。
        if isCapturing { onPCM?(bytes) }

        var sum: Double = 0
        for index in 0..<count { let value = Double(channel[0][index]) / 32768.0; sum += value * value }
        let rms = Float((sum / Double(max(count, 1))).squareRoot())
        level = rms
        onLevel?(rms, duration)
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
