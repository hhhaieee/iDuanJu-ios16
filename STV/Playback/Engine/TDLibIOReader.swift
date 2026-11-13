import AetherEngine
import Foundation

/// AetherEngine byte source over a TDLib file being streamed: every read is served by
/// `TDStreamSession.read`, which moves TDLib's `downloadFile(offset:limit:)` window to the requested
/// bytes and waits for them — no loopback HTTP hop on the Aether path.
/// Calls arrive on the engine's demux thread, so blocking on the async session is fine there.
final class TDLibIOReader: IOReader, @unchecked Sendable {
    static let AVSEEK_SIZE: Int32 = 0x10000
    private let session: TDStreamSession
    private let lock = NSLock()
    private var pos: Int64 = 0
    private var total: Int?
    private var inFlight: Task<Data, Never>?
    private var cancelGeneration = 0

    init(session: TDStreamSession) { self.session = session }

    private func await_<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached { () -> Data in
            do { box.value = try await work() } catch { box.error = error }
            sem.signal()
            return Data()
        }
        lock.withLock { inFlight = task }
        sem.wait()
        lock.withLock { inFlight = nil }
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T?; var error: Error? }

    private func length() -> Int? {
        if let total = lock.withLock({ total }) { return total }
        let s = session
        guard let n = await_({ try await s.totalLength() }), n > 0 else { return nil }
        lock.withLock { total = n }
        return n
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        guard let total = length() else { return -5 }                 // AVERROR(EIO)
        let at = Int(lock.withLock { pos })
        if at >= total { return 0 }                                     // EOF
        let n = min(Int(size), total - at)
        let gen = lock.withLock { cancelGeneration }
        let s = session
        guard let d = await_({ try await s.read(at, n) }), !d.isEmpty else {
            return lock.withLock { cancelGeneration } != gen ? -4 : -5  // EINTR after cancel(), else EIO
        }
        let count = min(d.count, n)
        d.copyBytes(to: buffer, count: count)
        lock.withLock { pos = Int64(at + count) }
        return Int32(count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & Self.AVSEEK_SIZE != 0 { return length().map(Int64.init) ?? -1 }
        let base: Int64
        switch whence & 3 {
        case 0: base = 0                                               // SEEK_SET
        case 1: base = lock.withLock { pos }                           // SEEK_CUR
        case 2: guard let t = length() else { return -1 }; base = Int64(t)   // SEEK_END
        default: return -1
        }
        let p = base + offset
        guard p >= 0 else { return -1 }
        lock.withLock { pos = p }
        return p
    }

    /// Unblock a parked read; the reader stays usable (the engine may rebuild on it).
    func cancel() {
        let t = lock.withLock { () -> Task<Data, Never>? in cancelGeneration += 1; return inFlight }
        t?.cancel()
    }

    func close() { cancel() }

    /// One TDLib download window per file: a second cursor would fight the first for it.
    func makeIndependentReader() -> IOReader? { nil }
    var discImageProbeEnabled: Bool { false }
}
