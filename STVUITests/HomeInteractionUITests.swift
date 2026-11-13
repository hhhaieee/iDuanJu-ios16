import XCTest

/// Real-interaction regression for the 发现 page (taps / swipes, not screenshots):
/// search + filter, channel tabs, expand panel, hero swipe + taps, section 全部 + cards,
/// vertical scrolling, the floating tab bar, and the other root pages' top controls.
/// Needs the hongguo network (same as the app's home feed).
final class HomeInteractionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HERO_STILL"] = "1"
        app.launchEnvironment["STV_SOURCES"] = "huangguo"   // 黄果 is 18+ and hidden by default
        app.launch()
        XCTAssertTrue(el("home.page.红果").waitForExistence(timeout: 15))
    }

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Tap at the element's centre via coordinates: this is what a finger does, so an
    /// invisible layer stacked on top would swallow it (element.tap() alone would too).
    func fingerTap(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: 15), "missing \(e)", file: file, line: line)
        XCTAssertTrue(e.isHittable, "not hittable: \(e)", file: file, line: line)
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.waitForExistence(timeout: 3) { b.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        XCTAssertTrue(el("home.page.红果").waitForExistence(timeout: 8))
    }

    func testSearchAndFilter() {
        fingerTap(el("home.search"))
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8), "search page did not open")
        back()
        fingerTap(el("home.filter"))
        XCTAssertTrue(app.navigationBars["频道"].waitForExistence(timeout: 5), "filter panel did not open")
        app.navigationBars["频道"].buttons["完成"].tap()
        XCTAssertTrue(el("home.expand").waitForExistence(timeout: 5))
        fingerTap(el("home.expand"))
        XCTAssertTrue(app.navigationBars["频道"].waitForExistence(timeout: 5), "expand panel did not open")
        // Choose 黄果 · App 源 from the panel → that source page + sub chip are selected.
        fingerTap(el("panel.黄果.App 源"))
        XCTAssertTrue(el("home.channel.黄果").isSelectedChannel(), "panel pick did not switch source")
        XCTAssertTrue(el("home.sub.App 源").isSelectedChannel(), "panel pick did not switch sub board")
    }

    func testSourceBarTapAndPagerSwipe() {
        XCTAssertTrue(el("home.hero.page.0").waitForExistence(timeout: 20), "hero not loaded")
        XCTAssertTrue(el("home.channel.红果").isSelectedChannel())
        // Swipe on the 红果 page below the hero → pages to 黄果. Start on a section header: the 继续观看 row
        // itself scrolls horizontally once there is watch history, and must keep that gesture.
        let header = app.staticTexts["继续观看"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let w = app.windows.firstMatch, y = header.frame.midY / max(1, w.frame.height)
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: y)))
        XCTAssertTrue(el("home.channel.黄果").isSelectedChannel(), "swipe on 红果 page did not page to 黄果")
        fingerTap(el("home.channel.红果"))
        XCTAssertTrue(el("home.channel.红果").isSelectedChannel())
        // Tap a source.
        fingerTap(el("home.channel.黄果"))
        XCTAssertTrue(el("home.channel.黄果").isSelectedChannel(), "tap did not select 黄果")
        XCTAssertTrue(el("home.sub.视频站").waitForExistence(timeout: 8), "黄果 page content not shown")
        // Swipe the content area left/right → next/previous source, bar follows.
        var pager = el("home.page.黄果")
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.75)))
        XCTAssertTrue(el("home.channel.AI剧").isSelectedChannel(), "swipe left did not page to AI剧")
        XCTAssertTrue(el("home.sub.红果 AI剧").waitForExistence(timeout: 8))
        pager = el("home.page.AI剧")
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75)))
        XCTAssertTrue(el("home.channel.黄果").isSelectedChannel(), "swipe right did not page back")
        fingerTap(el("home.channel.红果"))
        XCTAssertTrue(el("home.channel.红果").isSelectedChannel())
        // Sub boards inside a page switch content.
        fingerTap(el("home.sub.真人剧"))
        XCTAssertTrue(el("home.sub.真人剧").isSelectedChannel())
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.more.真人'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "真人剧 boards not shown")
    }

    func testHeroSwipeAndTaps() {
        let page0 = el("home.hero.page.0")
        XCTAssertTrue(page0.waitForExistence(timeout: 20))
        let dots = el("home.hero.dots")
        XCTAssertTrue(dots.waitForExistence(timeout: 5))
        let start = dots.label
        page0.swipeLeft()
        let moved = NSPredicate(format: "label != %@", start)
        expectation(for: moved, evaluatedWith: dots)
        waitForExpectations(timeout: 4)
        // A swipe inside the carousel belongs to the carousel, not the source pager.
        XCTAssertTrue(el("home.channel.红果").isSelected, "hero swipe leaked to the source pager")
        // 查看详情 / poster on the visible page open the detail page (tap where the capsule is drawn).
        let detailText = app.staticTexts.matching(NSPredicate(format: "label == %@", "查看详情")).allElementsBoundByIndex.first { $0.frame.minX > 0 && $0.frame.maxX < app.frame.width }
        XCTAssertNotNil(detailText, "查看详情 not on screen")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: detailText!.frame.midX, dy: detailText!.frame.midY)).tap()
        XCTAssertTrue(el("screen.detail").waitForExistence(timeout: 8), "查看详情 did not open detail")
        back()
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.hero.page.'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(page)
        page!.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()   // the poster side
        XCTAssertTrue(el("screen.detail").waitForExistence(timeout: 8), "poster did not open detail")
    }

    func testSectionsScrollAndCards() {
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.more.'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        fingerTap(more)
        XCTAssertTrue(el("screen.board").waitForExistence(timeout: 8), "全部 did not open the board")
        back()
        XCTAssertTrue(el("home.card").waitForExistence(timeout: 10))
        el("home.page.红果").swipeUp()
        // A card fully above the floating tab bar.
        let card = app.descendants(matching: .any).matching(identifier: "home.card").allElementsBoundByIndex
            .first { $0.frame.minY > 120 && $0.frame.maxY < app.frame.height - 110 }
        XCTAssertNotNil(card, "no card on screen")
        fingerTap(card!)
        XCTAssertTrue(el("screen.detail").waitForExistence(timeout: 8), "card did not open detail")
        back()
        // Vertical scrolling: the header leaves the screen after a few swipes up.
        let home = el("home.page.红果")
        for _ in 0..<3 { home.swipeUp() }
        XCTAssertFalse(el("home.hero.page.0").isHittable, "home did not scroll")
        for _ in 0..<4 { home.swipeDown() }
        XCTAssertTrue(el("home.search").waitForExistence(timeout: 3))
    }

    func testTabBarAndOtherRootTops() {
        fingerTap(el("tab.1"))
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8), "搜索 tab")
        fingerTap(app.textFields.firstMatch)
        app.typeText("总裁")
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "总裁", "search field at top not tappable")
        app.typeText("\n")   // submit → keyboard goes away so the tab bar is reachable again
        fingerTap(el("tab.2"))
        XCTAssertTrue(app.buttons["榜单"].firstMatch.waitForExistence(timeout: 8), "找剧 tab")
        // Top controls of 找剧 respond (segment + genre pill).
        fingerTap(app.buttons["榜单"].firstMatch)
        let pill = app.buttons["真人剧"].firstMatch
        if pill.waitForExistence(timeout: 5) { fingerTap(pill) }
        fingerTap(el("tab.3"))
        XCTAssertTrue(app.staticTexts["我的"].firstMatch.waitForExistence(timeout: 8), "我的 tab")
        fingerTap(el("tab.0"))
        XCTAssertTrue(el("home.search").waitForExistence(timeout: 8), "首页 tab")
        fingerTap(el("home.search"))
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8))
    }
}

