import Foundation
import libxml2

/// CSS selector → XPath 1.0 (subset: type, *, #id, .class, [attr], [a=v] [a~=v] [a^=v] [a$=v] [a*=v] [a|=v] [a!=v],
/// descendant / > / + / ~ combinators, comma groups, :first-child :last-child :nth-child(n) :not(simple) :contains(text)).
enum CSSXPath {
    struct Bad: Error { let message: String }

    static func convert(_ css: String) throws -> String {
        let groups = split(css, by: ",")
        guard !groups.isEmpty else { throw Bad(message: "空选择器") }
        return try groups.map { try one($0) }.joined(separator: " | ")
    }

    static func literal(_ s: String) -> String {
        if !s.contains("'") { return "'\(s)'" }
        if !s.contains("\"") { return "\"\(s)\"" }
        return "concat(" + s.split(separator: "'", omittingEmptySubsequences: false).map { "'\($0)'" }.joined(separator: ", \"'\", ") + ")"
    }

    /// Splits on `sep` outside brackets / parens / quotes.
    private static func split(_ s: String, by sep: Character) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        var quote: Character?
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); continue }
            if ch == "[" || ch == "(" { depth += 1 } else if ch == "]" || ch == ")" { depth -= 1 }
            if ch == sep && depth == 0 { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func one(_ sel: String) throws -> String {
        // Tokenize into compounds and combinators.
        var parts: [(comb: Character, compound: String)] = []
        var cur = "", depth = 0, pending: Character = " "
        var quote: Character?
        func flush() { if !cur.isEmpty { parts.append((pending, cur)); cur = ""; pending = " " } }
        for ch in sel {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); continue }
            if ch == "[" || ch == "(" { depth += 1 } else if ch == "]" || ch == ")" { depth -= 1 }
            if depth == 0 && (ch == ">" || ch == "+" || ch == "~") { flush(); pending = ch; continue }
            if depth == 0 && ch.isWhitespace { flush(); continue }
            cur.append(ch)
        }
        flush()
        guard !parts.isEmpty else { throw Bad(message: "空选择器") }
        var x = ""
        for (i, p) in parts.enumerated() {
            let (tag, preds) = try compound(p.compound)
            let pr = preds.map { "[\($0)]" }.joined()
            switch (i == 0 ? " " : p.comb) {
            case ">": x += "/\(tag)\(pr)"
            case "+": x += "/following-sibling::*[1]" + (tag == "*" ? "" : "[self::\(tag)]") + pr
            case "~": x += "/following-sibling::\(tag)\(pr)"
            default: x += (i == 0 ? ".//" : "//") + tag + pr
            }
        }
        return x
    }

    /// One compound selector → (tag, predicates).
    static func compound(_ s: String) throws -> (String, [String]) {
        var tag = "*"
        var preds: [String] = []
        var i = s.startIndex
        func readIdent() -> String {
            var r = ""
            while i < s.endIndex, s[i].isLetter || s[i].isNumber || s[i] == "-" || s[i] == "_" || s[i] == "\\" {
                if s[i] == "\\" { i = s.index(after: i); if i < s.endIndex { r.append(s[i]) } } else { r.append(s[i]) }
                if i < s.endIndex { i = s.index(after: i) }
            }
            return r
        }
        if i < s.endIndex, s[i] == "*" { i = s.index(after: i) }
        else if i < s.endIndex, s[i].isLetter { tag = readIdent().lowercased() }
        while i < s.endIndex {
            let c = s[i]
            i = s.index(after: i)
            switch c {
            case "#": preds.append("@id=\(literal(readIdent()))")
            case ".": preds.append("contains(concat(' ', normalize-space(@class), ' '), \(literal(" " + readIdent() + " ")))")
            case "[":
                guard let close = s[i...].firstIndex(of: "]") else { throw Bad(message: "缺少 ]") }
                preds.append(try attribute(String(s[i..<close])))
                i = s.index(after: close)
            case ":":
                let name = readIdent().lowercased()
                var arg = ""
                if i < s.endIndex, s[i] == "(" {
                    var depth = 0, j = i
                    repeat {
                        if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 }
                        j = s.index(after: j)
                    } while depth > 0 && j < s.endIndex
                    arg = String(s[s.index(after: i)..<s.index(before: j)])
                    i = j
                }
                switch name {
                case "first-child": preds.append("not(preceding-sibling::*)")
                case "last-child": preds.append("not(following-sibling::*)")
                case "only-child": preds.append("not(preceding-sibling::*) and not(following-sibling::*)")
                case "nth-child":
                    guard let n = Int(arg.trimmingCharacters(in: .whitespaces)), n > 0 else { throw Bad(message: ":nth-child 只支持数字") }
                    preds.append("count(preceding-sibling::*) = \(n - 1)")
                case "not":
                    let (t, p) = try compound(arg.trimmingCharacters(in: .whitespaces))
                    var all = p
                    if t != "*" { all.insert("self::\(t)", at: 0) }
                    preds.append("not(" + (all.isEmpty ? "false()" : all.map { "(\($0))" }.joined(separator: " and ")) + ")")
                case "contains": preds.append("contains(string(.), \(literal(unquote(arg))))")
                // jsoup extras (Legado book sources use them)
                case "containsown": preds.append("text()[contains(., \(literal(unquote(arg))))]")
                case "has":
                    let inner = try one(arg.trimmingCharacters(in: .whitespaces).hasPrefix(">") ? String(arg.trimmingCharacters(in: .whitespaces).dropFirst()) : arg)
                    preds.append(arg.trimmingCharacters(in: .whitespaces).hasPrefix(">") ? "./" + inner.dropFirst(3) : inner)
                case "first-of-type": preds.append(tag == "*" ? "not(preceding-sibling::*)" : "not(preceding-sibling::\(tag))")
                case "last-of-type": preds.append(tag == "*" ? "not(following-sibling::*)" : "not(following-sibling::\(tag))")
                case "nth-of-type":
                    guard let n = Int(arg.trimmingCharacters(in: .whitespaces)), n > 0 else { throw Bad(message: ":nth-of-type 只支持数字") }
                    preds.append("count(preceding-sibling::\(tag == "*" ? "*" : tag)) = \(n - 1)")
                // jsoup :eq / :lt / :gt compare the element's index among its siblings (0-based).
                case "eq", "lt", "gt":
                    guard let n = Int(arg.trimmingCharacters(in: .whitespaces)) else { throw Bad(message: ":\(name) 只支持数字") }
                    let op = name == "eq" ? "=" : name == "lt" ? "<" : ">"
                    preds.append(n < 0 && name == "eq" ? "count(following-sibling::*) = \(-n - 1)" : "count(preceding-sibling::*) \(op) \(n)")
                default: throw Bad(message: "不支持的伪类 :\(name)")
                }
            default: throw Bad(message: "无法解析选择器：\(s)")
            }
        }
        return (tag, preds)
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { return String(t.dropFirst().dropLast()) }
        return t
    }

    private static func attribute(_ body: String) throws -> String {
        let ops = ["~=", "^=", "$=", "*=", "|=", "!=", "="]
        for op in ops {
            if let r = body.range(of: op) {
                let name = body[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                var v = unquote(String(body[r.upperBound...]))
                if v.hasSuffix(" i") { v = String(v.dropLast(2)) }
                let a = "@\(name)", l = literal(v)
                switch op {
                case "=": return "\(a)=\(l)"
                case "!=": return "not(\(a)=\(l))"
                case "~=": return "contains(concat(' ', normalize-space(\(a)), ' '), \(literal(" " + v + " ")))"
                case "^=": return "starts-with(\(a), \(l))"
                case "$=": return "substring(\(a), string-length(\(a)) - string-length(\(l)) + 1) = \(l)"
                case "*=": return "contains(\(a), \(l))"
                default: return "(\(a)=\(l) or starts-with(\(a), concat(\(l), '-')))"
                }
            }
        }
        let name = body.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { throw Bad(message: "空属性选择器") }
        return "@\(name)"
    }
}

