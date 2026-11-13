import XCTest
@testable import STV

/// AetherEngine really decodes through each input path the coordinator uses.
@MainActor
final class AetherPlaybackTests: XCTestCase {
    private func playFor(_ src: PlaybackCoordinator.Source, seconds want: Double = 1.5, timeout: TimeInterval = 40) async throws -> (Double, String) {
        let e = try AetherPlayerEngine()
        defer { e.stop() }
        try await e.load(src, stream: nil, start: nil, title: "test")
        e.muted = true
        e.play(rate: 1)
        let deadline = Date().addingTimeInterval(timeout)
        while e.currentTime < want, Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        return (e.currentTime, e.routeLabel)
    }

    /// Local file (红果 episodes after CENC decryption land here).
    func testFixtureFilePlays() async throws {
        let data = try TDLibStreamTests.fixture("player_landscape.mp4")
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("aether_fixture.mp4")
        try data.write(to: u)
        let (t, route) = try await playFor(.file(u), seconds: 1.0)
        print("AETHER file: \(route) t=\(t)")
        XCTAssertGreaterThanOrEqual(t, 1.0)
    }

    /// TDLib streaming: Aether reads through TDLibIOReader (downloadFile offset/limit), no HTTP hop.
    func testTDLibIOReaderPlays() async throws {
        let data = try TDLibStreamTests.fixture("player_landscape.mp4")
        let src = MockTDFileSource(data, block: 16_384)
        let s = try XCTUnwrap(LocalHLSProxy.shared.tdURL(TDFileRef(id: 4242, size: data.count), budget: 4 * 1_048_576, source: src, chunk: 65_536))
        defer { if let t = LocalHLSProxy.token(of: s) { LocalHLSProxy.shared.release(t) } }
        let u = try XCTUnwrap(URL(string: s))
        guard case .td? = AetherPlayerEngine.input(for: .direct(u)) else { return XCTFail("TD route not mapped to IOReader") }
        let (t, route) = try await playFor(.direct(u), seconds: 1.0)
        print("AETHER td: \(route) t=\(t) windows=\(src.requests.count)")
        XCTAssertGreaterThanOrEqual(t, 1.0)
        XCTAssertFalse(src.requests.isEmpty)
    }

    /// Network: keyless HLS goes through the loopback proxy playlist (ad-strip applies) and plays.
    func testLiveHLSThroughAdStripProxy() async throws {
        let master = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
        guard (try? await URLSession.shared.data(from: URL(string: master)!)) != nil else { throw XCTSkip("network unavailable") }
        let p = try XCTUnwrap(LocalHLSProxy.shared.playlistURL(master, headers: [:], strip: false, budget: 0))
        defer { if let t = LocalHLSProxy.token(of: p) { LocalHLSProxy.shared.release(t) } }
        let (t, route) = try await playFor(.direct(URL(string: p)!), seconds: 2)
        print("AETHER hls: \(route) t=\(t)")
        XCTAssertGreaterThanOrEqual(t, 2)
    }

    /// Network: progressive MP4 with custom headers straight from the CDN.
    func testLiveRemoteMP4WithHeaders() async throws {
        let mp4 = URL(string: "https://devstreaming-cdn.apple.com/videos/wwdc/2016/102w0bsn0ge83qfv7za/102/102_sd_platforms_state_of_the_union.mp4")!
        guard (try? await URLSession.shared.data(for: { var r = URLRequest(url: mp4); r.httpMethod = "HEAD"; return r }())) != nil else { throw XCTSkip("network unavailable") }
        let (t, route) = try await playFor(.remote(mp4, ["Referer": "https://developer.apple.com/"]), seconds: 2)
        print("AETHER remote: \(route) t=\(t)")
        XCTAssertGreaterThanOrEqual(t, 2)
    }
}
