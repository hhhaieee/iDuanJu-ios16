import Foundation

/// SupJav — WordPress list cards; each video exposes several embed "servers" whose links are
/// reversed and bounced through `lk1.supremejav.com`. Port of UAV-Downloader `sites/supjav.py` (Apache-2.0).
/// LUC is intentionally not supported. HLS from these hosts often carries a fake PNG header in
/// front of every TS segment, so HLS goes through `LocalHLSProxy` which strips it.
struct SupJavProvider: SiteProvider {
    let source = DramaSource.supjav
    static let mirrors = ["https://supjav.com"]
    static let bounce = "https://lk1.supremejav.com/supjav.php?c="
    /// Resolution order (UAV `SERVER_PRIORITY` minus LUC).
    static let serverOrder = ["EVS", "FST", "VAS", "VOE", "TV", "ST"]

    let categories: [SiteCategory] = [
        .init(id: "latest", title: "最近更新", path: "/zh/"),
        .init(id: "popular", title: "热门总榜", path: "/zh/popular", isRank: true),
        .init(id: "popular-week", title: "本周热门", path: "/zh/popular?sort=week", isRank: true),
        .init(id: "popular-month", title: "本月热门", path: "/zh/popular?sort=month", isRank: true),
        .init(id: "chinese-subtitles", title: "中文字幕", path: "/zh/category/chinese-subtitles"),
        .init(id: "censored", title: "有码", path: "/zh/category/censored-jav"),
        .init(id: "uncensored", title: "无码", path: "/zh/category/uncensored-jav"),
        .init(id: "amateur", title: "素人", path: "/zh/category/amateur"),
        .init(id: "reducing-mosaic", title: "破解", path: "/zh/category/reducing-mosaic"),
        .init(id: "english-subtitles", title: "英文字幕", path: "/zh/category/english-subtitles"),
    ]

