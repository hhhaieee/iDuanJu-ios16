import Foundation
import CryptoKit
import libxml2
import CQuickJS

// MARK: - HTML nodes (libxml2)

/// One parsed HTML document; nodes keep it alive.
final class LegadoDoc: @unchecked Sendable {
    let doc: htmlDocPtr
    init(_ html: String) {
        let opts = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
        let src = html.isEmpty ? "<html></html>" : html
        doc = src.withCString { p in htmlReadMemory(p, Int32(strlen(p)), "about:blank", "UTF-8", opts) } ?? htmlNewDoc(nil, nil)
    }
    deinit { xmlFreeDoc(doc) }
    var node: LegadoNode { LegadoNode(owner: self, ptr: UnsafeMutableRawPointer(doc).assumingMemoryBound(to: xmlNode.self)) }
}

struct LegadoNode {
    let owner: LegadoDoc
    let ptr: xmlNodePtr

    var isElement: Bool { ptr.pointee.type == XML_ELEMENT_NODE }
    var name: String { ptr.pointee.name.map { String(cString: $0) }?.lowercased() ?? "" }

    var children: [LegadoNode] {
        var out: [LegadoNode] = []
        var c = ptr.pointee.children
        while let n = c { if n.pointee.type == XML_ELEMENT_NODE { out.append(LegadoNode(owner: owner, ptr: n)) }; c = n.pointee.next }
        return out
    }

    /// Any XPath result: elements, attributes and text nodes as nodes; scalars as strings.
    func xpathRaw(_ expr: String) -> (nodes: [LegadoNode], scalar: String?) {
        guard let ctx = xmlXPathNewContext(ptr.pointee.doc) else { return ([], nil) }
        defer { xmlXPathFreeContext(ctx) }
        ctx.pointee.node = ptr
        guard let obj = xmlXPathEvalExpression(expr, ctx) else { return ([], nil) }
        defer { xmlXPathFreeObject(obj) }
        switch obj.pointee.type {
        case XPATH_NODESET:
            guard let set = obj.pointee.nodesetval else { return ([], nil) }
            return ((0..<Int(set.pointee.nodeNr)).compactMap { set.pointee.nodeTab[$0].map { LegadoNode(owner: owner, ptr: $0) } }, nil)
        case XPATH_STRING: return ([], obj.pointee.stringval.map { String(cString: $0) })
        case XPATH_NUMBER: let v = obj.pointee.floatval; return ([], v == v.rounded() ? String(Int(v)) : String(v))
        case XPATH_BOOLEAN: return ([], obj.pointee.boolval != 0 ? "true" : "false")
        default: return ([], nil)
        }
    }

    func css(_ selector: String) -> [LegadoNode] {
        guard let x = try? CSSXPath.convert(selector) else { return [] }
        return xpathRaw(x).nodes.filter(\.isElement)
    }

    /// Jsoup `text()`: all descendant text, whitespace collapsed.
    var text: String {
        guard let c = xmlNodeGetContent(ptr) else { return "" }
        defer { xmlFree(c) }
        let s = String(cString: c)
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Text of direct text children, one per line (Jsoup `textNodes`).
    var textNodes: [String] {
        var out: [String] = []
        var c = ptr.pointee.children
        while let n = c {
            if n.pointee.type == XML_TEXT_NODE || n.pointee.type == XML_CDATA_SECTION_NODE, let v = xmlNodeGetContent(n) {
                let s = String(cString: v).trimmingCharacters(in: .whitespacesAndNewlines)
                xmlFree(v)
                if !s.isEmpty { out.append(s) }
            }
            c = n.pointee.next
        }
        return out
    }

    var ownText: String { textNodes.joined(separator: " ") }

    func attr(_ name: String) -> String {
        guard isElement, let v = xmlGetProp(ptr, name.lowercased()) else { return "" }
        defer { xmlFree(v) }
        return String(cString: v)
    }

    func html(outer: Bool) -> String {
        guard let buf = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buf) }
        if ptr.pointee.type == XML_HTML_DOCUMENT_NODE || ptr.pointee.type == XML_DOCUMENT_NODE {
            if let root = xmlDocGetRootElement(ptr.pointee.doc) { htmlNodeDump(buf, ptr.pointee.doc, root) }
        } else if outer {
            htmlNodeDump(buf, ptr.pointee.doc, ptr)
        } else {
            var c = ptr.pointee.children
            while let n = c { htmlNodeDump(buf, ptr.pointee.doc, n); c = n.pointee.next }
        }
        return xmlBufferContent(buf).map { String(cString: $0) } ?? ""
    }

    /// Value of a non-element XPath hit (attribute / text node).
    var stringValue: String {
        if isElement { return text }
        guard let c = xmlNodeGetContent(ptr) else { return "" }
        defer { xmlFree(c) }
        return String(cString: c)
    }

    /// Element and all element descendants (document order).
    var descendants: [LegadoNode] { children.flatMap { [$0] + $0.descendants } }
}

