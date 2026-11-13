import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Stream robustness (ported from hongguo-open-player app-source.js)
// 1. Resolve cache (180 s) + in-flight dedupe, so next episodes can be prefetched and switched instantly.
// 2. `fallback_api` follow when video_model has no inline video_list.
// 3. `key_seed` AES-wrapped media addresses (decryptSpadeUrl).

extension HongguoClient {
    static let resolveTTL: TimeInterval = 180

    /// Primary entry. Cached / shared in-flight result first, then the unchanged resolve chain.
    func resolve(vid: String) async throws -> HGResolvedVideo {
        if let hit = cachedResolve(vid) { return hit }
        if let t = resolveInflight[vid] { return try await t.value }
        let t = Task { try await self.resolveFresh(vid: vid) }
        resolveInflight[vid] = t
        defer { resolveInflight[vid] = nil }
        let r = try await t.value
        if r.err == nil, !r.streams.isEmpty { resolveCache[vid] = (r, Date()) }
        return r
    }

    func cachedResolve(_ vid: String) -> HGResolvedVideo? {
        guard let e = resolveCache[vid] else { return nil }
        let now = Date()
        let urlAlive = (e.video.expiresAt ?? 0) <= 0 || TimeInterval(e.video.expiresAt!) > now.timeIntervalSince1970 + 60
        if now.timeIntervalSince(e.at) < Self.resolveTTL && urlAlive { return e.video }
        resolveCache[vid] = nil
        return nil
    }

    /// Warm play URLs for upcoming episodes (sequential, at most 3) — like their batch `nextVids`.
    func prefetch(vids: [String]) {
        let todo = Array(vids.filter { !$0.isEmpty && cachedResolve($0) == nil && resolveInflight[$0] == nil }.prefix(3))
        guard !todo.isEmpty else { return }
        Task {
            for v in todo {
                let t0 = Date()
                do {
                    let r = try await self.resolve(vid: v)
                    NSLog("[HG] prefetch %@ ok streams=%d %.2fs", v, r.streams.count, Date().timeIntervalSince(t0))
                } catch { NSLog("[HG] prefetch %@ failed: %@", v, error.localizedDescription) }
            }
        }
    }

    func clearResolveCache() { resolveCache.removeAll() }

    // MARK: fallback_api / key_seed

    /// Inline video_list → parse directly (unchanged path). Otherwise follow `fallback_api` like parseEntryPlayInfo.
    func materialize(_ vm: [String: Any], vid: String) async throws -> HGResolvedVideo {
        let seed = Self.keySeed(vm)
        if Self.hasInlineList(vm) { return Self.parseVideoModel(vm, vid: vid, keySeed: seed) }
        let fb = Self.fallbackAPI(vm["fallback_api"])
        guard !fb.isEmpty else { return Self.parseVideoModel(vm, vid: vid, keySeed: seed) }
        guard let u = URL(string: fb), let host = u.host?.lowercased(), u.scheme == "https" || u.scheme == "http",
              ["fqnovel.com", "snssdk.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw ProviderError.upstream("fallback_api 地址不受信任")
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue(Self.videoModelUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await playerSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw ProviderError.upstream("fallback_api HTTP \(status) 空响应") }
        let outer = try J.parse(data)
        let vi = J.dict(outer["video_info"])
        for c in [outer["code"] ?? outer["Code"], vi["code"] ?? vi["Code"]] where c != nil {
            if J.int(c) != 0 { throw ProviderError.upstream("fallback_api 暂未提供本集播放信息 code=\(J.str(c))") }
        }
        var info = J.dict(vi["data"])
        guard !info.isEmpty else { throw ProviderError.upstream("fallback_api 未返回片源模型") }
        if info["video_duration"] == nil { info["video_duration"] = vm["video_duration"] }
        if info["url_expire"] == nil { info["url_expire"] = vm["url_expire"] }
        var r = Self.parseVideoModel(info, vid: vid, keySeed: Self.keySeed(info) ?? seed)
        r.note = "fallback_api"
        NSLog("[HG] fallback_api followed vid=%@ streams=%d", vid, r.streams.count)
        return r
    }

    static func hasInlineList(_ vm: [String: Any]) -> Bool {
        if let m = vm["video_list"] as? [String: Any] { return !m.isEmpty }
        return !J.arr(vm["video_list"]).isEmpty
    }

    static func fallbackAPI(_ v: Any?) -> String {
        if let s = v as? String {
            if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return J.str(o["fallback_api"]) }
            return s
        }
        if let a = v as? [Any] { return J.str(a.first) }
        return J.str(J.dict(v)["fallback_api"])
    }

    static func keySeed(_ vm: [String: Any]) -> Data? {
        let s = J.str(vm["key_seed"]); guard !s.isEmpty else { return nil }
        return b64(s)
    }

    /// Tolerant base64 (url-safe, missing padding) like Node's Buffer.from(…, 'base64').
    static func b64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func mediaURL(_ value: Any?, seed: Data?) -> URL? {
        if let seed, let plain = decryptSpadeURL(J.str(value), seed: seed),
           let u = URL(string: plain), ["http", "https"].contains(u.scheme), u.host != nil { return u }
        return mediaURL(value)
    }

    private static let spadeURLConst: [UInt8] = Bytes.fromHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!

    /// app-source.js decryptSpadeUrl: header a8 ?? 01 00, AES-128-CBC with key/iv from SHA512(SHA512(seed) ‖ const).
    static func decryptSpadeURL(_ value: String, seed: Data) -> String? {
        guard !value.isEmpty, let raw = b64(value) else { return nil }
        let b = [UInt8](raw)
        guard b.count >= 5, b[0] == 0xa8, b[2] == 0x01, b[3] == 0x00 else { return nil }
        let n = (b.count - 4) / 16 * 16
        guard n > 0 else { return nil }
        let h1 = Array(SHA512.hash(data: seed))
        let h2 = Array(SHA512.hash(data: Data(h1 + spadeURLConst)))
        let key = Array(h2[0..<16]), iv = Array(h2[16..<32])
        let cipher = Array(b[4..<(4 + n)])
        var out = [UInt8](repeating: 0, count: n + 16)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), key, key.count, iv,
                         cipher, cipher.count, &out, out.count, &moved)
        guard st == kCCSuccess else { return nil }
        var plain = Array(out[0..<moved])
        if let pad = plain.last, pad >= 1, pad <= 16, Int(pad) <= plain.count { plain.removeLast(Int(pad)) }
        while plain.last == 0 { plain.removeLast() }
        return String(bytes: plain, encoding: .utf8)
    }
}
