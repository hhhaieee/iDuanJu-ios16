import Foundation
import Compression

/// One chapter of a converted book: a UTF-16 range of the book's plain text.
struct NovelChapter: Codable, Hashable {
    var title: String
    var start: Int
    var end: Int
    var length: Int { end - start }
}

/// Result of importing a local file: plain text (paragraphs separated by "\n") plus chapter ranges.
struct NovelParsed {
    var title: String
    var author: String?
    var text: String
    var chapters: [NovelChapter]
    var cover: Data?
}

enum NovelImportError: LocalizedError {
    case unreadable, unsupported(String), badEPUB(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: "无法识别文件编码"
        case .unsupported(let e): "不支持的格式：\(e)（支持 TXT / EPUB）"
        case .badEPUB(let why): "EPUB 解析失败：\(why)"
        }
    }
}

enum NovelImport {
    static func parse(_ data: Data, fileName: String) throws -> NovelParsed {
        let base = (fileName as NSString).deletingPathExtension
        switch (fileName as NSString).pathExtension.lowercased() {
        case "txt", "text", "":
            guard let raw = decodeText(data) else { throw NovelImportError.unreadable }
            let text = normalize(raw)
            return NovelParsed(title: base, author: nil, text: text, chapters: splitChapters(text), cover: nil)
        case "epub":
            return try EPUB.parse(data, fallbackTitle: base)
        case let e:
            throw NovelImportError.unsupported(e)
        }
    }

    // MARK: TXT

    /// BOM first, then strict UTF-8, then GB18030 (covers GBK / GB2312), then Big5.
    static func decodeText(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(3))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(data: data.dropFirst(3), encoding: .utf8) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data, encoding: .utf16LittleEndian).map { String($0.drop { $0 == "\u{FEFF}" }) } }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data, encoding: .utf16BigEndian).map { String($0.drop { $0 == "\u{FEFF}" }) } }
        if let s = String(data: data, encoding: .utf8) { return s }
        for cf in [CFStringEncodings.GB_18030_2000, .big5] {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }

    /// Unix newlines, trimmed paragraphs (leading full-width indents are re-applied by the reader), no blank runs.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}\u{00A0}"))) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 第X章 / 第X回 / 卷 / 节 / Chapter N / 序章 / 楔子 … on their own line.
    static let headingPattern = try! NSRegularExpression(
        pattern: #"^(?:第[0-9零〇一二两三四五六七八九十百千万]+[章回节卷集部篇](?:[ 　:：·、.\-—].{0,30}|.{0,30})|(?:chapter|CHAPTER|Chapter)\s*\d+.{0,30}|序章.{0,20}|序言|前言|楔子.{0,20}|引子.{0,20}|尾声.{0,20}|后记|番外.{0,24})$"#,
        options: [.anchorsMatchLines])

    static func splitChapters(_ text: String) -> [NovelChapter] {
        let ns = text as NSString
        let total = ns.length
        var heads: [(title: String, start: Int)] = []
        headingPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: total)) { m, _, _ in
            guard let r = m?.range, r.length <= 40 else { return }
            heads.append((ns.substring(with: r), r.location))
        }
        var out: [NovelChapter] = []
        if let first = heads.first {
            // Text before the first heading (书名 / 简介) becomes its own page when it is more than a stub.
            if first.start > 0, ns.substring(to: first.start).trimmingCharacters(in: .whitespacesAndNewlines).count > 80 {
                out.append(NovelChapter(title: "前言", start: 0, end: first.start))
            }
            for (i, h) in heads.enumerated() {
                let start = i == 0 && out.isEmpty ? 0 : h.start
                let end = i + 1 < heads.count ? heads[i + 1].start : total
                out.append(NovelChapter(title: h.title, start: start, end: end))
            }
            return out.filter { $0.length > 0 }
        }
        // No headings: ~8000-character sections cut at paragraph ends.
        var start = 0, n = 1
        while start < total {
            var end = min(total, start + 8000)
            if end < total {
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: end, length: min(2000, total - end)))
                end = nl.location == NSNotFound ? end : nl.location + 1
            }
            out.append(NovelChapter(title: "第 \(n) 节", start: start, end: end))
            start = end; n += 1
        }
        return out
    }
}

// MARK: - EPUB

