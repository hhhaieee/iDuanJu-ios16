import Foundation
import UIKit
import CoreGraphics

/// Host-side content rule applied to every plugin / 采集站 result (plugins cannot opt out):
/// anything tagged or titled as involving minors is dropped.
enum ContentFilter {
    static let cjk = ["未成年", "幼女", "幼童", "幼儿", "幼児", "儿童", "兒童", "萝莉", "蘿莉", "ロリ", "ショタ", "正太", "小学生", "小學生",
                      "中学生", "中學生", "初中", "女子中学", "女子小学", "童女", "炼铜", "煉銅", "女高中生", "高中生", "女子校生", "女子高生", "女子中学生", "学生妹", "學生妹", "JK制服"]
    static let latin = ["loli", "lolis", "lolicon", "shota", "shotacon", "toddler", "toddlers", "underage", "under age", "preteen", "pre teen",
                        "child", "children", "kid", "kids", "minor", "minors", "jailbait", "elementary school", "middle school", "junior high",
                        "schoolgirl", "schoolgirls", "school girl", "school girls", "schoolboy", "school boy", "jk", "jc", "teen", "teens", "age regression", "high school girl", "highschool girl", "joshikousei", "joshi kousei", "jogakusei", "jogakuin", "joshikou", "joshi chuugakusei", "little girl", "little boy"]
    private static let latinRegex: NSRegularExpression = {
        let alt = latin.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![a-z0-9])(" + alt + ")(?![a-z0-9])", options: [.caseInsensitive])
    }()

    static func isBlocked(_ texts: [String]) -> Bool {
        for t in texts where !t.isEmpty {
            let s = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            if cjk.contains(where: { s.localizedCaseInsensitiveContains($0) }) { return true }
            if latinRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        }
        return false
    }
}

/// Plugin-provided images go through `idjimg://` refs so that every fetch is checked against that plugin's
/// media allow-list, uses only that plugin's cookies, and applies declared transforms natively.
enum PluginMedia {
    static let scheme = "idjimg://"
    static let allowedHeaders: Set<String> = ["referer", "user-agent", "origin", "accept", "accept-language"]

    static func ref(plugin: String, url: String, headers: [String: String]? = nil, transform: [String: Any]? = nil) -> String {
        guard !url.isEmpty else { return "" }
        var o: [String: Any] = ["u": url]
        if let h = headers?.filter({ allowedHeaders.contains($0.key.lowercased()) }), !h.isEmpty { o["h"] = h }
        if let transform, !transform.isEmpty { o["t"] = transform }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        let b64 = d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return scheme + plugin + "/" + b64
    }

