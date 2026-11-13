import Foundation
import CryptoKit

/// idj1 plugin manifest (see docs/plugins/SPEC_ZH.md). Only the idj1 format is accepted — there is no
/// FongMi/CatVod compatibility mode.
enum PluginType: String, Codable, CaseIterable, Hashable {
    case video, shortdrama, comic, live
    var label: String { switch self { case .video: "长视频"; case .shortdrama: "短剧"; case .comic: "漫画"; case .live: "直播" } }
    var requiredCapabilities: [String] {
        switch self {
        case .video, .shortdrama: ["detail", "play"]
        case .comic: ["detail", "pages"]
        case .live: ["play"]
        }
    }
}

struct PluginManifest: Codable, Hashable {
    struct Author: Codable, Hashable { var name: String; var contact: String? }
    struct Permissions: Codable, Hashable {
        var http: [String]
        var media: [String]?
        var cloudflare: Bool?
        var storage: Bool?
        var login: Bool?
    }
    struct Setting: Codable, Hashable, Identifiable {
        var key: String
        var name: String
        /// text | select | secret
        var type: String
        var `default`: String?
        var options: [String]?
        var id: String { key }
    }
    struct Update: Codable, Hashable { var url: String?; var channel: String? }
    struct Signature: Codable, Hashable {
        /// Only "ed25519".
        var alg: String
        /// base64 raw 32-byte public key.
        var publicKey: String
        /// base64 signature over `PluginManifest.signingPayload`.
        var value: String
    }
    struct Integrity: Codable, Hashable { var files: [String: String]?; var signature: Signature? }

    var schema: Int
    var id: String
    var name: String
    var version: String
    var author: Author
    var description: String?
    var type: PluginType
    var adult: Bool
    var language: [String]?
    var minAppVersion: String
    var entry: String
    var icon: String?
    var permissions: Permissions
    var capabilities: [String]
    var settings: [Setting]?
    var update: Update?
    var integrity: Integrity?

    var httpDomains: [String] { permissions.http }
    var mediaDomains: [String] { permissions.media ?? permissions.http }
    var allowsCF: Bool { permissions.cloudflare ?? false }
    var allowsStorage: Bool { permissions.storage ?? false }
    var allowsLogin: Bool { permissions.login ?? false }

    static func decode(_ data: Data) throws -> PluginManifest {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = o["compat"] as? String, c != "idj1" {
            throw PluginError.invalidManifest(["不支持兼容模式 compat=\(c)：只接受 idj1 格式的插件"])
        }
        do { return try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch let DecodingError.keyNotFound(k, _) { throw PluginError.invalidManifest(["manifest 缺少字段 \(k.stringValue)"]) }
        catch let DecodingError.typeMismatch(_, c) { throw PluginError.invalidManifest(["manifest 字段类型不对：\(c.codingPath.map(\.stringValue).joined(separator: "."))"]) }
        catch let DecodingError.dataCorrupted(c) {
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            throw PluginError.invalidManifest([path.isEmpty ? "manifest 不是合法 JSON" : "manifest 字段取值不对：\(path)"])
        }
        catch { throw PluginError.invalidManifest(["manifest 解析失败：\(error.localizedDescription)"]) }
    }

    /// All problems at once (empty = valid).
    func problems(appVersion: String = AppInfo.version) -> [String] {
        var p: [String] = []
        if schema != 1 { p.append("schema 必须为 1") }
        if id.count > 100 || id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+){2,}$"#, options: .regularExpression) == nil { p.append("id 必须是反向域名形式（小写），如 com.yourname.site") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 40 { p.append("name 不能为空且不超过 40 字") }
        if Self.semver(version) == nil { p.append("version 必须是 x.y.z") }
        if author.name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("author.name 不能为空") }
        if Self.semver(minAppVersion, loose: true) == nil { p.append("minAppVersion 格式不对") }
        else if Self.compare(minAppVersion, appVersion) > 0 { p.append("需要 App \(minAppVersion) 或更高版本（当前 \(appVersion)）") }
        if entry.range(of: #"^[A-Za-z0-9_-]+\.js$"#, options: .regularExpression) == nil { p.append("entry 必须是同目录下的 .js 文件名") }
        if permissions.http.isEmpty { p.append("permissions.http 至少声明一个域名") }
        for d in permissions.http + (permissions.media ?? []) where DomainRule(d) == nil {
            p.append("域名格式不对：\(d)（只允许 example.com 或 *.example.com）")
        }
        for c in type.requiredCapabilities where !capabilities.contains(c) { p.append("type=\(type.rawValue) 必须实现 \(c)") }
        for s in settings ?? [] {
            if s.key.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,31}$"#, options: .regularExpression) == nil { p.append("settings.key 不合法：\(s.key)") }
            if !["text", "select", "secret"].contains(s.type) { p.append("settings.type 只能是 text/select/secret：\(s.key)") }
        }
        if let u = update?.url, !u.isEmpty, URL(string: u)?.scheme != "https" { p.append("update.url 必须是 https") }
        if let sig = integrity?.signature, sig.alg != "ed25519" { p.append("signature.alg 只支持 ed25519") }
        return p
    }

    /// Canonical bytes covered by the author signature.
    static func signingPayload(id: String, version: String, fileHashes: [String: String]) -> Data {
        let lines = fileHashes.keys.sorted().map { "\($0):\(fileHashes[$0]!)" }
        return Data((["idj1", id, version] + lines).joined(separator: "\n").utf8)
    }

    static func fileHash(_ data: Data) -> String { "sha256-" + Data(SHA256.hash(data: data)).base64EncodedString() }

    static func semver(_ v: String, loose: Bool = false) -> [Int]? {
        let parts = v.split(separator: ".").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), loose ? (1...3).contains(parts.count) : parts.count == 3 else { return nil }
        return parts.map { $0! }
    }
    /// -1 / 0 / 1
    static func compare(_ a: String, _ b: String) -> Int {
        let x = semver(a, loose: true) ?? [0], y = semver(b, loose: true) ?? [0]
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5" }
}

