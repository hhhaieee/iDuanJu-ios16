import Foundation

struct LegadoSearchItem: Hashable, Identifiable, Codable {
    var name: String
    var author: String
    var kind: String
    var intro: String
    var cover: String
    var latest: String
    var bookURL: String
    var sourceURL: String
    var sourceName: String
    var id: String { sourceURL + "|" + bookURL }
}

struct LegadoBookInfo: Hashable {
    var name: String
    var author: String
    var intro: String
    var cover: String
    var kind: String
    var latest: String
    var tocURL: String
}

struct LegadoChapter: Codable, Hashable {
    var title: String
    var url: String
}

/// Chapter text cleanup: HTML → paragraphs.
enum LegadoContent {
    static func text(fromHTML h0: String) -> String {
        // Escaped markup (`&lt;br/&gt;`) is unescaped first so its tags become line breaks too.
        let h = h0.contains("&lt;") && !h0.contains("<") ? HTMLText.decodeEntities(h0) : h0
        guard h.contains("<") else { return HTMLText.decodeEntities(h) }
        var s = h.replacingOccurrences(of: "<(script|style)[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|<p[^>]*>|</h\d>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTMLText.decodeEntities(s)
    }

    static func clean(_ raw: String) -> String {
        NovelImport.normalize(text(fromHTML: raw))
    }
}

/// Book-source operations (synchronous; call from a worker via the async wrappers).
enum LegadoClient {
    static func search(_ s: LegadoSource, key: String, page: Int = 1) throws -> [LegadoSearchItem] {
        let ctx = LegadoContext(source: s)
        ctx.key = key
        ctx.page = page
        guard let url = s.searchUrl, !url.isEmpty else { return [] }
        let r = try LegadoURL.request(url, ctx: ctx, base: s.bookSourceUrl)
        let resp = try r.fetch()
        let base = resp.url.absoluteString
        let rules = s.ruleSearch ?? [:]
        let page = LegadoAnalyzer(resp.text, baseURL: base, ctx: ctx)
        let list = try page.elements(rules["bookList"] ?? "")
        var out: [LegadoSearchItem] = []
        for el in list {
            let a = LegadoAnalyzer(el, baseURL: base, ctx: ctx)
            func f(_ k: String) -> String { (try? a.string(rules[k] ?? "")) ?? "" }
            let name = clean(f("name"))
            guard !name.isEmpty else { continue }
            var bookURL = f("bookUrl")
            bookURL = bookURL.isEmpty ? base : LegadoURL.absolute(bookURL, base: base)
            out.append(LegadoSearchItem(name: name, author: cleanAuthor(f("author")), kind: f("kind").replacingOccurrences(of: "\n", with: " · "),
                    intro: f("intro"), cover: LegadoURL.absolute(f("coverUrl"), base: base), latest: f("lastChapter"),
                    bookURL: bookURL, sourceURL: s.bookSourceUrl, sourceName: s.bookSourceName))
        }
        // Some sites jump straight to the book page when there is one hit.
        if out.isEmpty, let info = try? info(s, html: resp.text, url: base, ctx: ctx), !info.name.isEmpty {
            out.append(LegadoSearchItem(name: info.name, author: info.author, kind: info.kind, intro: info.intro, cover: info.cover,
                    latest: info.latest, bookURL: base, sourceURL: s.bookSourceUrl, sourceName: s.bookSourceName))
        }
        return out
    }

    static func info(_ s: LegadoSource, bookURL: String) throws -> LegadoBookInfo {
        let ctx = LegadoContext(source: s)
        ctx.book = ["bookUrl": bookURL]
        let r = try LegadoURL.request(bookURL, ctx: ctx, base: s.bookSourceUrl)
        let resp = try r.fetch()
        return try info(s, html: resp.text, url: resp.url.absoluteString, ctx: ctx, original: bookURL)
    }

    private static func info(_ s: LegadoSource, html: String, url: String, ctx: LegadoContext, original: String? = nil) throws -> LegadoBookInfo {
        let rules = s.ruleBookInfo ?? [:]
        var a = LegadoAnalyzer(html, baseURL: url, ctx: ctx)
        if let initRule = rules["init"], !initRule.isEmpty, let first = try a.elements(initRule).first {
            a = LegadoAnalyzer(first, baseURL: url, ctx: ctx)
        }
        func f(_ k: String) -> String { (try? a.string(rules[k] ?? "")) ?? "" }
        let toc = f("tocUrl")
        return LegadoBookInfo(name: clean(f("name")), author: cleanAuthor(f("author")), intro: f("intro"),
            cover: LegadoURL.absolute(f("coverUrl"), base: url), kind: f("kind").replacingOccurrences(of: "\n", with: " · "),
            latest: f("lastChapter"), tocURL: toc.isEmpty ? (original ?? url) : LegadoURL.absolute(toc, base: url))
    }