    static func parse(_ ref: String) -> (plugin: String, url: URL, headers: [String: String], transform: [String: Any]?)? {
        guard ref.hasPrefix(scheme) else { return nil }
        let rest = ref.dropFirst(scheme.count)
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let plugin = String(rest[..<slash])
        var b64 = String(rest[rest.index(after: slash)...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = o["u"] as? String, let url = URL(string: u) else { return nil }
        return (plugin, url, o["h"] as? [String: String] ?? [:], o["t"] as? [String: Any])
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let policy: DomainPolicy
        var blocked: String?
        init(policy: DomainPolicy) { self.policy = policy }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let u = request.url, let h = u.host, u.scheme == "https" || u.scheme == "http", policy.allows(h),
                  !NetGuard.isIPLiteral(h), !NetGuard.resolvesToBlocked(h) else { blocked = request.url?.host; return nil }
            return request
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        ProxySettings.shared.apply(to: c)
        return URLSession(configuration: c)
    }()

    /// Final image bytes (transform applied).
    static func load(_ ref: String) async throws -> Data {
        guard let r = parse(ref) else { throw ProviderError.invalid("图片地址无效") }
        guard let rec = PluginStore.snapshot(r.plugin), rec.enabled else { throw ProviderError.invalid("插件未启用") }
        let policy = DomainPolicy(rec.manifest.mediaDomains + rec.manifest.httpDomains + rec.extraDomains)
        guard let host = r.url.host, r.url.scheme == "https" || r.url.scheme == "http", policy.allows(host), !NetGuard.isIPLiteral(host) else {
            PluginLog.add(r.plugin, "✕ 图片域名未授权 \(r.url.host ?? "?")")
            throw ProviderError.invalid("图片域名未授权：\(r.url.host ?? "")")
        }
        let blocked = await Task.detached { NetGuard.resolvesToBlocked(host) }.value
        if blocked { throw ProviderError.invalid("图片地址解析到内网") }
        var data: Data
        if let fx = PluginFixtures.responder, let reply = fx(URLRequest(url: r.url)) { data = reply.body }
        else {
            var req = URLRequest(url: r.url)
            req.setValue(rec.learnedUA ?? PluginHostContext.defaultUA, forHTTPHeaderField: "User-Agent")
            for (k, v) in r.headers where allowedHeaders.contains(k.lowercased()) { req.setValue(v, forHTTPHeaderField: k) }
            let cs = PluginRuntime.jar(r.plugin).cookies(for: r.url)
            for (k, v) in HTTPCookie.requestHeaderFields(with: cs) { req.setValue(v, forHTTPHeaderField: k) }
            let guardD = RedirectGuard(policy: policy)
            let (d, resp) = try await session.data(for: req, delegate: guardD)
            if let b = guardD.blocked { throw ProviderError.invalid("图片跳转到未授权域名 \(b)") }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), !d.isEmpty else { throw ProviderError.upstream("图片 HTTP \(code) · \(host)") }
            guard d.count <= 30 << 20 else { throw ProviderError.upstream("图片太大") }
            data = d
        }
        if let t = r.transform { data = try apply(t, data) }
        return data
    }

    static func apply(_ t: [String: Any], _ data: Data) throws -> Data {
        switch t["type"] as? String ?? "" {
        case "stripes":
            let n = t["segments"] as? Int ?? 0
            guard n > 1 else { return data }
            guard let img = UIImage(data: data)?.cgImage else { throw ProviderError.invalid("图片无法解码") }
            guard let out = ImageStripes.unscramble(img, segments: n) else { throw ProviderError.invalid("图片还原失败") }
            return UIImage(cgImage: out).jpegData(compressionQuality: 0.92) ?? data
        case "aes":
            let enc = t["keyEncoding"] as? String ?? "utf8"
            let key = try PluginCrypto.decode(t["key"] as? String ?? "", enc)
            let iv = try (t["iv"] as? String).map { try PluginCrypto.decode($0, enc) }
            var input = data
            if (t["encoding"] as? String) == "base64" { input = try PluginCrypto.decode(String(decoding: data, as: UTF8.self), "base64") }
            return try PluginCrypto.aes(encrypt: false, mode: t["mode"] as? String ?? "cbc", key: key, iv: iv, data: input,
                                        padding: (t["padding"] as? String ?? "pkcs7") != "none")
        default:
            return data
        }
    }
}

/// 18comic-style horizontal stripe scramble (public JMComic algorithm, MIT reference implementation
/// hect0x7/JMComic-Crawler-Python `JmImageTool.decode_and_save`): the image is cut into `segments`
/// horizontal bands stored in reverse order; the first band of the original absorbs `height % segments` rows.
enum ImageStripes {
    /// (source y, destination y, height) for each band, in the original algorithm's coordinate system (top-left origin).
    static func plan(height h: Int, segments num: Int) -> [(src: Int, dst: Int, h: Int)] {
        guard num > 1, h >= num else { return [] }
        let over = h % num
        var out: [(Int, Int, Int)] = []
        for i in 0..<num {
            var move = h / num
            let ySrc = h - move * (i + 1) - over
            var yDst = move * i
            if i == 0 { move += over } else { yDst += over }
            out.append((ySrc, yDst, move))
        }
        return out
    }

    static func unscramble(_ img: CGImage, segments: Int) -> CGImage? {
        let w = img.width, h = img.height
        let bands = plan(height: h, segments: segments)
        guard !bands.isEmpty else { return img }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for b in bands {
            guard let piece = img.cropping(to: CGRect(x: 0, y: b.src, width: w, height: b.h)) else { return nil }
            // CGContext origin is bottom-left.
            ctx.draw(piece, in: CGRect(x: 0, y: h - b.dst - b.h, width: w, height: b.h))
        }
        return ctx.makeImage()
    }

