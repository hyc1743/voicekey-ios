import AVFoundation
import Foundation

/// 实验性后台待命：播放一段静音，尽量让主 App 在后台不被立刻挂起，
/// 这样键盘点麦克风时不需要跳到前台。
///
/// 说明（务必如实告知用户）：
/// - iOS 仍可能在任意时刻挂起该进程，这里只是"提高存活概率"，不是保证。
/// - 只在用户显式开启且 App 进入后台时运行；回到前台或用户关闭时立刻停止。
/// - 不使用任何私有 API / 画中画 hook，避免审核与兼容风险。
final class StandbyKeeper {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let hardware = engine.outputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0 else { throw StandbyError.unavailable }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: min(hardware.channelCount, 2)) else {
            throw StandbyError.unavailable
        }
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            _ = frameCount
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        source = node
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        isRunning = false
        _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum StandbyError: LocalizedError {
        case unavailable

        var errorDescription: String? { "当前设备无法启动后台待命。" }
    }
}
