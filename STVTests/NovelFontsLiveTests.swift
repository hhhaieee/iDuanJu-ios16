import XCTest
import UIKit
@testable import STV

/// Live (`STV_LIVE_FONT=1`): downloads 思源黑体 / 霞鹜文楷 (jsDelivr → GitHub) and the 楷体 system asset, then checks they render.
@MainActor
final class NovelFontsLiveTests: XCTestCase {
    func testDownloadAndRegister() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_FONT"] == "1", "live")
        let fonts = NovelFonts.shared
        for id in ["sourcesans", "wenkai", "kaiti"] {
            fonts.fetch(id)
            let end = Date().addingTimeInterval(240)
            while !fonts.isReady(id), fonts.errors[id] == nil, Date() < end { try await Task.sleep(for: .milliseconds(500)) }
            XCTAssertNil(fonts.errors[id], id)
            XCTAssertTrue(fonts.isReady(id), "\(id) not available")
            let f = NovelFonts.font(id, size: 18)
            XCTAssertNotEqual(f.familyName, UIFont.systemFont(ofSize: 18).familyName, "\(id) fell back to the system font")
            print("[live] \(id) → \(f.fontName)")
        }
    }
}
