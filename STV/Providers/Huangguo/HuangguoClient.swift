import Foundation
import CommonCrypto

/// Port of gateway provider/huangguo: three sub-sources called directly from the device.
///  - ai:     huangguoai.com mirrors (HTML scraping + small JSON API)
///  - video:  huangguo.video (HTML scraping, data-hls)
///  - legacy: cloudfront app API (AES-CBC params, AES-CBC encrypted responses, guest login)
enum HuangguoSub: String, CaseIterable, Identifiable {
    case ai, video, legacy
    var id: String { rawValue }
    var label: String { switch self { case .ai: "AI 站"; case .video: "视频站"; case .legacy: "App 源" } }
}

struct HuangguoChannel: Hashable, Identifiable {
    let sub: HuangguoSub
    let slug: String
    let title: String
    let isRank: Bool
    var id: String { sub.rawValue + "/" + slug }
}

actor HuangguoClient {
    static let shared = HuangguoClient()

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
    /// AI site mirrors (2026-11: old *.ediayikma.cc now 301 → *.adihsppe.cc; huangguoai.com is unreachable from
    /// mainland networks). More are discovered from the site's /go-home/ page and persisted.
    static let aiMirrors = ["https://00b4b.adihsppe.cc", "https://bsl8m.adihsppe.cc", "https://hgai12.com",
                            "https://brma.adihsppe.cc", "https://mzofzp.adihsppe.cc", "https://rpb7bz.adihsppe.cc", "https://v2tg.adihsppe.cc",
                            "https://huangguoai.com", "https://huangguoai.io", "https://huangguoai.me", "https://huangguoai.ai",
                            "https://thu.agdkczeyx.cc", "https://ttvoij.ediayikma.cc"]
    static let mirrorsKey = "stv.huangguo.aiMirrors"
    static let baseKey = "stv.huangguo.aiBase"
    static let videoBase = "https://huangguo.video"
    static let frontendURL = "https://d2pypzndaqisk.cloudfront.net"
    static let apiHosts = ["https://dr6skssi3nxbk.cloudfront.net", "https://d18ka9rqpfd3lo.cloudfront.net", "https://d37n0wjehmw08f.cloudfront.net"]
    static let cdnURL = "https://sjljsla.lkkwip.cn"
    static let legacyXUA = "BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;Terminal=1;IsH5=1;Sid=00000000000000000000000000000000"

    /// Note: the gateway's "ai-huanlian" (AI face-swap) channel is intentionally not ported.
    static let aiChannels: [HuangguoChannel] = [
        .init(sub: .ai, slug: "recommend", title: "精选推荐", isRank: false),
        .init(sub: .ai, slug: "newest", title: "最近上新", isRank: false),
        .init(sub: .ai, slug: "hot", title: "热播榜", isRank: true),
        .init(sub: .ai, slug: "rank-recommend", title: "推荐榜", isRank: true),
        .init(sub: .ai, slug: "potential", title: "潜力榜", isRank: true),
        .init(sub: .ai, slug: "ai-duanju", title: "AI短剧", isRank: false),
        .init(sub: .ai, slug: "ai-manju", title: "AI漫剧", isRank: false),
        .init(sub: .ai, slug: "ai-mogai", title: "AI魔改", isRank: false),
    ]
    static let videoChannels: [HuangguoChannel] = (0...4).map {
        .init(sub: .video, slug: String($0), title: ["全部", "MV/音乐剧", "短片", "连续剧", "片段"][$0], isRank: false)
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()
    private var aiBase: String?
    private var textCache: [String: (Date, String)] = [:]

    // MARK: HTTP

    private func fetch(_ url: String, referer: String, headers: [String: String] = [:]) async throws -> Data {
        guard let u = URL(string: url) else { throw ProviderError.invalid("bad url") }
        var r = URLRequest(url: u)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(referer, forHTTPHeaderField: "Referer")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.upstream("HTTP \(code)") }
        return d
    }
    private func text(_ url: String, referer: String, ttl: TimeInterval = 300) async throws -> String {
        if let (t, s) = textCache[url], Date().timeIntervalSince(t) < ttl { return s }
        let s = String(decoding: try await fetch(url, referer: referer), as: UTF8.self)
        textCache[url] = (Date(), s)
        if textCache.count > 60 { textCache.removeAll() }
        return s
    }

    /// Candidate order: last good base, discovered mirrors, built-in list.
    static func mirrorCandidates(defaults: UserDefaults = .standard) -> [String] {
        var out: [String] = []
        for m in [defaults.string(forKey: baseKey)].compactMap({ $0 }) + (defaults.stringArray(forKey: mirrorsKey) ?? []) + aiMirrors
        where !out.contains(m) { out.append(m) }
        return out
    }

    /// Mirror origins listed on a /go-home/ (发布页) page: same-site hosts only (huangguoai.* / *.adihsppe.cc / hgai*.com).
    static func discoveredMirrors(_ html: String) -> [String] {
        var out: [String] = []
        for m in HTML.all("https://((?:[a-z0-9-]+\\.)?(?:adihsppe\\.cc|huangguoai\\.(?:com|io|me|ai)|hgai\\d*\\.com))(?=[/\"'\\s<])", html) {
            let o = "https://" + m[1]
            if !out.contains(o) { out.append(o) }
        }
        return out
    }

    /// One mirror probe: GET / (redirects followed) and keep the FINAL origin so later POSTs don't hit a 301.
    private func probe(_ m: String) async -> (String, String)? {
        guard let u = URL(string: m + "/") else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 8)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await session.data(for: r), let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let body = String(decoding: d, as: UTF8.self)
        guard body.contains("hg-drama-card") || body.contains("videoInitialData") || body.contains("/ai-duanju/") else { return nil }
        let f = http.url ?? u
        return ("\(f.scheme ?? "https")://\(f.host ?? u.host ?? "")", body)
    }

    /// Races all mirrors (first valid wins), remembers the winner and learns new mirrors from /go-home/.
    private func ensureAIBase() async throws -> String {
        if let b = aiBase { return b }
        let cands = Self.mirrorCandidates()
        let won: (String, String)? = await withTaskGroup(of: (String, String)?.self) { g in
            for m in cands { g.addTask { await self.probe(m) } }
            for await r in g { if let r { g.cancelAll(); return r } }
            return nil
        }
        guard let (base, _) = won else { throw ProviderError.upstream("黄果 AI 站镜像均不可用（\(cands.count) 个）") }
        aiBase = base
        UserDefaults.standard.set(base, forKey: Self.baseKey)
        Task { await self.learnMirrors(base) }
        return base
    }

    private func learnMirrors(_ base: String) async {
        guard let h = try? await text(base + "/go-home/", referer: base + "/", ttl: 3600) else { return }
        let found = Self.discoveredMirrors(h)
        if !found.isEmpty { UserDefaults.standard.set(Array(found.prefix(24)), forKey: Self.mirrorsKey) }
    }

    // MARK: Lists

    func list(_ ch: HuangguoChannel, page: Int) async throws -> HGPage {
        switch ch.sub {
        case .ai:
            let base = try await ensureAIBase()
            if ch.isRank {
                guard page <= 1 else { return HGPage(items: [], hasMore: false) }
                let slug = ch.slug.replacingOccurrences(of: "rank-", with: "")
                let h = try await text("\(base)/ranks/\(slug)/", referer: base + "/")
                return HGPage(items: parseRankJSONLD(h, slug: slug), hasMore: false)
            }
            if ch.slug.hasPrefix("ai-") {
                let u = "\(base)/api/videos/category/\(ch.slug)?sort=hot&page=\(page)&size=24"
                if let d = try? await fetch(u, referer: "\(base)/\(ch.slug)/"),
                   let obj = try? JSONSerialization.jsonObject(with: d) {
                    let items = aiJSONCards(obj, base: base)
                    return HGPage(items: items, hasMore: items.count >= 24, nextOffset: page + 1)
                }
                guard page == 1 else { return HGPage(items: [], hasMore: false) }
                let h = try await text("\(base)/\(ch.slug)/", referer: base + "/")
                return HGPage(items: parseAICards(h, pageURL: "\(base)/\(ch.slug)/"), hasMore: false)
            }
            let u = "\(base)/\(ch.slug)/\(page)/"
            let items = parseAICards(try await text(u, referer: base + "/"), pageURL: u)
            return HGPage(items: items, hasMore: !items.isEmpty, nextOffset: page + 1)
        case .video:
            var q: [String] = []
            if ch.slug != "0" { q.append("category=\(ch.slug)") }
            if page > 1 { q.append("page=\(page)") }
            let u = Self.videoBase + "/videos" + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
            let items = parseVideoCards(try await text(u, referer: Self.videoBase + "/"), pageURL: u)
            return HGPage(items: items, hasMore: !items.isEmpty, nextOffset: page + 1)
        case .legacy:
            await ensureImageCDN()
            let obj = try await legacy("/api/app/playlet/home/tab/" + ch.slug,
                                       params: ["pageNumber": "\(page)", "pageSize": "20", "tabSortType": "1"])
            let rows = J.arr(J.dict(obj)["list"]).compactMap { $0 as? [String: Any] }
            let items = rows.compactMap { legacyItem($0) }
            return HGPage(items: items, hasMore: rows.count >= 20, nextOffset: page + 1)
        }
    }

    func legacyChannels() async throws -> [HuangguoChannel] {
        await ensureImageCDN()
        let obj = try await legacy("/api/app/playlet-tab/all", params: nil)
        let rows = (obj as? [Any]) ?? J.arr(J.dict(obj)["list"])
        return rows.compactMap { $0 as? [String: Any] }.compactMap {
            let id = J.str($0["id"]); let name = J.str($0["name"])
            return id.isEmpty ? nil : HuangguoChannel(sub: .legacy, slug: id, title: name.isEmpty ? id : name, isRank: false)
        }
    }

    /// 视频站 and AI 站 have real site search (huangguo.video `/search?q=`, AI mirror `/api/search?q=`); the old
    /// "first page of a few catalogs, then title contains" scan missed almost everything (issue #2 / #3).
    /// The legacy App 源 has no search endpoint, so it keeps the catalog scan.
    func search(_ q: String) async throws -> [HGSeries] {
        let needle = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let enc = q.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? needle
        var groups: [[HGSeries]] = [[], [], []]
        var errors: [String] = []
        await withTaskGroup(of: (Int, Result<[HGSeries], Error>).self) { g in
            g.addTask { (0, await Self.attempt {
                let page = Self.videoBase + "/search?q=" + enc
                let h = try await self.text(page, referer: Self.videoBase + "/")
                // Only the results section: the page also links trending titles elsewhere.
                let body = h.range(of: "id=\"search-content\"").map { String(h[$0.lowerBound...]) } ?? h
                let section = body.range(of: "</section>").map { String(body[..<$0.lowerBound]) } ?? body
                return await self.parseVideoCards(section, pageURL: page)
            }) }
            g.addTask { (1, await Self.attempt {
                let base = try await self.ensureAIBase()
                var out: [HGSeries] = []
                for p in 1...2 {
                    let d = try await self.fetch("\(base)/api/search?q=\(enc)&page=\(p)&size=24", referer: base + "/")
                    let obj = try JSONSerialization.jsonObject(with: d)
                    let items = await self.aiJSONCards(obj, base: base)
                    out += items
                    let pages = J.int(J.dict(J.dict((obj as? [String: Any])?["data"])["pagination"])["pages"])
                    if items.count < 24 || p >= pages { break }
                }
                return out
            }) }
            g.addTask { (2, await Self.attempt {
                var out: [HGSeries] = []
                for ch in try await self.legacyChannels().prefix(6) { out += (try? await self.list(ch, page: 1).items) ?? [] }
                return out.filter { $0.title.lowercased().contains(needle) }
            }) }
            for await (i, r) in g {
                switch r { case .success(let s): groups[i] = s; case .failure(let e): errors.append(e.localizedDescription) }
            }
        }
        var seen = Set<String>()
        // Same rule as Android HuangguoClient.blocked: never return minors / non-consent titles.
        let hits = groups.joined().filter { !Self.blocked($0) && seen.insert($0.id).inserted }
        if hits.isEmpty, errors.count == groups.count, let e = errors.first { throw ProviderError.upstream(e) }
        return hits
    }

    // MARK: Detail

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let (sub, sid) = Self.split(s.seriesId)
        switch sub {
        case .ai:
            let base = try await ensureAIBase()
            let page = "\(base)/video/\(sid)/"
            let h = try await text(page, referer: base + "/")
            var eps = parseAIEpisodes(h, pageURL: page, sourceID: sid)
            if eps.isEmpty, case let m = aiVideoURL(h, pageURL: page), !m.isEmpty {
                eps = [HGEpisode(ep: 1, vid: "1", duration: 0, title: "第1集", page: page, media: m)]
            }
            var title = HTML.pageTitle(h); if HTML.titleNeedsRepair(title, sid) { title = s.title }
            return HGSeriesDetail(source: .huangguo, seriesId: s.seriesId, title: title, cover: Self.aiDetailCover(h, page: page, listCover: s.cover),
                                  desc: HTML.description(h), author: nil, actors: [], onlineTime: 0, totalEps: eps.count, episodes: eps)
        case .video:
            let path = sid.hasPrefix("series/") || sid.hasPrefix("video/") ? sid : "series/" + sid
            let page = Self.videoBase + "/" + path
            let h = try await text(page, referer: Self.videoBase + "/")
            var eps = path.hasPrefix("video/") ? [] : parseVideoEpisodes(h, pageURL: page)
            if eps.isEmpty, let m = dataHLS(h, page) { eps = [HGEpisode(ep: 1, vid: "1", duration: 0, title: "第1集", page: page, media: m)] }
            return HGSeriesDetail(source: .huangguo, seriesId: s.seriesId, title: HTML.pageTitle(h).nonEmpty ?? s.title,
                                  cover: HTML.resolve(page, HTML.ogImage(h)).nonEmpty ?? s.cover, desc: HTML.description(h),
                                  author: nil, actors: [], onlineTime: 0, totalEps: eps.count, episodes: eps)
        case .legacy:
            await ensureImageCDN()
            let raw = J.dict(try await legacy("/api/app/playlet/detail/" + sid, params: nil))
            var chapters = J.arr(raw["chapters"])
            if chapters.isEmpty { chapters = ((try? await legacy("/api/app/playlet-chapter/list/" + sid, params: nil)) as? [Any]) ?? [] }
            var eps: [HGEpisode] = []
            var seen = Set<String>()
            for (i, c) in chapters.compactMap({ $0 as? [String: Any] }).enumerated() {
                let media = J.firstNonEmpty(J.str(c["videoUrl"]), J.str(c["video_url"]), J.str(c["url"]), J.str(c["playUrl"]))
                if media.isEmpty { continue }
                let key = J.firstNonEmpty(HTML.cleanID(J.str(c["id"])), HTML.cleanID(media))
                guard seen.insert(key).inserted else { continue }
                let title = J.str(c["title"]).nonEmpty ?? J.str(c["name"])
                var idx = HTML.episodeIndex(title, 0); if idx <= 0 { idx = J.int(c["currentEpisode"]) }; if idx <= 0 { idx = i + 1 }
                eps.append(HGEpisode(ep: idx, vid: key, duration: J.int(c["mediaTime"]), title: title.nonEmpty ?? "第\(idx)集", media: media))
            }
            return HGSeriesDetail(source: .huangguo, seriesId: s.seriesId,
                                  title: J.firstNonEmpty(J.str(raw["title"]), J.str(raw["name"]), s.title),
                                  cover: Self.absCover(J.firstNonEmpty(J.str(raw["cover"]), J.str(raw["coverUrl"]), s.cover), base: imageCDN),
                                  desc: J.firstNonEmpty(J.str(raw["desc"]), J.str(raw["intro"]), J.str(raw["description"])),
                                  author: nil, actors: [], onlineTime: 0, totalEps: max(eps.count, J.int(raw["episodeCount"])), episodes: eps)
        }
    }

    // MARK: Resolve

    func resolve(seriesId: String, episode: HGEpisode) async throws -> HGResolvedVideo {
        let (sub, _) = Self.split(seriesId)
        var media = episode.media ?? ""
        var referer: String
        var headers = ["User-Agent": Self.userAgent]
        var keyFetchHeaders = headers
        switch sub {
        case .ai:
            let base = try await ensureAIBase()
            referer = base + "/"
            // 2026-11-09 site update: the page no longer embeds videoSrc; the player POSTs
            // /api/videos/<id>/episodes/<ep>/playback (anonymous OK) → {streams.main/hevc, cdn{authKey,authValue,app}}.
            let (_, sid) = Self.split(seriesId)
            if let pb = try? await aiPlayback(base: base, id: sid, ep: max(1, episode.ep), page: episode.page) {
                referer = (episode.page ?? base + "/video/\(sid)/")
                headers["Origin"] = base
                headers.merge(pb.cdn) { _, new in new }
                keyFetchHeaders = ["User-Agent": Self.userAgent, "Origin": base]
                media = pb.main
            } else if let p = episode.page {
                let page = try await text(p, referer: referer, ttl: 30)
                if media.isEmpty { media = aiVideoURL(page, pageURL: p) }
                // UAV-Downloader alignment: public episodes may require x-cdn-auth / x-cdn-app on the CDN.
                let cdn = Self.aiCDNHeaders(page, origin: base)
                headers.merge(cdn) { _, new in new }
                keyFetchHeaders.merge(cdn) { _, new in new }
            }
        case .video:
            referer = Self.videoBase + "/"
            if media.isEmpty, let p = episode.page { media = dataHLS(try await text(p, referer: referer, ttl: 30), p) ?? "" }
        case .legacy:
            let a = try await legacyAccess()
            let base = try await apiBase()
            referer = Self.frontendURL + "/"
            let path = media.hasPrefix("/") ? String(media.drop(while: { $0 == "/" })) : media
            media = "\(base)/api/app/vid/h5/m3u8/\(path)?token=\(GoURL.queryEscape(a.token))&c=\(GoURL.queryEscape(Self.cdnURL))"
            headers["Origin"] = Self.frontendURL
            headers["X-User-Agent"] = legacyUA(a)
            keyFetchHeaders = headers
        }
        headers["Referer"] = referer
        keyFetchHeaders["Referer"] = referer
        guard !media.isEmpty else { throw ProviderError.upstream("未解析到播放地址（可能需要登录或链接失效）") }

        if !media.lowercased().contains(".m3u8") && !media.contains("/m3u8/") {
            let s = HGStream(streamId: "mp4", quality: "source", url: media, key: "", kind: .mp4Clear, headers: headers)
            return HGResolvedVideo(vid: episode.vid, url: media, key: nil, duration: nil, expiresAt: nil, err: nil, streams: [s])
        }
        let master = String(decoding: try await fetch(media, referer: referer, headers: headers), as: UTF8.self)
        var targets: [(String, HLSPlaylist.Variant?)] = [(media, nil)]
        let vars = HLSPlaylist.variants(master, media)
        if !vars.isEmpty { targets = vars.map { ($0.url, $0) } }
        var streams: [HGStream] = []
        var duration: Double?
        for (i, (u, v)) in targets.prefix(4).enumerated() {
            let pl = v == nil ? master : String(decoding: (try? await fetch(u, referer: referer, headers: headers)) ?? Data(), as: UTF8.self)
            let k = HLSPlaylist.keys(pl, u)
            var keyHex = ""
            if k.encrypted, !k.uri.isEmpty, let d = try? await fetch(k.uri, referer: referer, headers: keyFetchHeaders) { keyHex = HLSPlaylist.keyHex(d) }
            if duration == nil { let d = HLSPlaylist.duration(pl); if d > 0 { duration = d } }
            streams.append(HGStream(streamId: "hls\(i)", quality: v.map(HLSPlaylist.quality) ?? "source", url: u, key: keyHex,
                                    width: v?.width, height: v?.height, bitrate: v?.bandwidth,
                                    kind: k.encrypted ? .hlsAES : .hls, headers: headers))
        }
        let note = streams.contains { $0.kind == .hlsAES && $0.key.isEmpty } ? "加密 HLS 未能取到密钥" : nil
        return HGResolvedVideo(vid: episode.vid, url: streams.first?.url, key: streams.first?.key, duration: duration,
                               expiresAt: nil, err: nil, streams: streams, note: note)
    }

    /// Same rule as Android HuangguoClient.blocked: the shared ContentFilter (minors) plus non-consent themes.
    static let nonConsent = ["强奸", "強姦", "强暴", "強暴", "迷奸", "迷姦", "轮奸", "輪姦", "下药", "下藥", "迷药", "迷藥", "催眠", "胁迫", "脅迫", "强迫", "強迫", "被迫",
                            "肉偿", "肉償", "凌辱", "侵犯", "猥亵", "猥褻", "非自愿", "囚禁", "绑架", "綁架", "偷拍", "盗摄", "醉奸", "睡奸", "性奴", "调教", "調教", "rape", "forced", "drugged", "hypno"]
    static func blocked(_ s: HGSeries) -> Bool {
        let t = [s.title, s.subtitle ?? ""]
        return ContentFilter.isBlocked(t) || t.contains { x in nonConsent.contains { x.localizedCaseInsensitiveContains($0) } }
    }

    static func attempt<T: Sendable>(_ f: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    // MARK: IDs

    static func split(_ ref: String) -> (HuangguoSub, String) {
        if let i = ref.firstIndex(of: ":"), let s = HuangguoSub(rawValue: String(ref[..<i])) { return (s, String(ref[ref.index(after: i)...])) }
        return (.ai, ref)
    }

    // MARK: AI parsing

    /// AI detail page cover. 2026-11: `og:image` points at a share host (expose.eisees.com) that answers
    /// 200 with an EMPTY body, so the hero stayed blank. The real cover is the page's `coverSrc` / `posterSrc`
    /// JSON (pic.drleao.cn, AES like the cards); then the list card's cover; og:image only as a last resort.
    static func aiDetailCover(_ h: String, page: String, listCover: String) -> String {
        func clean(_ s: String) -> String { HTML.unescape(s.replacingOccurrences(of: "\\/", with: "/")).trimmingCharacters(in: .whitespaces) }
        for key in ["coverSrc", "posterSrc", "cover_src", "poster", "cover"] {
            if let m = HTML.groups("\"\(key)\"\\s*:\\s*\"([^\"]+)\"", h), case let u = clean(m[1]), u.contains("://") || u.hasPrefix("/") {
                let abs = HTML.resolve(page, u)
                if !Self.deadCoverHost(abs) { return abs }
            }
        }
        if let m = HTML.groups("(https://pic\\.drleao\\.cn/[^\"'\\s<>]+)", h) { return clean(m[1]) }
        if !listCover.isEmpty { return listCover }
        let og = HTML.resolve(page, HTML.ogImage(h))
        return Self.deadCoverHost(og) ? "" : og
    }
    /// Hosts seen serving empty bodies for covers.
    static func deadCoverHost(_ url: String) -> Bool { (URL(string: url)?.host ?? "").hasSuffix("eisees.com") }

    private func aiItem(_ id: String, _ title: String, cover: String = "", base: String, eps: Int = 0, rank: Int? = nil, sub: String? = nil, tags: [String] = []) -> HGSeries {
        HGSeries(source: .huangguo, seriesId: "ai:" + id, title: title, cover: cover, rank: rank, subtitle: sub,
                 episodeCount: eps, tags: tags, page: "\(base)/detail/\(id)/")
    }

    private func parseAICards(_ html: String, pageURL: String) -> [HGSeries] {
        let base = aiBase ?? ""
        let markup = HTML.replace(HTML.nonContent, html, "")
        var out: [HGSeries] = []
        var pos: [String: Int] = [:]
        func add(_ s: HGSeries) {
            if let p = pos[s.seriesId] { if out[p].cover.isEmpty { out[p].cover = s.cover }; return }
            pos[s.seriesId] = out.count; out.append(s)
        }
        let starts = HTML.re("<div\\b[^>]*class=[\"'][^\"']*\\bhg-drama-card\\b[^\"']*[\"'][^>]*>")
            .matches(in: markup, range: NSRange(location: 0, length: (markup as NSString).length)).map(\.range.location)
        let ns = markup as NSString
        for (i, st) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let block = ns.substring(with: NSRange(location: st, length: end - st))
            var id = HTML.cleanID(HTML.attr(block, "data-track-id"))
            if id.isEmpty, let m = HTML.groups("href=[\"']([^\"']*/detail/([^\"'/?#]+)[^\"']*)[\"']", block) { id = HTML.cleanID(m[2]) }
            if id.isEmpty { continue }
            let title = [HTML.attr(block, "data-track-title"), HTML.classText(block, "hg-drama-card__title"), HTML.attr(block, "title"), HTML.attr(block, "alt")]
                .first { !HTML.titleNeedsRepair($0, id) } ?? id
            let cover = HTML.resolve(pageURL, HTML.attr(block, "data-src", "data-original", "src"))
            let epText = HTML.classText(block, "hg-drama-card__episode")
            let eps = Int(HTML.attr(block, "data-ep-base")) ?? HTML.episodeIndex(epText, 0)
            add(aiItem(id, title, cover: cover, base: base, eps: eps,
                       sub: [HTML.classText(block, "hg-drama-card__badge"), epText].filter { !$0.isEmpty }.joined(separator: " ").nonEmpty))
        }
        for m in HTML.all("<a\\b[^>]*href=[\"']([^\"']*/detail/([^\"'/?#]+)[^\"']*)[\"'][^>]*>.*?</a>", markup) {
            let id = HTML.cleanID(m[2]); if id.isEmpty { continue }
            let t = [HTML.attr(m[0], "title", "alt", "aria-label"), HTML.cleanText(m[0])].first { !HTML.titleNeedsRepair($0, id) }
            guard let t else { continue }
            add(aiItem(id, t, cover: HTML.resolve(pageURL, HTML.attr(m[0], "data-src", "data-original", "src")), base: base))
        }
        return out
    }

    private func aiJSONCards(_ obj: Any, base: String) -> [HGSeries] {
        var out: [HGSeries] = []
        var seen = Set<String>()
        func walk(_ v: Any) {
            if let a = v as? [Any] { a.forEach(walk); return }
            guard let m = v as? [String: Any] else { return }
            if m["id"] != nil {
                var id = J.firstNonEmpty(J.str(m["id"]), J.str(m["videoId"]), J.str(m["slug"]))
                let d = HTML.detailID(id); if !d.isEmpty { id = d }
                id = HTML.cleanID(id)
                let title = J.firstNonEmpty(J.str(m["title"]), J.str(m["name"]), J.str(m["videoTitle"]))
                if !id.isEmpty, !HTML.titleNeedsRepair(title, id), seen.insert(id).inserted {
                    let cover = J.firstNonEmpty(J.str(m["cover"]), J.str(m["coverUrl"]), J.str(m["cover_url"]), J.str(m["coverImage"]), J.str(m["image"]), J.str(m["thumbnail"]), J.str(m["poster"]))
                    let eps = Int(J.firstPositive(m["episode_count"], m["episodeCount"], m["total_episodes"], m["totalEpisodes"], m["episodes"]))
                    out.append(aiItem(id, title, cover: HTML.resolve(base + "/", cover), base: base, eps: eps,
                                      sub: J.firstNonEmpty(J.str(m["remark"]), J.str(m["vod_remarks"])).nonEmpty))
                }
                return
            }
            m.values.forEach(walk)
        }
        walk(obj)
        return out
    }

    private func parseRankJSONLD(_ html: String, slug: String) -> [HGSeries] {
        let base = aiBase ?? ""
        var covers: [String: String] = [:]
        for m in HTML.all("href=[\"']([^\"']*/video/(\\d+)[^\"']*)[\"']", html) {
            let id = m[2]
            if covers[id] != nil { continue }
            if let range = html.range(of: m[0]) {
                let window = String(html[range.lowerBound...].prefix(1200))
                if let c = HTML.groups("https://pic\\.drleao\\.cn[^\"\\s<>]+", window) {
                    covers[id] = c[0]
                }
            }
        }
        for b in HTML.all("<script[^>]*ld\\+json[^>]*>(.*?)</script>", html) {
            guard let d = HTML.unescape(b[1]).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            for g in J.arr(o["@graph"]).compactMap({ $0 as? [String: Any] }) where J.str(g["@type"]) == "ItemList" && J.str(g["@id"]).hasSuffix("/ranks/\(slug)/#itemlist") {
                return J.arr(g["itemListElement"]).compactMap { $0 as? [String: Any] }.compactMap { e in
                    let id = Self.aiID(J.str(e["url"])); let n = J.str(e["name"])
                    return id.isEmpty || n.isEmpty ? nil : aiItem(id, n, cover: covers[id] ?? "", base: base, rank: J.int(e["position"]))
                }
            }
        }
        return []
    }

    private func parseAIEpisodes(_ html: String, pageURL: String, sourceID: String) -> [HGEpisode] {
        let markup = HTML.replace(HTML.nonContent, html, "")
        let ms = HTML.all("<a\\b[^>]*href=[\"']([^\"']*/video/[^\"']+)[\"'][^>]*>.*?</a>", markup)
        func link(_ href: String) -> (String, String)? {
            let full = HTML.resolve(pageURL, href)
            guard let u = URL(string: full) else { return nil }
            let parts = u.path.split(separator: "/").map(String.init)
            guard (parts.count == 2 || parts.count == 3), parts[0] == "video", parts[1] == sourceID else { return nil }
            return (full, parts.count == 3 ? HTML.cleanID(parts[2]) : "1")
        }
        func control(_ a: String) -> Bool { !HTML.attr(a, "data-ep-id").isEmpty || HTML.attr(a, "class").split(separator: " ").contains("hg-web-play__ep") }
        let marked = ms.contains { link($0[1]) != nil && control($0[0]) }
        var seen = Set<String>(), used = Set<Int>()
        var eps: [HGEpisode] = []
        for m in ms {
            guard let (full, key) = link(m[1]), !marked || control(m[0]), !seen.contains(key), !seen.contains(full) else { continue }
            seen.insert(key); seen.insert(full)
            let title = HTML.attr(m[0], "title", "aria-label").nonEmpty ?? HTML.cleanText(m[0])
            var idx = Int(HTML.attr(m[0], "data-ep-id")) ?? 0
            if idx <= 0, let e = HTML.groups("/ep-(\\d+)(?:/|$)", full) { idx = Int(e[1]) ?? 0 } else if idx <= 0, key == "1" { idx = 1 }
            if idx <= 0 { idx = HTML.episodeIndex(title, eps.count + 1) }
            while used.contains(idx) { idx += 1 }
            used.insert(idx)
            let label = (title.isEmpty || Int(title) != nil || ["立即播放", "播放", "选集", "正片", "在线观看"].contains(title)) ? "第\(idx)集" : title
            eps.append(HGEpisode(ep: idx, vid: key, duration: 0, title: label, page: full))
        }
        return eps.sorted { $0.ep < $1.ep }
    }

    struct AIPlayback { var main: String; var hevc: String; var cdn: [String: String] }

    /// POST playback credentials (signed m3u8 URL + CDN auth header) for one episode.
    func aiPlayback(base: String, id: String, ep: Int, page: String?) async throws -> AIPlayback {
        guard id.allSatisfy(\.isNumber), let u = URL(string: "\(base)/api/videos/\(id)/episodes/\(ep)/playback") else {
            throw ProviderError.invalid("bad huangguo id")
        }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.httpBody = Data("{}".utf8)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        r.setValue(base, forHTTPHeaderField: "Origin")
        r.setValue(page ?? "\(base)/video/\(id)/", forHTTPHeaderField: "Referer")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.upstream("黄果 AI 取流接口 HTTP \(code)") }
        return try Self.parsePlayback(d, id: id, ep: ep)
    }

    static func parsePlayback(_ d: Data, id: String, ep: Int) throws -> AIPlayback {
        let env = try J.parse(d)
        guard J.int(env["status"]) == 1 || J.int(env["code"]) == 200 else {
            throw ProviderError.upstream(J.str(env["msg"]).nonEmpty ?? "黄果 AI 取流失败")
        }
        let data = J.dict(env["data"])
        guard J.str(data["manifest_method"]).uppercased() == "GET", J.str(data["id"]) == id, J.int(data["ep"]) == ep else {
            throw ProviderError.upstream("黄果 AI 取流参数不匹配")
        }
        let streams = J.dict(data["streams"])
        let main = J.str(streams["main"])
        guard main.hasPrefix("https://") else { throw ProviderError.upstream("黄果 AI 未返回播放地址") }
        let cdn = J.dict(data["cdn"])
        var h: [String: String] = [:]
        let key = J.str(cdn["authKey"]), value = J.str(cdn["authValue"]), app = J.str(cdn["app"])
        if (cdn["m3u8Enabled"] as? Bool ?? false) || (cdn["otherEnabled"] as? Bool ?? false),
           key.lowercased() == "x-cdn-auth", !value.isEmpty, !app.isEmpty, value.count <= 2048, app.count <= 64,
           !(value + app).unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) {
            h = ["x-cdn-auth": value, "x-cdn-app": app]
        }
        return AIPlayback(main: main, hevc: J.str(streams["hevc"]), cdn: h)
    }

    /// `videoInitialData.cdnAuthKey/cdnAuthValue/cdnApp` → CDN auth headers (+ Origin), as in UAV-Downloader
    /// `sites/huangguo.py` (Apache-2.0). Only when the page enables them and the values look sane.
    static func aiCDNHeaders(_ html: String, origin: String) -> [String: String] {
        guard let m = HTML.groups("<script\\b[^>]*id=[\"']videoInitialData[\"'][^>]*>(.*?)</script>", html),
              let d = HTML.unescape(m[1]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        let key = J.str(o["cdnAuthKey"]), value = J.str(o["cdnAuthValue"]), app = J.str(o["cdnApp"])
        let enabled = (o["cdnM3u8Enabled"] as? Bool ?? false) || (o["cdnOtherEnabled"] as? Bool ?? false)
        guard enabled, key.lowercased() == "x-cdn-auth", !value.isEmpty, !app.isEmpty,
              value.count <= 2048, app.count <= 64,
              !(value + app).unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else { return [:] }
        return ["x-cdn-auth": value, "x-cdn-app": app, "Origin": origin]
    }

    private func aiVideoURL(_ html: String, pageURL: String) -> String {
        if let m = HTML.groups("<script\\b[^>]*id=[\"']videoInitialData[\"'][^>]*>(.*?)</script>", html),
           let d = HTML.unescape(m[1]).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let direct = HTML.mediaURL(pageURL, J.firstNonEmpty(J.str(o["videoSrc"]), J.str(o["videoUrl"]), J.str(o["playUrl"])))
            if !direct.isEmpty { return direct }
            let eps = J.dict(o["epPlaySrcs"])
            var pref = J.firstNonEmpty(J.str(o["ep"]), J.str(o["episode"]))
            if let e = HTML.groups("/ep-(\\d+)(?:/|$)", pageURL) { pref = e[1] }
            if !pref.isEmpty, case let u = HTML.mediaURL(pageURL, J.str(eps[pref])), !u.isEmpty { return u }
            for k in eps.keys.sorted(by: { HTML.episodeIndex($0, Int($0) ?? 0) < HTML.episodeIndex($1, Int($1) ?? 0) }) {
                let u = HTML.mediaURL(pageURL, J.str(eps[k])); if !u.isEmpty { return u }
            }
        }
        if let m = HTML.groups("data-play-src=[\"']([^\"']+)[\"']", html), case let u = HTML.mediaURL(pageURL, m[1]), !u.isEmpty { return u }
        for m in HTML.all("[\"']?(?:videoSrc|videoUrl|playUrl)[\"']?\\s*[:=]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)(?:[^\"']*)?)[\"']", html) {
            let u = HTML.mediaURL(pageURL, m[1]); if !u.isEmpty { return u }
        }
        return ""
    }

    /// /detail/<id>/ or (newer site) /video/<id>/.
    static func aiID(_ url: String) -> String {
        let d = HTML.detailID(url); if !d.isEmpty { return d }
        let parts = (URL(string: url)?.path ?? url).split(separator: "/").map(String.init)
        return parts.count == 2 && parts[0] == "video" ? HTML.cleanID(parts[1]) : ""
    }

    // MARK: video parsing

    private func videoRef(_ href: String) -> (String, String)? {
        let path = URL(string: HTML.unescape(href))?.path ?? href
        let parts = path.split(separator: "/").map(String.init)
        for i in 0..<max(0, parts.count - 1) where parts[i] == "series" || parts[i] == "video" {
            let c = HTML.cleanID(parts[i + 1]); return c.isEmpty ? nil : (parts[i], parts[i] + "/" + c)
        }
        return nil
    }
    private func videoCards(_ html: String) -> [String] {
        let b = HTML.all("<article\\b[^>]*class=[\"'][^\"']*\\bvideo-card\\b[^\"']*[\"'][^>]*>.*?</article>", html).map { $0[0] }
        return b.isEmpty ? HTML.all("<a\\b[^>]*href=[\"']([^\"']*/(?:series|video)/([^\"'/?#]+)[^\"']*)[\"'][^>]*>.*?</a>", html).map { $0[0] } : b
    }
    private static let mediaLink = "<a\\b[^>]*href=[\"']([^\"']*/(?:series|video)/([^\"'/?#]+)[^\"']*)[\"'][^>]*>.*?</a>"

    private func parseVideoCards(_ html: String, pageURL: String) -> [HGSeries] {
        var seen = Set<String>()
        return videoCards(html).compactMap { b in
            guard let l = HTML.groups(Self.mediaLink, b), let (_, sid) = videoRef(l[1]), seen.insert(sid).inserted else { return nil }
            let title = HTML.attr(b, "title", "alt", "aria-label").nonEmpty ?? HTML.cleanText(b)
            return HGSeries(source: .huangguo, seriesId: "video:" + sid, title: title,
                            cover: HTML.resolve(pageURL, HTML.attr(b, "data-src", "data-original", "src")),
                            subtitle: HTML.classText(b, "text-gold-dim").nonEmpty, page: HTML.resolve(pageURL, l[1]))
        }
    }

    private func parseVideoEpisodes(_ html: String, pageURL: String) -> [HGEpisode] {
        var seen = Set<String>()
        var eps: [HGEpisode] = []
        for b in videoCards(html) {
            guard let l = HTML.groups(Self.mediaLink, b), let (kind, sid) = videoRef(l[1]), kind == "video" else { continue }
            let key = String(sid.dropFirst("video/".count))
            guard seen.insert(key).inserted else { continue }
            let title = HTML.attr(b, "title").nonEmpty ?? HTML.attr(b, "alt").nonEmpty ?? HTML.cleanText(b)
            eps.append(HGEpisode(ep: HTML.episodeIndex(title, eps.count + 1), vid: key, duration: 0, title: title,
                                 page: HTML.resolve(pageURL, l[1]), media: dataHLS(b, pageURL)))
        }
        return eps.sorted { $0.ep < $1.ep }
    }
    private func dataHLS(_ html: String, _ page: String) -> String? {
        HTML.groups("data-hls=[\"']([^\"']+)[\"']", html).map { HTML.mediaURL(page, $0[1]) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Legacy (cloudfront) API

    struct LegacyAccess: Codable { var interfaceKey: String; var paramKey: String; var paramIV: String; var token: String; var deviceId: String }
    private var access: LegacyAccess?
    private var api: String?
    private var imageCDN: String = "https://zzzznnn.lkkwip.cn"

    private static var sessionURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("huangguo_session.json")
    }
    func resetSession() { access = nil; api = nil; aiBase = nil; textCache = [:]; UserDefaults.standard.removeObject(forKey: Self.baseKey); try? FileManager.default.removeItem(at: Self.sessionURL) }

    private func legacyUA(_ a: LegacyAccess) -> String {
        Self.legacyXUA.replacingOccurrences(of: "DevID=00000000000000000000000000000", with: "DevID=" + a.deviceId)
    }

    private func frontendScript() async throws -> String {
        let page = try await text(Self.frontendURL + "/", referer: Self.frontendURL + "/")
        for m in HTML.all("<script\\b[^>]*\\bsrc=[\"']([^\"']+)[\"']", page) where m[1].contains("/main-") && m[1].hasSuffix(".js") {
            let u = HTML.resolve(Self.frontendURL + "/", m[1])
            if URL(string: u)?.host == URL(string: Self.frontendURL)?.host { return try await text(u, referer: Self.frontendURL + "/", ttl: 3600) }
        }
        throw ProviderError.upstream("黄果官网未提供可识别的接口脚本")
    }

    private func apiBase() async throws -> String {
        if let api { return api }
        var cands = Self.apiHosts
        for pass in 0..<2 {
            if pass == 1 {
                guard let s = try? await frontendScript() else { break }
                cands = HTML.all("https://[a-z0-9]+\\.cloudfront\\.net", s).map { $0[0] }.filter { $0 != Self.frontendURL }
            }
            for c in cands {
                if let d = try? await fetch(c + "/api/app/ping/check", referer: Self.frontendURL + "/"),
                   J.int((try? J.parse(d))?["code"]) == 200 { api = c; return c }
            }
        }
        throw ProviderError.upstream("黄果旧 API 候选域名均不可用")
    }

    private func legacyAccess() async throws -> LegacyAccess {
        if let access { return access }
        if let d = try? Data(contentsOf: Self.sessionURL), let a = try? JSONDecoder().decode(LegacyAccess.self, from: d), !a.token.isEmpty {
            access = a; return a
        }
        let s = try await frontendScript()
        func val(_ n: String) -> String { HTML.groups("[\"']" + n + "[\"']\\s*[:,]\\s*[\"']([^\"'\\\\\\r\\n]+)[\"']", s)?[1] ?? "" }
        let ik = val("interfaceKey"), pk = val("parameterKey"), piv = val("parameterIv")
        guard !ik.isEmpty, pk.utf8.count == 16, piv.utf8.count == 16 else { throw ProviderError.upstream("黄果官网协议已变化，无法识别当前接口参数") }
        let dev = Bytes.hex(Bytes.random(8)).uppercased() + String(Int64(Date().timeIntervalSince1970 * 1000))
        var a = LegacyAccess(interfaceKey: ik, paramKey: pk, paramIV: piv, token: "", deviceId: dev)
        let login = J.dict(try await legacyRequest("POST", "/api/app/mine/login/h5", ["devID": dev, "sysType": "ios", "isAppStore": false], a))
        let tok = J.str(login["token"])
        guard !tok.isEmpty, !tok.contains(" ") else { throw ProviderError.upstream("黄果访客登录未返回有效令牌") }
        a.token = tok
        access = a
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: Self.sessionURL, options: .completeFileProtection) }
        return a
    }

    private func legacy(_ path: String, params: [String: Any]?) async throws -> Any {
        for attempt in 0..<2 {
            let a = try await legacyAccess()
            do { return try await legacyRequest("GET", path, params, a) }
            catch ProviderError.upstream(let m) where attempt == 0 && m.hasPrefix("5005") {
                access = nil; try? FileManager.default.removeItem(at: Self.sessionURL)
            }
        }
        throw ProviderError.upstream("黄果访客登录已失效，请稍后重试")
    }

    private func legacyRequest(_ method: String, _ path: String, _ params: [String: Any]?, _ a: LegacyAccess) async throws -> Any {
        let base = try await apiBase()
        var full = path
        var body: Data?
        if let params {
            let enc = try Self.aesCBC(encrypt: true, Array(J.encodeSorted(params)), key: Array(a.paramKey.utf8), iv: Array(a.paramIV.utf8)).base64EncodedString()
            if method == "GET" { full += (full.contains("?") ? "&" : "?") + "data=" + GoURL.queryEscape(enc) }
            else { body = J.encodeSorted(["data": enc]) }
        }
        var r = URLRequest(url: URL(string: base + full)!)
        r.httpMethod = method
        r.httpBody = body
        if !a.token.isEmpty { r.setValue(a.token, forHTTPHeaderField: "Authorization") }
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("test", forHTTPHeaderField: "temp")
        r.setValue(legacyUA(a), forHTTPHeaderField: "X-User-Agent")
        r.setValue(Self.frontendURL, forHTTPHeaderField: "Origin")
        r.setValue(Self.frontendURL + "/", forHTTPHeaderField: "Referer")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { if code >= 500 { api = nil }; throw ProviderError.upstream("黄果旧 API 返回 HTTP \(code)") }
        let env = try J.parse(d)
        let c = J.str(env["code"])
        if !c.isEmpty, c != "200", c != "0" {
            throw ProviderError.upstream("\(c) " + J.str(env["msg"]).replacingOccurrences(of: a.token, with: "[已隐藏]"))
        }
        let hash = env["hash"]
        let hashOn: Bool = { if let b = hash as? Bool { return b }; if let s = hash as? String { return !["", "false", "0", "null"].contains(s.lowercased()) }; return hash != nil && !(hash is NSNull) }()
        if hashOn, let s = env["data"] as? String {
            let plain = try Self.decryptResponse(s, interfaceKey: Array(a.interfaceKey.utf8))
            return try JSONSerialization.jsonObject(with: Data(plain), options: .fragmentsAllowed)
        }
        guard let data = env["data"], !(data is NSNull) else { throw ProviderError.upstream("黄果旧 API 未返回数据") }
        return data
    }

    private func legacyItem(_ row: [String: Any]) -> HGSeries? {
        let id = HTML.cleanID(J.firstNonEmpty(J.str(row["id"]), J.str(row["dramaId"]), J.str(row["playletId"])))
        guard !id.isEmpty else { return nil }
        let cover = Self.absCover(J.firstNonEmpty(J.str(row["cover"]), J.str(row["coverUrl"]), J.str(row["image"]), J.str(row["imageUrl"]), J.str(row["img"]), J.str(row["poster"])), base: imageCDN)
        return HGSeries(source: .huangguo, seriesId: "legacy:" + id,
                        title: J.firstNonEmpty(J.str(row["title"]), J.str(row["name"]), J.str(row["dramaName"]), id),
                        cover: cover,
                        subtitle: J.firstNonEmpty(J.str(row["remark"]), J.str(row["statusText"])).nonEmpty,
                        episodeCount: Int(J.firstPositive(row["episodeCount"], row["episode_count"], row["totalEpisodes"], row["total"])),
                        playCount: J.int(row["playCount"]))
    }


    static func absCover(_ raw: String, base: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return t.hasPrefix("http://") ? "https://" + t.dropFirst(7) : t }
        if t.hasPrefix("//") { return "https:" + t }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + t.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Refresh IMAGE CDN from /ping/domain/h5 (best-effort).
    private func ensureImageCDN() async {
        guard let data = try? await legacy("/api/app/ping/domain/h5", params: nil) else { return }
        let rows = J.arr(J.dict(data)["sourceList"])
        for r in rows.compactMap({ $0 as? [String: Any] }) where J.str(r["type"]).uppercased() == "IMAGE" {
            let domains = J.arr(r["domain"]).compactMap { $0 as? [String: Any] }
            if let u = domains.first(where: { J.int($0["status"]) == 0 }).map({ J.str($0["url"]) }) ?? domains.first.map({ J.str($0["url"]) }),
               !u.isEmpty {
                imageCDN = u.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return
            }
        }
    }

    static func aesCBC(encrypt: Bool, _ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> Data {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let st = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, input, input.count, &out, out.count, &moved)
        guard st == kCCSuccess else { throw ProviderError.invalid("AES 失败 \(st)") }
        return Data(out[0..<moved])
    }

    static func decryptResponse(_ s: String, interfaceKey: [UInt8]) throws -> [UInt8] {
        guard let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)).map(Array.init), raw.count >= 12 else {
            throw ProviderError.invalid("encrypted payload too short")
        }
        let r = interfaceKey + raw[0..<12]
        let l = r.count >> 1
        let sh = Array(Bytes.sha256(r)[8..<24])
        let d = Bytes.sha256(sh + r[0..<l])
        let f = Bytes.sha256(Array(r[l...]) + sh)
        let key = Array(d[0..<8]) + f[8..<24] + d[24...]
        let iv = Array(f[0..<4]) + d[12..<20] + f[28...]
        return Array(try aesCBC(encrypt: false, Array(raw[12...]), key: key, iv: iv))
    }
}

extension String {
    var nonEmpty: String? { let t = trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
}
