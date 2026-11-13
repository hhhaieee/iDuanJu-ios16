import Network
import XCTest
@testable import STV

/// Streaming CENC: decrypting arbitrary byte windows with `RangePlan` must give exactly the bytes the
/// whole-file `decrypt` produces.
final class CENCStreamTests: XCTestCase {
    private let key = "00112233445566778899aabbccddeeff"

    func testRangePlanMatchesWholeFileDecrypt() throws {
        let file = Self.syntheticCENC(sampleSizes: [1, 15, 16, 17, 4000, 33, 70_001, 5], subsamples: true)
        var whole = file
        XCTAssertTrue(try CENCDecryptor.decrypt(&whole, keyHex: key))

        guard case .end(let moovEnd) = CENCDecryptor.moovLocation(file) else { return XCTFail("moov") }
        let plan = try XCTUnwrap(try CENCDecryptor.rangePlan(header: Array(file.prefix(moovEnd)), keyHex: key))

        for chunk in [1, 7, 16, 1000, 65_536, file.count] {
            var out = Data()
            var at = 0
            while at < file.count {
                var d = Data(file[at..<min(file.count, at + chunk)])
                try plan.apply(&d, at: at)
                out += d
                at += chunk
            }
            XCTAssertEqual(out, Data(whole), "chunk \(chunk)")
        }
        // Random windows
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = Int.random(in: 0..<file.count, using: &rng)
            let b = Int.random(in: a..<min(file.count, a + 90_000), using: &rng) + 1
            var d = Data(file[a..<b])
            try plan.apply(&d, at: a)
            XCTAssertEqual(d, Data(whole[a..<b]))
        }
    }

    func testFullSampleEncryptionWithoutSubsamples() throws {
        let file = Self.syntheticCENC(sampleSizes: [100, 3, 48, 999], subsamples: false)
        var whole = file
        XCTAssertTrue(try CENCDecryptor.decrypt(&whole, keyHex: key))
        guard case .end(let n) = CENCDecryptor.moovLocation(file) else { return XCTFail("moov") }
        let plan = try XCTUnwrap(try CENCDecryptor.rangePlan(header: Array(file.prefix(n)), keyHex: key))
        var d = Data(file)
        try plan.apply(&d, at: 0)
        XCTAssertEqual(d, Data(whole))
    }

    func testMoovLocation() {
        let file = Self.syntheticCENC(sampleSizes: [10], subsamples: false)
        XCTAssertEqual(CENCDecryptor.moovLocation(Array(file.prefix(20))), .more)
        if case .end = CENCDecryptor.moovLocation(file) {} else { XCTFail("moov not found") }
        let tail = Self.box("ftyp", Array("isom".utf8) + [0, 0, 0, 1]) + Self.box("mdat", [1, 2, 3])
        XCTAssertEqual(CENCDecryptor.moovLocation(tail), .tail)
    }

    // MARK: - Synthetic progressive CENC file (random "ciphertext"; equivalence is all we check)

    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + Array(type.utf8) + body }
    static func full(_ type: String, flags: UInt32 = 0, _ body: [UInt8]) -> [UInt8] { box(type, be32(Int(flags)) + body) }
    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func syntheticCENC(sampleSizes: [Int], subsamples: Bool) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        func random(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) } }

        let tenc = full("tenc", [0, 0, 1, 8] + random(16))
        let sinf = box("sinf", box("frma", Array("avc1".utf8)) + full("schm", Array("cenc".utf8) + be32(0x10000))
        + box("schi", tenc))
        let encv = box("encv", [UInt8](repeating: 0, count: 78) + sinf)
        let stsd = full("stsd", be32(1) + encv)
        let stsz = full("stsz", be32(0) + be32(sampleSizes.count) + sampleSizes.flatMap { be32($0) })
        let stsc = full("stsc", be32(1) + be32(1) + be32(sampleSizes.count) + be32(1))
        var senc = be32(sampleSizes.count)
        for s in sampleSizes {
            senc += random(8)
            if subsamples {
                let clear = min(s, 5)
                senc += be16(1) + be16(clear) + be32(s - clear)
            }
        }
        let sencBox = full("senc", flags: subsamples ? 2 : 0, senc)
        func moov(_ chunkOffset: Int) -> [UInt8] {
            let stbl = box("stbl", stsd + stsz + stsc + full("stco", be32(1) + be32(chunkOffset)) + sencBox)
            let tkhd = full("tkhd", [UInt8](repeating: 0, count: 8) + be32(1) + [UInt8](repeating: 0, count: 68))
            return box("moov", box("trak", tkhd + box("mdia", box("minf", stbl))))
        }
        let ftyp = box("ftyp", Array("isom".utf8) + [0, 0, 0, 1])
        let header = ftyp + moov(0)
        let data = random(sampleSizes.reduce(0, +))
        return ftyp + moov(header.count + 8) + box("mdat", data)
    }
}

