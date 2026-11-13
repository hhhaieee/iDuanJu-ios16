import Foundation

/// Jable.TV — plain HLS (AES-128 key URI is public), list pages are server-rendered KVS templates.
/// Port of UAV-Downloader `sites/jabletv.py` (Apache-2.0) with regex instead of BeautifulSoup.
struct JableProvider: SiteProvider {
    let source = DramaSource.jable
    static let mirrors = ["https://jable.tv", "https://fs1.app"]

    let categories: [SiteCategory] = [
        .init(id: "latest", title: "最近更新", path: "/latest-updates/"),
        .init(id: "new", title: "新片上架", path: "/new-release/"),
        .init(id: "hot-today", title: "今日热门", path: "/hot/?sort_by=video_viewed_today", isRank: true),
        .init(id: "hot-week", title: "本周热门", path: "/hot/?sort_by=video_viewed_week", isRank: true),
        .init(id: "hot-month", title: "本月热门", path: "/hot/?sort_by=video_viewed_month", isRank: true),
        .init(id: "hot", title: "热门总榜", path: "/hot/", isRank: true),
        .init(id: "zh-sub", title: "中文字幕", path: "/categories/chinese-subtitle/"),
        .init(id: "uncensored", title: "无码", path: "/categories/uncensored/"),
    ]

    private var headers: [String: String] { ["Cookie": "kt_rt_lang=zh"] }

    static func pageURL(_ path: String, page: Int) -> String {
        guard page > 1 else { return path }
        return path + (path.contains("?") ? "&" : "?") + "from=\(page)"
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        let r = try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: Self.pageURL(c.path, page: page), headers: headers)
        return Self.parseList(r.text, base: r.base, page: page)
    }

    func search(_ q: String, page: Int) async throws -> HGPage {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let r = try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: Self.pageURL("/search/?q=\(enc)", page: page), headers: headers)
        return Self.parseList(r.text, base: r.base, page: page)
    }

    static func parseList(_ h: String, base: String, page: Int) -> HGPage {
        var items: [HGSeries] = []
        for m in HTML.all("<div class=\"video-img-box[^\"]*\">(.*?)<p class=\"sub-title\">(.*?)</p>", h) {
            let block = m[1]
            guard let link = HTML.groups("href=\"([^\"]*/videos/([^/\"]+)/?)\"", block) else { continue }
            let title = HTML.groups("<h6[^>]*>(.*?)</h6>", block).map { HTML.cleanText($0[1]) } ?? ""
            let dur = HTML.groups("<span class=\"label\">([^<]+)</span>", block).map { SiteParse.clock($0[1]) } ?? 0
            let views = HTML.groups("icon-eye\"></use></svg>([^<]+)<", m[2]).map { SiteParse.count(HTML.cleanText($0[1])) } ?? 0
            items.append(HGSeries(source: .jable, seriesId: link[2], title: title.isEmpty ? link[2].uppercased() : title,
                                  cover: HTML.resolve(base, HTML.attr(block, "data-src", "src")),
                                  subtitle: SiteParse.code(title), episodeCount: 0, duration: dur, playCount: views,
                                  orientation: "landscape", page: HTML.resolve(base, link[1])))
        }
        let maxFrom = HTML.all("from(?:_videos)?[:=]0*(\\d+)", h).compactMap { Int($0[1]) }.max() ?? 0
        return HGPage(items: items, hasMore: !items.isEmpty && maxFrom > page, nextOffset: page + 1)
    }

    private func page(_ s: HGSeries) async throws -> SiteHTTP.Response {
        let path = s.page.flatMap(HTML.sitePath) ?? "/videos/\(s.seriesId)/"
        return try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: path, headers: headers, ttl: 600)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await page(s)
        return Self.parseDetail(r.text, series: s, base: r.base, url: r.url)
    }

    static func parseDetail(_ h: String, series s: HGSeries, base: String, url: String) -> HGSeriesDetail {
        let title = HTML.groups("<h4>(.*?)</h4>", h).map { HTML.cleanText($0[1]) }.flatMap { $0.isEmpty ? nil : $0 } ?? HTML.pageTitle(h)
        let tags = HTML.all("<a class=\"tag[^\"]*\" href=\"[^\"]*/tags/[^\"]*\">([^<]+)</a>", h).map { HTML.cleanText($0[1]) }
        let models = HTML.groups("<div class=\"models\">(.*?)</div>", h).map { HTML.all("title=\"([^\"]+)\"", $0[1]).map { HTML.unescape($0[1]) } } ?? []
        let date = HTML.groups("上市於\\s*([0-9-]+)", h)?[1] ?? ""
        let views = HTML.groups("icon-eye\"></use></svg>\\s*<span[^>]*>([^<]+)</span>", h).map { SiteParse.count($0[1]) } ?? s.playCount
        let dur = s.duration
        var desc = [SiteParse.code(title).map { "番号 \($0)" }, date.isEmpty ? nil : "发行 \(date)"].compactMap { $0 }.joined(separator: " · ")
        if views > 0 { desc += (desc.isEmpty ? "" : " · ") + Fmt.count(views) + "次观看" }
        return HGSeriesDetail(source: .jable, seriesId: s.seriesId, title: title.isEmpty ? s.title : title,
                              cover: HTML.resolve(base, HTML.ogImage(h)).nonEmptyOr(s.cover), desc: desc,
                              author: nil, actors: models, onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: dur),
                              tags: Array(tags.prefix(16)), episodeLabel: dur > 0 ? Fmt.clock(dur) : "长视频")
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let r = try await page(s)
        guard let m = HTML.groups("hlsUrl\\s*=\\s*['\"]([^'\"]+\\.m3u8[^'\"]*)['\"]", r.text) else {
            throw SiteError.parse("Jable 页面里没有找到 hlsUrl")
        }
        let hdr = ["Referer": r.base + "/", "Origin": r.base, "User-Agent": DramaSource.jable.userAgent]
        let host = URL(string: r.base)?.host ?? "jable"
        let stream = HGStream(streamId: "jable-hls", quality: "\(host) · HLS", url: m[1], key: "", kind: .hls, headers: hdr)
        return HGResolvedVideo(vid: s.seriesId, url: m[1], key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: [stream])
    }
}

extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
