import Foundation

struct ServiceError: LocalizedError {
    let message: String
    var detail: String? = nil

    var errorDescription: String? {
        if let detail, !detail.isEmpty { return "\(message)：\(detail)" }
        return message
    }
}

/// 云端语音识别。
///
/// 百炼部分**逐字段对齐已在真机验证过的实现**（`Voxt-ios` 的
/// `RemoteClients.aliyunASRPayload` 及其单测 `testQwenAudio31UsesNativeDashScopeSchema`、
/// `testProviderCapabilitiesNeverInventUnknownHotwordParameters`），
/// 路由规则同时与百炼官方 CLI `modelstudioai/cli` 的 `asr-routes.ts` 一致：
///
/// - `qwen-audio-3.x-asr-flash`、`fun-asr-flash*` → **原生短音频**
///   `POST /api/v1/services/aigc/multimodal-generation/generation`
///   `{"model":…,"input":{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"data:audio/wav;base64,…"}}]}]},
///     "parameters":{"format":"wav","sample_rate":16000}}`，请求头带 `X-DashScope-SSE: disable`
/// - `qwen3-asr-flash*` → **兼容模式 chat**
///   `POST /compatible-mode/v1/chat/completions`，`{model, stream:false, messages:[…input_audio…]}`
/// - 其它 → OpenAI 兼容 `/audio/transcriptions`（multipart）
///
/// 刻意*不*发的东西：这些模型上没有依据的热词字段（`parameters.vocabulary`）、
/// 额外的 `input_text` 上下文消息。术语改由整理模型的提示词承担。
final class ASRClient {
    var session: URLSession = .shared
    /// 实例级：并发分段时不会互相覆盖（原来是 static，存在竞态）。
    private(set) var exchange: String = ""

    /// 已验证实现的硬限制：base64 后不超过 10 MB。
    private static let maxBase64Bytes = 10 * 1024 * 1024

    func transcribe(audio: Data, format: UploadFormat, settings: ASRSettings, terms: [String]) async throws -> String {
        guard !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError(message: "缺少语音识别 API Key", detail: "请在设置里填写")
        }
        guard !audio.isEmpty else { throw ServiceError(message: "没有可识别的音频") }
        let encoded = audio.base64EncodedString()
        guard encoded.utf8.count < Self.maxBase64Bytes else {
            throw ServiceError(message: "单段音频过大", detail: "base64 后需小于 10 MB，请缩短分段长度或改用 AAC/m4a")
        }
        let dataURI = "data:\(format.mimeType);base64,\(encoded)"

