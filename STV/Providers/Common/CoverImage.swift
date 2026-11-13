import Foundation
import UIKit
import CommonCrypto
import SwiftUI

/// How a remote cover must be decoded before UIImage can show it.
enum CoverKind {
    case plain
    /// Huangguo AI CDN (pic.drleao.cn): whole body is AES-128-CBC ciphertext (no padding).
    case aiAES
    /// Huangguo legacy/cloudfront CDN: first 100 bytes XOR with repeating "2019ysapp7527".
    case legacyXOR
}

enum CoverCrypto {
    /// From AI site crypto-worker.js media_key / media_iv (ASCII digits→chars).
    static let aiKey = Array("f5d965df75336270".utf8)
    static let aiIV  = Array("97b60394abc2fbe1".utf8)
    /// From legacy frontend ue.imgKey.
    static let xorKey = Array("2019ysapp7527".utf8)

    static func kind(for url: String) -> CoverKind {
        let l = url.lowercased()
        if l.contains("pic.drleao.cn") || l.contains("drleao.") { return .aiAES }
        if l.contains("lkkwip.cn") || l.contains("/cf") && l.contains("/image/") { return .legacyXOR }
        // Relative legacy paths are absolutized before fetch; treat bare cf* as XOR.
        if url.hasPrefix("cf") || url.hasPrefix("hc") { return .legacyXOR }
        return .plain
    }

    static func decrypt(_ data: Data, kind: CoverKind) throws -> Data {
        switch kind {
        case .plain: return data
        case .aiAES:
            guard data.count >= 16, data.count % 16 == 0 else { throw ProviderError.invalid("AI cover length") }
            var out = [UInt8](repeating: 0, count: data.count)
            var moved = 0
            let st = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                             aiKey, aiKey.count, aiIV, [UInt8](data), data.count, &out, out.count, &moved)
            guard st == kCCSuccess else { throw ProviderError.invalid("AI cover AES \(st)") }
            return Data(out[0..<moved])
        case .legacyXOR:
            var b = [UInt8](data)
            let n = min(100, b.count)
            for i in 0..<n { b[i] ^= xorKey[i % xorKey.count] }
            return Data(b)
        }
    }
}

/// Disk+memory cache of decrypted cover images. Shared by all poster views.
actor CoverStore {
    static let shared = CoverStore()
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()
    private var inflight: [String: Task<UIImage, Error>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
        return URLSession(configuration: c)
    }()

    private var diskDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stv-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func image(url raw: String, headers: [String: String] = [:]) async throws -> UIImage {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if url.hasPrefix("fixture://"), let v = UInt32(url.dropFirst("fixture://".count).prefix(6), radix: 16) {
            let c = UIColor(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
            return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { ctx in c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180)) }
        }
        #endif
        if url.hasPrefix("tdfile://") {
            // Telegram media read through TDLib (restricted / private channels): downloadFile → local path.
            if let img = memory.object(forKey: url as NSString) { return img }
            let local = try await TDLibService.shared.file(url)
            guard let img = UIImage(contentsOfFile: local.path) else { throw ProviderError.invalid("tdfile not an image") }
            cache(img, url: url)
            return img
        }
        if url.hasPrefix("file://"), let u = URL(string: url) {
            // Downloaded Telegram photos / offline manga pages.
            guard let img = UIImage(contentsOfFile: u.path) else { throw ProviderError.invalid("local image missing") }
            return img
        }
        if url.hasPrefix(PluginMedia.scheme) {
            // Plugin images: allow-list + per-plugin cookies + native transforms (PluginMedia).
            if let img = memory.object(forKey: url as NSString) { return img }
            let disk = diskDir.appendingPathComponent(Bytes.hex(Bytes.md5(url)) + ".img")
            if let d = try? Data(contentsOf: disk), let img = UIImage(data: d) { cache(img, url: url); return img }
            if let t = inflight[url] { return try await t.value }
            let task = Task<UIImage, Error> {
                let data = try await PluginMedia.load(url)
                guard let img = UIImage(data: data) else { throw ProviderError.invalid("插件图片无法解码") }
                try? data.write(to: disk, options: .atomic)
                return img
            }
            inflight[url] = task
            defer { inflight[url] = nil }
            let img = try await task.value
            cache(img, url: url)
            return img
        }
        guard !url.isEmpty, var u = URL(string: url), u.scheme == "http" || u.scheme == "https" else {
            throw ProviderError.invalid("empty cover")
        }
        // ATS: hongguo CDNs (fqnovelpic / douyinpic …) serve the same object over https.
        if u.scheme == "http", let h = u.host, h.hasSuffix("fqnovelpic.com") || h.hasSuffix("douyinpic.com") || h.hasSuffix("byteimg.com"),
           let up = URL(string: "https" + url.dropFirst(4)) { u = up }
        if let img = memory.object(forKey: url as NSString) { return img }
        let key = Bytes.hex(Bytes.md5(url))
        let disk = diskDir.appendingPathComponent(key + ".img")
        if let d = try? Data(contentsOf: disk), let img = UIImage(data: d) {
            cache(img, url: url)
            return img
        }
        if let t = inflight[url] { return try await t.value }
        let task = Task<UIImage, Error> {
            var req = URLRequest(url: u)
            req.setValue(HuangguoClient.userAgent, forHTTPHeaderField: "User-Agent")
            var hdrs = CoverHeaders.for(url: url).merging(headers) { _, given in given }
            if CoverCrypto.kind(for: url) == .legacyXOR {
                hdrs["Referer"] = hdrs["Referer"] ?? HuangguoClient.frontendURL + "/"
                hdrs["Origin"] = hdrs["Origin"] ?? HuangguoClient.frontendURL
            }
            for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), !data.isEmpty else { throw ProviderError.upstream(data.isEmpty && code == 200 ? "cover empty body" : "cover HTTP \(code)") }
            let plain = try CoverCrypto.decrypt(data, kind: CoverCrypto.kind(for: url))
            guard let img = UIImage(data: plain) else { throw ProviderError.invalid("cover not an image") }
            try? plain.write(to: disk, options: .atomic)
            return img
        }
        inflight[url] = task
        defer { inflight[url] = nil }
        let img = try await task.value
        cache(img, url: url)
        return img
    }

    private func cache(_ image: UIImage, url: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: url as NSString, cost: cost)
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }
}

