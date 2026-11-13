import XCTest
@testable import STV

private func fixture(_ name: String) throws -> String {
    let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
    return try String(contentsOf: u, encoding: .utf8)
}
private func fixtureData(_ name: String) throws -> Data { Data(try fixture(name).utf8) }

final class TelegramParserTests: XCTestCase {
    func testTelegramChannelPage() throws {
        let p = TGParser.page(try fixture("tg_telegram.html"), channel: "telegram")
        XCTAssertEqual(p.posts.count, 20)
        XCTAssertEqual(p.info?.title, "Telegram News")
        XCTAssertFalse(p.info?.subscribers.isEmpty ?? true)
        XCTAssertEqual(p.before, 441)
        // newest first
        XCTAssertEqual(p.posts.map(\.msgId), p.posts.map(\.msgId).sorted(by: >))
        XCTAssertTrue(p.posts.allSatisfy { $0.date != nil })
        let videos = p.posts.flatMap(\.media).filter { $0.kind == .video }
        XCTAssertFalse(videos.isEmpty)
        XCTAssertTrue(videos.allSatisfy { $0.video?.hasPrefix("https://") == true && !$0.thumb.isEmpty })
        XCTAssertTrue(videos.contains { $0.duration > 0 })
        XCTAssertTrue(p.posts.contains { !$0.text.isEmpty && !$0.text.contains("<") })
    }

    func testDurovTextLinksAndAlbum() throws {
        let p = TGParser.page(try fixture("tg_durov.html"), channel: "durov")
        XCTAssertEqual(p.posts.count, 20)
        XCTAssertTrue(p.posts.contains { $0.text.contains("Georgia") })
        XCTAssertTrue(p.posts.contains { $0.preview != nil })
        XCTAssertTrue(p.posts.contains { !$0.views.isEmpty })
        let older = TGParser.page(try fixture("tg_durov_older.html"), channel: "durov")
        let album = older.posts.first { $0.media.count > 1 }
        XCTAssertNotNil(album, "album (grouped media) parsed")
        XCTAssertTrue(album!.media.allSatisfy { !$0.link.contains("?single") })
        XCTAssertTrue(older.posts.flatMap(\.media).contains { $0.kind == .photo })
    }

    func testNormalize() {
        XCTAssertEqual(TGChannel.normalize("https://t.me/s/durov?before=3"), "durov")
        XCTAssertEqual(TGChannel.normalize("@telegram"), "telegram")
        XCTAssertEqual(TGChannel.normalize("t.me/NudefilmsTV/12"), "NudefilmsTV")
        XCTAssertEqual(TGChannel.normalize("bhg1232"), "bhg1232")
        XCTAssertNil(TGChannel.normalize("ab"))
        XCTAssertNil(TGChannel.normalize("频道名"))
    }

    func testBotLinkAndLanding() {
        let b = TGBotLink(url: "https://t.me/ExampleFileBot?start=abc123")
        XCTAssertEqual(b?.bot, "ExampleFileBot"); XCTAssertEqual(b?.payload, "abc123")
        XCTAssertNil(TGBotLink(url: "https://t.me/durov?start=x"), "not a bot username")
        let html = "<div class=\"tgme_page_title\"><span dir=\"auto\">示例</span></div><div class=\"tgme_page_extra\">1 234 subscribers</div>"
        let c = TGParser.landing(html, channel: "example")
        XCTAssertEqual(c.title, "示例"); XCTAssertEqual(c.subscribers, "1 234 subscribers")
        XCTAssertEqual(TGParser.embedError("<div class=\"tgme_widget_message_error\" dir=\"auto\">This channel can’t be displayed because it was used to spread pornographic content.</div>")?.contains("pornographic"), true)
    }
}

final class TelegramFilterTests: XCTestCase {
    private func ads() throws -> [TGPost] { TGParser.page(try fixture("tg_adsample.html"), channel: "adsample").posts }

