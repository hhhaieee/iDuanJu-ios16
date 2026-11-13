import Foundation
import CryptoKit
import CommonCrypto

/// Pure-Swift port of gateway/internal/provider/hongguo/playersign (4edae5c, 2026-11-03).
/// Full portable player signature set (Argus/Gorgon/Helios/Ladon/Medusa) for video_model v1.
enum HGPlayerSign {
    struct Entropy {
        var envLaunch: Int64, envPID: Int64, nowSecs: Int64
        var messageRandom: UInt32, random: UInt32, packedRandom: UInt32, gorgonRandom: UInt32, heliosRandom: UInt32
        static func draw(_ nowMillis: Int64) -> Entropy {
            var b = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
            func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
            let n = UInt64(u32(0)) | UInt64(u32(4)) << 32
            let u16a = UInt16(b[8]) | UInt16(b[9]) << 8
            let u16b = UInt16(b[12]) | UInt16(b[13]) << 8
            return Entropy(envLaunch: 100 + Int64(n % 21), envPID: 10001 + Int64(u16a % 2000), nowSecs: nowMillis / 1000,
                           messageRandom: u32(0), random: u32(4), packedRandom: u32(8), gorgonRandom: UInt32(u16b), heliosRandom: u32(12))
        }
    }

    // MARK: request

    static func signPOST(path: String, pairs: [(String, String)], nowMillis: Int64, deviceID: String, versionName: String,
                         body: [UInt8], entropy: Entropy? = nil) -> (query: String, headers: [String: String]) {
        var ent = entropy ?? Entropy.draw(nowMillis)
        let bodyMD5 = md5(body)
        let base = UInt64(nowMillis)
        var query = "", ticket: UInt64 = 0, khronos: UInt32 = 0
        for offset in UInt64(0)..<32 {
            ticket = base + offset
            khronos = UInt32(truncatingIfNeeded: ticket / 1000)
            query = encodeQuery(pairs + [("ts", String(khronos)), ("_rticket", String(ticket))])
            if branchOf(sm3(Array(query.utf8)), bodyMD5, le32(khronos)) != 1 { break }
        }
        if ent.nowSecs == 0 { ent.nowSecs = Int64(khronos) }
        let rawURL = "https://reading.snssdk.com" + path + "?" + query
        let h: [String: String] = [
            "Accept": "application/json; charset=utf-8,application/x-protobuf",
            "x-xs-from-web": "0",
            "x-ss-req-ticket": String(ticket),
            "x-tt-request-tag": "t=0;n=0",
            "sdk-version": "2",
            "passport-sdk-version": "50561",
            "x-vc-bdturing-sdk-version": "3.7.2.cn",
            "x-khronos": String(khronos),
            "x-ladon": Data(be32(khronos)).base64EncodedString(),
            "x-argus": Data(le32(khronos)).base64EncodedString(),
            "x-gorgon": xGorgon(query, body, khronos, ent.gorgonRandom),
            "x-helios": helios(khronos, ent.heliosRandom),
            "x-medusa": medusa(rawURL, body, khronos, deviceID, versionName, ent),
            "Content-Type": "application/json; charset=UTF-8",
            "x-ss-stub": bodyMD5.map { String(format: "%02X", $0) }.joined(),
        ]
        return (query, h)
    }

    static func encodeQuery(_ pairs: [(String, String)]) -> String {
        pairs.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&")
    }
    private static func enc(_ s: String) -> String {
        let un = Set("-_.!~*'()".utf8)
        var o = ""
        for c in s.utf8 {
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || un.contains(c) { o.append(Character(UnicodeScalar(c))) }
            else { o += String(format: "%%%02X", c) }
        }
        return o
    }

    // MARK: prim

