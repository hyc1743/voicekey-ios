import Foundation

/// 文本整理。默认适配 DeepSeek（OpenAI 兼容 /chat/completions）。
struct LLMClient {
    var session: URLSession = .shared
    static var lastExchange: String = ""

    func cleanup(raw: String, settings: LLMSettings, terms: [String]) async throws -> String {
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

        let body: [String: Any] = [
            "model": settings.model.isEmpty ? Defaults.deepSeekModel : settings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": raw]
            ],
            "temperature": settings.temperature,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Self.lastExchange = "POST \(url.absoluteString)\nmodel=\(settings.model)\n原文 \(raw.count) 字"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "整理服务返回了非 HTTP 响应")
        }
        Self.lastExchange += "\nHTTP \(http.statusCode)\n\(String(data: data.prefix(600), encoding: .utf8) ?? "")"
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError(message: "整理请求失败（HTTP \(http.statusCode)）", detail: Self.errorMessage(data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ServiceError(message: "整理结果格式无法解析", detail: String(data: data.prefix(300), encoding: .utf8))
        }
        let text: String
        if let content = message["content"] as? String {
            text = content
        } else if let items = message["content"] as? [[String: Any]] {
            text = items.compactMap { $0["text"] as? String }.joined()
        } else if let reasoning = message["reasoning_content"] as? String {
            text = reasoning
        } else {
            throw ServiceError(message: "整理结果里没有 content 字段")
        }
        let trimmed = Self.stripDecoration(text)
        // 模型偶尔会返回空或明显跑偏，此时退回原文，避免用户丢字。
        guard !trimmed.isEmpty, trimmed.count <= max(40, raw.count * 4) else { return raw }
        return trimmed
    }

    /// 去掉模型可能加的引号/代码块/“整理后：”这类前缀。
    private static func stripDecoration(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["整理后：", "整理后:", "最终文本：", "最终文本:", "输出：", "输出:"] {
            if value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
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
