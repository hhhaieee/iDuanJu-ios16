import XCTest
@testable import STV

final class PlayerEngineTests: XCTestCase {
    private func session(_ data: Data) -> (TDStreamSession, MockTDFileSource) {
        let src = MockTDFileSource(data, block: 4096)
        let s = TDStreamSession(ref: TDFileRef(id: 7, size: data.count), source: src, chunk: 16_384, readAhead: 65_536)
        s.pollNanos = 2_000_000
        return (s, src)
    }

    private func bytes(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    func testTDLibIOReaderReadSeekSizeEOF() {
        let data = bytes(200_000)
        let (s, _) = session(data)
        let r = TDLibIOReader(session: s)
        XCTAssertEqual(r.seek(offset: 0, whence: TDLibIOReader.AVSEEK_SIZE), Int64(data.count))
        var buf = [UInt8](repeating: 0, count: 10_000)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 10_000) }
        XCTAssertEqual(n, 10_000)
        XCTAssertEqual(Data(buf), data.prefix(10_000))
        // SEEK_CUR / SEEK_SET / SEEK_END
        XCTAssertEqual(r.seek(offset: 5, whence: 1), 10_005)
        XCTAssertEqual(r.seek(offset: 150_000, whence: 0), 150_000)
        let m = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 4_000) }
        XCTAssertEqual(m, 4_000)
        XCTAssertEqual(Data(buf.prefix(4_000)), data.subdata(in: 150_000..<154_000))
        XCTAssertEqual(r.seek(offset: -100, whence: 2), Int64(data.count - 100))
        let tail = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 4_000) }
        XCTAssertEqual(tail, 100)                                  // clipped at EOF
        XCTAssertEqual(buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 10) }, 0)   // EOF
        XCTAssertEqual(r.seek(offset: -1, whence: 0), -1)
        XCTAssertNil(r.makeIndependentReader())
    }

    func testTDLibIOReaderRetargetsTDLibWindow() {
        let data = bytes(400_000)
        let (s, src) = session(data)
        let r = TDLibIOReader(session: s)
        _ = r.seek(offset: 300_000, whence: 0)
        var buf = [UInt8](repeating: 0, count: 1_000)
        XCTAssertEqual(buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 1_000) }, 1_000)
        XCTAssertTrue(src.requests.contains { $0.offset == 300_000 }, "\(src.requests)")
        XCTAssertEqual(Data(buf), data.subdata(in: 300_000..<301_000))
    }

    func testAetherInputRouting() throws {
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        guard case .url(let u, _, false)? = AetherPlayerEngine.input(for: .file(file)) else { return XCTFail() }
        XCTAssertEqual(u, file)
        let remote = URL(string: "https://cdn.example.com/v.mp4")!
        guard case .url(_, let h, false)? = AetherPlayerEngine.input(for: .remote(remote, ["Referer": "https://x/"])) else { return XCTFail() }
        XCTAssertEqual(h["Referer"], "https://x/")
        // Loopback HLS (ad-stripped playlist) → native HLS path.
        let pl = URL(string: "http://127.0.0.1:5000/abcd/p.m3u8")!
        guard case .url(_, _, true)? = AetherPlayerEngine.input(for: .direct(pl)) else { return XCTFail() }
        // TDLib route → IOReader when the proxy knows the session, else unsupported (AVPlayer keeps the proxy).
        let tg = URL(string: "http://127.0.0.1:5000/tok1/tg/v.mp4")!
        let (sess, _) = session(bytes(10))
        if LocalHLSProxy.token(of: tg.absoluteString) != nil {
            guard case .td? = AetherPlayerEngine.input(for: .direct(tg), tdSession: { _ in sess }) else { return XCTFail() }
        }
        // Resource-loader AES / custom playlists stay on AVPlayer.
        XCTAssertNil(AetherPlayerEngine.input(for: .stream(HLSPlayback(headers: [:], keyHex: "00ff"), "https://x/v.mp4")))
        XCTAssertNil(AetherPlayerEngine.input(for: .stream(HLSPlayback(headers: [:], keyHex: ""), "https://x/index.m3u8")))
        guard case .url? = AetherPlayerEngine.input(for: .stream(HLSPlayback(headers: ["Referer": "r"], keyHex: ""), "https://x/v.mp4")) else { return XCTFail() }
    }

    func testHeadersAddUserAgentNotForLoopback() {
        let h = AetherPlayerEngine.headers(["Referer": "r"], for: URL(string: "https://cdn.example.com/a.mp4")!)
        XCTAssertEqual(h["Referer"], "r")
        XCTAssertNotNil(h["User-Agent"])
        let l = AetherPlayerEngine.headers([:], for: URL(string: "http://127.0.0.1:1/a.mp4")!)
        XCTAssertNil(l["Cookie"])
    }

    func testLabels() {
        XCTAssertEqual(AetherPlayerEngine.codecLabel("hevc"), "HEVC")
        XCTAssertEqual(AetherPlayerEngine.codecLabel("h264"), "H.264")
        XCTAssertEqual(AetherPlayerEngine.codecLabel("av1"), "AV1")
        XCTAssertEqual(AetherPlayerEngine.codecLabel(nil), "")
        XCTAssertEqual(PlayerTech.audioName(codec: "eac3", channels: 6), "E-AC3 5.1")
        XCTAssertEqual(PlayerTech.channelLabel(2), "2.0")
        XCTAssertEqual(MediaTrack.title(name: "UND (aac)", language: "und", codec: "aac", channels: 2, index: 0), "轨道 1 · AAC 2.0")
        XCTAssertEqual(MediaTrack.title(name: "Director Commentary", language: "und", codec: "", channels: 0, index: 1), "Director Commentary")
        XCTAssertTrue(MediaTrack.title(name: "", language: "jpn", codec: "aac", channels: 6, index: 1).hasSuffix("AAC 5.1"))
    }

    func testEngineSettingDefaultsToAether() {
        let d = UserDefaults.standard
        let old = d.object(forKey: PlayerEngineSettings.key)
        defer { d.set(old, forKey: PlayerEngineSettings.key) }
        d.removeObject(forKey: PlayerEngineSettings.key)
        XCTAssertEqual(PlayerEngineSettings.preferred, ProcessInfo.processInfo.environment["STV_ENGINE"] == "avplayer" ? .avplayer : .aether)
    }
}
