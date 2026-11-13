import Foundation

/// MissAV — list cards are server-rendered; the playlist sits in a p,a,c,k,e,d packed script.
/// Parsing is a port of UAV-Downloader `sites/missav.py` (Apache-2.0). The mirror probing, the
/// `surrit.mrstcdn.store` / `fourhoi.mrstcdn.store` hosts and the endpoint list follow the public
/// behaviour of those sites (as also used by the "MissAV_TuT" Forward widget); no code is copied from it.
struct MissAVProvider: SiteProvider {
    let source = DramaSource.missav
    /// Probe order. `.fans` / `.media` currently answer without Cloudflare; the classic domains are kept as fallbacks.
    static let mirrors = ["https://missav.fans", "https://missav.media", "https://missav.ai", "https://missav.ws", "https://missav.live"]
    /// iPhone Safari UA the mirrors serve plain HTML to (also used by the verify sheet so `cf_clearance` matches).
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    static let probePath = "/dm539/cn/new"
    /// Video CDN that is reachable without Cloudflare (surrit.com is CF-gated).
    static let videoHost = "surrit.mrstcdn.store"
    static let coverHosts = ["fourhoi.mrstcdn.store", "fourhoi.com"]

    /// Simplified-Chinese listing paths (`/dmNNN/cn/slug`); `sort=` is the site's own ordering parameter.
    let categories: [SiteCategory] = [
        .init(id: "today-hot", title: "今日热门", path: "/dm298/cn/today-hot", isRank: true),
        .init(id: "weekly-hot", title: "本周热门", path: "/dm170/cn/weekly-hot", isRank: true),
        .init(id: "monthly-hot", title: "月度热门", path: "/dm266/cn/monthly-hot", isRank: true),
        .init(id: "chinese-subtitle", title: "中文字幕", path: "/dm278/cn/chinese-subtitle?sort=released_at"),
        .init(id: "chinese-subtitle-week", title: "中文字幕 · 本周最多看", path: "/dm278/cn/chinese-subtitle?sort=weekly_views", isRank: true),
        .init(id: "release", title: "最新发布", path: "/dm632/cn/release?sort=released_at"),
        .init(id: "new", title: "最近更新", path: "/dm539/cn/new"),
        .init(id: "uncensored-leak", title: "无码流出", path: "/dm816/cn/uncensored-leak?sort=released_at"),
        .init(id: "fc2", title: "FC2", path: "/dm473/cn/fc2?sort=released_at"),
        .init(id: "siro", title: "SIRO 素人", path: "/dm36/cn/siro?sort=released_at"),
        .init(id: "madou", title: "麻豆", path: "/dm63/cn/madou?sort=released_at"),
    ]

    static var headers: [String: String] { ["User-Agent": DramaSource.missav.userAgent, "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6"] }

    static func pageURL(_ path: String, page: Int) -> String {
        guard page > 1 else { return path }
        return path + (path.contains("?") ? "&" : "?") + "page=\(page)"
    }

    /// GET on the probed mirror; if it stops answering (or turns into a challenge) re-probe once.
    private func get(_ path: String, ttl: TimeInterval = 120) async throws -> SiteHTTP.Response {
        let base = try await MissAVSite.shared.current()
        do {
            return try await SiteHTTP.shared.get(source, mirrors: [base], path: path, headers: Self.headers, ttl: ttl)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let next = try await MissAVSite.shared.current(invalidating: base)
            guard next != base else { throw error }
            return try await SiteHTTP.shared.get(source, mirrors: [next], path: path, headers: Self.headers, ttl: ttl)
        }
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        let r = try await get(Self.pageURL(c.path, page: page))
        return Self.parseList(r.text, base: r.base, page: page)
    }

    func search(_ q: String, page: Int) async throws -> HGPage {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        let r = try await get(Self.pageURL("/cn/search/\(enc)", page: page))
        return Self.parseList(r.text, base: r.base, page: page)
    }

