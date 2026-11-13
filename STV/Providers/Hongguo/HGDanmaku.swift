import Foundation
import CommonCrypto

/// One time-coded official danmaku (bullet comment).
struct HGDanmaku: Hashable, Identifiable {
    var time: Double
    var text: String
    var likes: Int = 0
    /// `#RRGGBB`
    var color: String = "#FFFFFF"
    var mode: Mode = .scroll
    /// > 1 when several duplicate/similar comments were merged into this one.
    var count: Int = 1
    var id: String { String(format: "%.3f|", time) + text }
    enum Mode: String, Hashable { case scroll, top, bottom }
}

struct HGDanmakuResult: Hashable {
    var items: [HGDanmaku]
    var truncated = false
    /// Non-empty when the source failed (never shown as "本集没有弹幕").
    var error = ""
    var notice: String {
        if !error.isEmpty { return error }
        if truncated { return "弹幕较多，仅载入前 \(items.count) 条" }
        if items.isEmpty { return "本集暂无弹幕" }
        return ""
    }
}

/// Signing for `/novel/commentapi/comment/list/{vid}/v1/` (X-Gorgon nonce variant / X-Ladon / X-Argus).
/// Byte-for-byte port of hongguo-open-player `danmaku-sign.js` (itself from guoapp / nas-backend).
/// Do not "fix" the RC4 key schedule (`box[i] = box[j]` is an assignment on purpose).
enum HGCommentSign {
    static let nonceBytes = 11

