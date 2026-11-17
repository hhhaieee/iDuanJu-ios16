import Foundation

/// Port of hongguo/device.go: anonymous device_register, persisted on-device (Application Support).
struct HGDevice: Codable {
    var deviceId: String
    var iid: String
    var cdid: String
    var openudid: String
    var sessionEntropy: String
    /// Unix seconds of the device_register call. nil = file written by an older build (age unknown → treated as stale).
    var registeredAt: Double?

    /// video_model soft-rejects (HTTP 200 + 0 bytes) a registered device roughly 9–10 min after device_register
    /// (live probe 2026-11-11: P for 11 requests up to t=509 s, F from t=629 s on, with or without traffic in between).
    static let playbackMaxAge: TimeInterval = 7 * 60
    var isStaleForPlayback: Bool {
        guard let t = registeredAt else { return true }
        return Date().timeIntervalSince1970 - t > Self.playbackMaxAge
    }

    var entropy: [UInt8] { Bytes.fromHex(sessionEntropy) ?? [UInt8](repeating: 0, count: 20) }

    static let appVersion = "7.3.3.32"
    static let versionCode = "73332"
    static let ua = "com.phoenix.read/72133 (Linux; U; Android 10; zh_CN_#Hans; EML-AL00; Build/HUAWEIEML-AL00; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hongguo_device.json")
    }

    static func load() -> HGDevice? {
        guard let d = try? Data(contentsOf: fileURL), let dev = try? JSONDecoder().decode(HGDevice.self, from: d),
              !dev.deviceId.isEmpty, !dev.iid.isEmpty, !dev.cdid.isEmpty else { return nil }
        return dev
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.fileURL, options: .atomic) } }
    static func reset() { try? FileManager.default.removeItem(at: fileURL) }

    static func uuid4() -> String { UUID().uuidString.lowercased() }
    static func randomDigits(_ n: Int) -> String {
        var s = String(Int.random(in: 1...9)); while s.count < n { s += String(Int.random(in: 0...9)) }; return s
    }

    static func register(session: URLSession) async throws -> HGDevice {
        var dev = HGDevice(deviceId: randomDigits(19), iid: randomDigits(19), cdid: uuid4(),
                           openudid: Bytes.hex(Bytes.random(8)), sessionEntropy: Bytes.hex(Bytes.random(20)), registeredAt: nil)
        let query = "aid=8662&app_name=novelread&version_code=\(versionCode)&version_name=\(appVersion)" +
            "&device_platform=android&os=android&ssmix=a&language=zh&channel=ry_hongguo_offlinestore_04" +
            "&device_type=sdk_gphone64_arm64&device_brand=google&resolution=1080*2400&dpi=420&host_abi=arm64-v8a" +
            "&manifest_version_code=\(versionCode)&update_version_code=\(versionCode)" +
            "&ac=wifi&app_type=normal&cpu_support64=true" +
            "&device_id=\(dev.deviceId)&iid=\(dev.iid)&cdid=\(dev.cdid)&openudid=\(dev.openudid)"
        let header: [String: Any] = [
            "display_name": "红果短剧", "aid": 8662, "channel": "ry_hongguo_offlinestore_04", "package": "com.phoenix.read",
            "app_version": appVersion, "version_code": 73332, "manifest_version_code": 73332, "update_version_code": 73332,
            "sdk_version": "3.9.5", "sdk_target_version": 35, "os": "Android", "os_version": "15", "os_api": 35,
            "device_model": "sdk_gphone64_arm64", "device_brand": "google", "device_manufacturer": "Google",
            "cpu_abi": "arm64-v8a", "release_build": "AE3A.240806.043", "density_dpi": 420, "display_density": "xhdpi",
            "resolution": "1080x2400", "language": "zh", "timezone": 8, "region": "CN", "tz_name": "Asia/Shanghai",
            "cdid": dev.cdid, "openudid": dev.openudid, "clientudid": uuid4(), "google_aid": "", "req_id": uuid4()
        ]
        let body = J.encodeSorted(["magic_tag": "ss_app_log", "header": header, "_gen_time": Int(Date().timeIntervalSince1970)])
        var req = URLRequest(url: URL(string: "https://log.snssdk.com/service/2/device_register/?" + query)!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in HGSign.basicHeaders(params: query, body: Array(body)) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        let (data, _) = try await session.data(for: req)
        let j = try J.parse(data)
        let did = J.firstNonEmpty(J.str(j["device_id_str"]), J.str(j["device_id"]))
        var iid = J.firstNonEmpty(J.str(j["install_id_str"]), J.str(j["install_id"]))
        if iid.isEmpty || iid == "0" { iid = J.str(j["iid"]) }
        guard !did.isEmpty, did != "0", !iid.isEmpty, iid != "0" else {
            throw ProviderError.upstream("device_register 返回无效设备 ID")
        }
        dev.deviceId = did; dev.iid = iid
        dev.registeredAt = Date().timeIntervalSince1970
        dev.save()
        return dev
    }
}

