import Foundation
import CryptoKit

/// Direct-to-upstream port of the gateway hongguo provider (rank / search / detail / panel / category / resolve).
/// No gateway, no API key: the device registers its own anonymous device and signs requests locally.
actor HongguoClient {
    static let shared = HongguoClient()

    private let session: URLSession
    /// Player batch only: bypass system proxy (proxied requests get 200 + 0 bytes; direct streams).
    let playerSession: URLSession
    private var device: HGDevice?
    private var registering: Task<HGDevice, Error>?
    private var searchEntered = false
    private var lastSearchQuery = ""
    private var lastSearchAt: Date?
    private let vmDeviceId = HongguoClient.vmID()
    private let vmInstallId = HongguoClient.vmID()
    /// Resolved play URLs (hongguo-open-player entry cache, 180 s) + in-flight dedupe for next-episode prefetch.
    var resolveCache: [String: (video: HGResolvedVideo, at: Date)] = [:]
    var resolveInflight: [String: Task<HGResolvedVideo, Error>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg)
        let pcfg = URLSessionConfiguration.ephemeral
        pcfg.timeoutIntervalForRequest = 20
        pcfg.httpCookieStorage = nil
        pcfg.httpShouldSetCookies = false
        // Empty dict alone does not defeat Clash TUN/fake-ip; still disable URLSession-level HTTP/HTTPS/SOCKS.
        pcfg.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "HTTPProxy": "", "HTTPSProxy": "", "SOCKSProxy": ""
        ]
        playerSession = URLSession(configuration: pcfg)
    }

    private static func vmID() -> String { String(1_000_000_000_000_000_000 + UInt64.random(in: 0..<8_000_000_000_000_000_000)) }

    // MARK: constants (fetch.go / rank_cell.go)
    private static let ua = HGDevice.ua
    /// AB-on form (dr_scene in path). Soft-rejected when server AB is off (2026-10-21).
    private static let urlBatch = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1?"
    /// AB-off form (dr_scene stays in body). Default preferred since 2026-10-21 gateway fix 2d70cfd.
    private static let urlBatchABOff = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/v1?"
    private static let urlDetail = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_detail/preload/v1?"
    private static let urlBookDir = "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/directory/all_items/v?"
    private static let urlCategory = "https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v:version/?"
    static let urlRankCell = "https://api5-normal-sinfonlinec.fqnovel.com/reading/bookapi/bookmall/cell/change/v:version/?"
    /// 「系列剧」落地页（scene=10 + stick_ids），与 gateway list.go buildSeriesLandingURL 一致。
    private static let urlPlan = "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/plan/v?"
    private static let urlVideoModel = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/"
    static let videoModelUA = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"


    /// Remember last successful batch endpoint form (gateway hgPlayerBatchBase). Default AB-off.
    private static var preferredBatchABOff = true

    private static func playerBatchBases() -> [String] {
        preferredBatchABOff ? [urlBatchABOff, urlBatch] : [urlBatch, urlBatchABOff]
    }

    private static func rememberPlayerBatchBase(_ base: String) {
        preferredBatchABOff = (base == urlBatchABOff)
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Device segment from `HGPlayerDevice` (gateway player_device.go); no longer hard-coded.
    private static func playerQuery(_ rt: Int64) -> String {
        HGPlayerDevice.queryPart() + "&ac=wifi&channel=ry_hongguo_offlinestore_04&aid=8662&app_name=novelread" +
        "&version_code=72133&version_name=7.2.133&device_platform=android&os=android&ssmix=a&device_type=EML-AL00&device_brand=HUAWEI" +
        "&language=zh&os_api=29&os_version=10&manifest_version_code=72133&resolution=1080*2340&dpi=480&update_version_code=72133&_rticket=\(rt)"
    }
    private static func detailQuery(_ rt: Int64) -> String {
        HGPlayerDevice.queryPart() + "&ac=wifi&channel=ry_hongguo_offlinestore_04&aid=8662&app_name=novelread" +
        "&version_code=73332&version_name=7.3.3.32&device_platform=android&os=android&ssmix=a&device_type=sdk_gphone64_arm64&device_brand=google" +
        "&language=en&os_api=35&os_version=15&manifest_version_code=73332&resolution=1080*2400&dpi=420&update_version_code=73332" +
        "&_rticket=\(rt)&&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=73332&compliance_status=0&need_personal_recommend=1" +
        "&player_so_load=1&is_android_pad_screen=0&rom_version=sdk_gphone64_arm64-userdebug+15+AE3A.240806.043+12960925+dev-keys" +
        "&cdid=22daeba8-ef23-4742-abbe-c41bc3d6d4c8"
    }
    static func listQuery(_ d: HGDevice, _ rt: Int64) -> String {
        let vc = HGDevice.versionCode
        return "iid=\(d.iid)&device_id=\(d.deviceId)&ac=wifi&channel=ry_hongguo_offlinestore_04&aid=8662&app_name=novelread" +
        "&version_code=\(vc)&version_name=\(HGDevice.appVersion)&device_platform=android&os=android&ssmix=a" +
        "&device_type=sdk_gphone64_arm64&device_brand=google&language=zh&os_api=35&os_version=15" +
        "&manifest_version_code=\(vc)&resolution=1080*2400&dpi=420&update_version_code=\(vc)&_rticket=\(rt)" +
        "&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=\(vc)&compliance_status=0&need_personal_recommend=1&player_so_load=1" +
        "&is_android_pad_screen=0&rom_version=sdk_gphone64_arm64-userdebug+15+AE3A.240806.043+12960925+dev-keys&cdid=\(d.cdid)"
    }

    // MARK: device

    func ensureDevice() async throws -> HGDevice {
        if let d = device { return d }
        if let d = HGDevice.load() { device = d; return d }
        if let t = registering { return try await t.value }
        let s = session
        // device_register occasionally answers device_id 0 (seen right after a burst); one short retry.
        let t = Task {
            do { return try await HGDevice.register(session: s) } catch {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await HGDevice.register(session: s)
            }
        }
        registering = t
        defer { registering = nil }
        let d = try await t.value
        device = d
        return d
    }

    func resetDevice() { device = nil; HGDevice.reset() }

    /// Last automatic re-registration (soft-reject recovery). Throttle so a blocked network can't hammer device_register.
    private var lastAutoReregister: Date?
    private static let autoReregisterMinInterval: TimeInterval = 30

    private static var hasPurePlayerOverride: Bool {
        guard let s = UserDefaults.standard.string(forKey: "stv.hg.purePlayerDevice") else { return false }
        let p = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return p.count == 2 && !p[0].isEmpty && !p[1].isEmpty
    }

    /// Proactive renewal before video_model: a registered device only plays for ~10 min after device_register, so a
    /// device restored on a cold start (or kept across a long session) is already dead. Same as tapping 「重置」.
    private func refreshDeviceIfStaleForPlayback() async {
        if Self.hasPurePlayerOverride { return }
        guard let d = device ?? HGDevice.load(), d.isStaleForPlayback else { return }
        if let t = lastAutoReregister, Date().timeIntervalSince(t) < Self.autoReregisterMinInterval { return }
        lastAutoReregister = Date()
        resetDevice()
        if let n = try? await ensureDevice() {
            NSLog("[HG] device …%@ older than %.0fs -> re-registered …%@", String(d.deviceId.suffix(4)),
                  HGDevice.playbackMaxAge, String(n.deviceId.suffix(4)))
        }
    }

    /// Automatic 「重置红果设备注册」: video_model soft-rejects (HTTP 200 + 0 bytes) a registered device after it has
    /// been used for a while, and nothing ever renewed it, so every later play came back empty until the user reset by hand.
    /// Drops the device only if it is still the one that failed (a concurrent prefetch may already have replaced it).
    /// Returns true when a different, usable device is now in place.
    private func reregisterAfterSoftReject(failedDeviceId did: String) async -> Bool {
        if Self.hasPurePlayerOverride { return false }          // user-pinned device: never replace it
        if let cur = device ?? HGDevice.load(), cur.deviceId != did { return true }
        if let t = lastAutoReregister, Date().timeIntervalSince(t) < Self.autoReregisterMinInterval { return false }
        lastAutoReregister = Date()
        resetDevice()
        do {
            let d = try await ensureDevice()
            NSLog("[HG] soft reject on device …%@ -> re-registered …%@", String(did.suffix(4)), String(d.deviceId.suffix(4)))
            return d.deviceId != did
        } catch {
            NSLog("[HG] auto re-register failed: %@", String(describing: error))
            return false
        }
    }

    // MARK: transport

    private func commonHeaders(_ req: inout URLRequest) {
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
        req.setValue("1506", forHTTPHeaderField: "comment-source")
        req.setValue("101", forHTTPHeaderField: "lc")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        req.setValue("5051452", forHTTPHeaderField: "passport-sdk-version")
        req.setValue("4.0.3.cn", forHTTPHeaderField: "x-vc-bdturing-sdk-version")
        req.setValue("cn-cq", forHTTPHeaderField: "x-tt-store-region")
        req.setValue("did", forHTTPHeaderField: "x-tt-store-region-src")
        req.setValue("0", forHTTPHeaderField: "x-xs-from-web")
        req.setValue("\(Self.nowMs())-\(Int.random(in: 100_000_000..<1_000_000_000))", forHTTPHeaderField: "x-reading-request")
    }

    private func send(_ req: URLRequest, retries: Int = 2) async throws -> [String: Any] {
        var last: Error = ProviderError.upstream("请求失败")
        for i in 0...retries {
            if i > 0 { try await Task.sleep(nanoseconds: UInt64(i) * 800_000_000) }
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if data.isEmpty { last = ProviderError.upstream("HTTP \(status) 空响应（上游软拒绝）"); continue }
                return try J.parse(data)
            } catch let e as ProviderError { last = e } catch { last = error }
        }
        throw last
    }

    /// GET / empty POST with list headers; `signed` adds the 6-header search signature.
    func list(_ url: String, method: String = "GET", signed: Bool = false) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw ProviderError.invalid("URL") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if method == "POST" { req.httpBody = Data() }
        commonHeaders(&req)
        if signed, let d = device {
            for (k, v) in try HGSign.fullHeaders(rawURL: url, device: d) { req.setValue(v, forHTTPHeaderField: k) }
        }
        return try await send(req)
    }

    /// gzip JSON POST with x-ss-stub (fetch.go postJSON). For detail/list — **not** player batch.
    private func postJSON(_ base: String, _ query: String, _ body: Data, retries: Int = 2) async throws -> [String: Any] {
        let gz = Gzip.compress(body)
        let now = Self.nowMs()
        var req = URLRequest(url: URL(string: base + query)!)
        req.httpMethod = "POST"
        req.httpBody = gz
        commonHeaders(&req)
        req.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
        req.setValue(String(now), forHTTPHeaderField: "x-ss-req-ticket")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        req.setValue(Bytes.hex(Bytes.md5(Array(gz))).uppercased(), forHTTPHeaderField: "x-ss-stub")
        return try await send(req, retries: retries)
    }

    /// Soft reject from multi_video_model/player/v1: HTTP 200 + 0 bytes (gateway errPlayerEmptyBody).
    private struct PlayerEmptyBody: Error {}

    /// Player batch dialect (gateway `postPlayerBatch`): **no gzip**; signer from `playerSigner(base)`.
    /// AB-off (`multi_video_model/v1`) → genericSessionHeaders (flags 0x0000 + Argus);
    /// AB-on (`…/player/v1`) → videoModelHeaders (0x84404…).
    private static func playerBatchURL(baseEndingWithQuestion base: String, query: String) -> URL {
        let root = String(base.dropLast())
        var c = URLComponents(string: root)!
        c.percentEncodedQuery = query
        return c.url!
    }

    private static func playerSignHeaders(base: String, query: String, body: Data, now: Date) -> [String: String] {
        let bytes = Array(body)
        if base == urlBatchABOff {
            return HGSign.genericSessionHeaders(rawQuery: query, body: bytes, now: now)
        }
        return HGSign.videoModelHeaders(rawQuery: query, body: bytes, now: now)
    }

    private func postPlayerBatch(_ base: String, _ query: String, _ body: Data) async throws -> [String: Any] {
        var last: Error = PlayerEmptyBody()
        for i in 0...2 {
            if i > 0 { try await Task.sleep(nanoseconds: UInt64(i) * 1_000_000_000) }
            let now = Date()
            var req = URLRequest(url: Self.playerBatchURL(baseEndingWithQuestion: base, query: query))
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
            req.setValue("2", forHTTPHeaderField: "Sdk-Version")
            for (k, v) in Self.playerSignHeaders(base: base, query: query, body: body, now: now) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            do {
                let (data, resp) = try await playerSession.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if data.isEmpty {
                    last = PlayerEmptyBody()
                    let form = (base == Self.urlBatchABOff) ? "ab_off" : "ab_on"
                    NSLog("[HG] player batch HTTP %d empty form=%@ attempt=%d", status, form, i + 1)
                    continue
                }
                return try J.parse(data)
            } catch let e as PlayerEmptyBody {
                last = e
            } catch {
                last = error
            }
        }
        throw last
    }

    func ok(_ j: [String: Any], _ what: String) throws -> [String: Any] {
        let code = J.str(j["code"])
        guard code == "0" else { throw ProviderError.upstream("\(what) code=\(code) \(J.str(j["message"]))") }
        return J.dict(j["data"])
    }

    // MARK: rank (rank_cell.go + rank_options.go)

    private static let rankSelected: [HGRankGenre: String] = [.all: "all", .human: "human", .comic: "comic_series_rank", .ai: "ai_playlet"]
    private static let rankSubIds: [HGRankGenre: [HGRankSub: String]] = [
        .all: [.subscribe: "ranklist_subscribe", .recommend: "ranklist_hot_sc", .hot: "ranklist_hot_play_sc", .zhenguo: "ranklist_prestige",
               .new: "ranklist_new_rank_sc", .mustWatch: "ranklist_must_watch", .followed: "ranklist_followed", .hotSearch: "ranklist_hot_search_sc"],
        .human: [.recommend: "human_hot_sc", .hot: "human_hot_play", .new: "human_new_rank", .hotSearch: "human_hot_search",
                 .mustWatch: "human_must_watch", .followed: "human_followed"],
        .comic: [.recommend: "comic_series_hot_rank", .hot: "comic_series_hot_play", .new: "comic_series_new_rank", .hotSearch: "comic_series_hot_search"],
        .ai: [.recommend: "ai_playlet_hot_sc", .hot: "ai_playlet_hot_play", .new: "ai_playlet_new_rank", .mustWatch: "ai_playlet_must_watch",
              .followed: "ai_playlet_followed", .hotSearch: "ai_playlet_hot_search"]
    ]

    func rank(sub: HGRankSub, genre: HGRankGenre, offset: Int = 0, seenIds: [String] = []) async throws -> HGPage {
        guard let selected = Self.rankSelected[genre], let subId = Self.rankSubIds[genre]?[sub] else {
            throw ProviderError.invalid("\(genre.label) 没有 \(sub.label) 榜")
        }
        let d = try await ensureDevice()
        let u = Self.urlRankCell + "background_selected_items&celebrity_user_id&cell_id=7470092475068071998" +
            "&client_req_type=2&client_template=2&filter_ids=" + GoURL.queryEscape(seenIds.joined(separator: ",")) +
            "&offset=\(offset)&panel_selected_items&rank_version=\(Int(Date().timeIntervalSince1970))&screen_width_px=1080" +
            "&selected_items=" + selected + "&sub_selected_items=" + subId + "&tab_type=26&unlimited_selector_change_type=1&" +
            Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u), "rank")
        var items: [HGSeries] = []
        var rank = offset
        for c in J.arr(J.dict(data["cell_view"])["cell_data"]) {
            for v in J.arr(J.dict(c)["video_data"]) {
                rank += 1
                var s = Self.parseVideoData(J.dict(v)); s.rank = rank
                items.append(s)
            }
        }
        let hasMore = J.bool(data["has_more"])
        return HGPage(items: items, hasMore: hasMore, nextOffset: J.int(data["next_offset"]), nextCursor: nil, sessionId: J.str(data["session_id"]))
    }

    // MARK: search (list.go buildSearchTabURL / parseSearchJSONForTab)

    private static func selectorId(_ f: HGContentFilter) -> String? {
        switch f { case .human: "content_type_short_play"; case .comic: "content_type_dynamic_comic"; case .ai: "content_type_ai_dynamic_comic"; case .all: nil }
    }

    /// cursor = previous nextCursor ("offset|passback").
    func search(_ q: String, contentFilter: HGContentFilter = .all, cursor: String? = nil) async throws -> HGPage {
        let d = try await ensureDevice()
        var offset = 0, passback = ""
        if let c = cursor, !c.isEmpty {
            let parts = c.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            offset = Int(parts[0]) ?? 0
            if parts.count > 1 { passback = String(parts[1]) }
        }
        // search page flags (device.go searchPageFlags)
        let last = lastSearchQuery.isEmpty ? q : lastSearchQuery
        let interval = lastSearchAt.map { max(0, Int64(Date().timeIntervalSince($0) * 1000)) } ?? 0
        let first = offset == 0 && !searchEntered
        if offset == 0 { searchEntered = true; lastSearchQuery = q; lastSearchAt = Date() }
        let sid = d.cdid.isEmpty ? "0" : d.cdid
        var u = "https://api5-normal-sinfonlinec.fqnovel.com/reading/bookapi/search/tab/v?" +
            "bookshelf_search_plan=4&live_room_id=0&user_is_login=0&bookstore_tab=-1&biz_config_ctx_infos&last_book_id=0" +
            "&last_search_page_query=" + GoURL.queryEscape(last) +
            "&clicked_content=page_search_button&report_info&use_lynx=false&last_book_consume_time=0&product_id=0&line_words_num=0" +
            "&tab_name&last_consume_interval=0&pad_column_cover=0&last_chapter_id=0&only_feed=false&offset=\(offset)" +
            "&from_rs=false&only_large_card=false&query=" + GoURL.queryEscape(q) +
            "&count=0&search_source=0&search_source_id=clks%23%23%23&use_correct=false&last_search_page_interval=\(interval)" +
            "&seed_product_id=0&from_half_screen=false&is_first_enter_search=\(first)" +
            "&iid=\(d.iid)&device_id=\(d.deviceId)&ac=wifi&channel=vivo_8662_64&aid=8662&app_name=novelread" +
            "&version_code=73532&version_name=7.3.5.32&device_platform=android&os=android&ssmix=a" +
            "&device_type=NX809J&device_brand=Nubia&language=zh&os_api=31&os_version=12" +
            "&manifest_version_code=73532&resolution=1280*720&dpi=240&update_version_code=73532&_rticket=\(Self.nowMs())" +
            "&normal_session_cnt_in_day=1&gender=2&cold_start_session_cnt_in_day=1&host_abi=arm64-v8a&dragon_device_type=pad" +
            "&sys_mini_window=0&pv_player=73532&app_mini_window=0&normal_session_id=" + GoURL.queryEscape(sid + "#1") +
            "&compliance_status=0&har_status=1&cold_start_session_id=" + GoURL.queryEscape(sid) +
            "&cold_start_session_cnt_in_life=1&charging=0&normal_session_cnt_in_life=1&is_power_save_mode=0&app_dark_mode=0" +
            "&screen_brightness=102&battery_pct=80&down_speed=30000&sys_dark_mode=0&need_personal_recommend=1&player_so_load=1" +
            "&font_scale=100&is_android_pad_screen=1&network_type=4&rom_version=Nubia-user+12.0.0+20171130.276299+release-keys" +
            "&current_volume=33&cdid=\(d.cdid)&client_ab_info=" +
            GoURL.queryEscape(#"{"middle_style_from_video":false,"result_style_from_video":false}"#)
        if let s = Self.selectorId(contentFilter) { u += "&selected_items=" + GoURL.queryEscape(s) }
        if !passback.isEmpty { u += "&passback=" + GoURL.queryEscape(passback) }

        var lastErr: Error = ProviderError.upstream("搜索失败")
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_600_000_000) }
            let j: [String: Any]
            do { j = try await list(u, signed: true) } catch { lastErr = error; continue }
            let code = J.str(j["code"])
            if code != "0" {
                lastErr = ProviderError.upstream("search code=\(code) \(J.str(j["message"]))")
                if code == "100103" { continue }
                break
            }
            var best = -1
            var page = HGPage(items: [], hasMore: false, nextOffset: nil, nextCursor: nil, sessionId: nil)
            for t in J.arr(j["search_tabs"]) {
                let tm = J.dict(t)
                let wanted = J.int(tm["tab_type"]) == 11 || J.str(tm["title"]) == "综合"
                if !wanted { continue }
                var items: [HGSeries] = []
                var seen = Set<String>()
                var lands: [SeriesLandRef] = []
                for c in J.arr(tm["data"]) {
                    let cm = J.dict(c)
                    let land = Self.seriesLandFromCell(cm)
                    if !land.stickIds.isEmpty {
                        lands.append(land)
                        continue
                    }
                    var vds = J.arr(cm["video_data"])
                    if vds.isEmpty, let one = cm["video_data"] as? [String: Any] { vds = [one] }
                    let fallbackSid = Self.firstID(cm, "book_id", "search_result_id")
                    for v in vds {
                        let vm = J.dict(v)
                        if contentFilter != .all, Self.contentFilterOf(vm) != contentFilter { continue }
                        var s = Self.parseVideoData(vm)
                        if s.seriesId.isEmpty { s.seriesId = fallbackSid }
                        if s.seriesId.isEmpty && s.title.isEmpty { continue }
                        if !s.seriesId.isEmpty { if seen.contains(s.seriesId) { continue }; seen.insert(s.seriesId) }
                        items.append(s)
                    }
                }
                let score = (items.isEmpty ? 0 : 10) + 100
                if score > best {
                    best = score
                    let next = J.int(tm["next_offset"])
                    let pb = J.str(tm["passback"])
                    // Expand 「系列剧」landing cards so every season appears in search.
                    for land in lands {
                        if let more = try? await self.seriesLanding(stickIds: land.stickIds, from: land.from, query: land.query, bookId: land.bookId) {
                            for var s in more {
                                if contentFilter != .all {
                                    // Landing cards lack content_type; keep all seasons of the franchise.
                                }
                                if s.seriesId.isEmpty && s.title.isEmpty { continue }
                                if !s.seriesId.isEmpty { if seen.contains(s.seriesId) { continue }; seen.insert(s.seriesId) }
                                items.append(s)
                            }
                        }
                    }
                    page = HGPage(items: items, hasMore: J.bool(tm["has_more"]), nextOffset: next,
                                  nextCursor: "\(next)|\(pb)", sessionId: nil)
                }
            }
            if best < 0 { lastErr = ProviderError.upstream("search 缺少综合栏"); continue }
            return page
        }
        throw lastErr
    }

    private static func contentFilterOf(_ vd: [String: Any]) -> HGContentFilter? {
        let det = J.dict(vd["video_detail"])
        switch J.firstPositive(vd["content_type"], det["content_type"]) {
        case 1: return .human
        case 1004: return J.firstNonEmpty(J.str(det["video_category_type"]), J.str(vd["video_category_type"])) == "ai_video" ? .ai : .comic
        default: return nil
        }
    }

    // MARK: detail (series.go)

    /// `web: false` skips the official-site scrape (cast / tags / rating) — the slowest leg; fill it in later with `enrich`.
    func detail(seriesId sid: String, web: Bool = true) async throws -> HGSeriesDetail {
        let body: [String: Any] = [
            "biz_param": [
                "detail_page_version": 0, "disable_digg_stat": false, "disable_video_relate_book": false,
                "image_shrink_datas_str": "W3siaW1hZ2VfdHlwZSI6MywiaW1hZ2Vfd2lkdGgiOjEwNzksInNocmlua190eXBlIjozfSx7ImltYWdlX3R5cGUiOjQsImltYWdlX3dpZHRoIjo5NCwic2hyaW5rX3R5cGUiOjR9XQ==",
                "need_all_video_definition": false, "need_mp4_align": false, "screen_width_px": "1079", "source": 7,
                "use_os_player": false, "use_server_dns": false
            ] as [String: Any],
            "dr_scene": "preload", "series_id": sid
        ]
        // Fire detail, directory and franchise landing concurrently (was a serial waterfall).
        let t0 = Date()
        async let detailJ = Self.timed("detail.preload", t0) { try? await self.postJSON(Self.urlDetail, Self.detailQuery(Self.nowMs()), J.encodeSorted(body), retries: 0) }
        async let dirJ = Self.timed("detail.directory", t0) { try? await self.bookDirectory(sid) }
        async let landedJ = Self.timed("detail.landing", t0) { try? await self.seriesLanding(stickIds: sid, maxPages: 2) }
        async let webJ = web ? Self.timed("detail.web", t0) { try? await self.webDetail(seriesId: sid) } : nil
        var vd: [String: Any] = [:]
        if let j = await detailJ, J.str(j["code"]) == "0" {
            vd = J.dict(J.dict(J.dict(j["data"])[sid])["video_data"])
        }
        let dir = await dirJ
        let landed = await landedJ
        let info = J.dict(J.dict(dir?["data"])["book_info"])
        if vd.isEmpty {
            guard let dir else { throw ProviderError.upstream("详情获取失败") }
            let data = J.dict(dir["data"])
            var eps: [HGEpisode] = []
            for (i, raw) in J.arr(data["item_data_list"]).enumerated() {
                let m = J.dict(raw)
                let vid = J.firstNonEmpty(J.str(m["item_id"]), J.str(m["vid"]))
                if vid.isEmpty { continue }
                let n = J.int(m["chapter_index"])
                eps.append(HGEpisode(ep: n > 0 ? n : i + 1, vid: vid, duration: 0, title: J.str(m["title"])))
            }
            let title = J.firstNonEmpty(J.str(info["book_name"]), J.str(info["original_book_name"]))
            let cover = J.str(info["thumb_url"])
            let total = max(J.int(info["serial_count"]), eps.count)
            let related = await self.loadRelatedSeries(seriesId: sid, title: title, cover: cover, episodeCount: total, videoData: [:], excludeId: sid, landed: landed)
            return Self.enrich(HGSeriesDetail(seriesId: sid, title: title,
                                  cover: J.str(info["thumb_url"]), desc: J.str(info["abstract"]),
                                  author: J.str(info["author"]), actors: Self.names(info["roles"], info["role"]),
                                  onlineTime: Int(J.unix(info["create_time"])), totalEps: max(J.int(info["serial_count"]), eps.count), episodes: eps,
                                  relatedSeries: related), with: await webJ)
        }
        var eps: [HGEpisode] = []
        for e in J.arr(vd["video_list"]) {
            let em = J.dict(e)
            let vid = J.str(em["vid"]); if vid.isEmpty { continue }
            eps.append(HGEpisode(ep: J.int(em["vid_index"]), vid: vid, duration: J.int(em["duration"]), title: J.str(em["title"])))
        }
        var actors = Self.celebrities(vd)
        if actors.isEmpty { actors = Self.names(info["roles"], info["role"]) }
        let title = J.str(vd["series_title"])
        let cover = J.str(vd["series_cover"])
        let total = J.int(vd["episode_cnt"])
        let related = await self.loadRelatedSeries(seriesId: sid, title: title, cover: cover, episodeCount: max(total, eps.count), videoData: vd, excludeId: sid, landed: landed)
        return Self.enrich(HGSeriesDetail(seriesId: sid, title: title, cover: cover,
                              desc: J.firstNonEmpty(J.str(vd["series_intro"]), J.str(info["abstract"])),
                              author: J.firstNonEmpty(J.str(info["author"]), J.str(info["source"])), actors: actors,
                              onlineTime: Int(J.unix(info["create_time"])), totalEps: J.int(vd["episode_cnt"]), episodes: eps,
                              relatedSeries: related), with: await webJ)
    }

    /// DEBUG: logs how long a 红果 request took since `t0` (one line per call, for latency work).
    private static func timed<T>(_ label: String, _ t0: Date, _ work: () async -> T?) async -> T? {
        let v = await work()
        #if DEBUG
        NSLog("%@", String(format: "[HG] t %@ %.2fs%@", label, Date().timeIntervalSince(t0), v == nil ? " (nil)" : ""))
        #endif
        return v
    }

    private func bookDirectory(_ sid: String) async throws -> [String: Any] {
        let now = Self.nowMs()
        var req = URLRequest(url: URL(string: Self.urlBookDir + Self.playerQuery(now) + "&book_id=" + sid)!)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
        req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
        req.setValue(String(now), forHTTPHeaderField: "x-ss-req-ticket")
        req.setValue(String(now / 1000), forHTTPHeaderField: "x-khronos")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        req.setValue("5051452", forHTTPHeaderField: "passport-sdk-version")
        let j = try await send(req, retries: 1)
        let code = J.str(j["code"])
        guard code == "0" || code.uppercased() == "SUCCESS" || J.str(j["message"]).uppercased() == "SUCCESS" else {
            throw ProviderError.upstream("directory code=\(code)")
        }
        return j
    }

    // MARK: panel / category (list.go)

    private var panelCache: (Date, HGPanel)?

    func panel() async throws -> HGPanel {
        if let (at, p) = panelCache, Date().timeIntervalSince(at) < 600 { return p }
        let d = try await ensureDevice()
        let u = Self.urlCategory + "need_selector_panel=true&req_type=only_panel&req_scene=default&" + Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u, method: "POST"), "panel")
        let rows = J.arr(data["selector_rows"]).map { r -> HGFilterRow in
            let rm = J.dict(r)
            return HGFilterRow(type: J.str(rm["type"]), name: J.str(rm["row_name"]), selectType: J.int(rm["selection_type"]),
                               items: J.arr(rm["items"]).map { HGFilterOption(id: J.str(J.dict($0)["selector_item_id"]), name: J.str(J.dict($0)["show_name"])) })
        }
        let p = HGPanel(rows: rows)
        panelCache = (Date(), p)
        return p
    }

    func category(filterIds: [String], offset: Int = 0, sessionId: String? = nil) async throws -> HGPage {
        let d = try await ensureDevice()
        var u = Self.urlCategory + "offset=\(offset)&need_selector_panel=false&limit=12&session_id=" + GoURL.queryEscape(sessionId ?? "") +
            "&client_req_type=3&req_type=only_content"
        if !filterIds.isEmpty { u += "&filter_ids=" + GoURL.queryEscape(filterIds.joined(separator: ",")) }
        u += "&" + Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u, method: "POST"), "category")
        let next = J.int(data["next_offset"])
        var sess = J.str(data["session_id"]); if sess.isEmpty { sess = sessionId ?? "" }
        let more = J.bool(data["has_more"]) && next > offset && !sess.isEmpty
        let items = J.arr(data["video_data"]).map { Self.parseVideoData(J.dict($0)) }
        return HGPage(items: items, hasMore: more, nextOffset: next, nextCursor: nil, sessionId: sess)
    }

    // MARK: resolve (resolve.go batch via postPlayerBatch → video_model.go single dialect)

    func resolveFresh(vid: String) async throws -> HGResolvedVideo {
        var sawSoftReject = false
        await refreshDeviceIfStaleForPlayback()
        _ = try? await ensureDevice()   // make sure a device_register device exists before video_model
        // Full Argus 551 / Ladon on single video_model first; legacy batch remains a fallback.
        let pureDid = Self.purePlayerDeviceID
        if let r = try await resolvePureLevels(vid, sawSoftReject: &sawSoftReject) { return r }
        // Soft reject on the registered device = that device has gone stale upstream. Re-register once and retry,
        // instead of falling through to the legacy dialects (they use minted devices and are soft-rejected anyway).
        if sawSoftReject, await reregisterAfterSoftReject(failedDeviceId: pureDid) {
            if let r = try await resolvePureLevels(vid, sawSoftReject: &sawSoftReject) { return r }
        }
        for level in [3, 4] {
            try Task.checkCancellation()
            do {
                if let r = try await resolveBatch(vid, level: level) {
                    if r.err == Self.byteVC2Only && level == 3 { continue }
                    return r
                }
            } catch is PlayerEmptyBody {
                sawSoftReject = true
                NSLog("[HG] resolveBatch soft-reject level=%d", level)
            } catch {
                NSLog("[HG] resolveBatch error level=%d: %@", level, String(describing: error))
            }
        }
        for level in [3, 4] {
            try Task.checkCancellation()
            do {
                let r = try await resolveSingle(vid, level: level)
                if r.err == Self.byteVC2Only && level == 3 { continue }
                return r
            } catch let e as ProviderError {
                if case .upstream(let m) = e, m.contains("空响应") || m.contains("软拒绝") { sawSoftReject = true }
                NSLog("[HG] resolveSingle error level=%d: %@", level, e.localizedDescription)
                if level == 4 { break }
            } catch {
                NSLog("[HG] resolveSingle error level=%d: %@", level, String(describing: error))
            }
        }
        if sawSoftReject {
            throw ProviderError.upstream("取流被上游空包拒绝（软拒绝）")
        }
        throw ProviderError.upstream("取链失败")
    }

    /// Pure video_model at level 3 then 4. An empty body at level 3 means the device is rejected, so level 4 is
    /// skipped (it would only spend another request on a dead device).
    private func resolvePureLevels(_ vid: String, sawSoftReject: inout Bool) async throws -> HGResolvedVideo? {
        for level in [3, 4] {
            try Task.checkCancellation()
            do {
                let r = try await resolvePure(vid, level: level)
                if r.err == Self.byteVC2Only && level == 3 { continue }
                return r
            } catch is PlayerEmptyBody {
                sawSoftReject = true
                NSLog("[HG] resolvePure empty level=%d", level)
                return nil
            } catch {
                NSLog("[HG] resolvePure error level=%d: %@", level, String(describing: error))
            }
        }
        return nil
    }

    // MARK: pure player (gateway player_pure.go, 7.3.9.32 profile)

    private static let purePlayerHost = "api5-normal-sinfonlinea.fqnovel.com"
    private static let purePlayerPath = "/novel/player/video_model/v1/"
    private static let purePlayerVersionName = "7.3.9.32"
    private static let purePlayerVersionCode = "73932"
    private static let purePlayerUA = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"
    // Upstream may reject freshly minted devices with 200 + 0 bytes. No device is bundled in the open-source build:
    // by default this install's own minted device is used; you may set your own known-good pair via
    // UserDefaults key `stv.hg.purePlayerDevice` = "<device_id>,<iid>".
    private static var purePlayerDevice: (did: String, iid: String) {
        if let s = UserDefaults.standard.string(forKey: "stv.hg.purePlayerDevice") {
            let p = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, !p[0].isEmpty, !p[1].isEmpty { return (p[0], p[1]) }
        }
        // video_model only accepts devices that went through device_register (2026-11-11: a locally minted
        // did/iid gets 200 + 0 bytes, a freshly registered one returns video_model). Prefer the registered one.
        if let r = HGDevice.load() { return (r.deviceId, r.iid) }
        let d = HGPlayerDevice.current()
        return (d.deviceId, d.iid)
    }
    private static var purePlayerDeviceID: String { purePlayerDevice.did }
    private static var purePlayerIID: String { purePlayerDevice.iid }

    private static func stableUUID(_ seed: String) -> String {
        var b = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        let h = HGPlayerSign.hexStr(b)
        let c = Array(h)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    private static func purePlayerPairs() -> [(String, String)] {
        let did = purePlayerDeviceID
        let cdid = stableUUID("hongguo-player-cdid:" + did)
        let openudid = HGPlayerSign.hexStr(Array(SHA256.hash(data: Data(("hongguo-player-openudid:" + did).utf8)).prefix(8)))
        let vc = purePlayerVersionCode
        return [("iid", purePlayerIID), ("device_id", did), ("ac", "wifi"), ("channel", "xiaomi_8662_64"), ("aid", "8662"),
                ("app_name", "novelread"), ("cdid", cdid), ("version_code", vc), ("version_name", purePlayerVersionName),
                ("device_platform", "android"), ("os", "android"), ("ssmix", "a"), ("device_type", "23127PN0CC"),
                ("device_brand", "Xiaomi"), ("language", "zh"), ("os_api", "34"), ("os_version", "14"),
                ("manifest_version_code", vc), ("resolution", "1200*2670"), ("dpi", "460"), ("update_version_code", vc),
                ("host_abi", "arm64-v8a"), ("dragon_device_type", "phone"), ("pv_player", vc), ("compliance_status", "0"),
                ("need_personal_recommend", "1"), ("player_so_load", "1"), ("is_android_pad_screen", "0"), ("openudid", openudid)]
    }

    private func resolvePure(_ vid: String, level: Int) async throws -> HGResolvedVideo {
        // Keep the previously compatible single-video body; sign its exact bytes.
        let bodyObj: [String: Any] = ["video_id": vid,
                                      "biz_param": ["video_id_type": 0, "need_all_video_definition": true, "video_platform": 3,
                                                    "device_level": level >= 4 ? 4 : 3] as [String: Any]]
        let body = J.encodeSorted(bodyObj)
        var last: Error = PlayerEmptyBody()
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            let now = Date()
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let ts = UInt32(nowMs / 1000)
            let q = HGPlayerSign.encodeQuery(Self.purePlayerPairs() + [("ts", String(ts)), ("_rticket", String(nowMs))])
            let headers = try HGPlayerSign.playbackHeaders(query: q, body: Array(body), timestamp: ts)
            var req = URLRequest(url: URL(string: "https://" + Self.purePlayerHost + Self.purePlayerPath + "?" + q)!)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            for (k, v) in headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(Self.purePlayerUA, forHTTPHeaderField: "User-Agent")
            req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
            req.setValue("101", forHTTPHeaderField: "lc")
            req.setValue("\(nowMs)-\(Int64(now.timeIntervalSince1970 * 1_000_000_000) & 0x7fffffff)", forHTTPHeaderField: "x-reading-request")
            do {
                // Same no-proxy session as batch — system proxy/SOCKS yields 200 empty on this Mac.
                let (data, resp) = try await playerSession.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 || status >= 500 { last = ProviderError.upstream("video_model HTTP \(status)"); continue }
                guard status == 200 else { throw ProviderError.upstream("video_model HTTP \(status)") }
                if data.isEmpty { NSLog("[HG] resolvePure HTTP 200 empty level=%d", level); throw PlayerEmptyBody() }
                let j = try J.parse(data)
                for c in [j["code"], J.dict(j["BaseResp"])["StatusCode"]] where c != nil {
                    if J.str(c) != "0" { throw ProviderError.upstream("video_model code=\(J.str(c)) \(J.str(j["message"]))") }
                }
                guard let raw = Self.videoModelJSON(J.dict(j["data"])["video_model"]) else { throw ProviderError.upstream("video_model 缺失") }
                let r = try await materialize(raw, vid: vid)
                NSLog("[HG] resolvePure ok level=%d streams=%d", level, r.streams.count)
                return r
            } catch let e as URLError {
                last = e
            }
        }
        throw last
    }

    private static let byteVC2Only = "该集仅返回 ByteVC2 编码，iOS 无法解码"

    private func resolveBatch(_ vid: String, level: Int) async throws -> HGResolvedVideo? {
        let body: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "device_level": level, "disable_digg_stat": false, "disable_video_relate_book": false,
                          "need_all_video_definition": true, "need_mp4_align": false, "use_os_player": false, "use_server_dns": true,
                          "use_server_dns_scene": "cold_start_stage", "video_platform": 1024] as [String: Any],
            "dr_scene": "player", "mixed_video_id_map": ["1004": [vid]]
        ]
        let bodyData = J.encodeSorted(body)
        // Gateway postPlayerChunk (2d70cfd): try both AB forms per device; remint only if both soft-reject.
        let attempts = HGPlayerDevice.devicesForChunk()
        var lastEmpty: Error?
        for attempt in 0..<attempts {
            let bases = Self.playerBatchBases()
            for base in bases {
                do {
                    let j = try await postPlayerBatch(base, Self.playerQuery(Self.nowMs()), bodyData)
                    Self.rememberPlayerBatchBase(base)
                    let ent = J.dict(J.dict(j["data"])[vid])
                    guard let raw = Self.videoModelJSON(ent["video_model"]) else {
                        NSLog("[HG] player batch code=%@ no video_model", J.str(j["code"]))
                        return nil
                    }
                    let r = try await materialize(raw, vid: vid)
                    let form = (base == Self.urlBatchABOff) ? "ab_off" : "ab_on"
                    NSLog("[HG] player batch code=%@ form=%@ level=%d streams=%d device=%@", J.str(j["code"]), form, level, r.streams.count, HGPlayerDevice.current().deviceId)
                    return r
                } catch is PlayerEmptyBody {
                    lastEmpty = PlayerEmptyBody()
                    continue
                } catch {
                    // Non-empty errors: do not rotate device; fall through to single dialect.
                    throw error
                }
            }
            if attempt + 1 >= attempts { break }
            let d = HGPlayerDevice.remint()
            NSLog("[HG] player device remint after both forms empty -> %@", d.deviceId)
        }
        if lastEmpty != nil { throw PlayerEmptyBody() }
        return nil
    }

    private func resolveSingle(_ vid: String, level: Int) async throws -> HGResolvedVideo {
        let bodyObj: [String: Any] = ["video_id": vid, "content_type": 1,
                                      "biz_param": ["need_all_video_definition": true, "video_platform": 3, "device_level": level] as [String: Any]]
        let body = J.encodeSorted(bodyObj)
        let now = Date()
        // video_model.go: separate anonymous 19-digit ids (newVideoModelDeviceID), never player mint / search device.
        let q = GoURL.encode([
            "aid": "8662", "app_name": "novelread", "version_code": "73532", "version_name": "7.3.5.32",
            "manifest_version_code": "73532", "update_version_code": "73532", "channel": "update_64",
            "device_platform": "android", "os": "android", "ssmix": "a", "device_type": "25053RT47C", "device_brand": "Redmi",
            "language": "zh", "os_api": "36", "os_version": "16", "resolution": "1280*2772", "dpi": "520", "ac": "wifi",
            "device_id": vmDeviceId, "iid": vmInstallId, "_rticket": String(Int64(now.timeIntervalSince1970 * 1000))
        ])
        var req = URLRequest(url: URL(string: Self.urlVideoModel + "?" + q)!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.videoModelUA, forHTTPHeaderField: "User-Agent")
        req.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
        req.setValue("2", forHTTPHeaderField: "Sdk-Version")
        for (k, v) in HGSign.videoModelHeaders(rawQuery: q, body: Array(body), now: now) { req.setValue(v, forHTTPHeaderField: k) }
        // Same no-proxy session as batch — system proxy/SOCKS yields 200 empty on this Mac.
        let (data, resp) = try await playerSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if data.isEmpty {
            NSLog("[HG] resolveSingle HTTP %d empty (soft reject)", status)
            throw ProviderError.upstream("HTTP \(status) 空响应（上游软拒绝）")
        }
        let j = try J.parse(data)
        for c in [j["code"], J.dict(j["BaseResp"])["StatusCode"]] where c != nil {
            if J.str(c) != "0" { throw ProviderError.upstream("video_model code=\(J.str(c))") }
        }
        guard let raw = Self.videoModelJSON(J.dict(j["data"])["video_model"]) else { throw ProviderError.upstream("video_model 缺失") }
        let r = try await materialize(raw, vid: vid)
        NSLog("[HG] resolveSingle code ok level=%d streams=%d", level, r.streams.count)
        return r
    }

    private static func videoModelJSON(_ v: Any?) -> [String: Any]? {
        if let d = v as? [String: Any] { return d }
        if let s = v as? String, let data = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return o }
        return nil
    }

    private static let qualityMap = [1: "1080p", 10: "720p", 20: "540p", 30: "480p", 40: "360p"]

    static func mediaURL(_ value: Any?) -> URL? {
        var address = J.str(value)
        if !address.hasPrefix("http"), let data = Data(base64Encoded: address) {
            address = String(decoding: data, as: UTF8.self)
        }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil else { return nil }
        return url
    }

    static func parseVideoModel(_ vm: [String: Any], vid: String, keySeed: Data? = nil) -> HGResolvedVideo {
        let duration = J.double(vm["video_duration"])
        let expire = J.int(vm["url_expire"])
        var entries: [[String: Any]] = []
        if let m = vm["video_list"] as? [String: Any] { entries = m.values.compactMap { $0 as? [String: Any] } }
        else { entries = J.arr(vm["video_list"]).compactMap { $0 as? [String: Any] } }
        var choices: [(HGStream, Int, Bool)] = []
        var vc2 = 0
        for v in entries {
            let meta = J.dict(v["video_meta"])
            let enc = J.dict(v["encrypt_info"])
            let codec = J.firstNonEmpty(J.str(meta["codec_type"]), J.str(v["codec_type"])).lowercased()
            if codec == "bytevc2" || J.str(v["gear_des_key"]).lowercased().contains("bytevc2") { vc2 += 1; continue }
            // fallback_api models put alternates in backup_url_list; key_seed models AES-wrap every address.
            let alts = ([v["backup_url"]] + J.arr(v["backup_url_list"]).map { Optional($0) }).compactMap { mediaURL($0, seed: keySeed) }
            let backup = alts.first
            guard let primary = mediaURL(v["main_url"], seed: keySeed) ?? backup else { continue }
            var key = ""
            let spade = J.firstNonEmpty(J.str(enc["spade_a"]), J.str(v["spade_a"]))
            if !spade.isEmpty || J.bool(enc["encrypt"]) || J.str(enc["encryption_method"]) == "cenc-aes-ctr" {
                guard let k = HGSign.contentKey(envelope: spade) else { continue }
                key = k
            }
            let w = J.int(meta["vwidth"]) > 0 ? J.int(meta["vwidth"]) : J.int(v["vwidth"])
            let h = J.int(meta["vheight"]) > 0 ? J.int(meta["vheight"]) : J.int(v["vheight"])
            var height = Int(J.firstNonEmpty(J.str(meta["definition"]), J.str(v["definition"])).lowercased().replacingOccurrences(of: "p", with: "")) ?? 0
            if height == 0 && w > 0 && h > 0 { height = min(w, h) }
            if height == 0 { height = Int((qualityMap[J.int(v["quality_type"])] ?? "").replacingOccurrences(of: "p", with: "")) ?? 0 }
            let am = J.dict(v["audio_meta"])
            let audio = am.isEmpty ? nil : HGStreamAudio(codec: J.firstNonEmpty(J.str(am["codec_type"]), J.str(am["codec"])), profile: J.str(am["profile"]),
                                                         language: J.str(am["language"]), channels: J.int(am["channels"]),
                                                         sampleRate: J.int(am["sample_rate"]), bitrate: J.int(am["bitrate"]))
            let q = height > 0 ? "\(height)p" : nil
            let size = Int(J.firstPositive(v["size"], v["file_size"]))
            let s = HGStream(streamId: "\(q ?? "")|\(codec)", quality: q, url: primary.absoluteString, key: key, width: w, height: h, codec: codec,
                             size: size, bitrate: J.int(v["bitrate"]), audio: audio, kind: key.isEmpty ? .mp4Clear : .mp4Cenc,
                             backupURL: backup == primary ? nil : backup)
            choices.append((s, height, codec == "h264" || codec == "avc1"))
        }
        choices.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 }
            return (a.0.bitrate ?? 0) > (b.0.bitrate ?? 0)
        }
        guard let top = choices.first else {
            return HGResolvedVideo(vid: vid, url: nil, key: nil, duration: duration, expiresAt: expire,
                                   err: (!entries.isEmpty && vc2 == entries.count) ? byteVC2Only : "没有可用的媒体/密钥", streams: [])
        }
        var seen = Set<String>(); var streams: [HGStream] = []
        for c in choices where !seen.contains(c.0.id) { seen.insert(c.0.id); streams.append(c.0) }
        return HGResolvedVideo(vid: vid, url: top.0.url, key: top.0.key, duration: duration, expiresAt: expire, err: nil, streams: streams)
    }

    // MARK: related seasons / 系列剧 landing (list.go expandSeriesLanding)

    private struct SeriesLandRef {
        var stickIds: String = ""
        var from: String = "same_ip_same_series_land_page"
        var query: String = ""
        var bookId: String = ""
    }

    /// Merge detail-response related books with plan/v scene=10 stick_ids landing.
    private func loadRelatedSeries(seriesId sid: String, title: String, cover: String, episodeCount: Int, videoData vd: [String: Any], excludeId: String, landed: [HGSeries]?) async -> [HGSeries] {
        var out = Self.parseRelatedFromDetail(vd)
        if let landed {
            out = Self.mergeSeries(out, landed)
        }
        var seen = Set<String>()
        var merged: [HGSeries] = []
        for s in out where !s.seriesId.isEmpty {
            if seen.contains(s.seriesId) { continue }
            seen.insert(s.seriesId)
            merged.append(s)
        }
        // Ensure current season is on the shelf when siblings exist.
        if !seen.contains(excludeId) {
            merged.insert(HGSeries(seriesId: excludeId, title: title, cover: cover, episodeCount: episodeCount), at: 0)
            seen.insert(excludeId)
        } else if let i = merged.firstIndex(where: { $0.seriesId == excludeId }) {
            if merged[i].title.isEmpty { merged[i].title = title }
            if merged[i].cover.isEmpty { merged[i].cover = cover }
            if merged[i].episodeCount == 0 { merged[i].episodeCount = episodeCount }
        }
        if merged.count <= 1 { return [] } // alone — hide shelf
        // Season order 第1季 → 第N季 (hongguo-open-player). Fall back to current-first when nothing is numbered.
        if merged.contains(where: { SeasonParser.parse($0.title).explicit }) { return SeasonParser.sorted(merged) }
        if let i = merged.firstIndex(where: { $0.seriesId == excludeId }), i > 0 {
            let cur = merged.remove(at: i)
            merged.insert(cur, at: 0)
        }
        return merged
    }

    /// plan/v?scene=10&stick_ids=… — same-IP / same-screenplay franchise seasons.
    func seriesLanding(stickIds: String, from: String = "same_ip_same_series_land_page", query: String = "", bookId: String = "", maxPages: Int = 8) async throws -> [HGSeries] {
        let ids = stickIds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { Self.looksSID(String($0)) }
        guard !ids.isEmpty else { return [] }
        let d = try await ensureDevice()
        var out: [HGSeries] = []
        var seen = Set<String>()
        var offset = 0
        var sessionId = ""
        let fromVal = from.isEmpty ? "same_ip_same_series_land_page" : from
        for _ in 0..<maxPages {
            var q = "scene=10&from=" + GoURL.queryEscape(fromVal) +
                "&stick_ids=" + GoURL.queryEscape(ids.joined(separator: ",")) +
                "&offset=\(offset)"
            if !query.isEmpty { q += "&query=" + GoURL.queryEscape(query) }
            if Self.looksSID(bookId) { q += "&book_id=" + GoURL.queryEscape(bookId) }
            if !sessionId.isEmpty { q += "&session_id=" + GoURL.queryEscape(sessionId) }
            q += "&" + Self.listQuery(d, Self.nowMs())
            let j = try await list(Self.urlPlan + q, signed: true)
            guard J.str(j["code"]) == "0" else {
                if out.isEmpty { throw ProviderError.upstream("series landing code=\(J.str(j["code"]))") }
                break
            }
            let page = Self.parseSeriesLandingJSON(j)
            if !page.sessionId.isEmpty { sessionId = page.sessionId }
            for s in page.items {
                if s.seriesId.isEmpty { continue }
                if seen.contains(s.seriesId) { continue }
                seen.insert(s.seriesId)
                out.append(s)
            }
            if page.items.isEmpty || !page.hasMore || page.nextOffset <= offset { break }
            offset = page.nextOffset
        }
        return out
    }

    private struct LandingPage {
        var items: [HGSeries] = []
        var hasMore = false
        var nextOffset = 0
        var sessionId = ""
    }

    private static func parseSeriesLandingJSON(_ j: [String: Any]) -> LandingPage {
        var out = LandingPage()
        var data = j
        if let inner = j["data"] as? [String: Any] { data = inner }
        // Some responses wrap as data: [ { cell_data, has_more, ... } ]
        if let list = data["data"] as? [Any], let first = list.first as? [String: Any] { data = first }
        out.hasMore = J.bool(data["has_more"])
        out.nextOffset = J.int(data["next_offset"])
        out.sessionId = J.str(data["session_id"])
        var items: [HGSeries] = []
        for c in J.arr(data["cell_data"]) {
            items.append(contentsOf: parseCellVideoData(J.dict(c)))
        }
        if items.isEmpty { items = parseCellVideoData(data) }
        out.items = items
        return out
    }

    private static func parseCellVideoData(_ cell: [String: Any]) -> [HGSeries] {
        var vds = J.arr(cell["video_data"])
        if vds.isEmpty, let one = cell["video_data"] as? [String: Any] { vds = [one] }
        let fallback = firstID(cell, "book_id", "search_result_id", "series_id")
        var out: [HGSeries] = []
        for v in vds {
            var s = parseVideoData(J.dict(v))
            if s.seriesId.isEmpty { s.seriesId = fallback }
            if s.seriesId.isEmpty && s.title.isEmpty { continue }
            out.append(s)
        }
        return out
    }

    private static func seriesLandFromCell(_ cell: [String: Any]) -> SeriesLandRef {
        let ld = parseLynxPayload(cell["lynx_data"])
        var cellURL = J.str(cell["cell_url"])
        if cellURL.isEmpty { cellURL = J.str(ld["cell_url"]) }
        let vals = parseLynxQuery(cellURL)
        var land = SeriesLandRef(
            stickIds: firstNonEmpty(vals["stick_ids"] ?? "", joinStickIds(stickIdsFromURL(cellURL))),
            from: firstNonEmpty(vals["from"] ?? "", "same_ip_same_series_land_page"),
            query: vals["query"] ?? "",
            bookId: firstNonEmpty(vals["book_id"] ?? "", J.str(cell["book_id"]))
        )
        if !looksSID(land.bookId) { land.bookId = "" }
        if land.stickIds.isEmpty {
            land.stickIds = joinStickIds(stickIdsFromURL(J.str(ld["cell_url"])))
        }
        // Inline lynx_data.cell_data may already list sibling seasons — keep as stick_ids if missing.
        if land.stickIds.isEmpty, !ld.isEmpty {
            var ids: [String] = []
            for c in J.arr(ld["cell_data"]) {
                for s in parseCellVideoData(J.dict(c)) where looksSID(s.seriesId) { ids.append(s.seriesId) }
            }
            land.stickIds = joinStickIds(ids)
        }
        return land
    }

    private static func parseLynxPayload(_ v: Any?) -> [String: Any] {
        if let m = v as? [String: Any] { return m }
        if let s = v as? String, let d = s.data(using: .utf8),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return m }
        return [:]
    }

    private static func parseLynxQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        guard !raw.isEmpty else { return out }
        func collect(_ q: [String: String]) {
            for k in ["stick_ids", "from", "query", "book_id", "card_type"] {
                if let v = q[k], !v.isEmpty, out[k] == nil { out[k] = v }
            }
        }
        var walk = raw
        for _ in 0..<4 {
            if let d = walk.removingPercentEncoding, d != walk { walk = d; continue }
            break
        }
        collect(parseRawQuery(walk))
        if let u = URL(string: walk), let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            var qmap: [String: String] = [:]
            for item in comps.queryItems ?? [] { if let v = item.value { qmap[item.name] = v } }
            collect(qmap)
            if let inner = qmap["url"], !inner.isEmpty {
                for (k, v) in parseLynxQuery(inner) where out[k] == nil { out[k] = v }
            }
        }
        return out
    }

    private static func parseRawQuery(_ raw: String) -> [String: String] {
        var s = raw
        if let i = s.firstIndex(of: "?") { s = String(s[s.index(after: i)...]) }
        var out: [String: String] = [:]
        for part in s.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let k = String(kv[0])
            let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            out[k] = v
        }
        return out
    }

    private static func stickIdsFromURL(_ raw: String) -> [String] {
        guard raw.contains("stick_ids=") else { return [] }
        if let u = URL(string: raw), let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            if let v = comps.queryItems?.first(where: { $0.name == "stick_ids" })?.value {
                let ids = splitStickIds(v)
                if !ids.isEmpty { return ids }
            }
            if let inner = comps.queryItems?.first(where: { $0.name == "url" })?.value {
                return stickIdsFromURL(inner.removingPercentEncoding ?? inner)
            }
        }
        return stickIdsFromQuery(raw)
    }

    private static func stickIdsFromQuery(_ raw: String) -> [String] {
        guard let r = raw.range(of: "stick_ids=") else { return [] }
        var rest = String(raw[r.upperBound...])
        if let amp = rest.firstIndex(of: "&") { rest = String(rest[..<amp]) }
        rest = rest.removingPercentEncoding ?? rest
        return splitStickIds(rest)
    }

    private static func splitStickIds(_ s: String) -> [String] {
        s.split(separator: ",").compactMap { p -> String? in
            let id = String(p).trimmingCharacters(in: .whitespaces)
            return looksSID(id) ? id : nil
        }
    }

    private static func joinStickIds(_ ids: [String]) -> String { ids.filter(looksSID).joined(separator: ",") }

    /// Walk detail video_data for related-book arrays (disable_video_relate_book:false).
    private static func parseRelatedFromDetail(_ vd: [String: Any]) -> [HGSeries] {
        guard !vd.isEmpty else { return [] }
        var out: [HGSeries] = []
        var seen = Set<String>()
        func take(_ arr: [Any]) {
            for e in arr {
                let m = J.dict(e)
                // Nested video_data / book / series shapes.
                if let nested = m["video_data"] {
                    if let a = nested as? [Any] {
                        for v in a {
                            var s = parseVideoData(J.dict(v))
                            if s.seriesId.isEmpty { s.seriesId = firstID(J.dict(v), "series_id", "book_id", "album_id_str") }
                            if looksSID(s.seriesId), !seen.contains(s.seriesId) { seen.insert(s.seriesId); out.append(s) }
                        }
                    } else if let one = nested as? [String: Any] {
                        var s = parseVideoData(one)
                        if looksSID(s.seriesId), !seen.contains(s.seriesId) { seen.insert(s.seriesId); out.append(s) }
                    }
                } else {
                    var s = parseVideoData(m)
                    if s.seriesId.isEmpty {
                        s.seriesId = firstID(m, "series_id", "book_id", "album_id_str", "relate_book_id", "related_book_id")
                        if s.title.isEmpty { s.title = J.firstNonEmpty(J.str(m["book_name"]), J.str(m["series_title"]), J.str(m["title"]), J.str(m["name"])) }
                        if s.cover.isEmpty { s.cover = J.firstNonEmpty(J.str(m["cover"]), J.str(m["thumb_url"]), J.str(m["series_cover"])) }
                        if s.episodeCount == 0 { s.episodeCount = J.int(m["episode_cnt"]); if s.episodeCount == 0 { s.episodeCount = J.int(m["serial_count"]) } }
                    }
                    if looksSID(s.seriesId), !seen.contains(s.seriesId) { seen.insert(s.seriesId); out.append(s) }
                }
            }
        }
        let keys = [
            "video_relate_book", "video_relate_book_list", "relate_book_list", "related_book_list",
            "relate_video_list", "related_video_list", "same_series_list", "same_ip_list",
            "relate_books", "related_books", "book_relate_list", "recommend_book_list"
        ]
        for k in keys {
            let v = vd[k]
            if let a = v as? [Any] { take(a) }
            else if let m = v as? [String: Any] {
                if let a = m["book_list"] as? [Any] { take(a) }
                else if let a = m["video_data"] as? [Any] { take(a) }
                else if let a = m["list"] as? [Any] { take(a) }
                else { take([m]) }
            }
        }
        // Also scan shallow nested dicts for arrays of series-like objects.
        for (k, v) in vd where k.lowercased().contains("relate") || k.lowercased().contains("same_ip") || k.lowercased().contains("same_series") {
            if let a = v as? [Any] { take(a) }
        }
        return out
    }

    private static func mergeSeries(_ a: [HGSeries], _ b: [HGSeries]) -> [HGSeries] {
        var seen = Set<String>()
        var out: [HGSeries] = []
        for s in a + b where looksSID(s.seriesId) {
            if seen.contains(s.seriesId) { continue }
            seen.insert(s.seriesId)
            out.append(s)
        }
        return out
    }

    private static func firstNonEmpty(_ vals: String...) -> String {
        for v in vals where !v.isEmpty { return v }
        return ""
    }

    // MARK: parsing helpers (list.go parseVideoData etc.)

    static func looksSID(_ s: String) -> Bool { (15...25).contains(s.count) && s.allSatisfy(\.isNumber) }
    static func firstID(_ m: [String: Any], _ keys: String...) -> String {
        for k in keys { let s = J.str(m[k]).trimmingCharacters(in: .whitespaces); if looksSID(s) { return s } }
        return ""
    }

    static func isNew(_ m: [String: Any]) -> Bool {
        for k in ["video_tag_info", "tag_info"] where J.str(J.dict(m[k])["text"]).contains("新剧") { return true }
        for k in ["cover_tag_info_list", "rec_tags", "secondary_infos"] {
            for e in J.arr(m[k]) { let em = J.dict(e); if J.str(em["content"]).contains("新剧") || J.str(em["text"]).contains("新剧") { return true } }
        }
        return J.str(m["rec_text"]).contains("新剧")
    }

    static func orientation(_ m: [String: Any]) -> String? {
        if let v = m["vertical"] ?? m["video_vertical"], !(v is NSNull) { return J.bool(v) ? "portrait" : "landscape" }
        return nil
    }

    static func parseVideoData(_ vd: [String: Any]) -> HGSeries {
        let det = J.dict(vd["video_detail"])
        var s = HGSeries(seriesId: "", title: J.firstNonEmpty(J.str(vd["raw_book_name"]), J.str(det["series_title"]), J.str(vd["title"])),
                         cover: J.str(vd["cover"]))
        s.subtitle = J.str(vd["sub_title"]).isEmpty ? nil : J.str(vd["sub_title"])
        s.author = J.str(vd["copyright"]).isEmpty ? nil : J.str(vd["copyright"])
        s.episodeCount = J.int(vd["episode_cnt"])
        s.duration = J.int(vd["duration"])
        s.playCount = Int(J.firstPositive(vd["series_play_cnt"], vd["play_cnt"], vd["read_count"], det["series_play_cnt"], det["play_cnt"]))
        s.followCount = Int(J.firstPositive(vd["followed_cnt"], vd["follow_cnt"], vd["collect_cnt"], det["followed_cnt"]))
        s.onlineTime = Int(J.unix(vd["create_time"]))
        if s.onlineTime == 0 { s.onlineTime = Int(J.unix(vd["first_online_time"])) }
        if s.episodeCount == 0 { s.episodeCount = J.int(det["episode_cnt"]) }
        s.orientation = orientation(vd)
        s.isNew = isNew(vd) || isNew(det)
        if let schema = vd["category_schema"] as? String, let d = schema.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            s.tags = arr.map { J.firstNonEmpty(J.str($0["name"]), J.str($0["category_name"])) }.filter { !$0.isEmpty }
        }
        let al = J.dict(vd["album_info"])
        if !al.isEmpty {
            if s.title.isEmpty { s.title = J.str(al["title"]) }
            let n = J.int(al["episode_cnt"]); if n > 0 { s.episodeCount = n }
            if s.cover.isEmpty { s.cover = J.str(al["cover"]) }
            s.seriesId = firstID(al, "album_id_str", "album_id")
        }
        if s.seriesId.isEmpty { s.seriesId = firstID(vd, "series_id", "seriesId", "series_id_str", "recommend_group_id") }
        return s
    }

    static func celebrities(_ vd: [String: Any]) -> [String] {
        for k in ["celebrities", "celebrity_list", "actors"] {
            let names = J.arr(vd[k]).compactMap { e -> String? in
                if let s = e as? String { return s }
                let m = J.dict(e)
                let n = J.firstNonEmpty(J.str(m["name"]), J.str(m["user_name"]), J.str(m["celebrity_name"]), J.str(m["role_name"]))
                return n.isEmpty ? nil : n
            }
            if !names.isEmpty { return Array(NSOrderedSet(array: names)) as? [String] ?? names }
        }
        return []
    }

    static func names(_ vals: Any?...) -> [String] {
        var out: [String] = []
        for v in vals {
            if let a = v as? [Any] {
                for e in a {
                    let n = (e as? String) ?? J.firstNonEmpty(J.str(J.dict(e)["name"]), J.str(J.dict(e)["role_name"]))
                    if !n.isEmpty, !out.contains(n) { out.append(n) }
                }
            } else if let s = v as? String, !s.isEmpty {
                let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                for p in cleaned.split(whereSeparator: { ",/、|".contains($0) }) {
                    let n = p.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !n.isEmpty, !out.contains(n) { out.append(n) }
                }
            }
        }
        return out
    }
}