    @inline(__always) static func rol32(_ v: UInt32, _ c: UInt32) -> UInt32 { let n = c & 31; return n == 0 ? v : (v << n) | (v >> (32 - n)) }
    @inline(__always) static func ror32(_ v: UInt32, _ c: UInt32) -> UInt32 { let n = c & 31; return n == 0 ? v : (v >> n) | (v << (32 - n)) }
    @inline(__always) static func ror64(_ v: UInt64, _ c: UInt64) -> UInt64 { let n = c & 63; return n == 0 ? v : (v >> n) | (v << (64 - n)) }
    static func reverseBits(_ v: UInt8) -> UInt8 { var r: UInt8 = 0; for i in 0..<8 { r = (r << 1) | ((v >> UInt8(i)) & 1) }; return r }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
    static func be32(_ v: UInt32) -> [UInt8] { le32(v).reversed() }
    static func rdLE32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
    static func rdBE32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
    static func rdLE64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(rdLE32(b, o)) | UInt64(rdLE32(b, o + 4)) << 32 }
    static func wrLE64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xffffffff)) + le32(UInt32(v >> 32)) }
    static func md5(_ d: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(d))) }
    static func hexStr(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func hexBytes(_ s: String) -> [UInt8] {
        let a = Array(s.utf8); var o = [UInt8](); o.reserveCapacity(a.count / 2)
        func v(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : (c >= 65 ? c - 55 : c - 48) }
        var i = 0; while i + 1 < a.count { o.append(v(a[i]) << 4 | v(a[i + 1])); i += 2 }
        return o
    }

    static func getIV(_ iv: UInt32, _ data: [UInt8]) -> UInt32 {
        var v = iv
        for (i, b) in data.enumerated() {
            if i & 1 == 0 { v = (v >> 4) ^ v ^ (v << 6) ^ UInt32(b); continue }
            v = ~((v >> 7) ^ v ^ (UInt32(b) | (v << 12)))
        }
        return v
    }

    static func sumMD5(_ data: [UInt8]) -> UInt32 {
        var check: UInt32 = 0x20220420
        for i in 0..<12 {
            var temp: UInt32
            if i & 1 == 0 { temp = (check >> 3) ^ check; check = UInt32(data[i]) ^ (check << 7) }
            else { temp = (check >> 5) ^ check; check = ~(UInt32(data[i]) | (check << 11)) }
            check ^= temp
        }
        return (check | 4) ^ 0x01000000
    }

    static func sm3(_ d: [UInt8]) -> [UInt8] { Medusa.sm3(d) }

    // MARK: proto

    static func varint(_ v0: UInt64) -> [UInt8] { var v = v0; var o = [UInt8](); while v > 127 { o.append(UInt8(v & 127) | 128); v >>= 7 }; o.append(UInt8(v)); return o }
    static func pKey(_ tag: UInt32, _ w: UInt8) -> [UInt8] { varint(UInt64(tag) << 3 | UInt64(w)) }
    static func pBytes(_ tag: UInt32, _ b: [UInt8]) -> [UInt8] { b.isEmpty ? [] : pKey(tag, 2) + varint(UInt64(b.count)) + b }
    static func pStr(_ tag: UInt32, _ s: String) -> [UInt8] { pBytes(tag, Array(s.utf8)) }
    static func pSInt(_ tag: UInt32, _ v: Int64) -> [UInt8] { pKey(tag, 0) + varint(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }
    static func pFloat(_ tag: UInt32, _ v: Float) -> [UInt8] { pKey(tag, 5) + le32(v.bitPattern) }

    // MARK: const

    static let appID = "8662"
    static let channelID = "1588093228"
    static let gorgonSDKVersion: UInt32 = 67503104
    static let sbox: [UInt8] = Array(Data(base64Encoded: "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")!)
    static let branch2Orders: [UInt8] = hexBytes("0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003")
    static let medusaSignKey = hexBytes("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
    static let medusaAESKey = hexBytes("f1593376766ea98d34f31b057a9d5be4")
    static let medusaAESIV = hexBytes("1fe109a4125283f418de9e051a969e12")
    static let branch2SV: [UInt32] = [
        0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73,
        0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64,
        0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
        0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28,
        0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec,
        0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
        0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
        0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3,
    ]

    // MARK: gorgon

    static func rc4Gorgon(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % key.count])) & 255; s[i] = s[j] }
        var out = [UInt8](); out.reserveCapacity(data.count)
        var i = 0; j = 0
        for v in data {
            i += 1
            let x = s[i & 255]; j += Int(x)
            let y = s[j & 255]; s[i & 255] = y
            out.append(v ^ s[(Int(y) + Int(y)) & 255])
        }
        return out
    }

    static func xGorgon(_ query: String, _ body: [UInt8], _ khronos: UInt32, _ random: UInt32) -> String {
        let qm = md5(Array(query.utf8)), bm = md5(body)
        let input = Array(qm[0..<4]) + Array(bm[0..<4]) + [0, 0, 0, 0] + le32(gorgonSDKVersion) + be32(khronos)
        let key: [UInt8] = [0x4a, 0x40, 0x16, UInt8((random >> 8) & 255), 0x47, 0x6c, 0x01, UInt8(random & 255)]
        var out = rc4Gorgon(input, key)
        let n = out.count
        for i in 0..<n {
            let v = out[i]
            let sw = (v >> 4) | (v << 4)
            let next = i + 1 < n ? out[i + 1] : out[0]
            out[i] = ~(reverseBits(next ^ sw) ^ 20)
        }
        return hexStr([0x84, 0x04, UInt8(random & 255), UInt8((random >> 8) & 255), 0x40, 0x01] + out)
    }

    // MARK: helios

    static func helios(_ khronos: UInt32, _ random: UInt32) -> String {
        let ascii = Array(hexStr(md5(le32(random) + Array(appID.utf8))).utf8)
        let words = (0..<4).map { rdLE64(ascii, $0 * 8) }
        // diffuse
        var table = [words[0]]
        var b0 = words[0], b8 = words[1]
        var queue = Array(words[2...])
        for i in UInt64(0)..<34 {
            var x8 = ror64(b8, 8) &+ b0
            x8 ^= i
            queue.append(x8)
            x8 ^= ror64(b0, 61)
            table.append(x8)
            b0 = x8; b8 = queue.removeFirst()
        }
        let text = Array("\(khronos)-\(channelID)-\(appID)".utf8)
        let fill = UInt8(16 - (text.count % 16))
        let size = ((text.count + 1 + 15) / 16) * 16
        var padded = [UInt8](repeating: fill, count: size)
        for (i, c) in text.enumerated() { padded[i] = c }
        var output = [UInt8]()
        var off = 0
        while off < padded.count {
            var a = rdLE64(padded, off), b = rdLE64(padded, off + 8)
            for t in table[0..<34] { b = t ^ (a &+ ror64(b, 8)); a = b ^ ror64(a, 61) }
            output += wrLE64(a) + wrLE64(b)
            off += 16
        }
        return Data(le32(random) + output).base64EncodedString()
    }

    // MARK: f13

    static let b0IV: [UInt32] = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1]
    static let b0TT: [UInt32] = [
        0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
        0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
        0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
        0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
        0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
        0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
        0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
        0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
    ]
    static let b0Init: [UInt32] = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]
    static let b0Rounds: [[UInt32]] = [
        [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3], [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4], [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
        [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6], [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4], [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
    ]

    static func branchOf(_ q: [UInt8], _ bm: [UInt8], _ ts: [UInt8]) -> UInt32 {
        let iv = getIV(getIV(getIV(0x20230928, q), bm), ts)
        let low = iv & 15
        return low - ((low * 171) >> 9) * 3
    }

    static func hashF13(_ qs: [UInt8], _ bm: [UInt8], _ ts: [UInt8], _ khronos: UInt32) -> [UInt8] {
        let iv = getIV(getIV(getIV(0x20230928, qs), bm), ts)
        let low = iv & 15
        let ivV0 = (low * 171) >> 9
        let branch = low - ivV0 * 3
        if branch == 2 { return branch2F13(iv, qs, bm, ts, khronos) }
        if branch != 0 { return Array(qs[0..<16]) + bm + le32(sumMD5(qs + bm)) }
        return branch0F13(qs, bm, ts, khronos, ivV0)
    }

    static func expandWords(_ data: [UInt8]) -> [UInt32] {
        var di = [UInt32]()
        var off = 0; while off + 4 <= data.count { di.append(rdBE32(data, off)); off += 4 }
        var di0 = di[0]
        for i in 0..<112 {
            let di1 = di[i + 1], di14 = di[i + 14]
            let r1 = rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >> 3)
            let r2 = rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >> 10)
            di.append(di0 &+ di[i + 9] &+ r1 &+ r2)
            di0 = di1
        }
        return di
    }

    static func mixRounds(_ st: [UInt32], _ r: [UInt32], _ di: [UInt32], _ tt: [UInt32], _ ivV1: UInt32) -> [UInt32] {
        var s = st
        func x(_ k: Int) -> Int { Int(r[k]) }
        for i in UInt32(0)..<r[0] {
            let base = ivV1 &+ i
            let w = di[Int(base & 127)]
            let n1 = ((s[x(3)] ^ s[x(4)]) & s[x(1)]) ^ s[x(3)]
            let n2 = rol32(s[x(1)], 26) ^ rol32(s[x(1)], 21) ^ rol32(s[x(1)], 7)
            let n4 = w &+ n1 &+ n2 &+ tt[Int(base & 63)] &+ s[x(5)]
            let n5 = rol32(s[x(2)], 30) ^ rol32(s[x(2)], 19) ^ rol32(s[x(2)], 10)
            let n6 = (s[x(2)] & s[x(6)]) | ((s[x(2)] | s[x(6)]) & s[x(7)])
            let n7 = n5 &+ n6
            let old = s[x(9)]
            s = [s[s.count - 1]] + Array(s[0..<(s.count - 1)])
            s[x(10)] = n7 &+ n4
            s[x(8)] = old &+ n4
        }
        return s
    }

    static func branch0F13(_ qs: [UInt8], _ bm: [UInt8], _ ts: [UInt8], _ khronos: UInt32, _ ivV0: UInt32) -> [UInt8] {
        let ivV1 = b0IV[min(Int(ivV0), b0IV.count - 1)]
        let countV1 = (ivV1 &+ khronos &+ 1) & 255
        let countV2 = ivV1 &+ khronos
        let tt = b0TT.map { ror32($0, countV1) }
        let n0 = UInt16((countV2 &+ 2) & 7)
        let pad = [UInt8]([0xfa, 0x45, 0x61, 0xd7]).map { v -> UInt8 in let c = UInt16(v) | UInt16(v) << 8; return UInt8((c >> n0) & 255) }
        let data = qs + bm + ts + pad + hexBytes("00000000000001a0")
        let di = expandWords(data)
        let ini = b0Init.map { ror32($0, countV2 & 31) }
        let d = mixRounds(ini, b0Rounds[Int(ivV0)], di, tt, ivV1)
        var ret = [UInt8]()
        for i in 0..<8 { ret += be32(d[i] &+ ini[i]) }
        for i in 0..<16 { ret[i] ^= ret[16 + i] }
        return Array(ret[0..<16]) + le32(sumMD5(Array(ret[0..<16])))
    }

    static func md5V3Step(_ kind: UInt32, _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ m: UInt32, _ sh: UInt32, _ k: UInt32) -> UInt32 {
        let f: UInt32
        switch kind {
        case 0: f = (b & c) | (~b & d)
        case 1: f = (b & d) | (c & ~d)
        case 2: f = b ^ c ^ d
        default: f = c ^ (b | ~d)
        }
        return b &+ rol32(a &+ f &+ m &+ k, sh)
    }

    static func md5SumV3(_ msg: [UInt8], _ countV2: UInt32, _ orders: [UInt8], _ countV1: UInt32) -> [UInt8] {
        let sv = branch2SV.map { ror32($0, countV1) }
        let start = [ror32(0x79e0f2fb, countV2), ror32(0xc8b52570, countV2), ror32(0xebc2f8cd, countV2), ror32(0x7c104d93, countV2)]
        let ec = (countV2 &+ 6) & 255
        let end = [ror32(0x19be4866, ec), ror32(0xe85986b4, ec), ror32(0xe19b326e, ec), ror32(0x71d1d7d4, ec)]
        let m = (0..<16).map { rdLE32(msg, $0 * 4) }
        var a = start[0], b = start[1], c = start[2], d = start[3]
        func run(_ kind: UInt32, _ shifts: [UInt32], _ offset: Int) {
            for i in 0..<16 {
                let w = m[Int(orders[offset + i])], k = sv[offset + i]
                switch i & 3 {
                case 0: a = md5V3Step(kind, a, b, c, d, w, shifts[i], k)
                case 1: d = md5V3Step(kind, d, a, b, c, w, shifts[i], k)
                case 2: c = md5V3Step(kind, c, d, a, b, w, shifts[i], k)
                default: b = md5V3Step(kind, b, c, d, a, w, shifts[i], k)
                }
            }
        }
        run(0, [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22], 0)
        run(1, [5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20], 16)
        run(2, [4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23], 32)
        run(3, [6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21], 48)
        let ret = le32((start[0] &+ a) ^ end[0]) + le32((start[1] &+ b) ^ end[1]) + le32((start[2] &+ c) ^ end[2]) + le32((start[3] &+ d) ^ end[3])
        return ret + le32(sumMD5(ret))
    }

    static func branch2F13(_ iv: UInt32, _ qs: [UInt8], _ bm: [UInt8], _ ts: [UInt8], _ khronos: UInt32) -> [UInt8] {
        let v = (iv & 13) &* 86
        let ivV0 = ((v >> 15) & 255) + ((v >> 8) & 255)
        let n1s: [UInt32] = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4]
        let n1 = n1s[min(Int(ivV0), n1s.count - 1)]
        let countV1 = (n1 &+ khronos &+ 1) & 255
        let countV2 = n1 &+ khronos
        let sh = UInt16((countV2 &+ 5) & 7)
        let pad = [UInt8]([0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8]).map { v -> UInt8 in let c = UInt16(v) | UInt16(v) << 8; return UInt8((c >> sh) & 255) }
        let input = qs + bm + ts + pad + hexBytes("a0010000")
        let begin = Int(ivV0) << 6
        return md5SumV3(input, countV2, Array(branch2Orders[begin..<(begin + 64)]), countV1)
    }

    // MARK: aes (custom v3)

    static let aesCon2: [[Int]] = [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]]
    static let aesOrder: [[Int]] = [
        [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3], [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
        [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15], [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ]
    static let aesInitWord: [UInt32] = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f]

    static func xorBytes(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { a.enumerated().map { $0.element ^ b[$0.offset % b.count] } }

    static func aesEncrypt(_ data: [UInt8], _ iv: [UInt8], key: [UInt8], khronos: UInt32) -> [UInt8] {
        let word = Int(khronos & 3)
        let box = Array(sbox[(word * 256)..<(word * 256 + 256)])
        let con2 = aesCon2[word], order = aesOrder[word]
        // expand
        let ini = aesInitWord[word]
        var ex = xorBytes(le32(ini) + le32(ini) + le32(ini) + le32(ini), key) + [UInt8](repeating: 0, count: 32)
        var rounds: UInt32 = 8
        for i in 4..<12 {
            let at = 4 * (i - 1)
            var a = ex[at], b = ex[at + 1], c = ex[at + 2], d = ex[at + 3]
            if i & 3 == 0 {
                let t = ((ini >> (rounds & 24)) ^ UInt32(box[Int(b)])) & 255
                b = box[Int(c)]; c = box[Int(d)]; d = box[Int(a)]; a = UInt8(t)
            }
            rounds += 2
            ex[at + 4] = a ^ ex[at - 12]; ex[at + 5] = b ^ ex[at - 11]; ex[at + 6] = c ^ ex[at - 10]; ex[at + 7] = d ^ ex[at - 9]
        }
        let keys: [[UInt8]] = (0..<12).map { Array(ex[($0 * 4)..<($0 * 4 + 4)]) }
        func addCon(_ s: inout [[UInt8]], _ k0: Int) { for i in 0..<4 { for j in 0..<4 { s[i][j] ^= keys[k0 + i][con2[j]] } } }
        func block(_ v: [UInt8]) -> [UInt8] {
            var s: [[UInt8]] = (0..<4).map { Array(v[($0 * 4)..<($0 * 4 + 4)]) }
            addCon(&s, 0)
            for r in 1..<3 {
                for i in 0..<4 { for j in 0..<4 { s[i][j] = box[Int(s[i][j])] } }
                let old = s; for i in 0..<4 { s[i] = old[con2[i]] }
                let flat = s.flatMap { $0 }
                for i in 0..<16 { s[i / 4][i % 4] = flat[order[i]] }
                if r == 1 {
                    let o2 = s; for i in 0..<4 { for j in 0..<4 { s[i][j] = o2[i][con2[j]] } }
                    func xt(_ x: UInt8) -> UInt8 { var v = x << 1; if x & 128 != 0 { v ^= 0x1b }; return v }
                    for i in 0..<4 {
                        let t = s[0][i] ^ s[1][i] ^ s[2][i] ^ s[3][i]
                        let u = s[0][i]
                        s[0][i] ^= t ^ xt(s[0][i] ^ s[1][i])
                        s[1][i] ^= t ^ xt(s[1][i] ^ s[2][i])
                        s[2][i] ^= t ^ xt(s[2][i] ^ s[3][i])
                        s[3][i] ^= t ^ xt(s[3][i] ^ u)
                    }
                }
                addCon(&s, r * 4)
            }
            for i in 0..<4 { for j in 0..<4 { s[i][j] ^= keys[4 + i][j] } }
            return s.flatMap { $0 }
        }
        var src = data
        var pt = [UInt8](repeating: 0, count: 32)
        for i in 0..<31 {
            let at = i * 8
            var n = (src[at] >> 4) & 2
            n |= src[at + 1] & 64
            n |= (src[at + 2] >> 2) & 1
            n |= (src[at + 3] << 3) & 128
            n |= (src[at + 4] >> 1) & 4
            n |= (src[at + 5] << 3) & 16
            n |= (src[at + 6] << 5) & 32
            pt[i] = n | ((src[at + 7] >> 4) & 8)
        }
        pt[31] = 1
        var blocks = [UInt8]()
        var prev = iv
        for off in stride(from: 0, to: 32, by: 16) {
            let v = block(xorBytes(Array(pt[off..<(off + 16)]), prev)); blocks += v; prev = v
        }
        for i in 0..<31 {
            let at = i * 8, k = blocks[i]
            src[at] = (src[at] & 0xdf) | ((k << 4) & 32)
            src[at + 1] = (src[at + 1] & 0xbf) | (k & 64)
            src[at + 2] = (src[at + 2] & 0xfb) | ((k << 2) & 4)
            src[at + 3] = (src[at + 3] & 0xef) | ((k >> 3) & 16)
            src[at + 4] = (src[at + 4] & 0xf7) | ((k &+ k) & 8)
            src[at + 5] = (src[at + 5] & 0xfd) | ((k >> 3) & 2)
            src[at + 6] = (src[at + 6] & 0xfe) | ((k >> 5) & 1)
            src[at + 7] = (src[at + 7] & 0x7f) | ((k << 4) & 128)
        }
        return [blocks[31]] + src
    }

    // MARK: medusa

    static func xmxor(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let n = data.count
        var e = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let at = (i * 4) & 28
            let d0 = key[at], d1 = key[at + 1]
            let sw = (data[i] << 4) | (data[i] >> 4)
            var d2 = UInt8(truncatingIfNeeded: UInt32(sw) + UInt32(d0))
            d2 = ~d2 ^ d1
            d2 = (d2 << 3) | (d2 >> 5)
            d2 = d2 &+ d1
            d2 ^= d0
            e[n - i - 1] = ~d2
        }
        let last = e[n - 1] ^ e[n - 2]
        let first = e[0]
        e[0] = (~last) &+ first
        e[1] = (e[0] ^ e[n - 1] ^ 254) &+ e[1]
        let shifted = (e[1] << 3) | (e[1] >> 5)
        let fix2 = (last &- first) ^ (shifted ^ 2)
        e[2] = e[2] &+ fix2
        for i in 0..<(n - 4) {
            let sh = (e[i + 2] << 3) | (e[i + 2] >> 5)
            let temp = sh ^ e[i + 1] ^ UInt8(truncatingIfNeeded: i + 3)
            e[i + 3] = (~temp) &+ e[i + 3]
        }
        e[n - 1] ^= e[n - 2]
        var sum: UInt32 = 0
        for item in e[1...] { sum = sum &+ UInt32(item) }
        e[0] = (e[0] ^ e[1]) &+ UInt8(truncatingIfNeeded: sum)
        return e
    }

    static func keyHash(_ signKey: [UInt8], _ random: UInt32) -> ([UInt8], [UInt8]) {
        let hash = sm3(signKey + le32(random) + signKey)
        let d1 = (random >> 16) & 255
        var d2 = (d1 << 11) | (random >> 24)
        d2 ^= d1 >> 5
        d2 ^= d1
        d2 = ~d2
        return (hash, le32(d2))
    }

    static func deviceProto(_ deviceID: String) -> [UInt8] {
        var o = [UInt8]()
        o += pSInt(1, 1); o += pSInt(2, 2); o += pStr(3, appID); o += pStr(4, deviceID)
        o += pStr(5, "Ai6svO3PyrwDOUSmO6ZcResxu"); o += pStr(6, "!noperm!")
        o += pSInt(7, -888888); o += pSInt(8, -888888); o += pSInt(9, 3); o += pSInt(10, -888888)
        o += pStr(11, "!notset!"); o += pStr(12, "Asia/Shanghai,8"); o += pStr(13, "zh_CN"); o += pSInt(14, 4)
        o += pFloat(16, 255.24993896484375); o += pFloat(17, 35.58599090576172); o += pFloat(18, 3.467449188232422)
        o += pFloat(19, 3.467449188232422); o += pFloat(20, 255.1754913330078); o += pFloat(21, 42.17544174194336)
        o += pStr(22, "16"); o += pSInt(23, 41); o += pSInt(24, 36)
        o += pSInt(25, 1728388016635); o += pSInt(26, 1728388016635); o += pSInt(27, 1728388016635); o += pSInt(28, 1728388016637)
        o += pSInt(29, -1); o += pStr(30, "25053RT47C"); o += pStr(31, "Redmi"); o += pStr(32, "25053RT47C"); o += pStr(33, "25053RT47C")
        o += pStr(34, "Xiaomi"); o += pStr(35, "Redmi"); o += pStr(36, "Redmi"); o += pSInt(38, 31)
        return o
    }

    static func medusa(_ rawURL: String, _ body: [UInt8], _ khronos: UInt32, _ deviceID: String, _ versionName: String, _ ent: Entropy) -> String {
        let bm = md5(body)
        let queryRaw: String = rawURL.firstIndex(of: "?").map { String(rawURL[rawURL.index(after: $0)...]) } ?? ""
        let qs = sm3(Array(queryRaw.utf8))
        let ts = le32(khronos)
        let qbt = hashF13(qs, bm, ts, khronos)
        let check = (UInt32(qs[0] & 63) << 14) | 0x18000001 | (UInt32(qbt[0] & 63) << 8)
        let nested = pSInt(1, 111) + pSInt(2, 10) + pSInt(3, 694367) + pSInt(5, 586952199)
        let nested13 = pSInt(1, ent.nowSecs) + pSInt(2, -2) + pSInt(4, 200)
        var env = pSInt(1, ent.envLaunch) + pSInt(2, 146331399) + pSInt(3, 146331396) + pSInt(5, 7)
        env += pStr(6, "v04.06.04.03-bugfix") + pSInt(7, ent.envPID) + pBytes(12, deviceProto(deviceID)) + pBytes(13, nested13) + pStr(14, versionName)
        let queryHash = sm3(Array(queryRaw.utf8) + bm + Array("none".utf8))
        let fixed1 = hexBytes("f7e85ffad7d7dc3bd62ac87057cf6118"), fixed2 = hexBytes("4001000000000000")
        var msg = pBytes(1, fixed1) + pSInt(2, 3) + pSInt(3, Int64(ent.messageRandom)) + pStr(4, appID) + pStr(5, deviceID)
        msg += pStr(6, channelID) + pStr(7, versionName) + pStr(8, "v04.06.04-ml-android") + pSInt(9, 67503104) + pBytes(10, fixed2)
        msg += pSInt(12, Int64(khronos)) + pBytes(13, qbt) + pBytes(14, Array(qs[0..<6])) + pBytes(15, nested)
        msg += pStr(16, "AXYQOS6n2m60x1fVZHIrH3iol") + pSInt(17, Int64(khronos)) + pBytes(19, queryHash) + pStr(20, "none")
        msg += pSInt(21, 312) + pBytes(23, env)
        msg += pStr(24, #"{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}"#)
        let (hash, seed) = keyHash(medusaSignKey, ent.random)
        var tr: [UInt8] = Array((fixed2 + xmxor(msg, hash)).reversed())
        for i in 0..<tr.count { tr[i] ^= seed[(~i) & 3] }
        let packed = [0x35] + le32(ent.packedRandom) + le32(check) + tr + [UInt8((ent.random >> 16) & 255), UInt8(ent.random >> 24)]
        let encrypted = aesEncrypt(packed, medusaAESIV, key: medusaAESKey, khronos: khronos)
        let version = hexBytes("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
        var out = [UInt8]()
        for i in 0..<5 { out += le32(rdLE32(version, i * 4) ^ khronos) }
        out += [UInt8(ent.random & 255), UInt8((ent.random >> 8) & 255), 0, 1]
        out += encrypted
        return Data(out).base64EncodedString()
    }
}

// Playback 551 framing and protocol constants cross-checked with hongguo-open-player
// 3f687c5 (src/server/native/argus.js, GPL-3.0-only; adapted from fqapp/hongguoTV).
// These are SDK protocol constants, not user credentials.
extension HGPlayerSign {
    /// Sign the exact wire body. Legacy Gorgon/Medusa must not be added to this dialect:
    /// the upstream rejects that combination even when Argus and Ladon are valid.
    static func playbackHeaders(query: String, body: [UInt8], timestamp: UInt32,
                                argusRandom: UInt32? = nil, ladonRandom: UInt32? = nil) throws -> [String: String] {
        func param(_ name: String) -> String {
            for part in query.split(separator: "&") {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if String(pair[0]).removingPercentEncoding == name {
                    return pair.count > 1 ? (String(pair[1]).removingPercentEncoding ?? String(pair[1])) : ""
                }
            }
            return ""
        }
        let aid = param("aid").isEmpty ? "1967" : param("aid")
        let license = "1611921764"
        let random = argusRandom ?? UInt32.random(in: .min ... .max)
        // This schema uses unsigned uint32 varints, unlike the older Medusa schema.
        func uint(_ field: UInt32, _ value: UInt32) -> [UInt8] { pKey(field, 0) + varint(UInt64(value)) }
        func str(_ field: UInt32, _ value: String) -> [UInt8] {
            let bytes = Array(value.utf8)
            return pKey(field, 2) + varint(UInt64(bytes.count)) + bytes
        }
        var bean = uint(1, 1077940818) + uint(2, 2) + uint(3, random)
        bean += str(4, aid) + str(5, param("device_id")) + str(6, license)
        bean += str(7, param("version_name")) + str(8, "v04.04.05-ov-android")
        bean += uint(9, 134744640) + pBytes(10, [UInt8](repeating: 0, count: 8)) + uint(11, 0)
        bean += uint(12, timestamp &* 2)
        bean += pBytes(13, Array(sm3(body.isEmpty ? [UInt8](repeating: 0, count: 16) : md5(body)).prefix(6)))
        bean += pBytes(14, Array(sm3(query.isEmpty ? [UInt8](repeating: 0, count: 16) : Array(query.utf8)).prefix(6)))
        bean += pBytes(15, uint(1, 1) + uint(2, 1) + uint(3, 1) + uint(7, 0xC792ECCC))
        bean += str(16, param("iid")) + str(20, "none") + uint(21, 738)
        bean += pBytes(23, str(1, "NX551J") + uint(2, 8196) + uint(4, 0x80E0D800)) + uint(25, 2)

        let signKey = hexBytes("fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")
        var keys = (0..<4).map { rdLE64(signKey, $0 * 8) }
        let z: UInt64 = 0x3DC94C3A046D678B
        for i in 4..<72 {
            var t = ror64(keys[i - 1], 3) ^ keys[i - 3]
            t ^= ror64(t, 1)
            keys.append(~keys[i - 4] ^ t ^ ((z >> UInt64((i - 4) % 62)) & 1) ^ 3)
        }
        let padded = playbackPad(bean)
        var encrypted = [UInt8]()
        for at in stride(from: 0, to: padded.count, by: 16) {
            var left = rdLE64(padded, at), right = rdLE64(padded, at + 8)
            for key in keys {
                let oldRight = right
                right = left ^ (ror64(right, 63) & ror64(right, 56)) ^ ror64(right, 62) ^ key
                left = oldRight
            }
            encrypted += wrLE64(left) + wrLE64(right)
        }
        let magic = hexBytes("f2f7fcfff2f7fcff")
        var frame = magic + encrypted + hexBytes("eafb2cfe8568519154")
        for i in 8..<frame.count { frame[i] ^= magic[i % 8] }
        frame.reverse()
        let packet = playbackPad(frame + [0x61, 0x6f])
        let argus = try playbackAES(packet, key: hexBytes("d31e3718288a1027baab59f146a09a9c"), iv: hexBytes("ea180a0336ed352fcd24e4d50018ae54"))
        var headers = ["x-ss-req-ticket": String(UInt64(timestamp) * 1000), "x-khronos": String(timestamp),
                       "x-argus": Data([0xf2, 0x81] + argus).base64EncodedString(),
                       "x-ladon": playbackLadon(timestamp: timestamp, aid: aid, license: license,
                                                random: ladonRandom ?? UInt32.random(in: .min ... .max))]
        if !body.isEmpty { headers["x-ss-stub"] = hexStr(md5(body)).uppercased() }
        return headers
    }

    private static func playbackPad(_ bytes: [UInt8]) -> [UInt8] {
        let count = 16 - bytes.count % 16
        return bytes + [UInt8](repeating: UInt8(count), count: count)
    }

    private static func playbackLadon(timestamp: UInt32, aid: String, license: String, random: UInt32) -> String {
        let ascii = Array(hexStr(md5(le32(random) + Array(aid.utf8))).utf8)
        var table = [rdLE64(ascii, 0)]
        var a = table[0], b = rdLE64(ascii, 8)
        var queue = [rdLE64(ascii, 16), rdLE64(ascii, 24)]
        for i in UInt64(0)..<34 {
            let x = (ror64(b, 8) &+ a) ^ i
            queue.append(x)
            a = x ^ ror64(a, 61)
            table.append(a)
            b = queue.removeFirst()
        }
        let text = playbackPad(Array("\(timestamp)-\(license)-\(aid)".utf8))
        var result = le32(random)
        for at in stride(from: 0, to: text.count, by: 16) {
            var left = rdLE64(text, at), right = rdLE64(text, at + 8)
            for key in table.prefix(34) {
                right = key ^ (left &+ ror64(right, 8))
                left = right ^ ror64(left, 61)
            }
            result += wrLE64(left) + wrLE64(right)
        }
        return Data(result).base64EncodedString()
    }

    private static func playbackAES(_ bytes: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + 16)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                             key, key.count, iv, bytes, bytes.count, &output, output.count, &written)
        guard status == kCCSuccess else { throw ProviderError.invalid("播放器签名 AES 失败：\(status)") }
        return Array(output.prefix(written))
    }
}
