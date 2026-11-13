import XCTest

/// Network (`STV_LIVE_HG=1`): swipe to the next 红果 episode in the real feed and check it plays.
/// Screenshots land in `STV_SHOT_DIR` when set.
final class EpisodeSwipeUITests: XCTestCase {
    func testSwipeToNextEpisodePlays() throws {
 try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_HG"] == "1")
 let app = XCUIApplication()
        app.launchEnvironment["STV_PLAY_SERIES"] = ProcessInfo.processInfo.environment["STV_SERIES"] ?? "7701935931787316286"
        app.launch()
        let progress = app.descendants(matching: .any)["player.progress"].firstMatch
 XCTAssertTrue(progress.waitForExistence(timeout: 30), "first episode did not become ready")
        shot(app, "swipe_0_ready")
 let w = app.windows.firstMatch
        let t0 = Date()
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
     .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        shot(app, "swipe_1_after")
        XCTAssertTrue(progress.waitForExistence(timeout: 30), "next episode did not become ready")
        print("SWIPE next ready in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        shot(app, "swipe_2_next_ready")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STV_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