    /// `/zh/popular?sort=week` → `/zh/popular/page/2?sort=week`.
    static func pageURL(_ path: String, page: Int) -> String {
        guard page > 1 else { return path }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var p = parts[0]
        if !p.hasSuffix("/") { p += "/" }
        p += "page/\(page)/"
        return parts.count > 1 ? p + "?" + parts[1] : p
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        let r = try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: Self.pageURL(c.path, page: page))
        return Self.parseList(r.text, base: r.base, page: page)
    }

    func search(_ q: String, page: Int) async throws -> HGPage {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        let r = try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: Self.pageURL("/zh/", page: page) + "?s=\(enc)")
        return Self.parseList(r.text, base: r.base, page: page)
    }

    static func parseList(_ h: String, base: String, page: Int) -> HGPage {
        var items: [HGSeries] = []
        var seen = Set<String>()
        for chunk in h.components(separatedBy: "<div class=\"post\">").dropFirst() {
            let card = String(chunk.prefix(4000))
            guard let a = HTML.groups("<a\\s[^>]*href=\"([^\"]+?(\\d+)\\.html)\"[^>]*>", card) else { continue }
            let url = HTML.resolve(base, a[1])
            let id = a[2]
            guard seen.insert(id).inserted else { continue }
            var title = HTML.groups("<a\\s[^>]*href=\"[^\"]+\\.html\"[^>]*title=\"([^\"]*)\"", card).map { HTML.unescape($0[1]) } ?? ""
            if title.isEmpty { title = HTML.groups("<h3[^>]*>\\s*<a[^>]*>(.*?)</a>", card).map { HTML.cleanText($0[1]) } ?? id }
            let img = HTML.groups("<img[^>]*?data-original=\"([^\"]+)\"", card)?[1]
                ?? HTML.groups("<img[^>]*?data-src=\"([^\"]+)\"", card)?[1]
                ?? HTML.groups("<img[^>]*?\\ssrc=\"(https?[^\"]+)\"", card)?[1] ?? ""
            let views = HTML.groups("([0-9,]+)\\s*Views", card).map { SiteParse.count($0[1]) } ?? 0
            let date = HTML.groups("class=\"meta\">\\s*([0-9/]+)", card)?[1]
            items.append(HGSeries(source: .supjav, seriesId: id, title: title, cover: img,
                                  subtitle: SiteParse.code(title) ?? date, playCount: views,
                                  orientation: "landscape", page: url))
        }
        let more = h.contains("/page/\(page + 1)") || h.contains("class=\"next")
        return HGPage(items: items, hasMore: !items.isEmpty && (more || page == 1 && items.count >= 20), nextOffset: page + 1)
    }

    private func page(_ s: HGSeries) async throws -> SiteHTTP.Response {
        let path = s.page ?? "/zh/\(s.seriesId).html"
        return try await SiteHTTP.shared.get(source, mirrors: Self.mirrors, path: path, ttl: 600)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let r = try await page(s)
        return Self.parseDetail(r.text, series: s, url: r.url)
    }

    static func parseDetail(_ h: String, series s: HGSeries, url: String) -> HGSeriesDetail {
        let title = HTML.groups("<h1[^>]*>(.*?)</h1>", h).map { HTML.cleanText($0[1]) }.flatMap { $0.isEmpty ? nil : $0 } ?? s.title
        let cover = HTML.groups("class=\"post-meta[^\"]*\">\\s*<img[^>]*?src=\"([^\"]+)\"", h)?[1] ?? s.cover
        let cats = HTML.groups("<div class=\"cats\">(.*?)</div>", h)?[1] ?? ""
        let catLinks = HTML.all("<a[^>]*>([^<]+)</a>", cats).map { HTML.cleanText($0[1]) }
        let maker = HTML.groups("Maker\\s*:\\s*</span>\\s*<a[^>]*>([^<]+)</a>", cats).map { HTML.cleanText($0[1]) }
        let cast = HTML.groups("Cast\\s*:\\s*</span>(.*?)</p>", cats).map { HTML.all("<a[^>]*>([^<]+)</a>", $0[1]).map { HTML.cleanText($0[1]) } } ?? []
        let tagBlock = HTML.groups("<div class=\"tags\">(.*?)</div>", h)?[1] ?? ""
        var tags = HTML.all("<a[^>]*>([^<]+)</a>", tagBlock).map { HTML.cleanText($0[1]) }
        if let first = catLinks.first, !tags.contains(first) { tags.insert(first, at: 0) }
        let servers = Self.servers(h).map(\.name)
        let code = SiteParse.code(title) ?? ""
        let meta = [code.isEmpty ? nil : "番号 \(code)", servers.isEmpty ? nil : "线路 " + servers.joined(separator: " / ")]
            .compactMap { $0 }.joined(separator: " · ")
        return HGSeriesDetail(source: .supjav, seriesId: s.seriesId, title: title, cover: cover, desc: meta,
                              author: maker, actors: cast, onlineTime: 0, totalEps: 1,
                              episodes: SiteParse.singleEpisode(s, page: url, duration: s.duration),
                              tags: Array(tags.prefix(16)), episodeLabel: s.duration > 0 ? Fmt.clock(s.duration) : "长视频")
    }

    struct Server: Hashable { let name: String; let link: String }

    /// `<a class="btn-server" data-link="…">FST</a>`, LUC dropped, sorted by `serverOrder`.
    static func servers(_ h: String) -> [Server] {
        var out: [Server] = []
        var seen = Set<String>()
        for m in HTML.all("<a[^>]*class=\"btn-server[^\"]*\"[^>]*data-link=\"([^\"]+)\"[^>]*>([^<]*)</a>", h) {
            let name = HTML.cleanText(m[2]).uppercased()
            guard !name.isEmpty, name != "LUC", seen.insert(name).inserted else { continue }
            out.append(Server(name: name, link: m[1]))
        }
        func rank(_ n: String) -> Int { serverOrder.firstIndex(of: n) ?? serverOrder.count }
        return out.sorted { rank($0.name) < rank($1.name) }
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let r = try await page(s)
        let servers = Self.servers(r.text)
        guard !servers.isEmpty else { throw SiteError.parse("SupJav 页面里没有找到播放线路") }
        var results: [Int: HGStream] = [:]
        var errors: [String] = []
        await withTaskGroup(of: (Int, Result<HGStream, Error>).self) { g in
            for (i, sv) in servers.enumerated() {
                g.addTask {
                    do { return (i, .success(try await Self.resolveServer(sv))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for await (i, res) in g {
                switch res {
                case .success(let st): results[i] = st
                case .failure(let e): errors.append("\(servers[i].name): \(e.localizedDescription)")
                }
            }
        }
        let streams = results.keys.sorted().compactMap { results[$0] }
        guard let first = streams.first else {
            throw ProviderError.upstream("SupJav 所有线路解析失败（" + errors.sorted().joined(separator: "；") + "）")
        }
        return HGResolvedVideo(vid: s.seriesId, url: first.url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil,
                               streams: streams, note: errors.isEmpty ? nil : "部分线路不可用：" + errors.sorted().joined(separator: "；"))
    }

    // MARK: Server resolvers

    static func resolveServer(_ sv: Server) async throws -> HGStream {
        let reversed = String(sv.link.reversed())
        let c = reversed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? reversed
        var (html, embed) = try await SiteHTTP.shared.fetchFollowing(bounce + c, referer: "https://supjav.com/")
        guard let embedURL = URL(string: embed), let host = embedURL.host, !host.contains("supremejav") else {
            throw ProviderError.upstream("跳转失败")
        }
        // VOE (and clones) first serve a JS redirect to a rotating domain.
        for _ in 0..<2 {
            guard !html.contains("application/json"),
                  let next = HTML.groups("window\\.location\\.href\\s*=\\s*'(https?://[^']+/e/[^']+)'", html)?[1] else { break }
            (html, embed) = try await SiteHTTP.shared.fetchFollowing(next, referer: "https://supjav.com/")
        }
        let origin = (URL(string: embed).flatMap { u in u.host.map { "\(u.scheme ?? "https")://\($0)" } }) ?? "https://\(host)"
        let hdr = ["Referer": embed.components(separatedBy: "#")[0], "Origin": origin, "User-Agent": DramaSource.supjav.userAgent]

        func hls(_ url: String, referer: [String: String] = hdr) throws -> HGStream {
            guard let p = LocalHLSProxy.shared.playlistURL(url, headers: referer) else { throw ProviderError.upstream("本地代理未启动") }
            return HGStream(streamId: "supjav-\(sv.name)", quality: sv.name, url: p, key: "", kind: .hls, headers: [:])
        }

        switch sv.name {
        case "VOE":
            guard let u = voeSource(html) else { throw SiteError.parse("VOE 解码失败") }
            return try hls(u)
        case "FST":
            guard let u = fstSource(html, embed: embed) else { throw SiteError.parse("FST 未找到 m3u8") }
            return try hls(u)
        case "VAS":
            let code = embedURL.pathComponents.last ?? ""
            let body = try JSONSerialization.data(withJSONObject: ["filecode": code, "device": "web", "codecs": [String]()])
            let (t, status, _) = try await SiteHTTP.shared.raw(origin + "/api/stream", referer: embed,
                                                               headers: ["Content-Type": "application/json", "Origin": origin],
                                                               method: "POST", body: body)
            guard (200..<300).contains(status),
                  let j = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
                  let u = j["streaming_url"] as? String, u.hasPrefix("http") else { throw ProviderError.upstream("VAS 接口无返回") }
            return try hls(u)
        case "TV":
            guard let u = HTML.groups("urlPlay\\s*=\\s*['\"]([^'\"]+\\.m3u8[^'\"]*)['\"]", html)?[1] else { throw SiteError.parse("TV 未找到 m3u8") }
            return try hls(u, referer: ["Referer": "https://supjav.com/", "User-Agent": DramaSource.supjav.userAgent])
        case "ST":
            guard let u = streamtapeSource(html) else { throw SiteError.parse("Streamtape 直链拼接失败") }
            return HGStream(streamId: "supjav-ST", quality: "ST（MP4）", url: u, key: "", kind: .mp4Clear, headers: hdr)
        default:
            for js in JSUnpacker.unpackedScripts(html) + [html] {
                if let u = HTML.groups("(https?://[^'\"\\s]+\\.m3u8[^'\"\\s]*)", js)?[1] { return try hls(u) }
            }
            throw SiteError.parse("\(sv.name) 未找到 m3u8")
        }
    }

    /// VOE: `<script type="application/json">["…"]</script>` → rot13 → strip noise → b64 → shift −3 → reverse → b64 → JSON.
    static func voeSource(_ html: String) -> String? {
        guard let raw = HTML.groups("<script type=\"application/json\">(.*?)</script>", html)?[1],
              let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any], let enc = arr.first as? String else { return nil }
        var s = String(String.UnicodeScalarView(enc.unicodeScalars.map { c -> Unicode.Scalar in
            switch c.value {
            case 65...90: Unicode.Scalar((c.value - 65 + 13) % 26 + 65)!
            case 97...122: Unicode.Scalar((c.value - 97 + 13) % 26 + 97)!
            default: c
            }
        }))
        for n in ["@$", "^^", "~@", "%?", "*~", "!!", "#&"] { s = s.replacingOccurrences(of: n, with: "_") }
        s = s.replacingOccurrences(of: "_", with: "")
        guard let d1 = Data(base64Encoded: pad(s)) else { return nil }
        let shifted = String(String.UnicodeScalarView(d1.compactMap { Unicode.Scalar(UInt32($0) &- 3) }))
        guard let d2 = Data(base64Encoded: pad(String(shifted.reversed()))),
              let j = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] else { return nil }
        return (j["source"] as? String) ?? (j["direct_access_url"] as? String)
    }

    private static func pad(_ s: String) -> String {
        let r = s.count % 4
        return r == 0 ? s : s + String(repeating: "=", count: 4 - r)
    }

    /// FST: packed `var links={hls2,hls3,hls4}` + jwplayer `sources:[{file:links.hls4||links.hls3||…}]`.
    static func fstSource(_ html: String, embed: String) -> String? {
        for js in JSUnpacker.unpackedScripts(html) + [html] {
            guard let raw = HTML.groups("var\\s+links\\s*=\\s*(\\{[^}]*\\})", js)?[1],
                  let links = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] else { continue }
            var order: [String] = []
            if let f = HTML.groups("file\\s*:\\s*((?:links\\.\\w+\\s*\\|\\|\\s*)*links\\.\\w+)", js)?[1] {
                order = HTML.all("links\\.(\\w+)", f).map { $0[1] }
            }
            for k in order + ["hls4", "hls3", "hls2"] {
                if let v = links[k], !v.isEmpty { return HTML.resolve(embed, v) }
            }
        }
        return nil
    }

    /// Streamtape: `getElementById('robotlink').innerHTML = '//streamtape.com/get_video?id'+ ('xcd=…').substring(2).substring(1);`
    static func streamtapeSource(_ html: String) -> String? {
        for id in ["robotlink", "botlink", "ideoolink"] {
            guard let m = HTML.groups("getElementById\\('\(id)'\\)\\.innerHTML\\s*=\\s*['\"]([^'\"]*)['\"]\\s*\\+\\s*(?:''\\s*\\+\\s*)?\\(['\"]([^'\"]*)['\"]\\)((?:\\.substring\\(\\d+\\))*)", html) else { continue }
            var tail = m[2]
            for n in HTML.all("substring\\((\\d+)\\)", m[3]).compactMap({ Int($0[1]) }) { tail = String(tail.dropFirst(n)) }
            var u = m[1] + tail
            while u.hasPrefix("/") { u.removeFirst() }
            guard u.contains("get_video") else { continue }
            return "https://" + u
        }
        return nil
    }
}
