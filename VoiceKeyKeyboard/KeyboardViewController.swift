import UIKit

/// 键盘扩展：只做三件事——判断主 App 是否真的活着、发指令让它录音、把结果插进宿主输入框。
///
/// 样式参考 Voxt-ios 的语音面板：顶部字标 + 状态药丸、居中黑色大药丸麦克风、
/// 底部「圆–药丸–圆」。不做双拼/拼音输入，也不需要 Rime。
/// 保留地球键（Apple 要求 needsInputModeSwitchKey 时提供，否则用户可能无法切回其它键盘）。
final class KeyboardViewController: UIInputViewController {

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
        if isRecording { stopRecording(); return }
        guard hasFullAccess else {
            setState("需要完全访问", color: .systemRed,
                     status: "", hint: "设置 → 通用 → 键盘 → VoiceKey，打开「允许完全访问」。")
            return
        }
        guard SharedStore.isAvailable else {
            promptOpenApp(reason: "当前签名没有 App Group。")
            return
        }
        setState("确认中", color: .systemOrange, status: "正在确认 App 状态…", hint: "")
        if pingMainApp() {
            startViaSharedChannel()
        } else {
            promptOpenApp(reason: "App 不在后台运行。")
        }
    }

    @objc private func micLongPressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if !isRecording { micTapped() }
        case .ended, .cancelled, .failed:
            if isRecording { stopRecording() }
        default:
            break
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        setState("识别中", color: .systemOrange, status: "正在生成文字…", hint: "")
        send(source: "stop")
        startPolling()
    }

    @objc private func insertTapped() {
        if let result = SharedStore.read(ResultPayload.self, name: "result.json"),
           Date().timeIntervalSince1970 - result.createdAt < 300 {
            insert(result.text, session: result.sessionID)
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            setState("无内容", color: .systemGray, status: "没有可插入的内容", hint: "先说一句，或让 App 写回结果。")
            return
        }
        textDocumentProxy.insertText(text)
        setState("已插入", color: .systemGreen, status: "已插入剪贴板内容（\(text.count) 字）", hint: "")
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    // MARK: - 与主 App 的共享通道

    /// 发一次 ping 并短暂等待回执：比"心跳没过期"更可靠（心跳新鲜 ≠ 现在能起麦克风）。
    private func pingMainApp() -> Bool {
        let request = DictationRequest(source: "ping")
        SharedStore.write(request, name: "request.json")
        SharedStore.post(SharedStore.commandNotification)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if SharedStore.read(DictationReply.self, name: "reply-\(request.id).json") != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func startViaSharedChannel() {
        let request = DictationRequest(source: "start")
        activeSession = request.sessionID
        SharedStore.write(request, name: "request.json")
        SharedStore.remove(name: "result.json")
        SharedStore.post(SharedStore.commandNotification)
        isRecording = true
        setState("录音中", color: .systemRed, status: "正在开始录音…", hint: "点麦克风或松手结束")
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
        setState("已插入", color: .systemGreen, status: "已插入 \(text.count) 个字", hint: "")
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
            setState("录音中", color: .systemRed, status: "正在录音…", hint: "点麦克风或松手结束")
        case .processing:
            applyMicAppearance(recording: false)
            setState("识别中", color: .systemOrange, status: "正在识别与整理…", hint: "")
        case .ready:
            isRecording = false
            applyMicAppearance(recording: false)
            setState("完成", color: .systemGreen, status: "已完成", hint: "结果会自动插入")
        case .error:
            isRecording = false
            applyMicAppearance(recording: false)
            setState("出错", color: .systemRed, status: "出错了", hint: message)
        case .standby:
            isRecording = false
            applyMicAppearance(recording: false)
            if !hasFullAccess {
                setState("需要完全访问", color: .systemRed, status: "", hint: "设置 → 通用 → 键盘 → VoiceKey")
            } else if !KeyboardChannel.isConfigured {
                setState("待命", color: .systemGreen, status: "点击麦克风开始说话", hint: "还没配置 API Key，请打开 App 设置。")
            } else {
                setState("待命", color: .systemGreen, status: "点击麦克风开始说话",
                         hint: KeyboardChannel.standbyDescription)
            }
        case .unavailable:
            isRecording = false
            applyMicAppearance(recording: false)
            if !hasFullAccess {
                setState("需要完全访问", color: .systemRed, status: "", hint: "设置 → 通用 → 键盘 → VoiceKey")
            } else if !SharedStore.isAvailable {
                setState("未连接", color: .systemGray, status: "未连接主 App",
                         hint: "当前签名没有 App Group，请用「打开 App + 左下角插入结果」。")
            } else {
                setState("未运行", color: .systemGray, status: "VoiceKey 未在后台", hint: "点麦克风会提示打开 App。")
            }
        }

        if let started = pollStartedAt, Date().timeIntervalSince(started) > 30, isRecording {
            stopPolling()
            isRecording = false
            applyMicAppearance(recording: false)
            setState("无响应", color: .systemRed, status: "没有收到结果", hint: "请确认 App 已打开并配置好 API Key。")
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
        setState("待启动", color: .systemOrange, status: "已请求打开 VoiceKey",
                 hint: "\(reason) 回去录完后切回来，或点左下角插入结果。")
        openContainingApp()
    }

    private func openContainingApp() {
        guard !didOpenContainingApp else { return }
        didOpenContainingApp = true
        guard let url = URL(string: "\(SharedStore.scheme)://dictate") else { return }
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
        setState("待启动", color: .systemRed, status: "无法自动打开 VoiceKey", hint: "请手动切到 App 使用。")
    }
}
