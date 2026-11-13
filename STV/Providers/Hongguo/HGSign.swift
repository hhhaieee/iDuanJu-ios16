import Foundation

/// Pure-Swift ports of gateway/internal/provider/hongguo sign.go, sign_helios_ladon.go,
/// video_model.go (signVideoModelRequest) and spade.go (Unwrap / downloadContentKey).
enum HGSign {
    // MARK: X-Gorgon (sign.go)
    private static func nibbleSwap(_ b: UInt8) -> UInt8 { (b & 0x0f) << 4 | (b >> 4) & 0x0f }
    private static func bitReverse(_ b: UInt8) -> UInt8 {
        var r: UInt8 = 0; for i in 0..<8 where (b & (1 << i)) != 0 { r |= 1 << (7 - i) }; return r
    }
    private static func brokenRC4(_ key: [UInt8], _ n: Int) -> [UInt8] {
        var S = Array(0..<256)
        var j = 0
        for i in 0..<256 { j = (j + S[i] + Int(key[i & 7])) & 0xff; S[i] = S[j] }
        var i = 0, jj = 0
        var out = [UInt8]()
        for _ in 0..<n {
            i = (i + 1) & 0xff
            jj = (jj + S[i]) & 0xff
            let v = S[jj]
            S[i] = v
            out.append(UInt8(S[(S[i] + v) & 0xff] & 0xff))
        }
        return out
    }
    private static func gorgon20(_ seed: [UInt8]) -> [UInt8] {
        var buf = seed
        for n in 0..<min(20, buf.count) {
            buf[n] = nibbleSwap(buf[n])
            let x = buf[n] ^ buf[(n + 1) % 20]
            buf[n] = 0x14 ^ (~bitReverse(x))
        }
        return buf
    }

    static func xGorgon(params: String, ts: Int64, variant v: Int? = nil, body: [UInt8]? = nil, flags: UInt16 = 0x4481) -> String {
        let variant = v ?? (((Int.random(in: 0..<16) << 12) | Int.random(in: 0..<256)) & 0xffff)
        let chunkX: [UInt8] = (body?.isEmpty == false) ? Array(Bytes.md5(body!)[0..<4]) : [0, 0, 0, 0]
        var concat = Array(Bytes.md5(params)[0..<4]) + chunkX + [0, 0, 0, 0] + [0x00, 0x03, 0x0a, 0x04]
        concat += Bytes.u32BE(UInt32(truncatingIfNeeded: ts))
        let fh = UInt8(flags >> 8), fl = UInt8(flags & 0xff)
        let key: [UInt8] = [0x4a, fh, 0x16, UInt8(variant & 0xff), 0x47, 0x6c, fl, UInt8(variant >> 8)]
        let ks = brokenRC4(key, 20)
        let xored = (0..<20).map { concat[$0] ^ ks[$0] }
        let head: [UInt8] = [0x84, 0x04, UInt8(variant >> 8), UInt8(variant & 0xff), fh, fl]
        return Bytes.hex(head + gorgon20(xored))
    }

    static func xArgus(_ ts: Int64) -> String { Data(Bytes.u32LE(UInt32(truncatingIfNeeded: ts))).base64EncodedString() }

    /// X-Khronos / X-Gorgon / X-Argus (device_register uses this set).
    static func basicHeaders(params: String, body: [UInt8]?) -> [String: String] {
        let ts = Int64(Date().timeIntervalSince1970)
        return ["X-Khronos": String(ts), "X-Gorgon": xGorgon(params: params, ts: ts, body: body), "X-Argus": xArgus(ts)]
    }

    // MARK: X-Helios / X-Ladon (sign_helios_ladon.go)
    private static func ror64(_ v: UInt64, _ c: UInt64) -> UInt64 { let c = c & 63; return (v >> c) | (v << ((64 - c) & 63)) }

    private static func heliosTable(_ md5hex: [UInt8]) -> [UInt8] {
        var ht = [UInt8](repeating: 0, count: 288)
        for i in 0..<32 { ht[i] = md5hex[i] }
        var temp: [UInt64] = (0..<4).map { Bytes.readU64LE(ht, $0 * 8) }
        var b0 = temp[0], b8 = temp[1]
        temp.removeFirst(2)
        for i in UInt64(0)..<0x22 {
            let x9 = b0
            var x8 = ror64(b8, 8) &+ x9
            x8 ^= i
            temp.append(x8)
            x8 ^= ror64(x9, 61)
            Bytes.writeU64LE(x8, into: &ht, at: Int(i + 1) * 8)
            b0 = x8
            b8 = temp.removeFirst()
        }
        return ht
    }

