import XCTest

/// Issue #3: deleting 观看历史 records — ✕ on a row, swipe-to-delete, and 清空 all (with confirmation).
final class HistoryDeleteUITests: XCTestCase {
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STV_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func gone(_ e: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !e.exists { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return !e.exists
    }

    func testDeleteRecords() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["STV_SEED_WATCH"] = "4"
        app.launchEnvironment["STV_ROUTE"] = "history"
        app.launch()
        // Newest first: the seeded 测试记录 4 is the top row, 测试记录 3 the next.
        let first = app.staticTexts["测试记录 4"], second = app.staticTexts["测试记录 3"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "history rows not shown")
        XCTAssertTrue(second.exists)
        shot("history_01")

        // ✕ on the first row
        app.buttons.matching(identifier: "history.delete").firstMatch.tap()
        XCTAssertTrue(gone(first), "✕ did not delete 测试记录 4")
        XCTAssertTrue(second.exists)

        // swipe left on the (new) first row → 删除
        app.cells.firstMatch.swipeLeft()
        let swipeDelete = app.buttons["删除"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3), "swipe action missing")
        swipeDelete.tap()
        XCTAssertTrue(gone(second), "swipe did not delete 测试记录 3")

        // 清空 → confirm
        app.buttons["history.clear"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '清空 '")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "clear confirmation missing")
        shot("history_02_confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["还没有观看记录"].waitForExistence(timeout: 3), "history not cleared")
    }
}