/// SwiftUI cover that decrypts AI AES / legacy XOR when needed, with shimmer placeholder.
struct CoverView: View {
    let url: String
    var headers: [String: String] = [:]
    var corner: CGFloat = 14
    /// Tried when `url` is empty or fails (e.g. detail-page cover dead → list-card cover).
    var fallback: String? = nil
    /// When set, the cover is one accessibility element with this id and value loaded / failed / loading.
    var a11yID: String? = nil
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    // scaledToFill overflows its frame; .clipped() only clips drawing, so without
                    // .contentShape the invisible overflow kept receiving touches (1.2b4: the hero
                    // backdrop's overflow sat on top of the search bar / channel row).
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                } else if failed {
                    LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.25))
                } else {
                    ShimmerBlock()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .modifier(CoverA11y(id: a11yID, state: image != nil ? "loaded" : failed ? "failed" : "loading"))
        .task(id: url + "|" + (fallback ?? "")) {
            image = nil; failed = false
            var tried = Set<String>()
            for u in [url, fallback ?? ""] where !u.isEmpty && tried.insert(u).inserted {
                do {
                    let loaded = try await CoverStore.shared.image(url: u, headers: headers)
                    try Task.checkCancellation()
                    image = loaded
                    #if DEBUG
                    if u != url { print("[STV] cover fallback used: \(url.prefix(80)) → \(u.prefix(80))") }
                    #endif
                    return
                } catch { if Task.isCancelled { return } }
            }
            failed = true
        }
    }
}

private struct CoverA11y: ViewModifier {
    let id: String?
    let state: String
    func body(content: Content) -> some View {
        if let id { content.accessibilityElement(children: .ignore).accessibilityIdentifier(id).accessibilityValue(state) }
        else { content }
    }
}

struct ShimmerBlock: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase * 200)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

/// Extra request headers some cover CDNs need (hotlink protection). Filled from live probes.
enum CoverHeaders {
    /// Host suffix → Referer. Live probe 2026-11: pix-cdn77.phncdn.com answers 403 without the
    /// pornhub Referer (pix-fl / ei don't care); the others are hotlink-protected CDNs where sending
    /// the site's own Referer is what a browser does anyway.
    static let referers: [(String, String)] = [
        ("phncdn.com", "https://www.pornhub.com/"),
        ("xvideos-cdn.com", "https://www.xvideos.com/"),
        ("xnxx-cdn.com", "https://www.xnxx.com/"),
        ("hembed.com", "https://hanime1.me/"),
        ("jable.tv", "https://jable.tv/"),
        ("mrstcdn.store", "https://missav.ws/"),
        ("fourhoi.com", "https://missav.ws/"),
        ("supjav.com", "https://supjav.com/"),
        ("eporner.com", "https://www.eporner.com/"),
    ]
    static func `for`(url: String) -> [String: String] {
        guard let h = URL(string: url)?.host?.lowercased() else { return [:] }
        for (suffix, ref) in referers where h == suffix || h.hasSuffix("." + suffix) { return ["Referer": ref] }
        return [:]
    }
}

/// Which cover the detail hero shows: the detail page's own cover, else the list card's.
enum DetailCover {
    static func pick(detail: String, list: String) -> String {
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? list : d
    }
}
