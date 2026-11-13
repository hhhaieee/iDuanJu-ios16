import XCTest

/// 1.4b8 regressions: TDLib login survives an app relaunch; restricted channels are read through TDLib when
/// logged in, and show 「去登录 TDLib」 when not. Uses the DEBUG mock engine (`STV_TD_MOCK`) — no Telegram
/// account, no network; all images are solid-colour placeholders.
final class TDLibUITests: XCTestCase {
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


    func testLoginSurvivesRelaunch() {
        launch(["STV_TD_MOCK": "session", "STV_TD_RESET": "1", "STV_TD_OPEN": "1"])
        XCTAssertTrue(el("tdlib.view").waitForExistence(timeout: 15))
        let id = el("tdlib.apiId"); tap(id); id.typeText("12345")
        let hash = el("tdlib.apiHash"); tap(hash); hash.typeText(String(repeating: "a", count: 32))
        tap(el("tdlib.saveCreds"))
        tap(el("tdlib.start"))
        let phone = el("tdlib.phone"); tap(phone); phone.typeText("+10000000000")
        tap(el("tdlib.sendPhone"))
        let code = el("tdlib.code"); tap(code); code.typeText("12345")
        tap(el("tdlib.sendCode"))
        XCTAssertTrue(waitLabelPrefix(el("tdlib.state"), "已登录"), "login failed: \(el("tdlib.state").label)")

        // Leave the page and come back: still logged in.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.terminate()

        // Cold start, no input: the session is restored by itself.
        launch(["STV_TD_MOCK": "session", "STV_TD_OPEN": "1"])
        XCTAssertTrue(el("tdlib.view").waitForExistence(timeout: 15))
        XCTAssertTrue(waitLabelPrefix(el("tdlib.state"), "已登录", timeout: 10), "after relaunch: \(el("tdlib.state").label)")
        XCTAssertFalse(el("tdlib.phone").exists, "must not ask for the phone again")
        shot("td_01_restored_after_relaunch")

        // Explicit logout asks first.
        tap(el("tdlib.logout"))
        XCTAssertTrue(app.buttons["退出登录并删除本机会话"].waitForExistence(timeout: 5))
        app.buttons["退出登录并删除本机会话"].tap()
        XCTAssertTrue(waitLabelPrefix(el("tdlib.state"), "未启动"), "after logout: \(el("tdlib.state").label)")
    }

    func testRestrictedChannelReadThroughTDLib() {
        launch(["STV_TD_MOCK": "ready", "STV_HOME_TAB": "channels", "STV_TG_CHANNELS": "restrictedsample,telegram"])
        XCTAssertTrue(el("tg.feed").waitForExistence(timeout: 15))
        tap(el("tg.chip.restrictedsample"))
        // Telegram restricts it for this account → explicit reason + 「显示敏感内容」.
        tap(el("tg.error.sensitive.restrictedsample"), "restriction banner")
        XCTAssertTrue(el("tg.post.restrictedsample/300").waitForExistence(timeout: 15), "TDLib posts not in feed")
        XCTAssertFalse(el("tg.error.restrictedsample").exists, "banner should be gone once TDLib delivers")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "TDLib 示例帖")).firstMatch.exists)
        shot("td_02_restricted_via_tdlib")
        // Paging (getChatHistory from the oldest id) + ad heuristics on TDLib posts.
        let feed = el("tg.feed")
        var n = 0
        while !el("tg.post.restrictedsample/260").exists && n < 40 { feed.swipeUp(velocity: .fast); n += 1 }
        XCTAssertTrue(el("tg.post.restrictedsample/260").exists, "second TDLib page not loaded")
    }

    func testRestrictedChannelNotLoggedInOffersLogin() {
        launch(["STV_TD_RESET": "1", "STV_HOME_TAB": "channels", "STV_TG_CHANNELS": "restrictedsample"])
        XCTAssertTrue(el("tg.feed").waitForExistence(timeout: 15))
        tap(el("tg.error.login.restrictedsample"), "去登录 TDLib")
        XCTAssertTrue(el("tdlib.view").waitForExistence(timeout: 10))
        shot("td_03_login_entry")
    }

    func waitLabelPrefix(_ e: XCUIElement, _ s: String, timeout: TimeInterval = 8) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", s), object: e)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
}