// MARK: - HTTP

struct LegadoResponse {
    var url: URL
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String
}

enum LegadoError: LocalizedError {
    case http(Int, String), network(String), rule(String), empty(String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let u): "HTTP \(c)：\(u)"
        case .network(let m): m
        case .rule(let m): "书源规则错误：\(m)"
        case .empty(let m): m
        }
    }
}

enum LegadoHTTP {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    /// Shared session; DEBUG `STV_NO_PROXY=1` bypasses the Mac's system proxy in the simulator (closer to a phone).
    static let session: URLSession = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_NO_PROXY"] == "1" {
            let c = URLSessionConfiguration.default
            c.connectionProxyDictionary = [:]
            return URLSession(configuration: c)
        }
        #endif
        return URLSession.shared
    }()

    /// Tests replace the network (URL → response).
    nonisolated(unsafe) static var transport: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    /// Synchronous request (book-source rules run on a worker thread).
    static func fetch(_ req0: URLRequest, charset: String? = nil) throws -> LegadoResponse {
        // `data:` URLs (API sources pack ids into them) answer locally, like Legado.
        if let u = req0.url, u.scheme == "data" {
            let raw = u.absoluteString.dropFirst(5)
            guard let comma = raw.firstIndex(of: ",") else { throw LegadoError.rule("data 网址无效") }
            let meta = raw[..<comma], payload = String(raw[raw.index(after: comma)...])
            let body = meta.hasSuffix(";base64") ? (Data(base64Encoded: payload.removingPercentEncoding ?? payload) ?? Data())
            : Data((payload.removingPercentEncoding ?? payload).utf8)
            return LegadoResponse(url: u, status: 200, headers: [:], body: body, text: decode(body, contentType: nil, charset: charset))
        }
        var req = req0
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if req.timeoutInterval > 20 || req.timeoutInterval <= 0 { req.timeoutInterval = 15 }
        let data: Data, resp: HTTPURLResponse
        if let t = transport {
            (data, resp) = try t(req)
        } else {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Data?, URLResponse?, Error?)
            session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.2 { throw LegadoError.network("网络错误：\(e.localizedDescription)") }
            guard let r = out.1 as? HTTPURLResponse else { throw LegadoError.network("没有响应") }
            (data, resp) = (out.0 ?? Data(), r)
        }
        let headers = Dictionary(resp.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        guard (200..<400).contains(resp.statusCode) else { throw LegadoError.http(resp.statusCode, req.url?.absoluteString ?? "") }
        let text = decode(data, contentType: headers["content-type"], charset: charset)
        return LegadoResponse(url: resp.url ?? req.url!, status: resp.statusCode, headers: headers, body: data, text: text)
    }

    static func encoding(_ name: String?) -> String.Encoding? {
        guard let n = name?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), !n.isEmpty else { return nil }
        if n.contains("utf-8") || n == "utf8" { return .utf8 }
        if n.contains("gb") { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) }
        if n.contains("big5") { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))) }
        let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
        return cf == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Charset: source option > Content-Type > <meta charset> > UTF-8 (GB18030 if UTF-8 fails).
    static func decode(_ d: Data, contentType: String?, charset: String?) -> String {
        if let e = encoding(charset), let s = String(data: d, encoding: e) { return s }
        if let ct = contentType, let r = ct.range(of: "charset=", options: .caseInsensitive),
        let e = encoding(String(ct[r.upperBound...]).components(separatedBy: ";")[0]), let s = String(data: d, encoding: e) { return s }
        let head = String(decoding: d.prefix(2048), as: UTF8.self)
        if let m = head.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let name = head[m].components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
            if let e = encoding(name), let s = String(data: d, encoding: e) { return s }
        }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let e = encoding("gbk"), let s = String(data: d, encoding: e) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    /// Percent-encodes `s` in `charset` (GBK sites expect GBK-encoded keywords).
    static func percentEncode(_ s: String, charset: String?) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        guard let e = encoding(charset), e != .utf8, let d = s.data(using: e) else {
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        return d.map { b in
            let c = Character(Unicode.Scalar(b))
            return b < 0x80 && allowed.contains(Unicode.Scalar(b)) ? String(c) : String(format: "%%%02X", b)
        }.joined()
    }
}

