import Foundation
import CryptoKit
import CommonCrypto
import Security

/// host.crypto / host.codec / host.m3u8 implementations (pure functions, no I/O).
enum PluginCrypto {
    static func fail(_ m: String) -> PluginError { .runtime(code: "E_INTERNAL", message: m) }

    static func decode(_ s: String, _ enc: String?) throws -> Data {
        switch enc ?? "utf8" {
        case "utf8", "text": return Data(s.utf8)
        case "hex": guard let b = Bytes.fromHex(s.lowercased()) else { throw fail("hex 不合法") }; return Data(b)
        case "base64":
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").filter { !$0.isWhitespace }
            while t.count % 4 != 0 { t += "=" }
            guard let d = Data(base64Encoded: t) else { throw fail("base64 不合法") }
            return d
        case "latin1": return Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        default: throw fail("不支持的编码 \(enc!)")
        }
    }

    static func encode(_ d: Data, _ enc: String?) throws -> String {
        switch enc ?? "hex" {
        case "hex": return Bytes.hex(Array(d))
        case "base64": return d.base64EncodedString()
        case "utf8", "text": return String(decoding: d, as: UTF8.self)
        case "latin1": return String(d.map { Character(Unicode.Scalar($0)) })
        default: throw fail("不支持的编码 \(enc!)")
        }
    }

    static func hash(alg: String, _ d: Data) throws -> Data {
        switch alg.lowercased() {
        case "md5": return Data(Insecure.MD5.hash(data: d))
        case "sha1": return Data(Insecure.SHA1.hash(data: d))
        case "sha256": return Data(SHA256.hash(data: d))
        case "sha384": return Data(SHA384.hash(data: d))
        case "sha512": return Data(SHA512.hash(data: d))
        default: throw fail("不支持的哈希 \(alg)")
        }
    }

