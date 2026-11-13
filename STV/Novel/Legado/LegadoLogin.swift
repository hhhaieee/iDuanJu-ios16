import Foundation
import UIKit
import WebKit

/// Per-source login state, like Legado: login info (the loginUi form), login header (added to every request of
/// the source) and the `cache` object (values with an optional lifetime). Persisted in UserDefaults.
enum LegadoSourceState {
    private static let lock = NSLock()
    private static let key = "stv.legado.state"
    nonisolated(unsafe) private static var mem: [String: [String: String]]?

    private static func load() -> [String: [String: String]] {
        if let m = mem { return m }
        let m = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        mem = m
        return m
    }

    static func get(_ source: String, _ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[source]?[k]
    }

    static func set(_ source: String, _ k: String, _ v: String?) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[source, default: [:]][k] = v
        mem = all
        UserDefaults.standard.set(all, forKey: key)
    }

    static func loginInfo(_ s: String) -> [String: String] {
        guard let t = get(s, "loginInfo"), let d = t.data(using: .utf8) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?.mapValues { "\($0)" } ?? [:]
    }

    static func setLoginInfo(_ s: String, _ m: [String: String]) {
        set(s, "loginInfo", (try? JSONSerialization.data(withJSONObject: m)).map { String(decoding: $0, as: UTF8.self) })
    }

    /// Login header JSON object (merged into the source's requests).
    static func loginHeader(_ s: String) -> [String: String] {
        guard let t = get(s, "loginHeader"), let d = t.data(using: .utf8) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?.mapValues { "\($0)" } ?? [:]
    }

    static func cacheGet(_ s: String, _ k: String) -> String? {
        guard let v = get(s, "cache." + k) else { return nil }
        if let exp = get(s, "cacheExp." + k).flatMap(Double.init), exp > 0, Date().timeIntervalSince1970 > exp {
            set(s, "cache." + k, nil)
            return nil
        }
        return v
    }

    static func cachePut(_ s: String, _ k: String, _ v: String?, seconds: Double) {
        set(s, "cache." + k, v)
        set(s, "cacheExp." + k, seconds > 0 ? String(Date().timeIntervalSince1970 + seconds) : nil)
    }

    static func isLoggedIn(_ s: String) -> Bool { !loginInfo(s).isEmpty || !loginHeader(s).isEmpty || get(s, "webLogin") == "1" }

    static func logout(_ s: String) {
        lock.lock()
        var all = load()
        all[s] = nil
        mem = all
        UserDefaults.standard.set(all, forKey: key)
        lock.unlock()
    }
}

/// WebKit cookies → URLSession (HTTPCookieStorage.shared), so book-source requests carry the login.
enum LegadoCookies {
    @MainActor static func syncFromWebKit() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
    }

    static func syncFromWebKitBlocking() {
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in await syncFromWebKit(); sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
    }
}

// MARK: - Browser (login pages, java.startBrowser)

/// Full-screen browser presented over whatever is on screen. `open` returns when the user taps 完成.
@MainActor
final class LegadoBrowser: NSObject, WKNavigationDelegate {
    static func open(url: URL?, html: String?, title: String, sourceURL: String?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let vc = LegadoBrowserVC(url: url, html: html, title: title) {
                Task { @MainActor in
                    await LegadoCookies.syncFromWebKit()
                    if let s = sourceURL { LegadoSourceState.set(s, "webLogin", "1") }
                    cont.resume()
                }
            }
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            guard let top = Self.topController() else { cont.resume(); return }
            top.present(nav, animated: true)
        }
    }

    /// From a book-source worker thread: shows the browser and blocks until it is closed.
    nonisolated static func openBlocking(url: URL?, html: String?, title: String, sourceURL: String?) {
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await open(url: url, html: html, title: title, sourceURL: sourceURL)
            sem.signal()
        }
        sem.wait()
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}

final class LegadoBrowserVC: UIViewController {
    private let web = WKWebView(frame: .zero, configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()
            return c
        }())
    private let url: URL?
    private let html: String?
    private let onDone: () -> Void

    init(url: URL?, html: String?, title: String, onDone: @escaping () -> Void) {
        self.url = url
        self.html = html
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        web.customUserAgent = LegadoHTTP.userAgent
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "browser.done"
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: web, action: #selector(WKWebView.reload))
        if let html { web.loadHTMLString(html, baseURL: url) } else if let url { web.load(URLRequest(url: url)) }
    }

    @objc private func done() {
        dismiss(animated: true) { [onDone] in onDone() }
    }
}

// MARK: - Hidden WebView (java.webView)

/// Loads a page (or HTML) in an off-screen WKWebView with the shared login cookies, then evaluates `js`
/// (default: the page HTML). Blocking; call from a worker thread.
enum LegadoWebView {
    nonisolated static func run(html: String?, url: String?, js: String?, timeout: TimeInterval = 25) throws -> String {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(LegadoError.network("网页加载超时"))
        Task { @MainActor in
            let runner = Runner()
            result = await runner.run(html: html, url: url, js: js, timeout: timeout)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut { throw LegadoError.network("网页加载超时") }
        return try result.get()
    }

    @MainActor private final class Runner: NSObject, WKNavigationDelegate {
        private var web: WKWebView?
        private var loaded: CheckedContinuation<Void, Never>?

        func run(html: String?, url: String?, js: String?, timeout: TimeInterval) async -> Result<String, Error> {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
            w.customUserAgent = LegadoHTTP.userAgent
            w.navigationDelegate = self
            web = w
            let base = url.flatMap { URL(string: $0) }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                loaded = c
                if let html, !html.isEmpty { w.loadHTMLString(html, baseURL: base) }
                else if let base { w.load(URLRequest(url: base)) }
                else { c.resume(); loaded = nil }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.finishLoad()
                }
            }
            // Give scripts on the page a moment (tokens are often written after load).
            try? await Task.sleep(for: .milliseconds(600))
            let code = (js?.isEmpty == false ? js! : "document.documentElement.outerHTML")
            do {
                let v = try await w.evaluateJavaScript("(function(){ return (\(code)); })()")
                web = nil
                return .success(v.map { "\($0)" } ?? "")
            } catch {
                // Statements (not an expression): run as-is.
                let v = try? await w.evaluateJavaScript(code)
                web = nil
                return .success(v.map { "\($0)" } ?? "")
            }
        }

        private func finishLoad() {
            loaded?.resume()
            loaded = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad() }
    }
}
