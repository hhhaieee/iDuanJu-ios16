import Foundation
import CommonCrypto
import Compression
import CryptoKit
import Security

/// Regex "all in one" match (`:regex` list rules): group texts, `$0` = whole match.
struct LegadoGroups { var groups: [String] }

/// State shared by one operation (search / 详情 / 目录 / 正文): variables from `@put`, the book, the JS engine.
/// `java.put` / `java.get` variables, persisted like Legado's book / source variables.
enum LegadoVars {
    private static let lock = NSLock()
    private static let key = "stv.legado.vars"
    nonisolated(unsafe) private static var cache: [String: [String: String]]?

    private static func load() -> [String: [String: String]] {
        if let c = cache { return c }
        let c = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        cache = c
        return c
    }
    static func get(_ scope: String, _ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return load()[scope]?[k] }
    static func put(_ scope: String, _ k: String, _ v: String) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[scope, default: [:]][k] = v
        cache = all
        UserDefaults.standard.set(all, forKey: key)
    }
}

final class LegadoContext {
    let source: LegadoSource
    /// Operation-local values (`@put` inside one rule run) — `java.put` also persists them.
    var vars: [String: String] = [:]
    private var inHeaders = false
    /// Login page actions may open the in-app browser; normal operations may not.
    var interactive = false
    /// Jsoup handles for scripts (`org.jsoup.Jsoup.parse`, `java.getElement`): index into this table.
    private var jsNodes: [LegadoNode] = []
    private func handle(_ n: LegadoNode) -> Int { jsNodes.append(n); return jsNodes.count - 1 }
    private func nodes(_ v: Any?) -> [LegadoNode] { ((v as? [Any]) ?? []).compactMap { ($0 as? Int).flatMap { jsNodes.indices.contains($0) ? jsNodes[$0] : nil } } }
    private var sourceScope: String { "s|" + source.bookSourceUrl }
    private var bookScope: String? { (book["bookUrl"] as? String).flatMap { $0.isEmpty ? nil : "b|" + source.bookSourceUrl + "|" + $0 } }

    func putVar(_ k: String, _ v: String) {
        vars[k] = v
        LegadoVars.put(bookScope ?? sourceScope, k, v)
    }

    func getVar(_ k: String) -> String {
        vars[k] ?? bookScope.flatMap { LegadoVars.get($0, k) } ?? LegadoVars.get(sourceScope, k) ?? ""
    }
    var book: [String: Any] = [:]
    var chapter: [String: Any]?
    var key: String?
    var page: Int?
    var log: [String] = []
    let js = LegadoJS()
    fileprivate var stack: [LegadoAnalyzer] = []

    init(source: LegadoSource) {
        self.source = source
        js.jsLib = source.jsLib
        js.handler = { [unowned self] name, args in try self.host(name, args as? [String: Any] ?? [:]) }
    }

    var sourceJSON: [String: Any] {
        // Scripts read these (乐读 evals its bookSourceComment; others read header / loginUrl).
        ["bookSourceUrl": source.bookSourceUrl, "bookSourceName": source.bookSourceName, "bookSourceGroup": source.bookSourceGroup ?? "",
            "bookSourceComment": source.bookSourceComment ?? "", "header": source.header ?? "", "loginUrl": source.loginUrl ?? "",
            "searchUrl": source.searchUrl ?? "", "exploreUrl": source.exploreUrl ?? "", "bookSourceType": source.bookSourceType ?? 0]
    }

