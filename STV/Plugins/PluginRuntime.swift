import Foundation
import CQuickJS
import Security

/// Dedicated thread per plugin (8 MB stack; QuickJS stack cap 2 MB). Jobs run strictly one at a time.
final class PluginThread: Thread, @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopping = false

    init(name: String) {
        super.init()
        self.name = name
        stackSize = 8 << 20
        qualityOfService = .userInitiated
    }

    override func main() {
        while true {
            cond.lock()
            while jobs.isEmpty && !stopping { cond.wait() }
            if jobs.isEmpty && stopping { cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            autoreleasepool { job() }
        }
    }

    func enqueue(_ job: @escaping () -> Void) {
        cond.lock(); jobs.append(job); cond.signal(); cond.unlock()
    }

    func stop() { cond.lock(); stopping = true; cond.signal(); cond.unlock() }
}

/// What a plugin's host calls can touch: its own manifest, its own cookie jar / storage / settings / log.
final class PluginHostContext: @unchecked Sendable {
    let id: String
    let manifest: PluginManifest
    let dir: URL
    let net: PluginNet
    let html = HTMLSession()
    private var settings: [String: String]
    private let lock = NSLock()
    private var kv: [String: Any]
    private var requestsThisCall = 0
    static let maxRequestsPerCall = 60
    static let storageLimit = 1 << 20
    var learnedUA: String?

