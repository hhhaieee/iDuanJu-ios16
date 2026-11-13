import UIKit
import CoreText
import Combine

/// Reader typefaces. 苹方 ships with iOS; 宋体 / 楷体 / 圆体 are Apple's downloadable system fonts;
/// 霞鹜文楷 (Lite) / 思源宋体 / 思源黑体 (all SIL OFL 1.1) are downloaded on first use from the projects' GitHub
/// repositories — through jsDelivr first (reachable and fast in mainland China), GitHub as the fallback —
/// and registered for this process only.
@MainActor
final class NovelFonts: ObservableObject {
    static let shared = NovelFonts()

    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable {
            case system
            case installed(String)
            case apple(String)
            /// "owner/repo@tag/path/in/repo"
            case remote(String)
        }
        var id: String
        var name: String
        var kind: Kind
        var bytes: Int = 0
        var note: String = ""

        var mirrors: [URL] {
            guard case .remote(let spec) = kind, let at = spec.firstIndex(of: "@") else { return [] }
            let repo = spec[..<at]
            let rest = spec[spec.index(after: at)...]
            guard let slash = rest.firstIndex(of: "/") else { return [] }
            let tag = rest[..<slash], path = rest[rest.index(after: slash)...]
            return ["https://fastly.jsdelivr.net/gh/\(spec)", "https://cdn.jsdelivr.net/gh/\(spec)", "https://github.com/\(repo)/raw/\(tag)/\(path)"]
                .compactMap(URL.init(string:))
        }
    }

    static let all: [Entry] = [
        Entry(id: "system", name: "苹方", kind: .system, note: "系统默认"),
        Entry(id: "songti", name: "宋体", kind: .apple("STSongti-SC-Regular"), note: "系统字体 · 首次使用由系统下载"),
        Entry(id: "kaiti", name: "楷体", kind: .apple("STKaitiSC-Regular"), note: "系统字体 · 首次使用由系统下载"),
        Entry(id: "yuanti", name: "圆体", kind: .apple("STYuanti-SC-Regular"), note: "系统字体 · 首次使用由系统下载"),
        Entry(id: "wenkai", name: "霞鹜文楷", kind: .remote("lxgw/LxgwWenKai-Lite@v1.530/fonts/TTF/LXGWWenKaiLite-Regular.ttf"),
            bytes: 13_949_472, note: "SIL OFL 1.1 · lxgw/LxgwWenKai-Lite"),
        Entry(id: "sourceserif", name: "思源宋体", kind: .remote("adobe-fonts/source-han-serif@2.003R/SubsetOTF/CN/SourceHanSerifCN-Regular.otf"),
            bytes: 11_626_108, note: "SIL OFL 1.1 · Adobe"),
        Entry(id: "sourcesans", name: "思源黑体", kind: .remote("adobe-fonts/source-han-sans@2.005R/SubsetOTF/CN/SourceHanSansCN-Regular.otf"),
            bytes: 8_429_224, note: "SIL OFL 1.1 · Adobe"),
    ]

    /// 0…1 while downloading, keyed by font id.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// Bumped when a font becomes available so pages re-render.
    @Published private(set) var revision = 0
    @Published private var registered: Set<String> = []

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NovelFonts", isDirectory: true)
    }
    nonisolated static func file(_ e: Entry) -> URL? {
        guard case .remote(let spec) = e.kind else { return nil }
        return dir.appendingPathComponent((spec as NSString).lastPathComponent)
    }
    /// PostScript name read from the downloaded file.
    nonisolated static func storedName(_ id: String) -> String? { UserDefaults.standard.string(forKey: "stv.novel.font.ps." + id) }

    nonisolated static func postScriptName(_ e: Entry) -> String? {
        switch e.kind {
        case .system: nil
        case .installed(let ps), .apple(let ps): ps
        case .remote: storedName(e.id)
        }
    }

    func isReady(_ id: String) -> Bool {
        guard let e = Self.all.first(where: { $0.id == id }) else { return false }
        switch e.kind {
        case .system: return true
        case .installed(let ps), .apple(let ps): return UIFont(name: ps, size: 12) != nil
        case .remote:
            if let ps = Self.storedName(id), UIFont(name: ps, size: 12) != nil { return true }
            return register(e)
        }
    }

    @discardableResult private func register(_ e: Entry) -> Bool {
        guard let f = Self.file(e), FileManager.default.fileExists(atPath: f.path) else { return false }
        let names = (CTFontManagerCreateFontDescriptorsFromURL(f as CFURL) as? [CTFontDescriptor] ?? [])
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        guard let ps = names.first else { return false }
        UserDefaults.standard.set(ps, forKey: "stv.novel.font.ps." + e.id)
        if !registered.contains(e.id) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            registered.insert(e.id)
        }
        return UIFont(name: ps, size: 12) != nil
    }

    /// Makes the font available (download / system asset).
    func fetch(_ id: String) {
        guard let e = Self.all.first(where: { $0.id == id }), !isReady(id), progress[id] == nil else { return }
        errors[id] = nil
        progress[id] = 0
        switch e.kind {
        case .apple(let ps):
            let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: ps] as CFDictionary)
            CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, info in
                let p = (info as NSDictionary)[kCTFontDescriptorMatchingPercentage] as? Double
                let failed = state == .didFailWithError
                let done = state == .didFinish
                Task { @MainActor in
                    if let p { self.progress[id] = p / 100 }
                    if failed { self.progress[id] = nil; self.errors[id] = "系统字体下载失败" }
                    if done { self.progress[id] = nil; self.revision += 1 }
                }
                return true
            }
        case .remote:
            Task { await download(e) }
        default:
            progress[id] = nil
        }
    }

    /// Tries each mirror in turn; a mirror that sends nothing for 20 s is abandoned.
    private func download(_ e: Entry) async {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg)
        var last = "下载失败"
        for url in e.mirrors {
            do {
                let (tmp, resp) = try await session.download(from: url, delegate: ProgressDelegate { [id = e.id] p in
                        Task { @MainActor in if self.progress[id] != nil { self.progress[id] = p } }
                })
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { last = "下载失败（\(url.host ?? "")）"; continue }
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                let dest = Self.file(e)!
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                progress[e.id] = nil
                if register(e) { revision += 1 } else { errors[e.id] = "字体文件无效"; try? FileManager.default.removeItem(at: dest) }
                return
            } catch {
                last = "下载失败：\(error.localizedDescription)"
            }
        }
        progress[e.id] = nil
        errors[e.id] = last
    }

    func delete(_ id: String) {
        guard let e = Self.all.first(where: { $0.id == id }), let f = Self.file(e) else { return }
        if registered.contains(id) { CTFontManagerUnregisterFontsForURL(f as CFURL, .process, nil); registered.remove(id) }
        try? FileManager.default.removeItem(at: f)
        UserDefaults.standard.removeObject(forKey: "stv.novel.font.ps." + id)
        revision += 1
    }

    func downloaded(_ id: String) -> Bool {
        guard let e = Self.all.first(where: { $0.id == id }), let f = Self.file(e) else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    /// The UIFont for a reader font id (falls back to 苹方 until the font is available).
    nonisolated static func font(_ id: String, size: CGFloat, bold: Bool = false) -> UIFont {
        if let e = all.first(where: { $0.id == id }), let ps = postScriptName(e) {
            if bold, ps == "STSongti-SC-Regular", let f = UIFont(name: "STSongti-SC-Bold", size: size) { return f }
            if let f = UIFont(name: ps, size: size) {
                guard bold, let d = f.fontDescriptor.withSymbolicTraits(.traitBold) else { return f }
                return UIFont(descriptor: d, size: size)
            }
        }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ f: @escaping @Sendable (Double) -> Void) { onProgress = f }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in onProgress(p.fractionCompleted) }
    }
}
