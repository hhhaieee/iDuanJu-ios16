import Foundation
import Security

/// Port of gateway `player_device.go` (v3.9.97): player-endpoint device ring.
///
/// Batch player does **not** accept `device_register` devices. Default ring is
/// `[minted virtual]` only — the shared 9911… device is blocked upstream (2026-10-21) and is no longer used. Virtual = local 15-digit device_id,
/// `iid = did + 4096`, **no** device_register; persisted as `hongguo_player_device.json`
/// (write `.bak` before overwrite). Empty-body soft rejects call `remint()` / `rotate()`
/// to generate a fresh mint (9911… is gone; a 1-device ring cannot rotate otherwise).
enum HGPlayerDevice {
    struct Device: Codable, Equatable {
        var deviceId: String
        var iid: String
        var source: String?
        var mintedAt: String?

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case iid
            case source
            case mintedAt = "minted_at"
        }
    }

    private static let iidOffset: Int64 = 4096
    private static let chunkMaxDevices = 3

    private static let lock = NSLock()
    private static var index = 0
    private static var minted: Device?
    private static var mintLoaded = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hongguo_player_device.json")
    }

    private static var bakURL: URL {
        URL(fileURLWithPath: fileURL.path + ".bak")
    }

    /// `iid=…&device_id=…` for playerQuery / detailQuery.
    static func queryPart() -> String {
        var d = current()
        if d.deviceId.isEmpty || d.iid.isEmpty { d = mintedDevice() ?? mint() }
        return "iid=\(d.iid)&device_id=\(d.deviceId)"
    }

    static func current() -> Device {
        let ring = deviceRing()
        lock.lock(); defer { lock.unlock() }
        if ring.isEmpty { return mint() }
        if index >= ring.count { index = 0 }
        return ring[index]
    }

    /// Soft-reject recovery: mint a **new** virtual device, persist it (with .bak), make it current.
    @discardableResult
    static func remint() -> Device {
        let d = mint()
        saveFile(d)
        lock.lock()
        minted = d
        mintLoaded = true
        index = 0
        lock.unlock()
        return d
    }

    /// Advance after empty-body soft reject. With mint-only ring this remints.
    @discardableResult
    static func rotate() -> Device { remint() }

    /// Budget for empty-body remints (not ring length — ring is intentionally one mint).
    static func devicesForChunk() -> Int { chunkMaxDevices }

    /// Default ring: this install's own minted device only (persisted, never hard-coded).
    static func deviceRing() -> [Device] {
        [mintedDevice() ?? mint()]
    }

    static func mintedDevice() -> Device? {
        lock.lock()
        if mintLoaded {
            let d = minted
            lock.unlock()
            return d
        }
        lock.unlock()

        if let d = loadFile() {
            lock.lock(); minted = d; mintLoaded = true; lock.unlock()
            return d
        }
        let d = mint()
        saveFile(d)
        lock.lock(); minted = d; mintLoaded = true; lock.unlock()
        return d
    }

    /// 15-digit device_id (leading 5–9) + iid = device_id + 4096.
    static func mint() -> Device {
        var digits = [UInt8](repeating: 0, count: 15)
        let status = SecRandomCopyBytes(kSecRandomDefault, digits.count, &digits)
        if status != errSecSuccess {
            var seed = UInt64(Date().timeIntervalSince1970 * 1000)
            for i in 0..<15 {
                digits[i] = UInt8(truncatingIfNeeded: seed >> (UInt64(i % 8) * 8))
                seed = seed / 7 &+ 13
            }
        }
        var s = String(5 + Int(digits[0] % 5))
        for i in 1..<15 { s.append(String(digits[i] % 10)) }
        guard let n = Int64(s) else {
            let fallback = 500_000_000_000_000 + (Int64(Date().timeIntervalSince1970 * 1000) % 499_999_999_999_999)
            return Device(deviceId: String(fallback), iid: String(fallback + iidOffset),
                          source: "mint", mintedAt: isoNow())
        }
        return Device(deviceId: s, iid: String(n + iidOffset), source: "mint", mintedAt: isoNow())
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func loadFile() -> Device? {
        for candidate in [fileURL, bakURL] {
            guard let data = try? Data(contentsOf: candidate),
                  var d = try? JSONDecoder().decode(Device.self, from: data),
                  !d.deviceId.isEmpty, !d.iid.isEmpty else { continue }
            if d.source == nil || d.source?.isEmpty == true { d.source = "file" }
            return d
        }
        return nil
    }

    private static func saveFile(_ d: Device) {
        if let old = try? Data(contentsOf: fileURL), !old.isEmpty {
            try? old.write(to: bakURL, options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Test helper: reset process-local mint / index.
    static func resetForTests() {
        lock.lock()
        index = 0
        minted = nil
        mintLoaded = false
        lock.unlock()
    }
}
