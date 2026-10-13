# VoiceKey（VoiceKey）

一个可自定义云端 ASR / LLM 的 iOS 语音输入 App：**主 App 录音 + 键盘扩展上屏**。
默认适配 **阿里云百炼 `qwen-audio-3.1-asr-flash`**（识别）与 **DeepSeek**（整理），两者都可换成任意兼容服务。

> 不是 Typeless 的复刻代码，而是一次独立实现：分析结论见 `docs/`（若存在），实现只用公开 API。

---

## 一、它能做什么

| 能力 | 说明 |
|---|---|
| App 内说话 | 点大按钮开始，静音 2 秒自动结束（可关），结果自动复制到剪贴板 |
| 键盘内说话 | 键盘上的麦克风按钮触发主 App 录音，整理好后**自动插入当前输入框** |
| 云端识别 | 默认 `qwen-audio-3.1-asr-flash`（DashScope 原生多模态接口，Base64 WAV 直传）；也可切到任意 `/audio/transcriptions` 兼容服务（Whisper / GLM / SenseVoice…） |
| 文字整理 | 默认 DeepSeek `deepseek-chat`（OpenAI 兼容 `/chat/completions`）；Prompt、温度、模型都可改；整理失败自动回退原始识别结果 |
| 个人术语 | 每行一个专有名词，随请求发给 ASR 与整理模型 |
| 历史 | 本地保存最近 500 条，含原始识别与最终文本 |
| 诊断 | 展示最近一次接口往返（HTTP 状态码、返回体前 600 字节，API Key 不显示） |

---

## 二、架构

```
┌──────────────────────────┐        App Group / Darwin        ┌───────────────────────────┐
│  VoiceKeyKeyboard.appex  │  request.json / result.json      │  VoiceKey.app             │
│  只做 UI + 发指令 + 插入   │ ───────────────────────────────▶ │  AVAudioEngine 采集 16k    │
│  （iOS 不允许键盘录音）    │ ◀─────────────────────────────── │  → 云端 ASR → 云端整理     │
└──────────────────────────┘        event 通知 + 剪贴板兜底     └───────────────────────────┘
                                                                          │
                                                       https://dashscope.aliyuncs.com/...
                                                       https://api.deepseek.com/v1/chat/completions
```

- **键盘不录音**：键盘扩展没有麦克风权限，录音一律在主 App 完成。
- **键盘只是遥控器**：写入 `request.json` → Darwin 通知唤醒主 App → 主 App 更新状态 → 键盘轮询 `result.json` 并 `textDocumentProxy.insertText`。
- **没有 App Group 也能用**：自动降级为 Darwin 信号 + 剪贴板（键盘上会多一个「插入结果」按钮）。免费开发者证书就拿不到 App Group。
- **不使用私有 API 提交识别逻辑**：唯一例外是键盘兜底打开宿主 App 时会尝试 `openURL:options:completionHandler:`（先走 `extensionContext.open`），见「已知限制」。

文件清单（约 1300 行 Swift）：

```
Shared/SharedStore.swift        App Group 解析、原子文件读写、Darwin 通知、状态与协议结构
Shared/ProviderSettings.swift    ASR/LLM 配置模型与持久化
VoiceKey/Audio/AudioRecorder.swift   AVAudioEngine + AVAudioConverter → 16 kHz 单声道 PCM16 WAV
VoiceKey/Audio/StandbyKeeper.swift   实验性后台待命（静音输出）
VoiceKey/Net/ASRClient.swift     DashScope 原生接口 + OpenAI 兼容 multipart
VoiceKey/Net/LLMClient.swift     OpenAI 兼容 /chat/completions，带输出清洗与回退
VoiceKey/Dictation/DictationEngine.swift  状态机：录音→识别→整理→落库/上屏
VoiceKey/Dictation/HistoryStore.swift     历史落盘
VoiceKey/Views/*.swift           SwiftUI 四个页签
VoiceKeyKeyboard/KeyboardViewController.swift  键盘 UI 与共享通道
```

---

## 三、云端构建（推荐）

推送到 `main` 即触发 `.github/workflows/ios-ipa.yml`（macOS runner，约 2–4 分钟）：

1. **类型检查闸门**：`swiftc -typecheck` 先跑一遍，语法/类型错误几十秒内暴露，不浪费后面的完整构建。
2. `xcodegen generate` 生成 Xcode 工程（仓库里没有 `.xcodeproj`）。
3. `xcodebuild build`（Release、`CODE_SIGNING_ALLOWED=NO`）。
4. 打包 **unsigned IPA** 并校验关键 plist 字段（Bundle ID、后台模式、URL Scheme、键盘扩展标识与 Full Access）。
5. 产物：`VoiceKey-unsigned-ipa` → `VoiceKey-unsigned.ipa` + `SHA256SUMS.txt`。

