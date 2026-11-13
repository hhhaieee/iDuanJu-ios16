import Foundation

// Mainstream adult tube sites (Eporner / XVideos / XNXX / Pornhub). All opt-in (片源管理, default off).
// Page structures / endpoints were cross-checked against yt-dlp's extractors (The Unlicense, public domain);
// the Swift code here is an independent regex implementation. See THIRD_PARTY_NOTICES.md.

/// Paged path: "first|template" — `{p}` = page, `{p0}` = page − 1. A path without "|" is used for every page.
enum TubePath {
    static func url(_ path: String, page: Int) -> String {
        let parts = path.components(separatedBy: "|")
        let tpl = page <= 1 ? parts[0] : (parts.count > 1 ? parts[1] : parts[0])
        return tpl.replacingOccurrences(of: "{p0}", with: "\(max(0, page - 1))").replacingOccurrences(of: "{p}", with: "\(max(1, page))")
    }
    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
    /// "/best/2026-10" style month listing (previous calendar month; the current one is still filling up).
    static func lastMonth(_ now: Date = Date()) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(byAdding: .month, value: -1, to: now) ?? now
        return String(format: "%04d-%02d", c.component(.year, from: d), c.component(.month, from: d))
    }
}

/// Listing hygiene for user-uploaded tube sites: drop titles that indicate minors or non-consensual content.
enum TubeSafety {
    static let blocked = ["underage", "under age", "minor ", "minors", "preteen", "pre-teen", "child", "kid ", "kids", "loli", "shota",
                          "schoolgirl", "school girl", "jailbait", "rape", "raped", "forced", "non-consensual", "nonconsensual", "non consent",
                          "drugged", "unconscious", "sleeping", "passed out", "hidden cam", "hidden camera", "spy cam", "upskirt",
                          "未成年", "幼女", "萝莉", "蘿莉", "中学生", "中學生", "小学生", "小學生", "强奸", "強姦", "强暴", "迷奸", "迷姦", "偷拍", "下药", "下藥"]
    static func allowed(_ title: String) -> Bool {
        let t = " " + title.lowercased() + " "
        return !blocked.contains { t.contains($0) }
    }
}

enum TubeFmt {
    /// "12 min" / "1 h 5 min" / "40 sec" / "16:41" → seconds.
    static func duration(_ s: String) -> Int {
        let t = HTML.cleanText(s)
        if t.contains(":") { return SiteParse.clock(t) }
        var sec = 0
        if let h = HTML.groups("(\\d+)\\s*h", t) { sec += (Int(h[1]) ?? 0) * 3600 }
        if let m = HTML.groups("(\\d+)\\s*min", t) { sec += (Int(m[1]) ?? 0) * 60 }
        if let x = HTML.groups("(\\d+)\\s*sec", t) { sec += Int(x[1]) ?? 0 }
        return sec
    }
    static func jsString(_ s: String) -> String { s.replacingOccurrences(of: "\\/", with: "/") }
    /// The `[...]` that follows `marker` (bracket-balanced, string-aware) — non-greedy regexes break on nested `[]`.
    static func balancedArray(after marker: String, in h: String) -> String? {
        guard let r = h.range(of: marker), let open = h[r.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0, inStr = false, esc = false
        var i = open
        while i < h.endIndex {
            let c = h[i]
            if inStr { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false } }
            else if c == "\"" { inStr = true }
            else if c == "[" { depth += 1 }
            else if c == "]" { depth -= 1; if depth == 0 { return String(h[open...i]) } }
            i = h.index(after: i)
        }
        return nil
    }
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
}

// MARK: - Eporner (public JSON API for lists/search/detail; /xhr/video for streams)

