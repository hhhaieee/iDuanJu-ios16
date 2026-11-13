import Foundation

/// Pure-Swift port of gateway/internal/provider/hongguo/medusa (X-Medusa minting).
/// Transform tables are the gateway's embedded tables.bin, bundled as Resources/medusa_tables.bin.
enum Medusa {
    // MARK: SM3
    private static let sm3IV: [UInt32] = [0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600, 0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E]
    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { let n = n & 31; return n == 0 ? x : (x << n) | (x >> (32 - n)) }
    private static func p0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
    private static func p1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }

    static func sm3(_ data: [UInt8]) -> [UInt8] {
        var v = sm3IV
        var buf = data + [0x80]
        while buf.count % 64 != 56 { buf.append(0) }
        let bitLen = UInt64(data.count) * 8
        for i in (0..<8).reversed() { buf.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var off = 0
        while off < buf.count {
            var w = [UInt32](repeating: 0, count: 68)
            for i in 0..<16 {
                let o = off + i * 4
                w[i] = UInt32(buf[o]) << 24 | UInt32(buf[o + 1]) << 16 | UInt32(buf[o + 2]) << 8 | UInt32(buf[o + 3])
            }
            for j in 16..<68 { w[j] = p1(w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) ^ rotl(w[j - 13], 7) ^ w[j - 6] }
            var w1 = [UInt32](repeating: 0, count: 64)
            for j in 0..<64 { w1[j] = w[j] ^ w[j + 4] }
            var a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7]
            for j in 0..<64 {
                let tj: UInt32 = j < 16 ? 0x79CC4519 : 0x7A879D8A
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(tj, UInt32(j)), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c))
                let gg = j < 16 ? (e ^ f ^ g) : ((e & f) | (~e & g))
                let tt1 = ff &+ d &+ ss2 &+ w1[j]
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e; e = p0(tt2)
            }
            v = [v[0] ^ a, v[1] ^ b, v[2] ^ c, v[3] ^ d, v[4] ^ e, v[5] ^ f, v[6] ^ g, v[7] ^ h]
            off += 64
        }
        return v.flatMap { Bytes.u32BE($0) }
    }

    // MARK: bionic random()
    private static func randomSeq(_ seedIn: UInt32, _ n: Int) -> [UInt32] {
        var state = [UInt32](repeating: 0, count: 31)
        var seed = seedIn == 0 ? 1 : seedIn
        state[0] = seed
        for i in 1..<31 {
            let hi = seed / 127773, lo = seed % 127773
            let t = Int64(16807) * Int64(lo) - Int64(2836) * Int64(hi)
            seed = UInt32(truncatingIfNeeded: t)
            if seed & 0x8000_0000 != 0 { seed = seed &+ 0x7FFF_FFFF }
            state[i] = seed
        }
        var f = 3, r = 0
        func next() -> UInt32 {
            let val = state[f] &+ state[r]
            state[f] = val
            f = (f + 1) % 31; r = (r + 1) % 31
            return (val >> 1) & 0x7FFF_FFFF
        }
        for _ in 0..<310 { _ = next() }
        return (0..<n).map { _ in next() }
    }

    private static func t4AndU32(_ seed: UInt32) -> ([UInt8], UInt32) {
        let s = randomSeq(seed, 7)
        return (Bytes.u32LE(s[5]), s[6])
    }

    // MARK: protobuf builder
    private static let headC: [UInt8] = [0x16, 0x6f, 0x80, 0x75, 0xe2, 0x85, 0xb2, 0x36, 0xbc, 0xeb, 0x84, 0xca, 0x26, 0xcb, 0x43, 0xe8]
    private static let notset = "!notset!"
    private static let tscLike: UInt64 = 1388734
    private static let sentinel: UInt64 = 1999997

    private static func varint(_ d: inout [UInt8], _ n: UInt64) {
        var n = n
        while n > 0x7f { d.append(UInt8(n & 0x7f) | 0x80); n >>= 7 }
        d.append(UInt8(n))
    }
    private static func tagV(_ d: inout [UInt8], _ f: Int, _ v: UInt64) { varint(&d, UInt64(f << 3)); varint(&d, v) }
    private static func tagB(_ d: inout [UInt8], _ f: Int, _ b: [UInt8]) { varint(&d, UInt64(f << 3) | 2); varint(&d, UInt64(b.count)); d += b }
    private static func tagS(_ d: inout [UInt8], _ f: Int, _ s: String) { tagB(&d, f, Array(s.utf8)) }
    private static func tagF32(_ d: inout [UInt8], _ f: Int, _ b: [UInt8]) { varint(&d, UInt64(f << 3) | 5); d += b }

    private static func deviceInner() -> [UInt8] {
        var d = [UInt8]()
        tagV(&d, 1, 2); tagS(&d, 3, "3019"); tagS(&d, 5, notset); tagS(&d, 6, notset)
        for f in 7...10 { tagV(&d, f, sentinel) }
        tagS(&d, 11, notset); tagS(&d, 12, notset); tagS(&d, 13, notset)
        tagV(&d, 14, sentinel); tagS(&d, 15, notset)
        for f in 16...21 { tagF32(&d, f, [0xf0, 0x23, 0x74, 0xc9]) }
        tagS(&d, 22, notset)
        for f in [23, 24, 25, 27] { tagV(&d, f, sentinel) }
        tagV(&d, 28, 3578012222180); tagV(&d, 29, sentinel)
        for f in 30...37 { tagS(&d, f, notset) }
        tagV(&d, 38, sentinel)
        tagV(&d, 40, 3578012218524)
        return d
    }

    private static func f23(_ f1: UInt64) -> [UInt8] {
        var d = [UInt8]()
        tagV(&d, 1, f1); tagV(&d, 2, tscLike); tagV(&d, 3, tscLike); tagV(&d, 7, 12216)
        tagB(&d, 12, deviceInner()); tagB(&d, 13, []); tagS(&d, 14, notset)
        tagV(&d, 15, 12216); tagV(&d, 18, 5248703274); tagV(&d, 19, 3578012186); tagV(&d, 20, 4045878586)
        tagV(&d, 22, tscLike)
        return d
    }

    static func buildPlainPB(rawURL: String, unix: Int64, entropy: [UInt8]) -> [UInt8] {
        let seed = UInt64(UInt32(truncatingIfNeeded: unix ^ 4))
        let f12 = (2 * seed) & 0xFFFF_FFFF
        let f23f1 = (2 &* seed &- tscLike) & 0xFFFF_FFFF
        let query = rawURL.firstIndex(of: "?").map { String(rawURL[rawURL.index(after: $0)...]) } ?? ""
        let f14 = Array(sm3(Array(query.utf8)).prefix(6))
        var f1 = headC; for i in stride(from: 0, to: 16, by: 4) { f1[i] ^= 0x04 }
        var f15 = [UInt8](); tagV(&f15, 1, 2); for f in 2...5 { tagV(&f15, f, tscLike) }
        var d = [UInt8]()
        tagB(&d, 1, f1); tagV(&d, 2, 8); tagV(&d, 3, 504419796); tagS(&d, 4, "3019")
        tagS(&d, 6, "1611921764"); tagS(&d, 7, "6.8.1.32"); tagS(&d, 8, "v04.07.01-ml-android")
        tagV(&d, 9, 135135744); tagB(&d, 10, [UInt8](repeating: 0, count: 8))
        tagV(&d, 12, f12); tagB(&d, 13, entropy); tagB(&d, 14, f14); tagB(&d, 15, f15)
        tagS(&d, 20, "none"); tagV(&d, 21, 738); tagB(&d, 23, f23(f23f1))
        tagS(&d, 24, #"{"cmr":16777216,"cmr2":16777216,"un_h":0,"vpn":0,"kd":694367,"fkd":2980190854,"pd":539550637,"dyn":"","do":0,"tk":true}"#)
        return d
    }

    private static func readVarint(_ b: [UInt8], _ at: Int) throws -> (UInt64, Int) {
        var v: UInt64 = 0, s: UInt64 = 0
        for n in 0..<10 {
            guard at + n < b.count else { throw ProviderError.invalid("pb varint") }
            let c = b[at + n]
            v |= UInt64(c & 0x7f) << s
            if c < 0x80 { return (v, n + 1) }
            s += 7
        }
        throw ProviderError.invalid("pb varint overflow")
    }

    private static func midFromPB(_ pb: [UInt8]) throws -> UInt16 {
        var f13: UInt8?, f14: UInt8?
        var i = 0
        while i < pb.count {
            let (key, n) = try readVarint(pb, i); i += n
            let fn = Int(key >> 3), wt = Int(key & 7)
            switch wt {
            case 0: let (_, n2) = try readVarint(pb, i); i += n2
            case 2:
                let (ln, n2) = try readVarint(pb, i); i += n2
                if ln > 0 { if fn == 13 { f13 = pb[i] } else if fn == 14 { f14 = pb[i] } }
                i += Int(ln)
            case 5: i += 4
            case 1: i += 8
            default: throw ProviderError.invalid("pb wire")
            }
            if let a = f13, let b = f14 { return UInt16((Int(a) & 0x3f) | ((Int(b) & 0x3f) << 6)) }
        }
        throw ProviderError.invalid("pb missing f13/f14")
    }

    // MARK: ks.go
    private static let ksSeed: [UInt8] = [0xac, 0x1a, 0xda, 0xae, 0x95, 0xa7, 0xaf, 0x94, 0xa5, 0x11, 0x4a, 0xb3, 0xb3, 0xa9, 0x7d, 0xd8,
                                          0x00, 0x50, 0xaa, 0x0a, 0x39, 0x31, 0x4c, 0x40, 0x52, 0x8c, 0xae, 0xc9, 0x52, 0x56, 0xc2, 0x8c]
    private static func eon(_ a: UInt32, _ b: UInt32) -> UInt32 { ~(a ^ b) }

    private static func ksTransform(_ pb: [UInt8], _ sbox: [UInt8]) -> [UInt8] {
        let n = pb.count
        var b = [UInt8](repeating: 0x20, count: n)
        for i in 0..<n {
            let x = UInt32(pb[i])
            let sa = UInt32(sbox[(i << 2) % 32]), sb = UInt32(sbox[((i << 2) | 1) % 32])
            let t = ((x >> 4) & ~UInt32(0xff0)) | (x << 4)
            let w10 = eon(t &+ sa, sb)
            let rol3 = ((w10 << 3) & 0xFFFF_FFF8) | ((w10 >> 5) & 7)
            let w14 = eon(sa, rol3 &+ sb)
            b[n - 1 - i] = UInt8(truncatingIfNeeded: w14)
        }
        let last = b[n - 1], prev = b[n - 2]
        let new0 = UInt8(truncatingIfNeeded: UInt32(b[0]) &+ eon(UInt32(last), UInt32(prev)))
        let new1 = UInt8(truncatingIfNeeded: (UInt32(new0) ^ UInt32(last) ^ 0xfe) &+ UInt32(b[1]))
        b[0] = new0; b[1] = new1
        if n > 3 {
            for j in 2..<(n - 1) {
                let p = UInt32(b[j - 1])
                let rot = ((p >> 5) & 7) | (p << 3)
                let w17 = eon(UInt32(b[j - 2]) ^ rot, UInt32(j))
                b[j] = UInt8(truncatingIfNeeded: UInt32(b[j]) &+ w17)
            }
        }
        b[n - 1] ^= b[n - 2]
        var add0 = 0
        for x in b[1...] { add0 += Int(x) }
        b[0] = UInt8(truncatingIfNeeded: UInt32(b[0] ^ b[1]) &+ UInt32(add0 & 0xff))
        return b
    }

    private static func pureA(_ pb: [UInt8], _ t4: [UInt8]) -> [UInt8] {
        let sbox = sm3(ksSeed + Array(t4.prefix(4)) + ksSeed)
        let t2 = UInt32(t4[2]), t3 = UInt32(t4[3])
        let reg = ~(((t2 << 11) | t3) ^ t2 ^ (t2 >> 5))
        let buf4 = Bytes.u32BE(reg)
        let body = ksTransform(pb, sbox)
        let stream = [UInt8](repeating: 0, count: 8) + body
        let last = stream.count - 1
        return (0..<stream.count).map { i in buf4[i % 4] ^ stream[last - i] }
    }

    // MARK: packet.go
    private static let lane: [UInt8] = [1, 7, 2, 6, 3, 4, 0, 5]

    private static func extract32(_ buf: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for w in 0..<31 {
            var v: UInt8 = 0
            for j in 0..<8 { let i = 8 * w + j; v |= ((buf[i] >> lane[i % 8]) & 1) << j }
            out[w] = v
        }
        return out
    }

    private static func applyPatch(_ buf: [UInt8], _ aes32: [UInt8]) -> [UInt8] {
        var out = buf
        let n = min(out.count, 248)
        for w in 0..<31 {
            let b = aes32[w]
            for j in 0..<8 {
                let i = 8 * w + j
                if i >= n { break }
                let bit = (b >> j) & 1
                let mask: UInt8 = 1 << lane[j]
                out[i] = (out[i] & ~mask) | (bit << lane[j])
            }
        }
        return out
    }

    static func mint(headTS: Int64, pb: [UInt8]) throws -> [UInt8] {
        let tabs = try Tables.shared()
        let ts = UInt32(truncatingIfNeeded: headTS)
        let seed = UInt32(truncatingIfNeeded: headTS ^ 4)
        let tab = Int(ts & 3)
        let (t4, u32) = t4AndU32(seed)
        let mid = try midFromPB(pb)
        let seed8 = Bytes.u32LE(u32) + [0x01, UInt8(mid & 0xff), UInt8(mid >> 8), 0x18]
        let a = pureA(pb, t4)
        let pre: [UInt8] = [0xA6] + seed8 + a + [t4[2], t4[3]]
        guard pre.count >= 248 else { throw ProviderError.invalid("medusa body short") }
        let aes32 = try tabs.transform32(extract32(Array(pre[0..<248])), tab)
        let body = applyPatch(pre, aes32)
        var head = Bytes.u32LE(ts)
        for i in 0..<16 { head.append(headC[i] ^ head[i % 4]) }
        return head + [t4[0], t4[1]] + [0x00, 0x01, aes32[31]] + body
    }

    // MARK: tables.go / transform.go
    final class Matrix {
        let name: String; let parts: [String]; let rows: Int; let cols: Int; let words: Int
        let bits: [[UInt64]]
        init(name: String, parts: [String], rows: Int, cols: Int, words: Int, bits: [[UInt64]]) {
            self.name = name; self.parts = parts; self.rows = rows; self.cols = cols; self.words = words; self.bits = bits
        }
        func apply(_ parts: [[UInt8]]) throws -> [UInt8] {
            var feat: [UInt8] = parts.flatMap { $0 } + [UInt8(0x01)]
            guard feat.count == (rows + 7) / 8 else { throw ProviderError.invalid("\(name) feat \(feat.count)") }
            var wv = [UInt64](repeating: 0, count: words)
            feat += [UInt8](repeating: 0, count: words * 8)
            for w in 0..<words { wv[w] = Bytes.readU64LE(feat, w * 8) }
            var out = [UInt8](repeating: 0, count: (cols + 7) / 8)
            for j in 0..<cols {
                var p = 0
                for (w, cw) in bits[j].enumerated() { p ^= (wv[w] & cw).nonzeroBitCount }
                if p & 1 != 0 { out[j / 8] |= 1 << (j % 8) }
            }
            return out
        }
    }

    final class Tab {
        var id = 0, half = false
        var base: [UInt8] = [], sbox: [UInt8] = []
        var mat: [String: Matrix] = [:]
        var r1Rest = "", r3Rest = ""
        var outSrc: [UInt8] = [], outP: [[UInt8]] = [], outM: [UInt8] = []
        func m(_ n: String) throws -> Matrix { guard let x = mat[n] else { throw ProviderError.invalid("tab \(id) missing \(n)") }; return x }
    }

    final class Tables {
        private static var cached: Tables?
        static var overrideURL: URL?
        private static let lock = NSLock()
        var tabs: [Tab] = []

        static func shared() throws -> Tables {
            lock.lock(); defer { lock.unlock() }
            if let c = cached { return c }
            guard let url = overrideURL ?? Bundle.main.url(forResource: "medusa_tables", withExtension: "bin"),
                  let data = try? Data(contentsOf: url) else { throw ProviderError.invalid("medusa_tables.bin 缺失") }
            let t = try Tables(Array(data))
            cached = t
            return t
        }

        init(_ raw: [UInt8]) throws {
            guard raw.count >= 12, String(decoding: raw[0..<8], as: UTF8.self) == "HGMDTF02" else { throw ProviderError.invalid("tables magic") }
            var c = 10
            func u8() -> Int { let v = Int(raw[c]); c += 1; return v }
            func u16() -> Int { let v = Int(raw[c]) | Int(raw[c + 1]) << 8; c += 2; return v }
            func bytes(_ n: Int) -> [UInt8] { let v = Array(raw[c..<c + n]); c += n; return v }
            func pstr() -> String { let n = u8(); return String(decoding: bytes(n), as: UTF8.self) }
            let n = u16()
            var arr = [Tab?](repeating: nil, count: 4)
            for _ in 0..<n {
                let t = Tab()
                t.id = u8(); t.half = u8() == 1
                t.base = bytes(16); t.sbox = bytes(256)
                let nm = u8()
                for _ in 0..<nm {
                    let name = pstr()
                    let np = u8()
                    let parts = (0..<np).map { _ in pstr() }
                    let rows = u16(), cols = u16(), words = u16()
                    var bits = [[UInt64]]()
                    for _ in 0..<cols {
                        var col = [UInt64]()
                        for _ in 0..<words { col.append(Bytes.readU64LE(raw, c)); c += 8 }
                        bits.append(col)
                    }
                    t.mat[name] = Matrix(name: name, parts: parts, rows: rows, cols: cols, words: words, bits: bits)
                }
                t.r1Rest = pstr(); t.r3Rest = pstr()
                for _ in 0..<4 { _ = pstr() }
                if t.half {
                    t.outSrc = bytes(32)
                    let perm = bytes(256)
                    t.outP = (0..<32).map { Array(perm[$0 * 8..<($0 + 1) * 8]) }
                    t.outM = bytes(32)
                }
                guard t.id >= 0 && t.id < 4 else { throw ProviderError.invalid("tab id") }
                arr[t.id] = t
            }
            tabs = try arr.map { guard let t = $0 else { throw ProviderError.invalid("missing tab") }; return t }
        }

        private static let bitPerm = [5, 4, 0, 2, 1, 6, 3, 7]
        private static let identPerm = [0, 1, 2, 3, 4, 5, 6, 7]
        private static let r0Wire = [(0, 8), (1, 12), (4, 9), (5, 13), (8, 10), (9, 14), (12, 11), (13, 15)]
        private static let in1Idx = [2, 3, 6, 7, 10, 11, 14, 15]
        private static let outLO: [(Int, Int, UInt8, Bool)] = [
            (1, 8, 149, false), (1, 14, 243, false), (2, 3, 237, false), (2, 5, 55, false),
            (1, 9, 162, false), (1, 15, 208, false), (2, 0, 170, false), (2, 6, 138, false),
            (1, 10, 235, false), (1, 12, 53, false), (2, 1, 119, false), (2, 7, 155, false),
            (1, 11, 78, false), (1, 13, 19, false), (2, 2, 84, false), (2, 4, 156, false)]
        private static let outHI: [(Int, Int, UInt8, Bool)] = [
            (3, 8, 149, false), (3, 14, 243, false), (4, 3, 237, false), (4, 5, 55, false),
            (3, 9, 162, false), (3, 15, 208, false), (4, 0, 170, false), (4, 6, 138, false),
            (3, 10, 235, false), (3, 12, 53, false), (4, 1, 119, false), (4, 7, 155, false),
            (3, 11, 78, false), (3, 13, 19, false), (4, 2, 84, false), (4, 4, 135, true)]

        private static func permuteByte(_ b: UInt8) -> UInt8 {
            var o: UInt8 = 0; for (i, p) in bitPerm.enumerated() where b & (1 << i) != 0 { o |= 1 << p }; return o
        }
        private static func sboxed(_ x: [UInt8], _ sb: [UInt8]) -> [UInt8] { x.map { sb[Int($0)] } }
        private static func in1(_ x: [UInt8]) -> [UInt8] { in1Idx.map { x[$0] } }
        private static func in2(_ x: [UInt8]) -> [UInt8] { Array(x[16..<31]) }
        private static func gather(_ src: [UInt8], _ i: Int, _ mask: UInt8, _ perm: [Int]) -> UInt8 {
            let b: UInt8 = i < src.count ? src[i] : 0
            var o: UInt8 = 0; for (k, p) in perm.enumerated() where b & (1 << p) != 0 { o |= 1 << k }
            return o ^ mask
        }
        private static func r0(_ in32: [UInt8], _ base: [UInt8]) -> [UInt8] {
            var r = Array(base.prefix(16)); for (a, b) in r0Wire { r[b] ^= permuteByte(in32[a]) }; return r
        }

        private func named(_ m: Matrix, _ in32: [UInt8], _ r0v: [UInt8], _ r1v: [UInt8]?, _ r2v: [UInt8]?, _ r3v: [UInt8]?, _ lo: [UInt8]?) throws -> [UInt8] {
            let parts: [[UInt8]] = try m.parts.map { tok in
                switch tok {
                case "R0V": return r0v
                case "R1V": return r1v ?? []
                case "R2V": return r2v ?? []
                case "R3V": return r3v ?? []
                case "IN1": return Tables.in1(in32)
                case "IN2": return Tables.in2(in32)
                case "SBOX_LO": return lo ?? []
                default: throw ProviderError.invalid("feat \(tok)")
                }
            }
            return try m.apply(parts)
        }

        func transform32(_ in32: [UInt8], _ id: Int) throws -> [UInt8] {
            let t = tabs[id]
            let sb = t.sbox
            let r0v = Tables.sboxed(Tables.r0(in32, t.base), sb)
            if !t.half {
                let r1v = Tables.sboxed(try t.m("W1").apply([r0v, Tables.in1(in32)]), sb)
                let r2v = Tables.sboxed(try t.m("W2").apply([r1v, Tables.in2(in32)]), sb)
                let r3v = Tables.sboxed(try t.m("W3").apply([r2v, Tables.in2(in32)]), sb)
                let r4v = Tables.sboxed(try t.m("W4").apply([r3v]), sb)
                func pick(_ w: Int) -> [UInt8] { [r1v, r2v, r3v, r4v][w - 1] }
                var out = [UInt8]()
                for e in Tables.outLO { out.append(Tables.gather(pick(e.0), e.1, e.2, Tables.bitPerm)) }
                for e in Tables.outHI { out.append(Tables.gather(pick(e.0), e.1, e.2, e.3 ? Tables.identPerm : Tables.bitPerm)) }
                return out
            }
            let r1lo = try named(t.m("Wa"), in32, r0v, nil, nil, nil, nil)
            var r1: [UInt8]
            if t.r1Rest == "tab1_split" {
                let mid = try named(t.m("Wb"), in32, r0v, nil, nil, nil, Tables.sboxed(r1lo, sb))
                let hi = try named(t.m("Wc"), in32, r0v, nil, nil, nil, nil)
                r1 = r1lo + mid + hi
            } else {
                r1 = r1lo + (try named(t.m("Wb"), in32, r0v, nil, nil, nil, Tables.sboxed(r1lo, sb)))
            }
            let r1v = Tables.sboxed(r1, sb)
            var r2: [UInt8]
            if let w2a = t.mat["W2a"] {
                r2 = try named(w2a, in32, r0v, r1v, nil, nil, nil) + named(t.m("W2b"), in32, r0v, r1v, nil, nil, nil)
            } else {
                r2 = try named(t.m("W2"), in32, r0v, r1v, nil, nil, nil)
            }
            let r2v = Tables.sboxed(r2, sb)
            let r3lo = try named(t.m("W3a"), in32, r0v, r1v, r2v, nil, nil)
            var r3: [UInt8]
            if t.r3Rest == "tab1_split" {
                let mid = try named(t.m("W3b"), in32, r0v, r1v, r2v, nil, Tables.sboxed(r3lo, sb))
                let hi = try named(t.m("W3c"), in32, r0v, r1v, r2v, nil, nil)
                r3 = r3lo + mid + hi
            } else {
                r3 = r3lo + (try named(t.m("W3b"), in32, r0v, r1v, r2v, nil, Tables.sboxed(r3lo, sb)))
            }
            let r3v = Tables.sboxed(r3, sb)
            let lo = try named(t.m("W4a"), in32, r0v, r1v, r2v, r3v, nil)
            let hi = try named(t.m("W4b"), in32, r0v, r1v, r2v, r3v, nil)
            let r4v = Tables.sboxed(lo + hi, sb)
            let concat = r1v + r2v + r3v + r4v
            return (0..<32).map { i in Tables.gather(concat, Int(t.outSrc[i]), t.outM[i], t.outP[i].map { Int($0) }) }
        }
    }
}
