import Foundation

struct ServiceError: LocalizedError {
    let message: String
    var detail: String? = nil

    var errorDescription: String? {
        if let detail, !detail.isEmpty { return "\(message)：\(detail)" }
        return message
    }
}

/// 云端语音识别。默认适配阿里云百炼 `qwen-audio-3.1-asr-flash`。
struct ASRClient {
    var session: URLSession = .shared
    /// 最近一次请求/响应的脱敏摘要，供诊断页展示。
    static var lastExchange: String = ""

    func transcribe(audio: Data, format: UploadFormat, settings: ASRSettings, terms: [String]) async throws -> String {
        guard !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError(message: "缺少语音识别 API Key", detail: "请在设置里填写")
        }
        guard !audio.isEmpty else { throw ServiceError(message: "没有可识别的音频") }

        switch settings.kind {
        case .dashscopeQwen:
            return try await transcribeDashScope(audio: audio, format: format, settings: settings, terms: terms)
        case .openAITranscriptions:
            return try await transcribeMultipart(audio: audio, format: format, settings: settings, terms: terms)
        }
    }

    // MARK: - 阿里云百炼（DashScope 原生多模态接口）

    private func transcribeDashScope(audio: Data, format: UploadFormat, settings: ASRSettings, terms: [String]) async throws -> String {
        guard let url = URL(string: settings.endpoint), url.scheme != nil else {
            throw ServiceError(message: "语音识别接口地址无效", detail: settings.endpoint)
        }
        var content: [[String: Any]] = []
        let instruction = Self.instruction(prompt: settings.customPrompt, terms: terms, language: settings.language)
        if !instruction.isEmpty { content.append(["text": instruction]) }
        content.append(["audio": "data:\(format.mimeType);base64,\(audio.base64EncodedString())"])

        var parameters: [String: Any] = [:]
        if !settings.language.trimmingCharacters(in: .whitespaces).isEmpty {
            parameters["asr_options"] = ["language": settings.language]
        }

        let body: [String: Any] = [
            "model": settings.model.isEmpty ? Defaults.qwenASRModel : settings.model,
            "input": ["messages": [["role": "user", "content": content]]],
            "parameters": parameters
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Self.lastExchange = "POST \(url.absoluteString)\nmodel=\(settings.model)\n格式=\(format.rawValue) 大小=\(audio.count) bytes\n"
            + Self.instruction(prompt: settings.customPrompt, terms: terms, language: settings.language)
        let data = try await send(request, provider: "阿里云百炼")
        return try Self.parseText(data)
    }

    // MARK: - OpenAI 兼容 /audio/transcriptions

    private func transcribeMultipart(audio: Data, format: UploadFormat, settings: ASRSettings, terms: [String]) async throws -> String {
        guard let url = URL(string: settings.endpoint), url.scheme != nil else {
            throw ServiceError(message: "语音识别接口地址无效", detail: settings.endpoint)
        }
        let boundary = "VoiceKey-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", settings.model.isEmpty ? "whisper-1" : settings.model)
        if !settings.language.isEmpty { field("language", settings.language) }
        let prompt = Self.instruction(prompt: settings.customPrompt, terms: terms, language: "")
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
        return try Self.parseText(data)
    }

    // MARK: - 公共

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

    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["message"] as? String { return message }
        if let code = object["code"] as? String { return code }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    /// 防御式解析：兼容 DashScope、OpenAI、以及部分厂商的变体返回结构。
    static func parseText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { throw ServiceError(message: "无法解析识别结果") }
            return raw
        }
        if let text = root["text"] as? String, !text.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let output = root["output"] as? [String: Any] {
            if let text = output["text"] as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let choices = output["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let items = message["content"] as? [[String: Any]] {
                    let joined = items.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { return joined.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ServiceError(message: "识别结果里没有文本字段", detail: String(data: data.prefix(300), encoding: .utf8))
    }

    static func instruction(prompt: String, terms: [String], language: String) -> String {
        var parts: [String] = []
        if !prompt.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(prompt) }
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty { parts.append("请注意以下专有名词的写法：" + cleaned.prefix(40).joined(separator: "、")) }
        if !language.isEmpty { parts.append("音频语言：\(language)") }
        return parts.joined(separator: "\n")
    }
}
