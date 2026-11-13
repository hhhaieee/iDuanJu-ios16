import Foundation

/// Hanime1 — listing via `/search?sort=…&genre=…`, signed progressive MP4 `<source size=…>` on the watch page.
/// Port of UAV-Downloader `sites/hanime1.py` (Apache-2.0). Homepage is visited once to obtain session cookies.
struct Hanime1Provider: SiteProvider {
    let source = DramaSource.hanime1
    static let mirrors = ["https://hanime1.me"]

    static func q(_ pairs: [(String, String)]) -> String {
        var c = URLComponents()
        c.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return "/search?" + (c.percentEncodedQuery ?? "")
    }

    let categories: [SiteCategory] = [
        .init(id: "new-release", title: "最新上市", path: q([("sort", "最新上市")])),
        .init(id: "new-upload", title: "最新上传", path: q([("sort", "最新上傳")])),
        .init(id: "day", title: "本日排行", path: q([("sort", "本日排行")]), isRank: true),
        .init(id: "week", title: "本周排行", path: q([("sort", "本週排行")]), isRank: true),
        .init(id: "month", title: "本月排行", path: q([("sort", "本月排行")]), isRank: true),
        .init(id: "watching", title: "他们在看", path: q([("sort", "他們在看")])),
        .init(id: "hentai", title: "里番", path: q([("genre", "裏番"), ("sort", "最新上市")])),
        .init(id: "short", title: "泡面番", path: q([("genre", "泡麵番"), ("sort", "最新上市")])),
        .init(id: "3dcg", title: "3DCG", path: q([("genre", "3DCG"), ("sort", "最新上市")])),
        .init(id: "zh-sub", title: "中文字幕", path: q([("tags[]", "中文字幕"), ("sort", "最新上市")])),
    ]

    private static let primer = Primer()
    actor Primer {
        private var done = false
        func prime() async {
            guard !done else { return }
            done = true
            _ = try? await SiteHTTP.shared.get(.hanime1, mirrors: Hanime1Provider.mirrors, path: "/", ttl: 0)
        }
    }

    static func pageURL(_ path: String, page: Int) -> String {
        page > 1 ? path + (path.contains("?") ? "&" : "?") + "page=\(page)" : path
    }