    /// Prefer the CF-free cover host; rebuild from the video id when the card only has a placeholder.
    static func cover(_ raw: String?, id: String, kind: String = "cover-t") -> String {
        var u = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if u.hasPrefix("data:") || u.isEmpty || u.hasSuffix(".mp4") { u = "" }
        if u.contains("//fourhoi.com/") { u = u.replacingOccurrences(of: "//fourhoi.com/", with: "//\(coverHosts[0])/") }
        if u.isEmpty, !id.isEmpty { u = "https://\(coverHosts[0])/\(id.lowercased())/\(kind).jpg" }
        return u
    }

    static func parseList(_ h: String, base: String, page: Int) -> HGPage {
        var items: [HGSeries] = []
        var seen = Set<String>()
        let chunks = h.components(separatedBy: "class=\"thumbnail").dropFirst()
        for chunk in chunks {
            let card = String(chunk.prefix(6000))
            guard let href = HTML.groups("<a\\s+href=\"([^\"]+)\"", card)?[1] else { continue }
            let url = HTML.resolve(base, href)
            guard !url.contains("/search/"), let slug = URL(string: url)?.lastPathComponent,
                  slug.rangeOfCharacter(from: .decimalDigits) != nil, seen.insert(slug).inserted else { continue }
            let img = HTML.groups("<img[^>]*?data-src=\"([^\"]+)\"", card)?[1] ?? HTML.groups("<img[^>]*?\\ssrc=\"(https?[^\"]+)\"", card)?[1]
            var title = HTML.groups("<div class=\"my-2[^\"]*\">\\s*<a[^>]*>(.*?)</a>", card).map { HTML.cleanText($0[1]) } ?? ""
            if title.isEmpty { title = HTML.groups("<img[^>]*?alt=\"([^\"]*)\"", card).map { HTML.unescape($0[1]) } ?? slug.uppercased() }
            let dur = HTML.groups("bottom-1 right-1[^\"]*\">\\s*([0-9:]+)\\s*<", card).map { SiteParse.clock($0[1]) } ?? 0
            items.append(HGSeries(source: .missav, seriesId: slug, title: title, cover: cover(img, id: slug),
                                  subtitle: SiteParse.code(title) ?? slug.uppercased(), duration: dur,
                                  orientation: "landscape", page: url))
        }
        let more = h.contains("page=\(page + 1)")
        return HGPage(items: items, hasMore: !items.isEmpty && more, nextOffset: page + 1)
    }

    private func page(_ s: HGSeries) async throws -> SiteHTTP.Response {
        // Stored URLs may point at an older mirror; only the path is reused.
        let path = s.page.flatMap(HTML.sitePath) ?? "/cn/\(s.seriesId)"
        return try await get(path, ttl: 600)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await page(s)
        return Self.parseDetail(r.text, series: s, url: r.url)
    }

    static func field(_ h: String, _ labels: String) -> String? {
        HTML.groups("<span>(?:\(labels)):</span>(.*?)</div>", h).map { $0[1] }
    }

