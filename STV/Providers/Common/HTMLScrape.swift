import Foundation

/// Regex-based HTML helpers mirroring gateway huangguo/parse.go.
enum HTML {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()
    static func re(_ p: String) -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[p] { return r }
        let r = try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
        cache[p] = r
        return r
    }
    static func groups(_ p: String, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re(p).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
    static func all(_ p: String, _ s: String) -> [[String]] {
        let ns = s as NSString
        return re(p).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    static func replace(_ p: String, _ s: String, _ with: String) -> String {
        re(p).stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    static func unescape(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " ", "&#x2F;": "/", "&#47;": "/"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        for m in all("&#(\\d+);", t) { if let n = UInt32(m[1]), let u = UnicodeScalar(n) { t = t.replacingOccurrences(of: m[0], with: String(Character(u))) } }
        return t
    }

    static let nonContent = "<!--.*?-->|<script\\b[^>]*>.*?</script\\s*>|<style\\b[^>]*>.*?</style\\s*>"

    static func cleanText(_ s: String) -> String {
        var t = replace(nonContent, s, " ")
        t = replace("<[^>]+>", t, " ")
        t = unescape(t)
        return replace("[\\s\\u00a0\\u3000]+", t, " ").trimmingCharacters(in: .whitespaces)
    }

    static func attr(_ block: String, _ names: String...) -> String {
        for n in names {
            if let m = groups("\\b" + NSRegularExpression.escapedPattern(for: n) + "\\s*=\\s*[\"']([^\"']+)[\"']", block) {
                return unescape(m[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    static func classText(_ raw: String, _ cls: String) -> String {
        if let m = groups("<[^>]+class=[\"'][^\"']*\\b" + NSRegularExpression.escapedPattern(for: cls) + "\\b[^\"']*[\"'][^>]*>(.*?)</[a-z0-9]+>", raw) {
            return cleanText(m[1])
        }
        return ""
    }

    static func pageTitle(_ h: String) -> String {
        if let m = groups("<h1[^>]*>(.*?)</h1>", h) { let t = cleanText(m[1]); if !t.isEmpty { return t } }
        if let m = groups("<meta\\b[^>]*property=[\"']og:title[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>", h) { return unescape(m[1]).trimmingCharacters(in: .whitespaces) }
        if let m = groups("<title[^>]*>(.*?)</title>", h) { return cleanText(m[1]) }
        return ""
    }
    static func description(_ h: String) -> String {
        groups("<meta\\b[^>]*(?:name|property)=[\"'](?:description|og:description)[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>", h).map { unescape($0[1]) } ?? ""
    }
    /// Path (+query) of an absolute URL, keeping the trailing slash — `URL.path` drops it, and
    /// e.g. jable.tv answers `/videos/<id>` (no slash) with 404.
    static func sitePath(_ url: String) -> String? {
        guard let c = URLComponents(string: url), c.host != nil else { return nil }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return c.percentEncodedQuery.map { p + "?" + $0 } ?? p
    }

    static func ogImage(_ h: String) -> String {
        groups("<meta\\b[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>", h).map { $0[1].trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func episodeIndex(_ s: String, _ fallback: Int) -> Int {
        if let m = groups("(?:第\\s*0*(\\d+)\\s*(?:集|话|期)|(?:更新至|共|全)\\s*0*(\\d+)\\s*(?:集|话|期)|(?:episode|ep)\\s*#?\\s*0*(\\d+))", s) {
            for g in m.dropFirst() where !g.isEmpty { if let n = Int(g), n > 0 { return n } }
        }
        return fallback
    }

    static func cleanID(_ s: String) -> String {
        var t = unescape(s).trimmingCharacters(in: CharacterSet(charactersIn: " /\t\r\n\"'"))
        if let i = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<i]) }
        return t
    }

    static func resolve(_ base: String, _ ref: String) -> String {
        var r = unescape(ref).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\/", with: "/")
        if r.isEmpty { return "" }
        if r.hasPrefix("//") { r = "https:" + r }
        guard let u = URL(string: r, relativeTo: URL(string: base)) else { return r }
        var s = u.absoluteString
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        return s
    }

    static func mediaURL(_ page: String, _ raw: String) -> String {
        let t = unescape(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
        if t.isEmpty { return "" }
        let r = resolve(page, t)
        let l = r.lowercased()
        return (l.contains(".m3u8") || l.contains(".mp4")) ? r : ""
    }

    static func detailID(_ s: String) -> String {
        let path = URL(string: unescape(s))?.path ?? s
        let parts = path.split(separator: "/").map(String.init)
        for i in 0..<max(0, parts.count - 1) where parts[i] == "detail" { return cleanID(parts[i + 1]) }
        return ""
    }

    static func titleNeedsRepair(_ t: String, _ id: String) -> Bool {
        let t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == id || t == "短剧" || t == "搜索" ||
            groups("(?:\\b(?:class|type|title|aria-label)\\s*=|(?:data|ata)-search-input|hg-search(?:__|-))", t) != nil
    }
}

/// HLS playlist helpers (huangguo/hls.go).
enum HLSPlaylist {
    struct Variant { var url: String; var width = 0; var height = 0; var bandwidth = 0 }
    struct KeyInfo { var method = ""; var uri = ""; var iv = ""; var encrypted = false }

    static func variants(_ master: String, _ masterURL: String) -> [Variant] {
        var out: [Variant] = []
        var pending: Variant?
        for line in master.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
                var v = Variant(url: "")
                if let m = HTML.groups("RESOLUTION\\s*=\\s*(\\d+)x(\\d+)", t) { v.width = Int(m[1]) ?? 0; v.height = Int(m[2]) ?? 0 }
                if let m = HTML.groups("(?:AVERAGE-)?BANDWIDTH\\s*=\\s*(\\d+)", t) { v.bandwidth = Int(m[1]) ?? 0 }
                pending = v; continue
            }
            if t.hasPrefix("#") { continue }
            guard var v = pending, let u = URL(string: t, relativeTo: URL(string: masterURL))?.absoluteURL,
                  ["http", "https"].contains(u.scheme ?? "") else { pending = nil; continue }
            v.url = u.absoluteString
            out.append(v); pending = nil
        }
        return out.sorted { $0.height != $1.height ? $0.height > $1.height : $0.bandwidth > $1.bandwidth }
    }

    static func keys(_ pl: String, _ plURL: String) -> KeyInfo {
        var info = KeyInfo()
        for line in pl.split(whereSeparator: \.isNewline) {
            guard let m = HTML.groups("^#EXT-X-KEY:\\s*(.*)$", line.trimmingCharacters(in: .whitespaces)) else { continue }
            let a = m[1]
            let method = HTML.groups("METHOD\\s*=\\s*([A-Za-z0-9-]+)", a)?[1].uppercased() ?? "AES-128"
            if method == "NONE" { continue }
            info.encrypted = true
            if info.method.isEmpty { info.method = method }
            if info.uri.isEmpty, let u = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", a) {
                info.uri = URL(string: u[1], relativeTo: URL(string: plURL))?.absoluteString ?? u[1]
                info.iv = HTML.groups("\\bIV\\s*=\\s*(0x[0-9a-fA-F]+)", a)?[1] ?? ""
            }
        }
        return info
    }

    static func duration(_ pl: String) -> Double {
        pl.split(whereSeparator: \.isNewline).reduce(0) { acc, l in
            acc + (HTML.groups("^#EXTINF:\\s*([0-9.]+)", l.trimmingCharacters(in: .whitespaces)).flatMap { Double($0[1]) } ?? 0)
        }
    }

    static func quality(_ v: Variant) -> String {
        switch v.height {
        case 2160...: return "2160p"; case 1440...: return "1440p"; case 1080...: return "1080p"
        case 720...: return "720p"; case 480...: return "480p"; case 1...: return "\(v.height)p"
        default: return v.bandwidth > 0 ? "\(v.bandwidth / 1000)kbps" : "source"
        }
    }

    static func keyHex(_ body: Data) -> String {
        let b = [UInt8](body)
        if let s = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), s.count == 32, Bytes.fromHex(s) != nil { return s.lowercased() }
        if b.count == 16 { return Bytes.hex(b) }
        if b.count > 16, String(decoding: b[16...], as: UTF8.self).trimmingCharacters(in: .newlines).isEmpty { return Bytes.hex(Array(b[0..<16])) }
        return ""
    }
}