    private static func heliosBlock(_ ht: [UInt8], _ blk: ArraySlice<UInt8>) -> [UInt8] {
        let a = Array(blk)
        var d0 = Bytes.readU64LE(a, 0), d1 = Bytes.readU64LE(a, 8)
        for i in 0..<0x22 {
            let h = Bytes.readU64LE(ht, i * 8)
            d1 = h ^ (d0 &+ ror64(d1, 8))
            d0 = d1 ^ ror64(d0, 0x3d)
        }
        var out = [UInt8](repeating: 0, count: 16)
        Bytes.writeU64LE(d0, into: &out, at: 0); Bytes.writeU64LE(d1, into: &out, at: 8)
        return out
    }

    static func heliosToken(khronos: Int64, r4: [UInt8]? = nil) -> String {
        let r = r4 ?? Bytes.random(4)
        let md5hex = Array(Bytes.hex(Bytes.md5(r + Array("8662".utf8))).utf8)
        let ht = heliosTable(md5hex)
        var data = Array("\(khronos)-1611921764-3019".utf8)
        let pad = 16 - data.count % 16
        data += [UInt8](repeating: UInt8(pad), count: pad)
        var body = [UInt8]()
        var i = 0
        while i < data.count { body += heliosBlock(ht, data[i..<i + 16]); i += 16 }
        return Data(r + body.prefix(32)).base64EncodedString()
    }

    /// Full 6-header set for search/tab (sign_pure.go pureSignHeadersPB with plain PB).
    static func fullHeaders(rawURL: String, device: HGDevice) throws -> [String: String] {
        let headTS = Int64(Date().timeIntervalSince1970)
        let khronos = headTS ^ 4
        let params = rawURL.firstIndex(of: "?").map { String(rawURL[rawURL.index(after: $0)...]) } ?? ""
        let pb = Medusa.buildPlainPB(rawURL: rawURL, unix: headTS, entropy: device.entropy)
        let pkt = try Medusa.mint(headTS: headTS, pb: pb)
        return [
            "X-Khronos": String(khronos),
            "X-Helios": heliosToken(khronos: khronos),
            "X-Ladon": heliosToken(khronos: khronos),
            "X-Medusa": Data(pkt).base64EncodedString(),
            "X-Argus": xArgus(khronos),
            "X-Gorgon": xGorgon(params: params, ts: khronos)
        ]
    }


    /// Gateway `signGenericRequest` (7.3.6.32 session): X-Gorgon flags 0x0000 + X-Argus.
    /// Used for AB-off batch endpoint `multi_video_model/v1`. Pass flags: 0 literally (not 0x4481 default).
    static func genericSessionHeaders(rawQuery: String, body: [UInt8], now: Date) -> [String: String] {
        let ts = Int64(now.timeIntervalSince1970)
        let stub = Bytes.hex(Bytes.md5(body)).uppercased()
        return [
            "X-Gorgon": xGorgon(params: rawQuery, ts: ts, body: body, flags: 0),
            "X-Khronos": String(ts),
            "X-Argus": xArgus(ts),
            "X-SS-STUB": stub,
            "X-SS-Req-Ticket": String(Int64(now.timeIntervalSince1970 * 1000))
        ]
    }

