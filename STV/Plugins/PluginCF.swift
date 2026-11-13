import UIKit
import WebKit
import CryptoKit
import SwiftUI

/// Cloudflare pass for plugins. Every plugin gets its **own** persistent `WKWebsiteDataStore(forIdentifier:)`
/// (iOS 17+), so a plugin's clearance / login cookies never mix with WebKit's default store, the built-in
/// sites, or other plugins. Main-frame navigation is limited to the plugin's allow-listed domains. After a
/// pass only cookies for allow-listed domains are copied into that plugin's cookie jar.
@MainActor final class PluginCF: NSObject, WKNavigationDelegate {
    static let shared = PluginCF()
    nonisolated static let timeout: TimeInterval = 20
    private var webs: [String: WKWebView] = [:]
    private var policies: [String: DomainPolicy] = [:]
    private var inflight: [String: Task<Bool, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    static func storeID(_ pluginID: String) -> UUID {
        var b = Array(Insecure.MD5.hash(data: Data(("stv.plugin.webstore." + pluginID).utf8)))
        b[6] = (b[6] & 0x0f) | 0x30; b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func configuration(_ pluginID: String) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID(pluginID))
        let v = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        cfg.applicationNameForUserAgent = "Version/\(v) Mobile/15E148 Safari/604.1"
        return cfg
    }

    /// Deletes the plugin's WebKit data store (on uninstall / 清除数据).
    static func removeStore(_ pluginID: String) async {
        shared.webs[pluginID]?.removeFromSuperview()
        shared.webs[pluginID] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: storeID(pluginID))
    }

    // MARK: Blocking bridges for the plugin thread

    nonisolated static func solveBlocking(_ ctx: PluginHostContext, url: URL) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let id = ctx.id, policy = DomainPolicy(ctx.manifest.httpDomains + (PluginStore.snapshot(id)?.extraDomains ?? []))
        Task { @MainActor in
            let r = await shared.solve(id, policy: policy, url: url)
            box.ok = r.ok; box.ua = r.ua; box.cookies = r.cookies
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout + 8) == .success, box.ok else { return false }
        let mine = box.cookies.filter { policy.allows($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        ctx.net.jar.add(mine)
        if let ua = box.ua, !ua.isEmpty {
            ctx.learnedUA = ua
            Task { @MainActor in PluginStore.shared.setLearnedUA(id, ua) }
        }
        return true
    }

    nonisolated static func fetchBlocking(_ ctx: PluginHostContext, url: URL) -> String? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let id = ctx.id
        Task { @MainActor in box.text = await shared.fetch(id, url: url); sem.signal() }
        guard sem.wait(timeout: .now() + 25) == .success else { return nil }
        return box.text
    }

    final class ResultBox: @unchecked Sendable { var ok = false; var ua: String?; var cookies: [HTTPCookie] = []; var text: String? }

    // MARK: Hidden web view

    private func webView(_ pluginID: String) -> WKWebView {
        if let w = webs[pluginID] { return w }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        let w = WKWebView(frame: window?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844), configuration: Self.configuration(pluginID))
        w.navigationDelegate = self
        w.alpha = 0.02
        w.isUserInteractionEnabled = false
        window?.insertSubview(w, at: 0)
        webs[pluginID] = w
        return w
    }

    func solve(_ pluginID: String, policy: DomainPolicy, url: URL) async -> (ok: Bool, ua: String?, cookies: [HTTPCookie]) {
        guard let host = url.host, policy.allows(host) else { return (false, nil, []) }
        policies[pluginID] = policy
        if let f = failedAt[pluginID], Date().timeIntervalSince(f) < 30 { return (false, nil, []) }
        if let t = inflight[pluginID] { _ = await t.value }
        let wv = webView(pluginID)
        let t = Task<Bool, Never> { @MainActor in
            wv.load(URLRequest(url: url))
            let start = Date()
            while Date().timeIntervalSince(start) < Self.timeout {
                try? await Task.sleep(for: .milliseconds(600))
                guard let snap = await CFSolver.shared.snapshot(wv) else { continue }
                let v = CFDetect.verdict(title: snap.title, domChallenge: snap.domChallenge, cookies: snap.cookies, host: host, elapsed: Date().timeIntervalSince(start))
                if v != .waiting { return true }
            }
            return false
        }
        inflight[pluginID] = t
        let ok = await t.value
        inflight[pluginID] = nil
        if !ok { failedAt[pluginID] = Date(); PluginLog.add(pluginID, "☁︎ 后台验证超时，需要手动「去验证」"); return (false, nil, []) }
        failedAt[pluginID] = nil
        let ua = (try? await wv.evaluateJavaScript("navigator.userAgent")) as? String
        let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookies()
        PluginLog.add(pluginID, "☁︎ 后台验证通过 · 同步 \(cookies.count) 个 cookie")
        return (true, ua, cookies)
    }

    func fetch(_ pluginID: String, url: URL) async -> String? {
        guard let wv = webs[pluginID], let host = url.host, policies[pluginID]?.allows(host) == true else { return nil }
        if wv.url?.host != host {
            wv.load(URLRequest(url: url))
            for _ in 0..<20 where wv.isLoading { try? await Task.sleep(for: .milliseconds(300)) }
        }
        let js = "const r = await fetch(u, {credentials: 'include'}); return await r.text();"
        return try? await wv.callAsyncJavaScript(js, arguments: ["u": url.absoluteString], in: nil, contentWorld: .page) as? String
    }

    /// Main frame may only go to allow-listed hosts; Cloudflare's challenge iframe is allowed as a sub-frame.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await MainActor.run {
            guard let u = action.request.url, let host = u.host else { return action.request.url?.scheme == "about" ? .allow : .cancel }
            guard u.scheme == "https" || u.scheme == "http" else { return .cancel }
            if action.targetFrame?.isMainFrame == false { return .allow }
            let pid = webs.first { $0.value === webView }?.key
            return pid.flatMap { policies[$0] }?.allows(host) == true ? .allow : .cancel
        }
    }
}

/// Visible verification / login page for one plugin (its own data store; same allow-list rule).
struct PluginVerifySheet: View {
    let pluginID: String
    let url: URL
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PluginWebView(pluginID: pluginID, url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.host ?? "验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            Task {
                                await PluginStore.shared.importWebCookies(pluginID)
                                onDone(); dismiss()
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                }
        }
    }
}

struct PluginWebView: UIViewRepresentable {
    let pluginID: String
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(policy: DomainPolicy((PluginStore.snapshot(pluginID)?.manifest.httpDomains ?? []) + (PluginStore.snapshot(pluginID)?.extraDomains ?? []))) }
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: PluginCF.configuration(pluginID))
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let policy: DomainPolicy
        init(policy: DomainPolicy) { self.policy = policy }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let u = action.request.url, let host = u.host else { return .allow }
            if action.targetFrame?.isMainFrame == false { return .allow }
            return policy.allows(host) ? .allow : .cancel
        }
    }
}