    private func get(_ path: String, ttl: TimeInterval = 120) async throws -> SiteHTTP.Response {
        await Self.primer.prime()
        return try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: path, headers: ["Referer": "https://hanime1.me/"], ttl: ttl)
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        let r = try await get(Self.pageURL(c.path, page: page))
        return Self.parseList(r.text, base: r.base, page: page)
    }

    func search(_ text: String, page: Int) async throws -> HGPage {
        let r = try await get(Self.pageURL(Self.q([("query", text)]), page: page))
        return Self.parseList(r.text, base: r.base, page: page)
    }

    static func parseList(_ h: String, base: String, page: Int) -> HGPage {
        var items: [HGSeries] = []
        var seen = Set<String>()
        for chunk in h.components(separatedBy: "class=\"video-item-container\"").dropFirst() {
            let card = String(chunk.prefix(4000))
            guard let m = HTML.groups("href=\"([^\"]*/watch\\?v=(\\d+))\"", card), seen.insert(m[2]).inserted else { continue }
            let title = HTML.groups("<div class=\"title\">(.*?)</div>", card).map { HTML.cleanText($0[1]) } ?? ""
            let cover = HTML.groups("<img[^>]*class=\"main-thumb\"[^>]*src=\"([^\"]+)\"", card).map { HTML.unescape($0[1]) } ?? ""
            let dur = HTML.groups("<div class=\"duration\">\\s*([0-9:]+)", card).map { SiteParse.clock($0[1]) } ?? 0
            let author = HTML.groups("<div class=\"subtitle\">\\s*<a[^>]*>(.*?)</a>", card).map { HTML.cleanText($0[1]) }
            items.append(HGSeries(source: .hanime1, seriesId: m[2], title: title.isEmpty ? "#\(m[2])" : title, cover: cover,
                                  subtitle: author, author: author, duration: dur, orientation: "landscape",
                                  page: "https://hanime1.me/watch?v=\(m[2])"))
        }
        // 裏番 / 泡麵番 compact portrait cover grid. 2026-11: the card class gained extra tokens
        // ("home-rows-videos-div search-videos hover-lighter"), so match the class as a prefix.
        for m in HTML.all("<a[^>]*href=\"([^\"]*/watch\\?v=(\\d+))\"[^>]*>\\s*<div class=\"home-rows-videos-div search-videos[^\"]*\"(.*?)</a>", h)
        where seen.insert(m[2]).inserted {
            let title = HTML.groups("home-rows-videos-title\"[^>]*>(.*?)</div>", m[3]).map { HTML.cleanText($0[1]) } ?? ""
            guard !title.isEmpty else { continue }
            let cover = HTML.groups("<img[^>]*?(?:data-src|src)=\"([^\"]+)\"", m[3]).map { HTML.unescape($0[1]) } ?? ""
            items.append(HGSeries(source: .hanime1, seriesId: m[2], title: title, cover: cover, orientation: "portrait",
                                  page: "https://hanime1.me/watch?v=\(m[2])"))
        }
        return HGPage(items: items, hasMore: !items.isEmpty && h.contains("page=\(page + 1)"), nextOffset: page + 1)
    }

    private func watch(_ s: HGSeries) async throws -> SiteHTTP.Response {
        try await get("/watch?v=\(s.seriesId)", ttl: 300)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await watch(s)
        return Self.parseDetail(r.text, series: s, url: r.url)
    }

    static func parseDetail(_ h: String, series s: HGSeries, url: String) -> HGSeriesDetail {
        var title = HTML.groups("<h3[^>]*class=\"video-details-wrapper\"[^>]*>(.*?)</h3>", h).map { HTML.cleanText($0[1]) } ?? ""
        if title.isEmpty { title = HTML.replace("\\s+-\\s+Hanime1\\.me\\s*$", HTML.pageTitle(h), "") }
        let cover = HTML.ogImage(h).nonEmptyOr(HTML.groups("<video[^>]*poster=\"([^\"]+)\"", h)?[1] ?? s.cover)
        let dur = HTML.groups("og:video:duration\"\\s+content=\"(\\d+)\"", h).flatMap { Int($0[1]) } ?? s.duration
        let info = HTML.groups("觀看次數：([^<]+)</div>", h).map { HTML.cleanText($0[1]) } ?? ""
        var tags: [String] = []
        for m in HTML.all("class=\"single-video-tag\"[^>]*>\\s*<a[^>]*>(.*?)</a>", h) where !m[1].contains("material-icons") {
            let t = HTML.replace("\\(\\d+\\)\\s*$", HTML.cleanText(m[1]).replacingOccurrences(of: "#", with: ""), "")
                .trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !tags.contains(t) { tags.append(t) }
        }
        let desc = HTML.description(h)
        return HGSeriesDetail(source: .hanime1, seriesId: s.seriesId, title: title.isEmpty ? s.title : title, cover: cover,
                              desc: [info.isEmpty ? nil : "观看 " + info, desc.isEmpty ? nil : desc].compactMap { $0 }.joined(separator: "\n"),
                              author: s.author, actors: [], onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: dur),
                              tags: Array(tags.prefix(16)),
                              episodeLabel: dur > 0 ? Fmt.clock(dur) : "长视频")
    }

    /// Signed MP4s, highest first. Referer must be the watch page.
    static func streams(_ h: String, page: String) -> [HGStream] {
        let hdr = ["Referer": page, "User-Agent": DramaSource.hanime1.userAgent]
        var seen = Set<String>()
        var out: [(Int, HGStream)] = []
        for m in HTML.all("<source\\b([^>]*)>", h) {
            let src = HTML.attr(m[1], "src").replacingOccurrences(of: "\\/", with: "/")
            guard src.hasPrefix("https://"), src.lowercased().contains(".mp4"), seen.insert(src).inserted else { continue }
            let height = Int(HTML.attr(m[1], "size")) ?? HTML.groups("(\\d{3,4})p", src).flatMap { Int($0[1]) } ?? 0
            out.append((height, HGStream(streamId: "h1-\(height)", quality: height > 0 ? "\(height)p" : "MP4", url: src, key: "",
                                         height: height > 0 ? height : nil, kind: .mp4Clear, headers: hdr)))
        }
        return out.sorted { $0.0 > $1.0 }.map(\.1)
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let r = try await watch(s)
        let list = Self.streams(r.text, page: r.url)
        guard let first = list.first else { throw SiteError.parse("Hanime1 页面里没有找到 MP4 源") }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: list)
    }
}
