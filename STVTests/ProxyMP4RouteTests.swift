import XCTest
import AVFoundation
@testable import STV

/// The web-MP4 route (`/<token>/v.mp4?u=`) that Telegram public-channel videos play through.
/// Upstream is a second loopback proxy serving a fake file source over real HTTP with Range support,
/// so every byte, header and status is exercised end to end without the network.
final class ProxyMP4RouteTests: XCTestCase {
    private var upstreamProxy = LocalHLSProxy()

    /// Real HTTP upstream with Range/206 (a `/tg/<id>.mp4` route over a fake TDLib source).
    private func upstream(_ data: Data) throws -> String {
        let id = Int32.random(in: 100_000...9_000_000)
        return try XCTUnwrap(upstreamProxy.tdURL(TDFileRef(id: id), budget: 0, source: MockTDFileSource(data, block: 65_536), chunk: 262_144))
    }

    private func get(_ u: URL, _ range: String?) async throws -> (HTTPURLResponse, Data) {
        var r = URLRequest(url: u); r.timeoutInterval = 30
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        let (d, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        return (try XCTUnwrap(resp as? HTTPURLResponse), d)
    }

    /// Deterministic bytes larger than two proxy chunks (BufferSettings.mp4Chunk = 2 MB).
    private func blob(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }) }

    func testProbeHeadersAndRanges() async throws {
        let data = blob(5 * 1_048_576 + 12_345)
        let proxy = LocalHLSProxy()
        let s = try XCTUnwrap(proxy.mp4URL(try upstream(data), headers: [:], budget: 0))
        XCTAssertTrue(s.contains("/v.mp4?u="), s)
        let u = try XCTUnwrap(URL(string: s))

        // AVPlayer's first request: bytes=0-1 must be a 206, never a 200.
        let (h, d) = try await get(u, "bytes=0-1")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1/\(data.count)")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Length"), "2")
        XCTAssertEqual(d, data.prefix(2))

        // Open-ended range spanning all chunks.
        let (h2, all) = try await get(u, "bytes=0-")
        XCTAssertEqual(h2.statusCode, 206)
        XCTAssertEqual(h2.value(forHTTPHeaderField: "Content-Length"), "\(data.count)")
        XCTAssertEqual(all, data)

        // Across a chunk boundary.
        let lo = 2 * 1_048_576 - 100, hi = 2 * 1_048_576 + 100
        let (h3, mid) = try await get(u, "bytes=\(lo)-\(hi)")
        XCTAssertEqual(h3.statusCode, 206)
        XCTAssertEqual(h3.value(forHTTPHeaderField: "Content-Range"), "bytes \(lo)-\(hi)/\(data.count)")
        XCTAssertEqual(mid, data.subdata(in: lo..<(hi + 1)))

        // Suffix (moov-at-end probe).
        let (h4, tail) = try await get(u, "bytes=-1000")
        XCTAssertEqual(h4.statusCode, 206)
        XCTAssertEqual(tail, data.suffix(1000))

        // No Range → 200 with the whole file.
        let (h5, full) = try await get(u, nil)
        XCTAssertEqual(h5.statusCode, 200)
        XCTAssertEqual(full.count, data.count)

        // Past the end → 416 with the total.
        let (h6, _) = try await get(u, "bytes=\(data.count)-")
        XCTAssertEqual(h6.statusCode, 416)
        XCTAssertEqual(h6.value(forHTTPHeaderField: "Content-Range"), "bytes */\(data.count)")
    }

    /// Prefetch budget on: same bytes come back through the pre-buffer path.
    func testRangesThroughPrefetcher() async throws {
        let data = blob(3 * 1_048_576 + 7)
        let proxy = LocalHLSProxy()
        let s = try XCTUnwrap(proxy.mp4URL(try upstream(data), headers: [:], budget: 8 * 1_048_576))
        let u = try XCTUnwrap(URL(string: s))
        let (_, probe) = try await get(u, "bytes=0-1")
        XCTAssertEqual(probe, data.prefix(2))
        let (h, all) = try await get(u, "bytes=0-")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(all, data)
        if let tok = LocalHLSProxy.token(of: s) { proxy.release(tok) }
    }

    /// Unreachable upstream: a clean 502 (never a 206 header followed by an error body).
    func testDeadUpstreamIsClean502() async throws {
        let proxy = LocalHLSProxy()
        let s = try XCTUnwrap(proxy.mp4URL("http://127.0.0.1:9/gone.mp4", headers: [:], budget: 0))
        let (h, _) = try await get(try XCTUnwrap(URL(string: s)), "bytes=0-1")
        XCTAssertEqual(h.statusCode, 502)
        XCTAssertNil(h.value(forHTTPHeaderField: "Content-Range"))
    }

    /// AVPlayer opens a real MP4 through the web route; a dead upstream reproduces the device error
    /// (NSURLErrorDomain -1008 "resource unavailable") — the case the coordinator now falls back from.
    @MainActor func testAVPlayerThroughWebRouteAndDeviceError() async throws {
        let data = try TDLibStreamTests.fixture("player_landscape.mp4")
        let proxy = LocalHLSProxy()
        let s = try XCTUnwrap(proxy.mp4URL(try upstream(data), headers: [:], budget: 0))
        let ok = try XCTUnwrap(PlaybackCoordinator.makeItem(.direct(try XCTUnwrap(URL(string: s)))))
        let player = AVPlayer(playerItem: ok); player.isMuted = true
        var deadline = Date().addingTimeInterval(20)
        while ok.status == .unknown, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(ok.status, .readyToPlay, String(describing: ok.error))

        let dead = try XCTUnwrap(proxy.mp4URL("http://127.0.0.1:9/gone.mp4", headers: [:], budget: 0))
        let bad = try XCTUnwrap(PlaybackCoordinator.makeItem(.direct(try XCTUnwrap(URL(string: dead)))))
        player.replaceCurrentItem(with: bad)
        deadline = Date().addingTimeInterval(20)
        while bad.status == .unknown, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(bad.status, .failed)
        let e = bad.error as NSError?
        XCTAssertEqual(e?.domain, NSURLErrorDomain)
        XCTAssertEqual(e?.code, NSURLErrorResourceUnavailable)
        XCTAssertTrue(PlaybackCoordinator.failureText(bad.error).contains("-1008"))
    }

    @MainActor func testBypassRulesAndMime() {
        let proxied = PlaybackCoordinator.Source.direct(URL(string: "http://127.0.0.1:5000/abcd/v.mp4?u=x")!)
        let web = HGStream(url: "https://cdn4.telesco.pe/file/x.mp4?token=t", key: "", kind: .mp4Clear)
        let td = HGStream(url: "tdfile://77", key: "", kind: .mp4Clear)
        XCTAssertTrue(PlaybackCoordinator.canBypassProxy(proxied, stream: web))
        XCTAssertFalse(PlaybackCoordinator.canBypassProxy(proxied, stream: td))     // no CDN URL to fall back to
        XCTAssertFalse(PlaybackCoordinator.canBypassProxy(.remote(URL(string: web.url)!, [:]), stream: web))
        XCTAssertEqual(TDStreamSession.playableMime("application/octet-stream"), "video/mp4")
        XCTAssertEqual(TDStreamSession.playableMime(""), "video/mp4")
        XCTAssertEqual(TDStreamSession.playableMime("video/webm"), "video/mp4")
        XCTAssertEqual(TDStreamSession.playableMime("video/quicktime"), "video/quicktime")
    }
}
