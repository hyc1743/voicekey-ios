import AVFoundation
import AVKit
import UIKit

/// 画中画待命：用一个循环播放的静音视频占用系统画中画会话，换取后台运行时间。
///
/// 这是 Typeless 2.7.0 的做法（分析结论：`iosKeepActiveMode = pictureInPicture`），
/// 但按我们的原则重写：自生成的 2 KB 素材、失败一律回退、隐藏浮窗依赖
/// `PiPVisibilityAdapter` 且可整体关闭。
///
/// ⚠️ 隐藏浮窗用到 AVKit 私有方法；上架审核前请把 `hideWindow` 固定为 false 或删除适配器。
final class StandbyVideoPiP: NSObject, AVPictureInPictureControllerDelegate {
    struct Status: Equatable {
        var active = false
        var message = "未启动"
        var hidden = false
    }

    private(set) var status = Status()
    var onStatusChange: ((Status) -> Void)?

    /// 是否尝试隐藏浮窗内容（依赖私有 API）。
    var hideWindow = true

    private let adapter = PiPVisibilityAdapter()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var controller: AVPictureInPictureController?
    private var sourceView: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private var stopRequested = false
    private var startRequested = false

    var isActive: Bool {
        controller?.isPictureInPictureActive == true && player?.error == nil && status.active
    }

    // MARK: - 启动 / 停止

    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        if isActive { return }
        stop()
        stopRequested = false
        startRequested = false
        update(active: false, message: "正在启动画中画…", hidden: false)

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw StandbyPiPError.unsupported
        }
        guard let window = Self.keyWindow() else { throw StandbyPiPError.noWindow }
        let name = hideWindow ? "StandbyHidden" : "Standby"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else {
            throw StandbyPiPError.missingAsset
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try session.setActive(true)

        let player = AVQueuePlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: item)

        // 画中画要求图层在视图树里；这里放一个 2×2 的不可见锚点，尽量避免干扰界面。
        let anchor = UIView(frame: CGRect(x: 1, y: 1, width: 2, height: 2))
        anchor.alpha = 0.02
        anchor.isUserInteractionEnabled = false
        anchor.accessibilityElementsHidden = true
        let layer = AVPlayerLayer(player: player)
        layer.frame = anchor.bounds
        layer.videoGravity = .resizeAspect
        anchor.layer.addSublayer(layer)
        window.addSubview(anchor)

        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            anchor.removeFromSuperview()
            throw StandbyPiPError.unsupported
        }
        self.player = player
        self.looper = looper
        self.sourceView = anchor
        self.controller = controller
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startWhenPossible() }
        }
        player.play()
        startWhenPossible()
    }

    private func startWhenPossible() {
        guard !stopRequested, !startRequested, let controller, controller.isPictureInPicturePossible else { return }
        startRequested = true

        var hidden = false
        if hideWindow {
            hidden = adapter.bind(to: controller)
            if !hidden {
                // 隐藏失败不影响画中画本身，退回可见模式并如实上报。
                update(active: status.active, message: adapter.diagnostic, hidden: false)
            }
        }
        controller.startPictureInPicture()
        update(active: true, message: hidden ? "画中画待命（已隐藏浮窗）" : "画中画待命（浮窗可见）", hidden: hidden)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRequested = true
        startRequested = false
        adapter.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        update(active: false, message: "已停止", hidden: false)
    }

    private func update(active: Bool, message: String, hidden: Bool) {
        let next = Status(active: active, message: message, hidden: hidden)
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === self.controller else { return }
        update(active: false, message: "画中画启动失败：\(error.localizedDescription)", hidden: false)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        adapter.refresh()
        update(active: true, message: status.hidden ? "画中画待命（已隐藏浮窗）" : "画中画待命（浮窗可见）", hidden: status.hidden)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller, !stopRequested else { return }
        update(active: false, message: "画中画已被关闭，请回到 App 重新开启待命", hidden: false)
        player?.pause()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // 用户主动关闭时不要偷偷重启，也不要顺手开始录音。
        completionHandler(true)
    }

    enum StandbyPiPError: LocalizedError {
        case unsupported, noWindow, missingAsset

        var errorDescription: String? {
            switch self {
            case .unsupported: "这台设备不支持画中画待命。"
            case .noWindow: "需要先把 App 切到前台再启用画中画待命。"
            case .missingAsset: "缺少画中画素材（Standby.mp4 / StandbyHidden.mp4）。"
            }
        }
    }
}