struct EpornerProvider: SiteProvider {
    let source = DramaSource.eporner
    static let mirrors = ["https://www.eporner.com"]
    static func api(_ query: String, order: String) -> String {
        "/api/v2/video/search/?query=\(query)&order=\(order)&per_page=30&page={p}&thumbsize=big&format=json"
    }
    let categories: [SiteCategory] = [
        .init(id: "latest", title: "最新上传", path: api("all", order: "latest")),
        .init(id: "week", title: "本周热门", path: api("all", order: "top-weekly"), isRank: true),
        .init(id: "month", title: "本月热门", path: api("all", order: "top-monthly"), isRank: true),
        .init(id: "popular", title: "最受欢迎", path: api("all", order: "most-popular"), isRank: true),
        .init(id: "rated", title: "好评最多", path: api("all", order: "top-rated")),
        .init(id: "hd", title: "高清 1080P", path: api("1080p", order: "latest")),
    ]
    private func get(_ path: String, ttl: TimeInterval = 120) async throws -> SiteHTTP.Response {
        try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: path, headers: ["User-Agent": TubeFmt.desktopUA, "Referer": "https://www.eporner.com/"], ttl: ttl)
    }
    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        Self.parseList(try await get(TubePath.url(c.path, page: page)).text, page: page)
    }
    func search(_ q: String, page: Int) async throws -> HGPage {
        Self.parseList(try await get(TubePath.url(Self.api(TubePath.q(q), order: "latest"), page: page)).text, page: page)
    }
    static func item(_ v: [String: Any]) -> HGSeries? {
        let id = J.str(v["id"]), title = HTML.unescape(J.str(v["title"]))
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }), TubeSafety.allowed(title) else { return nil }
        return HGSeries(source: .eporner, seriesId: id, title: title, cover: J.str(J.dict(v["default_thumb"])["src"]),
                        subtitle: J.str(v["added"]).prefix(10).description.nonEmpty, duration: J.int(v["length_sec"]),
                        playCount: J.int(v["views"]), orientation: "landscape",
                        tags: J.str(v["keywords"]).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(8).map { $0 },
                        page: J.str(v["url"]).nonEmpty ?? "https://www.eporner.com/video-\(id)/")
    }
    static func parseList(_ text: String, page: Int) -> HGPage {
        guard let o = try? J.parse(Data(text.utf8)) else { return HGPage(items: [], hasMore: false) }
        let items = J.arr(o["videos"]).compactMap { ($0 as? [String: Any]).flatMap(item) }
        return HGPage(items: items, hasMore: page < J.int(o["total_pages"]), nextOffset: page + 1)
    }
    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await get("/api/v2/video/id/?id=\(s.seriesId)&thumbsize=big&format=json", ttl: 600)
        let v = (try? J.parse(Data(r.text.utf8))) ?? [:]
        let it = Self.item(v) ?? s
        var desc = [it.subtitle.map { "上传 \($0)" }].compactMap { $0 }.joined()
        if it.playCount > 0 { desc += (desc.isEmpty ? "" : " · ") + Fmt.count(it.playCount) + "次观看" }
        return HGSeriesDetail(source: .eporner, seriesId: s.seriesId, title: it.title, cover: it.cover.nonEmptyOr(s.cover), desc: desc,
                              author: nil, actors: [], onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: it.page ?? "", duration: it.duration),
                              tags: it.tags, episodeLabel: it.duration > 0 ? Fmt.clock(it.duration) : "长视频")
    }
    /// yt-dlp eporner: each 8-hex chunk of the page hash → base36.
    static func xhrHash(_ h: String) -> String {
        guard h.count == 32 else { return "" }
        let a = Array(h)
        return stride(from: 0, to: 32, by: 8).map { String(UInt64(String(a[$0..<$0 + 8]), radix: 16) ?? 0, radix: 36) }.joined()
    }
    static func streams(_ text: String) -> [HGStream] {
        guard let o = try? J.parse(Data(text.utf8)) else { return [] }
        let hdr = ["Referer": "https://www.eporner.com/", "User-Agent": TubeFmt.desktopUA]
        let src = J.dict(o["sources"])
        var out: [HGStream] = []
        for (_, v) in J.dict(src["hls"]) { if let u = J.dict(v)["src"] as? String, u.hasPrefix("https://") {
            out.append(HGStream(streamId: "ep-hls", quality: "自动 · HLS", url: u, key: "", kind: .hls, headers: hdr)) } }
        let mp4 = J.dict(src["mp4"]).compactMap { (k, v) -> (Int, HGStream)? in
            guard let u = J.dict(v)["src"] as? String, u.hasPrefix("https://") else { return nil }
            let h = HTML.groups("(\\d{3,4})p", k).flatMap { Int($0[1]) } ?? 0
            return (h, HGStream(streamId: "ep-\(h)", quality: "\(h)p · MP4", url: u, key: "", height: h, kind: .mp4Clear, headers: hdr))
        }.sorted { $0.0 > $1.0 }.map(\.1)
        return out + mp4
    }
    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let page = try await get(ep.page ?? s.page ?? "https://www.eporner.com/video-\(s.seriesId)/", ttl: 60)
        guard let h = HTML.groups("EP\\.video\\.player\\.hash\\s*=\\s*'([0-9a-f]{32})'", page.text)?[1] ?? HTML.groups("hash\\s*:\\s*'([0-9a-f]{32})'", page.text)?[1] else {
            throw SiteError.parse("Eporner 页面里没有播放器 hash")
        }
        let vid = HTML.groups("EP\\.video\\.player\\.vid\\s*=\\s*'([^']+)'", page.text)?[1] ?? s.seriesId
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let x = try await get("/xhr/video/\(vid)?hash=\(Self.xhrHash(h))&device=generic&domain=www.eporner.com&fallback=false&embed=false&supportedFormats=hls,mp4&tech=Html5&_=\(ts)", ttl: 0)
        let list = Self.streams(x.text)
        guard let first = list.first else { throw SiteError.parse("Eporner 未返回播放源") }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: list)
    }
}