// MARK: - rank / search enums (shared by UI)

enum HGRankGenre: String, CaseIterable, Identifiable {
    case all, human, comic, ai
    var id: String { rawValue }
    var label: String { switch self { case .all: "全部"; case .human: "真人剧"; case .comic: "漫剧"; case .ai: "AI剧" } }
    var subs: [HGRankSub] {
        switch self {
        case .all: [.hot, .recommend, .new, .hotSearch, .mustWatch, .followed, .zhenguo, .subscribe]
        case .human: [.hot, .recommend, .new, .hotSearch, .mustWatch, .followed]
        case .comic: [.hot, .recommend, .new, .hotSearch]
        case .ai: [.hot, .recommend, .new, .mustWatch, .followed, .hotSearch]
        }
    }
}

enum HGRankSub: String, CaseIterable, Identifiable {
    case hot, recommend, new, hotSearch = "hot_search", mustWatch = "must_watch", followed, zhenguo, subscribe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hot: "热播"; case .recommend: "推荐"; case .new: "新剧"; case .hotSearch: "热搜"
        case .mustWatch: "必看"; case .followed: "收藏"; case .zhenguo: "臻果"; case .subscribe: "预约"
        }
    }
}

enum HGContentFilter: String, CaseIterable, Identifiable {
    case all, human, comic, ai
    var id: String { rawValue }
    var label: String { switch self { case .all: "全部"; case .human: "真人剧"; case .comic: "漫剧"; case .ai: "AI剧" } }
}

