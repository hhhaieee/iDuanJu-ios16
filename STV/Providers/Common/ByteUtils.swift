import Foundation
import CryptoKit

enum Bytes {
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func fromHex(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8); guard c.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(c.count / 2)
        var i = 0
        while i < c.count {
            guard let v = UInt8(String(decoding: c[i..<i+2], as: UTF8.self), radix: 16) else { return nil }
            out.append(v); i += 2
        }
        return out
    }
    static func md5(_ b: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(b))) }
    static func md5(_ s: String) -> [UInt8] { md5(Array(s.utf8)) }
    static func sha256(_ b: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: Data(b))) }
    static func random(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator(); return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
    static func u32LE(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
    static func u32BE(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func readU64LE(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }; return v
    }
    static func writeU64LE(_ v: UInt64, into b: inout [UInt8], at o: Int) {
        for i in 0..<8 { b[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) }
    }
}

/// Go-compatible URL escaping (net/url.QueryEscape / url.Values.Encode), required for byte-exact signatures.
enum GoURL {
    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8))
    static func queryEscape(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if unreserved.contains(b) { out.append(Character(UnicodeScalar(b))) }
            else if b == 0x20 { out.append("+") }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }
    /// Sorted by key like url.Values.Encode.
    static func encode(_ values: [String: String]) -> String {
        values.keys.sorted().map { queryEscape($0) + "=" + queryEscape(values[$0]!) }.joined(separator: "&")
    }
}

/// Loose accessors over JSONSerialization output (mirrors the gateway's numStr/numInt/strOf helpers).
enum J {
    static func str(_ v: Any?) -> String {
        switch v {
        case let s as String: return (s == "<nil>" || s == "null") ? "" : s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return ""
        }
    }
    static func int(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }
    static func int64(_ v: Any?) -> Int64 {
        switch v {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }
    static func double(_ v: Any?) -> Double {
        switch v { case let n as NSNumber: return n.doubleValue; case let s as String: return Double(s) ?? 0; default: return 0 }
    }
    static func bool(_ v: Any?) -> Bool {
        switch v {
        case let n as NSNumber: return n.boolValue
        case let s as String: let l = s.lowercased(); return l == "true" || l == "1"
        default: return false
        }
    }
    static func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
    static func arr(_ v: Any?) -> [Any] { v as? [Any] ?? [] }
    static func firstNonEmpty(_ vals: String...) -> String {
        for s in vals { let t = s.trimmingCharacters(in: .whitespaces); if !t.isEmpty, t != "<nil>", t != "null" { return t } }
        return ""
    }
    static func firstPositive(_ vals: Any?...) -> Int64 { for v in vals { let n = int64(v); if n > 0 { return n } }; return 0 }
    static func unix(_ v: Any?) -> Int64 {
        var i: Int64 = 0
        if let n = v as? NSNumber { i = n.int64Value } else if let s = v as? String { i = Int64(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        if i > 1_000_000_000_000 { return i / 1000 }
        if i > 1_000_000_000 { return i }
        return 0
    }
    static func parse(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw ProviderError.upstream("非 JSON 对象响应")
        }
        return o
    }
    /// Go json.Marshal(map) emits keys sorted; match that.
    static func encodeSorted(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

enum ProviderError: LocalizedError {
    case upstream(String), invalid(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .upstream(let m): return "上游错误：\(m)"
        case .invalid(let m): return "参数错误：\(m)"
        case .unsupported(let m): return "暂不支持：\(m)"
        }
    }
}
