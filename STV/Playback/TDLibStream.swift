import Foundation

/// `tdfile://<file id>[?mime=…&s=0|1&size=…]` — a TDLib file reference carried in posts / streams.
/// Older refs without a query (`tdfile://123`) still parse.
struct TDFileRef: Equatable {
    let id: Int32
    var mime: String = "video/mp4"
    var streaming: Bool = true
    var size: Int = 0

    init(id: Int32, mime: String = "video/mp4", streaming: Bool = true, size: Int = 0) {
        self.id = id; self.mime = mime.isEmpty ? "video/mp4" : mime; self.streaming = streaming; self.size = size
    }

    init?(_ s: String) {
        guard s.hasPrefix("tdfile://"), let c = URLComponents(string: s) else { return nil }
        let host = c.host ?? String(s.dropFirst("tdfile://".count).prefix { $0 != "?" })
        guard let id = Int32(host) else { return nil }
        self.id = id
        for q in c.queryItems ?? [] {
            switch q.name {
            case "mime": if let v = q.value, !v.isEmpty { mime = v }
            case "s": streaming = q.value != "0"
            case "size": size = Int(q.value ?? "") ?? 0
            default: break
            }
        }
    }

    var string: String {
        var c = URLComponents(); c.scheme = "tdfile"; c.host = String(id)
        c.queryItems = [.init(name: "mime", value: mime), .init(name: "s", value: streaming ? "1" : "0"), .init(name: "size", value: String(size))]
        return c.string ?? "tdfile://\(id)"
    }
}

struct TDFileState: Sendable {
    var size: Int
    var expectedSize: Int
    var completed: Bool
    var path: String
}

/// The TDLib calls streaming needs (TDLibKitEngine / mocks).
protocol TDFileStreamSource: AnyObject {
    /// `getFile`.
    func fileState(_ id: Int32) async throws -> TDFileState
    /// `downloadFile(priority:offset:limit:synchronous:false)` — returns immediately; TDLib keeps the
    /// already downloaded parts and re-targets the running download to the new window.
    func requestDownload(_ id: Int32, offset: Int, limit: Int, priority: Int) async throws
    /// `getFileDownloadedPrefixSize(offset)`.
    func downloadedPrefix(_ id: Int32, offset: Int) async throws -> Int
    /// `readFilePart` (only already downloaded bytes).
    func readPart(_ id: Int32, offset: Int, count: Int) async throws -> Data
    /// `cancelDownloadFile(onlyIfPending: false)` — downloaded parts stay on disk.
    func cancelDownload(_ id: Int32) async
}

/// Files being fully downloaded by the user (「下载」). Streaming must not re-target or cancel those.
final class TDFullDownloads: @unchecked Sendable {
    static let shared = TDFullDownloads()
    private let lock = NSLock()
    private var ids: [Int32: Int] = [:]
    func begin(_ id: Int32) { lock.withLock { ids[id, default: 0] += 1 } }
    func end(_ id: Int32) { lock.withLock { ids[id] = (ids[id] ?? 1) - 1; if ids[id]! <= 0 { ids[id] = nil } } }
    func contains(_ id: Int32) -> Bool { lock.withLock { ids[id] != nil } }
}

enum TDStreamError: LocalizedError {
    case unknownSize, timeout(Int)
    var errorDescription: String? {
        switch self {
        case .unknownSize: "TDLib 文件大小未知"
        case .timeout(let o): "TDLib 下载超时（offset \(o)）"
        }
    }
}

/// One TDLib video played while it downloads. AVPlayer's Range requests become *waiters*; TDLib downloads
/// one window per file (a new offset/limit re-targets it), so the window always serves the oldest waiter
/// that isn't covered yet, then keeps reading ahead `readAhead` bytes (the pre-buffer budget).
final class TDStreamSession: @unchecked Sendable {
    let ref: TDFileRef
    let source: TDFileStreamSource
    let chunk: Int
    let readAhead: Int
    let priority: Int
    var pollNanos: UInt64 = 60_000_000
    /// No progress for this long → the request fails (player retries / shows the error).
    var stallTimeout: TimeInterval = 45
    var isPinned: () -> Bool

    private let lock = NSLock()
    private var length: Int?
    private var window: (offset: Int, limit: Int)?
    private var waiters: [(id: Int, lo: Int, n: Int)] = []
    private var nextWaiter = 0
    private var requests: [(offset: Int, limit: Int)] = []
    private var lastServedEnd = 0

    init(ref: TDFileRef, source: TDFileStreamSource, chunk: Int = 1_048_576, readAhead: Int, priority: Int = 32,
         isPinned: (() -> Bool)? = nil) {
        self.ref = ref; self.source = source; self.chunk = max(16_384, chunk)
        self.readAhead = max(readAhead, 4 * max(16_384, chunk)); self.priority = priority
        let id = ref.id
        self.isPinned = isPinned ?? { TDFullDownloads.shared.contains(id) }
    }