/// Network (`STV_LIVE_HG=1`): a real 红果 episode streamed through the decrypting proxy is byte-identical
/// to the whole-file decrypt, Aether plays it, and the first frame comes before the full download would.
@MainActor
final class CENCStreamLiveTests: XCTestCase {
    func testLiveHongguoStreamMatchesFullDecryptAndPlays() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_HG"] == "1")
        func since(_ d: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(d)) }
        var c = Date()
        let page = try await HongguoClient.shared.rank(sub: .hot, genre: .all)
        print("CENC-LIVE rank \(since(c))")
        let series = try XCTUnwrap(page.items.dropFirst(Int.random(in: 0..<min(10, page.items.count))).first)
        c = Date()
        let detail = try await HongguoClient.shared.detail(seriesId: series.seriesId)
        print("CENC-LIVE detail \(since(c)) sid=\(series.seriesId)")
        let ep = try XCTUnwrap(detail.episodes.first)
        c = Date()
        let r = try await HongguoClient.shared.resolve(vid: ep.vid)
        print("CENC-LIVE resolve \(since(c))")
        // Cold whole-file baseline on another episode (its CDN object not warmed by this test).
        if detail.episodes.count > 1 {
            let ep2 = detail.episodes[1]
            c = Date()
            let r2 = try await HongguoClient.shared.resolve(vid: ep2.vid)
            print("CENC-LIVE resolve2 \(since(c))")
            if let s2 = r2.streams.first(where: { $0.kind == .mp4Cenc }) {
                c = Date()
                let f = try await EpisodePlaybackLoader.playableFile(vid: ep2.vid + "-cenctest", stream: s2)
                print("CENC-LIVE coldFull \(since(c)) size=\((try? Data(contentsOf: f))?.count ?? 0)")
                try? FileManager.default.removeItem(at: f)
            }
        }
        let s = try XCTUnwrap(r.streams.first { $0.kind == .mp4Cenc }, "no CENC stream: \(r.streams.map(\.kind))")

        // Streaming: header → plan → playable through Aether.
        let t0 = Date()
 let p = try XCTUnwrap(LocalHLSProxy.shared.cencMP4URL(s.url, headers: s.headers, key: s.key, budget: 0))
        defer { if let t = LocalHLSProxy.token(of: p) { LocalHLSProxy.shared.release(t) } }
        try await LocalHLSProxy.shared.prepareCENC(p)
        let tPlan = Date().timeIntervalSince(t0)
        let e = try AetherPlayerEngine()
        defer { e.stop() }
        try await e.load(.direct(URL(string: p)!), stream: nil, start: nil, title: "hg")
        e.muted = true
 e.play(rate: 1)
        let deadline = Date().addingTimeInterval(30)
        while e.currentTime < 1.0, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let tFirst = Date().timeIntervalSince(t0)
        XCTAssertGreaterThanOrEqual(e.currentTime, 1.0, "route \(e.routeLabel)")
        e.stop()

        // Whole-file baseline (old path).
        let t1 = Date()
        let old = try await EpisodePlaybackLoader.playableFile(vid: ep.vid + "-cenctest", stream: s)
        defer { try? FileManager.default.removeItem(at: old) }
        let tOld = Date().timeIntervalSince(t1)

        let (streamed, _) = try await URLSession.shared.data(from: URL(string: p)!)
        let reference = try Data(contentsOf: old)
 XCTAssertEqual(streamed.count, reference.count)
        XCTAssertTrue(streamed == reference, "streamed bytes differ from whole-file decrypt")
 print("CENC-LIVE \(s.quality ?? "-") size=\(reference.count) plan=\(String(format: "%.2f", tPlan))s "
              + "streamPlay1s=\(String(format: "%.2f", tFirst))s fullDownloadDecrypt=\(String(format: "%.2f", tOld))s")
    }
}

