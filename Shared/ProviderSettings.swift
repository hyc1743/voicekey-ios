import Foundation

/// ASR 协议族。默认按模型名自动判定，规则与百炼官方 CLI 的 asr-routes.ts 一致：
/// `fun-asr-flash*` 与 `qwen-audio*-asr-flash` 走 input_audio 族；
/// `qwen3-asr-flash` 走 content.audio + asr_options 族。
enum ASRKind: String, Codable, CaseIterable, Identifiable {
    case auto
    case dashscopeNative
    case dashscopeCompatibleChat
    case openAITranscriptions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动（按模型名路由）"
        case .dashscopeNative: "百炼原生短音频（qwen-audio-3.x-asr-flash）"
        case .dashscopeCompatibleChat: "百炼兼容模式 chat（qwen3-asr-flash）"
        case .openAITranscriptions: "OpenAI 兼容 /audio/transcriptions"
        }
    }
    var hint: String {
        switch self {
        case .auto: "推荐。qwen-audio-* / fun-asr-flash* 走原生接口，qwen3-asr-flash* 走兼容模式。"
        case .dashscopeNative: "POST /api/v1/services/aigc/multimodal-generation/generation，content 用 {type:input_audio}，参数 format + sample_rate。"
        case .dashscopeCompatibleChat: "POST /compatible-mode/v1/chat/completions，content 用 input_audio；该路由支持术语提示。"
        case .openAITranscriptions: "multipart 上传，适用于 Whisper、GLM、SenseVoice 等兼容服务。"
        }
    }

    /// 路由规则与百炼官方 CLI 的 resolveAsrApi 一致：
    /// `fun-asr-flash*`、`qwen-audio*asr-flash` → 原生短音频接口；
    /// `qwen3-asr-flash*` → 兼容模式 chat/completions。
    static func resolve(model: String) -> ASRKind {
        let name = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("qwen3-asr-flash") { return .dashscopeCompatibleChat }
        if name.hasPrefix("fun-asr-flash") { return .dashscopeNative }
        if name.hasPrefix("qwen-audio") { return .dashscopeNative }
        return .dashscopeNative
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

/// 识别通道：批量 HTTP（按段提交）或实时 WebSocket（流式）。
enum ASRTransport: String, Codable, CaseIterable, Identifiable {
    case batch
    case realtime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .batch: "批量（HTTP 分段）"
        case .realtime: "实时（WebSocket 流式）"
        }
    }
    var detail: String {
        switch self {
        case .batch: "按 10–60 秒分段提交，可选边录边识别。兼容面最广，任何 OpenAI/百炼批量接口都能用。"
        case .realtime: "一条 WebSocket 长连接持续推 PCM，服务端边说边出字，停止后几乎立即拿到结果（Typeless 同款机制）。目前适配百炼 qwen3-asr-flash-realtime；失败会自动回落到批量通道。"
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
    var mimeType: String { self == .wav ? "audio/wav" : "audio/mp4" }
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
    var transport: ASRTransport = .batch
    /// 实时通道参数（transport == .realtime 时使用）。
    var realtimeEndpoint: String = Defaults.realtimeEndpoint
    var realtimeModel: String = Defaults.realtimeModel
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
    /// 是否附加官方 CLI 里的增强参数（language_hints / vocabulary）。
    /// 默认关闭：已验证实现从不发送这些字段，实测报错时保持关闭即可。
    var useCLIExtras: Bool = false
    /// 手动覆盖 parameters.format；留空按数据 URI 推断（官方同款规则）。
    var formatHintOverride: String = ""
    /// 仅内存 / Keychain，不落 UserDefaults。
    var apiKey: String = ""

    static let `default` = ASRSettings()

    /// 实时通道是否可用（需要端点、模型、Key 齐全）。
    var realtimeConfigured: Bool {
        !realtimeEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !realtimeModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
    /// DeepSeek 思考模式（官方默认开启）。整理任务不需要思维链，默认关闭。
    var thinking: Bool = false
    /// 思考强度：low / high / max（仅在思考模式开启时发送）。
    var reasoningEffort: String = "low"
    var apiKey: String = ""

    /// 是否是 DeepSeek 官方端点：只有它认识 thinking / reasoning_effort 这些扩展字段，
    /// 别的 OpenAI 兼容网关收到未知字段可能直接报错。
    var isDeepSeekEndpoint: Bool {
        endpoint.lowercased().contains("api.deepseek.com") || model.lowercased().hasPrefix("deepseek")
    }

    static let `default` = LLMSettings()
}

enum Defaults {
    static let dashscopeASREndpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    static let qwenASRModel = "qwen-audio-3.1-asr-flash"
    static let realtimeEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    static let realtimeModel = "qwen3-asr-flash-realtime"
    static let deepSeekEndpoint = "https://api.deepseek.com/chat/completions"
    static let deepSeekModel = "deepseek-flash"

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

    /// 最近一次因官方变更而自动修正的项，供诊断页显示。
    private(set) static var migrationNotes: [String] = []

    static func load() -> (asr: ASRSettings, llm: LLMSettings) {
        var asr = decode(ASRSettings.self, key: asrKey) ?? .default
        var llm = decode(LLMSettings.self, key: llmKey) ?? .default
        var notes: [String] = []
        // 2026-04-24 官方公告：deepseek-chat / deepseek-reasoner 已于 2026-07-24 停用，
        // 现行模型名为 deepseek-flash（推荐）或 deepseek-v4-pro。
        if llm.endpoint.lowercased().contains("api.deepseek.com") {
            let legacy: Set<String> = ["deepseek-chat", "deepseek-reasoner"]
            if legacy.contains(llm.model.lowercased()) {
                notes.append("整理模型 \(llm.model) 已由官方停用，已自动改为 \(Defaults.deepSeekModel)")
                llm.model = Defaults.deepSeekModel
            }
            if llm.endpoint.contains("/v1/chat/completions") {
                notes.append("整理接口已从 /v1/chat/completions 改为官方文档写的 /chat/completions")
                llm.endpoint = Defaults.deepSeekEndpoint
            }
        }
        asr.apiKey = KeychainStore.get(account: asrAccount)
        llm.apiKey = KeychainStore.get(account: llmAccount)
        migrationNotes = notes
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