本机构建（需要 Xcode 16+）：

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open VoiceKey.xcodeproj      # 选择自己的 Team 后真机运行
```

---

## 四、安装与签名

CI 产出的是**未签名 IPA**，需要自己重签后安装：

- **AltStore / Sideloadly / ESign**：用你的 Apple ID 重签 `VoiceKey-unsigned.ipa`。
- 免费 Apple ID：**拿不到 App Group**，键盘通道自动降级为 Darwin + 剪贴板（功能可用，状态显示更少）。
- 付费开发者账号：在 `VoiceKey/VoiceKey.entitlements` 与 `VoiceKeyKeyboard/VoiceKeyKeyboard.entitlements` 里把 `group.dev.hyc.voicekey` 换成你自己 Team 下的 App Group ID（两处必须一致），重签时带上该 entitlement。

安装后启用键盘：**设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → VoiceKey**，并在键盘详情里打开「允许完全访问」（不打开无法与主 App 通信）。

---

## 四之二、ASR 协议依据（逐字段对齐已真机验证的实现）

百炼部分不是"照文档猜的"，而是**逐字段对齐 `Voxt-ios` 里已被真机验证、并被单测锁定的实现**
（`RemoteClients.aliyunASRPayload` + `VoxtIOSTests.testQwenAudio31UsesNativeDashScopeSchema`
+ `PersonalizationTests.testProviderCapabilitiesNeverInventUnknownHotwordParameters`），
路由规则同时与百炼官方 CLI `modelstudioai/cli` 的 `asr-routes.ts` 一致。

| 项 | 取值 | 依据 |
|---|---|---|
| 路由 | `qwen-audio-*` / `fun-asr-flash*` → 原生短音频；`qwen3-asr-flash*` → 兼容模式 chat | 官方 CLI `resolveAsrApi` + 已验证实现 |
| 原生端点 | `POST /api/v1/services/aigc/multimodal-generation/generation` | 单测断言 `request.url?.path` |
| 原生 body | `{model, input:{messages:[{role:"user",content:[{type:"input_audio",input_audio:{data:"data:audio/wav;base64,…"}}]}]}, parameters:{format:"wav", sample_rate:16000}}` | 单测逐字段断言（**`sample_rate` 是整数**，`format` 是字符串） |
| 原生消息条数 | **恒为 1**，不发 `input_text` 上下文消息 | `PersonalizationTests` 断言 `messages.count == 1` |
| 热词 | 该模型**不发**热词字段；术语改由整理模型提示词承担 | 单测 `neverInventUnknownHotwordParameters` |
| 请求头 | `Authorization: Bearer …` + `X-DashScope-SSE: disable` | 单测断言 |
| 兼容模式 | `POST /compatible-mode/v1/chat/completions`，`{model, stream:false, messages:[…input_audio…]}`，可用 system 消息带术语 | 已验证实现 + 其单测 |
| 取文 | 原生：`output.text` → `output.sentence(.text)` → `output.choices`；兼容：`choices[].message.content` | 已验证实现 |
| 端点归一化 | 用户误填兼容模式地址或只填到 `/api/v1` 时自动改写 | 已验证实现的 `aliyunASRURL` |
| 大小上限 | base64 < 10 MB | 已验证实现的硬检查（也是本项目长录音分段的依据） |

设置页里的「附加官方 CLI 增强参数」是**默认关闭**的实验项：官方 CLI 会发 `language_hints`/`vocabulary`，
但已验证实现从不发送这些字段，所以默认不跟着发，报错时保持关闭即可。

> 教训：早期版本我用 `qwen3` 族的 body（`content:[{audio}]`）+ 字符串 `sample_rate` + 自创的
> `parameters.vocabulary` 去调 `qwen-audio-3.1-asr-flash`，三处都不对——现已按上述依据纠正。

## 四之三、DeepSeek 协议依据（官方文档实测）

文本整理默认接 DeepSeek，字段与端点取自**官方文档站**（`api-docs.deepseek.com`，可直接抓取）：

| 项 | 官方内容 | 本项目 |
|---|---|---|
| 端点 | `POST https://api.deepseek.com/chat/completions`（官方 curl 示例；文档已不再出现 `/v1`） | `Defaults.deepSeekEndpoint`，老配置里的 `/v1/chat/completions` 会自动改写 |
| 模型 | `deepseek-flash`（推荐）/ `deepseek-v4-pro`；旧 `deepseek-v4-flash*` 仅临时兼容 | `Defaults.deepSeekModel = deepseek-flash` |
| **`deepseek-chat` / `deepseek-reasoner`** | **2026-04-24 公告：将于 2026-07-24 停用**（当时指向 v4-flash 的非思考/思考模式） | 老配置启动时**自动迁移**到 `deepseek-flash`，并在诊断页提示 |
| 思考模式 | 默认开启；`{"thinking":{"type":"enabled|disabled"}}`，强度 `{"reasoning_effort":"low|high|max"}` | 整理任务默认**关闭**（省时省钱、输出直接）；设置里可开 |
| 思维链 | 思考模式下 `reasoning_content` 与 `content` 同级返回 | 只取 `content`；若只拿到思维链则报错并提示关闭思考模式 |
| `temperature` | 0–2，默认 1 | 默认 0.2（更确定），可调 |
| `top_p` | **仅思考模式生效**，有效范围 0.95–1.0；非思考模式固定 1.0 且忽略传入值 | 不发送 |
| 流式 | data-only SSE，以 `data: [DONE]` 结束 | `streamChat` 按此解析 |
| 扩展字段兼容性 | `thinking`/`reasoning_effort` 是 DeepSeek 专有 | 只在端点/模型是 DeepSeek 时才发送，避免其它 OpenAI 兼容网关报未知字段 |

