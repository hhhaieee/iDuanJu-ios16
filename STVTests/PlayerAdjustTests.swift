import XCTest
@testable import STV

@MainActor
final class PlayerAdjustTests: XCTestCase {
    func testPortraitOnlyOuterFifths() {
        let w: CGFloat = 400, e: CGFloat = 36
        XCTAssertNil(PlayerAdjuster.zone(x: 20, width: w, landscape: false, edge: e), "edge-back strip")
        XCTAssertEqual(PlayerAdjuster.zone(x: 60, width: w, landscape: false, edge: e), .brightness)
        XCTAssertNil(PlayerAdjuster.zone(x: 81, width: w, landscape: false, edge: e), "middle pages")
        XCTAssertNil(PlayerAdjuster.zone(x: 200, width: w, landscape: false, edge: e))
        XCTAssertNil(PlayerAdjuster.zone(x: 319, width: w, landscape: false, edge: e))
        XCTAssertEqual(PlayerAdjuster.zone(x: 350, width: w, landscape: false, edge: e), .volume)
    }
    func testLandscapeHalves() {
        let w: CGFloat = 900, e: CGFloat = 36
        XCTAssertNil(PlayerAdjuster.zone(x: 10, width: w, landscape: true, edge: e))
        XCTAssertEqual(PlayerAdjuster.zone(x: 300, width: w, landscape: true, edge: e), .brightness)
        XCTAssertEqual(PlayerAdjuster.zone(x: 600, width: w, landscape: true, edge: e), .volume)
    }
    func testBrightnessClampAndRestore() {
        let a = PlayerAdjuster()
        let orig = UIScreen.main.brightness
        a.begin(.brightness)
        a.change(.brightness, fraction: 5)
        XCTAssertEqual(a.hud?.value, 1)
        a.change(.brightness, fraction: -5)
        XCTAssertEqual(a.hud?.value, 0)
        a.restoreBrightness()
        XCTAssertEqual(UIScreen.main.brightness, orig, accuracy: 0.01)
    }
}