    @inline(__always) static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        let s = UInt64(((n % 64) + 64) % 64)
        return s == 0 ? x : (x << s) | (x >> (64 - s))
    }
    @inline(__always) static func rotr64(_ x: UInt64, _ n: Int) -> UInt64 { rotl64(x, -n) }
    @inline(__always) static func rotl8(_ x: UInt8, _ n: Int) -> UInt8 {
        let s = UInt8(n & 7); return s == 0 ? x : (x << s) | (x >> (8 - s))
    }
    static func reverse8(_ x: UInt8) -> UInt8 {
        var v = x
        v = ((v & 0xF0) >> 4) | ((v & 0x0F) << 4)
        v = ((v & 0xCC) >> 2) | ((v & 0x33) << 2)
        v = ((v & 0xAA) >> 1) | ((v & 0x55) << 1)
        return v
    }
    static func pad(_ d: [UInt8]) -> [UInt8] { let p = 16 - d.count % 16; return d + [UInt8](repeating: UInt8(p), count: p) }
    static func uvarint(_ value: UInt64) -> [UInt8] {
        var v = value; var out: [UInt8] = []
        while true {
            let b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { out.append(b | 0x80) } else { out.append(b); return out }
        }
    }

    static func newDeviceId() -> String { String(1_000_000_000_000_000_000 + UInt64.random(in: 0..<8_000_000_000_000_000_000)) }

    static func baseParams(deviceId: String, installId: String) -> [String: String] {
        ["aid": "8662", "app_name": "novelread", "version_code": "73532", "version_name": "7.3.5.32",
         "manifest_version_code": "73532", "update_version_code": "73532", "channel": "update_64",
         "device_platform": "android", "os": "android", "ssmix": "a", "device_type": "25053RT47C", "device_brand": "Redmi",
         "language": "zh", "os_api": "36", "os_version": "16", "resolution": "1280*2772", "dpi": "520", "ac": "wifi",
         "device_id": deviceId, "iid": installId]
    }

    /// Python `urlencode(sorted)` == Go url.Values.Encode for these values.
    static func buildQuery(stampMs: Int64, deviceId: String, installId: String) -> String {
        var p = baseParams(deviceId: deviceId, installId: installId)
        p["_rticket"] = String(stampMs)
        return GoURL.encode(p)
    }

    static func xGorgon(_ rawQuery: String, stamp: Int64, nonce: [UInt8]) -> String {
        let head2 = UInt8(truncatingIfNeeded: ((Int(nonce[0]) % 7) + 1) << 5)
        let head3 = UInt8(0xE0) | (nonce[1] & 0x0F)
        var seed = [UInt8](repeating: 0, count: 20)
        let digest = Bytes.md5(rawQuery)
        for i in 0..<4 { seed[i] = digest[i] }
        seed[12] = 0; seed[13] = 1; seed[14] = 7; seed[15] = 4
        let tb = Bytes.u32BE(UInt32(truncatingIfNeeded: stamp))
        for i in 0..<4 { seed[16 + i] = tb[i] }
        let key: [UInt8] = [0x4A, 0x00, 0x16, head3, 0x47, 0x6C, 0x00, head2]
        var box = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { box[i] = UInt8(i) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(box[i]) + Int(key[i & 7])) & 0xFF
            box[i] = box[j]
        }
        j = 0
        for offset in 0..<20 {
            let i = (offset + 1) & 0xFF
            j = (j + Int(box[i])) & 0xFF
            box[i] = box[j]
            seed[offset] ^= box[(Int(box[i]) + Int(box[j])) & 0xFF]
        }
        for i in 0..<20 {
            seed[i] = reverse8(rotl8(seed[i], 4) ^ seed[(i + 1) % 20]) ^ 0xEB
        }
        return Bytes.hex([0x84, 0x04, head2, head3, 0x00, 0x00] + seed)
    }

    static func ladon(stamp: Int64, prefix: [UInt8], aid: String = "8662") -> String {
        let digest = Array(Bytes.hex(Bytes.md5(prefix + Array(aid.utf8))).utf8)
        var left = Bytes.readU64LE(digest, 0)
        var right = Bytes.readU64LE(digest, 8)
        var queue = [Bytes.readU64LE(digest, 16), Bytes.readU64LE(digest, 24)]
        var keys: [UInt64] = []
        for i in 0..<34 {
            keys.append(left)
            let mixed = (rotr64(right, 8) &+ left) ^ UInt64(i)
            queue.append(mixed)
            left = mixed ^ rotl64(left, 3)
            right = queue.removeFirst()
        }
        var data = pad(Array("\(stamp)-1611921764-3019".utf8))
        var off = 0
        while off < data.count {
            var bl = Bytes.readU64LE(data, off), br = Bytes.readU64LE(data, off + 8)
            for k in keys {
                br = k ^ (bl &+ rotr64(br, 8))
                bl = br ^ rotl64(bl, 3)
            }
            Bytes.writeU64LE(bl, into: &data, at: off); Bytes.writeU64LE(br, into: &data, at: off + 8)
            off += 16
        }
        return Data(prefix + data).base64EncodedString()
    }

    static let argusKey: [UInt8] = Bytes.fromHex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")!

    static func argus(_ rawQuery: String, stamp: Int64, nonce: [UInt8]) -> String? {
        let key = argusKey
        var parts: [UInt8] = []
        func varint(_ field: UInt64, _ value: UInt64) { parts += uvarint(field * 8); parts += uvarint(value) }
        func bytes(_ field: UInt64, _ v: [UInt8]) { parts += uvarint(field * 8 + 2); parts += uvarint(UInt64(v.count)); parts += v }
        let n3 = UInt32(nonce[6]) | UInt32(nonce[7]) << 8 | UInt32(nonce[8]) << 16 | UInt32(nonce[9]) << 24
        varint(1, UInt64(0x20200929) * 2)
        varint(2, 2)
        varint(3, UInt64(n3))
        bytes(4, Array("3019".utf8))
        bytes(6, Array("1611921764".utf8))
        bytes(7, Array("6.8.1.32".utf8))
        bytes(8, Array("v04.07.01-ml-android".utf8))
        varint(9, 135135744)
        bytes(10, [UInt8](repeating: 0, count: 8))
        varint(12, UInt64(bitPattern: stamp) &* 2)
        let bodyHash = Medusa.sm3([UInt8](repeating: 0, count: 16))
        let queryHash = Medusa.sm3(Array(rawQuery.utf8))
        bytes(13, Array(bodyHash[0..<6]))
        bytes(14, Array(queryHash[0..<6]))
        var nested: [UInt8] = [0x08, UInt8(truncatingIfNeeded: 2 + (Int(nonce[10]) % 49) * 2)]
        for f: UInt64 in [2, 3, 4] { nested += uvarint(f * 8); nested += uvarint(1388734) }
        bytes(15, nested)
        bytes(20, Array("none".utf8))
        varint(21, 738)

        var data = pad(parts)
        let derived = Medusa.sm3(key + [0x3C, 0xCC, 0x56, 0x7B] + key)
        var rounds = [UInt64](repeating: 0, count: 72)
        for i in 0..<4 { rounds[i] = Bytes.readU64LE(derived, i * 8) }
        let c: UInt64 = 0x3DC94C3A046D678B
        for i in 4..<72 {
            var mixed = rotr64(rounds[i - 1], 3) ^ rounds[i - 3]
            mixed ^= rotr64(mixed, 1)
            rounds[i] = (~rounds[i - 4]) ^ mixed ^ ((c >> UInt64((i - 4) % 62)) & 1) ^ 3
        }
        var off = 0
        while off < data.count {
            var l = Bytes.readU64LE(data, off), r = Bytes.readU64LE(data, off + 8)
            for k in rounds {
                let next = l ^ (rotl64(r, 1) & rotl64(r, 8)) ^ rotl64(r, 2) ^ k
                l = r; r = next
            }
            Bytes.writeU64LE(l, into: &data, at: off); Bytes.writeU64LE(r, into: &data, at: off + 8)
            off += 16
        }
        let xor: [UInt8] = [0xD0, 0x4F, 0xFD, 0xFF, 0xD0, 0x4F, 0xFD, 0xFF]
        for i in 0..<data.count { data[i] ^= xor[i % 8] }
        let reversed = Array((xor + data).reversed())
        let container = pad([0xA6, 0xE7, 0x83, 0xEE, 0x70, 0x01, 0x10, 0x09, 0x18] + reversed + [0x56, 0x7B])
        guard let enc = aesCBCNoPad(container, key: Bytes.md5(Array(key[0..<16])), iv: Bytes.md5(Array(key[16...]))) else { return nil }
        return Data([0x3C, 0xCC] + enc).base64EncodedString()
    }

    static func aesCBCNoPad(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                         key, key.count, iv, input, input.count, &out, out.count, &moved)
        guard st == kCCSuccess else { return nil }
        return Array(out[0..<moved])
    }

    /// All signature headers. `nonce` must be 11 bytes: [0:2] Gorgon, [2:6] Ladon, [6:11] Argus.
    static func headers(rawQuery: String, stamp: Int64, nonce: [UInt8]) -> [String: String] {
        var h: [String: String] = [
            "X-Gorgon": xGorgon(rawQuery, stamp: stamp, nonce: nonce),
            "X-Khronos": String(stamp),
            "X-SS-Req-Ticket": String(stamp * 1000),
            "X-Ladon": ladon(stamp: stamp, prefix: Array(nonce[2..<6]))
        ]
        if let a = argus(rawQuery, stamp: stamp, nonce: nonce) { h["X-Argus"] = a }
        return h
    }
}

