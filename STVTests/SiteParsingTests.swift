import XCTest
@testable import STV

/// Parsers for 1.3 site fixes / new sources. Fixtures mirror the real markup (2026-11) with neutral text.
final class SiteParsingTests: XCTestCase {

    // MARK: Huangguo AI (2026-11-09 POST playback)

    func testHuangguoPlaybackParse() throws {
        let json = #"{"data":{"mode":1,"manifest_method":"GET","cdn":{"m3u8Enabled":true,"otherEnabled":false,"authKey":"x-cdn-auth","authValue":"abc123","app":"150"},"id":"10374","ep":1,"streams":{"main":"https://cdn.example.com/v/x.m3u8?auth_key=1","hevc":"https://cdn.example.com/v/x-h.m3u8"}},"status":1,"msg":""}"#
        let pb = try HuangguoClient.parsePlayback(Data(json.utf8), id: "10374", ep: 1)
        XCTAssertEqual(pb.main, "https://cdn.example.com/v/x.m3u8?auth_key=1")
        XCTAssertEqual(pb.cdn, ["x-cdn-auth": "abc123", "x-cdn-app": "150"])
        XCTAssertThrowsError(try HuangguoClient.parsePlayback(Data(json.utf8), id: "10374", ep: 2), "episode mismatch must fail")
        let bad = #"{"data":null,"status":0,"msg":"视频不存在或不可播放"}"#
        XCTAssertThrowsError(try HuangguoClient.parsePlayback(Data(bad.utf8), id: "1", ep: 1))
        let noAuth = json.replacingOccurrences(of: #""m3u8Enabled":true"#, with: #""m3u8Enabled":false"#)
        XCTAssertEqual(try HuangguoClient.parsePlayback(Data(noAuth.utf8), id: "10374", ep: 1).cdn, [:])
    }

    func testHuangguoMirrorDiscovery() {
        let h = #"<a href="https://00b4b.adihsppe.cc">a</a> <a href="https://huangguoai.io/ai-duanju/">b</a> https://hgai12.com "https://evil.example.com" https://pic.drleao.cn/x"#
        XCTAssertEqual(HuangguoClient.discoveredMirrors(h), ["https://00b4b.adihsppe.cc", "https://huangguoai.io", "https://hgai12.com"])
        let d = UserDefaults(suiteName: "hgtest")!
        d.removePersistentDomain(forName: "hgtest")
        d.set("https://x.adihsppe.cc", forKey: HuangguoClient.baseKey)
        XCTAssertEqual(HuangguoClient.mirrorCandidates(defaults: d).first, "https://x.adihsppe.cc")
        XCTAssertTrue(HuangguoClient.mirrorCandidates(defaults: d).contains("https://00b4b.adihsppe.cc"))
    }

    // MARK: Hanime1 裏番/泡麵番 compact grid

    func testHanimeCompactGridWithExtraClassTokens() {
        let card = { (id: Int, t: String) in """
        <a style="text-decoration: none;" href="https://hanime1.me/watch?v=\(id)">
            <div class="home-rows-videos-div search-videos hover-lighter">
                <div class="video-card-inner" style="position: relative;">
                    <img loading="lazy" src="https://img.example.com/cover/\(id).jpg?secure=a==,1">
                    <div class="home-rows-videos-title">
                        \(t)
                    </div>
                </div>
            </div>
        </a>
        """ }
        let ad = #"<a href="https://ads.example.com/s/1" target="_blank"><div class="home-rows-videos-div search-videos hover-lighter"><img src="x.jpg"></div></a>"#
        let html = ad + card(408317, "示例 1") + card(408319, "示例 2") + #"<a href="?genre=x&page=2">2</a>"#
        let p = Hanime1Provider.parseList(html, base: "https://hanime1.me", page: 1)
        XCTAssertEqual(p.items.map(\.seriesId), ["408317", "408319"])
        XCTAssertEqual(p.items.first?.title, "示例 1")
        XCTAssertEqual(p.items.first?.cover, "https://img.example.com/cover/408317.jpg?secure=a==,1")
        XCTAssertFalse(p.items[0].isLandscapeCover, "裏番 covers are portrait")
        XCTAssertTrue(p.hasMore)
    }

    /// Optional: the real saved page (`TEST_RUNNER_STV_HANIME_HTML=/path`), not committed.
    func testHanimeRealSavedPageIfProvided() throws {
        guard let p = ProcessInfo.processInfo.environment["STV_HANIME_HTML"] else { throw XCTSkip("no saved page") }
        let h = try String(contentsOfFile: p, encoding: .utf8)
        let page = Hanime1Provider.parseList(h, base: "https://hanime1.me", page: 1)
        print("HANIME real 裏番 items:", page.items.count, "hasMore:", page.hasMore)
        XCTAssertGreaterThanOrEqual(page.items.count, 20)
    }

    // MARK: Tube sites

    func testTubeHelpers() {
        XCTAssertEqual(TubePath.url("/|/new/{p0}", page: 1), "/")
        XCTAssertEqual(TubePath.url("/|/new/{p0}", page: 3), "/new/2")
        XCTAssertEqual(TubePath.url("/api?page={p}", page: 4), "/api?page=4")
        XCTAssertEqual(TubeFmt.duration("1 h 5 min"), 3900)
        XCTAssertEqual(TubeFmt.duration("12 min"), 720)
        XCTAssertEqual(TubeFmt.duration("16:41"), 1001)
        XCTAssertFalse(TubeSafety.allowed("Hidden camera something"))
        XCTAssertFalse(TubeSafety.allowed("某某 未成年"))
        XCTAssertTrue(TubeSafety.allowed("Couple vacation video"))
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 15
        XCTAssertEqual(TubePath.lastMonth(Calendar(identifier: .gregorian).date(from: c)!), "2025-12")
    }

    func testEporner() {
        XCTAssertEqual(EpornerProvider.xhrHash("9d3658642dbb4113c16159bea6d6fe82"), "17mcl7ocosr9v1hnmdoe1aailc2")
        let list = #"{"total_pages":3,"videos":[{"id":"K7TxeAh6TDh","title":"Sample &amp; one","keywords":"a, b","views":"79","url":"https://www.eporner.com/video-K7TxeAh6TDh/x/","added":"2026-11-07 12:24:27","length_sec":"1779","default_thumb":{"src":"https://static.example.com/t.jpg"}},{"id":"bad/id","title":"x"}]}"#
        let p = EpornerProvider.parseList(list, page: 1)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].title, "Sample & one")
        XCTAssertEqual(p.items[0].duration, 1779)
        XCTAssertEqual(p.items[0].tags, ["a", "b"])
        XCTAssertTrue(p.hasMore)
        let x = #"{"available":true,"sources":{"mp4":{"480p":{"src":"https://v.example.com/480.mp4"},"720p HD":{"src":"https://v.example.com/720.mp4"}},"hls":{"auto":{"src":"https://v.example.com/master.m3u8"}}}}"#
        let s = EpornerProvider.streams(x)
        XCTAssertEqual(s.map(\.url), ["https://v.example.com/master.m3u8", "https://v.example.com/720.mp4", "https://v.example.com/480.mp4"])
        XCTAssertEqual(s[0].kind, .hls); XCTAssertEqual(s[1].kind, .mp4Clear)
    }

    func testXVideosAndXNXX() {
        let xv = """
        <div id="video_olukc" data-id="1" class="frame-block thumb-block  "><div class="thumb-inside"><div class="thumb"><a href="/video.olukc/5859/0/slug"><img src="blank.gif"
        data-src="https://thumb.example.com/a/xv_29_t.jpg"/></a></div></div><div class="thumb-under"><p class="title"><a href="/video.olukc/5859/0/slug" title="Sample &amp; title">Sample <span class="duration">12 min</span></a></p><p class="metadata"><span class="bg"><span class="duration">12 min</span><span><a href="/u"><span class="name">Uploader</span></a></span></span></p></div></div>
        <div id="video_two" class="thumb-block"><a href="/video.two/1/0/s"><img data-src="https://thumb.example.com/b.jpg"></a><p class="title"><a href="/video.two/1/0/s" title="Hidden camera clip">x</a></p></div>
        """
        let p = XVProvider.parseList(xv, source: .xvideos, base: "https://www.xvideos.com", page: 1)
        XCTAssertEqual(p.items.map(\.seriesId), ["olukc"], "safety filter drops the second card")
        XCTAssertEqual(p.items[0].title, "Sample & title")
        XCTAssertEqual(p.items[0].duration, 720)
        XCTAssertEqual(p.items[0].author, "Uploader")
        XCTAssertEqual(p.items[0].page, "https://www.xvideos.com/video.olukc/5859/0/slug")
        let xn = #"<div id="video-thumb-1iym" class="thumb-block video" data-video='{}'><div class="thumb"><a class="thumb-link" href="/video-1iym/slug"><picture><img src="blank.gif" data-src="https://thumb.example.com/xn_7_t.jpg" alt="XN sample"></picture></a></div><div class="thumb-under"><p class="metadata">1.2M <span>98%</span> 24 min</p></div></div>"#
        let q = XVProvider.parseList(xn, source: .xnxx, base: "https://www.xnxx.com", page: 1)
        XCTAssertEqual(q.items.first?.seriesId, "1iym"); XCTAssertEqual(q.items.first?.title, "XN sample"); XCTAssertEqual(q.items.first?.duration, 1440)
        let watch = #"html5player.setVideoTitle('T');html5player.setVideoUrlLow('https://mp4.example.com/sd.mp4?secure=a');html5player.setVideoUrlHigh('https://mp4.example.com/hd.mp4?secure=a');html5player.setVideoHLS('https://hls.example.com/x/hls.m3u8');"#
        let s = XVProvider.streams(watch, page: "https://www.xvideos.com/video.olukc/slug")
        XCTAssertEqual(s.map(\.url), ["https://hls.example.com/x/hls.m3u8", "https://mp4.example.com/hd.mp4?secure=a", "https://mp4.example.com/sd.mp4?secure=a"])
        XCTAssertEqual(s[0].headers["Referer"], "https://www.xvideos.com/video.olukc/slug")
    }

    func testPornhub() {
        let li = { (k: String, t: String) in #"<li data-video-segment="straight" class="" data-video-id="1" data-video-vkey="\#(k)"><a href="/view_video.php?viewkey=\#(k)"><img class="videoThumb js-videoThumb" src="https://pix.example.com/\#(k).jpg" alt="\#(t)"></a><div class="duration thumbOverlay"><span class="time">16:41</span></div><div class="title"><a href="/view_video.php?viewkey=\#(k)">x</a></div><div class="views">198 Views</div></li>"# }
        let p = PornhubProvider.parseList(li("6af0", "Sample one") + li("7bb1", "Forced thing") + #"<a href="?o=mr&page=2">"#, page: 1)
        XCTAssertEqual(p.items.map(\.seriesId), ["6af0"])
        XCTAssertEqual(p.items[0].duration, 1001); XCTAssertEqual(p.items[0].playCount, 198)
        XCTAssertEqual(p.items[0].cover, "https://pix.example.com/6af0.jpg")
        XCTAssertTrue(p.hasMore)
        let v = #"var flashvars = {"mediaDefinitions":[{"group":1,"height":1080,"format":"hls","videoUrl":"https:\/\/hls.example.com\/1080\/master.m3u8?h=a","quality":"1080"},{"group":1,"height":480,"format":"hls","videoUrl":"https:\/\/hls.example.com\/480\/master.m3u8","quality":"480"},{"format":"mp4","videoUrl":"https:\/\/www.pornhub.com\/video\/get_media?s=1","quality":[],"remote":true},{"format":"hls","videoUrl":"https:\/\/hls.example.com\/240\/x.m3u8?a=[1]","quality":"240","height":240}],"isVertical":"false"};"#
        let s = PornhubProvider.streams(v)
        XCTAssertEqual(s.map(\.url), ["https://hls.example.com/1080/master.m3u8?h=a", "https://hls.example.com/480/master.m3u8", "https://hls.example.com/240/x.m3u8?a=[1]"])
        XCTAssertEqual(s[0].quality, "1080p · HLS")
    }
}

/// Live reachability/stream table (`TEST_RUNNER_STV_LIVE_SITES=1`). Prints one row per site; asserts only
/// for sources expected to be reachable from this machine (`TEST_RUNNER_STV_LIVE_EXPECT=huangguo,eporner`).
final class LiveSitesTests: XCTestCase {
    struct Row { var name: String; var list = "-"; var detail = "-"; var stream = "-" }

    static func check(_ s: HGStream) async -> String {
        var r = URLRequest(url: URL(string: s.url)!, timeoutInterval: 15)
        for (k, v) in s.headers { r.setValue(v, forHTTPHeaderField: k) }
        if s.kind == .mp4Clear { r.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return "网络失败" }
        if s.kind == .mp4Clear { return "MP4 \(code) \(d.count)B" }
        let text = String(decoding: d, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return "m3u8 \(code) 非清单" }
        var pl = text, plURL = s.url
        if let v = HLSPlaylist.variants(text, s.url).first, let (d2, _) = try? await URLSession.shared.data(for: { var q = URLRequest(url: URL(string: v.url)!); s.headers.forEach { q.setValue($1, forHTTPHeaderField: $0) }; return q }()) {
            pl = String(decoding: d2, as: UTF8.self); plURL = v.url
        }
        guard let seg = pl.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "m3u8 \(code) 无分片" }
        let su = URL(string: String(seg), relativeTo: URL(string: plURL))!.absoluteURL
        var q = URLRequest(url: su, timeoutInterval: 15); s.headers.forEach { q.setValue($1, forHTTPHeaderField: $0) }
        q.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (sd, sr) = try? await URLSession.shared.data(for: q) else { return "m3u8 \(code) 分片网络失败" }
        return "HLS \(code) · 分片 \((sr as? HTTPURLResponse)?.statusCode ?? 0) \(sd.count)B"
    }

    func testLiveSitesTable() async throws {
        guard ProcessInfo.processInfo.environment["STV_LIVE_SITES"] == "1" else { throw XCTSkip("live disabled") }
        let expect = Set((ProcessInfo.processInfo.environment["STV_LIVE_EXPECT"] ?? "").split(separator: ",").map(String.init))
        var rows: [Row] = []
        // Huangguo AI
        var hg = Row(name: "huangguo-ai")
        do {
            let ch = HuangguoClient.aiChannels.first { $0.slug == "ai-duanju" }!
            let items = try await HuangguoClient.shared.list(ch, page: 1).items
            hg.list = "\(items.count)"
            let d = try await HuangguoClient.shared.detail(items[0])
            hg.detail = "\(d.episodes.count) 集"
            let r = try await HuangguoClient.shared.resolve(seriesId: d.seriesId, episode: d.episodes[0])
            hg.stream = await Self.check(r.streams[0]) + (r.streams[0].key.isEmpty ? "" : " · key✓")
        } catch { hg.stream = "错误: \(error.localizedDescription)" }
        rows.append(hg)
        let hanimeHentai = Hanime1Provider().categories.first { $0.id == "hentai" }!
        for src in Sites.all {
            var row = Row(name: src.rawValue)
            guard let p = Sites.provider(src) else { continue }
            let c = src == .hanime1 ? hanimeHentai : p.categories[0]
            do {
                let items = try await withTimeout(40) { try await p.list(c, page: 1).items }
                row.list = "\(items.count)"
                guard let first = items.first else { rows.append(row); continue }
                let d = try await withTimeout(40) { try await p.detail(first) }
                row.detail = d.title.isEmpty ? "空" : "✓"
                let r = try await withTimeout(60) { try await p.resolve(first, d.episodes.first ?? SiteParse.singleEpisode(first, page: first.page ?? "", duration: 0)[0]) }
                row.stream = await Self.check(r.streams[0])
            } catch { if row.list == "-" { row.list = "✗ " + String(error.localizedDescription.prefix(40)) } else { row.stream = "✗ " + String(error.localizedDescription.prefix(60)) } }
            rows.append(row)
        }
        print("LIVE-TABLE-BEGIN")
        for r in rows { print("LIVE | \(r.name) | 列表 \(r.list) | 详情 \(r.detail) | 出流 \(r.stream)") }
        print("LIVE-TABLE-END")
        for r in rows where expect.contains(r.name) || (r.name == "huangguo-ai" && expect.contains("huangguo")) {
            XCTAssertTrue(r.stream.hasPrefix("HLS 200") || r.stream.hasPrefix("HLS 206") || r.stream.hasPrefix("MP4 20"), "\(r.name): \(r.stream)")
        }
    }

    func withTimeout<T: Sendable>(_ s: Double, _ f: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await f() }
            g.addTask { try await Task.sleep(for: .seconds(s)); throw ProviderError.upstream("超时 \(Int(s))s") }
            let v = try await g.next()!; g.cancelAll(); return v
        }
    }
}
