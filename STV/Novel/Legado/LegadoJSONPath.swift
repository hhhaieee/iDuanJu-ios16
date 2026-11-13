import Foundation

/// JSONPath subset used by Legado sources: `$`, `.key`, `['key']`, `[n]` (negative ok), `[*]` / `.*`, `[a,b]`,
/// `[start:end]`, recursive `..key`, filters `[?(@.k)]` / `[?(@.k op value)]` (== != < > <= >=, `&&`).
/// A path without a leading `$` is relative to the root (like jayway JsonPath).
enum LegadoJSONPath {
    static func read(_ root: Any, _ path: String) -> [Any] {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("@json:") { p.removeFirst(6) }
        if p.hasPrefix("$") { p.removeFirst() } else if !p.hasPrefix(".") && !p.hasPrefix("[") { p = "." + p }
        var cur: [Any] = [root]
        var i = p.startIndex
        while i < p.endIndex {
            if p[i...].hasPrefix("..") {
                i = p.index(i, offsetBy: 2)
                let all = cur.flatMap(descendants)
                if i < p.endIndex, p[i] == "[" {
                    let (sel, next) = bracket(p, i)
                    cur = all.flatMap { apply(sel, $0) }
                    i = next
                } else {
                    let (name, next) = ident(p, i)
                    cur = name == "*" ? all.flatMap(children) : all.compactMap { ($0 as? [String: Any])?[name] }
                    i = next
                }
            } else if p[i] == "." {
                i = p.index(after: i)
                if i < p.endIndex, p[i] == "[" { continue }   // `$.[*]` = `$[*]`
                let (name, next) = ident(p, i)
                cur = name == "*" ? cur.flatMap(children) : cur.compactMap { ($0 as? [String: Any])?[name] }
                i = next
            } else if p[i] == "[" {
                let (sel, next) = bracket(p, i)
                cur = cur.flatMap { apply(sel, $0) }
                i = next
            } else {
                let (name, next) = ident(p, i)
                cur = cur.compactMap { ($0 as? [String: Any])?[name] }
                i = next
            }
        }
        return cur
    }

    private static func ident(_ p: String, _ i: String.Index) -> (String, String.Index) {
        var j = i
        while j < p.endIndex, p[j] != ".", p[j] != "[" { j = p.index(after: j) }
        return (String(p[i..<j]), j)
    }

    /// Returns the bracket body and the index after `]` (quotes and nested parens respected).
    private static func bracket(_ p: String, _ i: String.Index) -> (String, String.Index) {
        var j = p.index(after: i), depth = 0
        var quote: Character?
        while j < p.endIndex {
            let c = p[j]
            if let q = quote { if c == q { quote = nil } }
            else if c == "'" || c == "\"" { quote = c }
            else if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            else if c == "]" && depth == 0 { break }
            j = p.index(after: j)
        }
        let body = String(p[p.index(after: i)..<min(j, p.endIndex)])
        return (body, j < p.endIndex ? p.index(after: j) : j)
    }

    private static func children(_ v: Any) -> [Any] {
        if let a = v as? [Any] { return a }
        if let d = v as? [String: Any] { return d.keys.sorted().compactMap { d[$0] } }
        return []
    }

    private static func descendants(_ v: Any) -> [Any] {
        [v] + children(v).flatMap(descendants)
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == "'" || f == "\"", t.last == f { return String(t.dropFirst().dropLast()) }
        return t
    }

    private static func apply(_ sel: String, _ v: Any) -> [Any] {
        let s = sel.trimmingCharacters(in: .whitespaces)
        if s == "*" { return children(v) }
        if s.hasPrefix("?(") && s.hasSuffix(")") { return children(v).filter { filter(String(s.dropFirst(2).dropLast()), $0) } }
        if let a = v as? [Any] {
            if s.contains(":") {
                let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                let n = a.count
                var lo = parts.first.flatMap { $0 } ?? 0, hi = parts.count > 1 ? (parts[1] ?? n) : n
                if lo < 0 { lo += n }; if hi < 0 { hi += n }
                lo = max(0, min(n, lo)); hi = max(lo, min(n, hi))
                return Array(a[lo..<hi])
            }
            return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.compactMap { i in
                let k = i < 0 ? a.count + i : i
                return a.indices.contains(k) ? a[k] : nil
            }
        }
        if let d = v as? [String: Any] {
            return s.split(separator: ",").compactMap { d[unquote(String($0))] }
        }
        return []
    }

    /// `@.a.b == 'x' && @.c > 3`, `@.k` (exists / truthy).
    private static func filter(_ expr: String, _ item: Any) -> Bool {
        for part in expr.components(separatedBy: "&&") {
            let e = part.trimmingCharacters(in: .whitespaces)
            var op: String?
            for o in ["==", "!=", "<=", ">=", "<", ">", "=~"] where e.contains(o) { op = o; break }
            guard let op else {
                let v = read(item, "$" + e.dropFirst(e.hasPrefix("@") ? 1 : 0)).first
                if v == nil || (v as? Bool) == false || v is NSNull { return false }
                continue
            }
            let sides = e.components(separatedBy: op)
            guard sides.count >= 2 else { return false }
            let lhs = read(item, "$" + sides[0].trimmingCharacters(in: .whitespaces).dropFirst(sides[0].trimmingCharacters(in: .whitespaces).hasPrefix("@") ? 1 : 0)).first
            let rhsRaw = sides[1...].joined(separator: op).trimmingCharacters(in: .whitespaces)
            let l = lhs.map(LegadoJSONPath.text) ?? ""
            let r = unquote(rhsRaw)
            let ln = Double(l), rn = Double(r)
            let ok: Bool
            switch op {
            case "==": ok = l == r
            case "!=": ok = l != r
            case "=~": ok = l.range(of: r.trimmingCharacters(in: CharacterSet(charactersIn: "/")), options: .regularExpression) != nil
            case "<": ok = (ln ?? 0) < (rn ?? 0)
            case ">": ok = (ln ?? 0) > (rn ?? 0)
            case "<=": ok = (ln ?? 0) <= (rn ?? 0)
            default: ok = (ln ?? 0) >= (rn ?? 0)
            }
            if !ok { return false }
        }
        return true
    }

    /// Scalar → text; containers → compact JSON.
    static func text(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case is NSNull: return ""
        default:
            guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "\(v)" }
            return String(decoding: d, as: UTF8.self)
        }
    }
}