    func testHeuristicsOnSyntheticAds() throws {
        let posts = try ads()
        XCTAssertEqual(posts.count, 6)
        let blocked = Set(posts.filter { TGFilter.heuristic($0).blocked }.map(\.msgId))
        XCTAssertEqual(blocked, [102, 103, 104], "tag+gambling, CTA button, invite-only promo")
        XCTAssertFalse(blocked.contains(101)); XCTAssertFalse(blocked.contains(105)); XCTAssertFalse(blocked.contains(106), "bot deep link is content, not an ad")
        XCTAssertEqual(posts.first { $0.msgId == 106 }?.botLinks.first?.payload, "abc123")
    }

    func testNoFalsePositivesOnOfficialChannels() throws {
        for (f, c) in [("tg_telegram.html", "telegram"), ("tg_durov.html", "durov"), ("tg_durov_older.html", "durov")] {
            let posts = TGParser.page(try fixture(f), channel: c).posts
            let hits = posts.filter { TGFilter.heuristic($0).blocked }
            XCTAssertEqual(hits.count, 0, "\(f): \(hits.map { "\($0.msgId) \(TGFilter.heuristic($0).reason)" })")
        }
    }

    func testRulesKeywordRegexDomainScope() throws {
        let posts = try ads()
        let p105 = posts.first { $0.msgId == 105 }!, p101 = posts.first { $0.msgId == 101 }!, p103 = posts.first { $0.msgId == 103 }!
        XCTAssertTrue(TGRule(kind: .domain, pattern: "example.org").matches(p105))
        XCTAssertTrue(TGRule(kind: .domain, pattern: "*.example.org").matches(p105))
        XCTAssertFalse(TGRule(kind: .domain, pattern: "example.org").matches(p101))
        XCTAssertTrue(TGRule(kind: .keyword, pattern: "风景").matches(p101))
        XCTAssertTrue(TGRule(kind: .keyword, pattern: "下载 app").matches(p103), "button text, case-insensitive")
        XCTAssertTrue(TGRule(kind: .regex, pattern: "app\\.example\\.net").matches(p103), "regex sees button URLs")
        XCTAssertFalse(TGRule(kind: .keyword, pattern: "风景", channel: "other").matches(p101))
        XCTAssertTrue(TGRule(kind: .keyword, pattern: "风景", channel: "adsample").matches(p101))
        let v = TGFilter.verdict(p101, rules: [TGRule(kind: .keyword, pattern: "公园")], heuristics: true, channelAdBlock: true)
        XCTAssertTrue(v.blocked); XCTAssertTrue(v.reason.contains("公园"))
        XCTAssertFalse(TGFilter.verdict(posts.first { $0.msgId == 102 }!, rules: [], heuristics: true, channelAdBlock: false).blocked, "per-channel switch")
    }

    func testSuggestionsAndImportExport() throws {
        let p103 = try ads().first { $0.msgId == 103 }!
        let s = TGFilter.suggestions(p103)
        XCTAssertTrue(s.contains { $0.kind == .domain && $0.pattern == "app.example.net" })
        XCTAssertTrue(s.contains { $0.kind == .keyword && $0.pattern == "点击下载 APP" })
        let b = TGRuleBundle(mode: .hide, heuristics: false, rules: [TGRule(kind: .regex, pattern: "a+b", channel: "x")])
        let back = TGFilter.importRules(TGFilter.export(b))
        XCTAssertEqual(back?.mode, .hide); XCTAssertEqual(back?.heuristics, false); XCTAssertEqual(back?.rules.first?.pattern, "a+b")
        let plain = TGFilter.importRules("推广\nre:^福利\ndomain:spam.example\n// comment")
        XCTAssertEqual(plain?.rules.map(\.kind), [.keyword, .regex, .domain])
    }

    func testVideoSeriesForPlayer() throws {
        let p = TGParser.page(try fixture("tg_telegram.html"), channel: "telegram").posts.first { $0.media.contains { $0.video != nil } }!
        let i = p.media.firstIndex { $0.video != nil }!
        let s = TGVideoProvider.series(p, media: i, channel: TGChannel(username: "telegram", title: "Telegram News"))
        XCTAssertEqual(s?.source, .telegram)
        XCTAssertEqual(s?.seriesId, "telegram/\(p.msgId)/\(i)")
        XCTAssertTrue(s?.page?.hasPrefix("https://") == true)
        XCTAssertTrue(s?.isLandscapeCover == true)
        XCTAssertTrue(DramaSource.telegram.isBuiltin && !DramaSource.telegram.isAdult && DramaSource.telegram.isLongVideo)
        let adult = TGVideoProvider.series(p, media: i, channel: TGChannel(username: "x", isAdult: true))
        XCTAssertEqual(adult?.tags, [TGVideoProvider.adultTag])
    }
}