    private func host(_ name: String, _ a: [String: Any]) throws -> Any? {
        func s(_ k: String) -> String { a[k] as? String ?? "" }
        switch name {
        case "ajax":
            let r = try LegadoURL.request(s("url"), ctx: self, base: source.bookSourceUrl)
            return try r.fetch().text
        case "connect":
            var r = try LegadoURL.request(s("url"), ctx: self, base: source.bookSourceUrl)
            if let m = a["method"] as? String { r.request.httpMethod = m; r.request.httpBody = Data(s("body").utf8) }
            if let h = a["headers"] as? [String: Any] { for (k, v) in h { r.request.setValue("\(v)", forHTTPHeaderField: k) } }
            let resp = try r.fetch()
            return ["body": resp.text, "status": resp.status, "url": resp.url.absoluteString, "headers": resp.headers]
        case "putVar": putVar(s("k"), s("v")); return nil
        case "getVar": return getVar(s("k"))
        case "getString", "getStringList":
            guard let cur = stack.last else { return name == "getString" ? "" : [] }
            let an = a["content"] is String ? LegadoAnalyzer(s("content"), baseURL: cur.baseURL, ctx: self) : cur
            return name == "getString" ? try an.string(s("rule")) : try an.strings(s("rule"))
        case "setContent":
            if let cur = stack.last { cur.setContent(s("content"), base: a["base"] as? String) }
            return nil
        case "b64d":
            var t = s("s")
            t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            guard let d = Data(base64Encoded: t, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: LegadoHTTP.encoding(a["cs"] as? String) ?? .utf8) ?? String(decoding: d, as: UTF8.self)
        case "b64e": return Data(s("s").utf8).base64EncodedString()
        case "md5": return LegadoJS.md5(s("s"))
        case "encodeURI": return LegadoHTTP.percentEncode(s("s"), charset: a["cs"] as? String)
        case "htmlFormat": return LegadoContent.text(fromHTML: s("s"))
        case "log": log.append(s("s")); return nil
            // Byte arrays travel as JSON number arrays (signed, like Java byte[]).
        case "bytes.enc": return LegadoBytes.json(s("s").data(using: LegadoHTTP.encoding(a["cs"] as? String) ?? .utf8) ?? Data())
        case "bytes.dec":
            let d = LegadoBytes.data(a["b"])
            return String(data: d, encoding: LegadoHTTP.encoding(a["cs"] as? String) ?? .utf8) ?? String(decoding: d, as: UTF8.self)
        case "b64.dec":
            var t = s("s").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            t = t.filter { !$0.isWhitespace }
            while t.count % 4 != 0 { t += "=" }
            return LegadoBytes.json(Data(base64Encoded: t) ?? Data())
        case "b64.enc": return LegadoBytes.data(a["b"]).base64EncodedString()
        case "hex.dec":
            let h = Array(s("s").utf8)
            var d = Data()
            var i = 0
            while i + 1 < h.count { if let v = UInt8(String(decoding: h[i...i + 1], as: UTF8.self), radix: 16) { d.append(v) }; i += 2 }
            return LegadoBytes.json(d)
        case "hex.enc": return LegadoBytes.data(a["b"]).map { String(format: "%02x", $0) }.joined()
        case "digest":
            let d = LegadoBytes.data(a["b"])
            switch s("alg").uppercased().replacingOccurrences(of: "-", with: "") {
            case "SHA1": return LegadoBytes.json(Data(Insecure.SHA1.hash(data: d)))
            case "SHA256": return LegadoBytes.json(Data(SHA256.hash(data: d)))
            case "SHA512": return LegadoBytes.json(Data(SHA512.hash(data: d)))
            default: return LegadoBytes.json(Data(Insecure.MD5.hash(data: d)))
            }
        case "cipher":
            return LegadoBytes.json(try LegadoBytes.cipher(s("t"), encrypt: (a["mode"] as? Int) == 1, key: LegadoBytes.data(a["key"]),
                    iv: a["iv"].map(LegadoBytes.data), data: LegadoBytes.data(a["b"])))
        case "rsa.dec":
            if a["priv"] is [Any], let k = a["priv"], !LegadoBytes.data(k).isEmpty {
                return LegadoBytes.json(try LegadoBytes.rsaPrivateDecrypt(key: LegadoBytes.data(k), data: LegadoBytes.data(a["b"])))
            }
            return LegadoBytes.json(try LegadoBytes.rsaPublicDecrypt(key: LegadoBytes.data(a["key"]), data: LegadoBytes.data(a["b"])))
        case "rsa.enc": return LegadoBytes.json(try LegadoBytes.rsaPublicEncrypt(key: LegadoBytes.data(a["key"]), data: LegadoBytes.data(a["b"])))
        case "inflate": return LegadoBytes.json(try LegadoBytes.inflate(LegadoBytes.data(a["b"]), raw: a["nowrap"] as? Bool ?? false))
        case "jsoup.parse": return handle(LegadoDoc(s("html")).node)
        case "jsoup.select":
            let hits = nodes(a["h"]).flatMap { $0.css(s("q")) }
            return (a["first"] as? Bool == true ? Array(hits.prefix(1)) : hits).map(handle)
        case "jsoup.children": return nodes(a["h"]).flatMap(\.children).map(handle)
        case "jsoup.rule":
            guard let cur = stack.last else { return [] }
            return try cur.elements(s("rule")).compactMap { $0 as? LegadoNode }.map(handle)
        case "jsoup.text": return nodes(a["h"]).map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        case "jsoup.ownText": return nodes(a["h"]).map(\.ownText).joined(separator: " ")
        case "jsoup.textNodes": return nodes(a["h"]).flatMap(\.textNodes)
        case "jsoup.attr":
            var k = s("k"); let abs = k.hasPrefix("abs:"); if abs { k.removeFirst(4) }
            let v = nodes(a["h"]).map { $0.attr(k) }.first { !$0.isEmpty } ?? ""
            return abs ? LegadoURL.absolute(v, base: stack.last?.baseURL ?? source.bookSourceUrl) : v
        case "jsoup.html": return nodes(a["h"]).map { $0.html(outer: false) }.joined(separator: "\n")
        case "jsoup.outer": return nodes(a["h"]).map { $0.html(outer: true) }.joined(separator: "\n")
        case "ua": return LegadoHTTP.userAgent
        case "convert": return s("s").applyingTransform(StringTransform(rawValue: s("to")), reverse: false) ?? s("s")
        case "uuid": return UUID().uuidString.lowercased()
        case "cookieRemove":
            if let u = URL(string: LegadoURL.absolute(s("url"), base: source.bookSourceUrl)) {
                (HTTPCookieStorage.shared.cookies(for: u) ?? []).forEach(HTTPCookieStorage.shared.deleteCookie)
            }
            return nil
        case "cookieSet":
            if let u = URL(string: LegadoURL.absolute(s("url"), base: source.bookSourceUrl)) {
                let cookies = s("c").split(separator: ";").compactMap { part -> HTTPCookie? in
                    let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2, let host = u.host else { return nil }
                    return HTTPCookie(properties: [.name: kv[0], .value: kv[1], .domain: host, .path: "/"])
                }
                HTTPCookieStorage.shared.setCookies(cookies, for: u, mainDocumentURL: nil)
            }
            return nil
        case "loginInfo":
            let m = LegadoSourceState.loginInfo(source.bookSourceUrl)
            return m.isEmpty ? "" : String(decoding: (try? JSONSerialization.data(withJSONObject: m)) ?? Data(), as: UTF8.self)
        case "putLoginInfo":
            let t = s("v")
            if let d = t.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                LegadoSourceState.setLoginInfo(source.bookSourceUrl, m.mapValues { "\($0)" })
            } else { LegadoSourceState.set(source.bookSourceUrl, "loginInfo", t.isEmpty ? nil : t) }
            return nil
        case "loginHeader": return LegadoSourceState.get(source.bookSourceUrl, "loginHeader") ?? ""
        case "putLoginHeader": LegadoSourceState.set(source.bookSourceUrl, "loginHeader", s("v").isEmpty ? nil : s("v")); return nil
        case "cacheGet": return LegadoSourceState.cacheGet(source.bookSourceUrl, s("k"))
        case "cachePut": LegadoSourceState.cachePut(source.bookSourceUrl, s("k"), a["v"] as? String, seconds: (a["sec"] as? Double) ?? 0); return nil
        case "webView":
            return try LegadoWebView.run(html: a["html"] as? String, url: (a["url"] as? String).map { LegadoURL.absolute($0, base: source.bookSourceUrl) }, js: a["js"] as? String)
        case "browser":
            // Only from the login page: during 搜书 / 阅读 several sources run at once and a browser would block them.
            guard interactive else { throw LegadoError.rule("这个操作需要在书源的「登录」页里进行") }
            let u = URL(string: LegadoURL.absolute(s("url"), base: source.bookSourceUrl))
            let title = s("title").isEmpty ? source.bookSourceName : s("title")
            if a["wait"] as? Bool == true {
                LegadoBrowser.openBlocking(url: u, html: nil, title: title, sourceURL: source.bookSourceUrl)
                return (try? u.map { try LegadoHTTP.fetch(URLRequest(url: $0)).text }) ?? ""
            }
            Task { @MainActor in await LegadoBrowser.open(url: u, html: nil, title: title, sourceURL: self.source.bookSourceUrl) }
            return nil
        case "headers":
            // Guard against a header script that itself calls getHeaderMap().
            if inHeaders { return [:] }
            inHeaders = true; defer { inHeaders = false }
            return (try? LegadoURL.headers(ctx: self)) ?? [:]
        case "androidId": return String(LegadoJS.md5(source.bookSourceUrl).prefix(16))
        case "cookie":
            guard let u = URL(string: s("url")) else { return "" }
            let cs = HTTPCookieStorage.shared.cookies(for: u) ?? []
            if let k = a["k"] as? String { return cs.first { $0.name == k }?.value ?? "" }
            return cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        default: return nil
        }
    }

    /// JS with Legado's globals.
    func evalJS(_ code: String, result: Any?, baseURL: String, extra: [String: Any] = [:]) throws -> Any? {
        var b: [String: Any] = ["baseUrl": baseURL, "source": sourceJSON, "book": book]
        b["result"] = LegadoAnalyzer.jsonable(result)
        if let key { b["key"] = key }
        if let page { b["page"] = page }
        if let chapter { b["chapter"] = chapter; b["title"] = chapter["title"] ?? "" }
        for (k, v) in extra { b[k] = v }
        return try js.eval(code, b)
    }
}

