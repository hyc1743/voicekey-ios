import AVFoundation
import Combine
import Foundation
import UIKit

/// 语音输入完整链路：录音 → 云端 ASR（可分段/边录边识别）→ 云端整理（可流式）→ 落库 / 上屏。
///
/// 与 Typeless / Voxt-ios 对应关系：
/// - 16 kHz 单声道采集、长录音分段、边录边出字 → 对应它们的流式分片与 partial 结果；
/// - 待命策略三档（关闭 / 静音输出 / 画中画），画中画为可选实验项，不默认开启；
/// - 录音与待命共用音频会话：待命期间**不 deactivate**，录完恢复待命播放；
/// - 失败一律回退（整理失败用原文、单段失败保留其余段），不静默丢字。
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
    private var interruptionObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    private var currentRequest: DictationRequest?
    private var sentBytes = 0
    private var partialRaw = ""
    private var partialInFlight = false
    private var quietSince: Date?
    private var cancelRequested = false
    private var appIsActive = true
    private var captureToken = UUID()
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
        if !SettingsStore.migrationNotes.isEmpty {
            diagnostics = "设置已按官方变更自动修正：\n- " + SettingsStore.migrationNotes.joined(separator: "\n- ")
        }
        observeKeyboard()
        observeAudioSession()
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
        recorder.cancel(deactivateSession: !standbyOwnsSession)
        stopTimers()
        stage = .idle
        seconds = 0
        level = 0
        liveText = ""
        partialRaw = ""
        progress = ""
        quietSince = nil
        KeyboardChannel.clearPartial()
        if let request = currentRequest {
            reply(request, kind: .rejected, text: nil, message: "用户取消")
        }
        currentRequest = nil
        publishPhase(.standby, message: "已取消")
        resumeStandbyPlaybackIfNeeded()
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
        guard currentRequest?.id != request.id else { return }

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

    // MARK: - 音频会话事件

    /// 来电 / 其它 App 抢占麦克风时，录音会变成"假录"（电平恒为 0）。这里如实告知并收尾。
    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    if case .recording = self.stage {
                        self.recorder.cancel(deactivateSession: !self.standbyOwnsSession)
                        self.stopTimers()
                        self.stage = .failed("系统中断了录音（来电或其它 App 占用麦克风），请重试。")
                        self.publishPhase(.error, message: "录音被系统中断")
                        if let request = self.currentRequest {
                            self.reply(request, kind: .failed, text: nil, message: "录音被系统中断")
                            self.currentRequest = nil
                        }
                    }
                case .ended:
                    self.diagnostics += "\n\n[系统中断已结束] 需要重新点一次录音。"
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - 录音

    private func startRecording(source: String) async {
        guard await AudioRecorder.requestPermission() else {
            fail(message: "没有麦克风权限，请到系统设置里允许 VoiceKey 使用麦克风。")
            return
        }
        // 正在待命时，采集与待命共用音频会话；采集前先收紧播放路径。
        if standbyMode == .silentAudio { silentStandby.stop() }
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
        quietSince = nil
        captureToken = UUID()
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

    /// 静音判定按**真实时间**累加。旧实现按回调次数每次加 0.05 秒，
    /// 而电平回调频率远高于 20 Hz，会把 2.2 秒静音误判成零点几秒就自动结束。
    private func handleLevel(_ value: Float) {
        level = value
        guard case .recording = stage, autoStopOnSilence else { return }
        guard seconds > 1.2 else { return }
        if value > 0.03 {
            quietSince = nil
            return
        }
        guard value < 0.01 else { return }
        let now = Date()
        if let since = quietSince {
            if now.timeIntervalSince(since) > 2.2 { stopAndProcess() }
        } else {
            quietSince = now
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds += 0.05
                if self.seconds >= 300 { self.stopAndProcess() }     // 硬上限 5 分钟（与录音缓冲一致）
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
        let chunk = Data(snapshot.data.prefix(snapshot.data.count - margin))
        sentBytes += chunk.count
        partialInFlight = true
        let token = captureToken
        let settings = asr
        let terms = termsList()

        Task {
            defer { self.partialInFlight = false }
            let outcome = try? await Self.recognize(pcm: chunk, settings: settings, terms: terms)
            // 会话已结束的迟到结果直接丢弃（对应收尾时等待在途分段的逻辑，二者只会命中一个）。
            guard self.captureToken == token else { return }
            guard let result = outcome, !result.text.isEmpty else {
                if let message = outcome?.error ?? nil {
                    self.diagnostics += "\n\n[分段识别失败] \(message)"
                }
                return
            }
            self.partialRaw = Self.joinTranscripts([self.partialRaw, result.text])
            self.liveText = self.partialRaw
            KeyboardChannel.publishPartial(self.partialRaw)
        }
    }

    // MARK: - 收尾处理

    private func process() async {
        // 等在途的分段识别落地：否则它的字节已经算进 sentBytes，文字却会被丢掉。
        var waited = 0.0
        while partialInFlight, waited < 6 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }

        let standbyActive = standbyOwnsSession
        guard let pcm = recorder.stop(deactivateSession: !standbyActive) else {
            recorder.cancel(deactivateSession: !standbyActive)
            stopTimers()
            resumeStandbyPlaybackIfNeeded()
            fail(message: "没有录到有效音频，请多说几个字。")
            return
        }
        let duration = Double(pcm.count / 2) / AudioRecorder.targetSampleRate
        stopTimers()
        level = 0
        quietSince = nil
        stage = .transcribing
        publishPhase(.processing, message: "识别中")

        let settings = asr
        let llmSettings = llm
        let terms = termsList()
        let source = triggerSource
        let tail = pcm.count > sentBytes ? Data(pcm.subdata(in: sentBytes..<pcm.count)) : Data()
        let segments = AudioTranscoder.chunks(pcm16: tail, seconds: max(5, settings.chunkSeconds))

        var collected: [String] = partialRaw.isEmpty ? [] : [partialRaw]
        var exchanges: [String] = []
        let outcome = await Self.recognizeAll(segments: segments, settings: settings, terms: terms,
                                              onProgress: { [weak self] done, total in
            Task { @MainActor in self?.progress = total > 1 ? "识别中 \(done)/\(total)" : "识别中" }
        })
        collected.append(contentsOf: outcome.texts)
        exchanges.append(contentsOf: outcome.exchanges)
        progress = ""
        if !outcome.errors.isEmpty {
            diagnostics += "\n\n[部分分段识别失败]\n" + outcome.errors.joined(separator: "\n")
        }

        let raw = Self.joinTranscripts(collected)
        lastRaw = raw
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resumeStandbyPlaybackIfNeeded()
            fail(message: "识别结果为空，请重说一次。")
            return
        }

        stage = .cleaning
        liveText = raw
        publishPhase(.processing, message: "整理中")
        var final = raw
        if llmSettings.enabled {
            let client = LLMClient()
            do {
                final = try await client.cleanup(raw: raw, settings: llmSettings, terms: terms) { [weak self] partial in
                    Task { @MainActor in self?.liveText = partial }
                }
                exchanges.append("--- 整理 ---\n" + client.exchange)
            } catch {
                exchanges.append("--- 整理失败（已使用原始识别结果）---\n\(error.localizedDescription)")
            }
        }
        diagnostics = exchanges.joined(separator: "\n\n")
        finish(text: final, raw: raw, seconds: duration, source: source)
        resumeStandbyPlaybackIfNeeded()
    }

    /// 单段识别：编码 → 调 ASR → 返回文本与诊断（非隔离，便于并发跑多段）。
    private nonisolated static func recognize(pcm: Data, settings: ASRSettings, terms: [String])
        async throws -> (text: String, exchange: String, error: String?) {
        let audio: Data
        let format: UploadFormat
        switch settings.uploadFormat {
        case .wav:
            audio = AudioRecorder.wav(fromPCM16: pcm); format = .wav
        case .m4a:
            if let compressed = try? AudioTranscoder.encodeAAC(pcm16: pcm) {
                audio = compressed; format = .m4a
            } else {
                audio = AudioRecorder.wav(fromPCM16: pcm); format = .wav
            }
        }
        let client = ASRClient()
        let started = Date()
        do {
            let text = try await client.transcribe(audio: audio, format: format, settings: settings, terms: terms)
            let elapsed = Date().timeIntervalSince(started)
            let header = String(format: "第 %.1f 秒音频 / %.0f KB / 耗时 %.1fs",
                                Double(pcm.count / 2) / AudioRecorder.targetSampleRate,
                                Double(audio.count) / 1024, elapsed)
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), header + "\n" + client.exchange, nil)
        } catch {
            return ("", client.exchange, error.localizedDescription)
        }
    }

    /// 分段并发提交（最多 3 路上行），按原顺序拼回；单段失败不影响其它段。
    private nonisolated static func recognizeAll(
        segments: [Data],
        settings: ASRSettings,
        terms: [String],
        onProgress: @escaping (Int, Int) -> Void
    ) async -> (texts: [String], exchanges: [String], errors: [String]) {
        guard !segments.isEmpty else { return ([], [], []) }
        let limit = min(3, segments.count)
        var texts = [String](repeating: "", count: segments.count)
        var exchanges = [String](repeating: "", count: segments.count)
        var errors: [String] = []
        var finished = 0

        await withTaskGroup(of: (Int, String, String, String?).self) { group in
            var next = 0
            while next < min(limit, segments.count) {
                let index = next; let segment = segments[index]
                group.addTask { await task(index: index, segment: segment, settings: settings, terms: terms) }
                next += 1
            }
            while let (index, text, exchange, error) = await group.next() {
                texts[index] = text
                exchanges[index] = exchange
                if let error { errors.append("第 \(index + 1)/\(segments.count) 段：\(error)") }
                finished += 1
                onProgress(finished, segments.count)
                if next < segments.count {
                    let index = next; let segment = segments[index]
                    group.addTask { await task(index: index, segment: segment, settings: settings, terms: terms) }
                    next += 1
                }
            }
        }
        return (texts.filter { !$0.isEmpty }, exchanges.filter { !$0.isEmpty }, errors)
    }

    private nonisolated static func task(index: Int, segment: Data, settings: ASRSettings, terms: [String])
        async -> (Int, String, String, String?) {
        let outcome: (text: String, exchange: String, error: String?)
        do {
            outcome = try await recognize(pcm: segment, settings: settings, terms: terms)
        } catch {
            outcome = ("", "", error.localizedDescription)
        }
        return (index, outcome.text, outcome.exchange, outcome.error)
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
    nonisolated static func joinTranscripts(_ parts: [String]) -> String {
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

    /// 待命是否正持有音频会话（决定录音结束时能不能 deactivate）。
    private var standbyOwnsSession: Bool {
        standbyMode == .pictureInPicture && pipStandby.isActive
    }

    private func resumeStandbyPlaybackIfNeeded() {
        guard standbyOwnsSession else { return }
        pipStandby.resumeIdlePlayback()
    }

    func handleScenePhase(active: Bool) {
        appIsActive = active
        if !active {
            // 后台前把设置落盘，避免防抖窗口里被杀进程丢配置。
            persistTask?.cancel()
            SettingsStore.save(asr: asr, llm: llm)
        }
        updateStandby(force: false)
    }

    private func updateStandby(force: Bool) {
        guard force || !appIsActive else {
            // 回到前台：停止一切待命，避免占着音频会话。
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
