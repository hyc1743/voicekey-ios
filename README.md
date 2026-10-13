# VOXT（VoiceKey）

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

安装后启用键盘：**设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → VOXT**，并在键盘详情里打开「允许完全访问」（不打开无法与主 App 通信）。

---

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

1. **后台待命不保证**：开启后 App 退到后台会播放静音（`.playback` + `mixWithOthers`）以尽量存活，但 iOS 仍可能随时挂起。挂起时键盘会提示「VOXT 未在后台运行」并退回「打开 VOXT」路径。没有使用画中画等私有 API 手段。
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