// MARK: - Official web page (cast / tags / social), celebrities, season discovery
// Ported from hongguo-open-player (hongguo.js parseEpisodeListHtml, hongguo-actor.js, app.js fetchRelatedSeasons).

struct HGWebDetail: Hashable {
    var title = ""
    var intro = ""
    var tags: [String] = []
    var cast: [HGCelebrity] = []
    var favoriteCount = 0
    var episodeLabel = ""
    var seriesGroupId = ""
    var rating: Double = 0
    var ratingCount = ""
    var hotText = ""
}

extension HongguoClient {
    private static let webOrigin = "https://hongguoduanju.com"
    private static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// `https://hongguoduanju.com/player/{sid}` embeds `_ROUTER_DATA` with celebrities (ids + avatars + roles), tags, intro.
    func webDetail(seriesId sid: String) async throws -> HGWebDetail {
        guard Self.looksSID(sid) else { throw ProviderError.invalid("seriesId") }
        var req = URLRequest(url: URL(string: Self.webOrigin + "/player/" + sid)!)
        req.timeoutInterval = 7
        req.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(Self.webOrigin + "/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        guard let router = Self.routerData(html) else { throw ProviderError.upstream("官网页面缺少 _ROUTER_DATA") }
        let ld = J.dict(router["loaderData"])
        let page = J.dict(ld["player_(series_id)/page"] ?? ld["player_(series_id)/(vid)/page"] ?? ld["detail_page"])
        let sd = J.dict(page["seriesDetail"])
        guard J.str(sd["series_id"]) == sid else { throw ProviderError.upstream("官网返回的剧集不一致") }
        var w = HGWebDetail()
        w.title = J.str(sd["series_name"])
        w.intro = J.str(sd["series_intro"]).trimmingCharacters(in: .whitespacesAndNewlines)
        w.tags = J.arr(sd["tags"]).map { J.str($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        w.episodeLabel = J.str(sd["episode_right_text"]).trimmingCharacters(in: .whitespaces)
        w.seriesGroupId = J.str(J.dict(sd["season_info"])["series_group_id"])
        var seen = Set<String>()
        for e in J.arr(sd["celebrities"]) {
            let m = J.dict(e)
            if J.bool(m["is_label"]) { continue }
            let name = J.firstNonEmpty(J.str(m["nickname"]), J.str(m["name"]))
            let id = J.firstNonEmpty(J.str(m["celebrity_id"]), J.str(m["actor_id"]))
            if name.isEmpty || seen.contains(id + name) { continue }
            seen.insert(id + name)
            w.cast.append(HGCelebrity(id: id, name: name, avatar: J.str(m["avatar"]),
                                      role: J.firstNonEmpty(J.str(m["sub_title"]), J.str(m["role"]))))
        }
        let social = J.dict(page["seriesSocialInfo"])
        w.favoriteCount = J.int(social["series_favorite_count"])
        w.rating = J.double(social["rating"])
        w.ratingCount = J.str(social["rating_count"])
        w.hotText = J.str(J.dict(social["hot_score_data"])["text"])
        return w
    }

    /// Brace-matching extractor for `window._ROUTER_DATA = {...}` (catalog.js readRouterData).
    static func routerData(_ html: String) -> [String: Any]? {
        guard let r = html.range(of: #"(?:window\.)?_ROUTER_DATA\s*=\s*\{"#, options: .regularExpression) else { return nil }
        let bytes = Array(html.utf8)
        let start = html.utf8.distance(from: html.utf8.startIndex, to: r.upperBound.samePosition(in: html.utf8)!) - 1
        var depth = 0, quoted = false, escaped = false
        var i = start
        while i < bytes.count {
            let c = bytes[i]
            if quoted {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { quoted = false }
            } else if c == 0x22 { quoted = true }
            else if c == 0x7B { depth += 1 }
            else if c == 0x7D {
                depth -= 1
                if depth == 0 {
                    let slice = Data(bytes[start...i])
                    return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                }
            }
            i += 1
        }
        return nil
    }

    /// Merge web-page metadata into an app-side detail (cast with ids, tags, favorites).
    static func enrich(_ d: HGSeriesDetail, with w: HGWebDetail?) -> HGSeriesDetail {
        guard let w else { return d }
        var out = d
        out.cast = w.cast
        out.tags = w.tags
        out.favoriteCount = w.favoriteCount
        out.episodeLabel = w.episodeLabel
        if out.desc.isEmpty { out.desc = w.intro }
        if !w.cast.isEmpty {
            // Real performer names beat role names from book_info.roles.
            out = HGSeriesDetail(source: d.source, seriesId: d.seriesId, title: d.title.isEmpty ? w.title : d.title, cover: d.cover,
                                 desc: out.desc, author: d.author, actors: w.cast.map(\.name), onlineTime: d.onlineTime,
                                 totalEps: d.totalEps, episodes: d.episodes, relatedSeries: d.relatedSeries,
                                 cast: w.cast, tags: w.tags, favoriteCount: w.favoriteCount, episodeLabel: w.episodeLabel)
        }
        out.rating = w.rating
        out.ratingCount = w.ratingCount
        out.hotText = w.hotText
        return out
    }

    // MARK: celebrities (hongguo-actor.js; plain GET with list query works unsigned)

    func celebrity(id: String) async throws -> HGActorProfile {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw ProviderError.invalid("演员 ID") }
        let d = try await ensureDevice()
        let u = "https://api5-normal-sinfonlineb.fqnovel.com/reading/user/celebrity/homepage/v1/?encrypted_celebrity_id=" + id +
            "&" + Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u), "celebrity")
        let info = J.dict(data["celebrity_info"])
        guard !info.isEmpty else { throw ProviderError.upstream("未查询到该演员信息") }
        let actor = HGCelebrity(id: id, name: J.str(info["nickname"]), avatar: J.str(info["avatar"]), intro: J.str(info["intro"]))
        let related = J.arr(info["related_celebrities"]).compactMap { e -> HGCelebrity? in
            let m = J.dict(e)
            let cid = J.str(m["celebrity_id"]), name = J.str(m["nickname"])
            return cid.isEmpty || name.isEmpty ? nil : HGCelebrity(id: cid, name: name, avatar: J.str(m["avatar"]), intro: J.str(m["intro"]))
        }
        return HGActorProfile(actor: actor, related: related)
    }

    func celebrityWorks(id: String, count: Int = 200) async throws -> HGActorWorks {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw ProviderError.invalid("演员 ID") }
        let d = try await ensureDevice()
        let u = "https://api5-normal-sinfonlineb.fqnovel.com/reading/user/celebrity/works/v1/?encrypted_celebrity_ids=" + id +
            "&offset=0&count=\(max(1, min(300, count)))&req_scene=0&" + Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u), "celebrity works")
        let w = J.dict(J.dict(data["works"])[id])
        var seen = Set<String>()
        var items: [HGSeries] = []
        for v in J.arr(w["video_list"]) {
            let m = J.dict(v)
            var s = Self.parseVideoData(m)
            if s.episodeCount == 0, let r = J.str(m["sub_title"]).range(of: #"\d+(?=\s*集)"#, options: .regularExpression) {
                s.episodeCount = Int(J.str(m["sub_title"])[r]) ?? 0
            }
            guard Self.looksSID(s.seriesId), !s.title.isEmpty, !seen.contains(s.seriesId) else { continue }
            seen.insert(s.seriesId)
            items.append(s)
        }
        return HGActorWorks(items: items, total: max(J.int(w["total_count"]), items.count))
    }

    // MARK: season discovery by title (app.js parseSeasonInfo / fetchRelatedSeasons)

    /// Search the base title and keep same-franchise results, sorted 第1季 → 第N季.
    func discoverSeasons(title: String, current: HGSeries) async -> [HGSeries] {
        let info = SeasonParser.parse(title)
        guard info.base.count >= 2 else { return [] }
        var list: [HGSeries] = []
        if let p = try? await search(info.base) {
            list = p.items
            if p.hasMore, p.items.count >= 5, let p2 = try? await search(info.base, cursor: p.nextCursor) { list += p2.items }
        }
        let norm = SeasonParser.normalize(info.base)
        var seen: Set<String> = [current.seriesId]
        var out: [HGSeries] = [current]
        for s in list where Self.looksSID(s.seriesId) && !seen.contains(s.seriesId) {
            let b = SeasonParser.normalize(SeasonParser.parse(s.title).base)
            if b == norm || (norm.count >= 4 && b.contains(norm)) {
                seen.insert(s.seriesId)
                out.append(s)
            }
        }
        return out.count > 1 ? SeasonParser.sorted(out) : []
    }
}

