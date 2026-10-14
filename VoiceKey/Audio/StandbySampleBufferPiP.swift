import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// 画中画待命（Typeless 路线）：用 `AVSampleBufferDisplayLayer` + `AVPictureInPictureControllerContentSource`
/// 驱动画中画，而不是播放视频文件。
///
/// 为什么这条路更接近"用户感知不到"：
/// - Typeless 主二进制同时引用了 `AVSampleBufferDisplayLayer`、`AVPictureInPictureControllerContentSource`、
///   `initWithSampleBufferDisplayLayer:playbackDelegate:`，说明它走的是 sample-buffer 内容源，而不是 `playerLayer:`；
/// - 这条路下"窗口里画什么"完全由我们喂的帧决定，配合 `PiPVisibilityAdapter` 覆盖内容类型/控件样式，
///   系统可以完全不绘制内容面；
/// - 即使系统仍然绘制，我们喂的是 **2432×2 的全透明帧**，窗口会退化成一条细线（与已验证素材同规格）。
///
/// 失败一律抛出/返回 false，由调用方回落到视频路线，不静默变成"假待命"。
final class StandbySampleBufferPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {

    struct Status: Equatable {
        var active = false
        var message = "未启动"
        var hidden = false
    }

    private(set) var status = Status()
    var onStatusChange: ((Status) -> Void)?

    /// 是否尝试隐藏（依赖 `PiPVisibilityAdapter` 的私有方法替换）。
    var hideWindow = true

    /// 喂帧尺寸：极扁条带，保证窗口即使被绘制也只是发丝。
    private let frameSize = CGSize(width: 2432, height: 2)

    private let adapter = PiPVisibilityAdapter()
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private var anchorView: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private var feedTimer: Timer?
    private var stopRequested = false
    private var startRequested = false
    private var hiddenInstalled = false
    private var frameCount = 0

    var isActive: Bool {
        controller?.isPictureInPictureActive == true && status.active
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    // MARK: - 启动 / 停止

    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        if isActive { return }
        stop()
        stopRequested = false
        startRequested = false
        frameCount = 0
        update(active: false, message: "正在启动画中画（sample buffer）…", hidden: false)

        guard isSupported else { throw StandbySampleBufferError.unsupported }
        guard let window = Self.keyWindow() else { throw StandbySampleBufferError.noWindow }

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)

        // 显示层必须挂在视图树里；尺寸正常，隐藏交给内容与适配器。
        let anchor = UIView(frame: CGRect(x: 12, y: window.safeAreaInsets.top + 8, width: 96, height: 54))
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = anchor.bounds
        layer.videoGravity = .resizeAspect
        anchor.layer.addSublayer(layer)
        window.addSubview(anchor)

        guard let buffer = Self.makeFrame(width: Int(frameSize.width), height: Int(frameSize.height)) else {
            anchor.removeFromSuperview()
            throw StandbySampleBufferError.frameCreationFailed
        }
        layer.enqueue(buffer)

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        // 注意：init(contentSource:) 是非可失败构造器（与 init(playerLayer:) 不同）。
        let controller = AVPictureInPictureController(contentSource: source)

        self.anchorView = anchor
        self.displayLayer = layer
        self.controller = controller
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startWhenPossible() }
        }
        startFeeding()
        startWhenPossible()
    }

    private func startWhenPossible() {
        guard !stopRequested, !startRequested, let controller, controller.isPictureInPicturePossible else { return }
        startRequested = true
        var hidden = false
        if hideWindow {
            hidden = adapter.bind(to: controller)
            hiddenInstalled = hidden
        }
        controller.startPictureInPicture()
        update(active: true,
               message: hidden ? "画中画待命（sample buffer，已隐藏）" : "画中画待命（sample buffer，浮窗可见）",
               hidden: hidden)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRequested = true
        startRequested = false
        stopFeeding()
        adapter.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        displayLayer?.flushAndRemoveImage()
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        anchorView?.removeFromSuperview()
        anchorView = nil
        hiddenInstalled = false
        update(active: false, message: "已停止", hidden: false)
    }

    /// 录音会把音频类别切成 playAndRecord；这里切回 playback 并补一帧，防止画中画被判定结束。
    func resumeIdlePlayback() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard controller != nil, let layer = displayLayer else { return }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? audio.setActive(true)
        if layer.status == .failed { layer.flush() }
        enqueueFrame()
        adapter.refresh()
        startFeeding()
    }

    // MARK: - 喂帧

    private func startFeeding() {
        feedTimer?.invalidate()
        // 1 Hz 足够维持"有内容"的状态；帧很小（2432×2 透明 BGRA ≈ 19 KB），开销可忽略。
        feedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.enqueueFrame() }
        }
    }

    private func stopFeeding() {
        feedTimer?.invalidate()
        feedTimer = nil
    }

    private func enqueueFrame() {
        guard !stopRequested, let layer = displayLayer else { return }
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        guard let buffer = Self.makeFrame(width: Int(frameSize.width), height: Int(frameSize.height)) else { return }
        layer.enqueue(buffer)
        frameCount += 1
    }

    /// 全透明 BGRA 帧：alpha 为 0，系统若忽略 alpha 也只是黑，且高度只有 2px。
    private static func makeFrame(width: Int, height: Int) -> CMSampleBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: buffer,
                                                           formatDescriptionOut: &formatDescription) == noErr,
              let description = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: buffer,
                                                       formatDescription: description,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
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
        enqueueFrame()
        update(active: true,
               message: status.hidden ? "画中画待命（sample buffer，已隐藏）" : "画中画待命（sample buffer，浮窗可见）",
               hidden: status.hidden)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller, !stopRequested else { return }
        update(active: false, message: "画中画已被关闭，请回到 App 重新开启待命", hidden: false)
        stopFeeding()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // 用户主动关闭时不偷偷重启，也不顺手开始录音。
        completionHandler(true)
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    /// 直播式内容：时间范围无限，系统不会显示进度条与快进。
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        // 我们永远"在播"：待命不需要真的播内容。
        enqueueFrame()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        enqueueFrame()
    }

    enum StandbySampleBufferError: LocalizedError {
        case unsupported, noWindow, frameCreationFailed

        var errorDescription: String? {
            switch self {
            case .unsupported: "这台设备不支持 sample buffer 画中画。"
            case .noWindow: "需要先把 App 切到前台再启用画中画待命。"
            case .frameCreationFailed: "无法创建画中画帧。"
            }
        }
    }
}
