import XCTest
@testable import STV

/// Sample playlists modelled on the researched sources (hosts/paths shortened, structure kept).
final class HLSAdFilterTests: XCTestCase {
    private func pl(_ body: [String], endlist: Bool = true) -> String {
        (["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"] + body + (endlist ? ["#EXT-X-ENDLIST"] : [])).joined(separator: "\n")
    }
    private func segs(_ prefix: String, _ range: ClosedRange<Int>, dur: Double = 6) -> [String] {
        range.flatMap { ["#EXTINF:\(dur),", "\(prefix)\(String(format: "%04d", $0)).ts"] }
    }
    private func uris(_ text: String) -> [String] { text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty } }
    private let base = URL(string: "https://v.example.com/20250101/abc/1000kb/hls/index.m3u8")!

    /// 暴风: /video/adjump/ segments.
    func testBaofengAdjump() {
        let text = pl(segs("main", 0...9) + ["#EXT-X-DISCONTINUITY"] + segs("https://bfzy.example/video/adjump/time/ad", 0...2, dur: 5) + ["#EXT-X-DISCONTINUITY"] + segs("main", 10...19))
        let r = HLSAdFilter.filter(text, base: base)
        XCTAssertEqual(r.removed, 3)
        XCTAssertFalse(r.text.contains("adjump"))
        XCTAssertEqual(uris(r.text).count, 20)
        XCTAssertEqual(r.text.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1, 1, "one seam where the ad was")
        XCTAssertTrue(r.text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    /// 360资源 / 猫眼: AES main content, METHOD=NONE short block on 360zyx.vip.
    func testClearBlockInsideAES() {
        let key = "#EXT-X-KEY:METHOD=AES-128,URI=\"https://v.example.com/key.key\""
        let body = [key] + segs("main", 0...14, dur: 4)
            + ["#EXT-X-DISCONTINUITY", "#EXT-X-KEY:METHOD=NONE"] + segs("main_ad", 0...3, dur: 4)
            + ["#EXT-X-DISCONTINUITY", key] + segs("main", 15...30, dur: 4)
        let r = HLSAdFilter.filter(pl(body), base: URL(string: "https://play.360zyx.vip/x/index.m3u8")!)
        XCTAssertEqual(r.removed, 4)
        XCTAssertFalse(uris(r.text).contains { $0.contains("main_ad") })
        XCTAssertFalse(r.text.contains("METHOD=NONE"), "kept segments stay under the AES key")
        XCTAssertEqual(r.text.components(separatedBy: "METHOD=AES-128").count - 1, 1)
    }

    /// 爱坤: ad block from bfikuncdn.com between main segments.
    func testAikunForeignHost() {
        let body = segs("main", 0...20) + ["#EXT-X-DISCONTINUITY"] + segs("https://c1.bfikuncdn.com/ad/seg", 0...3, dur: 4) + ["#EXT-X-DISCONTINUITY"] + segs("main", 21...40)
        let r = HLSAdFilter.filter(pl(body), base: base)
        XCTAssertEqual(r.removed, 4)
        XCTAssertFalse(r.text.contains("bfikuncdn"))
    }

    /// 樱花: leading ad block on ts1.yhzybf.com, then the episode.
    func testYinghuaLeadingBlock() {
        let body = segs("https://ts1.yhzybf.com/ad/a", 0...2, dur: 5) + ["#EXT-X-DISCONTINUITY"] + segs("main", 0...30)
        let r = HLSAdFilter.filter(pl(body), base: base)
        XCTAssertEqual(r.removed, 3)
        XCTAssertFalse(r.text.contains("yhzybf"))
        XCTAssertFalse(r.text.contains("#EXT-X-DISCONTINUITY"), "nothing kept before the first main segment")
        XCTAssertEqual(uris(r.text).first, "main0000.ts")
    }

    /// 如意: DISCONTINUITY every 5 segments on the same host/dir — must be untouched.
    func testRuyiDiscontinuitiesKept() {
        var body: [String] = []
        for b in 0..<8 { if b > 0 { body.append("#EXT-X-DISCONTINUITY") }; body += segs("main", (b * 5)...(b * 5 + 4), dur: 5) }
        let text = pl(body)
        let r = HLSAdFilter.filter(text, base: base)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.text, text)
    }

    /// The same creative spliced in twice.
    func testRepeatedSegments() {
        let ad = ["#EXTINF:3,", "https://v.example.com/20250101/abc/1000kb/hls/promo.ts"]
        let body = segs("main", 0...10) + ad + segs("main", 11...20) + ad + segs("main", 21...30)
        let r = HLSAdFilter.filter(pl(body), base: base)
        XCTAssertEqual(r.removed, 2)
        XCTAssertFalse(r.text.contains("promo.ts"))
    }

    /// A foreign block that is long (a real second part) or a 2 s bumper is not an ad by these rules.
    func testLongOrTinyForeignBlocksKept() {
        let long = segs("main", 0...10) + ["#EXT-X-DISCONTINUITY"] + segs("https://other.example/p2/s", 0...9, dur: 6) + ["#EXT-X-DISCONTINUITY"] + segs("main", 11...20)
        XCTAssertEqual(HLSAdFilter.filter(pl(long), base: base).removed, 0)   // 60 s
        let tiny = segs("main", 0...10) + ["#EXT-X-DISCONTINUITY"] + segs("https://other.example/b/s", 0...0, dur: 2) + ["#EXT-X-DISCONTINUITY"] + segs("main", 11...20)
        XCTAssertEqual(HLSAdFilter.filter(pl(tiny), base: base).removed, 0)
    }

    /// Never more than 40 % of the playlist.
    func testSafetyCap() {
        let body = segs("main", 0...2) + ["#EXT-X-DISCONTINUITY"] + segs("https://ads.example/x/a", 0...3, dur: 5)
        let r = HLSAdFilter.filter(pl(body), base: base)
        XCTAssertEqual(r.removed, 0)
    }

    func testMasterPlaylistUntouched() {
        let m = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n1000kb/hls/index.m3u8\n"
        XCTAssertEqual(HLSAdFilter.filter(m, base: base).text, m)
    }

    func testToggle() {
        let old = UserDefaults.standard.object(forKey: HLSAdFilter.defaultsKey)
        defer { UserDefaults.standard.set(old, forKey: HLSAdFilter.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: HLSAdFilter.defaultsKey)
        XCTAssertTrue(HLSAdFilter.enabled, "default on")
        let text = pl(segs("main", 0...9) + ["#EXT-X-DISCONTINUITY"] + segs("https://bf.example/video/adjump/a", 0...1, dur: 5) + ["#EXT-X-DISCONTINUITY"] + segs("main", 10...19))
        XCTAssertFalse(HLSAdFilter.apply(text, base: base).contains("adjump"))
        HLSAdFilter.enabled = false
        XCTAssertEqual(HLSAdFilter.apply(text, base: base), text)
    }
}