    /// Inverse (used by tests to build scrambled fixtures).
    static func scramble(_ img: CGImage, segments: Int) -> CGImage? {
        let w = img.width, h = img.height
        let bands = plan(height: h, segments: segments)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for b in bands {
            guard let piece = img.cropping(to: CGRect(x: 0, y: b.dst, width: w, height: b.h)) else { return nil }
            ctx.draw(piece, in: CGRect(x: 0, y: h - b.src - b.h, width: w, height: b.h))
        }
        return ctx.makeImage()
    }
}

/// Shared output validation for plugin results.
enum PluginOut {
    static func s(_ v: Any?, max: Int = 300) -> String {
        let t = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
    static func url(_ v: Any?) -> String {
        let u = s(v, max: 2000)
        return u.hasPrefix("https://") || u.hasPrefix("http://") ? u : ""
    }
    static func strings(_ v: Any?, max: Int = 30) -> [String] { ((v as? [Any]) ?? []).prefix(max).map { s($0, max: 60) }.filter { !$0.isEmpty } }
    static func headers(_ v: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, val) in (v as? [String: Any]) ?? [:] where PluginMedia.allowedHeaders.contains(k.lowercased()) { out[k] = s(val, max: 500) }
        return out
    }
    static func categories(_ v: Any?) -> [PluginCategory] {
        ((v as? [[String: Any]]) ?? []).prefix(60).compactMap { c in
            let id = s(c["id"]), name = s(c["name"], max: 40)
            guard !id.isEmpty, !name.isEmpty, !ContentFilter.isBlocked([name, id]) else { return nil }
            return PluginCategory(id: id, name: name, isRank: c["isRank"] as? Bool ?? false)
        }
    }
}

// MARK: - Comic plugins

struct JSComicProvider: MangaProvider {
    let source: MangaSourceID
    var pluginID: String { source.pluginID ?? "" }
    static let homeID = "__home"

    var categories: [MangaCategory] {
        [MangaCategory(id: Self.homeID, title: "推荐")] + (PluginStore.snapshot(pluginID)?.cachedCategories ?? []).map { MangaCategory(id: $0.id, title: $0.name) }
    }
    var imageHeaders: [String: String] { [:] }

    private func item(_ o: [String: Any]) -> MangaItem? {
        let id = PluginOut.s(o["id"]), title = PluginOut.s(o["title"], max: 200)
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let tags = PluginOut.strings(o["tags"]) + PluginOut.strings(o["badges"])
        guard !ContentFilter.isBlocked([title] + tags) else { return nil }
        let cover = PluginOut.url(o["cover"])
        return MangaItem(source: source, mangaId: id, title: title,
                         cover: PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"])),
                         author: PluginOut.s(o["author"], max: 80), tags: tags, latest: PluginOut.s(o["remarks"], max: 40))
    }

    private func page(_ v: Any) -> MangaPage {
        let o = v as? [String: Any] ?? [:]
        let items = ((o["items"] as? [[String: Any]]) ?? []).prefix(500).compactMap(item)
        return MangaPage(items: Array(items), hasMore: (o["hasMore"] as? Bool ?? false) && !items.isEmpty)
    }

    func list(_ c: MangaCategory, page p: Int) async throws -> MangaPage {
        if c.id == Self.homeID {
            if p > 1 { return MangaPage(items: [], hasMore: false) }
            let r = try await PluginRuntime.call(pluginID, "home", [:])
            let cats = PluginOut.categories((r as? [String: Any])?["categories"])
            let id = pluginID
            await MainActor.run { PluginStore.shared.cacheCategories(id, cats) }
            if let items = (r as? [String: Any])?["items"] as? [Any], !items.isEmpty { return page(r) }
            guard let first = cats.first else { return MangaPage(items: [], hasMore: false) }
            return page(try await PluginRuntime.call(pluginID, "category", ["id": first.id, "page": 1, "filters": [String: String]()]))
        }
        return page(try await PluginRuntime.call(pluginID, "category", ["id": c.id, "page": p, "filters": [String: String]()]))
    }

    func search(_ q: String, page p: Int) async throws -> MangaPage {
        page(try await PluginRuntime.call(pluginID, "search", ["keyword": q, "page": p]))
    }