/// Legado's AnalyzeRule: evaluates list / string rules on HTML, JSON, regex groups or plain text.
final class LegadoAnalyzer {
    let ctx: LegadoContext
    private(set) var content: Any
    private(set) var baseURL: String
    private var parsedDoc: LegadoNode?
    private var parsedJSON: Any??

    init(_ content: Any, baseURL: String, ctx: LegadoContext) {
        self.content = content
        self.baseURL = baseURL
        self.ctx = ctx
    }

    func setContent(_ c: Any, base: String? = nil) {
        content = c
        parsedDoc = nil
        parsedJSON = nil
        if let base { baseURL = base }
    }

    // MARK: Public API

    func elements(_ rule0: String) throws -> [Any] {
        var rule = rule0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return [] }
        var reverse = false
        if rule.hasPrefix("-") { reverse = true; rule.removeFirst() } else if rule.hasPrefix("+") { rule.removeFirst() }
        ctx.stack.append(self); defer { ctx.stack.removeLast() }
        rule = try applyPutGet(rule)
        var cur: Any = content
        for seg in Self.jsSegments(rule) {
            switch seg {
            case .js(let code): cur = try ctx.evalJS(try fillJS(code), result: cur, baseURL: baseURL) ?? NSNull()
            case .rule(let r):
                let target = LegadoAnalyzer(cur, baseURL: baseURL, ctx: ctx)
                cur = try target.listCombined(r)
            }
        }
        var list = Self.asList(cur, parseJSON: true)
        if reverse { list.reverse() }
        return list
    }

    func string(_ rule0: String) throws -> String {
        try strings(rule0).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func strings(_ rule0: String) throws -> [String] {
        var rule = rule0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return [] }
        // A rule that is only `@get:{k}` is the stored value itself.
        if let m = rule.range(of: #"^@get:\{([^}]+)\}$"#, options: .regularExpression) {
            return [ctx.getVar(String(rule[m].dropFirst(6).dropLast()))]
        }
        ctx.stack.append(self); defer { ctx.stack.removeLast() }
        rule = try applyPutGet(rule)
        var cur: Any = content
        var touched = false
        for seg in Self.jsSegments(rule) {
            switch seg {
            case .js(let code): cur = try ctx.evalJS(try fillJS(code), result: touched ? cur : Self.textOf(cur), baseURL: baseURL) ?? ""
            case .rule(let r):
                let target = LegadoAnalyzer(cur, baseURL: baseURL, ctx: ctx)
                cur = try target.stringsCombined(r)
            }
            touched = true
        }
        if let a = cur as? [String] { return a }
        if let a = cur as? [Any] { return a.map(Self.textOf) }
        return [Self.textOf(cur)]
    }

    // MARK: Combinators (&& || %%) and replacement (##)

    private func listCombined(_ rule: String) throws -> [Any] {
        let (parts, op) = Self.splitTop(rule)
        if parts.count == 1 { return try listSingle(parts[0]) }
        var results: [[Any]] = []
        for p in parts {
            let r = try listSingle(p)
            if op == "||" && !r.isEmpty { return r }
            results.append(r)
        }
        if op == "%%" {
            var out: [Any] = []
            for i in 0..<(results.map(\.count).max() ?? 0) { for r in results where i < r.count { out.append(r[i]) } }
            return out
        }
        return results.flatMap { $0 }
    }

    private func stringsCombined(_ rule: String) throws -> [String] {
        if Self.isTemplate(rule) {
            let (main, regex, repl, firstOnly) = Self.splitReplace(rule)
            let t = try template(main)
            return [regex.map { Self.replace(t, $0, repl, firstOnly: firstOnly) } ?? t]
        }
        let (parts, op) = Self.splitTop(rule)
        var results: [[String]] = []
        for p in parts {
            let r = try stringsSingle(p).filter { !$0.isEmpty }
            if op == "||" && !r.isEmpty { return r }
            results.append(r)
        }
        if op == "%%" {
            var out: [String] = []
            for i in 0..<(results.map(\.count).max() ?? 0) { for r in results where i < r.count { out.append(r[i]) } }
            return out
        }
        return results.flatMap { $0 }
    }

    /// `rule##regex##replacement`; with a trailing `###` only the first match is kept, replaced (Legado replaceFirst).
    private static func splitReplace(_ rule: String) -> (String, String?, String, Bool) {
        let parts = rule.components(separatedBy: "##")
        guard parts.count > 1 else { return (rule, nil, "", false) }
        return (parts[0], parts[1], parts.count > 2 ? parts[2] : "", rule.hasSuffix("###"))
    }

    static func replace(_ s: String, _ regex: String, _ repl: String, firstOnly: Bool) -> String {
        guard let re = try? NSRegularExpression(pattern: regex) else { return s.replacingOccurrences(of: regex, with: repl) }
        let r = NSRange(s.startIndex..., in: s)
        if firstOnly {
            guard let m = re.firstMatch(in: s, range: r) else { return "" }
            return re.replacementString(for: m, in: s, offset: 0, template: repl)
        }
        return re.stringByReplacingMatches(in: s, range: r, withTemplate: repl)
    }

    // MARK: Single rules

    private enum Mode { case json, xpath, css, regexAll, jsoup }

    private func mode(_ r: String) -> (Mode, String) {
        if r.hasPrefix("@@") { return (.jsoup, String(r.dropFirst(2))) }
        if r.lowercased().hasPrefix("@xpath:") { return (.xpath, String(r.dropFirst(7))) }
        if r.lowercased().hasPrefix("@json:") { return (.json, String(r.dropFirst(6))) }
        if r.lowercased().hasPrefix("@css:") { return (.css, String(r.dropFirst(5))) }
        if r.hasPrefix(":") { return (.regexAll, String(r.dropFirst())) }
        if r.hasPrefix("$.") || r.hasPrefix("$[") || (json != nil && !(content is LegadoNode)) { return (.json, r) }
        if r.hasPrefix("/") { return (.xpath, r) }
        return (.jsoup, r)
    }

    private func listSingle(_ r0: String) throws -> [Any] {
        let (r, regex, repl, first) = Self.splitReplace(r0)
        let (m, rule) = mode(r)
        _ = (regex, repl, first)
        switch m {
        case .regexAll:
            guard let re = try? NSRegularExpression(pattern: rule) else { throw LegadoError.rule("正则 \(rule)") }
            let s = Self.textOf(content)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { mt in
                LegadoGroups(groups: (0..<mt.numberOfRanges).map { Range(mt.range(at: $0), in: s).map { String(s[$0]) } ?? "" })
            }
        case .json:
            guard let j = json else { return [] }
            let r = LegadoJSONPath.read(j, rule)
            if r.count == 1, let a = r[0] as? [Any] { return a }
            return r
        case .xpath:
            return doc.xpathRaw(rule).nodes.filter(\.isElement)
        case .css:
            let (sel, _) = Self.splitCSSAttr(rule, forList: true)
            return doc.css(sel)
        case .jsoup:
            var nodes = [doc]
            for seg in Self.splitAt(rule) { nodes = Self.select(seg, nodes) }
            return nodes
        }
    }

    private func stringsSingle(_ r0: String) throws -> [String] {
        let (r1, regex, repl, firstOnly) = Self.splitReplace(r0)
        let r = r1.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String]
        if let g = content as? LegadoGroups {
            out = [Self.groupRef(r, g)]
        } else if r.isEmpty {
            out = [Self.textOf(content)]
        } else {
            let (m, rule) = mode(r)
            switch m {
            case .regexAll:
                out = try listSingle(r).compactMap { ($0 as? LegadoGroups)?.groups.first }
            case .json:
                if rule.contains("{$.") { out = [jsonTemplate(rule)] }
                else if let j = json { out = LegadoJSONPath.read(j, rule).flatMap { ($0 as? [Any]) ?? [$0] }.map(LegadoJSONPath.text) }
                else { out = [] }
            case .xpath:
                let (nodes, scalar) = doc.xpathRaw(rule)
                out = scalar.map { [$0] } ?? nodes.map(\.stringValue)
            case .css:
                let (sel, attr) = Self.splitCSSAttr(rule, forList: false)
                out = Self.values(doc.css(sel), attr ?? "text")
            case .jsoup:
                var segs = Self.splitAt(rule)
                guard !segs.isEmpty else { out = [Self.textOf(content)]; break }
                let attr = segs.count > 1 || Self.attributeNames.contains(segs[0]) ? segs.removeLast() : "text"
                var nodes = [doc]
                for seg in segs { nodes = Self.select(seg, nodes) }
                out = Self.values(nodes, attr)
            }
        }
        if let regex { out = out.map { Self.replace($0, regex, repl, firstOnly: firstOnly) } }
        return out
    }

    // MARK: Templates and variables

    private static func isTemplate(_ r: String) -> Bool { r.contains("{{") && r.contains("}}") }

    /// `text {{rule or js}} text`.
    private func template(_ r: String) throws -> String {
        var out = "", rest = Substring(r)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            out += rest[..<open.lowerBound]
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let ruleLike = inner.hasPrefix("@@") || inner.hasPrefix("@css:") || inner.lowercased().hasPrefix("@xpath:") || inner.hasPrefix("@json:")
            || inner.hasPrefix("$.") || inner.hasPrefix("//")
            if ruleLike { out += try string(inner) }
            else { out += Self.textOf(try ctx.evalJS(inner, result: Self.textOf(content), baseURL: baseURL) ?? "") }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// `{{rule}}` inside `<js>` / `@js:` code is replaced with the value from the current item before running.
    private func fillJS(_ code: String) throws -> String {
        guard code.contains("{{") else { return code }
        var out = "", rest = Substring(code)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            out += rest[..<open.lowerBound]
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let ruleLike = inner.hasPrefix("@@") || inner.hasPrefix("@css:") || inner.lowercased().hasPrefix("@xpath:") || inner.hasPrefix("@json:")
            || inner.hasPrefix("$.") || inner.hasPrefix("//")
            out += ruleLike ? try string(inner) : "{{" + inner + "}}"
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private func jsonTemplate(_ r: String) -> String {
        guard let j = json, let re = try? NSRegularExpression(pattern: #"\{(\$\.[^{}]+)\}"#) else { return r }
        var out = r
        for m in re.matches(in: r, range: NSRange(r.startIndex..., in: r)).reversed() {
            guard let whole = Range(m.range, in: out), let p = Range(m.range(at: 1), in: r) else { continue }
            out.replaceSubrange(whole, with: LegadoJSONPath.read(j, String(r[p])).map(LegadoJSONPath.text).joined(separator: ","))
        }
        return out
    }

    /// `@put:{k:rule}` stores values; `@get:{k}` substitutes them.
    private func applyPutGet(_ r0: String) throws -> String {
        var r = r0
        while let p = r.range(of: "@put:{"), let end = r.range(of: "}", range: p.upperBound..<r.endIndex) {
            let body = "{" + r[p.upperBound..<end.lowerBound] + "}"
            r.removeSubrange(p.lowerBound..<end.upperBound)
            if let d = body.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                for (k, v) in m { ctx.putVar(k, try string("\(v)")) }
            }
        }
        while let g = r.range(of: "@get:{"), let end = r.range(of: "}", range: g.upperBound..<r.endIndex) {
            let k = String(r[g.upperBound..<end.lowerBound])
            r.replaceSubrange(g.lowerBound..<end.upperBound, with: ctx.getVar(k))
        }
        return r
    }

    private static func groupRef(_ r: String, _ g: LegadoGroups) -> String {
        guard r.contains("$") else { return r }
        var out = r
        for i in stride(from: g.groups.count - 1, through: 0, by: -1) { out = out.replacingOccurrences(of: "$\(i)", with: g.groups[i]) }
        return out
    }

    // MARK: Content forms

    private var doc: LegadoNode {
        if let n = content as? LegadoNode { return n }
        if let d = parsedDoc { return d }
        let d = LegadoDoc(Self.textOf(content)).node
        parsedDoc = d
        return d
    }

    private var json: Any? {
        if let p = parsedJSON { return p }
        var v: Any?
        switch content {
        case let d as [String: Any]: v = d
        case let a as [Any]: v = a
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("[") { v = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]) }
        default: v = nil
        }
        parsedJSON = .some(v)
        return v
    }

    // MARK: Jsoup-style default rules

    static let attributeNames: Set<String> = ["text", "textNodes", "ownText", "html", "all", "href", "src", "content", "value", "title", "alt"]

    /// Splits on `@` outside brackets / parens / quotes.
    static func splitAt(_ r: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        var quote: Character?
        for c in r {
            if let q = quote { cur.append(c); if c == q { quote = nil }; continue }
            if c == "'" || c == "\"" { quote = c; cur.append(c); continue }
            if c == "[" || c == "(" { depth += 1 } else if c == "]" || c == ")" { depth -= 1 }
            if c == "@" && depth == 0 { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `sel@attr` for @css: (the last part is an attribute when it is a bare word).
    static func splitCSSAttr(_ r: String, forList: Bool) -> (String, String?) {
        let parts = splitAt(r)
        guard parts.count > 1, let last = parts.last, last.range(of: #"^[A-Za-z][\w\-:]*$"#, options: .regularExpression) != nil else { return (r, nil) }
        return (parts.dropLast().joined(separator: "@"), last)
    }

    static func values(_ nodes: [LegadoNode], _ attr0: String) -> [String] {
        let attr = attr0.hasPrefix("abs:") ? String(attr0.dropFirst(4)) : attr0
        switch attr {
        case "text": return nodes.map(\.text).filter { !$0.isEmpty }
        case "textNodes": return nodes.map { $0.textNodes.joined(separator: "\n") }.filter { !$0.isEmpty }
        case "ownText": return nodes.map(\.ownText).filter { !$0.isEmpty }
        case "html": return nodes.map { stripScripts($0.html(outer: true)) }
        case "all": return nodes.map { $0.html(outer: true) }
        default: return nodes.map { $0.attr(attr) }.filter { !$0.isEmpty }
        }
    }

    private static func stripScripts(_ h: String) -> String {
        h.replacingOccurrences(of: "<(script|style)[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// One `@` segment: class.x / id.x / tag.x / text.x / children (+ index) or a CSS selector (+ [index]).
    static func select(_ seg: String, _ parents: [LegadoNode]) -> [LegadoNode] {
        var body = seg, index: String?
        // trailing [..] index (digits, ranges, commas, !)
        if body.hasSuffix("]"), let open = body.lastIndex(of: "["),
        body[body.index(after: open)..<body.index(before: body.endIndex)].allSatisfy({ "0123456789-:,! ".contains($0) }) {
            index = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
            body = String(body[..<open])
        }
        let typed = ["class.", "id.", "tag.", "text."].first { body.hasPrefix($0) }
        var name = body
        if let t = typed {
            name = String(body.dropFirst(t.count))
            if index == nil {
                if let bang = name.lastIndex(of: "!") { index = "!" + name[name.index(after: bang)...]; name = String(name[..<bang]) }
                else if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].allSatisfy({ "0123456789-:".contains($0) }), !name[name.index(after: dot)...].isEmpty {
                    index = String(name[name.index(after: dot)...]); name = String(name[..<dot])
                }
            }
        } else if body == "children" || body.hasPrefix("children.") {
            if body.hasPrefix("children."), index == nil { index = String(body.dropFirst(9)) }
            return parents.flatMap { pick($0.children, index) }
        }
        return parents.flatMap { p -> [LegadoNode] in
            let found: [LegadoNode]
            switch typed {
            case "class.":
                let want = name.split(separator: " ").map(String.init)
                found = p.descendants.filter { n in let c = Set(n.attr("class").split(separator: " ").map(String.init)); return want.allSatisfy(c.contains) }
            case "id.": found = p.descendants.filter { $0.attr("id") == name }
            case "tag.": found = p.descendants.filter { $0.name == name.lowercased() }
            case "text.": found = p.descendants.filter { $0.ownText.contains(name) }
            default: found = p.css(name)
            }
            return pick(found, index)
        }
    }

    /// Legado indexes: `0`, `-1`, `1,3`, `1:3` (inclusive), `!0` (exclude).
    static func pick(_ items: [LegadoNode], _ spec: String?) -> [LegadoNode] {
        guard var s = spec?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return items }
        let exclude = s.hasPrefix("!")
        if exclude { s.removeFirst() }
        let n = items.count
        var idx: [Int] = []
        for part in s.split(separator: ",") {
            let p = part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if p.count >= 2 {
                var a = p[0] ?? 0, b = p[1] ?? (n - 1)
                if a < 0 { a += n }; if b < 0 { b += n }
                // Clamp first: on a page with fewer items than the rule expects the range must not be built backwards.
                let lo = max(0, min(a, b)), hi = min(n - 1, max(a, b))
                if lo <= hi { idx += a <= b ? Array(lo...hi) : Array((lo...hi).reversed()) }
            } else if let i = p[0] {
                idx.append(i < 0 ? n + i : i)
            }
        }
        idx = idx.filter { $0 >= 0 && $0 < n }
        if exclude { let ex = Set(idx); return items.indices.filter { !ex.contains($0) }.map { items[$0] } }
        return idx.map { items[$0] }
    }

    // MARK: JS segments

    enum Segment { case rule(String), js(String) }

    /// `rule<js>code</js>rule@js:code` → ordered segments.
    static func jsSegments(_ r: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(r)
        while !rest.isEmpty {
            let tag = rest.range(of: "<js>", options: .caseInsensitive)
            let at = rest.range(of: "@js:", options: .caseInsensitive)
            if let t = tag, at == nil || t.lowerBound < at!.lowerBound {
                let before = rest[..<t.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { out.append(.rule(before)) }
                let close = rest.range(of: "</js>", options: .caseInsensitive, range: t.upperBound..<rest.endIndex)
                out.append(.js(String(rest[t.upperBound..<(close?.lowerBound ?? rest.endIndex)])))
                rest = close.map { rest[$0.upperBound...] } ?? ""
            } else if let a = at {
                let before = rest[..<a.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { out.append(.rule(before)) }
                out.append(.js(String(rest[a.upperBound...])))
                rest = ""
            } else {
                let r = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { out.append(.rule(r)) }
                rest = ""
            }
        }
        return out
    }

    /// Top-level `&&`, `||` or `%%` (first one found decides; brackets and quotes respected).
    static func splitTop(_ r: String) -> ([String], String) {
        for op in ["&&", "||", "%%"] {
            var parts: [String] = [], cur = "", depth = 0
            var quote: Character?
            var i = r.startIndex
            while i < r.endIndex {
                let c = r[i]
                if let q = quote { cur.append(c); if c == q { quote = nil }; i = r.index(after: i); continue }
                if c == "'" || c == "\"" { quote = c }
                if "[({".contains(c) { depth += 1 } else if "])}".contains(c) { depth -= 1 }
                if depth == 0, r[i...].hasPrefix(op) { parts.append(cur); cur = ""; i = r.index(i, offsetBy: 2); continue }
                cur.append(c)
                i = r.index(after: i)
            }
            parts.append(cur)
            if parts.count > 1 { return (parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, op) }
        }
        return ([r], "")
    }

    // MARK: Value helpers

    static func textOf(_ v: Any?) -> String {
        switch v {
        case nil: return ""
        case let s as String: return s
        case let n as LegadoNode: return n.html(outer: true)
        case let g as LegadoGroups: return g.groups.first ?? ""
        case let a as [Any]: return a.map { textOf($0) }.joined(separator: "\n")
        default: return LegadoJSONPath.text(v!)
        }
    }

    static func asList(_ v: Any, parseJSON: Bool) -> [Any] {
        switch v {
        case let a as [Any]: return a
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if parseJSON, t.hasPrefix("["), let a = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [Any] { return a }
            return t.isEmpty ? [] : [s]
        case is NSNull: return []
        default: return [v]
        }
    }

    /// Value for JS `result` (nodes become their HTML).
    static func jsonable(_ v: Any?) -> Any {
        switch v {
        case nil: return NSNull()
        case let n as LegadoNode: return n.html(outer: true)
        case let g as LegadoGroups: return g.groups
        case let a as [Any]: return a.map { jsonable($0) }
        case let d as [String: Any]: return d
        case let s as String: return s
        case let n as NSNumber: return n
        default: return "\(v!)"
        }
    }
}

// MARK: - URL rules (AnalyzeUrl)

struct LegadoRequest {
    var request: URLRequest
    var charset: String?
    /// Legado `type` option: the rule gets the raw body as hex instead of text.
    var type: String?

    func fetch() throws -> LegadoResponse {
        var r = try LegadoHTTP.fetch(request, charset: charset)
        if let type, !type.isEmpty { r.text = r.body.map { String(format: "%02x", $0) }.joined() }
        return r
    }
}

enum LegadoURL {
    /// `searchUrl` / `tocUrl` / … → request. Handles `{{key}}`, `{{page}}`, `{{js}}`, `<a,b,c>` page lists,
    /// `@js:` URLs and the `,{"method":…,"body":…,"charset":…,"headers":…}` option suffix.
    static func request(_ rule0: String, ctx: LegadoContext, base: String, analyzer: LegadoAnalyzer? = nil) throws -> LegadoRequest {
        var rule = rule0.trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = LegadoAnalyzer.jsSegments(rule)
        if segs.contains(where: { if case .js = $0 { true } else { false } }) {
            var cur: Any = ""
            for s in segs {
                switch s {
                case .rule(let r): cur = r
                case .js(let code): cur = try ctx.evalJS(code, result: LegadoAnalyzer.textOf(cur), baseURL: base) ?? ""
                }
            }
            rule = LegadoAnalyzer.textOf(cur)
        }
        // <1,2,3> page lists
        if let page = ctx.page, let re = try? NSRegularExpression(pattern: "<([^<>]+,[^<>]+)>") {
            for m in re.matches(in: rule, range: NSRange(rule.startIndex..., in: rule)).reversed() {
                guard let whole = Range(m.range, in: rule), let inner = Range(m.range(at: 1), in: rule) else { continue }
                let items = rule[inner].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                rule.replaceSubrange(whole, with: items[min(max(0, page - 1), items.count - 1)])
            }
        }
        // options suffix
        var options: [String: Any] = [:]
        if let r = Self.optionsStart(rule) {
            let tail = String(rule[rule.index(after: r.lowerBound)...])
            if let o = lenientObject(tail, ctx: ctx) {
                options = o
                rule = String(rule[..<r.lowerBound])
            }
        }
        let charset = options["charset"] as? String
        // {{ }} templates
        rule = try substitute(rule, ctx: ctx, base: base, charset: charset, encodeKey: true)
        guard let url = resolve(rule, base: base) else { throw LegadoError.rule("网址无效：\(rule)") }
        var req = URLRequest(url: url)
        req.setValue(LegadoHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in try headers(ctx: ctx) { req.setValue(v, forHTTPHeaderField: k) }
        if let h = options["headers"] as? [String: Any] { for (k, v) in h { req.setValue("\(v)", forHTTPHeaderField: k) } }
        else if let hs = options["headers"] as? String, let d = hs.data(using: .utf8), let h = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for (k, v) in h { req.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if (options["method"] as? String)?.uppercased() == "POST" {
            req.httpMethod = "POST"
            var body: String
            if let b = options["body"] as? String { body = b }
            else if let b = options["body"], JSONSerialization.isValidJSONObject(b), let d = try? JSONSerialization.data(withJSONObject: b) { body = String(decoding: d, as: UTF8.self) }
            else { body = "" }
            body = try substitute(body, ctx: ctx, base: base, charset: charset, encodeKey: !body.hasPrefix("{"))
            let isJSON = body.trimmingCharacters(in: .whitespaces).hasPrefix("{")
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue(isJSON ? "application/json; charset=UTF-8" : "application/x-www-form-urlencoded; charset=\(charset ?? "UTF-8")", forHTTPHeaderField: "Content-Type")
            }
            req.httpBody = isJSON ? Data(body.utf8) : (body.data(using: LegadoHTTP.encoding(charset) ?? .utf8) ?? Data(body.utf8))
        }
        return LegadoRequest(request: req, charset: charset, type: options["type"] as? String)
    }

    /// Options objects are often not strict JSON (single quotes, unquoted keys, line breaks): Legado reads them
    /// leniently, so fall back to evaluating them as a JS object literal.
    static func lenientObject(_ text: String, ctx: LegadoContext) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return nil }
        return (try? ctx.js.eval("JSON.parse(JSON.stringify(" + text + "))", [:])) as? [String: Any]
    }

    /// The `}}` that closes a `{{` (JS inside may itself contain `}}`, e.g. `})()}}`): the first one that leaves the
    /// braces balanced.
    static func closing(_ s: Substring, after start: String.Index) -> Range<String.Index>? {
        var depth = 0
        var i = start
        var quote: Character?
        while i < s.endIndex {
            let c = s[i]
            if let q = quote { if c == "\\" { i = s.index(after: i) } else if c == q { quote = nil } }
            else if c == "'" || c == "\"" || c == "`" { quote = c }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                if depth == 0, s[i...].hasPrefix("}}") { return i..<s.index(i, offsetBy: 2) }
                depth -= 1
            }
            if i < s.endIndex { i = s.index(after: i) }
        }
        return nil
    }

    /// The `,{` that starts the options object: the last one outside `{{ … }}` (JS inside may contain `,{`).
    static func optionsStart(_ rule: String) -> Range<String.Index>? {
        var outside: [Range<String.Index>] = []
        var i = rule.startIndex, depth = 0
        while i < rule.endIndex {
            if rule[i...].hasPrefix("{{") { depth += 1; i = rule.index(i, offsetBy: 2); continue }
            if depth > 0, rule[i...].hasPrefix("}}") { depth -= 1; i = rule.index(i, offsetBy: 2); continue }
            if depth == 0, rule[i...].hasPrefix(",{") { outside.append(i..<rule.index(i, offsetBy: 2)) }
            i = rule.index(after: i)
        }
        return outside.last
    }

    /// Replaces `{{key}}`, `{{page}}` and `{{js expression}}`; the keyword is percent-encoded in `charset`.
    static func substitute(_ s: String, ctx: LegadoContext, base: String, charset: String?, encodeKey: Bool) throws -> String {
        var out = "", rest = Substring(s)
        while let open = rest.range(of: "{{"), let close = closing(rest, after: open.upperBound) {
            out += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if inner == "key" { out += encodeKey ? LegadoHTTP.percentEncode(ctx.key ?? "", charset: charset) : (ctx.key ?? "") }
            else if inner == "page" { out += String(ctx.page ?? 1) }
            else { out += LegadoAnalyzer.textOf(try ctx.evalJS(inner, result: nil, baseURL: base)) }
            rest = rest[close.upperBound...]
        }
        out += rest
        // Legacy `searchKey` / `searchPage` placeholders.
        return out.replacingOccurrences(of: "searchKey", with: LegadoHTTP.percentEncode(ctx.key ?? "", charset: charset))
            .replacingOccurrences(of: "searchPage", with: String(ctx.page ?? 1))
    }

    static func resolve(_ s: String, base: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), u.scheme != nil { return u }
        let b = URL(string: base) ?? URL(string: base.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        if let u = URL(string: t, relativeTo: b)?.absoluteURL { return u }
        return URL(string: t.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? t, relativeTo: b)?.absoluteURL
    }

    /// Absolute URL text for links found in pages (href / src values).
    static func absolute(_ s: String, base: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if t.contains(",{") { return t }   // keeps request options
        return resolve(t, base: base)?.absoluteString ?? t
    }

    static func headers(ctx: LegadoContext) throws -> [String: String] {
        guard var h = ctx.source.header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else {
            return LegadoSourceState.loginHeader(ctx.source.bookSourceUrl)
        }
        if h.hasPrefix("@js:") || h.hasPrefix("<js>") {
            let code = h.hasPrefix("@js:") ? String(h.dropFirst(4)) : h.replacingOccurrences(of: "<js>", with: "").replacingOccurrences(of: "</js>", with: "")
            h = LegadoAnalyzer.textOf(try ctx.evalJS(code, result: nil, baseURL: ctx.source.bookSourceUrl))
        }
        var out = (h.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]).mapValues { "\($0)" }
        // Login header (putLoginHeader) applies to every request of the source, like Legado.
        for (k, v) in LegadoSourceState.loginHeader(ctx.source.bookSourceUrl) { out[k] = v }
        return out
    }
}


/// Java byte[] ⇄ Data, and the crypto / zip primitives behind the Rhino compatibility layer.
enum LegadoBytes {
    static func json(_ d: Data) -> [Int] { d.map { Int(Int8(bitPattern: $0)) } }

    static func data(_ v: Any?) -> Data {
        guard let a = v as? [Any] else { return (v as? String).map { Data($0.utf8) } ?? Data() }
        return Data(a.map { v -> UInt8 in
                if let i = v as? Int { return UInt8(truncatingIfNeeded: i) }
                guard let d = v as? Double, d.isFinite, abs(d) < 1e15 else { return 0 }
                return UInt8(truncatingIfNeeded: Int(d))
        })
    }

    /// "AES/CBC/PKCS5Padding", "AES/ECB/NoPadding", "DES/…", "DESede/…".
    static func cipher(_ transformation: String, encrypt: Bool, key: Data, iv: Data?, data: Data) throws -> Data {
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        let alg = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"
        let (algorithm, block): (CCAlgorithm, Int) = alg.hasPrefix("DESEDE") || alg == "3DES" ? (CCAlgorithm(kCCAlgorithm3DES), kCCBlockSize3DES)
        : alg.hasPrefix("DES") ? (CCAlgorithm(kCCAlgorithmDES), kCCBlockSizeDES) : (CCAlgorithm(kCCAlgorithmAES), kCCBlockSizeAES128)
        var options = CCOptions(0)
        if padding != "NOPADDING" { options |= CCOptions(kCCOptionPKCS7Padding) }
        if mode == "ECB" { options |= CCOptions(kCCOptionECBMode) }
        var out = Data(count: data.count + block)
        var moved = 0
        let ivData = mode == "ECB" ? nil : iv
        let status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in key.withUnsafeBytes { k in (ivData ?? Data()).withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options, k.baseAddress, key.count,
                            ivData == nil ? nil : v.baseAddress, i.baseAddress, data.count, o.baseAddress, o.count, &moved)
                    } } } }
        guard status == kCCSuccess else { throw LegadoError.rule("解密失败（\(transformation)）") }
        return out.prefix(moved)
    }

    // MARK: RSA (hutool-style AsymmetricCrypto)

    /// X.509 SubjectPublicKeyInfo → PKCS#1 RSAPublicKey (what SecKeyCreateWithData wants).
    static func pkcs1(fromSPKI d: Data) -> Data {
        let b = [UInt8](d)
        // SPKI starts with SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { RSAPublicKey } }.
        guard b.count > 24, b[0] == 0x30 else { return d }
        func len(_ i: inout Int) -> Int {
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            var n = 0
            for _ in 0..<(first & 0x7f) { n = (n << 8) | Int(b[i]); i += 1 }
            return n
        }
        var i = 1
        _ = len(&i) // outer SEQUENCE
        guard i < b.count, b[i] == 0x30 else { return d }
        i += 1; let algLen = len(&i); i += algLen       // AlgorithmIdentifier
        guard i < b.count, b[i] == 0x03 else { return d }
        i += 1; _ = len(&i); i += 1       // BIT STRING (+ unused-bits byte)
        return i < b.count ? Data(b[i...]) : d
    }

    static func publicKey(_ der: Data) throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var err: Unmanaged<CFError>?
        if let k = SecKeyCreateWithData(pkcs1(fromSPKI: der) as CFData, attrs as CFDictionary, &err) { return k }
        throw LegadoError.rule("RSA 公钥无效")
    }

    /// Public-key "decryption" (data was produced with the private key): raw RSA per block, then strip
    /// PKCS#1 v1.5 type-1/2 padding. Blocks are the modulus size.
    static func rsaPublicDecrypt(key: Data, data: Data) throws -> Data {
        let k = try publicKey(key)
        let block = SecKeyGetBlockSize(k)
        guard block > 11 else { throw LegadoError.rule("RSA 公钥无效") }
        var out = Data()
        var off = 0
        while off < data.count {
            let chunk = data.subdata(in: off..<min(data.count, off + block))
            off += block
            var err: Unmanaged<CFError>?
            guard let raw = SecKeyCreateEncryptedData(k, .rsaEncryptionRaw, chunk as CFData, &err) as Data? else { throw LegadoError.rule("RSA 解密失败") }
            let r = [UInt8](raw)
            // PKCS#1 v1.5: 00 01 FF..FF 00 data (or 00 02 random 00 data). Otherwise NoPadding (Android's default for
            // Cipher "RSA", which Legado's createAsymmetricCrypto uses): the plaintext is left-padded with zeros.
            if r.count > 2, r[0] == 0, r[1] == 1 || r[1] == 2, let sep = r[2...].firstIndex(of: 0), sep >= 10 {
                out.append(contentsOf: r[(sep + 1)...])
            } else {
                out.append(contentsOf: r.drop { $0 == 0 })
            }
        }
        return out
    }

    static func rsaPublicEncrypt(key: Data, data: Data) throws -> Data {
        let k = try publicKey(key)
        let block = SecKeyGetBlockSize(k) - 11
        var out = Data()
        var off = 0
        while off < data.count {
            var err: Unmanaged<CFError>?
            let chunk = data.subdata(in: off..<min(data.count, off + block))
            off += block
            guard let e = SecKeyCreateEncryptedData(k, .rsaEncryptionPKCS1, chunk as CFData, &err) as Data? else { throw LegadoError.rule("RSA 加密失败") }
            out.append(e)
        }
        return out
    }

    static func rsaPrivateDecrypt(key: Data, data: Data) throws -> Data {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(key as CFData, attrs as CFDictionary, &err) else { throw LegadoError.rule("RSA 私钥无效（需要 PKCS#1 格式）") }
        let block = SecKeyGetBlockSize(k)
        var out = Data()
        var off = 0
        while off < data.count {
            let chunk = data.subdata(in: off..<min(data.count, off + block))
            off += block
            guard let d = SecKeyCreateDecryptedData(k, .rsaEncryptionPKCS1, chunk as CFData, &err) as Data? else { throw LegadoError.rule("RSA 解密失败") }
            out.append(d)
        }
        return out
    }

    /// Raw deflate (Inflater(true)) or zlib-wrapped (header + adler32 trailer).
    static func inflate(_ d: Data, raw: Bool) throws -> Data {
        guard !d.isEmpty else { return Data() }
        var src = d
        if !raw, src.count > 6 { src = src.subdata(in: 2..<(src.count - 4)) }
        guard !src.isEmpty else { return Data() }
        var out = Data()
        let capacity = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: capacity, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw LegadoError.rule("解压失败") }
        defer { compression_stream_destroy(&stream) }
        try src.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            guard let base = b.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = capacity
                let st = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: capacity - stream.dst_size)
                if st == COMPRESSION_STATUS_END { break }
                guard st == COMPRESSION_STATUS_OK else { throw LegadoError.rule("解压失败") }
            }
        }
        return out
    }
}
