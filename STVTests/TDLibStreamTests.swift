import XCTest
import AVFoundation
@testable import STV

/// Behaves like TDLib for one file: one download window at a time (a new offset/limit re-targets it),
/// parts already downloaded stay, `readFilePart` only returns downloaded bytes, cancel keeps the parts.
final class MockTDFileSource: TDFileStreamSource, @unchecked Sendable {
    let data: Data
    let block: Int
    let delayNanos: UInt64
    private let lock = NSLock()
    private var have: [Bool]
    private var window: (offset: Int, limit: Int)?
    private var generation = 0
    private(set) var cancels = 0
    private(set) var requestLog: [(offset: Int, limit: Int, priority: Int)] = []

    init(_ data: Data, block: Int = 4096, delayNanos: UInt64 = 0) {
        self.data = data; self.block = block; self.delayNanos = delayNanos
        have = Array(repeating: false, count: (data.count + block - 1) / block)
    }

    func downloadedBlocks(in r: Range<Int>) -> Int { lock.withLock { r.filter { have.indices.contains($0 / block) && have[$0 / block] }.count / block } }
    func isDownloaded(byte o: Int) -> Bool { lock.withLock { have[o / block] } }
    var requests: [(offset: Int, limit: Int, priority: Int)] { lock.withLock { requestLog } }
    var cancelCount: Int { lock.withLock { cancels } }

    func fileState(_ id: Int32) async throws -> TDFileState {
        TDFileState(size: data.count, expectedSize: data.count, completed: lock.withLock { have.allSatisfy { $0 } }, path: "")
    }

    func requestDownload(_ id: Int32, offset: Int, limit: Int, priority: Int) async throws {
        let gen: Int = lock.withLock {
            window = (offset, limit); requestLog.append((offset, limit, priority)); generation += 1; return generation
        }
        Task.detached { [self] in
            let end = limit == 0 ? data.count : min(data.count, offset + limit)
            var b = offset / block
            while b * block < end {
                if lock.withLock({ generation != gen }) { return }
                if delayNanos > 0, !lock.withLock({ have[b] }) { try? await Task.sleep(nanoseconds: delayNanos) }
                guard lock.withLock({ () -> Bool in guard generation == gen else { return false }; have[b] = true; return true }) else { return }
                b += 1
            }
        }
    }

    func downloadedPrefix(_ id: Int32, offset: Int) async throws -> Int {
        lock.withLock {
            var b = offset / block
            guard b < have.count, have[b] else { return 0 }
            while b < have.count, have[b] { b += 1 }
            return min(data.count, b * block) - offset
        }
    }

    func readPart(_ id: Int32, offset: Int, count: Int) async throws -> Data {
        let end = min(data.count, offset + count)
        let ok = lock.withLock { (offset / block...(max(offset, end - 1)) / block).allSatisfy { have[$0] } }
        guard ok else { throw NSError(domain: "td", code: 400, userInfo: [NSLocalizedDescriptionKey: "not downloaded"]) }
        return data.subdata(in: offset..<end)
    }

    func cancelDownload(_ id: Int32) async { lock.withLock { cancels += 1; generation += 1; window = nil } }
}

