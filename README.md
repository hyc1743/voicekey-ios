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

## 四之四、双通道 ASR（批量 / 实时可选）

App 内「设置 → 语音识别 → 识别通道」可切换，两条路都保留：

| 通道 | 默认模型 | 机制 | 适合 |
|---|---|---|---|
| **批量（默认）** | `qwen-audio-3.1-asr-flash` | 录音→按 10–60 秒分段 HTTP 提交（最多 3 路并发）→ 可选每 4/6/10 秒增量"边录边识别" | 兼容面最广、字段与真机验证过的实现逐字段一致 |
| **实时（可选）** | `qwen3-asr-flash-realtime` | 一条 WebSocket 持续推 PCM16，服务端**边说边出字**，停止后几乎立即出结果 | 想要 Typeless 同款体感 |

**实时通道的协议依据**（逐字段照抄阿里官方 CLI，不自行发明）：
`QwenLM/qwen-code` → `packages/cli/src/ui/voice/qwen-asr-realtime-session.ts`（Apache-2.0）

| 环节 | 字段 |
|---|---|
| 端点 | `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=<model>`，鉴权走 WebSocket 请求头 `Authorization: Bearer` |
| 握手 | 服务端 `session.created` → 客户端发 `session.update`：`{"session":{"input_audio_format":"pcm","sample_rate":16000,"input_audio_transcription":{language?,corpus_text?},"turn_detection":null}}` → 服务端 `session.updated` |
| 上行 | `{"type":"input_audio_buffer.append","audio":"<base64 PCM16>"}`；**在途字节 > 1 MiB 主动丢帧并只警告一次**（同官方） |
| 实时预览 | `conversation.item.input_audio_transcription.text` → `{text, stash}` |
| 成句 | `conversation.item.input_audio_transcription.completed` → `{transcript}` |
| 失败 | `conversation.item.input_audio_transcription.failed` / `error`（读 `error.message`、`error.code`） |
| 收尾 | `input_audio_buffer.commit` + `session.finish` → 等 `session.finished`；连接超时 8 秒、收尾超时 60 秒 |
| 个人术语 | 作为 `input_audio_transcription.corpus_text` 提交（官方支持的通道） |

**兜底设计**：实时连接失败/中途断开/结果为空 → 自动回落到批量通道重新识别**整段本地音频**（录音期间 PCM 一直在本地累积），用户不会丢字；
连接断开会**立即失败**而不是等满 60 秒超时，所以回落几乎无感。

> 默认仍是批量通道：你之前定的模型是 `qwen-audio-3.1-asr-flash`（已验证 payload），实时通道需要换成 `qwen3-asr-flash-realtime`。
> 想体验流式，把通道切到「实时」即可；两条路的 Key 共用。

## 五之一、保活链路（模仿 Typeless）

目标是"用户离开 App 后，键盘点麦克风仍能直接开口，不用切回来"。链路如下，每步都有对应的失败兜底：

```
① 主 App 前台时用户开启「画中画待命」
      └ PiPVisibilityAdapter 绑定 AVKit 平台适配器（失败 → 自动换普通视频，不隐藏）
      └ 启动 96×54 的循环视频（隐藏模式用近黑素材）→ 得到系统画中画会话
② 待命期间**不 deactivate 音频会话**  ← 录音结束也不拆，否则系统会回收画中画
③ 键盘点麦克风：Darwin ping-pong 确认主 App 活着 → emit 命令（有活跃 PiP 时进程不会被挂起）
④ 录音：会话切 .playAndRecord(.default, mixWithOthers) → 画中画视频被停住但不结束
⑤ 录完：**不 deactivate** → resumeIdlePlayback() 切回 .playback + player.play() → 保活继续
⑥ 任何一步失败都会如实上报（诊断页 / 键盘状态药丸），不会静默变成"假待命"
```

### 为什么"跨 App 点麦克风"之前一定失败（v0.1.10 修复）

报错 `The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 2003329396.)` 里的
`2003329396` = FourCC `'what'`，含义是**后台不允许激活录音会话**。iOS 的硬限制是：
App 在后台**不能**把音频会话切到 `.playAndRecord` 并 `setActive(true)`。

我最初只做了「静音输出 / 画中画」两种待命——它们能保住**进程**，但保不住"**能开输入**"。
已验证实现（Voxt-ios）对此的答案是 `microphoneWarm` 模式，且它是**默认值**：

```swift
func arm() throws {                         // 必须在 App 还处于前台时调用
    try session.setCategory(.playAndRecord, mode: .default, options: [...])
    try session.setActive(true)
    engine = AVAudioEngine()                // 类别/路由变化后重建输入图
    input.installTap(onBus: 0, ...)         // 装好 tap → engine.isRunning == true 即 "warm"
    try engine.start()
}
func start(sessionID:chunkSeconds:) throws { try arm()  /* 只是翻采集标志，不再动会话 */ }
```

本项目的对应实现：`AudioRecorder.arm()` 在前台把 `.playAndRecord` 会话与 input tap 准备好，
`startCapture()` 只翻 `isCapturing`；待命方式默认改成 **「麦克风常开」**，并把旧配置一次性迁移过来。
静音/画中画模式保留，但 UI 里如实写明"只保进程、不保后台开麦"。