    init(manifest: PluginManifest, dir: URL, settings: [String: String], extraDomains: [String], learnedUA: String?) {
        id = manifest.id
        self.manifest = manifest
        self.dir = dir
        self.settings = settings
        self.learnedUA = learnedUA
        let jar = PluginCookieJar(file: dir.appendingPathComponent("cookies.plist"))
        let policy = DomainPolicy(manifest.httpDomains + extraDomains)
        let pid = manifest.id
        net = PluginNet(pluginID: pid, jar: jar, policy: { policy }, log: { PluginLog.add(pid, $0) })
        let f = dir.appendingPathComponent("storage.json")
        kv = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func beginCall() { requestsThisCall = 0 }
    func endCall() { html.reset() }

    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    func handle(_ name: String, _ argsJSON: String) -> Result<String?, PluginError> {
        do {
            let a = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
            func str(_ k: String) -> String { a[k] as? String ?? (a[k].map { "\($0)" } ?? "") }
            func out(_ v: Any) throws -> String? {
                let d = try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])
                return String(decoding: d, as: UTF8.self)
            }
            switch name {
            case "host.version": return .success(try out(["app": AppInfo.version, "spec": "idj1"]))
            case "host.has":
                let caps: Set<String> = ["http", "html", "crypto.hash", "crypto.hmac", "crypto.aes", "crypto.rsa", "codec", "m3u8", "storage", "settings", "url",
                                         "image.stripes", "image.aes"]
                return .success(try out(caps.contains(str("cap"))))
            case "http.request": return .success(try out(try httpRequest(a)))
            case "http.allowed": return .success(try out(URL(string: str("url")).map(net.allowed) ?? false))
            case "html.parse": return .success(try out(try html.parse(str("text"))))
            case "html.select": return .success(try out(try html.select(a["id"] as? Int ?? 0, str("q"), first: a["first"] as? Bool ?? false)))
            case "html.text": return .success(try out(try html.text(a["id"] as? Int ?? 0)))
            case "html.html": return .success(try out(try html.html(a["id"] as? Int ?? 0, outer: false)))
            case "html.outer": return .success(try out(try html.html(a["id"] as? Int ?? 0, outer: true)))
            case "html.attr": return .success(try out(try html.attr(a["id"] as? Int ?? 0, str("k"))))
            case "url.resolve":
                let base = URL(string: str("base"))
                return .success(try out(URL(string: str("rel"), relativeTo: base)?.absoluteString ?? str("rel")))
            case "crypto.hash":
                let d = try PluginCrypto.decode(str("data"), a["in"] as? String)
                return .success(try out(try PluginCrypto.encode(try PluginCrypto.hash(alg: str("alg"), d), a["out"] as? String)))
            case "crypto.hmac":
                let k = try PluginCrypto.decode(str("key"), a["keyEncoding"] as? String)
                let d = try PluginCrypto.decode(str("data"), a["in"] as? String)
                return .success(try out(try PluginCrypto.encode(try PluginCrypto.hmac(alg: str("alg"), key: k, d), a["out"] as? String)))
            case "crypto.aes":
                let enc = str("op") == "encrypt"
                let kenc = a["keyEncoding"] as? String
                let key = try PluginCrypto.decode(str("key"), kenc)
                let iv = a["iv"] as? String
                let data = try PluginCrypto.decode(str("data"), a["in"] as? String ?? (enc ? "utf8" : "base64"))
                let r = try PluginCrypto.aes(encrypt: enc, mode: a["mode"] as? String ?? "cbc", key: key,
                                             iv: try iv.map { try PluginCrypto.decode($0, a["ivEncoding"] as? String ?? kenc) },
                                             data: data, padding: (a["padding"] as? String ?? "pkcs7") != "none")
                return .success(try out(try PluginCrypto.encode(r, a["out"] as? String ?? (enc ? "base64" : "utf8"))))
            case "crypto.rsa":
                let pem = str("publicKeyPem")
                let data = try PluginCrypto.decode(str("data"), a["in"] as? String)
                if str("op") == "verify" {
                    let sig = try PluginCrypto.decode(str("signature"), "base64")
                    return .success(try out(try PluginCrypto.rsaVerify(pem: pem, data: data, signature: sig, hash: a["hash"] as? String ?? "sha256")))
                }
                let r = try PluginCrypto.rsaEncrypt(pem: pem, data: data, oaep: str("padding") == "oaep")
                return .success(try out(try PluginCrypto.encode(r, a["out"] as? String ?? "base64")))
            case "crypto.random":
                let n = min(max(a["n"] as? Int ?? 16, 1), 1024)
                return .success(try out(Bytes.hex(Bytes.random(n))))
            case "codec.convert":
                let d = try PluginCrypto.decode(str("data"), a["from"] as? String)
                return .success(try out(try PluginCrypto.encode(d, a["to"] as? String)))
            case "codec.gunzip":
                let d = try PluginCrypto.decode(str("data"), "base64")
                return .success(try out(String(decoding: try PluginCrypto.gunzip(d), as: UTF8.self)))
            case "codec.unpack": return .success(try out(JSUnpacker.unpack(str("js")) ?? ""))
            case "m3u8.parse": return .success(try out(PluginM3U8.parse(str("text"), base: URL(string: str("base")))))
            case "storage.get":
                try needStorage()
                lock.lock(); let v = kv[str("k")]; lock.unlock()
                return .success(try out(v ?? NSNull()))
            case "storage.set", "storage.remove":
                try needStorage()
                lock.lock()
                var next = kv
                if name == "storage.remove" || a["v"] is NSNull { next[str("k")] = nil } else { next[str("k")] = a["v"] }
                let data = (try? JSONSerialization.data(withJSONObject: next)) ?? Data()
                guard data.count <= Self.storageLimit else { lock.unlock(); throw PluginError.runtime(code: "E_STORAGE_FULL", message: "插件存储超过 1MB") }
                kv = next
                lock.unlock()
                try? data.write(to: dir.appendingPathComponent("storage.json"), options: .atomic)
                return .success(nil)
            case "settings.all":
                var visible = settings
                for s in manifest.settings ?? [] where s.type == "secret" { visible[s.key] = "@@secret:\(s.key)@@" }
                for s in manifest.settings ?? [] where visible[s.key] == nil { visible[s.key] = s.default ?? "" }
                return .success(try out(visible))
            case "log":
                PluginLog.add(id, "📝 " + String(str("m").prefix(500)))
                return .success(nil)
            default:
                throw PluginError.runtime(code: "E_UNSUPPORTED", message: "未知的宿主能力 \(name)")
            }
        } catch let e as PluginError {
            return .failure(e)
        } catch {
            return .failure(.runtime(code: "E_INTERNAL", message: error.localizedDescription))
        }
    }

    private func needStorage() throws {
        guard manifest.allowsStorage else { throw PluginError.runtime(code: "E_PERMISSION", message: "manifest 没有声明 permissions.storage") }
    }

    /// `@@secret:key@@` → Keychain value, only ever inside a request to an allow-listed host.
    func substituteSecrets(_ s: String) -> String {
        guard s.contains("@@secret:") else { return s }
        var r = s
        for st in manifest.settings ?? [] where st.type == "secret" {
            let token = "@@secret:\(st.key)@@"
            if r.contains(token) { r = r.replacingOccurrences(of: token, with: PluginSecrets.get(id, st.key) ?? "") }
        }
        return r
    }

    private func httpRequest(_ a: [String: Any]) throws -> [String: Any] {
        requestsThisCall += 1
        guard requestsThisCall <= Self.maxRequestsPerCall else {
            throw PluginError.runtime(code: "E_RATE_LIMIT", message: "单次调用最多 \(Self.maxRequestsPerCall) 个请求")
        }
        guard let url = URL(string: substituteSecrets(a["url"] as? String ?? "")) else { throw PluginError.runtime(code: "E_PERMISSION", message: "地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = (a["method"] as? String ?? "GET").uppercased()
        req.setValue(learnedUA ?? Self.defaultUA, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        for (k, v) in a["headers"] as? [String: Any] ?? [:] { req.setValue(substituteSecrets("\(v)"), forHTTPHeaderField: k) }
        if let body = a["body"], !(body is NSNull) {
            switch a["bodyType"] as? String ?? (body is String ? "text" : "json") {
            case "json":
                req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
                if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            case "form":
                let o = body as? [String: Any] ?? [:]
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
                req.httpBody = Data(o.keys.sorted().map { k in
                    "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(substituteSecrets("\(o[k]!)").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
                }.joined(separator: "&").utf8)
                if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            case "base64": req.httpBody = try PluginCrypto.decode("\(body)", "base64")
            default: req.httpBody = Data(substituteSecrets("\(body)").utf8)
            }
        }
        let timeout = min(Double(a["timeout"] as? Int ?? 20_000) / 1000, 60)
        let follow = (a["redirect"] as? String ?? "follow") != "manual"
        wantJSON = (a["responseType"] as? String) == "json"
        var r = try net.perform(req, follow: follow, timeout: timeout)
        var text: String? = nil
        if (a["responseType"] as? String ?? "text") != "base64" { text = Self.decodeText(r.body, contentType: r.headers["content-type"]) }
        let cfMode = a["cloudflare"] as? String ?? "auto"
        if let t = text, CFDetect.isChallenge(status: r.status, headers: r.headers, body: t) {
            guard manifest.allowsCF, cfMode != "off" else {
                PluginLog.add(id, "⚠︎ \(url.host ?? "") 返回 Cloudflare 验证页（插件未申请 cloudflare 权限）")
                return pack(r, text)
            }
            PluginLog.add(id, "☁︎ \(url.host ?? "") 需要 Cloudflare 验证，后台验证中…")
            if PluginCF.solveBlocking(self, url: r.url) {
                req.setValue(learnedUA ?? Self.defaultUA, forHTTPHeaderField: "User-Agent")
                if let again = try? net.perform(req, follow: follow, timeout: timeout) {
                    let t2 = Self.decodeText(again.body, contentType: again.headers["content-type"])
                    if !CFDetect.isChallenge(status: again.status, headers: again.headers, body: t2) {
                        PluginLog.add(id, "☁︎ 验证通过，App 请求成功")
                        r = again
                        return pack(r, (a["responseType"] as? String) == "base64" ? nil : t2)
                    }
                }
                if req.httpMethod == "GET", let page = PluginCF.fetchBlocking(self, url: r.url) {
                    PluginLog.add(id, "☁︎ App 请求仍被拦，改用验证浏览器取页面")
                    return ["status": 200, "url": r.url.absoluteString, "headers": [String: String](), "body": page]
                }
            }
            throw PluginError.runtime(code: "E_CF_REQUIRED", message: r.url.absoluteString)
        }
        return pack(r, text)
    }

    private var wantJSON = false
    private func pack(_ r: PluginNet.Response, _ text: String?) -> [String: Any] {
        var body: Any = text ?? r.body.base64EncodedString()
        if wantJSON, let t = text {
            body = (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        }
        return ["status": r.status, "url": r.url.absoluteString, "headers": r.headers, "body": body]
    }

    static func decodeText(_ d: Data, contentType: String?) -> String {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("gbk") || ct.contains("gb2312") || ct.contains("gb18030") {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let s = String(data: d, encoding: enc) { return s }
        }
        if ct.contains("big5") {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            if let s = String(data: d, encoding: enc) { return s }
        }
        return String(decoding: d, as: UTF8.self)
    }
}

private let idjHostCallback: idj_host_fn = { opaque, name, args, isErr in
    guard let opaque, let name else { return nil }
    let ctx = Unmanaged<PluginHostContext>.fromOpaque(opaque).takeUnretainedValue()
    switch ctx.handle(String(cString: name), args.map { String(cString: $0) } ?? "null") {
    case .success(let s): return s.flatMap { strdup($0) }
    case .failure(let e): isErr?.pointee = 1; return strdup(e.json)
    }
}

/// One loaded plugin: its own thread, QuickJS runtime/heap and host context.
final class PluginInstance: @unchecked Sendable {
    static let memoryLimit = 64 << 20
    static let stackLimit = 2 << 20
    let manifest: PluginManifest
    let host: PluginHostContext
    private let thread: PluginThread
    private var box: OpaquePointer?
    private(set) var exported: Set<String> = []

    init(manifest: PluginManifest, source: String, dir: URL, settings: [String: String], extraDomains: [String], learnedUA: String?) throws {
        self.manifest = manifest
        host = PluginHostContext(manifest: manifest, dir: dir, settings: settings, extraDomains: extraDomains, learnedUA: learnedUA)
        thread = PluginThread(name: "plugin." + manifest.id)
        thread.start()
        var failure: PluginError?
        let sem = DispatchSemaphore(value: 0)
        let h = host
        thread.enqueue { [self] in
            let b = idj_new(Self.memoryLimit, Self.stackLimit, idjHostCallback, Unmanaged.passUnretained(h).toOpaque())
            var err: UnsafeMutablePointer<CChar>?
            if let b, idj_load(b, PluginPrelude.source, source, manifest.entry, 5, &err) == 0 {
                box = b
                exported = Set(["init", "home", "category", "search", "detail", "play", "pages", "danmaku"].filter { idj_has(b, $0) != 0 })
            } else {
                failure = err.map { PluginError.runtime(json: String(cString: $0)) } ?? .runtime(code: "E_INTERNAL", message: "QuickJS 初始化失败")
                if let err { idj_str_free(err) }
                if let b { idj_free(b) }
            }
            h.endCall()
            sem.signal()
        }
        sem.wait()
        if let failure { thread.stop(); throw failure }
    }

    deinit { shutdown() }

    func shutdown() {
        guard let b = box else { return }
        box = nil
        let t = thread
        let h = host
        t.enqueue { idj_free(b); _ = h }
        t.stop()
    }

    /// Calls `default[fn](arg)` on the plugin thread. `timeout` limits script execution time (host calls excluded).
    func call(_ fn: String, _ arg: [String: Any], timeout: Double = 10) async throws -> Any {
        let argJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: arg)) ?? Data("{}".utf8), as: UTF8.self)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            thread.enqueue { [self] in
                guard let b = box else { cont.resume(throwing: PluginError.runtime(code: "E_INTERNAL", message: "插件已停用")); return }
                host.beginCall()
                var err: UnsafeMutablePointer<CChar>?
                let r = idj_call(b, fn, argJSON, timeout, &err)
                host.endCall()
                if let r {
                    let s = String(cString: r)
                    idj_str_free(r)
                    let v = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) ?? NSNull()
                    cont.resume(returning: v)
                } else {
                    let e = err.map { PluginError.runtime(json: String(cString: $0)) } ?? .runtime(code: "E_INTERNAL", message: "unknown")
                    if let err { idj_str_free(err) }
                    cont.resume(throwing: e)
                }
            }
        }
    }

    /// Tests: evaluate a snippet inside the same sandbox (still eval-less).
    func evalForTest(_ src: String) async throws -> Any {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            thread.enqueue { [self] in
                guard let b = box else { cont.resume(throwing: PluginError.runtime(code: "E_INTERNAL", message: "no box")); return }
                var err: UnsafeMutablePointer<CChar>?
                if let r = idj_eval_script(b, src, 2, &err) {
                    let s = String(cString: r); idj_str_free(r)
                    cont.resume(returning: (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) ?? NSNull())
                } else {
                    let e = err.map { PluginError.runtime(json: String(cString: $0)) } ?? .runtime(code: "E_INTERNAL", message: "unknown")
                    if let err { idj_str_free(err) }
                    cont.resume(throwing: e)
                }
            }
        }
    }

    var memoryUsed: Int {
        let sem = DispatchSemaphore(value: 0)
        var n = 0
        thread.enqueue { [self] in if let b = box { n = idj_memory_used(b) }; sem.signal() }
        sem.wait()
        return n
    }
}

