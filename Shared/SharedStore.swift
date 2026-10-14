import Foundation
import CoreFoundation

/// 键盘与主 App 之间的最小契约。
///
/// 设计要点（借鉴 Typeless 2.7.0 的取证结论，但不使用其私有 API）：
/// - App Group 是首选通道；企业签名/免费账号可能拿不到 App Group，因此有纯 Darwin + 剪贴板兜底。
/// - Darwin 通知只做唤醒，不承载数据；数据放在文件里原子写入。
/// - 每次命令带 `createdAt`，超过 15 秒的过期命令直接丢弃，避免旧请求被误执行。
enum SharedStore {
    static let baseGroup = "group.dev.hyc.voicekey"
    static let commandNotification = "dev.hyc.voicekey.command" as CFString
    static let eventNotification = "dev.hyc.voicekey.event" as CFString
    static let pasteboardMarker = "dev.hyc.voicekey.result"
    static let scheme = "voicekey"

    /// 兜底信号（无 App Group 时使用）
    enum Signal: String, CaseIterable {
        case ping, start, stop, cancel
        case ready, recording, processing, result, error

        var notificationName: CFString { "dev.hyc.voicekey.signal.\(rawValue)" as CFString }
    }

    private static let resolution = resolve()

    struct Resolution {
        let identifier: String
        let source: String
        let containerURL: URL?
    }

    static var resolutionSource: String { resolution.source }
    static var groupIdentifier: String { resolution.identifier }
    static var isAvailable: Bool { resolution.containerURL != nil }

    static var containerURL: URL? { resolution.containerURL }

    static var directory: URL? {
        guard let containerURL else { return nil }
        let url = containerURL.appendingPathComponent("protocol-v1", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static var defaults: UserDefaults? {
        guard resolution.containerURL != nil else { return nil }
        return UserDefaults(suiteName: resolution.identifier)
    }

    private static func resolve() -> Resolution {
        var candidates: [(String, String)] = []
        if let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profile),
           let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = (try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil
           )) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any] {
            let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
            candidates += groups.map { ($0, "描述文件") }
            if let appID = entitlements["application-identifier"] as? String,
               let team = appID.split(separator: ".").first, team.count == 10 {
                candidates.append(("\(baseGroup).\(team)", "描述文件 Team ID"))
            }
        }
        candidates.append((baseGroup, "项目默认值"))
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.0).inserted }
        for (identifier, source) in unique {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return Resolution(identifier: identifier, source: source, containerURL: url)
            }
        }
        return Resolution(identifier: unique.first?.0 ?? baseGroup, source: "不可用（将走 Darwin + 剪贴板兜底）", containerURL: nil)
    }

    // MARK: - 原子文件读写

    static func write<T: Encodable>(_ value: T, name: String) {
        guard let directory else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        // 直接用 .atomic 写：内部已经在临时文件上写完再 rename，
        // 不再用 replaceItemAt（目标不存在时行为不稳、且 try? 会静默丢文件）。
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let directory else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func remove(name: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    // MARK: - 通知

    static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true
        )
    }

    static func post(signal: Signal) { post(signal.notificationName) }

    static func observe(_ name: CFString, handler: @escaping () -> Void) -> ObserverBox {
        let box = ObserverBox(name: name, handler: handler)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(box).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue().fire()
            },
            name, nil, .deliverImmediately
        )
        return box
    }

    /// Darwin 观察者句柄。
    ///
    /// 关键：CFNotificationCenter 只保存**裸指针**（我们用 passUnretained），所以持有者一旦释放
    /// 而注册还在，下一次通告就会解引用已释放内存 → 键盘扩展崩溃 → 系统切到其它键盘。
    /// 因此这里必须显式 stop()，并在 deinit 兜底（与已验证实现的 `FallbackSignalListener.deinit` 一致）。
    final class ObserverBox {
        private let name: CFString
        private let handler: () -> Void
        private var stopped = false

        init(name: CFString, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
        }

        func fire() { handler() }

        func stop() {
            guard !stopped else { return }
            stopped = true
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name), nil
            )
        }

        deinit { stop() }
    }

    // MARK: - 共享状态（键盘用来显示状态）

    enum Phase: String {
        case unavailable, standby, recording, processing, ready, error

        var label: String {
            switch self {
            case .unavailable: "未连接主 App"
            case .standby: "待命"
            case .recording: "录音中"
            case .processing: "整理中"
            case .ready: "请插入"
            case .error: "出错了"
            }
        }
    }

    static var heartbeat: Double {
        defaults?.double(forKey: "heartbeat") ?? 0
    }

    static func markHeartbeat() {
        defaults?.set(Date().timeIntervalSince1970, forKey: "heartbeat")
    }

    /// 主 App 存活判定：心跳 6 秒内视为活跃（键盘触发前会再发一次 ping 并短暂等待）。
    static var mainAppIsAlive: Bool {
        Date().timeIntervalSince1970 - heartbeat < 6
    }

    static func publish(phase: Phase, message: String) {
        defaults?.set(phase.rawValue, forKey: "phase")
        defaults?.set(message, forKey: "phaseMessage")
        defaults?.set(Date().timeIntervalSince1970, forKey: "phaseAt")
    }

    static func readPhase() -> (Phase, String) {
        let raw = defaults?.string(forKey: "phase") ?? ""
        let message = defaults?.string(forKey: "phaseMessage") ?? ""
        return (Phase(rawValue: raw) ?? .unavailable, message)
    }

    static func publishResult(text: String, sessionID: String) {
        let payload = ResultPayload(text: text, sessionID: sessionID, createdAt: Date().timeIntervalSince1970)
        write(payload, name: "result.json")
        defaults?.set(text, forKey: "lastResult")
        defaults?.set(sessionID, forKey: "lastResultSession")
        publish(phase: .ready, message: "已完成，等待插入")
        post(signal: .result)
    }
}

