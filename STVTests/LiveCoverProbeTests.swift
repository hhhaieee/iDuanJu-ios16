import XCTest
import UIKit
@testable import STV

/// Opt-in live probe (`TEST_RUNNER_STV_LIVE_COVERS=1`): for every source, list → first items → detail, then load
/// the list cover and the detail cover through CoverStore (same decrypt / header path as the app) and print
/// `COVER <source> …` lines. No images are saved or shown — only byte sizes / pixel sizes / errors.
final class LiveCoverProbeTests: XCTestCase {
    func load(_ url: String) async -> String {
        guard !url.isEmpty else { return "EMPTY" }
        do {
            let img = try await CoverStore.shared.image(url: url, headers: CoverHeaders.for(url: url))
            return "OK \(Int(img.size.width))x\(Int(img.size.height))"
        } catch { return "ERR \(error.localizedDescription)" }
    }
    func host(_ u: String) -> String { URL(string: u)?.host ?? (u.isEmpty ? "-" : String(u.prefix(30))) }

    @MainActor func probe(_ name: String, _ items: [HGSeries]) async {
        guard !items.isEmpty else { print("COVER \(name) list EMPTY"); return }
        for s in items.prefix(2) {
            let l = await load(s.cover)
            do {
                let d = try await Catalog.detail(s)
                let shown = DetailCover.pick(detail: d.cover, list: s.cover)
                let dl = await load(d.cover)
                let sl = shown == d.cover ? dl : await load(shown)
                print("COVER \(name) id=\(s.seriesId) list[\(host(s.cover))]=\(l) detail[\(host(d.cover))]=\(dl) shown[\(host(shown))]=\(sl) detailURL=\(d.cover.prefix(140))")
            } catch { print("COVER \(name) id=\(s.seriesId) list[\(host(s.cover))]=\(l) detail ERROR \(error.localizedDescription)") }
        }
    }

    @MainActor func testLiveCovers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_COVERS"] == "1")
        let only = ProcessInfo.processInfo.environment["STV_LIVE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ n: String) -> Bool { only == nil || only!.contains(n) }
        if want("hongguo") {
            do { await probe("hongguo", try await HongguoClient.shared.rank(sub: .hot, genre: .all).items) }
            catch { print("COVER hongguo list ERROR \(error.localizedDescription)") }
        }
        if want("huangguo") {
            var chans = [HuangguoClient.aiChannels[1], HuangguoClient.aiChannels[5], HuangguoClient.videoChannels[0]]
            if let lc = try? await HuangguoClient.shared.legacyChannels(), let f = lc.first { chans.append(f) }
            for c in chans {
                do { await probe("huangguo/\(c.sub)/\(c.slug)", try await HuangguoClient.shared.list(c, page: 1).items) }
                catch { print("COVER huangguo/\(c.sub)/\(c.slug) list ERROR \(error.localizedDescription)") }
            }
        }
        for src in Sites.all where want(src.rawValue) {
            guard let p = Sites.provider(src), let c = p.categories.first else { continue }
            do { await probe(src.rawValue, try await p.list(c, page: 1).items) }
            catch { print("COVER \(src.rawValue) list ERROR \(error.localizedDescription)") }
        }
    }
}
