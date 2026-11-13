import XCTest
import AVFoundation
@testable import STV

final class PrefetchTests: XCTestCase {
    private func units(_ n: Int, dur: Double = 6) -> [PrefetchUnit] {
        (0..<n).map { PrefetchUnit(key: "k\($0)", url: URL(string: "https://x/\($0).ts")!, range: nil, start: Double($0) * dur, duration: dur) }
    }

    func testPlannerStopsAtBudgetAndRespectsConcurrency() {
        // 10 MB budget, 2 MB estimate → at most 5 units, but only 3 slots.
        let picks = PrefetchPlanner.next(start: 0, count: 100, sizes: [:], inFlight: [], budget: 10_000_000, concurrency: 3, estimate: 2_000_000)
        XCTAssertEqual(picks, [0, 1, 2])
        // 4 cached (8 MB ahead) + nothing in flight → one more unit fills the budget.
        let sizes = [0: 2_000_000, 1: 2_000_000, 2: 2_000_000, 3: 2_000_000]
        XCTAssertEqual(PrefetchPlanner.next(start: 0, count: 100, sizes: sizes, inFlight: [], budget: 10_000_000, concurrency: 3, estimate: 2_000_000), [4])
        // Budget reached → nothing.
        XCTAssertEqual(PrefetchPlanner.next(start: 0, count: 100, sizes: sizes.merging([4: 2_000_000]) { a, _ in a }, inFlight: [],
                                            budget: 10_000_000, concurrency: 3, estimate: 2_000_000), [])
        // In-flight downloads count toward the budget and the concurrency.
        XCTAssertEqual(PrefetchPlanner.next(start: 0, count: 100, sizes: [:], inFlight: [0, 1], budget: 10_000_000, concurrency: 3, estimate: 2_000_000), [2])
    }

