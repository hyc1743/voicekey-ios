import Foundation

/// 语音活动检测（用于"静音 N 秒自动结束"）。
///
/// 算法与已验证实现（Voxt-ios 的 `VoiceActivityDetector`）逐行一致：
/// - 电平转 dBFS，阈值取**自适应噪声底 + 10 dB**，并夹在 [-32, -18] dB 之间——安静环境更灵敏，嘈杂环境不误判；
/// - 4 dB 迟滞，避免在阈值附近抖动；
/// - 必须先有 0.25 秒语音，静音计时才开始（防止一开口就被判定结束）；
/// - 噪声底按"块时长加权"缓慢更新，停顿与路由切换不会被当成静音丢进来。
///
/// `silenceSeconds <= 0` 表示关闭自动结束（与已验证实现的默认一致）。
struct VoiceActivityDetector {
    var silenceSeconds: Double

    private(set) var noiseDB = -60.0
    private var speechSeconds = 0.0
    private var quietSeconds = 0.0
    private var speaking = false
    private var fired = false

    init(silenceSeconds: Double = 5) {
        self.silenceSeconds = silenceSeconds
    }

    mutating func reset() {
        self = Self(silenceSeconds: silenceSeconds)
    }

    /// 喂入一块音频的 RMS 与其时长（秒）；返回 true 表示"应当结束录音"。
    mutating func observe(rms: Double, duration: Double) -> Bool {
        guard rms.isFinite, duration.isFinite, duration > 0, silenceSeconds > 0, !fired else { return false }
        let db = 20 * log10(max(0.000001, rms))
        let threshold = max(-32, min(-18, noiseDB + 10))
        speaking = db > threshold - (speaking ? 4 : 0)
        if speaking {
            speechSeconds += duration
            quietSeconds = 0
        } else {
            let weight = min(1, duration / 2)
            noiseDB += weight * (db - noiseDB)
            if speechSeconds >= 0.25 { quietSeconds += duration }
        }
        if quietSeconds >= silenceSeconds {
            fired = true
            return true
        }
        return false
    }
}
