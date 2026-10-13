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
/// 协议依据：百炼官方 CLI `modelstudioai/cli` 的 `packages/core/src/client/asr-routes.ts`
/// （`resolveAsrApi` / `buildAsrFlashRequest` / `extractAsrFlashText`），
/// 与官方文档《录音文件识别》一致：
/// - `fun-asr-flash*`、`qwen-audio*-asr-flash` → **input_audio 族**
///   `parameters: {format, sample_rate, language_hints, vocabulary_id, vocabulary}`
/// - `qwen3-asr-flash` → **qwen3 族** `content: [{audio}]` + `parameters.asr_options.language`
/// 两族都走同一个同步端点 `.../aigc/multimodal-generation/generation`。
struct ASRClient {
    var session: URLSession = .shared
    static var lastExchange: String = ""

    func transcribe(audio: Data, format: UploadFormat, settings: ASRSettings, terms: [String]) async throws -> String {
        guard !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError(message: "缺少语音识别 API Key", detail: "请在设置里填写")
        }
        guard !audio.isEmpty else { throw ServiceError(message: "没有可识别的音频") }

        switch settings.resolvedKind {
        case .openAITranscriptions:
            return try await transcribeMultipart(audio: audio, format: format, settings: settings, terms: terms)
        case .dashscopeInputAudio:
            return try await transcribeInputAudioFamily(audio: audio, format: format, settings: settings, terms: terms)
        case .dashscopeQwen3:
            return try await transcribeQwen3Family(audio: audio, format: format, settings: settings, terms: terms)
        case .auto:
            return try await transcribeInputAudioFamily(audio: audio, format: format, settings: settings, terms: terms)
        }
    }

    // MARK: - input_audio 族（qwen-audio-3.1-asr-flash / fun-asr-flash）

    private func transcribeInputAudioFamily(audio: Data, format: UploadFormat,
                                           settings: ASRSettings, terms: [String]) async throws -> String {
        let url = try endpoint(settings)
        let dataURI = "data:\(format.mimeType);base64,\(audio.base64EncodedString())"

        var messages: [[String: Any]] = []
        // 上下文提示必须作为独立的 input_text 消息，且排在音频消息之前（官方 CLI 注释）。
        let context = contextText(prompt: settings.customPrompt, terms: settings.useVocabulary ? [] : terms, language: settings.language)
        if !context.isEmpty {
            messages.append(["role": "user", "content": [["type": "input_text", "text": context]]])
        }
        messages.append(["role": "user", "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]])

        var parameters: [String: Any] = [
            "format": settings.formatHintOverride.isEmpty
                ? Self.inferFormatHint(mimeType: format.mimeType)
                : settings.formatHintOverride,
            "sample_rate": "16000"
        ]
        if !settings.language.isEmpty { parameters["language_hints"] = [settings.language] }
        if settings.useVocabulary, !terms.isEmpty {
            parameters["vocabulary"] = Dictionary(uniqueKeysWithValues: terms.prefix(200).map { ($0, 4) })
        }

        let body: [String: Any] = ["model": settings.model.isEmpty ? Defaults.qwenASRModel : settings.model,
                                   "input": ["messages": messages],
                                   "parameters": parameters]
        Self.lastExchange = "POST \(url.absoluteString)\n族=input_audio model=\(settings.model)\nformat=\(parameters["format"] ?? "") 音频=\(audio.count) bytes"
        let data = try await post(body, to: url, key: settings.apiKey, provider: "百炼 ASR")
        return try Self.extractInputAudioText(data)
    }

    // MARK: - qwen3 族

    private func transcribeQwen3Family(audio: Data, format: UploadFormat,
                                       settings: ASRSettings, terms: [String]) async throws -> String {
        let url = try endpoint(settings)
        let dataURI = "data:\(format.mimeType);base64,\(audio.base64EncodedString())"
        var parameters: [String: Any] = [:]
        if !settings.language.isEmpty { parameters["asr_options"] = ["language": settings.language] }

        let body: [String: Any] = ["model": settings.model.isEmpty ? "qwen3-asr-flash" : settings.model,
                                   "input": ["messages": [["role": "user", "content": [["audio": dataURI]]]]],
                                   "parameters": parameters]
        Self.lastExchange = "POST \(url.absoluteString)\n族=qwen3 model=\(settings.model)\n音频=\(audio.count) bytes"
        let data = try await post(body, to: url, key: settings.apiKey, provider: "百炼 ASR")
        return try Self.extractQwen3Text(data)
    }

    // MARK: - OpenAI 兼容 multipart

    private func transcribeMultipart(audio: Data, format: UploadFormat,
                                     settings: ASRSettings, terms: [String]) async throws -> String {
        let url = try endpoint(settings)
        let boundary = "VoiceKey-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", settings.model.isEmpty ? "whisper-1" : settings.model)
        if !settings.language.isEmpty { field("language", settings.language) }
        let prompt = contextText(prompt: settings.customPrompt, terms: terms, language: "")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(format.fileExtension)\"\r\nContent-Type: \(format.mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        Self.lastExchange = "POST \(url.absoluteString)\nmodel=\(settings.model)\n格式=\(format.rawValue) 大小=\(audio.count) bytes"
        let data = try await send(request, provider: "语音识别")
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try Self.extractInputAudioText(data)
    }

    // MARK: - 公共

    private func endpoint(_ settings: ASRSettings) throws -> URL {
        guard let url = URL(string: settings.endpoint), url.scheme != nil else {
            throw ServiceError(message: "语音识别接口地址无效", detail: settings.endpoint)
        }
        return url
    }

    private func post(_ body: [String: Any], to url: URL, key: String, provider: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 同步接口：关掉 SSE，直接拿一次性 JSON。
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, provider: provider)
    }

    private func send(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "\(provider)返回了非 HTTP 响应")
        }
        let preview = String(data: data.prefix(600), encoding: .utf8) ?? "<\(data.count) 字节>"
        Self.lastExchange += "\nHTTP \(http.statusCode)\n\(preview)"
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError(message: "\(provider)请求失败（HTTP \(http.statusCode)）", detail: Self.errorMessage(data))
        }
        return data
    }

    /// 官方 CLI 的 `inferAudioFormatHint`：从数据 URI 的 MIME 推断 format。
    static func inferFormatHint(mimeType: String) -> String {
        let lower = mimeType.lowercased()
        guard lower.hasPrefix("audio/") else { return "wav" }
        let subtype = String(lower.dropFirst("audio/".count))
        if subtype == "mpeg" { return "mp3" }
        if subtype == "x-wav" || subtype == "wave" || subtype == "wav" { return "wav" }
        return subtype
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

    /// input_audio 族的取文顺序：output.text → output.sentence.text → output.output.sentence.text。
    static func extractInputAudioText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(message: "无法解析识别结果", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        if let output = root["output"] as? [String: Any] {
            if let text = output["text"] as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let sentence = output["sentence"] as? [String: Any], let text = sentence["text"] as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let nested = output["output"] as? [String: Any],
               let sentence = nested["sentence"] as? [String: Any],
               let text = sentence["text"] as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // 兜底：兼容其它厂商返回
        if let text = root["text"] as? String, !text.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let qwen3 = (try? extractQwen3Text(data)) ?? ""
        if !qwen3.isEmpty { return qwen3 }
        throw ServiceError(message: "识别结果里没有文本字段", detail: String(data: data.prefix(300), encoding: .utf8))
    }

    /// qwen3 族的取文顺序：output.choices[].message.content（字符串或 [{text}]）。
    static func extractQwen3Text(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ServiceError(message: "识别结果里没有 choices", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let items = message["content"] as? [[String: Any]] {
            let joined = items.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        throw ServiceError(message: "识别结果里没有文本字段")
    }

    /// 上下文文本：官方 input_audio 族把上下文放进独立的 input_text 消息。
    private func contextText(prompt: String, terms: [String], language: String) -> String {
        var parts: [String] = []
        if !prompt.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(prompt) }
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            parts.append("请注意以下专有名词的写法：" + cleaned.prefix(40).joined(separator: "、"))
        }
        if !language.isEmpty { parts.append("音频语言：\(language)") }
        return parts.joined(separator: "\n")
    }
}
