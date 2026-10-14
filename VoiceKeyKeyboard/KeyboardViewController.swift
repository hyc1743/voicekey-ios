import UIKit

/// 键盘扩展：只做三件事——判断主 App 是否真的活着、发指令让它录音、把结果插进宿主输入框。
///
/// 样式参考 Voxt-ios 的语音面板：顶部字标 + 状态药丸、居中黑色大药丸麦克风、
/// 底部「圆–药丸–圆」。不做双拼/拼音输入，也不需要 Rime。
/// 保留地球键（Apple 要求 needsInputModeSwitchKey 时提供，否则用户可能无法切回其它键盘）。
final class KeyboardViewController: UIInputViewController {

    // MARK: - 文案

    private enum Copy {
        // 状态药丸（短标签，2–3 字）
        static let ready = "就绪"
        static let listening = "聆听"
        static let writing = "成文"
        static let done = "完成"
        static let failed = "异常"
        static let offline = "离线"
        static let asleep = "待唤醒"
        static let limited = "受限"
        static let jumping = "跳转"
        static let hint = "提示"

        // 主文案
        static let idle = "轻点麦克风，说完即成文"
        static let listeningStatus = "聆听中"
        static let writingStatus = "正在成文"
        static let readyStatus = "文本已就绪"
        static let openingStatus = "正在唤起 VoiceKey"
        static let failedStatus = "未能完成"
        static let notReadyStatus = "VoiceKey 未在后台"
        static let offlineStatus = "尚未连接主 App"
        static let noAccessStatus = "需要「允许完全访问」"
        static let nothingStatus = "没有可写入的内容"
        static let timeoutStatus = "未收到结果"

        // 副文案
        static let idleHint = "静音 5 秒自动成文"
        static let listeningHint = "轻点结束 · 或静音自动结束"
        static let openingHint = "录完自动跳回，回来即写入"
        static let accessHint = "设置 › 通用 › 键盘 › VoiceKey"
        static let offlineHint = "打开 App 完成一次设置即可"
        static let asleepHint = "轻点麦克风会跳转 App，录完自动返回"
        static let timeoutHint = "请确认 App 已打开并配置好 API Key"
        static func inserted(_ count: Int) -> String { "已写入 \(count) 字" }
    }

    // MARK: - 调色板（跟随系统深浅色）

