import UIKit

/// 键盘扩展：本身不录音（iOS 不给键盘麦克风权限），只做三件事：
/// 1) 用 ping-pong 判断主 App 是否真的活着（沿用分析里 250 ms 心跳的思路，这里放宽到 500 ms）；
/// 2) 活着就发指令让它录音，**不切 App**；不活着才退回到"打开 App + 剪贴板"；
/// 3) 轮询结果并 `textDocumentProxy.insertText` 插进宿主输入框。
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let partialLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)

    private var observer: AnyObject?
    private var pollTimer: Timer?
    private var pollStartedAt: Date?
    private var lastInsertedSession = ""
    private var activeSession = ""
    private var didOpenContainingApp = false

    private let idleStatus = "点麦克风开始说话"

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
        if pollTimer != nil, !activeSession.isEmpty { send(source: "stop") }
        stopPolling()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        refresh()
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = idleStatus

        partialLabel.font = .systemFont(ofSize: 13)
        partialLabel.textColor = .secondaryLabel
        partialLabel.textAlignment = .left
        partialLabel.numberOfLines = 2
        partialLabel.isHidden = true

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2

        configure(micButton, title: "🎙", background: .systemBlue, textColor: .white)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.layer.cornerRadius = 28

        configure(stopButton, title: "停止", background: .systemRed, textColor: .white)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

        configure(pasteButton, title: "插入结果", background: .systemGreen, textColor: .white)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        pasteButton.isHidden = true

        configure(openButton, title: "打开 App", background: .systemGray, textColor: .white)
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        configure(globeButton, title: "🌐", background: .clear, textColor: .label)
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [micButton, stopButton, pasteButton, openButton, globeButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.alignment = .center
        buttons.distribution = .fillProportionally

        let stack = UIStackView(arrangedSubviews: [statusLabel, partialLabel, buttons, hintLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            micButton.widthAnchor.constraint(equalToConstant: 56),
            micButton.heightAnchor.constraint(equalToConstant: 56),
            view.heightAnchor.constraint(equalToConstant: 236)
        ])
    }

    private func configure(_ button: UIButton, title: String, background: UIColor, textColor: UIColor) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = background
        button.setTitleColor(textColor, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.layer.cornerRadius = 18
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
    }

    // MARK: - 动作

    @objc private func micTapped() {
        guard SharedStore.isAvailable else {
            // 没有 App Group：文件通道不可用，只能请 App 到前台 + 剪贴板兜底。
            promptOpenApp(reason: "当前签名没有 App Group，需要先打开 App。")
            return
        }
        statusLabel.text = "正在确认 App 状态…"
        if pingMainApp() {
            startViaSharedChannel()
        } else {
            promptOpenApp(reason: "App 不在后台运行。")
        }
    }

    @objc private func stopTapped() {
        guard !activeSession.isEmpty else { return }
        statusLabel.text = "正在生成文字…"
        send(source: "stop")
        startPolling()
    }

    @objc private func pasteTapped() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            hintLabel.text = "剪贴板里没有内容。"
            return
        }
        textDocumentProxy.insertText(text)
        hintLabel.text = "已插入 \(text.count) 个字。"
        pasteButton.isHidden = true
    }

    @objc private func openTapped() {
        promptOpenApp(reason: "手动打开")
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
        statusLabel.text = "正在开始录音…"
        partialLabel.isHidden = true
        startPolling()
    }

    private func send(source: String) {
        let request = DictationRequest(source: source)
        SharedStore.write(request, name: "request.json")
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

    private func refresh() {
        // 1) 有结果就插入
        if let result = SharedStore.read(ResultPayload.self, name: "result.json"),
           result.sessionID != lastInsertedSession,
           Date().timeIntervalSince1970 - result.createdAt < 120 {
            textDocumentProxy.insertText(result.text)
            lastInsertedSession = result.sessionID
            statusLabel.text = "已插入 \(result.text.count) 个字"
            partialLabel.isHidden = true
            hintLabel.text = nil
            pasteButton.isHidden = true
            stopPolling()
            activeSession = ""
            return
        }

        // 2) 状态 + 实时片段
        let (phase, message) = SharedStore.readPhase()
        let partial = KeyboardChannel.partialText
        if !partial.isEmpty, phase == .recording || phase == .processing {
            partialLabel.text = partial
            partialLabel.isHidden = false
        } else {
            partialLabel.isHidden = true
        }

        switch phase {
        case .recording:
            statusLabel.text = "🔴 正在录音…点“停止”生成文字"
            pasteButton.isHidden = true
        case .processing:
            statusLabel.text = "正在识别与整理…"
        case .ready:
            statusLabel.text = partial.isEmpty ? "已完成" : "已完成，等待插入"
        case .error:
            statusLabel.text = "出错了"
            hintLabel.text = message
        case .standby:
            statusLabel.text = idleStatus
            hintLabel.text = KeyboardChannel.isConfigured ? KeyboardChannel.standbyDescription : "还没配置 API Key，请打开 App 设置。"
        case .unavailable:
            statusLabel.text = "VoiceKey 未在后台"
            hintLabel.text = "点“打开 App”启动一次；或用剪贴板方案。"
            pasteButton.isHidden = UIPasteboard.general.string?.isEmpty ?? true
        }

        if let started = pollStartedAt, Date().timeIntervalSince(started) > 30 {
            stopPolling()
            statusLabel.text = "没有收到结果"
            hintLabel.text = "请确认 App 已打开并配置好 API Key。"
            pasteButton.isHidden = UIPasteboard.general.string?.isEmpty ?? true
        }
    }

    // MARK: - 打开宿主 App

    private func promptOpenApp(reason: String) {
        statusLabel.text = "已请求打开 VoiceKey"
        hintLabel.text = "\(reason)回去录完后切回来，或点“插入结果”。"
        pasteButton.isHidden = UIPasteboard.general.string?.isEmpty ?? true
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
        // 部分系统版本上 extensionContext.open 不回调也不生效，补一条兜底路径。
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
        hintLabel.text = "无法自动打开 VoiceKey，请手动切到 App 使用。"
    }
}
