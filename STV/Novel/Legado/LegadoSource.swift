import Foundation
import Combine

/// One 「阅读」(Legado) book source. Decoded leniently: rule values may be strings, numbers or nested JSON
/// (we keep them as strings); unknown keys are ignored. Only text sources (bookSourceType 0) are supported.
struct LegadoSource: Codable, Hashable, Identifiable {
    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?
    var bookSourceComment: String?
    var enabled: Bool?
    var header: String?
    var searchUrl: String?
    var exploreUrl: String?
    var loginUrl: String?
    var loginUi: String?
    var jsLib: String?
    var ruleSearch: [String: String]?
    var ruleBookInfo: [String: String]?
    var ruleToc: [String: String]?
    var ruleContent: [String: String]?
    var customOrder: Int?

    var id: String { bookSourceUrl }
    var isOn: Bool { enabled ?? true }
    var hasLogin: Bool { !(loginUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var supported: Bool { (bookSourceType ?? 0) == 0 && !(searchUrl ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookSourceComment, enabled, header, searchUrl,
        exploreUrl, loginUrl, loginUi, jsLib, ruleSearch, ruleBookInfo, ruleToc, ruleContent, customOrder
    }

    init(bookSourceUrl: String, bookSourceName: String, searchUrl: String?, ruleSearch: [String: String]? = nil,
        ruleBookInfo: [String: String]? = nil, ruleToc: [String: String]? = nil, ruleContent: [String: String]? = nil,
        header: String? = nil) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.searchUrl = searchUrl
        self.ruleSearch = ruleSearch
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
        self.header = header
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bookSourceUrl = try c.decode(String.self, forKey: .bookSourceUrl)
        bookSourceName = (try? c.decode(String.self, forKey: .bookSourceName)) ?? bookSourceUrl
        bookSourceGroup = Self.str(c, .bookSourceGroup)
        bookSourceType = (try? c.decode(Int.self, forKey: .bookSourceType)) ?? Self.str(c, .bookSourceType).flatMap(Int.init)
        bookSourceComment = Self.str(c, .bookSourceComment)
        enabled = (try? c.decode(Bool.self, forKey: .enabled))
        header = Self.str(c, .header)
        searchUrl = Self.str(c, .searchUrl)
        exploreUrl = Self.str(c, .exploreUrl)
        loginUrl = Self.str(c, .loginUrl)
        loginUi = Self.str(c, .loginUi)
        jsLib = Self.str(c, .jsLib)
        ruleSearch = Self.rules(c, .ruleSearch)
        ruleBookInfo = Self.rules(c, .ruleBookInfo)
        ruleToc = Self.rules(c, .ruleToc)
        ruleContent = Self.rules(c, .ruleContent)
        customOrder = try? c.decode(Int.self, forKey: .customOrder)
    }

    private static func str(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: k) { return s }
        if let v = try? c.decode(LegadoAny.self, forKey: k) { return v.text }
        return nil
    }

    /// Rule objects; some exports store them as a JSON string.
    private static func rules(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> [String: String]? {
        if let m = try? c.decode([String: LegadoAny].self, forKey: k) { return m.compactMapValues { $0.text } }
        if let s = try? c.decode(String.self, forKey: k), let d = s.data(using: .utf8),
        let m = try? JSONDecoder().decode([String: LegadoAny].self, from: d) { return m.compactMapValues { $0.text } }
        return nil
    }
}

/// Any JSON value, flattened to text (strings as-is, others re-serialized).
struct LegadoAny: Codable, Hashable {
    var text: String?
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let x = try? c.decode(Double.self) { text = String(x) }
        else if c.decodeNil() { text = nil }
        else if let m = try? c.decode([String: LegadoAny].self) {
            let o = m.compactMapValues { $0.text }
            text = (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) }
        } else if let a = try? c.decode([LegadoAny].self) {
            text = (try? JSONSerialization.data(withJSONObject: a.compactMap(\.text))).map { String(decoding: $0, as: UTF8.self) }
        } else { text = nil }
    }
    func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(text) }
}

/// Installed book sources (Application Support/NovelSources.json).
@MainActor
final class LegadoSourceStore: ObservableObject {
    static let shared = LegadoSourceStore()
    @Published private(set) var sources: [LegadoSource] = []

    nonisolated static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NovelSources.json")
    }

    private init() {
        sources = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([LegadoSource].self, from: $0) } ?? []
    }

    var enabled: [LegadoSource] { sources.filter { $0.isOn && $0.supported } }
    func source(_ url: String) -> LegadoSource? { sources.first { $0.bookSourceUrl == url } }

    /// Parses a Legado export (array or single object). Returns (added or updated, skipped as unsupported).
    nonisolated static func parse(_ data: Data) throws -> [LegadoSource] {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let d = Data(trimmed.utf8)
        if trimmed.hasPrefix("[") { return try JSONDecoder().decode([LossyItem].self, from: d).compactMap(\.value) }
        return [try JSONDecoder().decode(LegadoSource.self, from: d)]
    }

    private struct LossyItem: Decodable {
        var value: LegadoSource?
        init(from d: Decoder) throws { value = try? LegadoSource(from: d) }
    }

    @discardableResult
    func add(_ list: [LegadoSource]) -> (added: Int, updated: Int, unsupported: Int) {
        var added = 0, updated = 0, unsupported = 0
        for s in list {
            if !s.supported { unsupported += 1 }
            if let i = sources.firstIndex(where: { $0.bookSourceUrl == s.bookSourceUrl }) { sources[i] = s; updated += 1 }
            else { sources.append(s); added += 1 }
        }
        save()
        return (added, updated, unsupported)
    }

    func importText(_ text: String) throws -> (added: Int, updated: Int, unsupported: Int) {
        add(try Self.parse(Data(text.utf8)))
    }

    func importURL(_ url: URL) async throws -> (added: Int, updated: Int, unsupported: Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(LegadoHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: req)
        return add(try Self.parse(d))
    }

    func setEnabled(_ s: LegadoSource, _ on: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == s.id }) else { return }
        sources[i].enabled = on
        save()
    }

    func remove(_ ids: Set<String>) {
        sources.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sources).write(to: Self.file)
    }
}