    func detail(_ m: MangaItem) async throws -> MangaDetail {
        let o = try await PluginRuntime.call(pluginID, "detail", ["id": m.mangaId]) as? [String: Any] ?? [:]
        var item = m
        let title = PluginOut.s(o["title"], max: 200)
        if !title.isEmpty { item.title = title }
        let cover = PluginOut.url(o["cover"])
        if !cover.isEmpty { item.cover = PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"])) }
        let tags = PluginOut.strings(o["tags"])
        if !tags.isEmpty { item.tags = tags }
        let author = PluginOut.s(o["author"], max: 80)
        if !author.isEmpty { item.author = author }
        guard !ContentFilter.isBlocked([item.title] + item.tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let chapters = ((o["chapters"] as? [[String: Any]]) ?? []).prefix(5000).enumerated().compactMap { i, c -> MangaChapter? in
            let id = PluginOut.s(c["id"]), name = PluginOut.s(c["name"], max: 120)
            return id.isEmpty ? nil : MangaChapter(chapterId: id, title: name.isEmpty ? "第\(i + 1)话" : name, index: i)
        }.enumerated().map { MangaChapter(chapterId: $0.element.chapterId, title: $0.element.title, index: $0.offset) }
        let status = (o["status"] as? String) == "completed" ? "已完结" : (o["status"] as? String) == "ongoing" ? "连载中" : ""
        return MangaDetail(item: item, desc: PluginOut.s(o["desc"], max: 4000), status: status, chapters: chapters)
    }

    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String] {
        let o = try await PluginRuntime.call(pluginID, "pages", ["chapterId": c.chapterId, "mangaId": m.mangaId]) as? [String: Any] ?? [:]
        let common = PluginOut.headers(o["headers"])
        let imgs = ((o["images"] as? [[String: Any]]) ?? []).prefix(2000).compactMap { i -> String? in
            let u = PluginOut.url(i["url"])
            guard !u.isEmpty else { return nil }
            let h = common.merging(PluginOut.headers(i["headers"])) { _, b in b }
            var t = i["transform"] as? [String: Any]
            if let tt = t, !["stripes", "aes"].contains(tt["type"] as? String ?? "") { t = nil }
            return PluginMedia.ref(plugin: pluginID, url: u, headers: h, transform: t)
        }
        guard !imgs.isEmpty else { throw ProviderError.upstream("插件没有返回图片") }
        return imgs
    }
}

// MARK: - Video plugins

struct JSVideoProvider: SiteProvider {
    let source: DramaSource
    var pluginID: String { source.pluginID ?? "" }
    static let homeID = "__home"

    var categories: [SiteCategory] {
        [SiteCategory(id: Self.homeID, title: "推荐", path: Self.homeID)]
            + (PluginStore.snapshot(pluginID)?.cachedCategories ?? []).map { SiteCategory(id: $0.id, title: $0.name, path: $0.id, isRank: $0.isRank) }
    }

    private func series(_ o: [String: Any]) -> HGSeries? {
        let id = PluginOut.s(o["id"]), title = PluginOut.s(o["title"], max: 200)
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let tags = PluginOut.strings(o["tags"]) + PluginOut.strings(o["badges"])
        guard !ContentFilter.isBlocked([title] + tags) else { return nil }
        let cover = PluginMedia.ref(plugin: pluginID, url: PluginOut.url(o["cover"]), headers: PluginOut.headers(o["coverHeaders"]))
        return HGSeries(source: source, seriesId: id, title: title, cover: cover, subtitle: PluginOut.s(o["remarks"], max: 40).nilIfEmpty,
                        actors: PluginOut.strings(o["actors"]), orientation: (o["orientation"] as? String) == "portrait" ? "portrait" : nil, tags: tags)
    }

    private func page(_ v: Any, _ p: Int) -> HGPage {
        let o = v as? [String: Any] ?? [:]
        let items = ((o["items"] as? [[String: Any]]) ?? []).prefix(500).compactMap(series)
        return HGPage(items: Array(items), hasMore: (o["hasMore"] as? Bool ?? false) && !items.isEmpty, nextOffset: p + 1)
    }