/// `example.com` (exact host) or `*.example.com` (the domain itself and any subdomain).
struct DomainRule: Hashable, Codable {
    let suffix: String
    let wildcard: Bool
    init?(_ raw: String) {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let wild = s.hasPrefix("*.")
        let d = wild ? String(s.dropFirst(2)) : s
        guard d.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              d.rangeOfCharacter(from: CharacterSet.letters) != nil   // no bare IPv4
        else { return nil }
        suffix = d; wildcard = wild
    }
    func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == suffix { return true }
        return wildcard && h.hasSuffix("." + suffix)
    }
    var text: String { wildcard ? "*." + suffix : suffix }
}

struct DomainPolicy: Hashable {
    let rules: [DomainRule]
    init(_ list: [String]) { rules = list.compactMap(DomainRule.init) }
    func allows(_ host: String) -> Bool { rules.contains { $0.matches(host) } }
}

/// What changed between two versions — shown before an update is applied.
struct PermissionDiff: Hashable {
    var addedHTTP: [String] = []
    var removedHTTP: [String] = []
    var addedMedia: [String] = []
    var removedMedia: [String] = []
    var flags: [String] = []      // e.g. "新增：允许过 Cloudflare 验证"
    var needsConsent: Bool { !addedHTTP.isEmpty || !addedMedia.isEmpty || flags.contains { $0.hasPrefix("新增") } }
    var isEmpty: Bool { addedHTTP.isEmpty && removedHTTP.isEmpty && addedMedia.isEmpty && removedMedia.isEmpty && flags.isEmpty }

    init() {}
    init(old: PluginManifest, new: PluginManifest) {
        let oh = Set(old.httpDomains), nh = Set(new.httpDomains), om = Set(old.mediaDomains), nm = Set(new.mediaDomains)
        addedHTTP = nh.subtracting(oh).sorted(); removedHTTP = oh.subtracting(nh).sorted()
        addedMedia = nm.subtracting(om).sorted(); removedMedia = om.subtracting(nm).sorted()
        func flag(_ name: String, _ a: Bool, _ b: Bool) { if a != b { flags.append((b ? "新增：" : "取消：") + name) } }
        flag("允许过 Cloudflare 验证", old.allowsCF, new.allowsCF)
        flag("插件私有存储", old.allowsStorage, new.allowsStorage)
        flag("请你登录该站点", old.allowsLogin, new.allowsLogin)
        flag("成人内容", old.adult, new.adult)
        if old.type != new.type { flags.append("新增：类型改为 \(new.type.label)") }
    }
}

enum PluginError: LocalizedError, Equatable {
    case invalidManifest([String])
    case integrity(String)
    case install(String)
    /// Error raised inside the plugin or by a host capability (code = E_…).
    case runtime(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let p): "插件格式不对：" + p.joined(separator: "；")
        case .integrity(let m): "插件校验失败：\(m)"
        case .install(let m): "安装失败：\(m)"
        case .runtime(let code, let m): Self.describe(code, m)
        }
    }
    var code: String { if case .runtime(let c, _) = self { return c }; return "E_INSTALL" }

    static func describe(_ code: String, _ m: String) -> String {
        switch code {
        case "E_CF_REQUIRED": "站点需要 Cloudflare 验证。点「去验证」完成一次后重试。"
        case "E_PERMISSION": "插件访问被拦截：\(m)"
        case "E_TIMEOUT": "插件执行超时（\(m)）"
        case "E_MEMORY": "插件内存超限，已中断"
        case "E_PARSE": "解析失败，源可能已改版，请更新插件：\(m)"
        case "E_NOT_FOUND": "内容不存在：\(m)"
        case "E_UNSUPPORTED": "这个插件不支持该操作"
        case "E_NETWORK": "网络错误：\(m)"
        case "E_HTTP": "站点返回错误：\(m)"
        case "E_RATE_LIMIT": "请求太频繁，稍后再试：\(m)"
        case "E_LOGIN_REQUIRED": "需要登录：\(m)"
        default: "\(m) (\(code))"
        }
    }

    static func runtime(json: String) -> PluginError {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return .runtime(code: o["code"] as? String ?? "E_INTERNAL", message: o["message"] as? String ?? json)
    }
    var json: String {
        let (c, m): (String, String) = { if case .runtime(let c, let m) = self { return (c, m) }; return ("E_INTERNAL", errorDescription ?? "") }()
        return String(decoding: (try? JSONSerialization.data(withJSONObject: ["code": c, "message": m])) ?? Data(), as: UTF8.self)
    }
}