    func testPlannerOnlyCountsBytesAheadOfPlayheadAndSkipsFailures() {
        let sizes = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, 1_000_000) })
        // After a seek to unit 50, the 10 MB behind the playhead do not count.
        XCTAssertEqual(PrefetchPlanner.next(start: 50, count: 100, sizes: sizes, inFlight: [], budget: 3_000_000, concurrency: 3, estimate: 1_000_000), [50, 51, 52])
        XCTAssertEqual(PrefetchPlanner.next(start: 50, count: 100, sizes: [:], inFlight: [], budget: 3_000_000, concurrency: 3, estimate: 1_000_000, skip: [51]), [50, 52, 53])
        XCTAssertEqual(PrefetchPlanner.next(start: 98, count: 100, sizes: [:], inFlight: [], budget: 50_000_000, concurrency: 3, estimate: 1), [98, 99])
        XCTAssertEqual(PrefetchPlanner.next(start: 0, count: 100, sizes: [:], inFlight: [], budget: 0, concurrency: 3, estimate: 1), [])
    }

    func testStartIndexAndStatus() {
        let u = units(10)
        XCTAssertEqual(PrefetchPlanner.startIndex(u, time: 0), 0)
        XCTAssertEqual(PrefetchPlanner.startIndex(u, time: 13), 2)
        XCTAssertEqual(PrefetchPlanner.startIndex(u, time: 999), 9)
        let s = PrefetchPlanner.status(u, start: 2, sizes: [2: 5, 3: 5, 5: 5, 0: 100])
        XCTAssertEqual(s.bytes, 15)
        XCTAssertEqual(s.until, 24)   // contiguous 2,3 → 4*6
    }

    func testHLSMediaParse() {
        let pl = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        #EXTINF:5.5,
        https://cdn.example/seg1.ts?a=1
        #EXT-X-ENDLIST
        """
        let u = HLSMedia.parse(pl, base: URL(string: "https://h.example/v/index.m3u8")!)!
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[0].url.absoluteString, "https://h.example/v/seg0.ts")
        XCTAssertEqual(u[1].start, 6)
        XCTAssertEqual(u[0].key, PrefetchStore.key("https://h.example/v/seg0.ts"))
        XCTAssertNil(HLSMedia.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n", base: URL(string: "https://h/")!))
    }

    func testRangeParsingAndChunks() {
        XCTAssertEqual(LocalHLSProxy.parseRange("bytes=0-1", length: 100), 0...1)
        XCTAssertEqual(LocalHLSProxy.parseRange("bytes=10-", length: 100), 10...99)
        XCTAssertEqual(LocalHLSProxy.parseRange("bytes=-20", length: 100), 80...99)
        XCTAssertEqual(LocalHLSProxy.parseRange("bytes=90-500", length: 100), 90...99)
        XCTAssertNil(LocalHLSProxy.parseRange("bytes=200-", length: 100))
        XCTAssertEqual(LocalHLSProxy.chunks(covering: 3_000_000...5_000_000, chunk: 2_097_152), 1...2)
    }

    func testStoreLRUTrim() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        let s = PrefetchStore(root: dir)
        s.put("t", "a", Data(count: 1000)); Thread.sleep(forTimeInterval: 1.1)
        s.put("t", "b", Data(count: 1000)); Thread.sleep(forTimeInterval: 1.1)
        _ = s.get("t", "a")                           // touch: a is now newer than b
        s.put("t", "c", Data(count: 1000))
        XCTAssertEqual(s.totalBytes(), 3000)
        XCTAssertEqual(s.trim(to: 2000), 1000)
        XCTAssertNil(s.get("t", "b"), "least recently used goes first")
        XCTAssertNotNil(s.get("t", "a")); XCTAssertNotNil(s.get("t", "c"))
        s.remove("t"); XCTAssertEqual(s.totalBytes(), 0)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Real network: Apple's public bipbop HLS through the loopback proxy, prefetch until the byte budget,
    /// then a seek re-targets the prefetch. Budget = TEST_RUNNER_STV_LIVE_PREFETCH_MB (default 40).
    func testLiveAppleHLSPrefetchReachesBudget() async throws {
        let mb = Int(ProcessInfo.processInfo.environment["STV_LIVE_PREFETCH_MB"] ?? "") ?? 40
        let master = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
        let proxy = LocalHLSProxy.shared
        guard let purl = proxy.playlistURL(master, headers: [:], strip: false, budget: mb * 1_048_576),
              let tok = LocalHLSProxy.token(of: purl) else { return XCTFail("proxy did not start") }
        defer { proxy.release(tok) }
        let m: Data
        do { (m, _) = try await URLSession.shared.data(from: URL(string: purl)!) } catch { throw XCTSkip("network unavailable: \(error)") }
        // Highest-bandwidth variant (the one AVPlayer would settle on with a fast link).
        let lines = String(decoding: m, as: UTF8.self).split(separator: "\n").map(String.init)
        var best: (bw: Int, url: String)?
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
            let bw = Int(l.components(separatedBy: "BANDWIDTH=").last?.split(separator: ",").first ?? "") ?? 0
            if lines.indices.contains(i + 1), bw > (best?.bw ?? -1) { best = (bw, lines[i + 1]) }
        }
        let variant = try XCTUnwrap(best?.url)
        XCTAssertTrue(variant.hasPrefix("http://127.0.0.1"), "variant rewritten to proxy")
        let (media, _) = try await URLSession.shared.data(from: URL(string: variant)!)
        let segURLs = String(decoding: media, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("http://127.0.0.1") }
        XCTAssertGreaterThan(segURLs.count, 10)
        let t0 = Date()
        proxy.setPosition(tok, 0)
        var st = proxy.status(tok)!
        let deadline = Date().addingTimeInterval(Double(mb) * 0.6 + 40)
        while st.bytes < mb * 1_048_576, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500)); st = proxy.status(tok)!
        }
        let secs = Date().timeIntervalSince(t0)
        print("PREFETCH live: budget \(mb)MB → \(st.bytes / 1_048_576)MB ahead in \(String(format: "%.1f", secs))s, contiguous until \(Int(st.until))s")
        XCTAssertGreaterThanOrEqual(st.bytes, mb * 1_048_576, "prefetch did not reach the byte budget")
        // Not wildly over budget (concurrency 3 → at most a few segments over).
        XCTAssertLessThan(st.bytes, mb * 1_048_576 + 12 * 1_048_576)
        // The player's first segment request is now served from the disk cache, byte-identical to upstream.
        let (cached, _) = try await URLSession.shared.data(from: URL(string: segURLs[0])!)
        let upURL = URL(string: LocalHLSProxy.unb64(String(variant.split(separator: "=").last!))!)!
        let (upMedia, _) = try await URLSession.shared.data(from: upURL)
        let upstreamSeg = try XCTUnwrap(HLSMedia.parse(String(decoding: upMedia, as: UTF8.self), base: upURL)?.first)
        let (direct, _) = try await URLSession.shared.data(from: upstreamSeg.url)
        XCTAssertEqual(cached, direct)
        // Seek: prefetch restarts from the new position.
        proxy.setPosition(tok, 300)
        let d2 = Date().addingTimeInterval(60)
        repeat { try await Task.sleep(for: .milliseconds(500)); st = proxy.status(tok)! } while st.until < 330 && Date() < d2
        print("PREFETCH live: after seek to 300s → contiguous until \(Int(st.until))s, \(st.bytes / 1_048_576)MB ahead")
        XCTAssertGreaterThanOrEqual(st.until, 330)
    }

    /// AVPlayer really plays through the proxy (HLS and Range-served MP4), and MP4 prefetch fills chunks.
    func testLiveAVPlayerThroughProxyHLSAndMP4() async throws {
        let proxy = LocalHLSProxy.shared
        let hls = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
        let mp4 = "https://devstreaming-cdn.apple.com/videos/wwdc/2016/102w0bsn0ge83qfv7za/102/102_sd_platforms_state_of_the_union.mp4"
        for (kind, url) in [("hls", hls), ("mp4", mp4)] {
            let p = kind == "hls" ? proxy.playlistURL(url, headers: [:], strip: false, budget: 30 * 1_048_576)
                                  : proxy.mp4URL(url, headers: [:], budget: 30 * 1_048_576)
            let purl = try XCTUnwrap(p), tok = try XCTUnwrap(LocalHLSProxy.token(of: purl))
            defer { proxy.release(tok) }
            let player = await AVPlayer(url: URL(string: purl)!)
            await MainActor.run { player.isMuted = true; player.play() }
            let deadline = Date().addingTimeInterval(40)
            var t = 0.0
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
                t = await MainActor.run { player.currentTime().seconds }
                proxy.setPosition(tok, kind == "mp4" ? 0 : t)
                if t > 3 { break }
                if await MainActor.run(body: { player.currentItem?.status == .failed }) { break }
            }
            let err = await MainActor.run { player.currentItem?.error?.localizedDescription }
            print("PREFETCH avplayer \(kind): played \(String(format: "%.1f", t))s err=\(err ?? "nil")")
            XCTAssertGreaterThan(t, 3, "\(kind) did not play through the proxy: \(err ?? "")")
            await MainActor.run { player.pause() }
            if kind == "mp4" {
                var st = proxy.status(tok)!
                let d = Date().addingTimeInterval(60)
                while st.bytes < 30 * 1_048_576, Date() < d { try await Task.sleep(for: .milliseconds(500)); st = proxy.status(tok)! }
                print("PREFETCH mp4: \(st.bytes / 1_048_576)MB cached, chunks \(proxy.mp4Chunks(tok))")
                XCTAssertGreaterThanOrEqual(st.bytes, 30 * 1_048_576)
                // A range crossing a chunk boundary is byte-identical to the origin.
                var r1 = URLRequest(url: URL(string: purl)!); r1.setValue("bytes=2097000-2097999", forHTTPHeaderField: "Range")
                var r2 = URLRequest(url: URL(string: url)!); r2.setValue("bytes=2097000-2097999", forHTTPHeaderField: "Range")
                let (a, ra) = try await URLSession.shared.data(for: r1)
                let (b, _) = try await URLSession.shared.data(for: r2)
                XCTAssertEqual((ra as? HTTPURLResponse)?.statusCode, 206)
                XCTAssertEqual(a.count, 1000); XCTAssertEqual(a, b)
            }
        }
    }
}

/// Argus 551 / Ladon vectors checked against hongguo-open-player 3f687c5 (argus.js); placeholder IDs only.
final class HGPlayerSigningTests: XCTestCase {
    func testArgus551AndLadonVector1() throws {
        let body = Array("".utf8)
        let h = try HGPlayerSign.playbackHeaders(query: "aid=1967&device_id=dev_aaaaaaaa&iid=111", body: body,
                                                timestamp: 1700000000, argusRandom: 659662259, ladonRandom: 67305985)
        XCTAssertEqual(h["x-argus"], "8oF304qEDbfv2tmuZJhSIR1pFbZa9D3QxvEEiVNrm54Av877F40mKNw0TvKKIWEIod2TkiLHixpM/c7R/aH6SN4vNA1rmBvt6FoGwDuVmfhMF9iiybRqoTUi2RbP8uE5ALD4Ab7uj/YzTRotQ6Pcg5DHng6zlrLi8umMY06+ej6UDAUZ5SJhbxRwtrH6xnwiVN2oHb48o0UuVo+5NzLAfo7m0RTVrlv1tqexZboMHKNDJ39b8HlSahjZyJ5/ETs3dVZeoQ3MPF7vQE6qDjGksCd8")
        XCTAssertEqual(h["x-ladon"], "AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH")
        XCTAssertNil(h["x-gorgon"])
        XCTAssertNil(h["x-medusa"])
        XCTAssertNil(h["x-ss-stub"])
    }
    func testArgus551AndLadonVector2() throws {
        let body = Array("{\"video_id\":\"7683440834066271256\"}".utf8)
        let h = try HGPlayerSign.playbackHeaders(query: "aid=8662&device_id=test_device_0001&iid=test_iid_0001&version_name=7.3.9.32", body: body,
                                                timestamp: 1794360000, argusRandom: 4294967295, ladonRandom: 67305985)
        XCTAssertEqual(h["x-argus"], "8oGtly/q30zomF9jsMsfO3JH1WF7TLiPqtHvN1FuiHsrhW6sN8z+qJZZcPfczvamyDR/2qTQGr/N7GbvAj6ucmVkkmjscfFAAp2gUTcO2/wuJyg477IghAlTRVtzoWlteCii1qzMo0/1RokgXn7YLtNR2hpv5SQGpAMAy4Bb+yHqSJ8tEo+UhB08tF95IzZJPwmSbmzlawaLXKcMO+PyUmBFKRdh2GyZKD8stvwz9vcQ9wpd0Fkj+AL+mETq3iqxishDUAnU6vg/OCwEPYt/FcaopRmsXY6WoBjTwwbKu4jAmQ==")
        XCTAssertEqual(h["x-ladon"], "AQIDBN3Xttm3qfFgkTVv7tBrb9bF8APHUjBLe2ja98bNrRn+")
        XCTAssertNil(h["x-gorgon"])
        XCTAssertNil(h["x-medusa"])
        XCTAssertEqual(h["x-ss-stub"], "3B5CDED53D6FBAB1380ADF920399605E")
    }
}