> 另外核对过官方 changelog：2026-07-31 V4-Flash 公测、2026-08-13 V4-Pro GA、2026-09-10 V4.1-Flash 发布
> （"change the model name to `deepseek-flash`"）。所以本项目 v0.1.x 里的 `deepseek-chat` 默认值**早已失效**，已修正。

## 五、配置云端服务

### 语音识别：阿里云百炼（默认）
1. 百炼控制台创建 API Key（`sk-...`）。
2. 设置页 → 语音识别：接口地址保持默认
   `https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
3. 模型：`qwen-audio-3.1-asr-flash`；API Key 填入。

> 想换成 OpenAI 兼容服务：接口类型改为「OpenAI 兼容 /audio/transcriptions」，地址填 `<base>/audio/transcriptions`，模型填 `whisper-1` 之类即可。

### 文字整理：DeepSeek（默认）
1. DeepSeek 开放平台创建 Key。
2. 设置页 → 文字整理：地址 `https://api.deepseek.com/v1/chat/completions`，模型 `deepseek-chat`。

> 任何 OpenAI 兼容服务（Kimi、通义、Ollama、LM Studio、OpenRouter…）只需改地址与模型。局域网服务记得填 `http://192.168.x.x:端口/...`（已允许非 HTTPS）。

**诊断页**会显示最近一次请求的实际地址、HTTP 状态码与返回体片段——接口报错时先看这里。

---

## 六、已知限制（如实说明）

1. **后台待命不保证**：开启后 App 退到后台会播放静音（`.playback` + `mixWithOthers`）以尽量存活，但 iOS 仍可能随时挂起。挂起时键盘会提示「VoiceKey 未在后台运行」并退回「打开 VoiceKey」路径。没有使用画中画等私有 API 手段。
2. **键盘兜底打开主 App 用了私有 selector**：先调用官方的 `extensionContext.open(_:)`，失败才尝试响应链上的 `openURL:options:completionHandler:`。上架审核前请移除这段。
3. **API Key 存在 App Group UserDefaults**：同一 App Group 内的键盘扩展理论上可读；当前键盘代码不读密钥。要更严谨可迁移到 Keychain。
4. **未做流式识别**：一次请求上传整段 WAV（≤3 分钟）。长录音会明显变慢，后续可改为分片上传 / SSE。
5. **没有做 Opus 编码**：直接传 WAV，体积是 Typeless（16 kbps Opus）的十几倍，弱网体验会差一些。
6. **iOS 17+**：使用了 `AVAudioApplication`、`ContentUnavailableView` 等新 API。

---

## 七、开发约定

- 全部使用公开 API，除上述键盘兜底选择器外不 hook 系统内部实现。
- 网络请求失败一律**保留原文**（整理失败回退原始识别），不静默丢字。
- 共享通道里所有命令带 `createdAt`，超过 15 秒的过期指令直接丢弃。
- 不提交 `.xcodeproj`（由 XcodeGen 生成），不提交构建产物。