    /// Content-Type for AVPlayer: only containers it can open; TDLib's octet-stream / empty → video/mp4.
    var mime: String { Self.playableMime(ref.mime) }
    static func playableMime(_ m: String) -> String {
        let m = m.lowercased().trimmingCharacters(in: .whitespaces)
        return ["video/mp4", "video/quicktime", "video/x-m4v", "audio/mp4"].contains(m) ? m : "video/mp4"
    }

    /// Content-Length: `size`, else `expected_size` (TDLib knows the size of server files up front).
    func totalLength() async throws -> Int {
        if let n = lock.withLock({ length }) { return n }
        let st = try await source.fileState(ref.id)
        let n = st.size > 0 ? st.size : (st.expectedSize > 0 ? st.expectedSize : ref.size)
        guard n > 0 else { throw TDStreamError.unknownSize }
        lock.withLock { length = n }
        return n
    }

    /// Bytes `[lo, lo+count)` (clipped to the file); waits until TDLib has them.
    func read(_ lo: Int, _ count: Int) async throws -> Data {
        let total = try await totalLength()
        let n = min(count, total - lo)
        guard lo >= 0, n > 0 else { return Data() }
        let wid = lock.withLock { () -> Int in nextWaiter += 1; waiters.append((nextWaiter, lo, n)); return nextWaiter }
        defer {
            lock.withLock { waiters.removeAll { $0.id == wid }; lastServedEnd = max(lastServedEnd, lo + n) }
            Task { try? await self.retarget() }
        }
        var best = -1, lastProgress = Date()
        while true {
            try Task.checkCancellation()
            let have = try await source.downloadedPrefix(ref.id, offset: lo)
            if have >= n {
                let d = try await source.readPart(ref.id, offset: lo, count: n)
                if d.count >= n { return d.count == n ? d : d.prefix(n) }
            }
            if have > best { best = have; lastProgress = Date() }
            if Date().timeIntervalSince(lastProgress) > stallTimeout { throw TDStreamError.timeout(lo) }
            try await retarget()
            try await Task.sleep(nanoseconds: pollNanos)
        }
    }

    /// Point TDLib's download at the oldest waiter unless the running window will reach it soon
    /// (TDLib downloads a window front to back, so "inside the window" alone isn't enough after a seek).
    func retarget() async throws {
        guard !isPinned() else { return }
        let pick: (lo: Int, n: Int, window: (offset: Int, limit: Int)?, total: Int)? = lock.withLock {
            guard let w = waiters.first else { return nil }
            return (w.lo, w.n, window, length ?? Int.max)
        }
        guard let p = pick else { return }
        if let w = p.window {
            let end = w.limit == 0 ? p.total : w.offset + w.limit
            if p.lo >= w.offset, p.lo + p.n <= end {
                let frontier = w.offset + ((try? await source.downloadedPrefix(ref.id, offset: w.offset)) ?? 0)
                if p.lo <= frontier + 2 * chunk { return }
            }
        }
        try await request(p.lo, min(max(readAhead, p.n), p.total - p.lo))
    }

    /// TDLib download windows requested so far (tests / diagnostics).
    var requestLog: [(offset: Int, limit: Int)] { lock.withLock { requests } }

    /// Seek: start downloading at the new position right away (AVPlayer's request follows).
    func seek(fraction: Double) async {
        guard !isPinned(), let total = try? await totalLength() else { return }
        let o = (Int(Double(total) * min(max(fraction, 0), 1)) / chunk) * chunk
        let busy = lock.withLock { !waiters.isEmpty }
        guard !busy, o < total else { return }
        try? await request(o, min(readAhead, total - o))
    }

    private func request(_ o: Int, _ l: Int) async throws {
        lock.withLock { window = (o, l); requests.append((o, l)) }
        try await source.requestDownload(ref.id, offset: o, limit: l, priority: priority)
    }

    /// Downloaded bytes contiguous from `fraction` of the file → (bytes ahead, fraction reached).
    func buffered(from fraction: Double) async -> (bytes: Int, until: Double)? {
        guard let total = try? await totalLength() else { return nil }
        let o = min(total - 1, max(0, Int(Double(total) * fraction)))
        guard let have = try? await source.downloadedPrefix(ref.id, offset: o) else { return nil }
        return (have, Double(min(total, o + have)) / Double(total))
    }

    /// Leaving the player: stop TDLib's download (parts already on disk stay for next time).
    func cancel() async {
        guard !isPinned() else { return }
        await source.cancelDownload(ref.id)
    }
}
