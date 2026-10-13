import Foundation

/// 文本整理。默认适配 DeepSeek（OpenAI 兼容 /chat/completions），支持流式返回。
struct LLMClient {
    var session: URLSession = .shared
    private(set) var exchange: String = ""

    /// - Parameter onDelta: 流式回调，参数是"到目前为止"的完整文本（不是增量），便于直接上屏。
    func cleanup(raw: String,
                 settings: LLMSettings,
                 terms: [String],
                 onDelta: ((String) -> Void)? = nil) async throws -> String {
        guard settings.enabled else { return raw }
        guard !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ServiceError(message: "缺少整理模型 API Key", detail: "可在设置里关闭整理")
        }
        guard let url = URL(string: settings.endpoint), url.scheme != nil else {
            throw ServiceError(message: "整理接口地址无效", detail: settings.endpoint)
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }

        var system = settings.systemPrompt
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            system += "\n补充术语表（必须是这些写法）：" + cleaned.prefix(60).joined(separator: "、")
        }

        let wantsStream = settings.streaming && onDelta != nil
        var body: [String: Any] = [
            "model": settings.model.isEmpty ? Defaults.deepSeekModel : settings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": raw]
            ],
            "temperature": settings.temperature,
            "stream": wantsStream
        ]
        // DeepSeek 官方文档：思考模式默认开启，用 thinking.type 切换；
        // 只有官方端点认识这些扩展字段，其它兼容网关不发送。
        if settings.isDeepSeekEndpoint {
            body["thinking"] = ["type": settings.thinking ? "enabled" : "disabled"]
            if settings.thinking { body["reasoning_effort"] = settings.reasoningEffort }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if wantsStream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        exchange = "POST \(url.absoluteString)\nmodel=\(settings.model)\n流式=\(wantsStream)\n原文 \(raw.count) 字"

        let produced: String
        if wantsStream, let onDelta {
            produced = try await streamChat(request, onDelta: onDelta)
        } else {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServiceError(message: "整理服务返回了非 HTTP 响应")
            }
            exchange += "\nHTTP \(http.statusCode)\n\(String(data: data.prefix(600), encoding: .utf8) ?? "")"
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError(message: "整理请求失败（HTTP \(http.statusCode)）", detail: Self.errorMessage(data))
            }
            produced = try Self.parseChat(data)
        }

        let trimmed = Self.stripDecoration(produced)
        // 模型偶尔会返回空、或明显跑偏；此时退回原文，避免用户丢字。
        guard !trimmed.isEmpty, trimmed.count <= max(40, raw.count * 4) else { return raw }
        return trimmed
    }

    // MARK: - 流式

    private func streamChat(_ request: URLRequest, onDelta: @escaping (String) -> Void) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "整理服务返回了非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8192 else { break }
                data.append(byte)
            }
            exchange += "\nHTTP \(http.statusCode)\n\(String(data: data.prefix(600), encoding: .utf8) ?? "")"
            throw ServiceError(message: "整理请求失败（HTTP \(http.statusCode)）", detail: Self.errorMessage(data))
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        var accumulated = ""
        var firstChunk = ""
        var sawReasoning = false

        // 有些网关不返回 SSE，退化成一次性读取。
        guard contentType.contains("text/event-stream") else {
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4 * 1024 * 1024 else { throw ServiceError(message: "整理响应过大") }
                data.append(byte)
            }
            firstChunk = try Self.parseChat(data)
            onDelta(firstChunk)
            exchange += "\nHTTP \(http.statusCode)（非 SSE）\n\(String(data: data.prefix(600), encoding: .utf8) ?? "")"
            return firstChunk
        }

        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                let text = String(data: line, encoding: .utf8)
                line.removeAll(keepingCapacity: true)
                guard let text, text.hasPrefix("data:") else { continue }
                let payload = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard !payload.isEmpty,
                      let data = payload.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }

                if let delta = choice["delta"] as? [String: Any] {
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        sawReasoning = true
                    }
                    let piece = Self.text(from: delta["content"])
                    if !piece.isEmpty {
                        accumulated += piece
                        onDelta(accumulated)
                    }
                } else if accumulated.isEmpty, let message = choice["message"] as? [String: Any] {
                    let piece = Self.text(from: message["content"])
                    if !piece.isEmpty {
                        accumulated = piece
                        onDelta(accumulated)
                    }
                }
            } else {
                guard line.count < 64 * 1024 else { throw ServiceError(message: "流式响应行过长") }
                line.append(byte)
            }
        }
        exchange += "\nHTTP \(http.statusCode)（SSE）\n收到 \(accumulated.count) 字"
            + (sawReasoning ? "（期间有思维链输出）" : "")
        if accumulated.isEmpty, sawReasoning {
            throw ServiceError(message: "模型只返回了思考过程", detail: "请在设置里关闭「深度思考模式」后重试")
        }
        return accumulated
    }

    private static func text(from content: Any?) -> String {
        if let value = content as? String { return value }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    static func parseChat(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first else {
            throw ServiceError(message: "整理结果格式无法解析", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        if let message = choice["message"] as? [String: Any] {
            let value = text(from: message["content"])
            if !value.isEmpty { return value }
            // 思考模式下思维链在 reasoning_content，不能当成整理结果上屏。
            if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                throw ServiceError(message: "模型只返回了思考过程", detail: "请在设置里关闭「深度思考模式」后重试")
            }
        }
        if let delta = choice["delta"] as? [String: Any] {
            let value = text(from: delta["content"])
            if !value.isEmpty { return value }
        }
        throw ServiceError(message: "整理结果里没有 content 字段")
    }

    /// 去掉模型可能加的引号/代码块/“整理后：”这类前缀。
    private static func stripDecoration(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["整理后：", "整理后:", "最终文本：", "最终文本:", "输出：", "输出:"] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if value.count >= 2,
           let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }
}
