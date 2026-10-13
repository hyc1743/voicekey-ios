import UIKit

/// 键盘扩展：本身不录音（iOS 不允许键盘申请麦克风），只负责发出指令、
/// 展示状态，并把主 App 整理好的文本插入宿主输入框。
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)

    private var observer: AnyObject?
    private var pollTimer: Timer?
    private var pollStartedAt: Date?
    private var session: String = ""
    private var lastInsertedSession: String = ""
    private var didOpenContainingApp = false

    private let idleStatus = "按住麦克风开始说话"

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
        if pollTimer != nil, !session.isEmpty {
            send(source: "stop")
        }
        stopPolling()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        refresh()
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = idleStatus

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

        configure(openButton, title: "打开 VOXT", background: .systemGray, textColor: .white)
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        configure(globeButton, title: "🌐", background: .clear, textColor: .label)
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [micButton, stopButton, pasteButton, openButton, globeButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.alignment = .center
        buttons.distribution = .fillProportionally

        let stack = UIStackView(arrangedSubviews: [statusLabel, buttons, hintLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            micButton.widthAnchor.constraint(equalToConstant: 56),
            micButton.heightAnchor.constraint(equalToConstant: 56),
            view.heightAnchor.constraint(equalToConstant: 210)
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
        if SharedStore.isAvailable, SharedStore.mainAppIsAlive {
            startViaSharedChannel()
        } else {
            // 主 App 不在（或没有 App Group）：只能把 App 请到前台，由它录音并在返回后插入。
            statusLabel.text = "正在打开 VOXT…"
            openContainingApp()
        }
    }

    @objc private func stopTapped() {
        guard !session.isEmpty else { return }
        statusLabel.text = "正在生成文字…"
        send(source: "stop")
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
        openContainingApp()
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    // MARK: - 共享通道

    private func startViaSharedChannel() {
        session = UUID().uuidString
        let request = DictationRequest(source: "start")
        SharedStore.write(request, name: "request.json")
        SharedStore.remove(name: "result.json")
        SharedStore.post(SharedStore.commandNotification)
        statusLabel.text = "正在唤醒 VOXT…"
        startPolling(session: request.sessionID)
    }

    private func send(source: String) {
        let request = DictationRequest(source: source)
        SharedStore.write(request, name: "request.json")
        SharedStore.post(SharedStore.commandNotification)
    }

    private func startPolling(session sessionID: String) {
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
        let (phase, message) = SharedStore.readPhase()
        if let result = SharedStore.read(ResultPayload.self, name: "result.json"),
           result.sessionID != lastInsertedSession,
           Date().timeIntervalSince1970 - result.createdAt < 90 {
            textDocumentProxy.insertText(result.text)
            lastInsertedSession = result.sessionID
            statusLabel.text = "已插入 \(result.text.count) 个字"
            hintLabel.text = nil
            pasteButton.isHidden = true
            stopPolling()
            session = ""
            return
        }

        switch phase {
        case .recording:
            statusLabel.text = "🔴 正在录音…点“停止”生成文字"
            pasteButton.isHidden = true
        case .processing:
            statusLabel.text = "正在识别与整理…"
        case .ready:
            statusLabel.text = "已完成"
        case .error:
            statusLabel.text = "出错了"
            hintLabel.text = message
        case .standby:
            statusLabel.text = idleStatus
        case .unavailable:
            statusLabel.text = "VOXT 未在后台运行"
            hintLabel.text = "点“打开 VOXT”启动一次；或用剪贴板方案。"
            pasteButton.isHidden = UIPasteboard.general.string?.isEmpty ?? true
        }

        if let started = pollStartedAt, Date().timeIntervalSince(started) > 25 {
            stopPolling()
            statusLabel.text = "没有收到结果"
            hintLabel.text = "请确认 VOXT 已打开并配置好 API Key。"
            pasteButton.isHidden = UIPasteboard.general.string?.isEmpty ?? true
        }
    }

    // MARK: - 打开宿主 App

    private func openContainingApp() {
        guard !didOpenContainingApp else { return }
        didOpenContainingApp = true
        guard let url = URL(string: "\(SharedStore.scheme)://dictate") else { return }
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    if !success {
                        self?.openViaResponderChain(url)
                    }
                }
            }
            // 兼容路径：部分 iOS 版本上 extensionContext.open 直接返回 false。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.presentedViewController == nil else { return }
                self.openViaResponderChain(url)
            }
        } else {
            openViaResponderChain(url)
        }
        statusLabel.text = "已请求打开 VOXT"
        hintLabel.text = "回到 VOXT 录完后，切回来自动插入；或点“插入结果”。"
        pasteButton.isHidden = false
    }

    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current.responds(to: selector) {
                let options: [String: Any] = [:]
                current.perform(selector, with: url, with: options)
                return
            }
            responder = current.next
        }
        hintLabel.text = "无法自动打开 VOXT，请手动切到 VOXT 使用。"
    }
}
