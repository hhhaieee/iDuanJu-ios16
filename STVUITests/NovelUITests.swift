import XCTest

/// 小说 shelf → reader: page turning by tap, menu, 目录 jump, font size relayout.
final class NovelUITests: XCTestCase {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("STVTests/Fixtures/novel_sample_gbk.txt").path
    var app: XCUIApplication!
    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STV_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
    func pageLabel() -> (Int, Int) {
        let parts = el("novel.page").label.components(separatedBy: " / ").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    func testReadTurnPagesAndJumpChapter() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HOME_TAB"] = "novel"
        app.launchEnvironment["STV_NOVEL_SEED"] = Self.sample
        app.launch()
        let book = el("novel.book.novel_sample_gbk")
        XCTAssertTrue(book.waitForExistence(timeout: 10), "seeded book not on shelf")
        shot("novel_01_shelf")
        book.tap()
        XCTAssertTrue(el("novel.page").waitForExistence(timeout: 5), "reader did not open")
        let (p0, n0) = pageLabel()
        XCTAssertGreaterThan(n0, 1)
        shot("novel_02_page")

        // Right third → next page; left third → back.
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        waitPage(p0 + 1, "tap right did not turn the page")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        waitPage(p0, "tap left did not go back")

        // Middle → menu; 目录 → 第三章.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(el("novel.menu.目录").waitForExistence(timeout: 3), "menu did not show")
        shot("novel_03_menu")
        el("novel.menu.目录").tap()
        let ch3 = app.buttons["第三章 灯塔"]
        XCTAssertTrue(ch3.waitForExistence(timeout: 3), "目录 sheet missing")
        ch3.tap()
        XCTAssertTrue(app.staticTexts["第三章 灯塔"].waitForExistence(timeout: 3), "did not jump to 第三章")
        XCTAssertEqual(pageLabel().0, 1)

        // 设置: dragging the 字号 slider to the big end re-paginates (more pages for the same chapter).
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.menu.设置").tap()
        let size = el("novel.font.size")
        XCTAssertTrue(size.waitForExistence(timeout: 3))
        // Prefs persist between runs: start from the small end, then go big.
        size.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: size.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        let before = pageLabel().1
        size.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.05, thenDragTo: size.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)))
        shot("novel_04_font")
        el("novel.menu.亮度").tap()
        XCTAssertTrue(el("novel.theme.2").waitForExistence(timeout: 3))
        el("novel.theme.2").tap()
        shot("novel_04b_colors")
        el("novel.menu.进度").tap()
        shot("novel_04c_progress")
        el("novel.menu.目录").tap()
        shot("novel_04d_toc")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // close the menu
        XCTAssertGreaterThan(pageLabel().1, before, "bigger font did not add pages")
        shot("novel_05_paper")
    }

    func openSample() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HOME_TAB"] = "novel"
        app.launchEnvironment["STV_NOVEL_SEED"] = Self.sample
        app.launch()
        let book = el("novel.book.novel_sample_gbk")
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(el("novel.page").waitForExistence(timeout: 5))
    }

    func setTurn(_ raw: Int) {
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.menu.设置").tap()
        el("novel.turn").tap()
        XCTAssertTrue(el("novel.turn.\(raw)").waitForExistence(timeout: 3))
        el("novel.turn.\(raw)").tap()
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()   // close the menu
    }

    func waitPage(_ want: Int, _ msg: String) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, pageLabel().0 != want { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(pageLabel().0, want, msg)
    }

    /// 仿真 / 滑动 / 覆盖 / 无动画: tap the right third and drag right-to-left both turn forward; tap left goes back.
    func testTurnStyles() {
        openSample()
        let win = app.windows.firstMatch
        // The hint fades out after a few seconds (WeRead shows it only when the book opens).
        XCTAssertTrue(app.staticTexts["↑上滑显示工具栏"].exists)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.staticTexts["↑上滑显示工具栏"].exists, "hint did not go away")
        for (raw, name) in [(0, "curl"), (1, "slide"), (2, "cover"), (3, "none")] {
            setTurn(raw)
            let p = pageLabel().0
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            waitPage(p + 1, "\(name): tap right")
            let from = win.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
            from.press(forDuration: 0.05, thenDragTo: win.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)))
            waitPage(p + 2, "\(name): drag left")
            if raw == 1 { shot("novel_turn_slide") }
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            waitPage(p + 1, "\(name): tap left")
        }
    }

    /// 听书 reads aloud, pauses, and the page follows the sentence being read.
    func testListen() {
        openSample()
        let win = app.windows.firstMatch
        // Start at the top of the long first chapter (progress is shared between tests).
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.menu.目录").tap()
        app.buttons["第一章 雨夜"].tap()
        XCTAssertTrue(app.staticTexts["第一章 雨夜"].waitForExistence(timeout: 3))
        let start = pageLabel().0
        XCTAssertEqual(start, 1)
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.listen").tap()
        let state = el("novel.listen.state")
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertTrue(state.label.hasPrefix("正在朗读"), state.label)
        shot("novel_listen")
        el("novel.listen.toggle").tap()
        XCTAssertEqual(state.label, "已暂停")
        el("novel.listen.toggle").tap()
        XCTAssertTrue(state.label.hasPrefix("正在朗读"))
        // Skip ahead sentence by sentence: the page turns with the reading position.
        let next = app.buttons["下一句"]
        for _ in 0..<14 { next.tap() }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()   // close the menu
        XCTAssertTrue(el("novel.miniplayer").waitForExistence(timeout: 3), "mini player missing while reading")
        let end = Date().addingTimeInterval(5)
        while Date() < end, pageLabel().0 <= start { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertGreaterThan(pageLabel().0, start, "page did not follow 听书")
        shot("novel_listen_follow")
        el("novel.mini.toggle").tap()
    }

    /// 字体样式 panel lists the fonts; picking 楷体 (an iOS system font, downloaded by the system if needed) applies it.
    func testFontsPanel() {
        openSample()
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.menu.设置").tap()
        el("novel.fonts").tap()
        XCTAssertTrue(el("novel.font.wenkai").waitForExistence(timeout: 3), "font list missing")
        XCTAssertTrue(el("novel.font.sourceserif").exists)
        shot("novel_fonts")
        el("novel.font.kaiti").tap()
        let end = Date().addingTimeInterval(60)
        while Date() < end, !el("novel.fonts").exists { el("novel.font.kaiti").tap(); Thread.sleep(forTimeInterval: 2); if el("novel.font.kaiti").label.contains("楷体") && app.images["checkmark"].exists { break } }
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        shot("novel_kaiti")
    }

    /// 书源: source list → 搜书 → 详情 → 开始阅读 (chapters fetched from a local fake site) → 目录 jump.
    func testLegadoSourceSearchAndRead() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HOME_TAB"] = "novel"
        app.launchEnvironment["STV_LEGADO_FIXTURE"] = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("STVTests/Fixtures/legado").path
        app.launch()
        el("novel.sources").tap()
        XCTAssertTrue(app.staticTexts["测试书站"].waitForExistence(timeout: 5), "imported source not listed")
        shot("legado_01_sources")
        app.buttons["完成"].tap()
        el("novel.search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("wu\n")
        let hit = el("search.result.雾港")
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "no search result")
        XCTAssertTrue(el("search.result.雾港外传").exists)
        shot("legado_02_search")
        hit.tap()
        XCTAssertTrue(app.staticTexts["共 3 章"].waitForExistence(timeout: 10), "目录 not loaded on the detail page")
        XCTAssertTrue(app.staticTexts["雾气笼罩的港口小城里，每个人都在等一艘船。"].exists, "intro missing")
        shot("legado_03_detail")
        el("detail.read").tap()
        // Reader opens on 第一章, fetched from the fake site.
        XCTAssertTrue(el("novel.page").waitForExistence(timeout: 10), "reader did not open")
        let end = Date().addingTimeInterval(10)
        while Date() < end, pageLabel().1 < 2 { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertGreaterThan(pageLabel().1, 1, "chapter text did not arrive (still the 正在加载 page)")
        shot("legado_04_reader")
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        el("novel.menu.目录").tap()
        app.buttons["第三章 灯塔"].tap()
        XCTAssertTrue(app.staticTexts["第三章 灯塔"].waitForExistence(timeout: 10))
        shot("legado_05_ch3")
    }

    /// 书源登录 page built from loginUi: fields, a source button, 登录 → login() stores the login header.
    func testSourceLoginForm() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HOME_TAB"] = "novel"
        app.launchEnvironment["STV_LEGADO_FIXTURE"] = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("STVTests/Fixtures/legado").path
        app.launch()
        el("novel.sources").tap()
        let row = app.staticTexts["测试书站"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        app.buttons["登录"].firstMatch.tap()
        let account = app.textFields["账号"]
        XCTAssertTrue(account.waitForExistence(timeout: 5), "login form not shown")
        // Start logged out (state persists between runs).
        if app.buttons["退出登录"].exists { app.buttons["退出登录"].tap() }
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        account.tap(); account.typeText("reader01")
        app.buttons["测试按钮"].tap()
        XCTAssertTrue(app.staticTexts["书源按钮已执行"].waitForExistence(timeout: 5), "button action did not run")
        el("login.submit").tap()
        XCTAssertTrue(app.staticTexts["已登录：reader01"].waitForExistence(timeout: 5), "login() did not run")
        shot("legado_06_login")
        shot("legado_06_login")
    }

    /// Live: imports a real source collection (aggregates + audio / comic / video sources) and searches in the app.
    /// TEST_RUNNER_STV_LEGADO_IMPORT=/abs/all.json; the app must not crash and must finish every source.
    func testSearchWithImportedCollection() {
        guard let file = ProcessInfo.processInfo.environment["STV_LEGADO_IMPORT"] else { return }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_HOME_TAB"] = "novel"
        app.launchEnvironment["STV_LEGADO_IMPORT"] = file
        app.launch()
        el("novel.search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("斗破苍穹\n")
        let done = NSPredicate(format: "label BEGINSWITH '共 '")
        let header = app.staticTexts.matching(done).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 90), "search did not finish")
        XCTAssertEqual(app.state, .runningForeground, "app crashed")
        print("[ui-search] \(header.label)")
        shot("legado_07_collection_search")
    }
}
