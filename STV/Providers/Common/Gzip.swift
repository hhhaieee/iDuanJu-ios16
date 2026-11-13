import Foundation

/// Minimal gzip (RFC 1952) encoder: Apple's `.zlib` NSData compression emits raw DEFLATE.
enum Gzip {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = table[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    static func compress(_ data: Data) -> Data {
        let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        out.append(contentsOf: Bytes.u32LE(crc32(Array(data))))
        out.append(contentsOf: Bytes.u32LE(UInt32(truncatingIfNeeded: data.count)))
        return out
    }
}
