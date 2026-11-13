import Foundation

// Multi-source long-video sites (MissAV / Jable / SupJav / Hanime1).
// Site parsing is ported from UAV-Downloader (Apache-2.0, https://github.com/Alos21750/UAV-Downloader);
// see 我的 → 片源管理 → 开源许可.

extension DramaSource {
    /// Long-form single-video sites: no episodes, landscape player, "播放源" instead of "选集".
    var isLongVideo: Bool { self != .hongguo && self != .huangguo }
    /// Hidden until enabled in 片源管理 (and optionally behind Face ID).
    /// Telegram channel videos play in the long-video player but are not a 片源管理 site
    /// (adult channels are gated per channel by `SourceGate.showAdultChannels`).
    var isAdult: Bool {
        if let p = pluginID { return PluginStore.snapshot(p)?.manifest.adult ?? true }
        if let k = cmsKey { return CMSStore.site(k)?.adult ?? true }
        return isLongVideo && self != .telegram
    }
    var isBuiltin: Bool { !isAdult }
    /// MissAV mirrors want the iPhone Safari UA; the verify sheet must use the same one for `cf_clearance`.
    /// After a Cloudflare pass this is the verify WebView's own `navigator.userAgent` (cf_clearance is bound to it).
    var userAgent: String { SiteUA.learned(self) ?? (self == .missav ? MissAVProvider.userAgent : isTube ? TubeFmt.desktopUA : SiteHTTP.userAgent) }
    /// Mainstream tube sites (desktop pages carry the HLS master).
    var isTube: Bool { [.eporner, .xvideos, .xnxx, .pornhub].contains(self) }
    /// MissAV exposes resolutions of one stream (画质); the others expose alternative servers (播放源).
    var streamSectionTitle: String { self == .missav ? "画质" : "播放源" }
    var siteHost: String {
        switch self {
        case .hongguo: "hongguo"
        case .huangguo: "huangguo"
        case .jable: "jable.tv"
        case .missav: "missav.ai"
        case .hanime1: "hanime1.me"
        case .supjav: "supjav.com"
        case .eporner: "eporner.com"
        case .xvideos: "xvideos.com"
        case .xnxx: "xnxx.com"
        case .pornhub: "pornhub.com"
        case .telegram: "t.me"
        default:
            if let p = pluginID { PluginStore.snapshot(p)?.manifest.httpDomains.first ?? p }
            else if let k = cmsKey { URL(string: CMSStore.site(k)?.api ?? "")?.host ?? k }
            else { rawValue }
        }
    }
}

/// One browsable list on a site (最近更新 / 今日热门 / 某分类 …).
struct SiteCategory: Hashable, Identifiable {
    let id: String
    let title: String
    /// Path (or full query) relative to the site root, without the paging parameter.
    let path: String
    var isRank = false
}

protocol SiteProvider: Sendable {
    var source: DramaSource { get }
    var categories: [SiteCategory] { get }
    func list(_ c: SiteCategory, page: Int) async throws -> HGPage
    func search(_ q: String, page: Int) async throws -> HGPage
    func detail(_ s: HGSeries) async throws -> HGSeriesDetail
    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo
}

enum Sites {
    static let builtinSites: [DramaSource] = [.jable, .missav, .hanime1, .supjav, .eporner, .xvideos, .xnxx, .pornhub]
    /// Built-in sites + enabled video plugins + 采集站.
    static var all: [DramaSource] { builtinSites + PluginStore.videoSources() + CMSStore.sources() }
    static func provider(_ s: DramaSource) -> SiteProvider? {
        if s.pluginID != nil { return JSVideoProvider(source: s) }
        if let k = s.cmsKey { return CMSStore.site(k).map { MacCMSProvider(source: s, site: $0) } }
        let p: SiteProvider?
        switch s {
        case .jable: p = JableProvider()
        case .missav: p = MissAVProvider()
        case .hanime1: p = Hanime1Provider()
        case .supjav: p = SupJavProvider()
        case .eporner: p = EpornerProvider()
        case .xvideos, .xnxx: p = XVProvider(source: s)
        case .pornhub: p = PornhubProvider()
        case .telegram: p = TGVideoProvider()
        default: p = nil
        }
        return p
    }
}

/// Source the user picked on the detail page (播放源), honoured by `PlaybackCoordinator`.
@MainActor enum SitePrefs {
    static var preferredStream: [String: String] = [:]
}

enum SiteError: LocalizedError {
    /// Cloudflare (or similar) interstitial; needs a human pass in `SiteVerifySheet`.
    case needsVerification(DramaSource, String)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .needsVerification(let s, _): "\(s.label) 需要站点验证（Cloudflare）。点「去验证」在内置浏览器里完成一次验证后重试。"
        case .parse(let m): "解析失败：\(m)"
        }
    }
    var verification: (DramaSource, String)? {
        if case .needsVerification(let s, let u) = self { return (s, u) }
        return nil
    }
}

