import Foundation
import Combine
import CryptoKit

/// 苹果 CMS (maccms v10) 采集接口: built-in generic adapter, no JS needed.
struct CMSSite: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var api: String
    var adult: Bool = false
    var enabled: Bool = true
    var categories: [PluginCategory] = []
    var origin: String = "manual"
    var id: String { key }
    var source: DramaSource { .cms(key) }

    static func key(for api: String) -> String {
        String(Insecure.MD5.hash(data: Data(api.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10))
    }
}

@MainActor
final class CMSStore: ObservableObject {
    static let shared = CMSStore()
    @Published private(set) var sites: [CMSSite] = []
    @Published private(set) var revision = 0
    private let d = UserDefaults.standard
    private static let key = "stv.cms.sites"

    nonisolated(unsafe) private static var snap: [String: CMSSite] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated private static let lock = NSLock()
    nonisolated static func site(_ key: String) -> CMSSite? { lock.lock(); defer { lock.unlock() }; return snap[key] }
    nonisolated static func sources() -> [DramaSource] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { snap[$0] }.filter(\.enabled).map(\.source)
    }

    private init() {
        sites = d.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CMSSite].self, from: $0) } ?? []
        publish()
    }

    private func publish() {
        Self.lock.lock()
        Self.snap = Dictionary(uniqueKeysWithValues: sites.map { ($0.key, $0) })
        Self.order = sites.map(\.key)
        Self.lock.unlock()
        revision += 1
    }
    private func save() {
        if let data = try? JSONEncoder().encode(sites) { d.set(data, forKey: Self.key) }
        publish()
    }

    nonisolated static func normalize(_ api: String) throws -> String {
        var s = api.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }  // ATS: https only
        guard var c = URLComponents(string: s), c.scheme == "https", let h = c.host, !h.isEmpty, !NetGuard.isIPLiteral(h) else {
            throw ProviderError.invalid("需要 https 的采集接口地址（不支持 IP / 内网地址）")
        }
        c.queryItems = c.queryItems?.filter { !["ac", "t", "pg", "wd", "ids", "h"].contains($0.name) }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        c.fragment = nil
        return c.url?.absoluteString ?? s
    }

    /// Validates by fetching the class list, then saves.
    @discardableResult
    func add(name: String, api raw: String, adult: Bool, origin: String = "manual") async throws -> CMSSite {
        let api = try Self.normalize(raw)
        let cats = try await MacCMSProvider.fetchCategories(api: api)
        var site = CMSSite(key: CMSSite.key(for: api), name: name.isEmpty ? (URL(string: api)?.host ?? "采集站") : name, api: api,
                           adult: adult, categories: cats, origin: origin)
        if let i = sites.firstIndex(where: { $0.key == site.key }) { site.enabled = sites[i].enabled; sites[i] = site } else { sites.append(site) }
        save()
        return site
    }
    #if DEBUG
    func debugInsert(_ site: CMSSite) { sites.removeAll { $0.key == site.key }; sites.append(site); save() }
    #endif
    func remove(_ key: String) { sites.removeAll { $0.key == key }; save() }
    func setEnabled(_ key: String, _ on: Bool) { if let i = sites.firstIndex(where: { $0.key == key }) { sites[i].enabled = on; save() } }
    func setAdult(_ key: String, _ on: Bool) { if let i = sites.firstIndex(where: { $0.key == key }) { sites[i].adult = on; save() } }
    func cacheCategories(_ key: String, _ cats: [PluginCategory]) {
        guard let i = sites.firstIndex(where: { $0.key == key }), sites[i].categories != cats else { return }
        sites[i].categories = cats; save()
    }
    var visibleSites: [CMSSite] { sites.filter { !$0.adult || SourceGate.shared.unlocked } }
}

struct MacCMSProvider: SiteProvider {
    let source: DramaSource
    let site: CMSSite