/// Official time-coded danmaku for one hongguo episode (`book_id` = seriesId, `group_id` = vid).
actor HGDanmakuClient {
    static let shared = HGDanmakuClient()

    private static let base = "https://api5-normal-sinfonlineb.fqnovel.com"
    private static let ua = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    private static let pageCount = 90
    private static let maxPages = 40
    static let maxItems = 3000
    private static let maxTextLen = 200
    private static let windowMs: Int64 = 3_600_000
    private static let maxWindowMs: Int64 = 24 * 3_600_000
    private static let maxEmptyPages = 2

    private let session: URLSession
    private var cache: [String: (Date, HGDanmakuResult)] = [:]
    private var pending: [String: Task<HGDanmakuResult, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        ProxySettings.shared.apply(to: cfg)
        session = URLSession(configuration: cfg)
    }

    /// The upstream assigns a danmaku subset per anonymous identity; keep one stable per install.
    private static func identity() -> (String, String) {
        let d = UserDefaults.standard
        if let a = d.string(forKey: "stv.danmaku.did"), let b = d.string(forKey: "stv.danmaku.iid"), a.count == 19, b.count == 19 { return (a, b) }
        let a = HGCommentSign.newDeviceId(), b = HGCommentSign.newDeviceId()
        d.set(a, forKey: "stv.danmaku.did"); d.set(b, forKey: "stv.danmaku.iid")
        return (a, b)
    }

    func fetch(seriesId: String, vid: String, fresh: Bool = false) async -> HGDanmakuResult {
        guard HongguoClient.looksSID(seriesId) || seriesId.allSatisfy(\.isNumber), !vid.isEmpty, vid.allSatisfy(\.isNumber) else {
            return HGDanmakuResult(items: [], error: "仅红果来源的剧集支持弹幕")
        }
        let key = seriesId + ":" + vid
        if !fresh, let (at, r) = cache[key], Date().timeIntervalSince(at) < (r.error.isEmpty ? 300 : 15) { return r }
        if let t = pending[key] { return await t.value }
        let t = Task { await Self.load(session: session, seriesId: seriesId, vid: vid) }
        pending[key] = t
        let r = await t.value
        pending[key] = nil
        cache[key] = (Date(), r)
        if cache.count > 64, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
        return r
    }

    private static func load(session: URLSession, seriesId: String, vid: String) async -> HGDanmakuResult {
        var collected: [HGDanmaku] = []
        var seen = Set<String>()
        var start: Int64 = 0
        var duration = windowMs
        var empty = 0
        var truncated = false
        var failure = ""
        for page in 0..<maxPages {
            if Task.isCancelled { break }
            if page > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
            let payload: [String: Any]
            do { payload = try await requestWindow(session: session, vid: vid, bookId: seriesId, start: start, duration: duration) }
            catch {
                failure = collected.isEmpty ? "弹幕接口暂不可用（已用官方签名请求），请稍后重试" : "后续弹幕加载中断，已保留已获取的部分"
                NSLog("[HG] danmaku page %d error: %@", page, String(describing: error))
                break
            }
            let p = parsePage(payload, vid: vid)
            if p.items.isEmpty { empty += 1 } else { empty = 0 }
            for var it in p.items {
                it.text = cleanControl(it.text)
                if it.text.isEmpty || it.text.count > maxTextLen { continue }
                let k = String(format: "%.3f|", it.time) + it.text
                if seen.contains(k) { continue }
                seen.insert(k)
                collected.append(it)
                if collected.count >= maxItems { break }
            }
            if collected.count >= maxItems { truncated = true; break }
            guard let next = p.nextMs else {
                if p.hasMore == true { truncated = true; if collected.isEmpty { failure = "弹幕接口未返回有效分页，请稍后重试" } }
                break
            }
            if next <= start || next > 604_800_000 || empty >= maxEmptyPages || page == maxPages - 1 {
                truncated = true
                if collected.isEmpty { failure = "弹幕接口未返回有效分页，请稍后重试" }
                break
            }
            start = next
            duration = min(max(duration, start + windowMs), maxWindowMs)
        }
        collected.sort { $0.time < $1.time }
        return HGDanmakuResult(items: collected, truncated: truncated, error: failure)
    }

    private static func requestWindow(session: URLSession, vid: String, bookId: String, start: Int64, duration: Int64) async throws -> [String: Any] {
        let now = Date()
        let stampMs = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = stampMs / 1000
        let nonce = Bytes.random(HGCommentSign.nonceBytes)
        let (did, iid) = identity()
        let q = HGCommentSign.buildQuery(stampMs: stampMs, deviceId: did, installId: iid)
        let path = "/novel/commentapi/comment/list/\(vid)/v1/"
        var req = URLRequest(url: URL(string: base + path + "?" + q)!)
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "comment_source": 601, "server_channel": 1000, "group_id": vid, "group_type": 30, "comment_type": 20,
            "sort": 1, "count": pageCount, "cursor": "", "aid": 8662, "compliance_status": 0,
            "business_param": ["book_id": bookId, "start_offset_time": start, "playlet_item_duration": duration,
                               "need_danmaku_guide_type": [1, 3, 4, 2]] as [String: Any]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
        req.setValue("2", forHTTPHeaderField: "Sdk-Version")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("601", forHTTPHeaderField: "Comment-Source")
        req.setValue("1000", forHTTPHeaderField: "Server-Channel")
        req.setValue("", forHTTPHeaderField: "X-SS-STUB")
        for (k, v) in HGCommentSign.headers(rawQuery: q, stamp: stamp, nonce: nonce) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProviderError.upstream("danmaku HTTP \(status)") }
        guard !data.isEmpty else { throw ProviderError.upstream("danmaku 空响应") }
        let j = try J.parse(data)
        guard J.str(j["code"]) == "0", J.dict(j["data"])["data_list"] is [Any] else {
            throw ProviderError.upstream("danmaku code=\(J.str(j["code"]))\(J.str(j["Code"])) \(J.str(j["message"]))")
        }
        return j
    }

    struct Page { var items: [HGDanmaku]; var nextMs: Int64?; var hasMore: Bool? }

    static func parsePage(_ payload: [String: Any], vid: String) -> Page {
        let data = J.dict(payload["data"])
        var nextMs: Int64? = nil
        var hasMore: Bool? = nil
        let extra = J.dict(data["extra"])
        let raw = J.str(extra["next_query_danmaku_list_time"]).trimmingCharacters(in: .whitespaces)
        if let v = Int64(raw) { nextMs = v }
        let info = J.dict(data["common_list_info"])
        if let flag = info["has_more"] {
            if let b = flag as? Bool { hasMore = b }
            else { let s = J.str(flag).lowercased(); if !s.isEmpty { hasMore = ["1", "true", "yes"].contains(s) } }
        }
        var cursor: [String: Any] = J.dict(info["cursor"])
        if cursor.isEmpty, let s = info["cursor"] as? String, s.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let d = s.data(using: .utf8), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cursor = m }
        for k in ["end_offset_time", "next_offset_time", "offset"] {
            guard let v = cursor[k] else { continue }
            let c = J.int64(v)
            if c == 0 && J.str(v) != "0" { continue }
            if nextMs == nil || c > nextMs! { nextMs = c }
            break
        }
        if hasMore == false { nextMs = nil }
        var items: [HGDanmaku] = []
        for r in J.arr(data["data_list"]) {
            let row = J.dict(r)
            let comment = J.dict(row["comment"])
            guard !comment.isEmpty else { continue }
            let common = J.dict(comment["common"])
            let gid = J.str(common["group_id"])
            if !gid.isEmpty && gid != vid { continue }
            if J.str(common["status"]) != "1" { continue }
            let content = J.dict(common["content"])
            let text = J.str(content["text"])
            let expand = J.dict(comment["expand"])
            let tRaw = expand["offset_time"] ?? comment["offset_time"]
            let ms = J.double(tRaw)
            guard let tRaw, !(tRaw is NSNull), !J.str(tRaw).isEmpty, ms >= 0, ms / 1000 <= 604_800 else { continue }
            var color = "#FFFFFF"
            outer: for holder in [content, common, expand, comment] {
                for k in ["color", "font_color", "text_color", "col"] where holder[k] != nil {
                    color = normalizeColor(holder[k]); break outer
                }
            }
            let likes = max(0, J.int(J.dict(comment["stat"])["digg_count"]))
            items.append(HGDanmaku(time: ms / 1000, text: text, likes: likes, color: color, mode: mode(row, comment)))
        }
        if let n = nextMs, n <= 0 { nextMs = nil }
        return Page(items: items, nextMs: nextMs, hasMore: hasMore)
    }

    static func normalizeColor(_ v: Any?) -> String {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let i = n.int64Value; if i < 0 { return "#FFFFFF" }
            return String(format: "#%06X", i & 0xFFFFFF)
        }
        guard var s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "#FFFFFF" }
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            if s.count == 6, UInt32(s, radix: 16) != nil { return "#" + s.uppercased() }
            return "#FFFFFF"
        }
        if s.lowercased().hasPrefix("0x"), let i = UInt64(s.dropFirst(2), radix: 16) { return String(format: "#%06X", i & 0xFFFFFF) }
        if let i = UInt64(s) { return String(format: "#%06X", i & 0xFFFFFF) }
        return "#FFFFFF"
    }

    private static func mode(_ holders: [String: Any]...) -> HGDanmaku.Mode {
        for h in holders {
            for k in ["mode", "danmaku_type", "position", "fix_type", "danmaku_position"] {
                guard let v = h[k] else { continue }
                let t = J.str(v).lowercased()
                if ["top", "2", "fix_top", "顶部"].contains(t) { return .top }
                if ["bottom", "3", "fix_bottom", "底部"].contains(t) { return .bottom }
            }
        }
        return .scroll
    }

    static func cleanControl(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (u.value < 0x20 || u.value == 0x7F || u.value == 0x2028 || u.value == 0x2029) ? " " : u
        })).trimmingCharacters(in: .whitespaces)
    }
}