/// Player-only identity. Search registration stays in `HGDevice`; playback must use the same
/// 7.3.9.32 / Xiaomi profile carried by the pure video_model request.
struct HGPlayerIdentity: Codable {
    var deviceId: String
    var iid: String
    var cdid: String
    var openudid: String
    var registeredAt: Double
    static let profile = "73932-xiaomi-23127PN0CC"
    static let maxAge: TimeInterval = 7 * 60
    var isUsable: Bool { !deviceId.isEmpty && !iid.isEmpty && !cdid.isEmpty && !openudid.isEmpty && Date().timeIntervalSince1970 - registeredAt < Self.maxAge }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hongguo_player_registered_device.json")
    }

    static func load() -> HGPlayerIdentity? {
        for url in [fileURL, URL(fileURLWithPath: fileURL.path + ".bak")] {
            guard let data = try? Data(contentsOf: url), let id = try? JSONDecoder().decode(HGPlayerIdentity.self, from: data), id.isUsable else { continue }
            return id
        }
        return nil
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        if let old = try? Data(contentsOf: Self.fileURL) { try? old.write(to: URL(fileURLWithPath: Self.fileURL.path + ".bak"), options: .atomic) }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    static func register(session: URLSession) async throws -> HGPlayerIdentity {
        let cdid = HGDevice.uuid4(), openudid = Bytes.hex(Bytes.random(8))
        let query = "aid=8662&app_name=novelread&version_code=73932&version_name=7.3.9.32&device_platform=android&os=android&ssmix=a" +
            "&language=zh&channel=xiaomi_8662_64&device_type=23127PN0CC&device_brand=Xiaomi&resolution=1200*2670&dpi=460" +
            "&host_abi=arm64-v8a&manifest_version_code=73932&update_version_code=73932&ac=wifi&app_type=normal&cpu_support64=true" +
            "&os_api=34&os_version=14&cdid=\(cdid)&openudid=\(openudid)"
        let header: [String: Any] = [
            "display_name": "红果短剧", "aid": 8662, "channel": "xiaomi_8662_64", "package": "com.phoenix.read",
            "app_version": "7.3.9.32", "version_code": 73932, "manifest_version_code": 73932, "update_version_code": 73932,
            "sdk_version": "3.9.5", "sdk_target_version": 34, "os": "Android", "os_version": "14", "os_api": 34,
            "device_model": "23127PN0CC", "device_brand": "Xiaomi", "device_manufacturer": "Xiaomi", "cpu_abi": "arm64-v8a",
            "release_build": "UKQ1.230804.001", "density_dpi": 460, "display_density": "xxhdpi", "resolution": "2670x1200",
            "language": "zh", "timezone": 8, "region": "CN", "tz_name": "Asia/Shanghai", "cdid": cdid, "openudid": openudid,
            "clientudid": HGDevice.uuid4(), "google_aid": "", "req_id": HGDevice.uuid4(),
        ]
        let body = J.encodeSorted(["magic_tag": "ss_app_log", "header": header, "_gen_time": Int(Date().timeIntervalSince1970)])
        var req = URLRequest(url: URL(string: "https://log.snssdk.com/service/2/device_register/?" + query)!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in HGSign.basicHeaders(params: query, body: Array(body)) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(HongguoClient.purePlayerUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.upstream("播放器设备注册失败") }
        let j = try J.parse(data)
        let did = J.firstNonEmpty(J.str(j["device_id_str"]), J.str(j["device_id"]))
        var iid = J.firstNonEmpty(J.str(j["install_id_str"]), J.str(j["install_id"]))
        if iid.isEmpty || iid == "0" { iid = J.str(j["iid"]) }
        guard did.allSatisfy(\.isNumber), iid.allSatisfy(\.isNumber), !did.isEmpty, did != "0", !iid.isEmpty, iid != "0" else {
            throw ProviderError.upstream("播放器设备注册返回无效身份")
        }
        let id = HGPlayerIdentity(deviceId: did, iid: iid, cdid: cdid, openudid: openudid, registeredAt: Date().timeIntervalSince1970)
        id.save()
        return id
    }
}