/// Shared HTTP for all sites: one cookie jar (shared with the verify web view), mirror rotation,
/// Cloudflare detection. Same UA is used by WKWebView so `cf_clearance` stays valid.
actor SiteHTTP {
    static let shared = SiteHTTP()
    static let userAgent = HuangguoClient.userAgent

    private let session: URLSession

    /// `protocolClasses` lets unit tests stub the network while keeping the real cookie jar.
    init(protocolClasses: [AnyClass]? = nil) {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpCookieStorage = .shared
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        if let protocolClasses { c.protocolClasses = protocolClasses + (c.protocolClasses ?? []) }
        session = URLSession(configuration: c)
    }
    private var preferred: [DramaSource: String] = [:]
    /// Sources whose pages only load through the WebView (URLSession fingerprint rejected).
    private var webFetch: Set<DramaSource> = []
    private var cache: [String: (Date, String)] = [:]

    struct Response { let base: String; let url: String; let text: String }

    static func looksLikeChallenge(status: Int, headers: [AnyHashable: Any], body: String) -> Bool {
        CFDetect.isChallenge(status: status, headers: headers, body: body)
    }

    /// GET `path` against each mirror until one answers with real content.
    func get(_ source: DramaSource, mirrors: [String], path: String, headers: [String: String] = [:], ttl: TimeInterval = 120) async throws -> Response {
        var headers = headers
        if headers["User-Agent"] == nil { headers["User-Agent"] = source.userAgent }
        var order = mirrors
        if let p = preferred[source], let i = order.firstIndex(of: p) { order.remove(at: i); order.insert(p, at: 0) }
        var challenge: String?
        var last: Error = ProviderError.upstream("\(source.label) 所有镜像均不可用")
        for base in order {
            let url = path.hasPrefix("http") ? path : base + path
            if let (t, s) = cache[url], Date().timeIntervalSince(t) < ttl { return Response(base: base, url: url, text: s) }
            if webFetch.contains(source), let text = await CFSolverHook.fetch(source, url),
               !Self.looksLikeChallenge(status: 200, headers: [:], body: text) {
                cache[url] = (Date(), text)
                return Response(base: base, url: url, text: text)
            }
            do {
                let (text, status, hdrs) = try await raw(url, referer: base + "/", headers: headers)
                if Self.looksLikeChallenge(status: status, headers: hdrs, body: text) {
                    SiteLog.add("[\(source.label)] CF \(status) \(url) · UA \(SiteLog.shortUA(headers["User-Agent"] ?? "")) · cookies \(CFCookies.names(for: url).joined(separator: ","))")
                    challenge = challenge ?? url
                    last = SiteError.needsVerification(source, url)
                    continue
                }
                guard (200..<300).contains(status) else { last = ProviderError.upstream("HTTP \(status)"); continue }
                preferred[source] = base
                cache[url] = (Date(), text)
                if cache.count > 80 { cache.removeAll() }
                return Response(base: base, url: url, text: text)
            } catch {
                last = error
            }
            if path.hasPrefix("http") { break }
        }
        if let challenge {
            if let r = await solveAndRetry(source, url: challenge, headers: headers) { return r }
            throw SiteError.needsVerification(source, challenge)
        }
        throw last
    }

    /// Non-interactive Cloudflare JS challenge: solve it in a hidden WKWebView, sync cookies + the
    /// WebView's UA, retry once with URLSession; if URLSession is still challenged (fingerprint),
    /// fetch the page through the WebView itself.
    func solveAndRetry(_ source: DramaSource, url: String, headers: [String: String]) async -> Response? {
        guard await CFSolverHook.solve(source, url) else { return nil }
        var h = headers
        h["User-Agent"] = source.userAgent
        let base = URL(string: url).map { "\($0.scheme ?? "https")://\($0.host ?? "")" } ?? ""
        if let (text, status, hdrs) = try? await raw(url, referer: base + "/", headers: h),
           (200..<300).contains(status), !Self.looksLikeChallenge(status: status, headers: hdrs, body: text) {
            SiteLog.add("[\(source.label)] 后台验证后 App 请求成功 \(url)")
            preferred[source] = base
            cache[url] = (Date(), text)
            return Response(base: base, url: url, text: text)
        }
        if let text = await CFSolverHook.fetch(source, url), !Self.looksLikeChallenge(status: 200, headers: [:], body: text) {
            SiteLog.add("[\(source.label)] URLSession 仍被拦，改用 WebView 取页面 \(url)")
            webFetch.insert(source)
            cache[url] = (Date(), text)
            return Response(base: base, url: url, text: text)
        }
        SiteLog.add("[\(source.label)] 后台验证后仍被拦截 \(url)")
        return nil
    }

    func raw(_ url: String, referer: String?, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> (String, Int, [AnyHashable: Any]) {
        if let fx = SiteFixtures.lookup(url) { return (fx, 200, [:]) }
        guard let u = URL(string: url) else { throw ProviderError.invalid("bad url \(url)") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        // Attach the jar explicitly (incl. cf_clearance synced from WebKit) and store Set-Cookie ourselves,
        // so cookie handling doesn't depend on URLSession's implicit behaviour.
        r.httpShouldHandleCookies = false
        if let jar = HTTPCookieStorage.shared.cookies(for: u), !jar.isEmpty {
            for (k, v) in HTTPCookie.requestHeaderFields(with: jar) { r.setValue(v, forHTTPHeaderField: k) }
        }
        let (d, resp) = try await session.data(for: r)
        let http = resp as? HTTPURLResponse
        if let http, let fields = http.allHeaderFields as? [String: String] {
            let set = HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? u)
            if !set.isEmpty { HTTPCookieStorage.shared.setCookies(set, for: http.url ?? u, mainDocumentURL: nil) }
        }
        return (String(decoding: d, as: UTF8.self), http?.statusCode ?? 0, http?.allHeaderFields ?? [:])
    }

    /// GET following redirects; returns the body and the final URL (SupJav's lk1 bounce → embed host).
    func fetchFollowing(_ url: String, referer: String?, headers: [String: String] = [:]) async throws -> (String, String) {
        guard let u = URL(string: url) else { throw ProviderError.invalid("bad url \(url)") }
        var r = URLRequest(url: u)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: r)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.upstream("HTTP \(status) · \(u.host ?? "")") }
        return (String(decoding: d, as: UTF8.self), http?.url?.absoluteString ?? url)
    }

    /// Short GET used for HLS reachability probes; nil body on non-2xx.
    func probe(_ url: String, headers: [String: String], timeout: TimeInterval) async throws -> String? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        return String(decoding: d.prefix(65_536), as: UTF8.self)
    }

    func clearPreferred() { preferred = [:]; cache = [:] }
}