/// 「第N季/部/期/辑」「Season N」「(N)」 parsing shared by detail + player season pickers.
enum SeasonParser {
    struct Info: Hashable { var base: String; var number: Int; var explicit: Bool }

    private static let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    private static let patterns = [
        #"[（(【\s]*第\s*([0-9零一二两三四五六七八九十]+)\s*(?:季|部|期|辑)[）)】\s]*$"#,
        #"[（(【\s]*([0-9零一二两三四五六七八九十]+)\s*(?:季|部|期|辑)[）)】\s]*$"#,
        #"[（(【\s]*(?:Season|S)\s*([0-9]+)[）)】\s]*$"#,
        #"[（(【]\s*([0-9]+)\s*[）)】]$"#
    ]

    static func number(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let c = Array(s)
        if c.count == 1 { return c[0] == "十" ? 10 : digits[c[0]] }
        if c.count == 2, c[0] == "十", let b = digits[c[1]] { return 10 + b }
        if c.count == 2, c[1] == "十", let a = digits[c[0]] { return a * 10 }
        if c.count == 3, c[1] == "十", let a = digits[c[0]], let b = digits[c[2]] { return a * 10 + b }
        return nil
    }

    static func parse(_ raw: String) -> Info {
        let title = raw.trimmingCharacters(in: .whitespaces)
        let trimSet = CharacterSet(charactersIn: " :：·_—-")
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let r1 = Range(m.range(at: 1), in: title), let whole = Range(m.range, in: title),
                  let n = number(String(title[r1])), n > 0, n <= 100 else { continue }
            let base = String(title[..<whole.lowerBound]).trimmingCharacters(in: trimSet)
            if !base.isEmpty { return Info(base: base, number: n, explicit: true) }
        }
        return Info(base: title.trimmingCharacters(in: trimSet), number: 1, explicit: false)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !"：:，,！!？?“”\"'·".contains($0) }
    }

    static func label(_ s: HGSeries) -> String {
        let i = parse(s.title)
        return "第\(i.number)季"
    }

    /// Strict 1 → N; explicit markers before implicit at the same number, then more episodes first.
    static func sorted(_ items: [HGSeries]) -> [HGSeries] {
        items.map { ($0, parse($0.title)) }.sorted { a, b in
            if a.1.number != b.1.number { return a.1.number < b.1.number }
            if a.1.explicit != b.1.explicit { return a.1.explicit }
            return a.0.episodeCount > b.0.episodeCount
        }.map(\.0)
    }
}