// MARK: - JavaScript (QuickJS sandbox)

/// Runs Legado `@js:` / `<js>` / `{{ }}` snippets. Each evaluation gets a fresh sandbox (top-level `let` in one
/// snippet must not clash with the next). `java.*` calls come back to the host through `handler`.
final class LegadoJS {
    /// Host handler: (function name, JSON args) → JSON result.
    var handler: (String, Any?) throws -> Any? = { _, _ in nil }
    var jsLib: String?

    static let prelude = #"""
    (function (h) {
            const call = (n, a) => { const r = h(n, JSON.stringify(a === undefined ? null : a)); return r === undefined ? undefined : JSON.parse(r); };
            const str = (v) => v == null ? '' : String(v);
            globalThis.java = {
                ajax: (u) => call('ajax', { url: str(Array.isArray(u) ? u[0] : u) }),
                connect: (u, h2) => { const r = call('connect', { url: str(u), headers: h2 || null }); return { body: () => r.body, code: () => r.status, url: () => r.url, header: (k) => (r.headers || {})[String(k).toLowerCase()], headers: () => r.headers, raw: r }; },
                get: (k, h2) => { if (h2 === undefined && !/^https?:/.test(str(k))) return call('getVar', { k: str(k) }); const r = call('connect', { url: str(k), headers: h2 || null }); return { body: () => r.body, code: () => r.status, url: () => r.url, header: (n) => (r.headers || {})[String(n).toLowerCase()] }; },
                post: (u, b, h2) => { const r = call('connect', { url: str(u), method: 'POST', body: str(b), headers: h2 || null }); return { body: () => r.body, code: () => r.status, url: () => r.url, header: (n) => (r.headers || {})[String(n).toLowerCase()] }; },
                put: (k, v) => { call('putVar', { k: str(k), v: str(v) }); return v; },
                getString: (rule, content) => call('getString', { rule: str(rule), content: content === undefined ? null : str(content) }),
                getStringList: (rule, content) => call('getStringList', { rule: str(rule), content: content === undefined ? null : str(content) }),
                setContent: (c, b) => call('setContent', { content: str(c), base: b === undefined ? null : str(b) }),
                base64Decode: (s, cs) => call('b64d', { s: str(s), cs: cs || null }),
                base64Encode: (s) => call('b64e', { s: str(s) }),
                md5Encode: (s) => call('md5', { s: str(s) }),
                md5Encode16: (s) => call('md5', { s: str(s) }).substring(8, 24),
                encodeURI: (s, cs) => call('encodeURI', { s: str(s), cs: cs || null }),
                timeFormat: (t) => { const d = new Date(Number(t)); const p = (n) => String(n).padStart(2, '0'); return d.getFullYear() + '/' + p(d.getMonth() + 1) + '/' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()); },
                htmlFormat: (s) => call('htmlFormat', { s: str(s) }),
                log: (s) => { call('log', { s: str(s) }); return s; },
                toast: () => {}, longToast: () => {},
                getCookie: (u, k) => call('cookie', { url: str(u), k: k == null ? null : str(k) }),
            };
            globalThis.cookie = { getCookie: (u) => java.getCookie(u), getKey: (u, k) => java.getCookie(u, k), removeCookie: () => {} };
            // ---- Rhino / Android compatibility (only what book sources actually use) ----
            const bytesOf = (v) => Array.isArray(v) ? v : call('bytes.enc', { s: str(v), cs: 'UTF-8' });
            function JString(a, b, c, d) {
                let s;
                if (a == null || typeof a !== 'object' || !Array.isArray(a)) s = str(a);
                else if (typeof b === 'number') s = call('bytes.dec', { b: a.slice(b, b + c), cs: d || 'UTF-8' });
                else s = call('bytes.dec', { b: a, cs: b || 'UTF-8' });
                return { toString: () => s, valueOf: () => s, getBytes: (cs) => call('bytes.enc', { s, cs: cs || 'UTF-8' }), length: () => s.length };
            }
            const Arrays = {
                copyOf: (a, n) => { const r = a.slice(0, n); while (r.length < n) r.push(0); return r; },
                copyOfRange: (a, from, to) => { const r = a.slice(from, to); while (r.length < to - from) r.push(0); return r; },
                toString: (a) => '[' + a.join(', ') + ']',
            };
            const Base64 = {
                getDecoder: () => ({ decode: (v) => call('b64.dec', { s: Array.isArray(v) ? call('bytes.dec', { b: v, cs: 'UTF-8' }) : str(v) }) }),
                getMimeDecoder: () => Base64.getDecoder(),
                getUrlDecoder: () => Base64.getDecoder(),
                getEncoder: () => ({ encodeToString: (b) => call('b64.enc', { b: bytesOf(b) }), encode: (b) => call('bytes.enc', { s: call('b64.enc', { b: bytesOf(b) }), cs: 'UTF-8' }) }),
            };
            function Inflater(nowrap) {
                let input = [];
                return {
                    setInput: (b, off, len) => { off = off || 0; input = b.slice(off, len == null ? b.length : off + len); },
                    inflate: (out, off, len) => { const r = call('inflate', { b: input, nowrap: !!nowrap }); off = off || 0; const n = Math.min(r.length, len == null ? out.length - off : len); for (let i = 0; i < n; i++) out[off + i] = r[i]; return n; },
                    end: () => {}, finished: () => true,
                };
            }
            const MessageDigest = { getInstance: (alg) => { let acc = []; return {
                        update: (b) => { acc = acc.concat(bytesOf(b)); },
                        digest: (b) => { const all = b === undefined ? acc : acc.concat(bytesOf(b)); acc = []; return call('digest', { alg: str(alg), b: all }); },
                    }; } };
            const Cipher = { getInstance: (t) => { let mode = 2, key = null, iv = null; return {
                        init: (m, k, p) => { mode = m; key = k; iv = p || null; },
                        doFinal: (b) => call('cipher', { t: str(t), mode, key: key.key, iv: iv ? iv.iv : null, b: bytesOf(b) }),
                    }; }, ENCRYPT_MODE: 1, DECRYPT_MODE: 2 };
            function SecretKeySpec(k, alg) { return { key: bytesOf(k), alg: str(alg) }; }
            function IvParameterSpec(v) { return { iv: bytesOf(v) }; }
            // Rhino scope helpers: `this.getHeaderMap()` (the request headers) and login state (not supported → empty).
            globalThis.getHeaderMap = () => call('headers', null);
globalThis.getSource = () => globalThis.source;
  // Rhino's JavaImporter + `with (...)`: Java packages are not available here; an empty scope keeps scripts running.
  globalThis.JavaImporter = function () { return new Object(); };
              
  // ---- login, browser and cache (Legado `source` / `cache` objects) ----
  const parseObj = (t) => { try { return JSON.parse(t) || new Object(); } catch (e) { return new Object(); } };
  globalThis.__wrapSource = (src) => {
src.getKey = () => src.bookSourceUrl;
    src.key = src.bookSourceUrl;
    src.getVariable = () => java.get('__sourceVariable');
    src.setVariable = (v) => java.put('__sourceVariable', str(v));
    src.get = (k) => java.get(k);
    src.put = (k, v) => java.put(k, v);
    src.getLoginInfo = () => call('loginInfo', null);
src.getLoginInfoMap = () => __jmap(parseObj(call('loginInfo', null)));
    src.putLoginInfo = (v) => { call('putLoginInfo', { v: str(v) }); return true; };
    src.removeLoginInfo = () => call('putLoginInfo', { v: '' });
    src.getLoginHeader = () => call('loginHeader', null);
src.getLoginHeaderMap = () => __jmap(parseObj(call('loginHeader', null)));
    src.putLoginHeader = (v) => call('putLoginHeader', { v: str(v) });
    src.removeLoginHeader = () => call('putLoginHeader', { v: '' });
    src.getLoginJs = () => '';
    return src;
  };
  globalThis.cache = {
    get: (k) => call('cacheGet', { k: str(k) }),
    put: (k, v, sec) => { call('cachePut', { k: str(k), v: v == null ? null : str(v), sec: Number(sec || 0) }); return v; },
    delete: (k) => call('cachePut', { k: str(k), v: null, sec: 0 }),
    getFromMemory: (k) => call('cacheGet', { k: 'mem.' + str(k) }),
    putMemory: (k, v) => call('cachePut', { k: 'mem.' + str(k), v: str(v), sec: 0 }),
    getFile: (k) => call('cacheGet', { k: 'file.' + str(k) }),
    putFile: (k, v, sec) => call('cachePut', { k: 'file.' + str(k), v: str(v), sec: Number(sec || 0) }),
  };
  Object.assign(globalThis.java, {
    webView: (html, url, js) => call('webView', { html: html == null ? null : str(html), url: url == null ? null : str(url), js: js == null ? null : str(js) }),
    webViewGetSource: (html, url, js) => call('webView', { html: html == null ? null : str(html), url: url == null ? null : str(url), js: js == null ? null : str(js) }),
    startBrowser: (url, title) => { call('browser', { url: str(url), title: title == null ? '' : str(title), wait: false }); return ''; },
    startBrowserAwait: (url, title) => { const b = call('browser', { url: str(url), title: title == null ? '' : str(title), wait: true }); return { body: () => b, code: () => 200, url: () => str(url) }; },
    showBrowser: (url, title) => { call('browser', { url: str(url), title: title == null ? '' : str(title), wait: false }); return ''; },
    getCookieStr: (u) => java.getCookie(u),
  });

  // ---- Jsoup / Java collections on top of host-side libxml nodes (handles) ----
  const jsoupEl = (h) => ({
    __h: h,
    select: (q) => jsoupEls(call('jsoup.select', { h: [h], q: str(q) })),
    selectFirst: (q) => { const r = call('jsoup.select', { h: [h], q: str(q), first: true }); return r.length ? jsoupEl(r[0]) : null; },
    getElementsByClass: (c) => jsoupEls(call('jsoup.select', { h: [h], q: '.' + str(c) })),
    getElementsByTag: (t) => jsoupEls(call('jsoup.select', { h: [h], q: str(t) })),
    getElementById: (i) => { const r = call('jsoup.select', { h: [h], q: '#' + str(i), first: true }); return r.length ? jsoupEl(r[0]) : null; },
    children: () => jsoupEls(call('jsoup.children', { h: [h] })),
    text: () => call('jsoup.text', { h: [h] }),
    ownText: () => call('jsoup.ownText', { h: [h] }),
    textNodes: () => call('jsoup.textNodes', { h: [h] }).map((t) => ({ text: () => t, toString: () => t })),
    attr: (k) => call('jsoup.attr', { h: [h], k: str(k) }),
    absUrl: (k) => call('jsoup.attr', { h: [h], k: 'abs:' + str(k) }),
    hasClass: (c) => (' ' + call('jsoup.attr', { h: [h], k: 'class' }) + ' ').indexOf(' ' + str(c) + ' ') >= 0,
    html: () => call('jsoup.html', { h: [h] }),
    outerHtml: () => call('jsoup.outer', { h: [h] }),
    toString: () => call('jsoup.outer', { h: [h] }),
  });
  const jsoupEls = (hs) => {
    const a = hs.map(jsoupEl);
    const def = (k, f) => Object.defineProperty(a, k, { value: f, enumerable: false });
    def('select', (q) => jsoupEls(call('jsoup.select', { h: hs, q: str(q) })));
    def('text', () => call('jsoup.text', { h: hs }));
    def('eachText', () => hs.map((x) => call('jsoup.text', { h: [x] })));
    def('attr', (k) => call('jsoup.attr', { h: hs, k: str(k) }));
    def('eachAttr', (k) => hs.map((x) => call('jsoup.attr', { h: [x], k: str(k) })));
    def('html', () => call('jsoup.html', { h: hs }));
    def('outerHtml', () => call('jsoup.outer', { h: hs }));
    def('first', () => (a.length ? a[0] : null));
    def('last', () => (a.length ? a[a.length - 1] : null));
    def('eq', (i) => jsoupEls(hs[i] === undefined ? [] : [hs[i]]));
    def('toString', () => call('jsoup.outer', { h: hs }));
    return a;
  };
  globalThis.org = { jsoup: { Jsoup: { parse: (html) => jsoupEl(call('jsoup.parse', { html: str(html) })) } } };
  Object.assign(globalThis.java, {
    getElement: (rule) => jsoupEls(call('jsoup.rule', { rule: str(rule) })),
    getElements: (rule) => jsoupEls(call('jsoup.rule', { rule: str(rule) })),
  });
  // Java List / Collection methods on arrays (rules hand `result` to scripts as lists).
  const listMethods = {
    toArray: function () { return this; },
    size: function () { return this.length; },
    get: function (i) { return this[i]; },
    isEmpty: function () { return this.length === 0; },
    add: function (x) { this.push(x); return true; },
    contains: function (x) { return this.indexOf(x) >= 0; },
  };
  for (const k of Object.keys(listMethods)) {
    if (!(k in Array.prototype)) Object.defineProperty(Array.prototype, k, { value: listMethods[k], enumerable: false, writable: true, configurable: true });
  }

  // ---- more Legado / Java bits seen in real sources ----
  Object.assign(globalThis.java, {
    t2s: (s) => call('convert', { s: str(s), to: 'Hant-Hans' }),
    s2t: (s) => call('convert', { s: str(s), to: 'Hans-Hant' }),
    randomUUID: () => { const u = call('uuid', null); return { toString: () => u, valueOf: () => u }; },
    timeFormatUTC: (t, fmt, off) => java.timeFormat(t),
    // RSA (hutool AsymmetricCrypto): public-key "decrypt" = verify-style recovery, used to unpack chapter text.
    createAsymmetricCrypto: (alg) => {
      let pub = null, priv = null;
      const toBytes = (d) => Array.isArray(d) ? d : call('b64.dec', { s: str(d) });
      const o = {
        setPublicKey: (k) => { pub = toBytes(k); return o; },
        setPrivateKey: (k) => { priv = toBytes(k); return o; },
 decrypt: (d) => call('rsa.dec', { key: pub, priv, b: toBytes(d) }),
 decryptStr: (d) => call('bytes.dec', { b: call('rsa.dec', { key: pub, priv, b: toBytes(d) }), cs: 'UTF-8' }),
 encrypt: (d) => call('rsa.enc', { key: pub, b: Array.isArray(d) ? d : call('bytes.enc', { s: str(d), cs: 'UTF-8' }) }),
        encryptBase64: (d) => call('b64.enc', { b: o.encrypt(d) }),
      };
      return o;
    },
    getTxtInFolder: () => '', importScript: () => '', cacheFile: () => '',
  });
  globalThis.cookie.removeCookie = (u) => call('cookieRemove', { url: str(u) });
  globalThis.cookie.setCookie = (u, c) => call('cookieSet', { url: str(u), c: str(c) });
  // Java Map methods on the maps sources get from us (login header / info): map.get("k"), containsKey …
  globalThis.__jmap = (o) => {
    const m = o || new Object();
    const def = (k, f) => Object.defineProperty(m, k, { value: f, enumerable: false, writable: true, configurable: true });
    def('get', (k) => (m[k] === undefined ? null : m[k]));
    def('put', (k, v) => { m[k] = v; return v; });
    def('containsKey', (k) => Object.prototype.hasOwnProperty.call(m, k));
    def('keySet', () => Object.keys(m));
    def('isEmpty', () => Object.keys(m).length === 0);
    return m;
  };
  globalThis.Packages = {
                    java: { lang: { String: JString, Thread: { sleep: () => {} } }, util: { Arrays, Base64, zip: { Inflater } }, security: { MessageDigest } },
                    javax: { crypto: { Cipher, spec: { SecretKeySpec, IvParameterSpec } } },
                    cn: { hutool: { crypto: { digest: { DigestUtil: { md5Hex: (s) => java.md5Encode(s) } } } } },
                };
                const sym = (t, key, iv) => {
                    const k = bytesOf(key), v = iv == null ? null : bytesOf(iv), tt = str(t);
                    const run = (mode, data) => call('cipher', { t: tt, mode, key: k, iv: v, b: data });
                    const input = (d) => Array.isArray(d) ? d : (/^[0-9a-fA-F]+$/.test(str(d)) && str(d).length % 2 === 0 ? call('hex.dec', { s: str(d) }) : call('b64.dec', { s: str(d) }));
                    return {
                        decrypt: (d) => run(2, input(d)),
                        decryptStr: (d) => call('bytes.dec', { b: run(2, input(d)), cs: 'UTF-8' }),
                        encrypt: (d) => run(1, bytesOf(d)),
                        encryptBase64: (d) => call('b64.enc', { b: run(1, bytesOf(d)) }),
                        encryptHex: (d) => call('hex.enc', { b: run(1, bytesOf(d)) }),
                    };
                };
                Object.assign(globalThis.java, {
                        createSymmetricCrypto: sym,
                        aesBase64DecodeToString: (d, k, t, iv) => sym(t, k, iv).decryptStr(d),
                        aesDecodeToString: (d, k, t, iv) => sym(t, k, iv).decryptStr(d),
                        aesEncodeToBase64String: (d, k, t, iv) => sym(t, k, iv).encryptBase64(d),
                        hexDecodeToString: (s) => call('bytes.dec', { b: call('hex.dec', { s: str(s) }), cs: 'UTF-8' }),
                        hexEncodeToString: (s) => call('hex.enc', { b: bytesOf(s) }),
                        base64DecodeToByteArray: (s) => call('b64.dec', { s: str(s) }),
                        strToBytes: (s, cs) => call('bytes.enc', { s: str(s), cs: cs || 'UTF-8' }),
                        bytesToStr: (b, cs) => call('bytes.dec', { b, cs: cs || 'UTF-8' }),
                        getWebViewUA: () => call('ua', {}),
                        androidId: () => call('androidId', {}),
                        ajaxAll: (urls) => (urls || []).map((u) => { try { const r = call('connect', { url: str(u) }); return { body: () => r.body, code: () => r.status, url: () => r.url }; } catch (e) { return { body: () => '', code: () => 500, url: () => str(u) }; } }),
                        getVerificationCode: () => { throw new Error('需要输入验证码（暂不支持）'); },
                        openUrl: () => {}, open: () => {}, getThemeConfig: () => ({}),
                });

                globalThis.__legado_call = call;
        })(__host);