/// DEBUG-only offline fixtures for simulator tests when the Mac cannot reach the sites:
/// `STV_SITE_FIXTURES=/abs/dir` → serves `<dir>/<url with non-alphanumerics as _>.html` when present.
enum SiteFixtures {
    static func key(_ url: String) -> String {
        String(url.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }) + ".html"
    }
    static func lookup(_ url: String) -> String? {
        #if DEBUG
        guard let dir = ProcessInfo.processInfo.environment["STV_SITE_FIXTURES"], !dir.isEmpty else { return nil }
        let p = (dir as NSString).appendingPathComponent(key(url))
        return try? String(contentsOfFile: p, encoding: .utf8)
        #else
        return nil
        #endif
    }
}

enum SiteParse {
    /// "2:00:12" / "57:03" → seconds.
    static func clock(_ s: String) -> Int {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
    /// "7 187" / "1.2萬" / "12K" → Int.
    static func count(_ s: String) -> Int {
        let t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "")
        if let m = HTML.groups("([0-9.]+)\\s*(萬|万|w|k)?", t), let v = Double(m[1]) {
            switch m[2].lowercased() { case "萬", "万", "w": return Int(v * 10_000); case "k": return Int(v * 1_000); default: return Int(v) }
        }
        return 0
    }
    /// Pull the leading 番号 (e.g. "SSIS-123") out of a title.
    static func code(_ title: String) -> String? {
        HTML.groups("^\\s*([A-Za-z]{2,6}-?\\d{2,5}(?:-[A-Za-z0-9]+)?)\\b", title).map { $0[1].uppercased() }
    }
    static func singleEpisode(_ s: HGSeries, page: String, duration: Int) -> [HGEpisode] {
        [HGEpisode(ep: 1, vid: s.seriesId, duration: duration, title: s.title, page: page)]
    }
}

/// Indirection so SiteKit (no WebKit import) can reach the WebKit-based solver; set up in `CFSolver`.
enum CFSolverHook {
    nonisolated(unsafe) static var solveImpl: (@Sendable (DramaSource, String) async -> Bool)?
    nonisolated(unsafe) static var fetchImpl: (@Sendable (DramaSource, String) async -> String?)?
    static func solve(_ s: DramaSource, _ url: String) async -> Bool { await solveImpl?(s, url) ?? false }
    static func fetch(_ s: DramaSource, _ url: String) async -> String? { await fetchImpl?(s, url) }
}