final class MangaParserTests: XCTestCase {
    func testBaoziListSearchDetailChapter() throws {
        let l = BaoziProvider.parseList(try fixtureData("manga_baozi_list.json"))
        XCTAssertEqual(l.items.count, 36); XCTAssertTrue(l.hasMore)
        XCTAssertTrue(l.items[0].cover.hasPrefix("https://static-tw.baozimh.com/cover/"))
        let s = BaoziProvider.parseCards(try fixture("manga_baozi_search.html"))
        XCTAssertGreaterThan(s.count, 10)
        XCTAssertTrue(s.allSatisfy { !$0.title.isEmpty && $0.cover.hasPrefix("https://") })
        let d = BaoziProvider.parseDetail(try fixture("manga_baozi_detail.html"), item: MangaItem(source: .baozi, mangaId: "yirenzhixia-dongmantang", title: "", cover: ""))
        XCTAssertEqual(d.item.title, "一人之下"); XCTAssertEqual(d.item.author, "动漫堂"); XCTAssertEqual(d.status, "连载中")
        XCTAssertGreaterThan(d.chapters.count, 800)
        XCTAssertEqual(d.chapters.first?.chapterId, "0_0"); XCTAssertEqual(d.chapters.first?.title, "1.姐姐1")
        XCTAssertEqual(Set(d.chapters.map(\.chapterId)).count, d.chapters.count, "deduped")
        XCTAssertEqual(d.chapters.map(\.index), Array(0..<d.chapters.count))
        let pages = BaoziProvider.parsePages(try fixture("manga_baozi_chapter.html"))
        XCTAssertGreaterThan(pages.count, 10)
        XCTAssertTrue(pages.allSatisfy { $0.hasPrefix("https://static-tw.baozimh.com/scomic/yirenzhixia-dongmantang/") })
        XCTAssertTrue(pages[0].hasSuffix("/1.jpg"))
    }

    func testMangaDex() throws {
        let o = try JSONSerialization.jsonObject(with: try fixtureData("manga_md_list.json")) as! [String: Any]
        let l = MangaDexProvider.parseList(o)
        XCTAssertEqual(l.items.count, 6); XCTAssertTrue(l.hasMore)
        XCTAssertTrue(l.items.allSatisfy { $0.cover.hasPrefix("https://uploads.mangadex.org/covers/") && $0.cover.hasSuffix(".256.jpg") })
        let f = try JSONSerialization.jsonObject(with: try fixtureData("manga_md_feed.json")) as! [String: Any]
        let ch = MangaDexProvider.chapters(f["data"] as! [[String: Any]])
        XCTAssertFalse(ch.isEmpty)
        XCTAssertEqual(ch.map(\.index), Array(0..<ch.count))
        XCTAssertTrue(ch[0].title.hasPrefix("第75话"))
        let a = try JSONSerialization.jsonObject(with: try fixtureData("manga_md_athome.json")) as! [String: Any]
        let pages = MangaDexProvider.parseAtHome(a)
        XCTAssertEqual(pages.count, 15)
        XCTAssertTrue(pages[0].contains("/data-saver/") || pages[0].contains("/data/"))
        // adult ratings are dropped even if the API returned them
        XCTAssertNil(MangaDexProvider.item(["id": "x", "attributes": ["contentRating": "erotica", "title": ["en": "x"]]]))
    }
}

/// Live checks (opt-in: TEST_RUNNER_STV_LIVE_TG=1) — public non-adult channels + preset channels status.
final class LiveTelegramTests: XCTestCase {
    func testLiveTelegram() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_TG"] == "1")
        for c in ["telegram", "durov"] {
            do {
                let p = try await TGClient.shared.page(c)
                print("LIVE-TG | \(c) | posts \(p.posts.count) | before \(p.before ?? -1) | media \(p.posts.flatMap(\.media).count)")
            } catch { print("LIVE-TG | \(c) | ERROR \(error.localizedDescription)") }
        }
        for c in ["bhg1232", "NudefilmsTV"] {
            do { _ = try await TGClient.shared.page(c); print("LIVE-TG | \(c) | preview available") }
            catch { print("LIVE-TG | \(c) | \(error.localizedDescription)") }
        }
    }
}