    static func parseDetail(_ h: String, series s: HGSeries, url: String) -> HGSeriesDetail {
        let title = HTML.groups("og:title\"\\s+content=\"([^\"]+)\"", h).map { HTML.unescape($0[1]) } ?? s.title
        let cover = cover(HTML.groups("og:image\"\\s+content=\"([^\"]+)\"", h)?[1], id: s.seriesId, kind: "cover-n")
        let date = HTML.groups("<time datetime=\"[^\"]*\"[^>]*>([^<]+)</time>", h)?[1] ?? ""
        let code = field(h, "番號|番号").map(HTML.cleanText) ?? SiteParse.code(title) ?? ""
        let actors = field(h, "女優|女优").map { HTML.all("<a[^>]*>([^<]+)</a>", $0).map { HTML.cleanText($0[1]) } } ?? []
        let tags = field(h, "類型|类型").map { HTML.all("<a[^>]*>([^<]+)</a>", $0).map { HTML.cleanText($0[1]) } } ?? []
        let maker = field(h, "發行商|发行商").map(HTML.cleanText)
        let desc = HTML.groups("og:description\"\\s+content=\"([^\"]*)\"", h).map { HTML.unescape($0[1]) } ?? ""
        let meta = [code.isEmpty ? nil : "番号 \(code)", date.isEmpty ? nil : "发行 \(date)"].compactMap { $0 }.joined(separator: " · ")
        return HGSeriesDetail(source: .missav, seriesId: s.seriesId, title: title, cover: cover,
                              desc: [meta, desc].filter { !$0.isEmpty }.joined(separator: "\n"),
                              author: maker, actors: actors, onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: s.duration),
                              tags: Array(tags.prefix(16)), episodeLabel: s.duration > 0 ? Fmt.clock(s.duration) : "长视频")
    }

    /// Video UUID from the unpacked player script (`https://surrit.<host>/<uuid>/playlist.m3u8`).
    static func videoUUID(_ h: String) -> String? {
        let uuid = "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
        for js in JSUnpacker.unpackedScripts(h) {
            if let m = HTML.groups("https?://surrit\\.[a-z0-9.]+/\(uuid)/", js) { return m[1].lowercased() }
        }
        return HTML.groups("surrit\\.[a-z0-9.]+/\(uuid)/", h)?[1].lowercased()
    }

    static func isPlaylist(_ text: String) -> Bool {
        text.contains("#EXTM3U") && (text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-TARGETDURATION"))
    }

    /// 1080P/720P/480P/360P variants that actually answer on surrit.mrstcdn.store, plus the master as 自动.
    static func streams(uuid: String, site: String) async -> [HGStream] {
        let hdr = ["Referer": site + "/", "Origin": site, "User-Agent": DramaSource.missav.userAgent]
        let root = "https://\(videoHost)/\(uuid)"
        let fixed = [1080, 720, 480, 360]
        let probes: [(Int, String)] = [(0, "\(root)/playlist.m3u8")] + fixed.map { ($0, "\(root)/\($0)p/video.m3u8") }
        var ok: [Int: String] = [:]
        var master = ""
        await withTaskGroup(of: (Int, String, String?).self) { g in
            for (height, url) in probes {
                g.addTask {
                    let t = try? await SiteHTTP.shared.probe(url, headers: hdr, timeout: 6)
                    return (height, url, t)
                }
            }
            for await (height, url, text) in g {
                guard let text, isPlaylist(text) else { continue }
                if height == 0 { master = text } else { ok[height] = url }
            }
        }
        // Heights listed in the master but not in the fixed probe set (e.g. 540p) are trusted from the master.
        if !master.isEmpty, let base = URL(string: "\(root)/playlist.m3u8") {
            for v in HLSPlaylist.variants(master, base.absoluteString) {
                let height = v.height
                guard height > 0, ok[height] == nil, !fixed.contains(height) else { continue }
                ok[height] = v.url
            }
        }
        var out = ok.keys.sorted(by: >).map { h in
            HGStream(streamId: "missav-\(h)p", quality: "\(h)P", url: ok[h]!, key: "", height: h, kind: .hls, headers: hdr)
        }
        if !master.isEmpty {
            out.append(HGStream(streamId: "missav-auto", quality: "自动", url: "\(root)/playlist.m3u8", key: "", kind: .hls, headers: hdr))
        }
        return out
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let r = try await page(s)
        guard let uuid = Self.videoUUID(r.text) else { throw SiteError.parse("MissAV 页面里没有找到视频 ID（打包脚本可能已改版）") }
        let list = await Self.streams(uuid: uuid, site: r.base)
        guard let first = list.first else { throw ProviderError.upstream("MissAV 视频 CDN（\(Self.videoHost)）无响应") }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: list)
    }
}