// MARK: - XVideos / XNXX (same engine: html5player.setVideoHLS / setVideoUrlHigh)

struct XVProvider: SiteProvider {
    let source: DramaSource
    var base: String { source == .xnxx ? "https://www.xnxx.com" : "https://www.xvideos.com" }
    static let xvMirrors = ["https://www.xvideos.com"]
    static let xnMirrors = ["https://www.xnxx.com"]
    var categories: [SiteCategory] {
        let m = TubePath.lastMonth()
        if source == .xnxx {
            return [.init(id: "today", title: "今日精选", path: "/todays-selection|/todays-selection/{p0}"),
                    .init(id: "best", title: "上月最佳", path: "/best/\(m)|/best/\(m)/{p0}", isRank: true),
                    .init(id: "hits", title: "热门", path: "/hits|/hits/{p0}", isRank: true)]
        }
        return [.init(id: "new", title: "最新", path: "/|/new/{p0}"),
                .init(id: "best", title: "上月最佳", path: "/best/\(m)|/best/\(m)/{p0}", isRank: true)]
    }
    private func get(_ path: String, ttl: TimeInterval = 120) async throws -> SiteHTTP.Response {
        try await SiteHTTP.shared.get(source, mirrors: [base], path: path, headers: ["User-Agent": TubeFmt.desktopUA], ttl: ttl)
    }
    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        Self.parseList(try await get(TubePath.url(c.path, page: page)).text, source: source, base: base, page: page)
    }
    func search(_ q: String, page: Int) async throws -> HGPage {
        let path = source == .xnxx ? "/search/\(TubePath.q(q))|/search/\(TubePath.q(q))/{p0}" : "/?k=\(TubePath.q(q))|/?k=\(TubePath.q(q))&p={p0}"
        return Self.parseList(try await get(TubePath.url(path, page: page)).text, source: source, base: base, page: page)
    }
    static func parseList(_ h: String, source: DramaSource, base: String, page: Int) -> HGPage {
        var items: [HGSeries] = [], seen = Set<String>()
        for chunk in h.components(separatedBy: "thumb-block").dropFirst() {
            let card = String(chunk.prefix(5000))
            guard let l = HTML.groups("href=\"(/video[.-]([a-z0-9]+)/[^\"]*)\"", card), seen.insert(l[2]).inserted else { continue }
            // 2026-11 xnxx: no <p class="title"> and no img alt — the title is only on the card link.
            let title = HTML.unescape(HTML.groups("<p class=\"title\">\\s*<a[^>]*title=\"([^\"]+)\"", card)?[1]
                                      ?? HTML.groups("\\balt=\"([^\"]+)\"", card)?[1]
                                      ?? HTML.groups("<a[^>]*href=\"/video[.-][a-z0-9]+/[^\"]*\"[^>]*\\btitle=\"([^\"]+)\"", card)?[1] ?? "")
            guard !title.isEmpty, TubeSafety.allowed(title) else { continue }
            let cover = HTML.groups("data-src=\"(https://[^\"]+\\.jpg[^\"]*)\"", card)?[1] ?? ""
            let dur = HTML.groups("class=\"duration\">([^<]+)<", card).map { TubeFmt.duration($0[1]) }
                ?? HTML.groups("(\\d+\\s*(?:h|min|sec)\\b[^<]{0,12})", HTML.groups("class=\"metadata\">(.*?)</p>", card)?[1] ?? "").map { TubeFmt.duration($0[1]) } ?? 0
            let author = HTML.groups("<span class=\"name\">([^<]+)</span>", card).map { HTML.cleanText($0[1]) }
            items.append(HGSeries(source: source, seriesId: l[2], title: title, cover: cover, subtitle: author, author: author,
                                  duration: dur, orientation: "landscape", page: base + l[1]))
        }
        return HGPage(items: items, hasMore: !items.isEmpty, nextOffset: page + 1)
    }
    private func watch(_ s: HGSeries, _ ep: HGEpisode? = nil) async throws -> SiteHTTP.Response {
        let p = ep?.page ?? s.page ?? (source == .xnxx ? "\(base)/video-\(s.seriesId)/" : "\(base)/video.\(s.seriesId)/")
        return try await get(p, ttl: 300)
    }
    static func call(_ fn: String, _ h: String) -> String {
        HTML.groups("html5player\\.\(fn)\\('([^']*)'\\)", h).map { TubeFmt.jsString(HTML.unescape($0[1])) } ?? ""
    }
    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await watch(s)
        return Self.parseDetail(r.text, series: s, url: r.url)
    }
    static func parseDetail(_ h: String, series s: HGSeries, url: String) -> HGSeriesDetail {
        let title = call("setVideoTitle", h).nonEmptyOr(s.title)
        let cover = call("setThumbUrl169", h).nonEmptyOr(HTML.ogImage(h)).nonEmptyOr(s.cover)
        let dur = HTML.groups("\"duration\"\\s*:\\s*\"PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?\"", h)
            .map { (Int($0[1]) ?? 0) * 3600 + (Int($0[2]) ?? 0) * 60 + (Int($0[3]) ?? 0) } ?? s.duration
        let tags = HTML.all("<a[^>]*class=\"[^\"]*is-keyword[^\"]*\"[^>]*>([^<]+)</a>", h).map { HTML.cleanText($0[1]) }
        return HGSeriesDetail(source: s.source, seriesId: s.seriesId, title: title, cover: cover, desc: s.author.map { "上传者 \($0)" } ?? "",
                              author: s.author, actors: [], onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: dur),
                              tags: Array(tags.prefix(16)), episodeLabel: dur > 0 ? Fmt.clock(dur) : "长视频")
    }
    static func streams(_ h: String, page: String) -> [HGStream] {
        let hdr = ["Referer": page, "User-Agent": TubeFmt.desktopUA]
        var out: [HGStream] = []
        let hls = call("setVideoHLS", h)
        if hls.hasPrefix("https://") { out.append(HGStream(streamId: "xv-hls", quality: "自动 · HLS", url: hls, key: "", kind: .hls, headers: hdr)) }
        for (fn, q) in [("setVideoUrlHigh", "高清 MP4"), ("setVideoUrlLow", "标清 MP4")] {
            let u = call(fn, h)
            if u.hasPrefix("https://"), !out.contains(where: { $0.url == u }) {
                out.append(HGStream(streamId: "xv-\(fn)", quality: q, url: u, key: "", kind: .mp4Clear, headers: hdr))
            }
        }
        return out
    }
    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let r = try await watch(s, ep)
        let list = Self.streams(r.text, page: r.url)
        guard let first = list.first else { throw SiteError.parse("\(source.label) 页面里没有播放地址") }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: list)
    }
}

