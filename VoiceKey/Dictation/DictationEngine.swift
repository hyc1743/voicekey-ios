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
    /// 诊断用：warm 是否在跑、是否真的收到音频。
    var standbyProbe: String {
        recorder.isWarm
            ? (recorder.hasRecentAudio ? "已启用，正在收音频" : "已启用，但还没收到音频")
            : "未启用"
    }
    @Published private(set) var triggerSource: String = "app"

    @Published var asr: ASRSettings { didSet { persist() } }
    @Published var llm: LLMSettings { didSet { persist() } }
    @Published var personalTerms: String {
        didSet { UserDefaults.standard.set(personalTerms, forKey: "personalTerms") }
    }
    @Published var pipHideWindow: Bool {
        didSet {
            UserDefaults.standard.set(pipHideWindow, forKey: "pipHideWindow")
            pipStandby.hideWindow = pipHideWindow
            samplePiP.hideWindow = pipHideWindow
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
    private let samplePiP = StandbySampleBufferPiP()
    private let pipStandby = StandbyVideoPiP()
    /// 当前生效的画中画路线：sample-buffer / video / 空
    private var pipRoute = ""
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
    private var vad = VoiceActivityDetector(silenceSeconds: 0)
    private var didWarnAboutLimit = false
    private var cancelRequested = false
    private var appIsActive = true
    private var captureToken = UUID()
    private var persistTask: Task<Void, Never>?
    private var realtime: RealtimeASRClient?
    private var realtimeActive = false
    private var realtimeNote = ""

    init() {
        let loaded = SettingsStore.load()
        asr = loaded.asr
        llm = loaded.llm
        personalTerms = UserDefaults.standard.string(forKey: "personalTerms") ?? ""
        // 待命默认「麦克风常开」：iOS 只允许它后台开录；静音/画中画只能保进程。
        let storedStandby = UserDefaults.standard.string(forKey: "standbyMode") ?? ""
        var standbyNotes: [String] = []
        if !UserDefaults.standard.bool(forKey: "standbyMigrationWarm") {
            UserDefaults.standard.set(true, forKey: "standbyMigrationWarm")
            if storedStandby == "silentAudio" || storedStandby == "pictureInPicture" || storedStandby.isEmpty {
                standbyNotes.append("待命方式已改为「麦克风常开」：iOS 只允许该模式下后台开录，静音/画中画只能保进程")
                UserDefaults.standard.set(StandbyMode.microphoneWarm.rawValue, forKey: "standbyMode")
                standbyMode = .microphoneWarm
            } else {
                standbyMode = StandbyMode(rawValue: storedStandby) ?? .microphoneWarm
            }
        } else {
            standbyMode = StandbyMode(rawValue: storedStandby) ?? .microphoneWarm
        }
        let savedHide = UserDefaults.standard.object(forKey: "pipHideWindow") as? Bool
        pipHideWindow = savedHide ?? true
        pipStandby.hideWindow = savedHide ?? true
        samplePiP.hideWindow = savedHide ?? true
        recorder.onLevel = { [weak self] rms, duration in
            Task { @MainActor in self?.handleLevel(rms, duration: duration) }
        }
        samplePiP.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self, self.pipRoute == "sample-buffer" else { return }
                self.standbyStatus = status.message
                KeyboardChannel.publishStandby(active: status.active,
                                               mode: status.hidden ? "画中画" : "画中画(可见)")
            }
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
        let notes = SettingsStore.migrationNotes + standbyNotes
        if !notes.isEmpty {
            diagnostics = "设置已自动修正：\n- " + notes.joined(separator: "\n- ")
        }
        observeKeyboard()
        observeAudioSession()
        startHeartbeat()
        SettingsStore.save(asr: asr, llm: llm)
        publishPhase(.standby, message: "主 App 已就绪")
        // 启动即按所选模式准备待命：micWarm 需要在前台把会话与麦克风打开，
        // 否则用户切到别的 App 之后就没有机会再激活录音会话了。
        if standbyMode == .microphoneWarm, AVAudioApplication.shared.recordPermission == .granted {
            updateStandby(force: true)
        } else {
            KeyboardChannel.publishStandby(active: false, mode: standbyMode == .off ? "未开启" : "待启动")
        }
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
        realtime?.abort()
        realtime = nil
        realtimeActive = false
        recorder.onPCM = nil
        let keepWarm = standbyMode == .microphoneWarm
        _ = recorder.stopCapture(keepWarm: keepWarm, deactivateSession: !standbyOwnsSession)
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
                        _ = self.recorder.stopCapture(keepWarm: self.standbyMode == .microphoneWarm,
                                                      deactivateSession: !self.standbyOwnsSession)
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
        // 静音/画中画待命与采集抢会话：采集前先让它们让路。
        // micWarm 相反——会话本来就要一直握着，采集只是翻个标志位。
        if standbyMode == .silentAudio { silentStandby.stop() }
        do {
            try recorder.startCapture()
        } catch {
            let message = Self.audioFailureMessage(error, appActive: appIsActive, standby: standbyMode)
            diagnostics += "\n\n[录音启动失败] \(error.localizedDescription)"
            fail(message: message)
            return
        }
        stage = .recording
        seconds = 0
        level = 0
        sentBytes = 0
        partialRaw = ""
        liveText = ""
        progress = ""
        vad = VoiceActivityDetector(silenceSeconds: asr.silenceSeconds)
        didWarnAboutLimit = false
        realtimeNote = ""
        captureToken = UUID()
        KeyboardChannel.clearPartial()
        publishPhase(.recording, message: "正在录音")
        startTicker()
        if asr.transport == .realtime {
            await startRealtimeChannel()
        } else {
            startPartialTimer()
        }
    }

    /// 实时通道：一条 WebSocket 推 PCM，服务端边说边出字。
    /// 连接失败不阻塞录音——音频仍在本地累积，收尾时走批量兜底。
    private func startRealtimeChannel() async {
        guard asr.realtimeConfigured else {
            realtimeNote = "实时通道未配置端点或模型，本次走批量通道"
            diagnostics = realtimeNote
            startPartialTimer()
            return
        }
        let settings = asr
        let terms = termsList()
        let client = RealtimeASRClient(
            endpoint: settings.realtimeEndpoint,
            model: settings.realtimeModel,
            apiKey: settings.apiKey,
            language: settings.language,
            corpusText: terms.prefix(50).joined(separator: "、")
        ) { [weak self] event in
            Task { @MainActor in self?.handleRealtime(event) }
        }
        do {
            try await client.connect()
            realtime = client
            realtimeActive = true
            realtimeNote = "实时通道已就绪（\(settings.realtimeModel)）"
            diagnostics = realtimeNote
            recorder.onPCM = { [weak self] pcm in
                Task { @MainActor in self?.realtime?.append(pcm: pcm) }
            }
        } catch {
            realtimeActive = false
            realtime = nil
            realtimeNote = "实时通道连接失败，已回落到批量通道：\(error.localizedDescription)"
            diagnostics = realtimeNote
            startPartialTimer()
        }
    }

    private func handleRealtime(_ event: RealtimeASRClient.Event) {
        switch event {
        case .ready:
            publishPhase(.recording, message: "正在录音（实时）")
        case .interim(let text), .committed(let text):
            guard case .recording = stage else { return }
            liveText = text
            KeyboardChannel.publishPartial(text)
        case .failed(let message):
            diagnostics += "\n\n[实时通道] \(message)"
            if message.contains("拥塞") { return }
            realtimeNote = message
        case .finished:
            break
        }
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

    /// 静音自动结束：交给自适应 dB VAD（见 VoiceActivityDetector）。
    /// 旧实现用"回调次数 × 0.05 秒"累加，且阈值是无出处的原始 RMS，早已废弃。
    private func handleLevel(_ rms: Float, duration: Double) {
        level = rms
        guard case .recording = stage, asr.silenceSeconds > 0 else { return }
        guard seconds > 1.0 else { return }           // 头 1 秒不判定，避免一开口就被结束
        if vad.observe(rms: Double(rms), duration: duration) {
            diagnostics += String(format: "\n\n[静音自动结束] 静音超过 %.0f 秒", asr.silenceSeconds)
            stopAndProcess()
        }
    }

    /// 录音上限：批量通道 300 秒（收尾要按段跑，太久体验差），实时通道 540 秒（Typeless 同值）。
    private var recordingLimitSeconds: Double {
        asr.transport == .realtime ? 540 : 300
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds += 0.05
                let limit = self.recordingLimitSeconds
                if !self.didWarnAboutLimit, self.seconds >= limit - 60 {
                    self.didWarnAboutLimit = true
                    let hint = self.asr.transport == .batch
                        ? "还剩不到 1 分钟（批量通道上限 \(Int(limit / 60)) 分钟，长录音可切实时通道）"
                        : "还剩不到 1 分钟（上限 \(Int(limit / 60)) 分钟）"
                    SharedStore.publish(phase: .recording, message: hint)
                }
                if self.seconds >= limit {
                    self.diagnostics += "\n\n[到达录音上限] \(Int(limit)) 秒，已自动停止"
                    self.stopAndProcess()
                }
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
            self.partialRaw = TranscriptJoiner.join([self.partialRaw, result.text])
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
        let keepWarm = standbyMode == .microphoneWarm
        guard let pcm = recorder.stopCapture(keepWarm: keepWarm, deactivateSession: !standbyActive) else {
            stopTimers()
            resumeStandbyPlaybackIfNeeded()
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
        let tail = pcm.count > sentBytes ? Data(pcm.subdata(in: sentBytes..<pcm.count)) : Data()
        var exchanges: [String] = []
        var collected: [String] = []

        // 实时通道：先收尾拿整段文本；失败或为空则回落到批量分段（音频一直在本地累积，不会丢）。
        if realtimeActive, let client = realtime {
            progress = "实时收尾…"
            recorder.onPCM = nil
            do {
                let text = try await client.finish()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collected = [text]
                    exchanges.append("通道=实时 \(settings.realtimeModel)\n" + realtimeNote)
                } else {
                    exchanges.append("通道=实时，但结果为空 → 回落批量")
                }
            } catch {
                exchanges.append("通道=实时失败（回落批量）：\(error.localizedDescription)")
            }
            realtime = nil
            realtimeActive = false
            diagnostics = realtimeNote
        }

        if collected.isEmpty {
            let segments = AudioTranscoder.chunks(pcm16: tail, seconds: max(5, settings.chunkSeconds))
            if !partialRaw.isEmpty { collected.append(partialRaw) }
            let outcome = await Self.recognizeAll(segments: segments, settings: settings, terms: terms,
                                                  onProgress: { [weak self] done, total in
                Task { @MainActor in self?.progress = total > 1 ? "识别中 \(done)/\(total)" : "识别中" }
            })
            collected.append(contentsOf: outcome.texts)
            exchanges.append(contentsOf: outcome.exchanges)
            if !outcome.errors.isEmpty {
                diagnostics += "\n\n[部分分段识别失败]\n" + outcome.errors.joined(separator: "\n")
            }
        }
        progress = ""

        let raw = TranscriptJoiner.join(collected)
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
                // Typeless 的 REFINING_TIMEOUT = 20 秒：超时就用原始识别结果上屏，不让用户干等。
                final = try await Self.withTimeout(seconds: 20) {
                    try await client.cleanup(raw: raw, settings: llmSettings, terms: terms) { [weak self] partial in
                        Task { @MainActor in self?.liveText = partial }
                    }
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

    /// 把 CoreAudio/AVFAudio 的裸错误码翻译成可执行提示。
    /// 2003329396 = FourCC `'what'`：最常见于"后台尝试激活录音会话"。
    nonisolated static func audioFailureMessage(_ error: Error, appActive: Bool, standby: StandbyMode) -> String {
        let nsError = error as NSError
        let isCoreAudio = nsError.domain.contains("coreaudio") || nsError.domain.contains("AVFAudio")
        let raw = "\(nsError.domain) \(nsError.code)"
        if isCoreAudio || nsError.code == 2_003_329_396 {
            if appActive {
                return "无法开启麦克风（\(raw)）：可能被其它 App 占用，或系统刚中断过音频会话。请重试一次。"
            }
            if standby == .microphoneWarm {
                return "麦克风常开已失效（\(raw)）。请打开 VoiceKey 重新开启待命后再回来。"
            }
            return "后台无法开启麦克风（\(raw)）。iOS 只允许在「麦克风常开」待命下后台开录——请到设置里改成该模式，或先打开 App 一次。"
        }
        return error.localizedDescription
    }

    /// 给一个 async 操作加硬超时；超时抛错，由调用方决定回退策略。
    nonisolated static func withTimeout<T: Sendable>(seconds: Double,
                                                    _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ServiceError(message: "操作超时（\(Int(seconds)) 秒）")
            }
            guard let result = try await group.next() else {
                throw ServiceError(message: "操作未返回结果")
            }
            group.cancelAll()
            return result
        }
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

    // MARK: - 待命

    /// 待命是否正持有音频会话（决定录音结束时能不能 deactivate）。
    /// micWarm 也持有：它必须保持 `.playAndRecord` 会话激活，后台才能直接开录。
    private var standbyOwnsSession: Bool {
        switch standbyMode {
        case .microphoneWarm: return recorder.isWarm
        case .pictureInPicture: return samplePiP.isActive || pipStandby.isActive
        case .silentAudio: return silentStandby.isRunning
        case .off: return false
        }
    }

    private func resumeStandbyPlaybackIfNeeded() {
        guard standbyMode == .pictureInPicture else { return }
        if samplePiP.isActive { samplePiP.resumeIdlePlayback() }
        if pipStandby.isActive { pipStandby.resumeIdlePlayback() }
    }

    /// micWarm 的待命状态：warm 且真的收到过音频才算"就绪"。
    private var warmStandbyStatus: String {
        guard recorder.isWarm else { return "麦克风常开未就绪" }
        return recorder.hasRecentAudio ? "麦克风常开待命中" : "麦克风常开中（尚未收到音频）"
    }

    /// 优先 sample-buffer 路线（Typeless 同款，窗口可以不绘制内容）；不可用则回落到视频路线。
    private func startPiPStandby() {
        samplePiP.stop()
        pipStandby.stop()
        pipRoute = ""
        if samplePiP.isSupported, (try? samplePiP.start()) != nil {
            pipRoute = "sample-buffer"
            standbyStatus = samplePiP.status.message
            KeyboardChannel.publishStandby(active: samplePiP.status.active,
                                           mode: samplePiP.status.hidden ? "画中画" : "画中画(可见)")
            return
        }
        do {
            try pipStandby.start()
            pipRoute = "video"
            standbyStatus = pipStandby.status.message
            KeyboardChannel.publishStandby(active: pipStandby.status.active,
                                           mode: pipStandby.status.hidden ? "画中画" : "画中画(可见)")
        } catch {
            pipRoute = ""
            standbyStatus = "画中画待命启动失败：\(error.localizedDescription)"
            KeyboardChannel.publishStandby(active: false, mode: "失败")
        }
    }

    private func stopPiPStandby() {
        samplePiP.stop()
        pipStandby.stop()
        pipRoute = ""
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
        // 注意：待命**不随前台切换而拆除**。micWarm 必须一直保持会话激活，
        // 否则回到前台再切后台就又要重新激活——那正是 iOS 禁止的路径。
        switch standbyMode {
        case .off:
            stopPiPStandby()
            silentStandby.stop()
            recorder.disarm()
            standbyStatus = "未开启"
            KeyboardChannel.publishStandby(active: false, mode: "未开启")
        case .microphoneWarm:
            stopPiPStandby()
            silentStandby.stop()
            do {
                try recorder.arm()
                standbyStatus = warmStandbyStatus
                KeyboardChannel.publishStandby(active: true, mode: "麦克风常开")
                publishPhase(.standby, message: "麦克风常开待命中")
            } catch {
                let message = Self.audioFailureMessage(error, appActive: appIsActive, standby: standbyMode)
                standbyStatus = "麦克风常开启动失败：\(message)"
                diagnostics += "\n\n[待命] microphoneWarm arm 失败：\(error.localizedDescription)"
                KeyboardChannel.publishStandby(active: false, mode: "失败")
            }
        case .silentAudio:
            stopPiPStandby()
            do {
                try silentStandby.start()
                standbyStatus = "静音输出待命中（只保进程，不保后台开麦）"
                KeyboardChannel.publishStandby(active: true, mode: "静音输出")
            } catch {
                standbyStatus = "静音待命启动失败：\(error.localizedDescription)"
                KeyboardChannel.publishStandby(active: false, mode: "失败")
            }
        case .pictureInPicture:
            silentStandby.stop()
            startPiPStandby()
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
