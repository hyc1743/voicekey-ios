import AVFoundation
import Combine
import Foundation
import UIKit

/// 语音输入完整链路：录音 → 云端 ASR（可分段/边录边识别）→ 云端整理（可流式）→ 落库 / 上屏。
///
/// 与 Typeless 对应关系：
/// - 16 kHz 单声道采集、长录音分段、边录边出字 → 对应它的流式分片 + partial 结果；
/// - 待命策略分三档（关闭 / 静音输出 / 画中画），画中画为可选实验项，不默认开启；
/// - 失败一律回退（整理失败用原文、某段失败保留其余段），不静默丢字。
@MainActor
final class DictationEngine: ObservableObject {
    enum Stage: Equatable {
        case idle, recording, transcribing, cleaning
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .cleaning: true
            default: false
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var seconds: Double = 0
    @Published private(set) var lastRaw: String = ""
    @Published private(set) var liveText: String = ""
    @Published private(set) var progress: String = ""
    @Published private(set) var diagnostics: String = ""
    @Published private(set) var standbyStatus: String = "未开启"
    @Published private(set) var triggerSource: String = "app"
    @Published var autoStopOnSilence: Bool = true

    @Published var asr: ASRSettings { didSet { persist() } }
    @Published var llm: LLMSettings { didSet { persist() } }
    @Published var personalTerms: String {
        didSet { UserDefaults.standard.set(personalTerms, forKey: "personalTerms") }
    }
    @Published var pipHideWindow: Bool {
        didSet {
            UserDefaults.standard.set(pipHideWindow, forKey: "pipHideWindow")
            pipStandby.hideWindow = pipHideWindow
        }
    }
    @Published var standbyMode: StandbyMode {
        didSet {
            UserDefaults.standard.set(standbyMode.rawValue, forKey: "standbyMode")
            updateStandby(force: true)
        }
    }

    let history = HistoryStore()

    private let recorder = AudioRecorder()
    private let silentStandby = StandbyKeeper()
    private let pipStandby = StandbyVideoPiP()
    private var ticker: Timer?
    private var partialTimer: Timer?
    private var heartbeat: Timer?
    private var requestObserver: AnyObject?
    private var cancellables = Set<AnyCancellable>()

    private var currentRequest: DictationRequest?
    private var pending: DictationRequest?
    private var sentBytes = 0
    private var partialRaw = ""
    private var partialInFlight = false
    private var silenceAccumulated: Double = 0
    private var cancelRequested = false
    private var appIsActive = true
    private var persistTask: Task<Void, Never>?

