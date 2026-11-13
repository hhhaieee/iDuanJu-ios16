import Foundation

/// Byte-budget pre-buffering for long-video (adult) sources.
/// AVPlayer's `preferredForwardBufferDuration` is time-based and capped by the system, so we pre-download
/// on our side instead: the loopback proxy (`LocalHLSProxy`) serves HLS segments / MP4 ranges from a disk
/// cache and a per-stream prefetcher fills that cache ahead of the playhead until the configured bytes.
enum BufferSettings {
    static let options = [0, 200, 500, 750, 1000]
    static let key = "stv.buffer.longVideoMB"
    /// Long-video sources default to 500 MB. 短剧 keep the existing 3–4 episode warm-up instead.
    static var megabytes: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? 500 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func budget(for source: DramaSource) -> Int { source.isLongVideo ? megabytes * 1_048_576 : 0 }
    static func label(_ mb: Int) -> String { mb == 0 ? "关" : "\(mb)MB" }
    /// Total on-disk cap across streams (LRU), and the free-space floor below which we stop and purge.
    static let cacheCap: Int64 = 2 * 1_073_741_824
    static let lowStorage: Int64 = 1_073_741_824
    static let concurrency = 3
    static let mp4Chunk = 2 * 1_048_576
}

/// One prefetchable unit: an HLS media segment, or a fixed-size byte chunk of an MP4.
struct PrefetchUnit: Hashable {
    let key: String
    let url: URL
    /// Byte range for MP4 chunks (inclusive); nil for whole HLS segments.
    let range: ClosedRange<Int>?
    let start: Double
    let duration: Double
}