enum DanmakuText {
    /// Hongguo inline emoticon codes → emoji; unknown codes are kept verbatim.
    private static let emoji: [String: String] = [
        "笑哭": "😂", "偷笑": "🤭", "爱慕": "😍", "捂脸": "🤦", "送心": "💗", "鼓掌": "👏", "害羞": "😊", "大哭": "😭",
        "呲牙": "😁", "微笑": "🙂", "机智": "🤓", "赞": "👍", "点赞": "👍", "比心": "🫶", "爱心": "❤️", "心": "❤️",
        "流泪": "😢", "哭": "😢", "可怜": "🥺", "生气": "😠", "发怒": "😡", "惊讶": "😮", "震惊": "😱", "疑问": "❓",
        "思考": "🤔", "无语": "😑", "白眼": "🙄", "坏笑": "😏", "得意": "😎", "酷": "😎", "憨笑": "😄", "大笑": "😆",
        "笑": "😄", "开心": "😄", "亲亲": "😘", "飞吻": "😘", "色": "😍", "晕": "😵", "抓狂": "😫", "吐血": "🤮",
        "打脸": "🤕", "抱抱": "🤗", "拥抱": "🤗", "握手": "🤝", "加油": "💪", "强": "💪", "玫瑰": "🌹", "花": "🌸",
        "666": "6️⃣6️⃣6️⃣", "OK": "👌", "ok": "👌", "耶": "✌️", "吃瓜": "🍉", "狗头": "🐶", "火": "🔥", "灵机一动": "💡",
        "尴尬": "😅", "汗": "😓", "擦汗": "😓", "困": "😪", "睡": "😴", "再见": "👋", "拜拜": "👋", "鄙视": "😒",
        "委屈": "🥺", "难过": "😞", "撇嘴": "😕", "调皮": "😜", "吐舌": "😛", "奸笑": "😏", "皱眉": "😣", "泪奔": "😭"
    ]
    static func display(_ s: String) -> String {
        guard s.contains("[") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "]"), rest.distance(from: open, to: close) <= 7 else {
                out += rest[open...]; return out
            }
            let code = String(rest[rest.index(after: open)..<close])
            out += emoji[code] ?? "[\(code)]"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Merge duplicate / near-duplicate comments that land close together ("哈哈哈哈" ×12 → one bubble).
enum DanmakuMerger {
    /// Collapse runs of the same character to at most 2, drop whitespace / punctuation, lowercase.
    static func normalize(_ s: String) -> String {
        var out: [Character] = []
        let stripped = s.replacingOccurrences(of: #"\[[^\[\]]{1,6}\]"#, with: "", options: .regularExpression)
        for ch in stripped.lowercased() {
            if ch.isWhitespace || ch.isPunctuation || ch.isSymbol { continue }
            if out.count >= 2, out[out.count - 1] == ch, out[out.count - 2] == ch { continue }
            out.append(ch)
        }
        return String(out)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let c = Array(s)
        guard c.count >= 2 else { return [s] }
        var set = Set<String>()
        for i in 0..<(c.count - 1) { set.insert(String(c[i...i + 1])) }
        return set
    }

    private static func similar(_ a: String, _ b: String, _ ga: Set<String>, _ gb: Set<String>) -> Bool {
        if a == b { return true }
        let short = min(a.count, b.count)
        guard short >= 4 else { return false }
        if a.contains(b) || b.contains(a) { return Double(short) / Double(max(a.count, b.count)) >= 0.75 }
        let inter = ga.intersection(gb).count
        let uni = ga.union(gb).count
        return uni > 0 && Double(inter) / Double(uni) >= 0.8
    }

    /// `window`: seconds a group stays open after its first comment.
    static func merge(_ items: [HGDanmaku], window: Double = 12) -> [HGDanmaku] {
        struct Group { var item: HGDanmaku; var key: String; var grams: Set<String>; var best: Int }
        var open: [Group] = []
        var out: [HGDanmaku] = []
        func close(_ g: Group) { out.append(g.item) }
        for it in items.sorted(by: { $0.time < $1.time }) {
            // retire groups whose window has passed
            var keep: [Group] = []
            for g in open { if it.time - g.item.time > window { close(g) } else { keep.append(g) } }
            open = keep
            let key = normalize(it.text)
            if key.isEmpty { out.append(it); continue }
            let grams = bigrams(key)
            if let i = open.firstIndex(where: { similar($0.key, key, $0.grams, grams) }) {
                open[i].item.count += it.count
                open[i].item.likes += it.likes
                if it.likes > open[i].best { open[i].best = it.likes; open[i].item.text = it.text; open[i].item.color = it.color }
                continue
            }
            open.append(Group(item: it, key: key, grams: grams, best: it.likes))
        }
        open.forEach(close)
        return out.sorted { $0.time < $1.time }
    }
}