### 跨 App 两种路径（v0.1.11）

| 路径 | 条件 | 流程 | 体感 |
|---|---|---|---|
| **A 麦克风常开** | 待命方式 =「麦克风常开」且未到期 | 键盘 ping 通 → 直接开录，**完全不切 App** | 最佳 |
| **B 跳转 + 自动返回** | 麦克风未常开（或已到期） | 键盘带 `?return=<宿主bundleID>` 打开 App → App 录音 → 录完用宿主 App 的 URL scheme **自动跳回** → 键盘重新出现时**自动插入** | 有一次切换，但全程无需手动操作 |

路径 B 的依据来自 Typeless：它的 Info.plist 声明了 **50 个 App 的 URL scheme**
（`weixin / lark / notion / slack / telegram / whatsapp / twitter / instagram …`），
键盘也会把 `hostAppBundleId` 传给它——这正是"录完跳回上一个 App"的原料。本项目：
- 键盘用 `extensionContext` 的 `hostBundleIdentifier`（用 `responds/perform` 安全读取，取不到则省略）；
- App 侧维护 `ReturnAppCatalog`（bundle id → scheme，41 条），录完 0.8 秒后 `UIApplication.open` 跳回；
- 查不到的 App 退回**系统自带的"返回 <上一个 App>"状态栏入口**，并且结果已经写进 App Group + 剪贴板，键盘一出现就自动插入。

### 麦克风常开的时长档位

`不限 / 2 小时 / 30 分钟 / 5 分钟 / 10 秒`（默认 **30 分钟**），从**最后一次口述结束**开始计时；
到期自动关闭麦克风并在键盘上提示"需要打开 App"。10 秒档是留给你验证到期行为的。
（Typeless 的同类设置是"音频关闭延迟"：Never / 12 小时 / 5 分钟 / 10 秒。）

### 为什么静音/画中画"起不来"（v0.1.11 修复）

「麦克风常开」会把 `.playAndRecord` 会话握在手里；我原先在切换待命方式时**没有先拆掉它**，
于是静音输出/画中画去配置 `.playback` 会话时直接失败。现在切换任何待命方式前都会
`tearDownStandby()`：停画中画 → 停静音 → 必要时 `recorder.disarm()`，再启动新模式。

**关于"用户应该感知不到"**（这是关键体验指标）：

| | 原版 Typeless | 本项目（0.1.7 起） |
|---|---|---|
| PiP 内容源 | `AVPictureInPictureControllerContentSource` + `AVSampleBufferDisplayLayer`（`initWithContentSource:` / `initWithSampleBufferDisplayLayer:playbackDelegate:` 均在其二进制符号表中） | **同样是 sample-buffer 内容源**（主路线）；另有 `AVPlayerLayer` + 极扁素材作为兜底路线 |
| 帧内容 | 由代理内容类型 / 控件样式 override 决定画什么 | 喂 **2432×2 全透明 BGRA 帧**（1 Hz）；配合 `PiPVisibilityAdapter` 的 content type=6 / proxy style=5，系统可完全不绘制内容面 |
| 用户观感 | 无可见窗口 | 预期同"无可见窗口"；即使系统仍绘制，也只是 2px 高的细线或全透明 |
| 失败降级 | — | sample-buffer 起不来 → 自动回落 `playerLayer` + 2432×2 隐藏素材；再失败才提示不可用 |

> 两条路线共用同一套 AVKit 私有覆盖（`PiPVisibilityAdapter`）。sample-buffer 路线是 Typeless 的真实做法：
> 内容由我们喂的帧决定，因此"不画东西"是可能的；视频路线只能靠极扁素材把窗口压成一条线。

隐藏浮窗的原理（与 Typeless 2.7.0 取证一致）：对 `AVPictureInPicturePlatformAdapter` 做**作用域限定**的私有方法替换——
`pictureInPictureProxyContentType:` 返回 6、`_proxyControlsStyle` 返回 5、并挂钩两个刷新入口
（`_updateProxyPlaybackState` 与 `_updatePlaybackStateContentTypeIfNeeded`）在系统重算内容类型时再次应答，
同时**只观察** `_setStashedOrUnderLock:reason:`（保留系统收起行为，不做小动作）。
所有替换都做签名校验、只动本类实现、可完整回滚；设置里可单独关掉「隐藏画中画浮窗」，关掉后完全不碰私有方法。

**真机验证方法**（这也是我无法替你完成的部分）：
1. App 里选「画中画待命（实验）」，确认出现一个小的画中画窗口（或在系统画中画里看到）；
2. 按 Home 切到微信/备忘录，**等 1–2 分钟**（不要立刻操作）；
3. 切到 VoiceKey 键盘点麦克风：
   - 期望：键盘直接变红录音，没有跳到 App；
   - 若提示「未在后台」→ 说明待命已被系统回收，请把诊断页的待命状态发我；
4. 说完停止，确认文字自动插入，且键盘状态回到「待命、已插入」。

