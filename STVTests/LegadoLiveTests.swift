import XCTest
@testable import STV

/// Live (`STV_LEGADO_REAL=/dir/with/source/jsons`): runs real 「阅读」 sources end to end and prints a report.
/// Sources are not part of the repo; this only checks compatibility.
final class LegadoLiveTests: XCTestCase {
    func testRealSources() throws {
        guard let dir = ProcessInfo.processInfo.environment["STV_LEGADO_REAL"] else { throw XCTSkip("live") }
        let keys = (ProcessInfo.processInfo.environment["STV_LEGADO_KEYS"] ?? "斗破苍穹,凡人修仙传").split(separator: ",").map(String.init)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
        var report: [String] = []
        for f in files {
            guard let d = FileManager.default.contents(atPath: dir + "/" + f), let s = try? LegadoSourceStore.parse(d).first else {
                report.append("\(f): 解析失败"); continue
            }
            var line = "\(f) \(s.bookSourceName): "
            do {
                var hits: [LegadoSearchItem] = []
                var usedKey = ""
                for k in keys where hits.isEmpty { hits = try LegadoClient.search(s, key: k); usedKey = k }
                line += "搜索[\(usedKey)] \(hits.count) 条"
                guard !hits.isEmpty else { report.append(line + " ✗ 无结果"); continue }
                // Some books have no chapters on the site itself: try up to three hits.
                var h = hits[0], info = LegadoBookInfo(name: "", author: "", intro: "", cover: "", kind: "", latest: "", tocURL: ""), toc: [LegadoChapter] = []
                for cand in ([hits.first { keys.contains($0.name) }].compactMap { $0 } + hits).prefix(3) {
                    h = cand
                    info = try LegadoClient.info(s, bookURL: cand.bookURL)
                    toc = try LegadoClient.toc(s, tocURL: info.tocURL, book: ["name": info.name, "bookUrl": cand.bookURL])
                    if !toc.isEmpty { break }
                }
                line += "（\(h.name)/\(h.author)）"
                line += " → 详情 \(info.name.isEmpty ? "✗空" : "✓")"
                line += " → 目录 \(toc.count) 章"
                guard let c = toc.first else { report.append(line + " ✗"); continue }
                let text = try LegadoClient.content(s, chapter: c, nextChapterURL: toc.count > 1 ? toc[1].url : nil, book: ["name": info.name, "bookUrl": h.bookURL])
                line += " → 正文 \(text.count) 字 ✓ 「\(text.prefix(24).replacingOccurrences(of: "\n", with: " "))」"
            } catch {
                line += " ✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
            report.append(line)
        }
        print("[legado-live]\n" + report.joined(separator: "\n"))
    }

    /// Same as the app's 搜书: every source at once on worker threads (STV_LEGADO_REAL + STV_LEGADO_CONCURRENT=1).
    func testConcurrentSearch() async throws {
        guard let dir = ProcessInfo.processInfo.environment["STV_LEGADO_REAL"], ProcessInfo.processInfo.environment["STV_LEGADO_CONCURRENT"] == "1" else { throw XCTSkip("live") }
        let key = (ProcessInfo.processInfo.environment["STV_LEGADO_KEYS"] ?? "斗破苍穹").components(separatedBy: ",")[0]
        let sources = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { FileManager.default.contents(atPath: dir + "/" + $0) }.flatMap { (try? LegadoSourceStore.parse($0)) ?? [] }.filter(\.supported)
        let results = await withTaskGroup(of: String.self) { tg in
            for s in sources {
                tg.addTask {
                    do { return "\(s.bookSourceName): \(try await LegadoClient.run { try LegadoClient.search(s, key: key) }.count) 条" }
                    catch { return "\(s.bookSourceName): ✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
                }
            }
            var out: [String] = []
            for await r in tg { out.append(r) }
            return out
        }
        print("[legado-concurrent]\n" + results.sorted().joined(separator: "\n"))
    }
}
