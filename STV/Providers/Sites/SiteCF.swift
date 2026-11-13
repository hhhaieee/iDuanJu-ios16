import Foundation
import os

// Cloudflare plumbing shared by every CloudflareGate source (Jable / MissAV / Hanime1 / SupJav):
// challenge detection, "did the user really pass" verdict, WebKit → URLSession cookie sync,
// the WebView's real User-Agent (cf_clearance is bound to it) and an in-app diagnostic log.

extension DramaSource {
    /// Every host this source may talk to (mirrors), used for cookie sync / clearing.
    var siteHosts: [String] {
        let mirrors: [String] = switch self {
        case .jable: JableProvider.mirrors
        case .missav: MissAVProvider.mirrors
        case .hanime1: Hanime1Provider.mirrors
        case .supjav: SupJavProvider.mirrors
        case .eporner: EpornerProvider.mirrors
        case .xvideos: XVProvider.xvMirrors
        case .xnxx: XVProvider.xnMirrors
        case .pornhub: PornhubProvider.mirrors
        case .telegram: [TGClient.defaultBase]
        default: []
        }
        return mirrors.compactMap { URL(string: $0)?.host }
    }

    /// Source whose mirrors include `host` (or a subdomain of one).
    static func site(forHost host: String) -> DramaSource? {
        Sites.all.first { s in s.siteHosts.contains { CFCookies.domain($0, matches: host) } }
    }
}

/// UA learned from the verify WebView (`navigator.userAgent`), persisted per source.
/// Cloudflare binds `cf_clearance` to the UA that solved the challenge, so every later request
/// for that source (pages, probes, HLS headers) must send exactly this string.
enum SiteUA {
    private static func key(_ s: DramaSource) -> String { "stv.site.ua." + s.rawValue }
    static func learned(_ s: DramaSource, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(s)).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func set(_ ua: String, for s: DramaSource, defaults: UserDefaults = .standard) {
        guard !ua.isEmpty else { return }
        defaults.set(ua, forKey: key(s))
    }
    static func clear(_ s: DramaSource, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(s)) }
}

/// Challenge detection. Real pages on these sites embed `/cdn-cgi/challenge-platform/` near the end,
/// and the interstitial title is localized ("请稍候…" on a Chinese iPhone), so neither alone is enough.
enum CFDetect {
    static let challengeTitles = ["just a moment", "请稍候", "請稍候", "attention required", "please wait",
                                  "un instant", "einen moment", "しばらくお待ちください", "잠시만 기다리"]

    static func title(_ html: String) -> String {
        HTML.groups("<title[^>]*>([^<]*)</title>", String(html.prefix(20_000))).map { HTML.cleanText($0[1]) } ?? ""
    }

    static func isChallengeTitle(_ t: String) -> Bool {
        let l = t.lowercased()
        return challengeTitles.contains { l.contains($0) }
    }

    /// True for a Cloudflare interstitial / managed challenge, false for real content (even if it embeds CF scripts).
    static func isChallenge(status: Int, headers: [AnyHashable: Any], body: String) -> Bool {
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name }.map { "\($0.value)".lowercased() }
        }
        if header("cf-mitigated") == "challenge" { return true }
        let head = String(body.prefix(8000)).lowercased()
        if isChallengeTitle(title(body)) { return true }
        if head.contains("window._cf_chl_opt") || head.contains("cf_chl_opt") || head.contains("id=\"challenge-form\"")
            || head.contains("cf-browser-verification") || head.contains("id=\"challenge-stage\"") { return true }
        let cfServer = header("server")?.contains("cloudflare") ?? false
        if (status == 403 || status == 503), cfServer || head.contains("cloudflare") {
            // 403 with real cards is a soft block we can still parse; otherwise needs the browser.
            return body.count < 30_000 || head.contains("challenge-platform")
        }
        return false
    }

    enum Verdict: Equatable { case waiting, passed, passedWithoutClearance }

    /// Whether the verify WebView has really cleared the check for `host`.
    /// `domChallenge` = the page still has challenge DOM (`_cf_chl_opt`, `#challenge-form`, Turnstile widget).
    static func verdict(title: String, domChallenge: Bool, cookies: [HTTPCookie], host: String, elapsed: TimeInterval) -> Verdict {
        if title.trimmingCharacters(in: .whitespaces).isEmpty || isChallengeTitle(title) || domChallenge { return .waiting }
        if cookies.contains(where: { $0.name == "cf_clearance" && CFCookies.domain($0.domain, matches: host) }) { return .passed }
        // Some mirrors never challenge the WebView (only URLSession); give cookies a moment to land, then accept.
        return elapsed >= 4 ? .passedWithoutClearance : .waiting
    }
}

