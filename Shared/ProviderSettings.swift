import Foundation

enum ASRKind: String, Codable, CaseIterable, Identifiable {
    case dashscopeQwen
    case openAITranscriptions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashscopeQwen: "阿里云百炼 Qwen ASR"
        case .openAITranscriptions: "OpenAI 兼容 /audio/transcriptions"
        }
    }
    var hint: String {
        switch self {
        case .dashscopeQwen: "DashScope 原生多模态接口，音频以 Base64 WAV 直传，默认模型 qwen-audio-3.1-asr-flash。"
        case .openAITranscriptions: "multipart 上传 WAV，适用于 Whisper、GLM、SenseVoice 等兼容服务。"
        }
    }
}

enum LLMKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容 /chat/completions"
        }
    }
    var hint: String {
        switch self {
        case .openAICompatible: "DeepSeek、OpenAI、Kimi、通义、Ollama、LM Studio 都走这个接口。"
        }
    }
}

struct ASRSettings: Codable, Equatable {
    var kind: ASRKind = .dashscopeQwen
    var endpoint: String = Defaults.dashscopeASREndpoint
    var apiKey: String = ""
    var model: String = Defaults.qwenASRModel
    var language: String = ""            // 空 = 自动；"zh" / "en" 等
    var customPrompt: String = ""        // 术语/热词提示，部分服务支持

    static let `default` = ASRSettings()
}

struct LLMSettings: Codable, Equatable {
    var enabled: Bool = true
    var kind: LLMKind = .openAICompatible
    var endpoint: String = Defaults.deepSeekEndpoint
    var apiKey: String = ""
    var model: String = Defaults.deepSeekModel
    var systemPrompt: String = Defaults.defaultCleanupPrompt
    var temperature: Double = 0.2

    static let `default` = LLMSettings()
}

enum Defaults {
    static let dashscopeASREndpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    static let qwenASRModel = "qwen-audio-3.1-asr-flash"
    static let openAIASREndpoint = "https://api.openai.com/v1/audio/transcriptions"
    static let deepSeekEndpoint = "https://api.deepseek.com/v1/chat/completions"
    static let deepSeekModel = "deepseek-chat"

    static let defaultCleanupPrompt = """
    你是一个语音输入后处理器。用户给你一段语音识别的原始文本，请输出可以直接上屏的最终文本。
    规则：
    1. 去掉口头语、重复词、明显的识别噪声（例如“嗯”“那个”“呃”）。
    2. 修正同音字与标点，补全句子必要的标点。
    3. 保留说话人的原意、语气和语言（不要翻译，不要扩写，不要总结）。
    4. 如果原文已经是通顺的书面语，原样返回。
    5. 只输出最终文本，不要任何解释、前缀、引号或 Markdown。
    """

    static let defaultASRTerms = ""
}

/// 设置读写：优先写 App Group，读不到就退回 App 自己的 UserDefaults。
/// 键盘扩展只需要读“是否已配置”和状态，不接触密钥。
enum SettingsStore {
    static func load() -> (asr: ASRSettings, llm: LLMSettings) {
        let store = UserDefaults(suiteName: SharedStore.groupIdentifier)
        func data(_ key: String) -> Data? {
            (SharedStore.defaults?.data(forKey: key)) ?? store?.data(forKey: key) ?? UserDefaults.standard.data(forKey: key)
        }
        let asr = data("asrSettings").flatMap { try? JSONDecoder().decode(ASRSettings.self, from: $0) } ?? .default
        let llm = data("llmSettings").flatMap { try? JSONDecoder().decode(LLMSettings.self, from: $0) } ?? .default
        return (asr, llm)
    }

    static func save(asr: ASRSettings, llm: LLMSettings) {
        let encoder = JSONEncoder()
        guard let asrData = try? encoder.encode(asr), let llmData = try? encoder.encode(llm) else { return }
        SharedStore.defaults?.set(asrData, forKey: "asrSettings")
        SharedStore.defaults?.set(llmData, forKey: "llmSettings")
        UserDefaults.standard.set(asrData, forKey: "asrSettings")
        UserDefaults.standard.set(llmData, forKey: "llmSettings")
    }

    static func markConfigured(_ configured: Bool) {
        SharedStore.defaults?.set(configured, forKey: "configured")
    }

    static var isConfigured: Bool {
        SharedStore.defaults?.bool(forKey: "configured") ?? false
    }
}