    static func hmac(alg: String, key: Data, _ d: Data) throws -> Data {
        let k = SymmetricKey(data: key)
        switch alg.lowercased() {
        case "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: d, using: k))
        case "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: d, using: k))
        case "sha256": return Data(HMAC<SHA256>.authenticationCode(for: d, using: k))
        case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: d, using: k))
        default: throw fail("不支持的 HMAC \(alg)")
        }
    }

    /// mode cbc | ecb | ctr | gcm. GCM data = ciphertext ‖ 16-byte tag.
    static func aes(encrypt: Bool, mode: String, key: Data, iv: Data?, data: Data, padding: Bool) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw fail("AES key 长度必须是 16/24/32 字节") }
        switch mode.lowercased() {
        case "gcm":
            let k = SymmetricKey(data: key)
            guard let iv, let nonce = try? AES.GCM.Nonce(data: iv) else { throw fail("GCM 需要 iv") }
            if encrypt {
                let box = try AES.GCM.seal(data, using: k, nonce: nonce)
                return box.ciphertext + box.tag
            }
            guard data.count >= 16 else { throw fail("GCM 数据太短") }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
            return try AES.GCM.open(box, using: k)
        case "ctr":
            guard let iv, iv.count == 16 else { throw fail("CTR 需要 16 字节 iv") }
            var ref: CCCryptorRef?
            var st = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
            } }
            guard st == kCCSuccess, let ref else { throw fail("AES-CTR 初始化失败 \(st)") }
            defer { CCCryptorRelease(ref) }
            var out = Data(count: data.count)
            var moved = 0
            st = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in CCCryptorUpdate(ref, i.baseAddress, data.count, o.baseAddress, data.count, &moved) } }
            guard st == kCCSuccess else { throw fail("AES-CTR 失败 \(st)") }
            return out.prefix(moved)
        case "cbc", "ecb":
            let ecb = mode.lowercased() == "ecb"
            if !ecb { guard let iv, iv.count == 16 else { throw fail("CBC 需要 16 字节 iv") } }
            var opts = CCOptions(padding ? kCCOptionPKCS7Padding : 0)
            if ecb { opts |= CCOptions(kCCOptionECBMode) }
            var out = Data(count: data.count + 16)
            let cap = out.count
            var moved = 0
            let ivData = iv ?? Data(count: 16)
            let st = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in key.withUnsafeBytes { k in ivData.withUnsafeBytes { v in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), opts, k.baseAddress, key.count,
                        ecb ? nil : v.baseAddress, i.baseAddress, data.count, o.baseAddress, cap, &moved)
            } } } }
            guard st == kCCSuccess else { throw fail(st == kCCAlignmentError ? "数据长度不是 16 的倍数（检查 padding）" : "AES 失败 \(st)") }
            return out.prefix(moved)
        default: throw fail("不支持的 AES 模式 \(mode)")
        }
    }

    // MARK: RSA (public-key operations only)

    static func publicKey(pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard var der = Data(base64Encoded: body) else { throw fail("RSA 公钥不是合法 PEM") }
        if pem.contains("BEGIN PUBLIC KEY") { der = try stripSPKI(der) }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else { throw fail("RSA 公钥无法导入") }
        return k
    }

    /// SubjectPublicKeyInfo → PKCS#1 RSAPublicKey (contents of the BIT STRING).
    static func stripSPKI(_ d: Data) throws -> Data {
        let b = [UInt8](d)
        var i = 0
        func readLen() -> Int {
            var l = Int(b[i]); i += 1
            if l & 0x80 != 0 { let n = l & 0x7f; l = 0; for _ in 0..<n { l = l << 8 | Int(b[i]); i += 1 } }
            return l
        }
        guard b.count > 20, b[0] == 0x30 else { throw fail("SPKI 格式不对") }
        i = 1; _ = readLen()
        guard b[i] == 0x30 else { throw fail("SPKI 格式不对") }
        i += 1; let algLen = readLen(); i += algLen
        guard i < b.count, b[i] == 0x03 else { throw fail("SPKI 格式不对") }
        i += 1; let bitLen = readLen()
        guard i + bitLen <= b.count, bitLen > 1 else { throw fail("SPKI 格式不对") }
        return Data(b[(i + 1)..<(i + bitLen)])
    }

    static func rsaEncrypt(pem: String, data: Data, oaep: Bool) throws -> Data {
        let k = try publicKey(pem: pem)
        var err: Unmanaged<CFError>?
        let alg: SecKeyAlgorithm = oaep ? .rsaEncryptionOAEPSHA1 : .rsaEncryptionPKCS1
        guard let out = SecKeyCreateEncryptedData(k, alg, data as CFData, &err) else { throw fail("RSA 加密失败") }
        return out as Data
    }

    static func rsaVerify(pem: String, data: Data, signature: Data, hash: String) throws -> Bool {
        let k = try publicKey(pem: pem)
        let alg: SecKeyAlgorithm = hash.lowercased() == "sha1" ? .rsaSignatureMessagePKCS1v15SHA1 : .rsaSignatureMessagePKCS1v15SHA256
        return SecKeyVerifySignature(k, alg, data as CFData, signature as CFData, nil)
    }

    static func gunzip(_ d: Data) throws -> Data {
        var body = d
        if d.count > 18, d[d.startIndex] == 0x1f, d[d.startIndex + 1] == 0x8b {
            let b = [UInt8](d)
            var i = 10
            let flg = b[3]
            if flg & 4 != 0 { i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
            if flg & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
            if flg & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
            if flg & 2 != 0 { i += 2 }
            body = Data(b[i..<(b.count - 8)])
        } else if d.count > 2, d[d.startIndex] == 0x78 {
            body = d.dropFirst(2)
        }
        guard let out = try? (body as NSData).decompressed(using: .zlib) as Data else { throw fail("解压失败") }
        return out
    }
}

/// Minimal HLS playlist parser for host.m3u8.parse.
enum PluginM3U8 {
    static func parse(_ text: String, base: URL?) -> [String: Any] {
        func abs(_ s: String) -> String { base.flatMap { URL(string: s, relativeTo: $0)?.absoluteString } ?? s }
        func attrs(_ line: Substring) -> [String: String] {
            var out: [String: String] = [:]
            let pattern = #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#
            let ns = String(line) as NSString
            for m in (try! NSRegularExpression(pattern: pattern)).matches(in: String(line), range: NSRange(location: 0, length: ns.length)) {
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return out
        }
        var variants: [[String: Any]] = [], segments: [[String: Any]] = []
        var key: [String: Any]?
        var pendingVariant: [String: String]?
        var pendingDuration: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pendingVariant = attrs(line.dropFirst(18)) }
            else if line.hasPrefix("#EXTINF:") { pendingDuration = Double(line.dropFirst(8).split(separator: ",").first ?? "") }
            else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attrs(line.dropFirst(11))
                key = ["method": a["METHOD"] ?? "", "uri": a["URI"].map(abs) ?? "", "iv": a["IV"] ?? ""]
            } else if !line.hasPrefix("#") && !line.isEmpty {
                if let v = pendingVariant {
                    variants.append(["url": abs(line), "bandwidth": Int(v["BANDWIDTH"] ?? "") ?? 0, "resolution": v["RESOLUTION"] ?? "", "name": v["NAME"] ?? ""])
                    pendingVariant = nil
                } else {
                    segments.append(["url": abs(line), "duration": pendingDuration ?? 0])
                    pendingDuration = nil
                }
            }
        }
        var out: [String: Any] = ["variants": variants, "segments": segments]
        if let key { out["key"] = key }
        return out
    }
}
