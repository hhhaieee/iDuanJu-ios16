import Foundation

/// A subscribed Telegram channel. Public channels are read through the web preview (`t.me/s/<name>`);
/// channels whose preview is disabled can only be read with TDLib (see `TDLibBridge`).
struct TGChannel: Codable, Hashable, Identifiable {
    var username: String
    var title: String = ""
    var avatar: String = ""
    var subscribers: String = ""
    var about: String = ""
    /// Adult channels are hidden unless 片源管理 → 成人频道 is on (and Face ID unlocked when the lock is on).
    var isAdult: Bool = false
    /// Per-channel switch for built-in ad heuristics + rules.
    var adBlock: Bool = true
    var addedAt: Date = Date()
    /// Set when `t.me/s/<name>` redirects away (preview disabled by Telegram / the owner).
    var previewUnavailable: String? = nil
    var id: String { username.lowercased() }
    var displayName: String { title.isEmpty ? "@" + username : title }

    /// Accepts `name`, `@name`, `t.me/name`, `https://t.me/s/name`, `https://t.me/name/123`.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        for p in ["www.t.me/", "t.me/s/", "t.me/", "telegram.me/s/", "telegram.me/", "@"] where s.lowercased().hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        if s.lowercased().hasPrefix("s/") { s = String(s.dropFirst(2)) }
        s = String(s.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
        guard s.count >= 4, s.count <= 64, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              s.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return s
    }
}

struct TGMedia: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case photo, video, gif }
    var kind: Kind
    /// photo: full image URL; video: thumbnail.
    var thumb: String
    /// Direct MP4 for videos (signed CDN URL, expires); nil when the preview says "media too big".
    var video: String? = nil
    var duration: Int = 0
    /// `t.me/<channel>/<id>` of the album item (each album item is its own message).
    var link: String = ""
    var spoiler = false
    var id: String { link.isEmpty ? (video ?? thumb) : link }
}

struct TGButton: Codable, Hashable { var text: String; var url: String }

struct TGLinkPreview: Codable, Hashable {
    var site: String = ""
    var title: String = ""
    var desc: String = ""
    var image: String = ""
    var url: String = ""
}

struct TGPost: Codable, Hashable, Identifiable {
    var channel: String
    var msgId: Int
    var date: Date?
    var author: String = ""
    var text: String = ""
    var media: [TGMedia] = []
    var links: [String] = []
    var buttons: [TGButton] = []
    var preview: TGLinkPreview? = nil
    var views: String = ""
    var forwardedFrom: String = ""
    var isService = false
    var id: String { channel.lowercased() + "/\(msgId)" }
    var permalink: String { "https://t.me/\(channel)/\(msgId)" }
    /// Domains of every outgoing link (text links, buttons, preview).
    var linkDomains: [String] {
        (links + buttons.map(\.url) + [preview?.url ?? ""]).compactMap { URL(string: $0)?.host?.lowercased() }
    }
    /// Bot deep links (`t.me/<bot>?start=<payload>`) found in the post.
    var botLinks: [TGBotLink] { (links + buttons.map(\.url)).compactMap(TGBotLink.init(url:)) }
}

/// `https://t.me/somebot?start=payload`. Opening it as the user needs TDLib (sendBotStartMessage);
/// without a TDLib session the app only offers 「在 Telegram 中打开」.
struct TGBotLink: Hashable, Codable {
    var bot: String
    var payload: String
    init?(url: String) {
        guard let c = URLComponents(string: url), let h = c.host?.lowercased(), h == "t.me" || h == "telegram.me",
              let start = c.queryItems?.first(where: { $0.name == "start" })?.value else { return nil }
        let name = c.path.split(separator: "/").first.map(String.init) ?? ""
        guard name.lowercased().hasSuffix("bot") else { return nil }
        bot = name; payload = start
    }
    var tgURL: URL? { URL(string: "tg://resolve?domain=\(bot)&start=\(payload)") }
    var webURL: URL? { URL(string: "https://t.me/\(bot)?start=\(payload)") }
}

struct TGChannelPage {
    var info: TGChannel?
    var posts: [TGPost]
    /// `?before=` cursor for the next (older) page; nil at the start of the channel.
    var before: Int?
}

enum TGError: LocalizedError {
    case previewDisabled(String, String)
    case http(Int)
    case notPublic(String)
    var errorDescription: String? {
        switch self {
        case .previewDisabled(let c, let why): "@\(c) 的网页预览不可用（\(why)）。只能登录 TDLib 后读取，或「在 Telegram 中打开」。"
        case .http(let c): "Telegram 网页预览 HTTP \(c)"
        case .notPublic(let c): "@\(c) 不是公开频道（t.me/s 跳回频道主页）"
        }
    }
}