/// With the opt-in sites enabled the bar overflows: the selected source scrolls to the centre.
final class HomeSourceBarCenteringUITests: XCTestCase {
    func testSelectedSourceScrollsToCenter() {
        let app = XCUIApplication()
        app.launchEnvironment["STV_SOURCES"] = "jable,missav,hanime1,supjav"   // DEBUG hook; no screenshots taken
        app.launch()
        let bar = app.descendants(matching: .any)["home.channels"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        for name in ["MissAV", "Jable"] {
            let b = app.descendants(matching: .any)["home.channel.\(name)"].firstMatch
            for _ in 0..<3 where !b.isHittable { bar.swipeLeft() }
            b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(b.isSelectedChannel(), "\(name) not selected")
            sleep(1)
            XCTAssertLessThan(abs(b.frame.midX - bar.frame.midX), 36, "\(name) not centred: \(b.frame) in \(bar.frame)")
        }
        // Paging by swipe keeps the bar following and centred.
        let pager = app.descendants(matching: .any)["home.page.Jable"].firstMatch
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        let next = app.descendants(matching: .any)["home.channel.MissAV"].firstMatch
        XCTAssertTrue(next.isSelectedChannel(), "swipe did not advance from Jable to MissAV")
        sleep(1)
        XCTAssertLessThan(abs(next.frame.midX - bar.frame.midX), 36, "MissAV not centred after swipe")
    }
}

private extension XCUIElement {
    /// Selected channel carries the .isSelected trait.
    func isSelectedChannel() -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { if isSelected { return true }; usleep(200_000) }
        return isSelected
    }
}