/// 键盘可见的少量字段。密钥、历史、原文都不进这里。
enum KeyboardChannel {
    static func publishConfiguration(configured: Bool) {
        SharedStore.defaults?.set(configured, forKey: "configured")
        SharedStore.post(signal: .ready)
    }

    static var isConfigured: Bool {
        SharedStore.defaults?.bool(forKey: "configured") ?? false
    }

    /// 边录边识别时把已识别的片段推给键盘显示。
    static func publishPartial(_ text: String) {
        SharedStore.defaults?.set(text, forKey: "partialText")
        SharedStore.post(SharedStore.eventNotification)
    }

    static var partialText: String {
        SharedStore.defaults?.string(forKey: "partialText") ?? ""
    }

    static func clearPartial() {
        SharedStore.defaults?.removeObject(forKey: "partialText")
    }

    static func publishStandby(active: Bool, mode: String, captureCapable: Bool = false) {
        SharedStore.defaults?.set(active, forKey: "standbyActive")
        SharedStore.defaults?.set(mode, forKey: "standbyMode")
        SharedStore.defaults?.set(captureCapable, forKey: "standbyCaptureCapable")
    }

    /// 当前待命是否支持后台直接开录（只有"麦克风常开"为真）。
    static var standbySupportsBackgroundCapture: Bool {
        SharedStore.defaults?.bool(forKey: "standbyCaptureCapable") ?? false
    }

    /// 键盘侧记录上一次 ping 结果，便于诊断"为什么跳转了 App"。
    static func recordPing(ok: Bool, milliseconds: Int) {
        SharedStore.defaults?.set(ok ? "成功 \(milliseconds) ms" : "超时 \(milliseconds) ms", forKey: "lastPing")
        SharedStore.defaults?.set(Date().timeIntervalSince1970, forKey: "lastPingAt")
        SharedStore.defaults?.synchronize()
    }

    static var lastPingDescription: String {
        guard let value = SharedStore.defaults?.string(forKey: "lastPing") else { return "尚未检测" }
        let at = SharedStore.defaults?.double(forKey: "lastPingAt") ?? 0
        guard at > 0 else { return value }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(value) · \(formatter.string(from: Date(timeIntervalSince1970: at)))"
    }

    /// 键盘上显示的一行状态说明；未开启待命时返回空串，由键盘回落到默认提示。
    static var standbyDescription: String {
        let active = SharedStore.defaults?.bool(forKey: "standbyActive") ?? false
        guard active else { return "" }
        switch SharedStore.defaults?.string(forKey: "standbyMode") ?? "" {
        case "麦克风常开": return "麦克风常开 · 随时可录"
        case "画中画", "画中画(可见)": return "画中画待命 · 仅保进程"
        case "静音输出": return "静音待命 · 仅保进程"
        case let other: return other.isEmpty ? "" : "\(other) 待命"
        }
    }
}

// MARK: - 协议负载

struct DictationRequest: Codable, Equatable {
    let version: Int
    let id: String
    let sessionID: String
    let source: String
    let createdAt: Double

    init(source: String, now: Double = Date().timeIntervalSince1970) {
        version = 1
        id = UUID().uuidString
        sessionID = UUID().uuidString
        self.source = source
        createdAt = now
    }

    var isValid: Bool {
        let now = Date().timeIntervalSince1970
        return version == 1 && now - createdAt <= 15 && createdAt - now <= 2
    }
}

struct DictationReply: Codable {
    enum Kind: String, Codable { case accepted, rejected, partial, completed, failed }
    let requestID: String
    let sessionID: String
    let kind: Kind
    let text: String?
    let message: String
    let createdAt: Double
}

struct ResultPayload: Codable {
    let text: String
    let sessionID: String
    let createdAt: Double
}
