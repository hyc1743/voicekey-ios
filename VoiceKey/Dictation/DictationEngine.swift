import AVFoundation
import Combine
import Foundation
import UIKit

/// 语音输入的完整链路：录音 → 云端 ASR → 云端整理 → 落库 / 上屏。
///
/// 键盘触发的流程与 App 内录音共用同一条链路，只是出口不同（共享文件 + Darwin 通知）。
@MainActor
final class DictationEngine: ObservableObject {
    enum Stage: Equatable {
        case idle
        case recording
        case transcribing
        case cleaning
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
    @Published private(set) var diagnostics: String = ""
    @Published private(set) var triggerSource: String = "app"
    @Published var autoStopOnSilence: Bool = true

    @Published var asr: ASRSettings {
        didSet { persist() }
    }
    @Published var llm: LLMSettings {
        didSet { persist() }
    }
    @Published var personalTerms: String {
        didSet { UserDefaults.standard.set(personalTerms, forKey: "personalTerms") }
    }
    @Published var standbyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(standbyEnabled, forKey: "standbyEnabled")
            if !standbyEnabled { standby.stop() }
        }
    }

    let history = HistoryStore()

    private let recorder = AudioRecorder()
    private let standby = StandbyKeeper()
    private var ticker: Timer?
    private var heartbeat: Timer?
    private var requestObserver: AnyObject?
    private var currentRequest: DictationRequest?
    private var silenceAccumulated: Double = 0
    private var pending: DictationRequest?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let loaded = SettingsStore.load()
        asr = loaded.asr
        llm = loaded.llm
        personalTerms = UserDefaults.standard.string(forKey: "personalTerms") ?? ""
        standbyEnabled = UserDefaults.standard.bool(forKey: "standbyEnabled")
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.handleLevel(value) }
        }
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeKeyboard()
        startHeartbeat()
        publishPhase(.standby, message: "主 App 已就绪")
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
        triggerSource = source
        Task { await startRecording(source: source) }
    }

    func stopAndProcess() {
        guard case .recording = stage else { return }
        process()
    }

    func cancel() {
        recorder.cancel()
        stopTicker()
        stage = .idle
        seconds = 0
        level = 0
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
            pending = nil
            begin(source: "keyboard")
            currentRequest = request
            reply(request, kind: .accepted, text: nil, message: "已开始录音")
        case "stop":
            if let current = currentRequest, current.sessionID == request.sessionID {
                stopAndProcess()
            } else if case .recording = stage {
                stopAndProcess()
            } else {
                reply(request, kind: .rejected, text: nil, message: "当前没有在录音")
            }
        case "cancel":
            cancel()
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
            stage = .failed("没有麦克风权限，请到系统设置里允许 VOXT 使用麦克风。")
            publishPhase(.error, message: "没有麦克风权限")
            return
        }
        do {
            try recorder.start()
        } catch {
            stage = .failed(error.localizedDescription)
            publishPhase(.error, message: error.localizedDescription)
            if let request = currentRequest {
                reply(request, kind: .failed, text: nil, message: error.localizedDescription)
                currentRequest = nil
            }
            return
        }
        stage = .recording
        seconds = 0
        silenceAccumulated = 0
        publishPhase(.recording, message: "正在录音")
        startTicker()
    }

    private func handleLevel(_ value: Float) {
        level = value
        guard case .recording = stage, autoStopOnSilence else { return }
        let isQuiet = value < 0.01
        let hasSpeech = value > 0.03
        if hasSpeech { silenceAccumulated = 0 }
        else if isQuiet, seconds > 1.5 { silenceAccumulated += 0.05 }
        if silenceAccumulated > 2.2, hasSpeech == false, seconds > 1.5 {
            stopAndProcess()
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds += 0.05
                if self.seconds >= 120 { self.stopAndProcess() }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func process() {
        let duration = recorder.duration
        guard let wav = recorder.stop() else {
            recorder.cancel()
            stopTicker()
            stage = .failed("没有录到有效音频，请按住多说几个字。")
            publishPhase(.error, message: "没有录到有效音频")
            if let request = currentRequest {
                reply(request, kind: .failed, text: nil, message: "没有录到有效音频")
                currentRequest = nil
            }
            return
        }
        stopTicker()
        level = 0
        stage = .transcribing
        publishPhase(.processing, message: "识别中")
        let terms = personalTerms
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let asrSettings = asr
        let llmSettings = llm
        let source = triggerSource

        Task {
            do {
                let raw = try await ASRClient().transcribe(wav: wav, settings: asrSettings, terms: terms)
                self.lastRaw = raw
                self.diagnostics = ASRClient.lastExchange
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ServiceError(message: "识别结果为空，请重说一次")
                }
                self.stage = .cleaning
                let final: String
                do {
                    final = try await LLMClient().cleanup(raw: raw, settings: llmSettings, terms: terms)
                    self.diagnostics += "\n\n--- 整理 ---\n" + LLMClient.lastExchange
                } catch {
                    final = raw
                    self.diagnostics += "\n\n--- 整理失败（已使用原始识别结果）---\n\(error.localizedDescription)"
                }
                self.finish(text: final, raw: raw, seconds: duration, source: source)
            } catch {
                self.stage = .failed(error.localizedDescription)
                self.publishPhase(.error, message: "识别失败")
                if let request = self.currentRequest {
                    self.reply(request, kind: .failed, text: nil, message: error.localizedDescription)
                    self.currentRequest = nil
                }
            }
        }
    }

    private func finish(text: String, raw: String, seconds: Double, source: String) {
        stage = .done(text)
        history.add(HistoryRecord(id: UUID(), date: Date(), raw: raw, text: text,
                                  seconds: seconds, source: source,
                                  asrModel: asr.model, llmModel: llm.enabled ? llm.model : "未整理"))
        UIPasteboard.general.string = text
        SharedStore.publishResult(text: text, sessionID: currentRequest?.sessionID ?? UUID().uuidString)
        if let request = currentRequest {
            reply(request, kind: .completed, text: text, message: "已完成")
            currentRequest = nil
        }
        triggerSource = "app"
    }

    // MARK: - 待命与心跳

    func handleScenePhase(active: Bool) {
        if active {
            standby.stop()
            publishPhase(.standby, message: "主 App 已就绪")
        } else if standbyEnabled {
            do {
                try standby.start()
                diagnostics += "\n\n后台待命已开启（静音输出，系统仍可能挂起）。"
            } catch {
                diagnostics += "\n\n后台待命启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SharedStore.markHeartbeat() }
        }
    }

    private func publishPhase(_ phase: SharedStore.Phase, message: String) {
        SharedStore.publish(phase: phase, message: message)
    }

    private func persist() {
        SettingsStore.save(asr: asr, llm: llm)
        let configured = !asr.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        SettingsStore.markConfigured(configured)
    }
}