/// libxml2 HTML documents for one plugin call. Node handles are small integers valid until `reset()`.
final class HTMLSession {
    private var docs: [htmlDocPtr] = []
    private var nodes: [xmlNodePtr] = []
    static let maxNodes = 300_000
    static let maxDocs = 64

    deinit { reset() }

    func reset() {
        for d in docs { xmlFreeDoc(d) }
        docs = []; nodes = []
    }

    func parse(_ text: String) throws -> Int {
        guard docs.count < Self.maxDocs else { throw PluginError.runtime(code: "E_MEMORY", message: "单次调用解析的页面太多") }
        let opts = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue | HTML_PARSE_COMPACT.rawValue)
        var src = text.isEmpty ? "<html></html>" : text
        if src.utf8.count > 20 * 1024 * 1024 { src = String(src.prefix(20 * 1024 * 1024)) }
        let doc: htmlDocPtr? = src.withCString { p in htmlReadMemory(p, Int32(strlen(p)), "about:blank", "UTF-8", opts) }
        guard let doc else { throw PluginError.runtime(code: "E_PARSE", message: "HTML 解析失败") }
        docs.append(doc)
        return add(UnsafeMutableRawPointer(doc).assumingMemoryBound(to: xmlNode.self))
    }

    private func add(_ n: xmlNodePtr) -> Int { nodes.append(n); return nodes.count }

    private func node(_ id: Int) throws -> xmlNodePtr {
        guard id >= 1, id <= nodes.count else { throw PluginError.runtime(code: "E_INTERNAL", message: "节点句柄无效（只能在同一次调用里使用）") }
        return nodes[id - 1]
    }

    func select(_ id: Int, _ css: String, first: Bool) throws -> [Int] {
        let n = try node(id)
        let xpath: String
        do { xpath = try CSSXPath.convert(css) } catch let e as CSSXPath.Bad { throw PluginError.runtime(code: "E_PARSE", message: "选择器错误 \(css)：\(e.message)") }
        guard let ctx = xmlXPathNewContext(n.pointee.doc) else { throw PluginError.runtime(code: "E_INTERNAL", message: "xpath ctx") }
        defer { xmlXPathFreeContext(ctx) }
        ctx.pointee.node = n
        guard let obj = xmlXPathEvalExpression(xpath, ctx) else { throw PluginError.runtime(code: "E_PARSE", message: "选择器无法执行：\(css)") }
        defer { xmlXPathFreeObject(obj) }
        guard let set = obj.pointee.nodesetval else { return [] }
        var out: [Int] = []
        let count = Int(set.pointee.nodeNr)
        for i in 0..<count {
            guard let m = set.pointee.nodeTab[i], m.pointee.type == XML_ELEMENT_NODE else { continue }
            guard nodes.count < Self.maxNodes else { throw PluginError.runtime(code: "E_MEMORY", message: "节点太多") }
            out.append(add(m))
            if first { break }
        }
        return out
    }

    func text(_ id: Int) throws -> String {
        let n = try node(id)
        guard let c = xmlNodeGetContent(n) else { return "" }
        defer { xmlFree(c) }
        let s = String(cString: c)
        if n.pointee.type == XML_ELEMENT_NODE, let name = n.pointee.name, ["script", "style"].contains(String(cString: name)) { return s }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func attr(_ id: Int, _ name: String) throws -> String {
        let n = try node(id)
        guard n.pointee.type == XML_ELEMENT_NODE, let v = xmlGetProp(n, name.lowercased()) else { return "" }
        defer { xmlFree(v) }
        return String(cString: v)
    }

    func html(_ id: Int, outer: Bool) throws -> String {
        let n = try node(id)
        guard let buf = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buf) }
        if outer || n.pointee.type == XML_HTML_DOCUMENT_NODE {
            if n.pointee.type == XML_HTML_DOCUMENT_NODE, let root = xmlDocGetRootElement(n.pointee.doc) { htmlNodeDump(buf, n.pointee.doc, root) }
            else { htmlNodeDump(buf, n.pointee.doc, n) }
        } else {
            var c = n.pointee.children
            while let child = c { htmlNodeDump(buf, n.pointee.doc, child); c = child.pointee.next }
        }
        guard let content = xmlBufferContent(buf) else { return "" }
        return String(cString: content)
    }
}