/// TDLib engine smoke test: starts the native library with dummy (invalid) credentials and checks it
/// reaches "wait phone number". No phone number is sent, no account is touched.
final class TDLibEngineTests: XCTestCase {
    func testEngineReachesWaitPhone() async throws {
        XCTAssertTrue(TDEngineFactory.available, "TDLibKit linked")
        guard let e = TDEngineFactory.make() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-smoke-\(UUID().uuidString)")
        let exp = expectation(description: "waitPhone")
        var states: [TDAuthState] = []
        e.onState = { s in states.append(s); if s == .waitPhone { exp.fulfill() } }
        try await e.start(TDCredentials(apiId: "1", apiHash: String(repeating: "0", count: 32)), dir: dir, dbKey: "k")
        await fulfillment(of: [exp], timeout: 30)
        print("TDLIB-SMOKE states: \(states)")
        try? FileManager.default.removeItem(at: dir)
    }

    func testCredentialValidation() {
        XCTAssertTrue(TDCredentials(apiId: "12345", apiHash: String(repeating: "a", count: 32)).isValid)
        XCTAssertFalse(TDCredentials(apiId: "x", apiHash: String(repeating: "a", count: 32)).isValid)
        XCTAssertFalse(TDCredentials(apiId: "1", apiHash: "short").isValid)
    }
}

/// Opt-in live checks.
/// - `STV_TG_LIVE_DIR`: t.me/s pages fetched fresh (box, 2026-11-10) → run the Swift parser + filter on them.
/// - `STV_LIVE_MANGA=1`: hit 包子漫画 / MangaDex from this machine (list → detail → chapter pages → first image).
final class LiveContentTests: XCTestCase {
    func testLiveTGPagesParse() throws {
        guard let dir = ProcessInfo.processInfo.environment["STV_TG_LIVE_DIR"] else { throw XCTSkip("no STV_TG_LIVE_DIR") }
        for (f, c) in [("live_telegram_.html", "telegram"), ("live_durov_.html", "durov"), ("live_telegram_before_441_.html", "telegram"), ("live_durov_q_Telegram_.html", "durov")] {
            let html = try String(contentsOfFile: dir + "/" + f, encoding: .utf8)
            let p = TGParser.page(html, channel: c)
            let media = p.posts.flatMap(\.media)
            let blocked = p.posts.filter { TGFilter.heuristic($0).blocked }
            print("LIVE-TG-PARSE | \(f) | posts \(p.posts.count) | ids \(p.posts.first?.msgId ?? 0)..\(p.posts.last?.msgId ?? 0) | before \(p.before ?? -1) | photo \(media.filter { $0.kind == .photo }.count) video \(media.filter { $0.video != nil }.count) | 去广告前 \(p.posts.count) 后 \(p.posts.count - blocked.count)")
            XCTAssertGreaterThan(p.posts.count, 0)
        }
    }

    func testLiveManga() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_MANGA"] == "1")
        for s in MangaSourceID.allCases {
            let p = s.provider
            var line = "LIVE-MANGA | \(s.label)"
            do {
                let l = try await p.list(p.categories[0], page: 1); line += " | 列表 \(l.items.count)"
                let d = try await p.detail(l.items[0]); line += " | 详情《\(d.item.title)》章节 \(d.chapters.count)"
                let pages = try await p.pages(d.item, d.chapters[0]); line += " | 第1章 \(pages.count) 页"
                let (data, _) = try await MangaHTTP.get(pages[0], headers: p.imageHeaders); line += " | 首图 \(data.count / 1024)KB"
                let sr = try await p.search(s == .baozi ? "一人之下" : "frieren", page: 1); line += " | 搜索 \(sr.items.count)"
            } catch { line += " | ERROR \(error.localizedDescription)" }
            print(line)
        }
    }
}
