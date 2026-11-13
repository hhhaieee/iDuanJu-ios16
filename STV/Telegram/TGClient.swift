import Foundation

/// Reads public channels through Telegram's web preview. No account, no API keys.
/// `base` can point at a user-configured reverse proxy of t.me (same paths) for networks where t.me is blocked.
actor TGClient {
    static let shared = TGClient()
    static let baseKey = "stv.tg.base"
    static let defaultBase = "https://t.me"
    static var base: String {
        let b = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? defaultBase : (b.hasSuffix("/") ? String(b.dropLast()) : b)
    }
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    /// Newest page (before == nil) or older posts before a message id; `query` uses the preview's search.
    func page(_ channel: String, before: Int? = nil, query: String? = nil) async throws -> TGChannelPage {
        #if DEBUG
        if let p = try Self.fixturePage(channel, before: before, query: query) { return p }
        #endif
        var c = URLComponents(string: Self.base + "/s/" + channel)!
        var q: [URLQueryItem] = []
        if let query, !query.isEmpty { q.append(URLQueryItem(name: "q", value: query)) }
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        c.queryItems = q.isEmpty ? nil : q
        let (html, final) = try await get(c.url!)
        if !final.path.hasPrefix("/s/") {
            // t.me/s redirected to the landing page: preview disabled for this channel.
            let why = await restrictionReason(channel) ?? "频道关闭了网页预览或不是公开频道"
            throw TGError.previewDisabled(channel, why)
        }
        return TGParser.page(html, channel: channel)
    }

    /// Landing page info (title / subscribers) — works even when the preview is disabled.
    func landing(_ channel: String) async throws -> TGChannel {
        let (html, _) = try await get(URL(string: Self.base + "/" + channel)!)
        return TGParser.landing(html, channel: channel)
    }

    /// Telegram shows the restriction reason on single-message embeds.
    func restrictionReason(_ channel: String) async -> String? {
        guard let u = URL(string: Self.base + "/\(channel)/1?embed=1&mode=tme"), let (html, _) = try? await get(u) else { return nil }
        guard let e = TGParser.embedError(html) else { return nil }
        if e.contains("pornographic") { return "Telegram 因色情内容限制了该频道的网页显示" }
        if e.lowercased().contains("not found") || e.contains("isn’t accessible") { return nil }
        return e
    }

    /// Fresh copy of one post (video URLs carry an expiring token).
    func post(_ channel: String, _ id: Int) async throws -> TGPost? {
        let p = try await page(channel, before: id + 1)
        return p.posts.first { $0.msgId == id }
    }

    private func get(_ url: URL) async throws -> (String, URL) {
        var r = URLRequest(url: url)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TGError.http(code) }
        return (String(decoding: data, as: UTF8.self), resp.url ?? url)
    }

    #if DEBUG
    /// DEBUG `STV_TG_FIXTURE_DIR=<dir>`: serve `tg_<channel>.html` (newest) / `tg_<channel>_older.html` (any `before`)
    /// so UI tests and screenshots run without network. Search filters the fixture locally.
    static func fixturePage(_ channel: String, before: Int?, query: String?) throws -> TGChannelPage? {
        guard let dir = ProcessInfo.processInfo.environment["STV_TG_FIXTURE_DIR"], !dir.isEmpty else { return nil }
        let name = before == nil ? "tg_\(channel.lowercased()).html" : "tg_\(channel.lowercased())_older.html"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            if before != nil { return TGChannelPage(info: nil, posts: [], before: nil) }
            throw TGError.previewDisabled(channel, "fixture 不存在")
        }
        var p = TGParser.page(html, channel: channel)
        if before != nil { p.before = nil }
        if let query, !query.isEmpty { p.posts = p.posts.filter { $0.text.localizedCaseInsensitiveContains(query) }; p.before = nil }
        return p
    }
    #endif
}