    init() {
        let loaded = SettingsStore.load()
        asr = loaded.asr
        llm = loaded.llm
        personalTerms = UserDefaults.standard.string(forKey: "personalTerms") ?? ""
        standbyMode = StandbyMode(rawValue: UserDefaults.standard.string(forKey: "standbyMode") ?? "") ?? .off
        let savedHide = UserDefaults.standard.object(forKey: "pipHideWindow") as? Bool
        pipHideWindow = savedHide ?? true
        pipStandby.hideWindow = savedHide ?? true
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.handleLevel(value) }
        }
        pipStandby.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.standbyStatus = status.message
                KeyboardChannel.publishStandby(active: status.active, mode: status.hidden ? "画中画" : "画中画(可见)")
            }
        }
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeKeyboard()
        startHeartbeat()
        SettingsStore.save(asr: asr, llm: llm)
        publishPhase(.standby, message: "主 App 已就绪")
        KeyboardChannel.publishStandby(active: false, mode: "未开启")
    }

    // MARK: - App 内使用

    func toggle() {
        switch stage {
        case .recording: stopAndProcess()
        case .idle, .done, .failed: begin(source: "app")
        default: break
        }
    }

    func begin(source: String) {
        guard !stage.isBusy else { return }
        cancelRequested = false
        triggerSource = source
        Task { await startRecording(source: source) }
    }

    func stopAndProcess() {
        guard case .recording = stage else { return }
        Task { await process() }
    }

    func cancel() {
        cancelRequested = true
        recorder.cancel()
        stopTimers()
        stage = .idle
        seconds = 0
        level = 0
        liveText = ""
        partialRaw = ""
        progress = ""
        KeyboardChannel.clearPartial()
        if let request = currentRequest {
            reply(request, kind: .rejected, text: nil, message: "用户取消")
        }
        currentRequest = nil
        publishPhase(.standby, message: "已取消")
    }

    // MARK: - 键盘触发

    private func observeKeyboard() {
        requestObserver = SharedStore.observe(SharedStore.commandNotification) { [weak self] in
            Task { @MainActor in self?.handleKeyboardCommand() }
        }
    }

    private func handleKeyboardCommand() {
        guard let request = SharedStore.read(DictationRequest.self, name: "request.json") else { return }
        guard request.isValid else { return }
        guard pending?.id != request.id, currentRequest?.id != request.id else { return }

        switch request.source {
        case "start":
            begin(source: "keyboard")
            currentRequest = request
            reply(request, kind: .accepted, text: nil, message: "已开始录音")
        case "stop":
            if case .recording = stage {
                stopAndProcess()
            } else {
                reply(request, kind: .rejected, text: nil, message: "当前没有在录音")
            }
        case "cancel":
            cancel()
        case "ping":
            SharedStore.markHeartbeat()
            reply(request, kind: .accepted, text: nil, message: "alive")
        default:
            reply(request, kind: .rejected, text: nil, message: "未知指令 \(request.source)")
        }
    }

    private func reply(_ request: DictationRequest, kind: DictationReply.Kind, text: String?, message: String) {
        let payload = DictationReply(requestID: request.id, sessionID: request.sessionID,
                                     kind: kind, text: text, message: message,
                                     createdAt: Date().timeIntervalSince1970)
        SharedStore.write(payload, name: "reply-\(request.id).json")
        SharedStore.post(SharedStore.eventNotification)
    }

    // MARK: - 录音

    private func startRecording(source: String) async {
        guard await AudioRecorder.requestPermission() else {
            fail(message: "没有麦克风权限，请到系统设置里允许 VoiceKey 使用麦克风。")
            return
        }
        do {
            try recorder.start()
        } catch {
            fail(message: error.localizedDescription)
            return
        }
        stage = .recording
        seconds = 0
        level = 0
        sentBytes = 0
        partialRaw = ""
        liveText = ""
        progress = ""
        silenceAccumulated = 0
        KeyboardChannel.clearPartial()
        publishPhase(.recording, message: "正在录音")
        startTicker()
        startPartialTimer()
    }

    private func fail(message: String) {
        stage = .failed(message)
        publishPhase(.error, message: message)
        if let request = currentRequest {
            reply(request, kind: .failed, text: nil, message: message)
            currentRequest = nil
        }
        stopTimers()
    }

    private func handleLevel(_ value: Float) {
        level = value
        guard case .recording = stage, autoStopOnSilence else { return }
        if value > 0.03 {
            silenceAccumulated = 0
        } else if value < 0.01, seconds > 1.5 {
            silenceAccumulated += 0.05
        }
        if silenceAccumulated > 2.2, seconds > 1.5 {
            stopAndProcess()
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds += 0.05
                if self.seconds >= 300 { self.stopAndProcess() }     // 硬上限 5 分钟
            }
        }
    }

    /// 边录边识别：每 `partialSeconds` 秒提交一段**增量**音频（保留 1.5 秒尾部余量，避免切断词）。
    private func startPartialTimer() {
        partialTimer?.invalidate()
        let interval = asr.partialSeconds
        guard interval > 0 else { return }
        partialTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.submitPartial() }
        }
    }

    private func stopTimers() {
        ticker?.invalidate(); ticker = nil
        partialTimer?.invalidate(); partialTimer = nil
    }

    private func submitPartial() {
        guard case .recording = stage, !partialInFlight else { return }
        let margin = Int(AudioRecorder.targetSampleRate * 1.5) * 2       // 1.5 秒余量（字节）
        let snapshot = recorder.pcm(from: sentBytes)
        guard snapshot.data.count > margin + Int(AudioRecorder.targetSampleRate) else { return }
        let chunk = snapshot.data.prefix(snapshot.data.count - margin)
        sentBytes += chunk.count
        partialInFlight = true

        let settings = asr
        let terms = termsList()
        Task {
            defer { self.partialInFlight = false }
            do {
                let piece = try await self.recognize(pcm: Data(chunk), settings: settings, terms: terms)
                guard !piece.isEmpty else { return }
                self.partialRaw = Self.joinTranscripts([self.partialRaw, piece])
                self.liveText = self.partialRaw
                KeyboardChannel.publishPartial(self.partialRaw)
            } catch {
                self.diagnostics += "\n\n[分段识别失败，已忽略] \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 收尾处理

    private func process() async {
        guard let pcm = recorder.stop() else {
            recorder.cancel()
            stopTimers()
            fail(message: "没有录到有效音频，请多说几个字。")
            return
        }
        let duration = Double(pcm.count / 2) / AudioRecorder.targetSampleRate
        stopTimers()
        level = 0
        stage = .transcribing
        publishPhase(.processing, message: "识别中")

        let settings = asr
        let llmSettings = llm
        let terms = termsList()
        let source = triggerSource
        let tail = pcm.count > sentBytes ? pcm.subdata(in: sentBytes..<pcm.count) : Data()
        let segments = AudioTranscoder.chunks(pcm16: tail, seconds: max(5, settings.chunkSeconds))

        var collected: [String] = partialRaw.isEmpty ? [] : [partialRaw]
        for (index, segment) in segments.enumerated() {
            if cancelRequested { return }
            progress = segments.count > 1 ? "识别中 \(index + 1)/\(segments.count)" : "识别中"
            do {
                let piece = try await recognize(pcm: segment, settings: settings, terms: terms)
                if !piece.isEmpty { collected.append(piece) }
            } catch {
                // 单段失败不丢整体：记录后继续。
                diagnostics += "\n\n[第 \(index + 1)/\(segments.count) 段识别失败] \(error.localizedDescription)"
                if collected.isEmpty, index == segments.count - 1 {
                    fail(message: error.localizedDescription)
                    return
                }
            }
        }
        progress = ""
        let raw = Self.joinTranscripts(collected)
        lastRaw = raw
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(message: "识别结果为空，请重说一次。")
            return
        }

        stage = .cleaning
        liveText = raw
        publishPhase(.processing, message: "整理中")
        var final = raw
        if llmSettings.enabled {
            do {
                final = try await LLMClient().cleanup(raw: raw, settings: llmSettings, terms: terms) { [weak self] partial in
                    Task { @MainActor in self?.liveText = partial }
                }
                diagnostics += "\n\n--- 整理 ---\n" + LLMClient.lastExchange
            } catch {
                diagnostics += "\n\n--- 整理失败（已使用原始识别结果）---\n\(error.localizedDescription)"
            }
        }
        finish(text: final, raw: raw, seconds: duration, source: source)
    }

    private func recognize(pcm: Data, settings: ASRSettings, terms: [String]) async throws -> String {
        let audio: Data
        let format: UploadFormat
        switch settings.uploadFormat {
        case .wav:
            audio = AudioRecorder.wav(fromPCM16: pcm); format = .wav
        case .m4a:
            do { audio = try AudioTranscoder.encodeAAC(pcm16: pcm); format = .m4a }
            catch {
                diagnostics += "\n\n[AAC 压缩失败，回退 WAV] \(error.localizedDescription)"
                audio = AudioRecorder.wav(fromPCM16: pcm); format = .wav
            }
        }
        let started = Date()
        let text = try await ASRClient().transcribe(audio: audio, format: format, settings: settings, terms: terms)
        let elapsed = Date().timeIntervalSince(started)
        diagnostics = ASRClient.lastExchange
            + String(format: "\n耗时 %.1fs，音频 %.0f KB，第 %.1f 秒音频", elapsed, Double(audio.count) / 1024,
                     Double(pcm.count / 2) / AudioRecorder.targetSampleRate)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(text: String, raw: String, seconds: Double, source: String) {
        stage = .done(text)
        liveText = text
        history.add(HistoryRecord(id: UUID(), date: Date(), raw: raw, text: text,
                                  seconds: seconds, source: source,
                                  asrModel: asr.model,
                                  llmModel: llm.enabled ? llm.model : "未整理"))
        UIPasteboard.general.string = text
        SharedStore.publishResult(text: text, sessionID: currentRequest?.sessionID ?? UUID().uuidString)
        if let request = currentRequest {
            reply(request, kind: .completed, text: text, message: "已完成")
            currentRequest = nil
        }
        KeyboardChannel.clearPartial()
        triggerSource = "app"
        currentRequest = nil
    }

    private func termsList() -> [String] {
        personalTerms
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 中英混排拼接：两侧都是 ASCII 字母数字时补空格，否则直接相连（避免中文之间出现空格）。
    static func joinTranscripts(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty { result = trimmed; continue }
            let left = result.unicodeScalars.last.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII } ?? false
            let right = trimmed.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII } ?? false
            result += (left && right) ? " " + trimmed : trimmed
        }
        return result
    }

    // MARK: - 待命

    func handleScenePhase(active: Bool) {
        appIsActive = active
        updateStandby(force: false)
    }

    private func updateStandby(force: Bool) {
        guard force || !appIsActive else {
            // 回到前台：立即停止一切待命，避免占着麦克风/音频会话。
            pipStandby.stop()
            silentStandby.stop()
            KeyboardChannel.publishStandby(active: false, mode: "未开启")
            standbyStatus = "未开启"
            publishPhase(.standby, message: "主 App 已就绪")
            return
        }

        switch standbyMode {
        case .off:
            pipStandby.stop()
            silentStandby.stop()
            standbyStatus = "未开启"
            KeyboardChannel.publishStandby(active: false, mode: "未开启")
        case .silentAudio:
            pipStandby.stop()
            do {
                try silentStandby.start()
                standbyStatus = "静音输出待命中（系统仍可能挂起）"
                KeyboardChannel.publishStandby(active: true, mode: "静音输出")
            } catch {
                standbyStatus = "静音待命启动失败：\(error.localizedDescription)"
                KeyboardChannel.publishStandby(active: false, mode: "失败")
            }
        case .pictureInPicture:
            silentStandby.stop()
            do {
                try pipStandby.start()
                standbyStatus = pipStandby.status.message
                KeyboardChannel.publishStandby(active: pipStandby.status.active,
                                               mode: pipStandby.status.hidden ? "画中画" : "画中画(可见)")
            } catch {
                standbyStatus = "画中画待命启动失败：\(error.localizedDescription)"
                KeyboardChannel.publishStandby(active: false, mode: "失败")
            }
        }
    }

    // MARK: - 心跳与状态

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SharedStore.markHeartbeat() }
        }
    }

    private func publishPhase(_ phase: SharedStore.Phase, message: String) {
        SharedStore.publish(phase: phase, message: message)
    }

    /// 设置改动很频繁（每个按键都会触发），这里做 0.6 秒防抖，避免反复写 Keychain。
    private func persist() {
        persistTask?.cancel()
        persistTask = Task { [asr = self.asr, llm = self.llm] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            SettingsStore.save(asr: asr, llm: llm)
        }
    }
}