        switch settings.resolvedKind {
        case .openAITranscriptions:
            return try await transcribeMultipart(dataURI: dataURI, audio: audio, format: format, settings: settings, terms: terms)
        case .dashscopeCompatibleChat:
            return try await transcribeCompatibleChat(dataURI: dataURI, format: format, settings: settings, terms: terms)
        case .dashscopeNative, .auto:
            return try await transcribeNative(dataURI: dataURI, format: format, settings: settings)
        }
    }

    // MARK: - 原生短音频（qwen-audio-3.x-asr-flash）

    private func transcribeNative(dataURI: String, format: UploadFormat,
                                  settings: ASRSettings) async throws -> String {
        let url = try Self.resolveURL(settings.endpoint, native: true)
        var parameters: [String: Any] = [
            "format": settings.formatHintOverride.isEmpty ? Self.formatHint(for: format) : settings.formatHintOverride,
            // 已验证实现用的是整数而不是字符串。
            "sample_rate": 16_000
        ]
        if settings.useCLIExtras, !settings.language.isEmpty {
            parameters["language_hints"] = [settings.language]
        }

        let body: [String: Any] = [
            "model": settings.model.isEmpty ? Defaults.qwenASRModel : settings.model,
            "input": ["messages": [[
                "role": "user",
                "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]
            ]]],
            "parameters": parameters
        ]
        exchange = "POST \(url.absoluteString)\n路由=原生短音频 model=\(settings.model)\nformat=\(parameters["format"] ?? "")"
            + "\n音频 base64 \(dataURI.utf8.count / 1024) KB"
        let data = try await post(body, to: url, key: settings.apiKey, provider: "百炼 ASR", disableSSE: true)
        return try Self.extractNativeText(data)
    }

    // MARK: - 兼容模式 chat（qwen3-asr-flash）

    private func transcribeCompatibleChat(dataURI: String, format: UploadFormat,
                                          settings: ASRSettings, terms: [String]) async throws -> String {
        let url = try Self.resolveURL(settings.endpoint, native: false)
        var messages: [[String: Any]] = []
        // 该路由支持术语提示，写法与已验证实现一致（system 消息）。
        if !terms.isEmpty {
            messages.append(["role": "system",
                             "content": "Reference terms (use only when they match the audio): " + terms.joined(separator: ", ")])
        }
        messages.append([
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": ["data": dataURI,
                                "format": settings.formatHintOverride.isEmpty ? Self.formatHint(for: format) : settings.formatHintOverride]
            ]]
        ])
        let body: [String: Any] = [
            "model": settings.model.isEmpty ? "qwen3-asr-flash" : settings.model,
            "stream": false,
            "messages": messages
        ]
        exchange = "POST \(url.absoluteString)\n路由=兼容模式 chat model=\(settings.model)\n音频 base64 \(dataURI.utf8.count / 1024) KB"
        let data = try await post(body, to: url, key: settings.apiKey, provider: "百炼 ASR", disableSSE: false)
        return try Self.extractCompatibleText(data)
    }

    // MARK: - OpenAI 兼容 multipart

    private func transcribeMultipart(dataURI: String, audio: Data, format: UploadFormat,
                                     settings: ASRSettings, terms: [String]) async throws -> String {
        let url = try Self.requireURL(settings.endpoint, field: "语音识别接口地址")
        let boundary = "VoiceKey-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", settings.model.isEmpty ? "whisper-1" : settings.model)
        if !settings.language.isEmpty { field("language", settings.language) }
        if !terms.isEmpty { field("prompt", "Reference terms: " + terms.prefix(100).joined(separator: ", ")) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(format.fileExtension)\"\r\nContent-Type: \(format.mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        exchange = "POST \(url.absoluteString)\nmodel=\(settings.model)\n格式=\(format.rawValue) 大小=\(audio.count) bytes"
        let data = try await send(request, provider: "语音识别")
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try Self.extractNativeText(data)
    }

    // MARK: - 公共

    private func post(_ body: [String: Any], to url: URL, key: String,
                      provider: String, disableSSE: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if disableSSE { request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, provider: provider)
    }

    private func send(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "\(provider)返回了非 HTTP 响应")
        }
        let preview = String(data: data.prefix(600), encoding: .utf8) ?? "<\(data.count) 字节>"
        exchange += "\nHTTP \(http.statusCode)\n\(preview)"
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError(message: "\(provider)请求失败（HTTP \(http.statusCode)）", detail: Self.errorMessage(data))
        }
        return data
    }

    /// 端点归一化：用户可能填了兼容模式地址、或只填到 `/api/v1`，这里自动改写（与已验证实现同逻辑）。
    static func resolveURL(_ endpoint: String, native: Bool) throws -> URL {
        let url = try requireURL(endpoint, field: "语音识别接口地址")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServiceError(message: "语音识别接口地址无效", detail: endpoint)
        }
        let nativePath = "/api/v1/services/aigc/multimodal-generation/generation"
        let compatiblePath = "/compatible-mode/v1/chat/completions"
        // 非百炼地址原样使用（比如用户在填 OpenAI 兼容服务）。
        guard url.host?.contains("aliyuncs.com") == true || url.host?.contains("maas.aliyuncs.com") == true else {
            return url
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if native {
            if path == String(compatiblePath.dropFirst()) {
                components.path = nativePath
            } else if path.isEmpty || path == "api/v1" || path.hasSuffix("/api/v1") {
                components.path = "/" + (path.isEmpty ? "api/v1" : path) + "/services/aigc/multimodal-generation/generation"
            }
        } else {
            if path == String(nativePath.dropFirst()) || path.isEmpty {
                components.path = compatiblePath
            } else if path == "api/v1" || path.hasSuffix("/api/v1") {
                components.path = "/compatible-mode/v1/chat/completions"
            }
        }
        guard let final = components.url else {
            throw ServiceError(message: "语音识别接口地址无效", detail: endpoint)
        }
        return final
    }

    private static func requireURL(_ endpoint: String, field: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme != nil else {
            throw ServiceError(message: "\(field)无效", detail: endpoint)
        }
        return url
    }

    private static func formatHint(for format: UploadFormat) -> String {
        format == .wav ? "wav" : "m4a"
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["message"] as? String { return message }
        if let code = object["code"] as? String { return code }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    /// 原生短音频取文：output.text → output.sentence(.text) → output.choices。
    static func extractNativeText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any] else {
            throw ServiceError(message: "识别结果格式无法解析", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        for candidate in [output["text"], output["sentence"], output["choices"]] {
            if let text = text(from: candidate), !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw ServiceError(message: "识别结果里没有文本字段", detail: String(data: data.prefix(300), encoding: .utf8))
    }

    /// 兼容模式取文：choices[].message.content。
    static func extractCompatibleText(_ data: Data) throws -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = text(from: message["content"]), !text.isEmpty else {
            throw ServiceError(message: "识别结果里没有文本字段", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(from value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String, !text.isEmpty { return text }
            if let sentence = dict["text"] as? String { return sentence }
            if let nested = dict["sentence"] as? [String: Any], let text = nested["text"] as? String { return text }
        }
        if let items = value as? [[String: Any]] {
            let joined = items.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
            if let first = items.first, let text = first["text"] as? String { return text }
        }
        return nil
    }
}