    private enum Palette {
        static let background = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.11, alpha: 1)
                : UIColor(red: 0.90, green: 0.90, blue: 0.91, alpha: 1)
        }
        static let primaryFill = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : .black
        }
        static let primaryGlyph = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }
        static let secondaryFill = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : .white
        }
        static let recordFill = UIColor.systemRed
    }

    // MARK: - 视图

    private let stateDot = UIView()
    private let stateLabel = UILabel()
    private let statePill = UIView()
    private let globeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let liveContainer = UIView()
    private let liveLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    // MARK: - 状态

    private var observer: AnyObject?
    private var pollTimer: Timer?
    private var pollStartedAt: Date?
    private var lastInsertedSession = ""
    private var activeSession = ""
    private var didOpenContainingApp = false
    private var isRecording = false
    private var longPressActive = false
    private var pingTimer: Timer?
    private var pendingPingID: String?
    private var pingStartedAt: Date?
    private var pingDeadline: Date?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        observer = SharedStore.observe(SharedStore.eventNotification) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didOpenContainingApp = false
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 键盘消失时若还在录音，主动停止，避免麦克风一直开着。
        if isRecording, !activeSession.isEmpty { send(source: "stop") }
        stopPolling()
        stopPing()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        refresh()
    }

    // MARK: - 布局

    private func buildUI() {
        view.backgroundColor = Palette.background

        // 顶部：字标 + 地球键 + 状态药丸
        let wordmark = UILabel()
        wordmark.text = "VoiceKey"
        wordmark.font = .systemFont(ofSize: 18, weight: .bold)
        wordmark.setContentHuggingPriority(.required, for: .horizontal)

        stateDot.layer.cornerRadius = 4
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        stateDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .secondaryLabel

        let pillStack = UIStackView(arrangedSubviews: [stateDot, stateLabel])
        pillStack.axis = .horizontal
        pillStack.spacing = 6
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        statePill.backgroundColor = Palette.secondaryFill
        statePill.layer.cornerRadius = 15
        statePill.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: 12),
            pillStack.trailingAnchor.constraint(equalTo: statePill.trailingAnchor, constant: -12),
            pillStack.centerYAnchor.constraint(equalTo: statePill.centerYAnchor),
            statePill.heightAnchor.constraint(equalToConstant: 30)
        ])

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            globeButton.widthAnchor.constraint(equalToConstant: 30),
            globeButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        let topSpacer = UIView()
        let topBar = UIStackView(arrangedSubviews: [wordmark, topSpacer, globeButton, statePill])
        topBar.axis = .horizontal
        topBar.spacing = 8
        topBar.alignment = .center

        // 中间：状态文字 + 黑色大药丸
        statusLabel.font = .systemFont(ofSize: 15, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [statusLabel, hintLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.tintColor = Palette.primaryGlyph
        micButton.backgroundColor = Palette.primaryFill
        micButton.layer.cornerRadius = 28
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            micButton.heightAnchor.constraint(equalToConstant: 56),
            micButton.widthAnchor.constraint(equalToConstant: 200)
        ])
        let micRow = UIStackView(arrangedSubviews: [micButton])
        micRow.axis = .horizontal
        micRow.alignment = .center
        micRow.distribution = .equalCentering

        // 长按说话：按下开始，松手结束。
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(micLongPressed(_:)))
        longPress.minimumPressDuration = 0.28
        micButton.addGestureRecognizer(longPress)

        // 实时识别片段
        liveLabel.font = .systemFont(ofSize: 13)
        liveLabel.numberOfLines = 2
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveContainer.backgroundColor = Palette.secondaryFill
        liveContainer.layer.cornerRadius = 12
        liveContainer.addSubview(liveLabel)
        NSLayoutConstraint.activate([
            liveLabel.leadingAnchor.constraint(equalTo: liveContainer.leadingAnchor, constant: 10),
            liveLabel.trailingAnchor.constraint(equalTo: liveContainer.trailingAnchor, constant: -10),
            liveLabel.topAnchor.constraint(equalTo: liveContainer.topAnchor, constant: 8),
            liveLabel.bottomAnchor.constraint(equalTo: liveContainer.bottomAnchor, constant: -8)
        ])
        liveContainer.isHidden = true

        // 底部：圆 – 药丸 – 圆
        styleCircle(insertButton, systemName: "square.and.pencil", action: #selector(insertTapped))
        styleCircle(deleteButton, systemName: "delete.left", action: #selector(deleteTapped))
        returnButton.setTitle("换行", for: .normal)
        returnButton.setTitleColor(.label, for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 16)
        returnButton.backgroundColor = Palette.secondaryFill
        returnButton.layer.cornerRadius = 16
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let returnHolder = UIStackView(arrangedSubviews: [returnButton])
        returnHolder.axis = .horizontal
        returnHolder.distribution = .fillEqually

        let bottomRow = UIStackView(arrangedSubviews: [insertButton, returnHolder, deleteButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topBar, textStack, micRow, liveContainer, bottomRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            view.heightAnchor.constraint(equalToConstant: 300)
        ])
    }

    private func styleCircle(_ button: UIButton, systemName: String, action: Selector) {
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
        button.backgroundColor = Palette.secondaryFill
        button.layer.cornerRadius = 24
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    // MARK: - 动作

    @objc private func micTapped() {
        // 长按手势已经开始时不再处理点击，否则"按久一点"会变成开始后立刻结束。
        guard !longPressActive else { return }
        if isRecording { stopRecording(); return }
        beginAttempt()
    }

    @objc private func micLongPressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            longPressActive = true
            if !isRecording && pingTimer == nil { beginAttempt() }
        case .ended, .cancelled, .failed:
            longPressActive = false
            if isRecording { stopRecording() }
        default:
            break
        }
    }

    private func beginAttempt() {
        guard !isRecording, pingTimer == nil else { return }
        guard hasFullAccess else {
            setState(Copy.limited, color: .systemRed, status: Copy.noAccessStatus, hint: Copy.accessHint)
            return
        }
        guard SharedStore.isAvailable else {
            promptOpenApp(reason: "当前签名没有 App Group。")
            return
        }
        // 待命明确说明"支持后台开录"且心跳新鲜时直接开录，省掉一次往返。
        if KeyboardChannel.standbySupportsBackgroundCapture, SharedStore.mainAppIsAlive {
            startViaSharedChannel()
            return
        }
        startPing()
    }

    /// 异步 ping：**绝不阻塞键盘主线程**。
    /// 旧实现用 Thread.sleep 在主线程轮询 0.5 秒，键盘会被系统判为无响应并切回其它键盘。
    private func startPing() {
        let request = DictationRequest(source: "ping")
        pendingPingID = request.id
        pingStartedAt = Date()
        pingDeadline = Date().addingTimeInterval(1.0)
        SharedStore.write(request, name: "request.json")
        SharedStore.post(SharedStore.commandNotification)
        setState(Copy.listening, color: .systemOrange, status: "正在确认连接", hint: "")
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollPing()
        }
    }

    private func pollPing() {
        guard let id = pendingPingID, let started = pingStartedAt, let deadline = pingDeadline else {
            stopPing()
            return
        }
        if SharedStore.read(DictationReply.self, name: "reply-\(id).json") != nil {
            KeyboardChannel.recordPing(ok: true, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            stopPing()
            startViaSharedChannel()
            return
        }
        guard Date() >= deadline else { return }
        KeyboardChannel.recordPing(ok: false, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        stopPing()
        // 次级判据：心跳仍新鲜且待命支持后台开录时再赌一次，避免不必要的跳转
        // （跳转会让系统重置输入法，回来后要手动切回 VoiceKey）。
        if SharedStore.mainAppIsAlive, KeyboardChannel.standbySupportsBackgroundCapture {
            startViaSharedChannel()
        } else {
            promptOpenApp(reason: "麦克风常开未就绪。")
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
        pendingPingID = nil
        pingStartedAt = nil
        pingDeadline = nil
    }


    private func startViaSharedChannel() {
        let request = DictationRequest(source: "start")
        activeSession = request.sessionID
        SharedStore.write(request, name: "request.json")
        SharedStore.remove(name: "result.json")
        SharedStore.post(SharedStore.commandNotification)
        isRecording = true
        setState(Copy.listening, color: .systemRed, status: Copy.listeningStatus, hint: Copy.listeningHint)
        applyMicAppearance(recording: true)
        startPolling()
    }

    private func send(source: String) {
        SharedStore.write(DictationRequest(source: source), name: "request.json")
        SharedStore.post(SharedStore.commandNotification)
    }

    private func startPolling() {
        pollStartedAt = Date()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollStartedAt = nil
    }

    private func insert(_ text: String, session: String) {
        textDocumentProxy.insertText(text)
        lastInsertedSession = session
        // 用掉就删：键盘进程重启后不会重复插入同一条结果。
        SharedStore.remove(name: "result.json")
        isRecording = false
        activeSession = ""
        applyMicAppearance(recording: false)
        liveContainer.isHidden = true
        stopPolling()
        setState(Copy.done, color: .systemGreen, status: Copy.inserted(text.count), hint: "")
    }

    private func refresh() {
        if let result = SharedStore.read(ResultPayload.self, name: "result.json"),
           result.sessionID != lastInsertedSession,
           Date().timeIntervalSince1970 - result.createdAt < 300 {
            insert(result.text, session: result.sessionID)
            return
        }

        let (phase, message) = SharedStore.readPhase()
        let partial = KeyboardChannel.partialText
        if !partial.isEmpty, phase == .recording || phase == .processing {
            liveLabel.text = partial
            liveContainer.isHidden = false
        } else {
            liveContainer.isHidden = true
        }

        switch phase {
        case .recording:
            isRecording = true
            applyMicAppearance(recording: true)
            setState(Copy.listening, color: .systemRed, status: Copy.listeningStatus, hint: Copy.listeningHint)
        case .processing:
            applyMicAppearance(recording: false)
            setState(Copy.writing, color: .systemOrange, status: Copy.writingStatus, hint: "")
        case .ready:
            isRecording = false
            applyMicAppearance(recording: false)
            setState(Copy.done, color: .systemGreen, status: Copy.readyStatus, hint: "即将写入输入框")
        case .error:
            isRecording = false
            applyMicAppearance(recording: false)
            setState(Copy.failed, color: .systemRed, status: Copy.failedStatus, hint: message)
        case .standby:
            isRecording = false
            applyMicAppearance(recording: false)
            if !hasFullAccess {
                setState(Copy.limited, color: .systemRed, status: Copy.noAccessStatus, hint: Copy.accessHint)
            } else if !KeyboardChannel.isConfigured {
                setState(Copy.ready, color: .systemGreen, status: Copy.idle, hint: "尚未配置 API Key，请在 App 内完成设置")
            } else {
                let standbyLine = KeyboardChannel.standbyDescription
                let pingLine = "上次检测：\(KeyboardChannel.lastPingDescription)"
                setState(Copy.ready, color: .systemGreen, status: Copy.idle,
                         hint: standbyLine.isEmpty ? Copy.idleHint : "\(standbyLine) · \(pingLine)")
            }
        case .unavailable:
            isRecording = false
            applyMicAppearance(recording: false)
            if !hasFullAccess {
                setState(Copy.limited, color: .systemRed, status: Copy.noAccessStatus, hint: Copy.accessHint)
            } else if !SharedStore.isAvailable {
                setState(Copy.offline, color: .systemGray, status: Copy.offlineStatus, hint: Copy.offlineHint)
            } else {
                setState(Copy.asleep, color: .systemGray, status: Copy.notReadyStatus, hint: Copy.asleepHint)
            }
        }

        if let started = pollStartedAt, Date().timeIntervalSince(started) > 30, isRecording {
            stopPolling()
            isRecording = false
            applyMicAppearance(recording: false)
            setState(Copy.failed, color: .systemRed, status: Copy.timeoutStatus, hint: Copy.timeoutHint)
        }
    }

    private func setState(_ short: String, color: UIColor, status: String, hint: String) {
        stateLabel.text = short
        stateDot.backgroundColor = color
        if !status.isEmpty { statusLabel.text = status }
        hintLabel.text = hint
        hintLabel.isHidden = hint.isEmpty
    }

    private func applyMicAppearance(recording: Bool) {
        micButton.setImage(UIImage(systemName: recording ? "stop.fill" : "mic.fill"), for: .normal)
        micButton.backgroundColor = recording ? Palette.recordFill : Palette.primaryFill
        micButton.tintColor = recording ? .white : Palette.primaryGlyph
    }

    // MARK: - 打开宿主 App

    private func promptOpenApp(reason: String) {
        setState(Copy.jumping, color: .systemOrange, status: Copy.openingStatus,
                 hint: "\(reason) \(Copy.openingHint)")
        openContainingApp()
    }

    /// 宿主 App 的 bundle id。
    /// `hostBundleIdentifier` 不是公开 API，用 responds/perform 读；拿不到就返回 nil（不影响其它流程）。
    private var hostBundleIdentifier: String? {
        let selector = NSSelectorFromString("hostBundleIdentifier")
        guard let context = extensionContext, context.responds(to: selector),
              let value = context.perform(selector)?.takeUnretainedValue() as? String,
              !value.isEmpty else { return nil }
        return value
    }

    private func openContainingApp() {
        guard !didOpenContainingApp else { return }
        didOpenContainingApp = true
        // 带上宿主 App 的 bundle id：主 App 录完会用它自动跳回这个 App（Typeless 同款做法）。
        var components = URLComponents(string: "\(SharedStore.scheme)://dictate")
        if let host = hostBundleIdentifier {
            components?.queryItems = [URLQueryItem(name: "return", value: host)]
        }
        guard let url = components?.url else { return }
        extensionContext?.open(url) { [weak self] success in
            guard !success else { return }
            DispatchQueue.main.async { self?.openViaResponderChain(url) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.openViaResponderChain(url)
        }
    }

    /// ⚠️ 私有接口兜底：上架审核前请删除本方法及调用点。
    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url, with: [String: Any]())
                return
            }
            responder = current.next
        }
        setState(Copy.asleep, color: .systemRed, status: "无法唤起 VoiceKey", hint: "请手动切到 App 使用")
    }
}
