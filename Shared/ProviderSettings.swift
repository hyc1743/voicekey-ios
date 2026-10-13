import Foundation

/// ASR 协议族。默认按模型名自动判定，规则与百炼官方 CLI 的 asr-routes.ts 一致：
/// `fun-asr-flash*` 与 `qwen-audio*-asr-flash` 走 input_audio 族；
/// `qwen3-asr-flash` 走 content.audio + asr_options 族。
enum ASRKind: String, Codable, CaseIterable, Identifiable {
    case auto
    case dashscopeInputAudio
    case dashscopeQwen3
    case openAITranscriptions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动（按模型名判断协议族）"
        case .dashscopeInputAudio: "百炼 input_audio 族"
        case .dashscopeQwen3: "百炼 qwen3-asr-flash 族"
        case .openAITranscriptions: "OpenAI 兼容 /audio/transcriptions"
        }
    }
    var hint: String {
        switch self {
        case .auto: "推荐。模型名以 qwen-audio / fun-asr-flash 开头走 input_audio 族，qwen3-asr-flash 走旧族。"
        case .dashscopeInputAudio: "content 用 {type: input_audio}，参数 format/sample_rate/language_hints/vocabulary。"
        case .dashscopeQwen3: "content 用 {audio}，参数 asr_options.language。"
        case .openAITranscriptions: "multipart 上传，适用于 Whisper、GLM、SenseVoice 等兼容服务。"
        }
    }

    /// 官方 CLI 的判定顺序：realtime/streaming、filetrans 都另有接口，
    /// 这里只覆盖同步 flash 两类。
    static func resolve(model: String) -> ASRKind {
        let name = model.lowercased()
        if name.contains("realtime") || name.contains("streaming") { return .dashscopeInputAudio }
        if name.contains("filetrans") { return .dashscopeInputAudio }
        if name.hasPrefix("fun-asr-flash") { return .dashscopeInputAudio }
        if name.hasPrefix("qwen-audio") && name.contains("asr-flash") { return .dashscopeInputAudio }
        if name.hasPrefix("qwen3-asr-flash") { return .dashscopeQwen3 }
        return .dashscopeInputAudio
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

/// 上传音频格式。WAV 兼容性最好，m4a 体积约为 1/20（长录音推荐）。
enum UploadFormat: String, Codable, CaseIterable, Identifiable {
    case wav
    case m4a

    var id: String { rawValue }
    var title: String { self == .wav ? "WAV（兼容性最好）" : "AAC/m4a（体积约 1/20）" }
    var fileExtension: String { self == .wav ? "wav" : "m4a" }
    var mimeType: String { self == .wav ? "audio/x-wav" : "audio/mp4" }
}

/// 后台待命方式。
enum StandbyMode: String, Codable, CaseIterable, Identifiable {
    case off
    case silentAudio
    case pictureInPicture

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "关闭"
        case .silentAudio: "静音输出（无私有 API）"
        case .pictureInPicture: "画中画（实验，含私有 API）"
        }
    }
    var detail: String {
        switch self {
        case .off: "主 App 进入后台后可能被系统挂起，此时键盘会提示打开 App。"
        case .silentAudio: "播放静音尽量保持存活；iOS 仍可能挂起，但不触碰任何私有接口。"
        case .pictureInPicture: "用循环视频占用系统画中画会话换取后台运行时间（Typeless 同款思路）；依赖 AVKit 私有方法，系统升级可能失效，上架审核前请改用其它方式。"
        }
    }
}

struct ASRSettings: Codable, Equatable {
    var kind: ASRKind = .auto
    var endpoint: String = Defaults.dashscopeASREndpoint
    var model: String = Defaults.qwenASRModel
    var language: String = ""
    var customPrompt: String = ""
    var uploadFormat: UploadFormat = .wav
    /// 长录音分段长度（秒）。Typeless 用 3 秒流式分片；我们把批量接口切成 25 秒。
    var chunkSeconds: Double = 25
    /// 边录边识别间隔（秒），0 = 关闭。开启后边说边出字。
    var partialSeconds: Double = 6
    /// 术语是否作为热词提交（input_audio 族的 parameters.vocabulary）。
    var useVocabulary: Bool = true
    /// 手动覆盖 parameters.format；留空按数据 URI 推断（官方同款规则）。
    var formatHintOverride: String = ""
    /// 仅内存 / Keychain，不落 UserDefaults。
    var apiKey: String = ""

    static let `default` = ASRSettings()

    /// 实际使用的协议族。
    var resolvedKind: ASRKind {
        kind == .auto ? ASRKind.resolve(model: model) : kind
    }
}

struct LLMSettings: Codable, Equatable {
    var enabled: Bool = true
    var kind: LLMKind = .openAICompatible
    var endpoint: String = Defaults.deepSeekEndpoint
    var model: String = Defaults.deepSeekModel
    var systemPrompt: String = Defaults.defaultCleanupPrompt
    var temperature: Double = 0.2
    /// 流式返回，边整理边上屏。
    var streaming: Bool = true
    var apiKey: String = ""

    static let `default` = LLMSettings()
}

enum Defaults {
    static let dashscopeASREndpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    static let qwenASRModel = "qwen-audio-3.1-asr-flash"
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
}

/// 设置读写。
/// - 结构化配置走 UserDefaults（版本化 key，避免旧结构反序列化失败）。
/// - API Key 只走 Keychain，绝不出现在配置文件里。
enum SettingsStore {
    private static let asrKey = "settings.v2.asr"
    private static let llmKey = "settings.v2.llm"
    private static let asrAccount = "asr.apiKey"
    private static let llmAccount = "llm.apiKey"

    static func load() -> (asr: ASRSettings, llm: LLMSettings) {
        var asr = decode(ASRSettings.self, key: asrKey) ?? .default
        var llm = decode(LLMSettings.self, key: llmKey) ?? .default
        asr.apiKey = KeychainStore.get(account: asrAccount)
        llm.apiKey = KeychainStore.get(account: llmAccount)
        return (asr, llm)
    }

    static func save(asr: ASRSettings, llm: LLMSettings) {
        // 密钥单独存 Keychain；结构体落盘前清空，避免误写。
        var asrCopy = asr; asrCopy.apiKey = ""
        var llmCopy = llm; llmCopy.apiKey = ""
        encode(asrCopy, key: asrKey)
        encode(llmCopy, key: llmKey)
        KeychainStore.set(asr.apiKey, account: asrAccount)
        KeychainStore.set(llm.apiKey, account: llmAccount)
        KeyboardChannel.publishConfiguration(configured: !asr.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    static var isConfigured: Bool {
        !KeychainStore.get(account: asrAccount).isEmpty
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
