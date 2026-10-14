import AVFoundation
import Foundation

/// 百炼实时语音识别（WebSocket）。
///
/// 协议逐字段照抄阿里官方 CLI（`QwenLM/qwen-code`，Apache-2.0）
/// `packages/cli/src/ui/voice/qwen-asr-realtime-session.ts`，不自行发明字段：
///
/// 1. 连接 `wss://<host>/api-ws/v1/realtime?model=<model>`，鉴权放 WebSocket 请求头；
/// 2. 收到 `session.created` → 发 `session.update`：
///    `{"input_audio_format":"pcm","sample_rate":16000,
///      "input_audio_transcription":{"language":…,"corpus_text":…},"turn_detection":null}`
/// 3. 收到 `session.updated` → 就绪，开始推音频帧：
///    `{"type":"input_audio_buffer.append","audio":"<base64 PCM16>"}`
/// 4. 实时预览：`conversation.item.input_audio_transcription.text` → `{text, stash}`
///    成句：`conversation.item.input_audio_transcription.completed` → `{transcript}`（用空格拼接）
/// 5. 收尾：`input_audio_buffer.commit` + `session.finish` → 等 `session.finished`
///
/// 背压：在途字节超过 1 MiB 时丢帧并只警告一次（同官方实现）。
@MainActor
final class RealtimeASRClient {
    enum Event: Equatable {
        case ready
        case interim(String)      // 已提交文本 + 当前预览
        case committed(String)    // 成句后的完整文本
        case failed(String)
        case finished(String)
    }

    private enum Limits {
        static let connectTimeout: UInt64 = 8_000_000_000        // 8 s
        static let finishTimeout: UInt64 = 60_000_000_000        // 60 s
        static let maxPendingBytes = 1024 * 1024                 // 1 MiB
        static let maxErrorLength = 400
    }

    private let endpoint: String
    private let model: String
    private let apiKey: String
    private let language: String
    private let corpusText: String
    private let onEvent: (Event) -> Void

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var committed = ""
    private var preview = ""
    private var isReady = false
    private var isFinished = false
    private var isClosed = false
    private var pendingBytes = 0
    private var backpressureWarned = false
    private var failureMessage: String?

    init(endpoint: String, model: String, apiKey: String, language: String, corpusText: String,
         session: URLSession = .shared, onEvent: @escaping (Event) -> Void) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.language = language
        self.corpusText = corpusText
        self.session = session
        self.onEvent = onEvent
    }

    var transcript: String { committed.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - 连接

    func connect() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError(message: "缺少实时识别 API Key")
        }
        guard var components = URLComponents(string: endpoint) else {
            throw ServiceError(message: "实时识别地址无效", detail: endpoint)
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw ServiceError(message: "实时识别地址无效", detail: endpoint)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Limits.connectTimeout)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.failAll("实时识别连接超时（8 秒内没有收到 session.updated）")
                }
            }
        }
    }

    // MARK: - 上行

    func append(pcm: Data) {
        guard isReady, !isFinished, !isClosed, let task, !pcm.isEmpty else { return }
        let encoded = pcm.base64EncodedString()
        if pendingBytes > Limits.maxPendingBytes {
            if !backpressureWarned {
                backpressureWarned = true
                onEvent(.failed("网络拥塞，已丢弃部分音频帧"))
            }
            return
        }
        backpressureWarned = false
        pendingBytes += encoded.utf8.count
        guard let text = Self.json(["type": "input_audio_buffer.append", "audio": encoded]) else {
            pendingBytes -= encoded.utf8.count
            return
        }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBytes = max(0, self.pendingBytes - encoded.utf8.count)
                if let error {
                    self.onEvent(.failed("音频上行失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    /// 收尾：commit + finish，等到 session.finished 返回最终文本。
    func finish() async throws -> String {
        if isFinished { return transcript }
        // 连接已断/已报错时不再等 60 秒超时，让上层立刻回落到批量通道。
        if let failureMessage { throw ServiceError(message: failureMessage) }
        guard !isClosed else { throw ServiceError(message: "实时识别连接已关闭") }
        guard isReady else { throw ServiceError(message: "实时识别尚未就绪") }
        sendJSON(["type": "input_audio_buffer.commit"])
        sendJSON(["type": "session.finish"])

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            finishContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Limits.finishTimeout)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.failAll("实时识别收尾超时（60 秒内没有收到 session.finished）")
                }
            }
        }
    }

    func abort() {
        guard !isClosed else { return }
        close(reason: "用户取消")
    }

    // MARK: - 下行

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.failAll("实时连接中断：\(error.localizedDescription)")
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        break
                    }
                    if !self.isClosed { self.receive() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
        case "session.created":
            sendSessionUpdate()

        case "session.updated":
            isReady = true
            timeoutTask?.cancel()
            readyContinuation?.resume()
            readyContinuation = nil
            onEvent(.ready)

        case "conversation.item.input_audio_transcription.text":
            let value = (root["text"] as? String ?? "") + (root["stash"] as? String ?? "")
            preview = value.trimmingCharacters(in: .whitespacesAndNewlines)
            onEvent(.interim(TranscriptJoiner.join([committed, preview])))

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = root["transcript"] as? String, !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                committed = TranscriptJoiner.join([committed, transcript])
                preview = ""
                onEvent(.committed(committed))
            }

        case "conversation.item.input_audio_transcription.failed":
            let message = Self.errorMessage(root) ?? "实时识别失败"
            onEvent(.failed(message))
            failAll(message)

        case "session.finished":
            isFinished = true
            let final = transcript
            timeoutTask?.cancel()
            finishContinuation?.resume(returning: final)
            finishContinuation = nil
            onEvent(.finished(final))
            close(reason: "正常结束")

        case "error":
            let message = Self.errorMessage(root) ?? "实时识别请求失败"
            onEvent(.failed(message))
            failAll(message)

        default:
            break
        }
    }

    private func sendSessionUpdate() {
        var transcription: [String: Any] = [:]
        if !language.trimmingCharacters(in: .whitespaces).isEmpty { transcription["language"] = language }
        if !corpusText.trimmingCharacters(in: .whitespaces).isEmpty { transcription["corpus_text"] = corpusText }
        sendJSON([
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": 16_000,
                "input_audio_transcription": transcription,
                "turn_detection": NSNull()      // 与官方 CLI 一致：ASR 模式不开服务端 VAD，起停由客户端控制
            ]
        ])
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let text = Self.json(payload), let task else { return }
        task.send(.string(text)) { _ in }
    }

    private func failAll(_ message: String) {
        guard !isFinished else { return }
        if failureMessage == nil { failureMessage = message }
        timeoutTask?.cancel()
        readyContinuation?.resume(throwing: ServiceError(message: message))
        readyContinuation = nil
        finishContinuation?.resume(throwing: ServiceError(message: message))
        finishContinuation = nil
        close(reason: message)
    }

    private func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(with: .normalClosure, reason: reason.prefix(120).data(using: .utf8))
        task = nil
    }

    // MARK: - 工具

    private static func json(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func errorMessage(_ root: [String: Any]) -> String? {
        guard let error = root["error"] as? [String: Any] else { return nil }
        let message = error["message"] as? String
        let code = error["code"] as? String
        let text = message ?? code
        return text.map { String($0.prefix(Limits.maxErrorLength)) }
    }
}
