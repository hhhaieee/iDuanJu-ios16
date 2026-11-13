import SwiftUI
import WebKit

/// N9 站点验证 — hosts the site in a WKWebView so the user can pass the Cloudflare check once.
/// On pass: cookies (incl. `cf_clearance`) are copied into the URLSession jar, the WebView's real UA is
/// stored for that source, the app re-checks with its own HTTP stack, and only then retries.
struct VerifyTarget: Identifiable, Hashable {
    let source: DramaSource
    let url: String
    var id: String { url }
}

struct SiteVerifySheet: View {
    let target: VerifyTarget
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = "请在下方页面完成验证，通过后会自动关闭"
    @State private var passed = false
    @State private var busy = false
    @State private var opened = Date()
    @State private var last: VerifySnapshot?
    /// cf_clearance value that already failed the in-app re-check; wait for a new one before retrying.
    @State private var rejectedClearance: String?

    private var host: String { URL(string: target.url)?.host ?? "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: passed ? "checkmark.seal.fill" : "shield.lefthalf.filled")
                        .foregroundStyle(passed ? STVTheme.accent : STVTheme.accentWarm)
                    Text(status).font(.footnote).foregroundStyle(STVTheme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(STVTheme.surface)
                VerifyWebView(url: URL(string: target.url)) { snap in handle(snap) }
            }
            .navigationTitle("\(target.source.label) 站点验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Task { await finish(last, force: true) } }.disabled(busy)
                }
            }
        }
        .presentationBackground(STVTheme.bg)
        .onAppear { SiteLog.add("[\(target.source.label)] 打开验证页 \(target.url)") }
    }

    private func clearance(_ s: VerifySnapshot?) -> String? {
        s?.cookies.first { $0.name == "cf_clearance" && CFCookies.domain($0.domain, matches: host) }?.value
    }

    private func handle(_ snap: VerifySnapshot) {
        last = snap
        guard !passed, !busy else { return }
        let v = CFDetect.verdict(title: snap.title, domChallenge: snap.domChallenge, cookies: snap.cookies,
                                 host: host, elapsed: Date().timeIntervalSince(opened))
        guard v != .waiting else { return }
        if let bad = rejectedClearance, clearance(snap) == bad { return }
        Task { await finish(snap, force: false) }
    }

    /// Sync cookies + UA into the app's HTTP stack *before* dismissing, re-check with URLSession,
    /// then retry the original request.
    private func finish(_ snap: VerifySnapshot?, force: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let src = target.source
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let synced = CFCookies.sync(cookies)
        if let ua = snap?.ua, !ua.isEmpty { SiteUA.set(ua, for: src) }
        let hasClearance = cookies.contains { $0.name == "cf_clearance" && CFCookies.domain($0.domain, matches: host) }
        SiteLog.add("[\(src.label)] 验证页结束（\(force ? "手动完成" : "自动判定")）title=\(snap?.title ?? "-") · 同步 \(synced.count) 个 cookie · cf_clearance=\(hasClearance ? "有" : "无") · UA \(SiteLog.shortUA(src.userAgent))")
        CFSolver.shared.resetCooldown()
        await SiteHTTP.shared.clearPreferred()
        if src == .missav { await MissAVSite.shared.reset() }
        status = "正在用 App 网络复核…"
        let ok = await Self.recheck(target)
        if ok || force {
            passed = true
            status = ok ? "验证通过，正在返回…" : "已同步 Cookie，返回后重试"
            try? await Task.sleep(for: .milliseconds(400))
            dismiss(); onDone()
        } else {
            rejectedClearance = clearance(snap) ?? ""
            status = "页面已通过，但 App 请求仍被拦截（已写入诊断日志）。可在页面里刷新后再试，或点「完成」强制返回"
        }
    }

    /// One request with the app's own URLSession (same jar + learned UA) to confirm the clearance works.
    static func recheck(_ target: VerifyTarget) async -> Bool {
        let base = URL(string: target.url).map { "\($0.scheme ?? "https")://\($0.host ?? "")" } ?? ""
        do {
            let (text, status, hdrs) = try await SiteHTTP.shared.raw(target.url, referer: base + "/",
                                                                      headers: ["User-Agent": target.source.userAgent])
            let blocked = CFDetect.isChallenge(status: status, headers: hdrs, body: text)
            SiteLog.add("[\(target.source.label)] App 复核 \(status) \(blocked ? "仍是 Cloudflare" : "OK") · cookies \(CFCookies.names(for: target.url).joined(separator: ","))")
            return !blocked && status < 400
        } catch {
            SiteLog.add("[\(target.source.label)] App 复核失败 \(error.localizedDescription)")
            return false
        }
    }
}

struct VerifySnapshot {
    var title: String
    var ua: String
    var href: String
    var domChallenge: Bool
    var cookies: [HTTPCookie]
}

extension CFCookies {
    /// Cold start: re-copy site cookies the WebView store kept (it persists independently of HTTPCookieStorage).
    @MainActor static func restoreFromWebKit() async {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let n = sync(all).count
        if n > 0 { SiteLog.add("启动时从 WebKit 恢复 \(n) 个站点 cookie") }
    }

    /// 清除站点验证 Cookie: both jars + learned UAs.
    @MainActor static func clearAll() async {
        for c in HTTPCookieStorage.shared.cookies ?? [] where isSiteCookie(c) { HTTPCookieStorage.shared.deleteCookie(c) }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() where isSiteCookie(c) { await store.deleteCookie(c) }
        for s in Sites.all { SiteUA.clear(s) }
        await SiteHTTP.shared.clearPreferred()
        await MissAVSite.shared.reset()
        SiteLog.add("已清除站点 cookie 与 UA")
    }
}

private struct VerifyWebView: UIViewRepresentable {
    let url: URL?
    /// Snapshot after each navigation and every second while open.
    let onCheck: @MainActor (VerifySnapshot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCheck: onCheck) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = CFSolver.configuration()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = UIColor(STVTheme.bg)
        if let url { wv.load(URLRequest(url: url)) }
        context.coordinator.start(wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let onCheck: @MainActor (VerifySnapshot) -> Void
        private var timer: Timer?
        private weak var web: WKWebView?
        private var finishedOnce = false
        init(onCheck: @escaping @MainActor (VerifySnapshot) -> Void) { self.onCheck = onCheck }

        func start(_ wv: WKWebView) {
            web = wv
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
        }
        func stop() { timer?.invalidate(); timer = nil }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.finishedOnce = true; self.check() }
        }

        private func check() {
            guard finishedOnce, let wv = web else { return }
            wv.evaluateJavaScript(CFSolver.probeJS) { [weak self] r, _ in
                let j = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let snap = VerifySnapshot(title: j["t"] as? String ?? "", ua: j["ua"] as? String ?? "",
                                              href: j["href"] as? String ?? "", domChallenge: j["c"] as? Bool ?? true,
                                              cookies: cookies)
                    Task { @MainActor in self?.onCheck(snap) }
                }
            }
        }
    }
}

extension Error {
    /// Non-nil when the failure is a site interstitial the user can clear in `SiteVerifySheet`.
    var verifyTarget: VerifyTarget? {
        (self as? SiteError)?.verification.map { VerifyTarget(source: $0.0, url: $0.1) }
    }
}
