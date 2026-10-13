import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("接口类型", selection: $engine.asr.kind) {
                        ForEach(ASRKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    Text(engine.asr.kind.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("接口地址", text: $engine.asr.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $engine.asr.apiKey)
                    TextField("模型", text: $engine.asr.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("语言（可留空自动）", text: $engine.asr.language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("识别提示词（可选）", text: $engine.asr.customPrompt, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("语音识别 ASR")
                } footer: {
                    Text("默认：阿里云百炼 qwen-audio-3.1-asr-flash，音频以 Base64 WAV 直传。若换成 OpenAI 兼容服务，请把接口地址改为对应的 /audio/transcriptions。")
                }

                Section {
                    Toggle("启用文字整理", isOn: $engine.llm.enabled)
                    TextField("接口地址", text: $engine.llm.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $engine.llm.apiKey)
                    TextField("模型", text: $engine.llm.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    VStack(alignment: .leading) {
                        Text("温度 \(engine.llm.temperature, specifier: "%.1f")")
                            .font(.caption)
                        Slider(value: $engine.llm.temperature, in: 0...1, step: 0.1)
                    }
                    TextField("整理指令", text: $engine.llm.systemPrompt, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("文字整理 LLM")
                } footer: {
                    Text("默认：DeepSeek deepseek-chat（OpenAI 兼容）。整理失败时会自动回退到原始识别结果，不会丢字。")
                }

                Section {
                    TextField("每行一个专有名词", text: $engine.personalTerms, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("个人术语")
                } footer: {
                    Text("术语会随请求一起发给 ASR 与整理模型，用来纠正人名、产品名等。")
                }

                Section {
                    Toggle("后台待命（实验）", isOn: $engine.standbyEnabled)
                } header: {
                    Text("跨 App 输入")
                } footer: {
                    Text("开启后，App 退到后台时会播放静音以尽量保持存活，这样键盘点麦克风就不必跳到前台。iOS 仍可能随时挂起；不保证 100% 生效，也不会自动改成持续开麦。")
                }

                Section {
                    LabeledContent("App Group", value: SharedStore.resolutionSource)
                    LabeledContent("键盘通道", value: SharedStore.isAvailable ? "共享容器可用" : "仅 Darwin + 剪贴板")
                } header: {
                    Text("键盘通道")
                } footer: {
                    Text("免费证书或企业证书可能拿不到 App Group，此时自动降级为 Darwin 通知 + 剪贴板，仍可用但状态显示更少。")
                }
            }
            .navigationTitle("设置")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        NavigationStack {
            List {
                Section("键盘状态") {
                    let phase = SharedStore.readPhase()
                    LabeledContent("阶段", value: phase.0.label)
                    LabeledContent("说明", value: phase.1.isEmpty ? "-" : phase.1)
                    LabeledContent("主 App 心跳", value: SharedStore.mainAppIsAlive ? "活跃" : "未检测到")
                }
                Section("原始识别") {
                    Text(engine.lastRaw.isEmpty ? "还没有识别记录" : engine.lastRaw)
                        .textSelection(.enabled)
                        .font(.footnote)
                }
                Section("最近请求 / 响应") {
                    Text(engine.diagnostics.isEmpty ? "运行一次后这里会显示接口往返信息（API Key 不显示）。" : engine.diagnostics)
                        .textSelection(.enabled)
                        .font(.footnote.monospaced())
                }
            }
            .navigationTitle("诊断")
        }
    }
}