    /// Chapter list, following `nextTocUrl` (up to 100 pages). A `-` before `chapterList` reverses it.
    static func toc(_ s: LegadoSource, tocURL: String, book: [String: Any] = [:]) throws -> [LegadoChapter] {
        let ctx = LegadoContext(source: s)
        ctx.book = book
        let rules = s.ruleToc ?? [:]
        var out: [LegadoChapter] = []
        var next: [String] = [tocURL]
        var seen = Set<String>()
        while let u = next.first, seen.count < 100 {
            next.removeFirst()
            guard seen.insert(u).inserted else { continue }
            let r = try LegadoURL.request(u, ctx: ctx, base: s.bookSourceUrl)
            let resp = try r.fetch()
            let base = resp.url.absoluteString
            let page = LegadoAnalyzer(resp.text, baseURL: base, ctx: ctx)
            for el in try page.elements(rules["chapterList"] ?? "") {
                let a = LegadoAnalyzer(el, baseURL: base, ctx: ctx)
                let title = ((try? a.string(rules["chapterName"] ?? "")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let cu = (try? a.string(rules["chapterUrl"] ?? "")) ?? ""
                guard !title.isEmpty else { continue }
                out.append(LegadoChapter(title: title, url: cu.isEmpty ? base : LegadoURL.absolute(cu, base: base)))
            }
            if let nr = rules["nextTocUrl"], !nr.isEmpty {
                for n in (try? page.strings(nr)) ?? [] {
                    let abs = LegadoURL.absolute(n, base: base)
                    if !abs.isEmpty, !seen.contains(abs), abs != base { next.append(abs) }
                }
            }
        }
        return out
    }

    /// Chapter text, following `nextContentUrl` until it reaches the next chapter (up to 30 pages).
    static func content(_ s: LegadoSource, chapter: LegadoChapter, nextChapterURL: String?, book: [String: Any] = [:]) throws -> String {
        let ctx = LegadoContext(source: s)
        ctx.book = book
        ctx.chapter = ["title": chapter.title, "url": chapter.url]
        let rules = s.ruleContent ?? [:]
        var parts: [String] = []
        var url: String? = chapter.url
        var seen = Set<String>()
        while let u = url, seen.count < 30, seen.insert(u).inserted {
            let r = try LegadoURL.request(u, ctx: ctx, base: s.bookSourceUrl)
            let resp = try r.fetch()
            let base = resp.url.absoluteString
            let a = LegadoAnalyzer(resp.text, baseURL: base, ctx: ctx)
            parts.append(try a.strings(rules["content"] ?? "").joined(separator: "\n"))
            url = nil
            if let nr = rules["nextContentUrl"], !nr.isEmpty, let n = try? a.string(nr), !n.isEmpty {
                let abs = LegadoURL.absolute(n.components(separatedBy: "\n")[0], base: base)
                if abs != nextChapterURL, !seen.contains(abs) { url = abs }
            }
        }
        var text = LegadoContent.clean(parts.joined(separator: "\n"))
        if let rr = rules["replaceRegex"], !rr.isEmpty {
            for piece in rr.components(separatedBy: "\n") where !piece.isEmpty {
                let p = piece.hasPrefix("##") ? String(piece.dropFirst(2)) : piece
                let kv = p.components(separatedBy: "##")
                text = LegadoAnalyzer.replace(text, kv[0], kv.count > 1 ? kv[1] : "", firstOnly: false)
            }
            text = NovelImport.normalize(text)
        }
        guard !text.isEmpty else { throw LegadoError.empty("正文为空") }
        return text
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanAuthor(_ s: String) -> String {
        clean(s).replacingOccurrences(of: #"^(作\s*者\s*[：:]\s*)"#, with: "", options: .regularExpression)
    }

    // MARK: login

    struct LoginField: Hashable {
        var name: String
        var type: String          // text / password / select / button
        var options: [String]
        var action: String?
        var defaultValue: String
    }

    /// `loginUrl` as JS (function definitions), without the @js: / <js> wrapper; nil when it is a plain URL.
    static func loginJS(_ s: LegadoSource) -> String? {
        guard var t = s.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("@js:") { t.removeFirst(4) }
        else if t.hasPrefix("<js>") { t = t.replacingOccurrences(of: "<js>", with: "").replacingOccurrences(of: "</js>", with: "") }
        else if t.hasPrefix("http") || t.hasPrefix("/") { return nil }
        return t
    }

    /// The loginUi form (Legado accepts non-strict JSON, so it goes through JS first).
    static func loginFields(_ s: LegadoSource) -> [LoginField] {
        guard let ui = s.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !ui.isEmpty else { return [] }
        let ctx = LegadoContext(source: s)
        guard let v = try? ctx.js.eval("JSON.parse(JSON.stringify(" + ui + "))", [:]) as? [Any] else { return [] }
        return v.compactMap { $0 as? [String: Any] }.map { d in
            let options = (d["chars"] as? [Any])?.map { "\($0)" } ?? []
            return LoginField(name: d["name"] as? String ?? "", type: (d["type"] as? String ?? "text").lowercased(), options: options,
                action: d["action"] as? String, defaultValue: d["default"].map { "\($0)" } ?? options.first ?? "")
        }
    }

    /// Runs `loginJS + call` (a button action or `login()`), like Legado's login page.
    static func runLogin(_ s: LegadoSource, _ call: String) throws -> String {
        let ctx = LegadoContext(source: s)
        ctx.interactive = true
        let code = (loginJS(s) ?? "") + "\n" + call
        return LegadoAnalyzer.textOf(try ctx.evalJS(code, result: nil, baseURL: s.bookSourceUrl))
    }

    /// Login page URL for sources whose loginUrl is an address.
    static func loginPage(_ s: LegadoSource) -> URL? {
        guard loginJS(s) == nil, let t = s.loginUrl else { return nil }
        return LegadoURL.resolve(t, base: s.bookSourceUrl)
    }

    // MARK: async

    /// Runs a book-source operation on its own thread with an 8 MB stack: GCD workers have 512 KB, less than the
    /// JS engine's own stack limit, so deep recursion in a big jsLib would overflow the real stack and crash.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let t = Thread {
                do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
            }
            t.stackSize = 8 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
    }
}