enum HLSMedia {
    /// Media-playlist segments (absolute URLs) with start times; nil for a master playlist.
    static func parse(_ text: String, base: URL) -> [PrefetchUnit]? {
        var out: [PrefetchUnit] = [], pending: Double?, t = 0.0
        var byteRange: (len: Int, off: Int?)?, lastEnd: [String: Int] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            } else if line.uppercased().hasPrefix("#EXT-X-BYTERANGE:") {
                let p = line.dropFirst(17).split(separator: "@")
                if let len = Int(p[0]) { byteRange = (len, p.count > 1 ? Int(p[1]) : nil) }
            } else if !line.isEmpty, !line.hasPrefix("#"), let d = pending,
                      let u = URL(string: line, relativeTo: base)?.absoluteURL {
                var range: ClosedRange<Int>?
                if let br = byteRange {
                    let off = br.off ?? lastEnd[u.absoluteString] ?? 0
                    range = off...(off + br.len - 1); lastEnd[u.absoluteString] = off + br.len
                }
                out.append(PrefetchUnit(key: PrefetchStore.key(u.absoluteString + (range.map { "#\($0.lowerBound)-\($0.upperBound)" } ?? "")),
                                        url: u, range: range, start: t, duration: d))
                t += d; pending = nil; byteRange = nil
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Pure scheduling: which units to fetch next so the bytes *ahead of the playhead* reach the budget.
enum PrefetchPlanner {
    static func startIndex(_ units: [PrefetchUnit], time: Double) -> Int {
        guard !units.isEmpty else { return 0 }
        if let i = units.lastIndex(where: { $0.start <= time + 0.001 }) { return i }
        return 0
    }

    /// - sizes: bytes of units already cached (by index). inFlight: indices being downloaded.
    /// - estimate: expected bytes for a unit not yet seen (average of known sizes, or a default).
    static func next(start: Int, count: Int, sizes: [Int: Int], inFlight: Set<Int>,
                     budget: Int, concurrency: Int, estimate: Int, skip: Set<Int> = []) -> [Int] {
        guard budget > 0, start < count else { return [] }
        var ahead = sizes.filter { $0.key >= start }.reduce(0) { $0 + $1.value }
        ahead += inFlight.filter { $0 >= start }.count * max(1, estimate)
        var slots = concurrency - inFlight.count
        var picks: [Int] = []
        var i = start
        while i < count, slots > 0, ahead < budget {
            if sizes[i] == nil, !inFlight.contains(i), !skip.contains(i) {
                picks.append(i); slots -= 1; ahead += max(1, estimate)
            }
            i += 1
        }
        return picks
    }

    /// Bytes cached at/after `start`, and the playback time reached by the contiguous cached run.
    static func status(_ units: [PrefetchUnit], start: Int, sizes: [Int: Int]) -> (bytes: Int, until: Double) {
        let bytes = sizes.filter { $0.key >= start }.reduce(0) { $0 + $1.value }
        var until = units.indices.contains(start) ? units[start].start : 0
        var i = start
        while units.indices.contains(i), sizes[i] != nil { until = units[i].start + units[i].duration; i += 1 }
        return (bytes, until)
    }
}

/// Disk cache: Caches/stv-prefetch/<token>/<key>. LRU by modification date across all streams.
final class PrefetchStore: @unchecked Sendable {
    static let shared = PrefetchStore()
    let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    init(root: URL? = nil) {
        self.root = root ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stv-prefetch", isDirectory: true)
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    static func key(_ s: String) -> String {
        // FNV-1a 64 — stable, filename-safe.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private func file(_ token: String, _ key: String) -> URL { root.appendingPathComponent(token).appendingPathComponent(key) }

    func get(_ token: String, _ key: String) -> Data? {
        let f = file(token, key)
        guard let d = try? Data(contentsOf: f) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return d
    }

    func put(_ token: String, _ key: String, _ data: Data) {
        let dir = root.appendingPathComponent(token)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file(token, key), options: .atomic)
    }

    func remove(_ token: String) { try? fm.removeItem(at: root.appendingPathComponent(token)) }

    func clearAll() {
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func files() -> [(url: URL, size: Int64, date: Date)] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var out: [(URL, Int64, Date)] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            out.append((u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    func totalBytes() -> Int64 { files().reduce(0) { $0 + $1.size } }

    /// Least-recently-used files go first until the total is under `cap`. Returns bytes removed.
    @discardableResult func trim(to cap: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > cap else { return 0 }
        all.sort { $0.date < $1.date }
        var removed: Int64 = 0
        for f in all where total > cap {
            try? fm.removeItem(at: f.url); total -= f.size; removed += f.size
        }
        return removed
    }

    static func freeSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

/// Per-stream prefetcher. Units are set when the proxy serves the media playlist (HLS) or learns the
/// MP4 length; `position` follows the playhead (seek → restart from the new unit).
final class Prefetcher: @unchecked Sendable {
    let token: String
    let budget: Int
    private let headers: [String: String]
    private let store: PrefetchStore
    private let fetch: @Sendable (PrefetchUnit, [String: String]) async throws -> Data
    private let lock = NSLock()
    private var units: [PrefetchUnit] = []
    private var index: [String: Int] = [:]
    private var sizes: [Int: Int] = [:]
    private var inFlight: [Int: Task<Data, Error>] = [:]
    private var start = 0
    private var stopped = false
    /// Units that failed twice are skipped (no hot retry loop on a dead CDN node).
    private var failures: [Int: Int] = [:]
    private(set) var lowStorage = false
    var fetchedBytes: Int { lock.withLock { sizes.values.reduce(0, +) } }
    var cacheHits = 0

    init(token: String, budget: Int, headers: [String: String], store: PrefetchStore = .shared,
         fetch: @escaping @Sendable (PrefetchUnit, [String: String]) async throws -> Data) {
        self.token = token; self.budget = budget; self.headers = headers; self.store = store; self.fetch = fetch
    }

    func setUnits(_ new: [PrefetchUnit]) {
        lock.lock()
        if new.map(\.key) != units.map(\.key) {
            inFlight.values.forEach { $0.cancel() }; inFlight = [:]
            units = new
            index = Dictionary(new.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
            sizes = [:]
        }
        lock.unlock()
        pump()
    }

    func setPosition(_ seconds: Double) {
        lock.lock()
        let s = PrefetchPlanner.startIndex(units, time: seconds)
        let changed = s != start
        start = s
        if changed { // seek: drop downloads that are now behind the playhead
            for (i, t) in inFlight where i < s { t.cancel(); inFlight[i] = nil }
        }
        lock.unlock()
        pump()
    }

    func stop() {
        lock.lock(); stopped = true; inFlight.values.forEach { $0.cancel() }; inFlight = [:]; lock.unlock()
    }

    func status() -> (bytes: Int, until: Double, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let s = PrefetchPlanner.status(units, start: start, sizes: sizes)
        return (s.bytes, s.until, sizes.values.reduce(0, +))
    }

    /// Cached bytes for a unit key (proxy serving path); records size if it was fetched elsewhere.
    func cached(_ key: String) -> Data? {
        guard let d = store.get(token, key) else { return nil }
        lock.lock(); if let i = index[key] { sizes[i] = d.count }; cacheHits += 1; lock.unlock()
        return d
    }

    /// Serve a unit: cache → in-flight download → fresh download (stored either way).
    func data(for key: String, fallback: PrefetchUnit) async throws -> Data {
        if let d = cached(key) { return d }
        lock.lock()
        let i = index[key]
        let running = i.flatMap { inFlight[$0] }
        lock.unlock()
        if let running, let d = try? await running.value { return d }
        let d = try await fetch(fallback, headers)
        store.put(token, key, d)
        lock.lock(); if let i { sizes[i] = d.count }; lock.unlock()
        pump()
        return d
    }

    private func pump() {
        lock.lock()
        guard !stopped, budget > 0, !units.isEmpty else { lock.unlock(); return }
        if PrefetchStore.freeSpace() < BufferSettings.lowStorage {
            lowStorage = true; lock.unlock()
            store.trim(to: 0); return
        }
        let known = sizes.values
        let estimate = known.isEmpty ? 1_500_000 : known.reduce(0, +) / known.count
        let picks = PrefetchPlanner.next(start: start, count: units.count, sizes: sizes, inFlight: Set(inFlight.keys),
                                         budget: budget, concurrency: BufferSettings.concurrency, estimate: estimate,
                                         skip: Set(failures.filter { $0.value >= 2 }.keys))
        for i in picks {
            let u = units[i]
            let token = self.token, store = self.store, fetch = self.fetch, headers = self.headers
            inFlight[i] = Task { [weak self] in
                var ok = false
                defer { self?.finish(i, ok: ok) }
                if let d = store.get(token, u.key) { self?.record(i, d.count); ok = true; return d }
                let d = try await fetch(u, headers)
                try Task.checkCancellation()
                store.put(token, u.key, d)
                self?.record(i, d.count)
                ok = true
                return d
            }
        }
        lock.unlock()
    }

    private func record(_ i: Int, _ n: Int) { lock.lock(); sizes[i] = n; lock.unlock() }

    private func finish(_ i: Int, ok: Bool) {
        lock.lock()
        let cancelled = inFlight[i]?.isCancelled ?? true
        inFlight[i] = nil
        if !ok && !cancelled { failures[i, default: 0] += 1 }
        lock.unlock()

        store.trim(to: BufferSettings.cacheCap)
        pump()
    }
}