/// Loopback HTTP server that replays a byte blob at a capped rate with per-request latency (Range aware),
/// to compare start-up of the two CENC paths under phone-like networks inside the simulator.
final class ThrottledServer: @unchecked Sendable {
    let data: Data
    let bytesPerSecond: Int
    let latency: TimeInterval
    private let listener: NWListener
    private let queue = DispatchQueue(label: "throttled", attributes: .concurrent)
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(data: Data, bytesPerSecond: Int, latency: TimeInterval) throws {
        self.data = data; self.bytesPerSecond = bytesPerSecond; self.latency = latency
 listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
 listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] d, _, _, _ in
     let head = String(decoding: d ?? Data(), as: UTF8.self)
     let range = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
         .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
     let r = LocalHLSProxy.parseRange(range, length: data.count) ?? 0...(data.count - 1)
     var out = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: video/mp4\r\n"
     out += "Accept-Ranges: bytes\r\nContent-Length: \(r.count)\r\n"
     if range != nil { out += "Content-Range: bytes \(r.lowerBound)-\(r.upperBound)/\(data.count)\r\n" }
            out += "Connection: close\r\n\r\n"
     queue.asyncAfter(deadline: .now() + latency) { [self] in
  c.send(content: Data(out.utf8), completion: .contentProcessed { _ in })
         send(c, from: r.lowerBound, to: r.upperBound + 1)
            }
        }
    }

    /// 50 ms slices at the configured rate.
    private func send(_ c: NWConnection, from: Int, to: Int) {
 guard from < to else { c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let n = min(to - from, max(1, bytesPerSecond / 20))
        c.send(content: data.subdata(in: from..<(from + n)), completion: .contentProcessed { [self] err in
     if err != nil { c.cancel(); return }
     queue.asyncAfter(deadline: .now() + 0.05) { self.send(c, from: from + n, to: to) }
        })
    }
}

/// Network once (`STV_LIVE_HG=1`) to fetch a real encrypted episode, then both paths replayed through
/// `ThrottledServer`: time to the first playable second, old (download all → decrypt) vs streaming.
@MainActor
final class CENCThrottledStartupTests: XCTestCase {
    func testStartupUnderPhoneNetworks() async throws {
 try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_HG"] == "1")
 let page = try await HongguoClient.shared.rank(sub: .hot, genre: .all)
        let series = try XCTUnwrap(page.items.first)
 let detail = try await HongguoClient.shared.detail(seriesId: series.seriesId)
        let ep = try XCTUnwrap(detail.episodes.first)
        let r = try await HongguoClient.shared.resolve(vid: ep.vid)
        let s = try XCTUnwrap(r.streams.first { $0.kind == .mp4Cenc })
        var req = URLRequest(url: URL(string: s.url)!)
        req.allHTTPHeaderFields = s.headers
 let (blob, _) = try await URLSession.shared.data(for: req)
        print("THROTTLE episode \(s.quality ?? "-") \(blob.count / 1024) KB")

 // (label, bytes/s, latency per request)
        let profiles: [(String, Int, Double)] = [("4G 2MB/s", 2_000_000, 0.08), ("弱4G 500KB/s", 500_000, 0.15), ("3G 150KB/s", 150_000, 0.3)]
        for (label, bps, lat) in profiles {
     let server = try ThrottledServer(data: blob, bytesPerSecond: bps, latency: lat)
            var stream = s
            stream.url = "http://127.0.0.1:\(server.port)/ep.mp4"
            stream.backupURL = nil
     stream.streamId = "throttle-\(bps)-\(UUID().uuidString.prefix(6))"

     // Old: whole download + decrypt, then Aether to first second.
     var t = Date()
     let file = try await EpisodePlaybackLoader.playableFile(vid: ep.vid, stream: stream)
     let oldPlay = try await firstSecond(.file(file))
     let oldTotal = Date().timeIntervalSince(t)
     try? FileManager.default.removeItem(at: file)

     // New: header → plan → Aether through the decrypting proxy.
     t = Date()
     let p = try XCTUnwrap(LocalHLSProxy.shared.cencMP4URL(stream.url, headers: [:], key: s.key, budget: PlaybackCoordinator.cencBudget))
     try await LocalHLSProxy.shared.prepareCENC(p)
     let newPlay = try await firstSecond(.direct(URL(string: p)!))
     let newTotal = Date().timeIntervalSince(t)
     if let tok = LocalHLSProxy.token(of: p) { LocalHLSProxy.shared.release(tok) }

     print(String(format: "THROTTLE %@ old=%.2fs (play %.2fs) stream=%.2fs (play %.2fs)", label, oldTotal, oldPlay, newTotal, newPlay))
        }
    }

    /// Seconds from load to 1 s of decoded playback.
    private func firstSecond(_ src: PlaybackCoordinator.Source) async throws -> Double {
        let t = Date()
        let e = try AetherPlayerEngine()
        defer { e.stop() }
        try await e.load(src, stream: nil, start: nil, title: "t")
        e.muted = true
        e.play(rate: 1)
        let deadline = Date().addingTimeInterval(60)
 while e.currentTime < 1.0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(e.currentTime, 1.0)
        return Date().timeIntervalSince(t)
    }
}