enum EPUB {
    static func parse(_ data: Data, fallbackTitle: String) throws -> NovelParsed {
        let zip = try ZipArchive(data)
        guard let container = zip.text("META-INF/container.xml"),
        let opfPath = firstMatch(#"full-path\s*=\s*"([^"]+)""#, in: container) else { throw NovelImportError.badEPUB("缺少 container.xml") }
        guard let opf = zip.text(opfPath) else { throw NovelImportError.badEPUB("缺少 \(opfPath)") }
        let dir = (opfPath as NSString).deletingLastPathComponent
        let pkg = OPF(opf)

        var text = "", chapters: [NovelChapter] = []
        for idref in pkg.spine {
            guard let item = pkg.manifest[idref], item.type.contains("html") else { continue }
            guard let html = zip.text(resolve(item.href, in: dir)) else { continue }
            let (title, body) = HTMLText.extract(html)
            guard !body.isEmpty else { continue }
            let chapterTitle = title ?? "第 \(chapters.count + 1) 章"
            // Title is the chapter's first line unless the body already starts with it.
            let chunk = body.hasPrefix(chapterTitle) ? body : chapterTitle + "\n" + body
            let start = (text as NSString).length
            text += (text.isEmpty ? "" : "\n") + chunk
            chapters.append(NovelChapter(title: chapterTitle, start: start == 0 ? 0 : start + 1, end: (text as NSString).length))
        }
        guard !chapters.isEmpty else { throw NovelImportError.badEPUB("没有正文") }
        let cover = pkg.coverHref.flatMap { zip.data(resolve($0, in: dir)) }
        return NovelParsed(title: pkg.title ?? fallbackTitle, author: pkg.author, text: text, chapters: chapters, cover: cover)
    }

    static func resolve(_ href: String, in dir: String) -> String {
        let clean = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
        var parts: [String] = dir.isEmpty ? [] : dir.components(separatedBy: "/")
        for p in clean.components(separatedBy: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." && !p.isEmpty { parts.append(p) }
        }
        return parts.joined(separator: "/")
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
        let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Minimal OPF reader: dc:title / dc:creator, manifest, spine, cover image.
    final class OPF: NSObject, XMLParserDelegate {
        struct Item { var href: String; var type: String; var properties: String }
        var title: String?, author: String?
        var manifest: [String: Item] = [:]
        var spine: [String] = []
        private var coverId: String?
        private var buffer = "", inTitle = false, inCreator = false

        init(_ xml: String) {
            super.init()
            let p = XMLParser(data: Data(xml.utf8))
            p.shouldProcessNamespaces = false
            p.delegate = self
            p.parse()
        }

        var coverHref: String? {
            if let id = coverId, let i = manifest[id], i.type.hasPrefix("image") { return i.href }
            return manifest.values.first { $0.properties.contains("cover-image") }?.href
        }

        private func local(_ name: String) -> String { name.components(separatedBy: ":").last ?? name }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch local(name) {
            case "item":
                if let id = a["id"], let href = a["href"] { manifest[id] = Item(href: href, type: a["media-type"] ?? "", properties: a["properties"] ?? "") }
            case "itemref":
                if let id = a["idref"], a["linear"] != "no" { spine.append(id) }
            case "meta":
                if a["name"] == "cover" { coverId = a["content"] }
            case "title" where title == nil: inTitle = true; buffer = ""
            case "creator" where author == nil: inCreator = true; buffer = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle || inCreator { buffer += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if inTitle, local(name) == "title" { inTitle = false; if !v.isEmpty { title = v } }
            if inCreator, local(name) == "creator" { inCreator = false; if !v.isEmpty { author = v } }
        }
    }
}

/// XHTML chapter → (heading, plain paragraphs). Regex-based on purpose: XMLParser rejects the many
/// EPUBs with HTML entities or sloppy markup, and NSAttributedString(html:) must run on the main thread.
enum HTMLText {
    static func extract(_ html: String) -> (title: String?, body: String) {
        var s = html
        for tag in ["head", "script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        let heading = EPUB.firstMatch(#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, in: s).map { clean(strip($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        ?? EPUB.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map { clean(strip($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        s = s.replacingOccurrences(of: #"<br\s*/?>|</(p|div|h[1-6]|li|tr|blockquote|section)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let body = NovelImport.normalize(decodeEntities(strip(s)))
        return (heading, body)
    }

    static func strip(_ s: String) -> String { s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
    static func clean(_ s: String) -> String {
        decodeEntities(s).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&hellip;": "…", "&mdash;": "—", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = "", last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) { result += String(Character(u)) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Read-only ZIP (stored + deflate) — enough for EPUB. Reads the central directory, inflates with Compression.
struct ZipArchive {
    private struct Entry { var method: UInt16; var compressed: Int; var size: Int; var localOffset: Int }
    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 22 else { throw NovelImportError.badEPUB("不是 ZIP 文件") }
        var eocd = -1
        var i = n - 22
        while i >= max(0, n - 65_557) { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw NovelImportError.badEPUB("不是 ZIP 文件") }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10)
            let csize = Int(u32(p + 20)), usize = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            let local = Int(u32(p + 42))
            guard p + 46 + nameLen <= n else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: method, compressed: csize, size: usize, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
    private func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }

    func data(_ name: String) -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else { return nil }
        let h = e.localOffset
        guard h + 30 <= bytes.count, u32(h) == 0x04034b50 else { return nil }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressed <= bytes.count else { return nil }
        let raw = bytes[start..<(start + e.compressed)]
        switch e.method {
        case 0: return Data(raw)
        case 8:
            guard e.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            let written = raw.withUnsafeBufferPointer { src in
                compression_decode_buffer(&out, e.size, src.baseAddress!, e.compressed, nil, COMPRESSION_ZLIB)
            }
            return written == e.size ? Data(out) : nil
        default: return nil
        }
    }

    func text(_ name: String) -> String? { data(name).flatMap { NovelImport.decodeText($0) } }
}