    init(source: DramaSource, site: CMSSite) { self.source = source; self.site = site }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        ProxySettings.shared.apply(to: c)
        return URLSession(configuration: c)
    }()

    static func url(_ api: String, _ q: [String: String]) -> URL? {
        guard var c = URLComponents(string: api) else { return nil }
        c.queryItems = (c.queryItems ?? []) + q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    static func fetch(_ api: String, _ q: [String: String]) async throws -> [String: Any] {
        guard let u = url(api, q), let host = u.host, u.scheme == "https" else { throw ProviderError.invalid("采集接口地址无效") }
        let blocked = await Task.detached { NetGuard.resolvesToBlocked(host) }.value
        if blocked { throw ProviderError.invalid("采集接口解析到内网地址") }
        var data: Data
        if let fx = PluginFixtures.responder, let r = fx(URLRequest(url: u)) { data = r.body }
        else {
            var req = URLRequest(url: u)
            req.setValue(PluginHostContext.defaultUA, forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw ProviderError.upstream("采集站 HTTP \(code) · \(host)") }
            if let fu = resp.url?.host, fu != host, NetGuard.resolvesToBlocked(fu) { throw ProviderError.invalid("跳转到内网地址") }
            data = d
        }
        guard data.count < 8 << 20, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.upstream("采集站没有返回 JSON（可能只支持 XML 或需要 ?ac=detail）")
        }
        return o
    }

    static func parseCategories(_ o: [String: Any]) -> [PluginCategory] {
        ((o["class"] as? [[String: Any]]) ?? []).compactMap { c in
            let id = PluginOut.s(c["type_id"]), name = PluginOut.s(c["type_name"], max: 30)
            guard !id.isEmpty, !name.isEmpty, !ContentFilter.isBlocked([name]) else { return nil }
            return PluginCategory(id: id, name: name)
        }
    }

    static func fetchCategories(api: String) async throws -> [PluginCategory] {
        let o = try await fetch(api, ["ac": "list"])
        guard o["list"] != nil || o["class"] != nil else { throw ProviderError.upstream("不像苹果 CMS 接口（缺少 list/class 字段）") }
        return parseCategories(o)
    }

    static func parseItems(_ o: [String: Any], source: DramaSource) -> [HGSeries] {
        ((o["list"] as? [[String: Any]]) ?? []).compactMap { v in
            let id = PluginOut.s(v["vod_id"]), title = PluginOut.s(v["vod_name"], max: 200)
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let tags = [PluginOut.s(v["type_name"], max: 30), PluginOut.s(v["vod_class"], max: 60)].filter { !$0.isEmpty }
            guard !ContentFilter.isBlocked([title] + tags) else { return nil }
            var cover = PluginOut.s(v["vod_pic"], max: 2000)
            if cover.hasPrefix("//") { cover = "https:" + cover }
            if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst(7) }
            return HGSeries(source: source, seriesId: id, title: title, cover: cover, subtitle: PluginOut.s(v["vod_remarks"], max: 40).nilIfEmpty,
                            author: PluginOut.s(v["vod_director"], max: 60).nilIfEmpty,
                            actors: PluginOut.s(v["vod_actor"], max: 200).split(whereSeparator: { ",，/ ".contains($0) }).prefix(6).map(String.init),
                            orientation: "portrait", tags: tags)
        }
    }

    static func page(_ o: [String: Any], source: DramaSource, page p: Int) -> HGPage {
        let items = parseItems(o, source: source)
        let pageCount = Int(PluginOut.s(o["pagecount"])) ?? 0
        return HGPage(items: items, hasMore: !items.isEmpty && (pageCount == 0 ? items.count >= 10 : p < pageCount), nextOffset: p + 1)
    }

    /// `vod_play_from` "a$$$b", `vod_play_url` "第1集$url#第2集$url$$$..." → lines of (name, [(epName, url)]).
    static func lines(from: String, urls: String) -> [(name: String, eps: [(String, String)])] {
        let names = from.components(separatedBy: "$$$")
        return urls.components(separatedBy: "$$$").enumerated().compactMap { i, chunk in
            let eps: [(String, String)] = chunk.split(separator: "#").enumerated().compactMap { j, e in
                let parts = e.split(separator: "$", maxSplits: 1).map(String.init)
                let (n, u) = parts.count == 2 ? (parts[0], parts[1]) : ("第\(j + 1)集", parts.first ?? "")
                return u.isEmpty ? nil : (n.trimmingCharacters(in: .whitespaces), u.trimmingCharacters(in: .whitespaces))
            }
            return eps.isEmpty ? nil : ((i < names.count ? names[i] : "线路\(i + 1)"), eps)
        }
    }
    static func isDirect(_ u: String) -> Bool {
        let l = u.lowercased()
        return (l.hasPrefix("https://") || l.hasPrefix("http://")) && (l.contains(".m3u8") || l.contains(".mp4"))
    }

    static func parseDetail(_ o: [String: Any], series s: HGSeries, source: DramaSource) throws -> HGSeriesDetail {
        guard let v = (o["list"] as? [[String: Any]])?.first else { throw ProviderError.upstream("采集站没有返回详情") }
        let title = PluginOut.s(v["vod_name"], max: 200).nonEmptyOr(s.title)
        let tags = [PluginOut.s(v["type_name"], max: 30)] + PluginOut.s(v["vod_class"], max: 80).split(separator: ",").map(String.init)
        guard !ContentFilter.isBlocked([title] + tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let all = lines(from: PluginOut.s(v["vod_play_from"], max: 2000), urls: (v["vod_play_url"] as? String) ?? "")
        // Prefer lines with direct m3u8/mp4 (no parser needed); keep them all as alternative 播放源.
        let direct = all.filter { $0.eps.contains { isDirect($0.1) } }
        guard let main = direct.max(by: { $0.eps.count < $1.eps.count }) else { throw ProviderError.unsupported("该资源没有可直接播放的线路（需要解析器的线路暂不支持）") }
        let eps = main.eps.enumerated().map { i, e -> HGEpisode in
            let alts: [[String: String]] = direct.compactMap { l in i < l.eps.count && isDirect(l.eps[i].1) ? ["n": l.name, "u": l.eps[i].1] : nil }
            let media = (try? JSONSerialization.data(withJSONObject: alts)).map { String(decoding: $0, as: UTF8.self) }
            return HGEpisode(ep: i + 1, vid: "\(s.seriesId)#\(i)", duration: 0, title: e.0.isEmpty ? "第\(i + 1)集" : e.0, page: main.name, media: media)
        }
        var cover = PluginOut.s(v["vod_pic"], max: 2000)
        if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst(7) }
        var desc = PluginOut.s(v["vod_content"], max: 4000)
        desc = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&nbsp;", with: " ")
        let meta = [PluginOut.s(v["vod_year"]), PluginOut.s(v["vod_area"]), PluginOut.s(v["vod_remarks"])].filter { !$0.isEmpty }.joined(separator: " · ")
        return HGSeriesDetail(source: source, seriesId: s.seriesId, title: title, cover: cover.isEmpty ? s.cover : cover,
                              desc: [meta, desc].filter { !$0.isEmpty }.joined(separator: "\n"),
                              author: PluginOut.s(v["vod_director"], max: 60).nilIfEmpty,
                              actors: PluginOut.s(v["vod_actor"], max: 300).split(whereSeparator: { ",，/".contains($0) }).prefix(12).map { $0.trimmingCharacters(in: .whitespaces) },
                              onlineTime: 0, totalEps: eps.count, episodes: eps, tags: tags.filter { !$0.isEmpty },
                              episodeLabel: eps.count > 1 ? "共\(eps.count)集" : "长视频")
    }

    static func streams(for ep: HGEpisode) -> [HGStream] {
        let alts = ep.media.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: String]] } ?? []
        return alts.enumerated().compactMap { i, a in
            guard var u = a["u"] else { return nil }
            if u.hasPrefix("http://") { u = "https://" + u.dropFirst(7) }   // ATS; many CDNs serve both
            guard let url = URL(string: u), let h = url.host, !NetGuard.isIPLiteral(h) else { return nil }
            return HGStream(streamId: "cms\(i)", quality: (a["n"] ?? "线路\(i + 1)") + (u.contains(".m3u8") ? " · HLS" : " · MP4"), url: u, key: "",
                            kind: u.contains(".m3u8") ? .hls : .mp4Clear, headers: ["User-Agent": PluginHostContext.defaultUA])
        }
    }

    var categories: [SiteCategory] {
        let cats = CMSStore.site(site.key)?.categories ?? site.categories
        return [SiteCategory(id: "", title: "最新", path: "")] + cats.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }
    }

    func list(_ c: SiteCategory, page p: Int) async throws -> HGPage {
        var q = ["ac": "detail", "pg": String(p)]
        if !c.id.isEmpty { q["t"] = c.id }
        let o = try await Self.fetch(site.api, q)
        if c.id.isEmpty, p == 1, case let cats = Self.parseCategories(o), !cats.isEmpty {
            let k = site.key
            await MainActor.run { CMSStore.shared.cacheCategories(k, cats) }
        }
        return Self.page(o, source: source, page: p)
    }

    func search(_ q: String, page p: Int) async throws -> HGPage {
        Self.page(try await Self.fetch(site.api, ["ac": "detail", "wd": q, "pg": String(p)]), source: source, page: p)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        try Self.parseDetail(try await Self.fetch(site.api, ["ac": "detail", "ids": s.seriesId]), series: s, source: source)
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        var st = Self.streams(for: ep)
        if st.isEmpty {
            // Episode objects restored from history may lack `media`; refetch detail.
            let d = try await detail(s)
            if let e = d.episodes.first(where: { $0.vid == ep.vid }) ?? d.episodes.first(where: { $0.ep == ep.ep }) { st = Self.streams(for: e) }
        }
        guard let first = st.first else { throw ProviderError.unsupported("没有可播放的线路") }
        return HGResolvedVideo(vid: ep.vid, url: first.url, key: nil, duration: nil, expiresAt: nil, err: nil, streams: st)
    }
}