    // MARK: video_model/v1 signature (8404401c)
    static func videoModelHeaders(rawQuery: String, body: [UInt8], now: Date) -> [String: String] {
        let ts = UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970))
        let qh = Bytes.md5(rawQuery), bh = Bytes.md5(body)
        var p = [UInt8](repeating: 0, count: 20)
        for i in 0..<4 { p[i] = qh[i]; p[4 + i] = bh[i] }
        p[12] = 0; p[13] = 6; p[14] = 11; p[15] = 28
        let tsb = Bytes.u32BE(ts); for i in 0..<4 { p[16 + i] = tsb[i] }
        let key: [UInt8] = [0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f]
        for i in 0..<20 { p[i] ^= key[i] }
        for i in 0..<20 {
            let rot = (p[i] << 4) | (p[i] >> 4)
            let mixed = rot ^ p[(i + 1) % 20]
            p[i] = bitReverse(mixed) ^ 0xff ^ 20
        }
        return [
            "X-Gorgon": Bytes.hex([0x84, 0x04, 0x40, 0x1c, 0, 0] + p),
            "X-Khronos": String(ts),
            "X-SS-STUB": Bytes.hex(bh).uppercased(),
            "X-SS-Req-Ticket": String(Int64(now.timeIntervalSince1970 * 1000))
        ]
    }

    // MARK: spade_a envelope → 32-hex content key (spade.go)
    private static func popcount(_ x: Int) -> Int { x.nonzeroBitCount }

    private static func transformNonmagic(_ a: [UInt8], _ mode: Int) -> [UInt8] {
        var w11: UInt8 = 0x55, w12: UInt8 = 0xfa
        var out = [UInt8]()
        for (i, c) in a.enumerated() {
            let x: UInt8
            if i % 2 == 0 { x = w12; w12 = c } else { x = w11; w11 = c }
            let pc = popcount(i)
            let delta = mode != 0 ? pc + 0x15 : -0x15 - pc
            out.append(UInt8(truncatingIfNeeded: (Int(x ^ c) + delta) & 0xff))
        }
        return out
    }

    private static func transformMagic(_ a: [UInt8], _ mode: Int) -> [UInt8] {
        func swap(_ b: [UInt8]) -> [UInt8] {
            var b = b; var i = 0
            while i + 1 < b.count { b.swapAt(i, i + 1); i += 2 }
            return b
        }
        let s = swap(a)
        var w12: UInt8 = 0x55, w13: UInt8 = 0xfa
        var out = [UInt8]()
        for (i, c) in s.enumerated() {
            let x: UInt8, y: UInt8
            if i % 2 == 0 { x = w13; y = w12; w13 = c } else { x = w12; y = w13; w12 = c }
            let pc = popcount(i)
            let delta = mode != 0 ? pc + 0x15 : -0x15 - pc
            out.append(UInt8(truncatingIfNeeded: (Int(x ^ c) - Int(y) + delta) & 0xff))
        }
        return swap(out)
    }

    private static func hexval(_ ch: UInt8) -> Int {
        if ch >= 0x30 && ch <= 0x39 { return Int(ch) - 0x30 }
        if ch >= 0x61 && ch <= 0x66 { return Int(ch) - 0x57 }
        return -1
    }

    static func unwrap(_ spade: [UInt8], mode: Int = 0) -> String? {
        let ln = spade.count
        guard ln >= 4 else { return nil }
        let v = Int(spade[0] ^ spade[1] ^ spade[2])
        let hdr = v - 0x30
        guard hdr >= 1 else { return nil }
        let w22 = ln - v + 0x2f
        guard w22 >= 1, 1 + w22 <= ln else { return nil }
        let a = Array(spade[1..<1 + w22])
        let si = ln - hdr - 2
        guard si >= 0, si + 1 < ln, ln - hdr >= 0 else { return nil }
        let seed = spade[si] ^ spade[si + 1]
        let buf = (0..<hdr).map { seed ^ spade[ln - hdr + $0] }
        let magic = buf.count >= 6 && ["app_v2", "web_v2"].contains(String(decoding: buf[0..<6], as: UTF8.self))
        let a2 = magic ? transformMagic(a, mode) : transformNonmagic(a, mode)
        guard !a2.isEmpty else { return nil }
        let hv = hexval(a2[0])
        guard hv >= 0 else { return nil }
        let remaining = w22 - hv
        guard remaining >= 2, remaining <= a2.count else { return nil }
        return String(decoding: a2[1..<remaining], as: UTF8.self)
    }

    static func contentKey(envelope: String) -> String? {
        let t = envelope.trimmingCharacters(in: .whitespacesAndNewlines)
        var cands: [[UInt8]] = []
        var b64 = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        if let d = Data(base64Encoded: b64) { cands.append(Array(d)) }
        if let h = Bytes.fromHex(t) { cands.append(h) }
        for raw in cands {
            if let k = unwrap(raw), let kb = Bytes.fromHex(k), kb.count == 16 { return k.lowercased() }
        }
        return nil
    }


}