"""#

    func eval(_ code: String, _ bindings: [String: Any]) throws -> Any? {
        let box = idj_new_with_eval(32 << 20, 1 << 20, legadoHostCallback, Unmanaged.passUnretained(self).toOpaque())
        guard let box else { throw LegadoError.rule("JS 引擎初始化失败") }
        defer { idj_free(box) }
        var err: UnsafeMutablePointer<CChar>?
        guard idj_load(box, Self.prelude, "export default {}", "legado", 5, &err) == 0 else {
            defer { if let err { idj_str_free(err) } }
            throw LegadoError.rule("JS 初始化失败：" + (err.map { String(cString: $0) } ?? ""))
        }
        var header = ""
        for (k, v) in bindings {
            let json = (JSONSerialization.isValidJSONObject([v]) ? try? JSONSerialization.data(withJSONObject: [v]) : nil).map { String(decoding: $0, as: UTF8.self) } ?? "[null]"
            header += "var \(k) = \(json)[0];\n"
        }
        // `book` / `source` / `chapter` objects also answer Legado's getter style (book.getVariable, source.getKey()).
        header += "if (typeof source === 'object' && source) __wrapSource(source);\n"
        header += "if (typeof book === 'object' && book) { book.getVariable = () => ''; }\n"
        // jsLib and the snippet run as separate scripts (separate scopes in Legado). Top-level `let` / `const` become
        // `var` so names declared in both, or by two snippets, do not clash in the shared global scope.
        if let lib = jsLib, !lib.isEmpty {
            guard let r = idj_eval_sloppy(box, header + Self.relaxed(lib), 8, &err) else {
                defer { if let err { idj_str_free(err) } }
                throw LegadoError.rule("jsLib：" + Self.message(err))
            }
            idj_str_free(r)
            header = ""
        }
        // The snippet runs inside a block: its top-level let / const stay local (no clash with the injected globals,
        // jsLib or earlier snippets) and the block's completion value is still the result.
        var src = header + "{\n" + code + "\n}"
        #if DEBUG
        // STV_LEGADO_JSSTACK=1: error messages carry the JS stack (to find which call failed in a big jsLib).
        if ProcessInfo.processInfo.environment["STV_LEGADO_JSSTACK"] == "1" {
            src = header + "try {\n" + code + "\n} catch (e) { throw new Error(String(e && e.message || e) + ' | ' + String(e && e.stack || '').replace(/\\n/g, ' / ')); }"
        }
        #endif
        guard let r = idj_eval_sloppy(box, src, 8, &err) else {
            defer { if let err { idj_str_free(err) } }
            let msg = err.map { String(cString: $0) } ?? "unknown"
            let m = (try? JSONSerialization.jsonObject(with: Data(msg.utf8)) as? [String: Any])?["message"] as? String ?? msg
            throw LegadoError.rule("JS：\(m)")
        }
        defer { idj_str_free(r) }
        return try? JSONSerialization.jsonObject(with: Data(String(cString: r).utf8), options: [.fragmentsAllowed])
    }

    static func relaxed(_ js: String) -> String {
        js.replacingOccurrences(of: #"(?m)^(\s{0,4})(?:let|const)(\s+[A-Za-z_$])"#, with: "$1var$2", options: .regularExpression)
    }

    static func message(_ err: UnsafeMutablePointer<CChar>?) -> String {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        return (try? JSONSerialization.jsonObject(with: Data(msg.utf8)) as? [String: Any])?["message"] as? String ?? msg
    }

    // Helpers used by the handler.
    static func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}

private let legadoHostCallback: idj_host_fn = { opaque, name, args, isErr in
    guard let opaque, let name else { return nil }
    let js = Unmanaged<LegadoJS>.fromOpaque(opaque).takeUnretainedValue()
    let a = args.flatMap { try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8), options: [.fragmentsAllowed]) }
    do {
        let r = try js.handler(String(cString: name), a)
        guard let r, !(r is NSNull) else { return strdup("null") }
        // isValidJSONObject first: NaN / non-JSON values make JSONSerialization raise an Objective-C exception.
        let wrapped: Any = [r]
        if JSONSerialization.isValidJSONObject(wrapped), let d = try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed]) {
            return strdup(String(decoding: d, as: UTF8.self))
        }
        return strdup("null")
    } catch {
        isErr?.pointee = 1
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let d = (try? JSONSerialization.data(withJSONObject: ["code": "E_HOST", "message": msg])) ?? Data()
        return strdup(String(decoding: d, as: UTF8.self))
    }
}
