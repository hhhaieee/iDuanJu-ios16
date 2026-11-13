import Foundation

/// Dean Edwards `eval(function(p,a,c,k,e,d){…})` unpacker — pure string substitution, never runs remote JS.
/// Port of UAV-Downloader `sites/missav.py::_unpack_js_eval` (Apache-2.0), incl. its guards.
enum JSUnpacker {
    static func unpack(_ script: String) -> String? {
        guard let m = HTML.groups("eval\\(function\\(p,a,c,k,e,d\\)\\{.*?\\}\\('(.*?)',\\s*(\\d+),\\s*(\\d+),\\s*'([^']*)'\\s*\\.split\\('\\|'\\)", script),
              let a = Int(m[2]), let c = Int(m[3]) else { return nil }
        // base <= 1 would loop forever; absurd counts would allocate unbounded tables.
        guard a > 1, a <= 62, c >= 0, c <= 200_000 else { return nil }
        let packed = m[1]
        let keys = m[4].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var lookup: [String: String] = [:]
        for i in 0..<c {
            let k = toBase(i, a)
            lookup[k] = (i < keys.count && !keys[i].isEmpty) ? keys[i] : k
        }
        let ns = packed as NSString
        var out = ""
        var last = 0
        for w in HTML.re("\\b(\\w+)\\b").matches(in: packed, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: w.range.location - last))
            let token = ns.substring(with: w.range)
            out += lookup[token] ?? token
            last = w.range.location + w.range.length
        }
        out += ns.substring(from: last)
        return out.replacingOccurrences(of: "\\'", with: "'")
    }

    private static func toBase(_ n: Int, _ base: Int) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if n == 0 { return "0" }
        var n = n, s = ""
        while n > 0 { s = String(digits[n % base]) + s; n /= base }
        return s
    }

    /// All packed `<script>` blocks of a page, unpacked.
    static func unpackedScripts(_ html: String) -> [String] {
        HTML.all("<script[^>]*>(.*?)</script>", html).compactMap { m in
            m[1].contains("eval(function(p,a,c,k,e,d)") ? unpack(m[1]) : nil
        }
    }
}
