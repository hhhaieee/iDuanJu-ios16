import XCTest
@testable import STV

/// 1.4 (11): danmaku lanes are placed on the SCREEN (top, full width), never on the letterboxed video
/// and never over the bottom controls.
final class DanmakuRegionTests: XCTestCase {
    let lane: CGFloat = 16 * 1.55
    let portrait = CGSize(width: 402, height: 874), landscape = CGSize(width: 874, height: 402)

    func testPortraitStartsUnderTopBarNotAtVideo() {
        let r = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                      area: DanmakuSettings.Area.third.fraction, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(r.top, 62 + 44 + 34, "lane 0 right under top bar + tech strip")
        XCTAssertLessThan(r.top, portrait.height * 0.2, "lanes start in the top part of the SCREEN")
        XCTAssertEqual(r.rows, 4, "user's row setting caps the default 1/3 area")
        XCTAssertLessThanOrEqual(r.top + CGFloat(r.rows) * lane, r.bottomLimit)
        // A 16:9 video in portrait sits around y≈280…500; the region must not depend on it (no video input at all)
        // and lane 0 must be above where that video starts.
        XCTAssertLessThan(r.top, 280)
        let noTech = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: false,
                                           area: 0.34, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(noTech.top, 62 + 44 + 10)
    }

    func testPortraitAreaAndBottomControlsLimit() {
        let q = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                      area: DanmakuSettings.Area.quarter.fraction, laneHeight: lane, maxRows: 8)
        XCTAssertEqual(q.rows, Int((portrait.height - q.top) * 0.25 / lane))
        let most = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                         area: DanmakuSettings.Area.most.fraction, laneHeight: lane, maxRows: 99)
        XCTAssertLessThanOrEqual(most.top + CGFloat(most.rows) * lane, most.bottomLimit, "never over the bottom controls")
        XCTAssertEqual(most.bottomLimit, portrait.height - 34 - 220)
    }

    func testLandscapeFullWidthFromTop() {
        let r = DanmakuRegion.compute(screen: landscape, safeTop: 0, safeBottom: 21, landscape: true, showTech: true,
                                      area: DanmakuSettings.Area.third.fraction, laneHeight: lane, maxRows: 8)
        XCTAssertEqual(r.top, 14 + 44 + 6)
        XCTAssertGreaterThanOrEqual(r.rows, 3)
        XCTAssertLessThanOrEqual(r.top + CGFloat(r.rows) * lane, r.bottomLimit)
        let most = DanmakuRegion.compute(screen: landscape, safeTop: 0, safeBottom: 21, landscape: true, showTech: true,
                                         area: 0.75, laneHeight: lane, maxRows: 99)
        XCTAssertLessThanOrEqual(most.top + CGFloat(most.rows) * lane, most.bottomLimit, "landscape: above title/progress/icons")
    }

    func testAtLeastOneLaneOnTinyScreens() {
        let r = DanmakuRegion.compute(screen: CGSize(width: 320, height: 300), safeTop: 20, safeBottom: 0, landscape: false, showTech: true,
                                      area: 0.25, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(r.rows, 1)
    }
}
