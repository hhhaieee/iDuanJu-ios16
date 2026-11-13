import XCTest

/// Real taps on 频道 (Telegram feed) and 漫画. Network-free: Telegram pages come from saved fixtures of
/// the public @telegram / @durov channels plus synthetic placeholders; manga uses solid-colour fixture pages.
final class ChannelMangaUITests: XCTestCase {
    var app: XCUIApplication!
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("STVTests/Fixtures").path

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    func launch(_ env: [String: String]) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HERO_STILL"] = "1"
        app.launchEnvironment["STV_TG_FIXTURE_DIR"] = Self.fixtures
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launch()
    }
    func tap(_ e: XCUIElement, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: 15), "missing \(e) \(msg)", file: file, line: line)
        e.tap()
    }
    func waitLabel(_ e: XCUIElement, _ s: String, timeout: TimeInterval = 6) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", s), object: e)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
    func scrollTo(_ e: XCUIElement, in scroll: XCUIElement, max: Int = 25) {
        var n = 0
        while !(e.exists && e.isHittable) && n < max { scroll.swipeUp(velocity: .slow); n += 1 }
    }
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["STV_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    func testAddChannelRefreshViewImagesAndDownload() {
        launch(["STV_HOME_TAB": "channels", "STV_TG_CHANNELS": "telegram,gallery"])
        XCTAssertTrue(el("tg.feed").waitForExistence(timeout: 15))
        XCTAssertTrue(el("tg.post.gallery/7").waitForExistence(timeout: 15), "fixture feed did not load")
        shot("tg_01_feed")

        // Add @durov through 频道管理.
        tap(el("tg.manage"))
        let field = el("tg.add.field"); tap(field); field.typeText("https://t.me/s/durov")
        tap(el("tg.add.button"))
        XCTAssertTrue(app.staticTexts["已订阅 @durov"].waitForExistence(timeout: 5))
        XCTAssertTrue(el("tg.channel.durov").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Refresh → durov posts merged into the feed; chip filters to one channel.
        tap(el("tg.refresh"))
        tap(el("tg.chip.durov"))
        XCTAssertTrue(el("tg.post.durov/553").waitForExistence(timeout: 15), "durov posts not in feed after refresh")
        XCTAssertFalse(el("tg.post.gallery/7").exists, "chip should filter to @durov")
        shot("tg_02_durov")
        tap(el("tg.chip.gallery"))

        // Album → viewer: swipe to next image, double-tap zoom, swipe down to close.
        tap(el("tg.media.gallery/7.0"))
        XCTAssertTrue(el("tg.viewer").waitForExistence(timeout: 5))
        XCTAssertTrue(waitLabel(el("viewer.counter"), "1 / 3"))
        el("tg.viewer").swipeLeft()
        XCTAssertTrue(waitLabel(el("viewer.counter"), "2 / 3"), "swipe did not page: \(el("viewer.counter").label)")
        let img = app.images["viewer.image"].firstMatch.exists ? app.images["viewer.image"].firstMatch : el("viewer.image")
        img.doubleTap()
        XCTAssertTrue(NSPredicate(format: "value == 'zoomed'").evaluate(with: el("viewer.image")) || el("viewer.image").value as? String == "zoomed", "double tap did not zoom")
        shot("tg_03_viewer")
        img.doubleTap()
        el("tg.viewer").swipeDown(velocity: .fast)
        XCTAssertTrue(el("tg.viewer").waitForNonExistence(timeout: 5), "swipe down did not close viewer")

        // Ad post folded by built-in heuristics.
        XCTAssertTrue(el("tg.folded.gallery/6").waitForExistence(timeout: 5), "promo post not folded")

        // Download a short public video (@telegram) → 下载管理 shows it.
        tap(el("tg.chip.telegram"))
        let feed = el("tg.feed")
        let dl = el("tg.download.telegram/441")
        scrollTo(dl, in: feed, max: 40)
        tap(dl)
        var n = 0
        while !(el("tg.downloads").exists && el("tg.downloads").isHittable) && n < 40 { feed.swipeDown(velocity: .fast); n += 1 }
        tap(el("tg.downloads"))
        XCTAssertTrue(el("downloads.row.telegram-441-0").waitForExistence(timeout: 8), "download not queued")
        let done = el("downloads.open.telegram-441-0")
        if done.waitForExistence(timeout: 60) { shot("tg_04_downloads_done") } else { shot("tg_04_downloads_progress") }
        XCTAssertTrue(done.exists || el("downloads.pause.telegram-441-0").exists || el("downloads.resume.telegram-441-0").exists)
    }

    func testLongPressBlockRule() {
        launch(["STV_HOME_TAB": "channels", "STV_TG_CHANNELS": "gallery"])
        let post = el("tg.post.gallery/7")
        XCTAssertTrue(post.waitForExistence(timeout: 15))
        post.press(forDuration: 1.2)
        tap(app.buttons["加入屏蔽…"])
        let custom = el("block.custom"); tap(custom); custom.typeText("占位图片")
        tap(el("block.add"))
        XCTAssertTrue(el("tg.folded.gallery/7").waitForExistence(timeout: 5), "rule did not fold the post")
    }

    func testMangaReaderPageTurn() {
        launch(["STV_HOME_TAB": "manga", "STV_MANGA_FIXTURE": "1"])
        tap(el("manga.cell.fx0"), "manga grid")
        shot("manga_01_detail_pre")
        tap(el("manga.read"))
        XCTAssertTrue(el("manga.reader").waitForExistence(timeout: 8))
        XCTAssertTrue(el("manga.pageCounter").waitForExistence(timeout: 8))
        // Paged mode: swipe left = next page.
        if (el("manga.mode").label).contains("左右") { tap(el("manga.mode")) }
        let counter = el("manga.pageCounter")
        XCTAssertTrue(waitLabel(counter, "1 / 5"), "start page: \(counter.label)")
        el("manga.reader").swipeLeft()
        XCTAssertTrue(waitLabel(counter, "2 / 5"), "page turn failed: \(counter.label)")
        el("manga.reader").swipeLeft()
        XCTAssertTrue(waitLabel(counter, "3 / 5"), "page turn failed: \(counter.label)")
        // Tap zones: right third = next page, left third = previous.
        let r = el("manga.reader")
        r.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(waitLabel(counter, "4 / 5"), "right tap did not turn the page: \(counter.label)")
        r.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        XCTAssertTrue(waitLabel(counter, "3 / 5"), "left tap did not go back: \(counter.label)")
        shot("manga_02_reader_paged")
        tap(el("manga.close"))
        // Progress remembered → 续读.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '续读'")).firstMatch.waitForExistence(timeout: 5), "progress not recorded")
    }
}