/// ensureSite: probe mirrors in order, keep the first that serves a real list page (not a challenge).
/// The pick is cached in memory and in UserDefaults; Cloudflare is only surfaced when every mirror is behind it.
actor MissAVSite {
    static let shared = MissAVSite()
    private static let key = "stv.missav.site"
    private var picked: String? = UserDefaults.standard.string(forKey: key).flatMap { MissAVProvider.mirrors.contains($0) ? $0 : nil }
    private var probing: Task<ProbeResult, Error>?
    /// Last probe result per mirror, for 片源管理 / debugging.
    private(set) var report: [String: String] = [:]

    static func looksLikeList(_ html: String) -> Bool {
        guard !isChallenge(html) else { return false }
        return html.contains("thumbnail") || html.contains("text-secondary") || html.contains("fourhoi") || html.contains("surrit")
    }

    static func isChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        let hasCards = lower.contains("thumbnail") || lower.contains("text-secondary") || lower.contains("surrit")
        if hasCards && html.count > 12_000 { return false }   // real pages also embed cdn-cgi/challenge scripts
        if CFDetect.isChallengeTitle(CFDetect.title(html)) { return true }
        let human = lower.contains("verify you are human") || lower.contains("performing security verification")
            || lower.contains("checking your browser") || lower.contains("cf-browser-verification")
        return human && html.count < 20_000
    }

    /// After a Cloudflare pass: forget the pick so the next request re-probes with the new cookies/UA
    /// (the verified mirror may differ from the cached one).
    func reset() async {
        picked = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        await SiteHTTP.shared.clearPreferred()
    }

    func current(invalidating bad: String? = nil) async throws -> String {
        if let bad, picked == bad { picked = nil; UserDefaults.standard.removeObject(forKey: Self.key); await SiteHTTP.shared.clearPreferred() }
        if let picked { return picked }
        if let probing { return try await probing.value.site }
        let t = Task { try await Self.probeAll() }
        probing = t
        defer { probing = nil }
        let result = try await t.value
        report = result.report
        let site = result.site
        picked = site
        UserDefaults.standard.set(site, forKey: Self.key)
        return site
    }

    private static func probeAll(solved: Bool = false) async throws -> ProbeResult {
        var rep: [String: String] = [:]
        var challenged: String?
        for base in MissAVProvider.mirrors {
            let url = base + MissAVProvider.probePath
            do {
                let (text, status, hdrs) = try await SiteHTTP.shared.raw(url, referer: base + "/", headers: MissAVProvider.headers)
                if (200..<300).contains(status), looksLikeList(text) {
                    rep[base] = "OK"
                    SiteLog.add("[MissAV] 选中镜像 \(base)")
                    return ProbeResult(site: base, report: rep)
                }
                if isChallenge(text) || SiteHTTP.looksLikeChallenge(status: status, headers: hdrs, body: text) {
                    rep[base] = "Cloudflare \(status)"
                    SiteLog.add("[MissAV] 探测 \(base) → Cloudflare \(status) · cookies \(CFCookies.names(for: url).joined(separator: ","))")
                    challenged = challenged ?? url
                } else {
                    rep[base] = "HTTP \(status)"
                }
            } catch {
                SiteLog.add("[MissAV] 探测 \(base) → \(error.localizedDescription)")
                rep[base] = (error as? URLError).map { "网络错误 \($0.code.rawValue)" } ?? error.localizedDescription
            }
        }
        if let challenged {
            if !solved, await CFSolverHook.solve(.missav, challenged) { return try await probeAll(solved: true) }
            throw SiteError.needsVerification(.missav, challenged)
        }
        throw ProviderError.upstream("MissAV 所有镜像均不可用：" + MissAVProvider.mirrors.map { "\(URL(string: $0)?.host ?? $0) \(rep[$0] ?? "-")" }.joined(separator: "；"))
    }

    struct ProbeResult: Sendable {
        let site: String
        let report: [String: String]
    }
}
