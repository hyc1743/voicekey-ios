import Foundation

/// 中英混排拼接：两侧都是 ASCII 字母数字时补空格，否则直接相连。
///
/// 官方实时客户端（qwen-code）用的是简单空格拼接，那对英文合适；中文会拼出
/// "你好 世界" 这种多余空格，所以在客户端与引擎里统一用这个规则。
enum TranscriptJoiner {
    static func join(_ parts: [String]) -> String {
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
}