    func list(_ c: SiteCategory, page p: Int) async throws -> HGPage {
        if c.id == Self.homeID {
            if p > 1 { return HGPage(items: [], hasMore: false) }
            let r = try await PluginRuntime.call(pluginID, "home", [:])
            let cats = PluginOut.categories((r as? [String: Any])?["categories"])
            let id = pluginID
            await MainActor.run { PluginStore.shared.cacheCategories(id, cats) }
            if let items = (r as? [String: Any])?["items"] as? [Any], !items.isEmpty { return page(r, 1) }
            guard let first = cats.first else { return HGPage(items: [], hasMore: false) }
            return page(try await PluginRuntime.call(pluginID, "category", ["id": first.id, "page": 1, "filters": [String: String]()]), 1)
        }
        return page(try await PluginRuntime.call(pluginID, "category", ["id": c.id, "page": p, "filters": [String: String]()]), p)
    }

    func search(_ q: String, page p: Int) async throws -> HGPage {
        page(try await PluginRuntime.call(pluginID, "search", ["keyword": q, "page": p]), p)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let o = try await PluginRuntime.call(pluginID, "detail", ["id": s.seriesId]) as? [String: Any] ?? [:]
        let title = PluginOut.s(o["title"], max: 200).nonEmptyOr(s.title)
        let tags = PluginOut.strings(o["tags"])
        guard !ContentFilter.isBlocked([title] + tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let lines = ((o["lines"] as? [[String: Any]]) ?? []).prefix(20)
        var eps: [HGEpisode] = []
        if let line = lines.first {
            let lineName = PluginOut.s(line["name"], max: 40)
            for (i, e) in ((line["episodes"] as? [[String: Any]]) ?? []).prefix(3000).enumerated() {
                let id = PluginOut.s(e["id"], max: 2000)
                guard !id.isEmpty else { continue }
                eps.append(HGEpisode(ep: i + 1, vid: id, duration: e["duration"] as? Int ?? 0, title: PluginOut.s(e["name"], max: 80).nonEmptyOr("第\(i + 1)集"), page: lineName))
            }
        }
        let cover = PluginOut.url(o["cover"])
        return HGSeriesDetail(source: source, seriesId: s.seriesId, title: title,
                              cover: cover.isEmpty ? s.cover : PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"])),
                              desc: PluginOut.s(o["desc"], max: 4000), author: PluginOut.s(o["director"], max: 80).nilIfEmpty,
                              actors: PluginOut.strings(o["actors"]), onlineTime: 0, totalEps: eps.count, episodes: eps, tags: tags,
                              episodeLabel: eps.count > 1 ? "共\(eps.count)集" : "长视频")
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let o = try await PluginRuntime.call(pluginID, "play", ["line": ep.page ?? "", "episodeId": ep.vid, "id": s.seriesId]) as? [String: Any] ?? [:]
        guard let rec = PluginStore.snapshot(pluginID) else { throw ProviderError.invalid("插件未安装") }
        let media = DomainPolicy(rec.manifest.mediaDomains + rec.manifest.httpDomains + rec.extraDomains)
        var streams: [HGStream] = []
        for (i, st) in ((o["streams"] as? [[String: Any]]) ?? []).prefix(12).enumerated() {
            let u = PluginOut.url(st["url"])
            guard let url = URL(string: u), let host = url.host, url.scheme == "https", media.allows(host), !NetGuard.isIPLiteral(host) else {
                PluginLog.add(pluginID, "✕ 丢弃未授权/非 https 的流地址 \(URL(string: u)?.host ?? u.prefix(40).description)")
                continue
            }
            let fmt = (st["format"] as? String) ?? (u.contains(".m3u8") ? "hls" : "mp4")
            var h = PluginOut.headers(st["headers"])
            if h["User-Agent"] == nil { h["User-Agent"] = rec.learnedUA ?? PluginHostContext.defaultUA }
            streams.append(HGStream(streamId: "p\(i)", quality: PluginOut.s(st["name"], max: 40).nonEmptyOr(host), url: u, key: "",
                                    kind: fmt == "hls" ? .hls : .mp4Clear, headers: h))
        }
        guard let first = streams.first else { throw ProviderError.upstream("插件没有返回可播放的地址（需 https 且在 media 白名单内）") }
        return HGResolvedVideo(vid: ep.vid, url: first.url, key: nil, duration: nil, expiresAt: (o["expiresAt"] as? Int), err: nil, streams: streams)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
