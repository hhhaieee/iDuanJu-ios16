import XCTest
@testable import STV

/// Network (`STV_LIVE_HG=1`): 黄果 search uses the sites' own search (issue #2 / #3), not a first-page title scan.
final class HuangguoSearchLiveTests: XCTestCase {
    func testSiteSearchFindsIssueKeywords() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_HG"] == "1")
        for q in ["修仙", "神雕", "宋青书"] {
     let r = try await HuangguoClient.shared.search(q)
     let by = Dictionary(grouping: r, by: { $0.seriesId.split(separator: ":").first.map(String.init) ?? "?" }).mapValues(\.count)
     print("HGSEARCH \(q): \(r.count) \(by) e.g. \(r.prefix(3).map(\.title))")
        }
        let r = try await HuangguoClient.shared.search("修仙")
        XCTAssertGreaterThan(r.count, 10, "site search should return many 修仙 titles")
        XCTAssertTrue(r.allSatisfy { !$0.title.isEmpty && !$0.seriesId.isEmpty })
    }
}
