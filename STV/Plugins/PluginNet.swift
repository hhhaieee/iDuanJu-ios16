import Foundation
import Darwin

/// Per-plugin cookie jar. Never shared with `HTTPCookieStorage.shared`, other plugins, WebKit's default store,
/// TDLib or any built-in source. Persisted under the plugin's own directory.
final class PluginCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [HTTPCookie] = []
    private let file: URL?

    init(file: URL?) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file),
           let arr = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [[String: Any]] {
            cookies = arr.compactMap { HTTPCookie(properties: Dictionary(uniqueKeysWithValues: $0.map { (HTTPCookiePropertyKey($0.key), $0.value) })) }
        }
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        return cookies.filter { c in
            if let e = c.expiresDate, e < now { return false }
            if c.isSecure && url.scheme != "https" { return false }
            let d = c.domain.lowercased()
            let domainOK = d.hasPrefix(".") ? (host == String(d.dropFirst()) || host.hasSuffix(d)) : host == d
            return domainOK && path.hasPrefix(c.path.isEmpty ? "/" : c.path)
        }
    }

    func store(_ headers: [AnyHashable: Any], for url: URL) {
        var fields: [String: String] = [:]
        for (k, v) in headers { if let k = k as? String { fields[k] = "\(v)" } }
        let new = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !new.isEmpty else { return }
        add(new)
    }

    func add(_ new: [HTTPCookie]) {
        lock.lock()
        for c in new {
            cookies.removeAll { $0.name == c.name && $0.domain.lowercased() == c.domain.lowercased() && $0.path == c.path }
            if c.expiresDate.map({ $0 > Date() }) ?? true { cookies.append(c) }
        }
        if cookies.count > 300 { cookies.removeFirst(cookies.count - 300) }
        lock.unlock()
        persist()
    }

    var all: [HTTPCookie] { lock.lock(); defer { lock.unlock() }; return cookies }
    func clear() { lock.lock(); cookies = []; lock.unlock(); persist() }

    private func persist() {
        guard let file else { return }
        lock.lock()
        let arr = cookies.filter { !$0.isSessionOnly }.compactMap { c -> [String: Any]? in
            guard let p = c.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: p.map { ($0.key.rawValue, $0.value) })
        }
        lock.unlock()
        if let d = try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0) {
            try? d.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// Blocks loopback / private / link-local / multicast targets (protects the app's own 127.0.0.1 proxy,
/// the LAN, and DNS-rebinding of an allow-listed domain onto those ranges).
enum NetGuard {
    static func isBlockedIP(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network order
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _): return true
            case (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true                      // CGNAT
            case (224...255, _): return true                       // multicast / reserved / broadcast
            default: return false
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }                                  // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }           // ::1
            if b[0] & 0xfe == 0xfc { return true }                                        // fc00::/7
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                        // fe80::/10
            if b[0] == 0xff { return true }                                               // multicast
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {     // v4-mapped
                return isBlockedIP("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            return false
        }
        return false
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var a = in_addr(), b = in6_addr()
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, h, &a) == 1 || inet_pton(AF_INET6, h, &b) == 1
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Date, Bool)] = [:]
    /// Test hook: host → addresses.
    nonisolated(unsafe) static var resolverOverride: ((String) -> [String])?

    /// True when any address the host resolves to is in a blocked range. Blocking call (plugin thread).
    static func resolvesToBlocked(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        cacheLock.lock()
        if let (t, v) = cache[h], Date().timeIntervalSince(t) < 300 { cacheLock.unlock(); return v }
        cacheLock.unlock()
        let addrs = resolverOverride?(h) ?? resolve(h)
        let blocked = addrs.contains(where: isBlockedIP)
        cacheLock.lock(); cache[h] = (Date(), blocked); cacheLock.unlock()
        return blocked
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = a.pointee.ai_next
        }
        return out
    }
}

/// Test / UI-test hook that answers plugin requests offline.
enum PluginFixtures {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body: Data }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Reply?)?
}