final class TDLibStreamTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name))
    }

    private var fileId: Int32 = 0
    private func serve(_ src: MockTDFileSource, chunk: Int = 16_384, budget: Int = 0, mime: String = "video/mp4",
                       proxy: LocalHLSProxy) throws -> URL {
        fileId = Int32.random(in: 100_000...9_000_000)
        let s = try XCTUnwrap(proxy.tdURL(TDFileRef(id: fileId, mime: mime), budget: budget, source: src, chunk: chunk))
        XCTAssertTrue(s.hasSuffix("/tg/\(fileId).mp4"), s)
        return try XCTUnwrap(URL(string: s))
    }

    private func get(_ u: URL, _ range: String?) async throws -> (HTTPURLResponse, Data) {
        var r = URLRequest(url: u); r.timeoutInterval = 20
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        let (d, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        return (try XCTUnwrap(resp as? HTTPURLResponse), d)
    }

    func testRefParsing() {
        XCTAssertEqual(TDFileRef("tdfile://123")?.id, 123)
        XCTAssertEqual(TDFileRef("tdfile://123")?.mime, "video/mp4")
        let r = TDFileRef(id: 77, mime: "video/quicktime", streaming: false, size: 12345)
        XCTAssertEqual(TDFileRef(r.string), r)
        XCTAssertNil(TDFileRef("https://cdn.example/v.mp4"))
        XCTAssertEqual(LocalHLSProxy.token(of: "http://127.0.0.1:5000/tg/77"), "tg-77")
        XCTAssertEqual(LocalHLSProxy.token(of: "http://127.0.0.1:5000/tg/77.mp4"), "tg-77")
        XCTAssertEqual(LocalHLSProxy.token(of: "http://127.0.0.1:5000/abcd/v.mp4?u=x"), "abcd")
    }

    /// AVPlayer's probe (bytes=0-1) and a full GET: status, headers and bytes.
    func testHeadProbeAndFullBody() async throws {
        let data = try Self.fixture("player_landscape.mp4")
        let proxy = LocalHLSProxy(), src = MockTDFileSource(data)
        let u = try serve(src, mime: "video/mp4", proxy: proxy)
        let (h, d) = try await get(u, "bytes=0-1")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1/\(data.count)")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Length"), "2")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(h.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(d, data.prefix(2))
        XCTAssertEqual(src.requests.first?.priority, 32)
        let (h2, all) = try await get(u, nil)
        XCTAssertEqual(h2.statusCode, 200)
        XCTAssertEqual(all, data)
    }

    /// moov at the end: AVPlayer asks for the tail first — only the tail is downloaded, bytes are exact.
    func testTailRequestDownloadsOnlyTheTail() async throws {
        let data = try Self.fixture("player_tail_moov.mp4")
        let moov = try XCTUnwrap(data.range(of: Data("moov".utf8))).lowerBound - 4
        XCTAssertGreaterThan(moov, data.count / 2, "fixture must keep moov at the end")
        let proxy = LocalHLSProxy(), src = MockTDFileSource(data)
        let u = try serve(src, proxy: proxy)
        let (h, d) = try await get(u, "bytes=\(moov)-")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Range"), "bytes \(moov)-\(data.count - 1)/\(data.count)")
        XCTAssertEqual(d, data.subdata(in: moov..<data.count))
        XCTAssertEqual(src.requests.first?.offset, moov)
        XCTAssertFalse(src.isDownloaded(byte: 0), "head must not be downloaded for a tail request")
        // Suffix form too.
        let (h3, s3) = try await get(u, "bytes=-500")
        XCTAssertEqual(h3.value(forHTTPHeaderField: "Content-Range"), "bytes \(data.count - 500)-\(data.count - 1)/\(data.count)")
        XCTAssertEqual(s3, data.suffix(500))
        let (h4, _) = try await get(u, "bytes=\(data.count + 10)-")
        XCTAssertEqual(h4.statusCode, 416)
    }

    /// A range across several proxy chunks (and TDLib blocks) with a slow download.
    func testRangeAcrossChunks() async throws {
        let data = try Self.fixture("player_landscape.mp4")
        let proxy = LocalHLSProxy(), src = MockTDFileSource(data, block: 4096, delayNanos: 300_000)
        let u = try serve(src, chunk: 16_384, proxy: proxy)
        let (h, d) = try await get(u, "bytes=10000-70000")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Length"), "60001")
        XCTAssertEqual(d, data.subdata(in: 10000..<70001))
    }

    /// Seeking: the old request hangs up, the new offset re-targets TDLib's window immediately.
    func testSeekRetargetsDownloadWindow() async throws {
        let data = try Self.fixture("player_landscape.mp4")   // ~387 KB, 4 KB blocks at 15 ms → ~1.4 s whole
        let proxy = LocalHLSProxy(), src = MockTDFileSource(data, block: 4096, delayNanos: 15_000_000)
        let u = try serve(src, chunk: 16_384, budget: 32_768, proxy: proxy)
        var r = URLRequest(url: u); r.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let first = URLSession(configuration: .ephemeral).dataTask(with: r)
        first.resume()
        try await Task.sleep(nanoseconds: 150_000_000)
        first.cancel()                                           // AVPlayer drops the old connection on seek
        let target = Int(Double(data.count) * 0.7)
        let t0 = Date()
        let (h, d) = try await get(u, "bytes=\(target)-\(target + 9999)")
        XCTAssertEqual(h.statusCode, 206)
        XCTAssertEqual(d, data.subdata(in: target..<(target + 10000)))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "seek target must not wait for the bytes before it")
        XCTAssertTrue(src.requests.contains { $0.offset == target }, "\(src.requests.map(\.offset))")
        XCTAssertFalse(src.isDownloaded(byte: target - 60_000), "bytes between the old and new position are skipped")
        // Coordinator-side seek (scrub before AVPlayer asks) also moves the window.
        let td = try XCTUnwrap(proxy.tdSession("tg-\(fileId)"))
        try await Task.sleep(nanoseconds: 100_000_000)
        await td.seek(fraction: 0.25)
        let aligned = (Int(Double(data.count) * 0.25) / td.chunk) * td.chunk
        XCTAssertEqual(src.requests.last?.offset, aligned)
        let b = await td.buffered(from: 0.7)
        XCTAssertNotNil(b); XCTAssertGreaterThanOrEqual(b?.bytes ?? 0, 10_000)
    }

    /// Leaving the player cancels TDLib's download but keeps what was downloaded;
    /// a user 「下载」 of the same file is left alone.
    func testReleaseCancelsButKeepsParts() async throws {
        let data = try Self.fixture("player_landscape.mp4")
        let proxy = LocalHLSProxy(), src = MockTDFileSource(data)
        let u = try serve(src, proxy: proxy)
        _ = try await get(u, "bytes=0-9999")
        proxy.release("tg-\(fileId)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(src.cancelCount, 1)
        XCTAssertTrue(src.isDownloaded(byte: 0))
        let (h, _) = try await get(u, "bytes=0-1")
        XCTAssertEqual(h.statusCode, 404, "route is gone after release")

        let u2 = try serve(src, proxy: proxy)
        TDFullDownloads.shared.begin(fileId)
        defer { TDFullDownloads.shared.end(fileId) }
        let before = src.requests.count
        _ = try await get(u2, "bytes=200000-200100")
        XCTAssertEqual(src.requests.count, before, "a full user download must not be re-targeted")
        proxy.release("tg-\(fileId)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(src.cancelCount, 1, "a full user download must not be cancelled")
    }

    /// End to end: AVPlayer plays a moov-at-end MP4 through the proxy while it "downloads", and seeks.
    @MainActor func testAVPlayerStreamsAndSeeks() async throws {
        for (name, seekTo) in [("player_tail_moov.mp4", 14.0), ("player_landscape.mp4", 42.0)] {
            let data = try Self.fixture(name)
            let proxy = LocalHLSProxy(), src = MockTDFileSource(data, block: 8192, delayNanos: 2_000_000)
            let u = try serve(src, chunk: 65_536, budget: 131_072, proxy: proxy)
            let item = AVPlayerItem(asset: AVURLAsset(url: u))
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let deadline = Date().addingTimeInterval(20)
            while item.status == .unknown, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertEqual(item.status, .readyToPlay, "\(name): \(String(describing: item.error))")
            let dur = try await item.asset.load(.duration).seconds
            XCTAssertGreaterThan(dur, seekTo + 2, name)
            await player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            while player.currentTime().seconds < seekTo + 0.5, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, seekTo + 0.5, "\(name) did not play after seek")
            player.pause()
            XCTAssertLessThan(src.requests.count, 200)
            proxy.release("tg-\(fileId)")
        }
    }
}