// MARK: - Pornhub (mediaDefinitions → HLS)

struct PornhubProvider: SiteProvider {
    let source = DramaSource.pornhub
    static let mirrors = ["https://www.pornhub.com"]
    let categories: [SiteCategory] = [
        .init(id: "hot", title: "热门", path: "/video?o=ht|/video?o=ht&page={p}", isRank: true),
        .init(id: "new", title: "最新", path: "/video?o=mr|/video?o=mr&page={p}"),
        .init(id: "week", title: "本周最多观看", path: "/video?o=mv&t=w|/video?o=mv&t=w&page={p}", isRank: true),
        .init(id: "rated", title: "本月好评", path: "/video?o=tr&t=m|/video?o=tr&t=m&page={p}"),
    ]
    static let headers = ["User-Agent": TubeFmt.desktopUA, "Cookie": "platform=pc; accessAgeDisclaimerPH=1; age_verified=1"]
    private func get(_ path: String, ttl: TimeInterval = 120) async throws -> SiteHTTP.Response {
        try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: path, headers: Self.headers, ttl: ttl)
    }
    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        Self.parseList(try await get(TubePath.url(c.path, page: page)).text, page: page)
    }
    func search(_ q: String, page: Int) async throws -> HGPage {
        let p = "/video/search?search=\(TubePath.q(q))|/video/search?search=\(TubePath.q(q))&page={p}"
        return Self.parseList(try await get(TubePath.url(p, page: page)).text, page: page)
    }
    static func parseList(_ h: String, page: Int) -> HGPage {
        var items: [HGSeries] = [], seen = Set<String>()
        for chunk in h.components(separatedBy: "data-video-vkey=\"").dropFirst() {
            guard let key = HTML.groups("^([a-z0-9]+)\"", chunk)?[1], seen.insert(key).inserted else { continue }
            let card = String(chunk.prefix(6000))
            let thumbTag = HTML.groups("(<img\\b[^>]*videoThumb[^>]*>)", card)?[1] ?? ""
            let title = HTML.unescape(HTML.groups("\\salt=\"([^\"]+)\"", thumbTag)?[1]
                                      ?? HTML.groups("title=\"([^\"]+)\"", card)?[1] ?? "")
            guard !title.isEmpty, TubeSafety.allowed(title) else { continue }
            let cover = Self.cardCover(card)
            let dur = HTML.groups("<span class=\"time\">([0-9:]+)</span>", card).map { SiteParse.clock($0[1]) }
                ?? HTML.groups("<var class=\"duration\">([0-9:]+)</var>", card).map { SiteParse.clock($0[1]) } ?? 0
            let views = HTML.groups("<div class=\"views\">([^<]+)</div>", card).map { SiteParse.count($0[1]) }
                ?? HTML.groups("<span class=\"views\"><var>([^<]+)</var>", card).map { SiteParse.count($0[1]) } ?? 0
            items.append(HGSeries(source: .pornhub, seriesId: key, title: title, cover: cover, duration: dur, playCount: views,
                                  orientation: "landscape", page: "https://www.pornhub.com/view_video.php?viewkey=\(key)"))
        }
        return HGPage(items: items, hasMore: !items.isEmpty && h.contains("page=\(page + 1)"), nextOffset: page + 1)
    }
    /// Card thumbnail. 2026-11: `src` now comes BEFORE `class="…videoThumb…"` in the <img> (the old
    /// class-then-src regex matched nothing → empty covers) and data-mediumthumb became data-image.
    static func cardCover(_ card: String) -> String {
        guard let tag = HTML.groups("(<img\\b[^>]*videoThumb[^>]*>)", card)?[1] else {
            return HTML.unescape(HTML.groups("data-mediumthumb=\"(https://[^\"]+)\"", card)?[1] ?? "")
        }
        for a in ["src", "data-image", "data-mediumthumb", "data-src", "data-thumb_url"] {
            if let v = HTML.groups("\\s\(a)=\"(https://[^\"]+)\"", tag)?[1], !v.contains("blank.gif") { return HTML.unescape(v) }
        }
        return ""
    }
    private func watch(_ s: HGSeries) async throws -> SiteHTTP.Response {
        try await get("/view_video.php?viewkey=\(s.seriesId)", ttl: 300)
    }
    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await watch(s)
        return Self.parseDetail(r.text, series: s, url: r.url)
    }
    static func parseDetail(_ h: String, series s: HGSeries, url: String) -> HGSeriesDetail {
        let title = HTML.unescape(HTML.groups("<meta property=\"og:title\" content=\"([^\"]+)\"", h)?[1] ?? "").nonEmptyOr(s.title)
        let dur = HTML.groups("\"video_duration\"\\s*:\\s*\"?(\\d+)", h).flatMap { Int($0[1]) } ?? s.duration
        let tags = HTML.all("<a[^>]*data-label=\"(?:Category|Tag)\"[^>]*>([^<]+)</a>", h).map { HTML.cleanText($0[1]) }
        return HGSeriesDetail(source: .pornhub, seriesId: s.seriesId, title: title, cover: HTML.ogImage(h).nonEmptyOr(s.cover),
                              desc: s.playCount > 0 ? Fmt.count(s.playCount) + "次观看" : "",
                              author: nil, actors: [], onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: dur),
                              tags: Array(tags.prefix(16)), episodeLabel: dur > 0 ? Fmt.clock(dur) : "长视频")
    }
    static func streams(_ h: String) -> [HGStream] {
        guard let raw = TubeFmt.balancedArray(after: "\"mediaDefinitions\"", in: h),
              let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return [] }
        let hdr = ["Referer": "https://www.pornhub.com/", "User-Agent": TubeFmt.desktopUA]
        return arr.compactMap { d -> (Int, HGStream)? in
            guard J.str(d["format"]) == "hls", case let u = J.str(d["videoUrl"]), u.hasPrefix("https://") else { return nil }
            let q = J.int(d["height"]).nonZero ?? Int(J.str(d["quality"])) ?? 0
            return (q, HGStream(streamId: "ph-\(q)", quality: q > 0 ? "\(q)p · HLS" : "HLS", url: u, key: "", height: q > 0 ? q : nil, kind: .hls, headers: hdr))
        }.sorted { $0.0 > $1.0 }.map(\.1)
    }
    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let list = Self.streams(try await watch(s).text)
        guard let first = list.first else { throw SiteError.parse("Pornhub 页面里没有 HLS 播放源（可能需要年龄验证或地区受限）") }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: list)
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }
