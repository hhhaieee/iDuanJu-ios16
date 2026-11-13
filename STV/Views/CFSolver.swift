import UIKit
import WebKit

/// Silent Cloudflare pass for non-interactive JS challenges ("Just a moment…" that clears by itself):
/// load the URL in an off-screen WKWebView, poll until `cf_clearance` is set and the page is no longer a
/// challenge (≤ 20 s), then sync cookies + the WebView's real UA into the app's HTTP stack.
/// The visible `SiteVerifySheet` is only the fallback when this times out (Turnstile needing a tap etc.).
@MainActor final class CFSolver: NSObject {
    static let shared = CFSolver()
    static let timeout: TimeInterval = 20

    private var inflight: [String: Task<Bool, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    /// One web view per host, kept after solving so `fetch` can reuse its origin + cookies.
    private var webs: [String: WKWebView] = [:]

    static func install() {
        CFSolverHook.solveImpl = { s, u in await CFSolver.shared.solve(s, u) }
        CFSolverHook.fetchImpl = { s, u in await CFSolver.shared.fetch(s, u) }
    }

    /// Same configuration as the visible sheet: genuine WebKit UA + Safari tail, persistent store.
    static func configuration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        cfg.applicationNameForUserAgent = "Version/\(v) Mobile/15E148 Safari/604.1"
        return cfg
    }

    static let probeJS = """
    JSON.stringify({t: document.title || "", ua: navigator.userAgent || "", href: location.href,
      c: !!(window._cf_chl_opt || document.querySelector('#challenge-form,#challenge-stage,#challenge-running,#cf-challenge-running,.cf-turnstile,[name="cf-turnstile-response"]'))})
    """

    /// Explicit 重试 / 去验证 clears the 30 s back-off after a failed silent attempt.
    func resetCooldown() { failedAt = [:] }

    func solve(_ s: DramaSource, _ url: String) async -> Bool {
        guard let u = URL(string: url), let host = u.host else { return false }
        if let t = inflight[host] { return await t.value }
        if let f = failedAt[host], Date().timeIntervalSince(f) < 30 { return false }
        let t = Task { await self.run(s, u, host) }
        inflight[host] = t
        let ok = await t.value
        inflight[host] = nil
        if ok { failedAt[host] = nil } else { failedAt[host] = Date() }
        return ok
    }

    private func webView(for host: String) -> WKWebView {
        if let w = webs[host] { return w }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first
        // In-bounds but behind all content and nearly transparent: Cloudflare's challenge checks page
        // visibility / viewport, and WebKit throttles timers of views that are off-screen.
        let w = WKWebView(frame: window?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844), configuration: Self.configuration())
        w.alpha = 0.02
        w.isUserInteractionEnabled = false
        window?.insertSubview(w, at: 0)
        webs[host] = w
        return w
    }

    private func run(_ s: DramaSource, _ u: URL, _ host: String) async -> Bool {
        let wv = webView(for: host)
        SiteLog.add("[\(s.label)] 后台验证开始 \(u.absoluteString)")
        wv.load(URLRequest(url: u))
        let start = Date()
        while Date().timeIntervalSince(start) < Self.timeout {
            try? await Task.sleep(for: .milliseconds(600))
            guard let snap = await snapshot(wv) else { continue }
            let elapsed = Date().timeIntervalSince(start)
            let v = CFDetect.verdict(title: snap.title, domChallenge: snap.domChallenge, cookies: snap.cookies, host: host, elapsed: elapsed)
            guard v != .waiting else { continue }
            let synced = CFCookies.sync(snap.cookies, host: host)
            for c in snap.cookies where c.name == "cf_clearance" {
                let stored = (HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == c.name && $0.domain == c.domain }
                SiteLog.add("  cf_clearance domain=\(c.domain) path=\(c.path) secure=\(c.isSecure) props=\((c.properties ?? [:]).keys.map(\.rawValue).sorted().joined(separator: ",")) 入库=\(stored)")
            }
            SiteUA.set(snap.ua, for: s)
            SiteLog.add("[\(s.label)] 后台验证通过 \(String(format: "%.1f", elapsed))s · cf_clearance=\(v == .passed ? "有" : "无") · 同步 \(synced.count) 个 cookie · UA \(SiteLog.shortUA(snap.ua))")
            return true
        }
        let last = await snapshot(wv)
        SiteLog.add("[\(s.label)] 后台验证超时 \(Int(Self.timeout))s · title=\(last?.title ?? "-") · 改为弹出验证页")
        return false
    }

    func snapshot(_ wv: WKWebView) async -> VerifySnapshot? {
        guard let raw = try? await wv.evaluateJavaScript(Self.probeJS) as? String,
              let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookies()
        return VerifySnapshot(title: j["t"] as? String ?? "", ua: j["ua"] as? String ?? "", href: j["href"] as? String ?? "",
                              domChallenge: j["c"] as? Bool ?? true, cookies: cookies)
    }

    /// GET through the WebView itself (same TLS/JS fingerprint that passed the challenge).
    func fetch(_ s: DramaSource, _ url: String) async -> String? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        if webs[host] == nil { guard await solve(s, url) else { return nil } }
        guard let wv = webs[host] else { return nil }
        if wv.url?.host != host {
            wv.load(URLRequest(url: u))
            for _ in 0..<20 where wv.isLoading { try? await Task.sleep(for: .milliseconds(300)) }
        }
        let js = "const r = await fetch(u, {credentials: 'include'}); return await r.text();"
        do {
            let v = try await wv.callAsyncJavaScript(js, arguments: ["u": url], in: nil, contentWorld: .page)
            return v as? String
        } catch {
            SiteLog.add("[\(s.label)] WebView 取页面失败 \(error.localizedDescription)")
            return nil
        }
    }
}