/// The only network path a plugin has. Every request (and every redirect hop) must hit an allow-listed
/// domain that does not resolve to loopback/private ranges. Cookies come from the plugin's own jar only.
final class PluginNet: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Response { var status: Int; var url: URL; var headers: [String: String]; var body: Data }

    let pluginID: String
    let jar: PluginCookieJar
    private let policy: () -> DomainPolicy
    private let log: (String) -> Void
    private var session: URLSession!
    private let lock = NSLock()
    private var redirectInfo: [Int: (follow: Bool, blocked: String?, hops: Int)] = [:]
    private var window: [Date] = []
    static let maxBody = 20 * 1024 * 1024
    /// Unit tests: URLProtocol stubs (exercise the real redirect / cookie path).
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]?
    static let perMinute = 120

    init(pluginID: String, jar: PluginCookieJar, policy: @escaping () -> DomainPolicy, log: @escaping (String) -> Void) {
        self.pluginID = pluginID
        self.jar = jar
        self.policy = policy
        self.log = log
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.httpMaximumConnectionsPerHost = 4
        if let extra = Self.testProtocolClasses { c.protocolClasses = extra + (c.protocolClasses ?? []) }
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Throws E_PERMISSION when the URL is not reachable for this plugin.
    func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw PluginError.runtime(code: "E_PERMISSION", message: "只允许 http/https：\(url.absoluteString.prefix(80))")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { throw PluginError.runtime(code: "E_PERMISSION", message: "地址没有域名") }
        if NetGuard.isIPLiteral(host) { throw PluginError.runtime(code: "E_PERMISSION", message: "不允许直接访问 IP：\(host)") }
        if url.port != nil && url.port != 443 && url.port != 80 { throw PluginError.runtime(code: "E_PERMISSION", message: "不允许非标准端口：\(host):\(url.port!)") }
        guard policy().allows(host) else { throw PluginError.runtime(code: "E_PERMISSION", message: "域名未授权：\(host)") }
        if PluginFixtures.responder == nil, NetGuard.resolvesToBlocked(host) {
            throw PluginError.runtime(code: "E_PERMISSION", message: "\(host) 解析到本机/内网地址，已拦截")
        }
    }

    func allowed(_ url: URL) -> Bool { (try? check(url)) != nil }

    static let forbiddenHeaders: Set<String> = ["cookie", "cookie2", "host", "authorization", "proxy-authorization", "connection",
                                                "content-length", "transfer-encoding", "te", "upgrade", "proxy-connection", "keep-alive"]

    /// Synchronous on purpose: runs on the plugin's own thread while the script waits.
    func perform(_ req0: URLRequest, follow: Bool = true, timeout: TimeInterval = 20) throws -> Response {
        guard let url = req0.url else { throw PluginError.runtime(code: "E_PERMISSION", message: "地址无效") }
        do { try check(url) } catch { log("✕ 拦截 \(url.host ?? "?") · \(error.localizedDescription)"); throw error }
        try rateLimit()
        var req = req0
        req.timeoutInterval = min(max(timeout, 1), 60)
        for (k, _) in req.allHTTPHeaderFields ?? [:] where Self.forbiddenHeaders.contains(k.lowercased()) { req.setValue(nil, forHTTPHeaderField: k) }
        applyCookies(&req)
        let start = Date()
        if let fx = PluginFixtures.responder {
            guard let r = fx(req) else { throw PluginError.runtime(code: "E_NETWORK", message: "fixture missing \(url.absoluteString)") }
            log("\(r.status) \(req.httpMethod ?? "GET") \(url.host ?? "")\(url.path) · fixture")
            return Response(status: r.status, url: url, headers: r.headers, body: r.body)
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(PluginError.runtime(code: "E_NETWORK", message: "no response"))
        let task = session.dataTask(with: req) { d, r, e in
            if let e { result = .failure(e) }
            else if let h = r as? HTTPURLResponse { result = .success((d ?? Data(), h)) }
            sem.signal()
        }
        lock.lock(); redirectInfo[task.taskIdentifier] = (follow, nil, 0); lock.unlock()
        task.resume()
        sem.wait()
        lock.lock(); let info = redirectInfo.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if let blocked = info?.blocked {
            log("✕ 跳转被拦截 \(url.host ?? "") → \(blocked)")
            throw PluginError.runtime(code: "E_PERMISSION", message: "跳转到未授权地址：\(blocked)")
        }
        switch result {
        case .failure(let e):
            let ns = e as NSError
            let code = ns.code == NSURLErrorTimedOut ? "E_TIMEOUT" : "E_NETWORK"
            log("✕ \(req.httpMethod ?? "GET") \(url.host ?? "")\(url.path) · \(ns.localizedDescription)")
            throw PluginError.runtime(code: code, message: "\(url.host ?? "")：\(ns.localizedDescription)")
        case .success(let (data, http)):
            let final = http.url ?? url
            jar.store(http.allHeaderFields, for: final)
            if data.count > Self.maxBody { throw PluginError.runtime(code: "E_NETWORK", message: "响应超过 20MB") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k.lowercased()] = "\(v)" } }
            log("\(http.statusCode) \(req.httpMethod ?? "GET") \(final.host ?? "")\(final.path) · \(data.count)B · \(Int(Date().timeIntervalSince(start) * 1000))ms")
            return Response(status: http.statusCode, url: final, headers: headers, body: data)
        }
    }

    private func applyCookies(_ req: inout URLRequest) {
        guard let u = req.url else { return }
        let cs = jar.cookies(for: u)
        req.setValue(nil, forHTTPHeaderField: "Cookie")
        if !cs.isEmpty { for (k, v) in HTTPCookie.requestHeaderFields(with: cs) { req.setValue(v, forHTTPHeaderField: k) } }
    }

    private func rateLimit() throws {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        window.removeAll { now.timeIntervalSince($0) > 60 }
        guard window.count < Self.perMinute else { throw PluginError.runtime(code: "E_RATE_LIMIT", message: "每分钟最多 \(Self.perMinute) 次请求") }
        window.append(now)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let from = response.url { jar.store(response.allHeaderFields, for: from) }
        lock.lock()
        var info = redirectInfo[task.taskIdentifier] ?? (true, nil, 0)
        info.hops += 1
        lock.unlock()
        guard info.follow, info.hops <= 10 else { completionHandler(nil); return }
        guard let next = request.url else { completionHandler(nil); return }
        if let _ = try? check(next) {
            var r = request
            applyCookies(&r)
            lock.lock(); redirectInfo[task.taskIdentifier] = info; lock.unlock()
            completionHandler(r)
        } else {
            info.blocked = next.host ?? next.absoluteString
            lock.lock(); redirectInfo[task.taskIdentifier] = info; lock.unlock()
            task.cancel()
            completionHandler(nil)
        }
    }
}
