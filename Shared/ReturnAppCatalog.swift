import Foundation

/// 从 App Group / 剪贴板把文字送回"上一个 App"时，需要知道宿主 App 的 URL scheme。
///
/// 依据：Typeless 2.7.0 的 Info.plist 里声明了 50 个 App 的 URL scheme
/// （`weixin / lark / notion / slack / telegram / whatsapp / twitter / instagram …`），
/// 这正是它能"录完自动跳回上一个 App"的原料；它的键盘也会把 `hostAppBundleId` 传给主 App。
///
/// 这里只维护常见 App 的 bundle id → scheme 映射；查不到时返回 nil，
/// 由系统自带的"返回 <上一个 App>"状态栏入口兜底（那条路不需要任何配置）。
enum ReturnAppCatalog {
    /// 前缀匹配：bundle id 常见变体（如 com.tencent.xin / com.tencent.xinWeChat）都能命中。
    private static let table: [(prefix: String, scheme: String)] = [
        ("com.tencent.xin", "weixin"),
        ("com.tencent.mm", "weixin"),
        ("com.tencent.wework", "wxwork"),
        ("com.bytedance.ee.lark", "lark"),
        ("com.ss.lark", "lark"),
        ("com.bytedance.ee", "lark"),
        ("com.laiwang", "lark"),
        ("notion.id", "notion"),
        ("com.tinyspeck.chatlyio", "slack"),
        ("com.microsoft.teams", "msteams"),
        ("com.microsoft.Office.Outlook", "ms-outlook"),
        ("com.apple.mobilenotes", "mobilenotes"),
        ("com.apple.mobilemail", "mailto"),
        ("ph.telegra.Telegraph", "tg"),
        ("org.telegram", "tg"),
        ("net.whatsapp.WhatsApp", "whatsapp"),
        ("com.burbn.instagram", "instagram"),
        ("com.atebits.Tweetie2", "twitter"),
        ("com.facebook.Facebook", "fb"),
        ("com.facebook.Messenger", "fb-messenger"),
        ("com.hammerandchisel.discord", "discord"),
        ("com.toyopagroup.picaboo", "snapchat"),
        ("com.spotify.client", "spotify"),
        ("com.google.chrome.ios", "googlechrome"),
        ("com.google.Docs", "googledocs"),
        ("com.google.Drive", "googledrive"),
        ("com.google.Maps", "googlemaps"),
        ("com.openai.chat", "openai"),
        ("com.anthropic.claude", "claude"),
        ("ai.perplexity.app", "perplexity-app"),
        ("com.reddit.Reddit", "reddit"),
        ("pinterest", "pinterest"),
        ("com.zhiliaoapp.musically", "snssdk1233"),
        ("com.ss.iphone.ugc.Aweme", "snssdk1128"),
        ("com.burbn.barcelona", "barcelona"),
        ("com.evernote.iPhone.Evernote", "evernote"),
        ("com.linear", "linear"),
        ("com.atlassian.Jira", "jira"),
        ("com.monday.monday", "monday"),
        ("com.trello.trello", "trello"),
        ("com.netflix.Netflix", "nflx"),
        ("com.ubercab.UberClient", "uber"),
        ("com.ubercab.UberEats", "ubereats"),
        ("com.walmart.electronics", "walmart"),
        ("com.substack.app", "substack")
    ]

    /// 所有会被 `canOpenURL` 检查的 scheme（与 Info.plist 的 LSApplicationQueriesSchemes 保持一致）。
    static var declaredSchemes: [String] {
        Array(Set(table.map(\.scheme) + ["x-safari-https"])).sorted()
    }

    static func scheme(forBundleIdentifier bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let lowered = bundleID.lowercased()
        // 精确匹配优先，再退到前缀匹配。
        if let exact = table.first(where: { $0.prefix.lowercased() == lowered }) { return exact.scheme }
        return table.first { lowered.hasPrefix($0.prefix.lowercased()) }?.scheme
    }

    /// 是否是我们自己的 App（避免"返回"到自己）。
    static func isOwnApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.hasPrefix("dev.hyc.voicekey")
    }
}
