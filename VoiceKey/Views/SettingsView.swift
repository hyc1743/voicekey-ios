import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("识别通道", selection: $engine.asr.transport) {
                        ForEach(ASRTransport.allCases) { transport in Text(transport.title).tag(transport) }
                    }
                    Text(engine.asr.transport.detail).font(.caption).foregroundStyle(.secondary)
                    SecureField("API Key（存 Keychain）", text: $engine.asr.apiKey)
                    TextField("语言（可留空自动）", text: $engine.asr.language)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("静音自动结束", selection: $engine.asr.silenceSeconds) {
                        Text("关闭").tag(0.0)
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                        Text("10 秒").tag(10.0)
                    }

                    if engine.asr.transport == .realtime {
                        TextField("实时地址", text: $engine.asr.realtimeEndpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("实时模型", text: $engine.asr.realtimeModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        LabeledContent("协议", value: "百炼 /api-ws/v1/realtime")
                    } else {
                    LabeledContent("实际路由", value: {
                        switch engine.asr.resolvedKind {
                        case .dashscopeNative: return "百炼原生短音频"
                        case .dashscopeCompatibleChat: return "百炼兼容模式 chat"
                        case .openAITranscriptions: return "OpenAI 兼容 multipart"
                        case .auto: return "自动"
                        }
                    }())
                    Picker("接口类型", selection: $engine.asr.kind) {
                        ForEach(ASRKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    Text(engine.asr.kind.hint).font(.caption).foregroundStyle(.secondary)
                    TextField("接口地址", text: $engine.asr.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型", text: $engine.asr.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("识别提示词（可选）", text: $engine.asr.customPrompt, axis: .vertical).lineLimit(2...4)

                    Toggle("附加官方 CLI 增强参数（未验证）", isOn: $engine.asr.useCLIExtras)
                    TextField("format 覆盖（留空自动）", text: $engine.asr.formatHintOverride)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()

                    Picker("上传格式", selection: $engine.asr.uploadFormat) {
                        ForEach(UploadFormat.allCases) { format in Text(format.title).tag(format) }
                    }
                    LabeledContent("长录音分段", value: "\(Int(engine.asr.chunkSeconds)) 秒")
                    Slider(value: $engine.asr.chunkSeconds, in: 10...60, step: 5)
                    Picker("边录边识别", selection: $engine.asr.partialSeconds) {
                        Text("关闭").tag(0.0)
                        Text("每 4 秒").tag(4.0)
                        Text("每 6 秒").tag(6.0)
                        Text("每 10 秒").tag(10.0)
                    }
                    }
                } header: {
                    Text("语音识别 ASR")
                } footer: {
                    Text("批量：qwen-audio-3.1-asr-flash 原生短音频接口（content={type:input_audio,input_audio:{data}} + parameters={format,sample_rate:16000}，带 X-DashScope-SSE: disable），字段与真机验证过的实现逐字段一致；该模型不支持热词，术语交给整理模型。单段 base64 上限 10 MB。\n实时：qwen3-asr-flash-realtime 走 wss://…/api-ws/v1/realtime，协议按官方 CLI 实现（session.update / input_audio_buffer.append / …transcription.text 与 .completed / commit+finish）；实时失败会自动回落批量，音频不会丢。")
                }

                Section {
                    Toggle("启用文字整理", isOn: $engine.llm.enabled)
                    TextField("接口地址", text: $engine.llm.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key（存 Keychain）", text: $engine.llm.apiKey)
                    TextField("模型", text: $engine.llm.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("流式返回（边整理边上屏）", isOn: $engine.llm.streaming)
                    if engine.llm.isDeepSeekEndpoint {
                        Toggle("深度思考模式（官方默认开，整理不需要）", isOn: $engine.llm.thinking)
                        if engine.llm.thinking {
                            Picker("思考强度", selection: $engine.llm.reasoningEffort) {
                                Text("low").tag("low")
                                Text("high").tag("high")
                                Text("max").tag("max")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("温度 \(engine.llm.temperature, specifier: "%.1f")").font(.caption)
                        Slider(value: $engine.llm.temperature, in: 0...1, step: 0.1)
                    }
                    TextField("整理指令", text: $engine.llm.systemPrompt, axis: .vertical).lineLimit(4...10)
                } header: {
                    Text("文字整理 LLM")
                } footer: {
                    Text("默认：DeepSeek deepseek-flash（官方现行模型名）。接口为 https://api.deepseek.com/chat/completions，思考模式默认关闭。\n官方已停用 deepseek-chat / deepseek-reasoner（2026-04-24 公告，2026-07-24 生效）；老配置会被自动改到 deepseek-flash 并在诊断页提示。\n流式开启后整理结果逐字上屏；整理失败或明显跑偏会回退原始识别结果，不会丢字。")
                }

                Section {
                    TextField("每行一个专有名词", text: $engine.personalTerms, axis: .vertical).lineLimit(3...8)
                } header: {
                    Text("个人术语")
                } footer: {
                    Text("术语会随请求一起发给 ASR 与整理模型，用来纠正人名、产品名等。")
                }

                Section {
                    Picker("待命方式", selection: $engine.standbyMode) {
                        ForEach(StandbyMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    if engine.standbyMode == .microphoneWarm {
                        Picker("常开时长", selection: $engine.warmSeconds) {
                            ForEach(Defaults.warmSecondsOptions, id: \.self) { value in
                                Text(Self.warmLabel(value)).tag(value)
                            }
                        }
                    } else if engine.standbyMode == .pictureInPicture {
                        Toggle("隐藏画中画浮窗（私有 API）", isOn: $engine.pipHideWindow)
                    }
                    LabeledContent("当前状态", value: engine.standbyStatus)
                    if engine.standbyMode == .microphoneWarm {
                        LabeledContent("常开剩余", value: engine.warmRemainingText)
                    }
                } header: {
                    Text("跨 App 输入")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine.standbyMode.detail)
                        Text("键盘点麦克风前会先 ping 主 App：活着就直接开录（不切 App），不活着才提示打开 App + 剪贴板兜底。\n关掉“隐藏浮窗”后画中画只做保活，不再触碰任何私有方法。")
                    }
                }

                Section {
                    LabeledContent("App Group", value: SharedStore.resolutionSource)
                    LabeledContent("键盘通道", value: SharedStore.isAvailable ? "共享容器可用" : "仅 Darwin + 剪贴板")
                    LabeledContent("密钥存储", value: "Keychain（不进配置文件）")
                } header: {
                    Text("通道与安全")
                } footer: {
                    Text("免费证书或企业证书可能拿不到 App Group；此时自动降级，功能可用但状态显示更少。")
                }
            }
            .navigationTitle("设置")
        }
    }
}

extension SettingsView {
    static func warmLabel(_ seconds: Double) -> String {
        switch seconds {
        case 0: "不限"
        case 7200: "2 小时"
        case 1800: "30 分钟"
        case 300: "5 分钟"
        default: seconds >= 60 ? "\(Int(seconds / 60)) 分钟" : "\(Int(seconds)) 秒"
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        NavigationStack {
            List {
                Section("键盘 / 待命") {
                    let phase = SharedStore.readPhase()
                    LabeledContent("阶段", value: phase.0.label)
                    LabeledContent("说明", value: phase.1.isEmpty ? "-" : phase.1)
                    LabeledContent("主 App 心跳", value: SharedStore.mainAppIsAlive ? "活跃" : "未检测到")
                    LabeledContent("键盘上次检测", value: KeyboardChannel.lastPingDescription)
                    LabeledContent("待命可后台开录", value: KeyboardChannel.standbySupportsBackgroundCapture ? "是" : "否")
                    LabeledContent("待命", value: engine.standbyStatus)
                }
                Section("实时识别片段") {
                    Text(engine.liveText.isEmpty ? "（暂无）" : engine.liveText)
                        .textSelection(.enabled).font(.footnote)
                }
                Section("原始识别") {
                    Text(engine.lastRaw.isEmpty ? "还没有识别记录" : engine.lastRaw)
                        .textSelection(.enabled).font(.footnote)
                }
                Section("最近请求 / 响应") {
                    Text(engine.diagnostics.isEmpty ? "运行一次后这里会显示接口往返信息（API Key 不显示）。" : engine.diagnostics)
                        .textSelection(.enabled).font(.footnote.monospaced())
                }
            }
            .navigationTitle("诊断")
        }
    }
}