/// Plugin secrets (settings of type "secret"). Stored by the host in the Keychain; scripts only ever see the
/// `@@secret:key@@` handle, which the host substitutes inside requests to the plugin's own allow-listed domains.
enum PluginSecrets {
    static let service = "stv.plugin.secret"
    static func get(_ plugin: String, _ key: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: plugin + "#" + key,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ plugin: String, _ key: String, _ value: String?) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: plugin + "#" + key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func removeAll(_ plugin: String, keys: [String]) { for k in keys { set(plugin, k, nil) } }
}

/// Per-plugin request / error log (memory ring, persisted to the plugin's directory).
enum PluginLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rings: [String: [String]] = [:]
    static let limit = 300
    static let changed = Notification.Name("stv.plugin.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    static func add(_ id: String, _ line: String) {
        let l = fmt.string(from: Date()) + " " + line
        lock.lock()
        var r = rings[id] ?? load(id)
        r.append(l)
        if r.count > limit { r.removeFirst(r.count - limit) }
        rings[id] = r
        lock.unlock()
        #if DEBUG
        print("[plugin \(id)] \(line)")
        #endif
        persist(id)
    }

    static func lines(_ id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if rings[id] == nil { rings[id] = load(id) }
        return rings[id] ?? []
    }

    static func clear(_ id: String) { lock.lock(); rings[id] = []; lock.unlock(); persist(id) }

    private static func file(_ id: String) -> URL { PluginPaths.dir(id).appendingPathComponent("log.txt") }
    private static func load(_ id: String) -> [String] {
        (try? String(contentsOf: file(id), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
    private static let queue = DispatchQueue(label: "stv.plugin.log", qos: .utility)
    private static func persist(_ id: String) {
        queue.async {
            let text = lines(id).joined(separator: "\n")
            try? text.write(to: file(id), atomically: true, encoding: .utf8)
        }
    }
}

enum PluginPaths {
    static var root: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = u
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        return u
    }
    static func dir(_ id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let u = root.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