enum CFCookies {
    /// RFC 6265 domain match: cookie domain ".missav.ws" / "missav.ws" matches "missav.ws" and "www.missav.ws".
    static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let d = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let h = host.lowercased()
        return !d.isEmpty && (h == d || h.hasSuffix("." + d))
    }

    static func isSiteCookie(_ c: HTTPCookie) -> Bool {
        Sites.all.contains { s in s.siteHosts.contains { domain(c.domain, matches: $0) || domain($0, matches: c.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) } }
    }

    /// Copy WebKit cookies into the URLSession jar (all site cookies, not just the verified host,
    /// because the challenge may set them on the apex while requests go to `www.`/another path).
    @discardableResult
    static func sync(_ cookies: [HTTPCookie], host: String? = nil, into storage: HTTPCookieStorage = .shared) -> [HTTPCookie] {
        let mine = cookies.filter { c in isSiteCookie(c) || host.map { h in domain(c.domain, matches: h) } == true }
            .map(unpartitioned)
        for c in mine { storage.setCookie(c) }
        return mine
    }

    /// Cloudflare now sets `cf_clearance` as a CHIPS *partitioned* cookie. WebKit hands it over with a
    /// `StoragePartition` property; HTTPCookieStorage stores it but never returns it from `cookies(for:)`,
    /// so URLSession requests silently went out without it. Re-create the cookie without the partition.
    static func unpartitioned(_ c: HTTPCookie) -> HTTPCookie {
        guard var props = c.properties, props.keys.contains(where: { $0.rawValue == "StoragePartition" }) else { return c }
        props.removeValue(forKey: HTTPCookiePropertyKey("StoragePartition"))
        return HTTPCookie(properties: props) ?? c
    }

    /// Cookie names the jar would send to `url` (for the diagnostic log; values never logged).
    static func names(for url: String, storage: HTTPCookieStorage = .shared) -> [String] {
        guard let u = URL(string: url) else { return [] }
        return (storage.cookies(for: u) ?? []).map(\.name).sorted()
    }
}

/// Ring-buffer log for site/CF events, visible in 我的 → 片源管理 → 站点诊断日志 (also os_log category "sites").
enum SiteLog {
    private static let lock = NSLock()
    private static var lines: [String] = load()
    private static let logger = Logger(subsystem: "com.local.STV", category: "sites")
    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("site-log.txt")
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    static func add(_ s: String) {
        let line = stamp.string(from: Date()) + "  " + s
        logger.info("\(line, privacy: .public)")
        lock.lock()
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        let snapshot = lines
        lock.unlock()
        if let file { try? snapshot.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8) }
    }

    static func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }

    static func clear() {
        lock.lock(); lines = []; lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private static func load() -> [String] {
        guard let file, let s = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    static func shortUA(_ ua: String) -> String {
        HTML.groups("\\(([^)]*)\\)", ua).map { "(" + $0[1] + ")" + (ua.contains("Version/") ? " " + (HTML.groups("(Version/[0-9.]+)", ua)?[1] ?? "") : "") } ?? String(ua.prefix(40))
    }
}