> 未验证/不确定：不同 iOS 版本对 PiP 后台存活时长、以及类别切换时是否保留 PiP 的策略不同；
> 目前只能保证"按已验证实现的字段与调用顺序一致"，实际存活时长必须真机测。

## 五之二、键盘样式

沿用 **Voxt-ios 语音面板**的视觉语言，但不做双拼/拼音输入，也不引入 Rime（本键盘只负责说话与插入）：

- 顶部：`VoiceKey` 字标 + 右侧状态药丸（绿=待命、红=录音、橙=识别、灰=未连接），保留地球键。
- 中部：提示文字 + **200×56 黑色药丸麦克风**（录音时变红并显示停止图标，支持"按住说话"）。
- 实时识别片段：可折叠的圆角条，边录边出字时显示。
- 底部：「插入结果 / 换行 / 删除」——圆–药丸–圆，与参考样式一致。
- 高度 300pt，配色全部跟随系统深浅色。

## 六、限制的现状（逐条对照改进）

| 早期限制 | 现在的做法 | 仍存在的边界 |
|---|---|---|
| 一次传整段音频、长录音慢 | 按 10–60 秒分段提交（默认 25 秒），**最多 3 路并发**，按原顺序拼回 | 段间按标点/空格拼接，个别断句仍可能生硬 |
| 不能边录边出字 | 可选增量识别（默认每 6 秒），键盘同步显示实时片段 | 保留 1.5 秒尾部余量，最后一段略长；会增加请求次数 |
| 静音自动结束不准 | 换成**自适应 dB VAD**（阈值 `clamp(噪声底+10, -32, -18)` dB + 4 dB 迟滞 + 0.25 秒前置语音门槛），默认 **5 秒**，可切 关闭/3/5/10 | 嘈杂环境仍需实测调参 |
| 录音上限 | **分通道**：批量 300 秒（收尾按段跑，太久体验差）／实时 **540 秒**（Typeless 同值），**剩 1 分钟时预警** | 更长的录音需要真正的流式上传 |
| 画中画待命与录音抢音频会话 | 待命期间录音**不 deactivate** 会话，录完 `resumeIdlePlayback()` 恢复画中画（同 Voxt-ios 的 `finishCapture`） | 系统仍可能在类别切换时回收画中画 |
| 边录边识别与收尾抢数据 | 收尾前**等待在途分段**落地；会话结束后的迟到结果按 token 丢弃 | — |
| 来电/Siri 中断后"假录音" | 监听 `AVAudioSession.interruptionNotification`，中断即收尾并如实提示 | 中断结束后不自动续录 |
| WAV 体积大 | 可选 AAC/m4a（约 1/20），失败自动回退 WAV | **没有照抄 Typeless 的 Opus**：它端上编 Opus 因为服务端是自己的；我们直连第三方 API，只能交它认得的容器 |
| 整理要等全部返回 | SSE 流式整理，逐字上屏；**20 秒硬超时**（Typeless 的 `REFINING_TIMEOUT`），超时直接用原始识别结果 | 少数网关不返回 `text/event-stream`，自动退化为一次性解析 |
| API Key 存 UserDefaults | 全部迁 **Keychain**，写入做 0.6 秒防抖 | 键盘与主 App 同 Keychain 访问组理论上可读，但键盘不读密钥 |
| 后台待命只有静音输出 | 三档：关闭 / 静音输出 / **画中画**（私有 API 可单独关掉） | 画中画依赖 AVKit 私有方法，系统升级可能失效；失败会回退并如实提示 |
| 键盘靠心跳新鲜度判活 | **ping-pong（500 ms 超时）** | 极端情况下刚启动就被系统中断，会提示打开 App |
| 键盘重启重复插入 | 结果用掉即删 `result.json` | — |
| 无完全访问提示 | 未开「允许完全访问」时直接给设置路径 | — |
| 局域网端点缺用途说明 | Info.plist 增加 `NSLocalNetworkUsageDescription` | — |
| 键盘打开 App 用私有 selector | 先走官方 `extensionContext.open(_:)`，失败才兜底 | 兜底仍是私有接口，上架前必须删除 |

其余已知项：**iOS 17+**（用到 `AVAudioApplication`、`ContentUnavailableView`）；画中画素材是自产的 2 KB H.264；
`NSAllowsArbitraryLoads` 为支持自建 http 端点而开启，上架前需收紧。

## 七、开发约定

- 全部使用公开 API，除上述键盘兜底选择器外不 hook 系统内部实现。
- 网络请求失败一律**保留原文**（整理失败回退原始识别），不静默丢字。
- 共享通道里所有命令带 `createdAt`，超过 15 秒的过期指令直接丢弃。
- 不提交 `.xcodeproj`（由 XcodeGen 生成），不提交构建产物。

---

## 许可

MIT License，见 [LICENSE](LICENSE)。

> 提示：`VoiceKey/Audio/PiPVisibilityAdapter.m` 与键盘里的 `openViaResponderChain` 使用了系统私有接口，
> 仅适合自签安装与个人研究；上架 App Store 前请按「私有 API 策略」一节产出合规构建。
