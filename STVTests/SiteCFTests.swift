import XCTest
import WebKit
@testable import STV

/// Stub network: Cloudflare-like origin that only serves content when the request carries
/// `cf_clearance=<good>` AND the User-Agent the clearance was issued to.
final class CFStubProtocol: URLProtocol {
    nonisolated(unsafe) static var clearance = "good-token"
    nonisolated(unsafe) static var ua = ""
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("missav.ws") == true || request.url?.host?.hasSuffix("hanime1.me") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let ok = cookie.contains("cf_clearance=\(Self.clearance)") && request.value(forHTTPHeaderField: "User-Agent") == Self.ua
        let body = ok
            ? "<html><head><title>MissAV</title></head><body>" + String(repeating: "<div class=\"thumbnail group\"><a href=\"https://missav.ws/cn/abc-123\">x</a></div>", count: 200) + "<script src=\"/cdn-cgi/challenge-platform/scripts/jsd/main.js\"></script></body></html>"
            : "<html><head><title>请稍候…</title></head><body><script>window._cf_chl_opt={cvId:'3'}</script></body></html>"
        let resp = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 403, httpVersion: "HTTP/1.1",
                                   headerFields: ok ? ["Content-Type": "text/html"] : ["Content-Type": "text/html", "Server": "cloudflare", "cf-mitigated": "challenge"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SiteCFTests: XCTestCase {
    let webUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"

    override func setUp() {
        for c in HTTPCookieStorage.shared.cookies ?? [] where CFCookies.isSiteCookie(c) { HTTPCookieStorage.shared.deleteCookie(c) }
        SiteUA.clear(.missav); SiteUA.clear(.hanime1)
        CFStubProtocol.seen = []
        // Unit tests drive the cookie/UA chain directly; keep the WebKit solver out of it.
        CFSolverHook.solveImpl = nil
        CFSolverHook.fetchImpl = nil
    }
    override func tearDown() { setUp() }

    // MARK: detection

    func testLocalizedChallengeTitleIsChallenge() {
        let zh = "<html><head><title>请稍候…</title></head><body>x</body></html>"
        XCTAssertTrue(CFDetect.isChallenge(status: 403, headers: ["Server": "cloudflare"], body: zh))
        XCTAssertTrue(CFDetect.isChallenge(status: 200, headers: [:], body: zh))
        XCTAssertTrue(CFDetect.isChallengeTitle("Just a moment..."))
    }

    func testRealPageWithChallengePlatformScriptIsNotChallenge() {
        let real = "<html><head><title>Hanime1</title></head><body>" + String(repeating: "<div class=\"video-item-container\">a</div>", count: 2000)
            + "<script src=\"/cdn-cgi/challenge-platform/h/g/scripts/jsd/x/main.js\"></script></body></html>"
        XCTAssertFalse(CFDetect.isChallenge(status: 200, headers: ["Server": "cloudflare"], body: real))
    }

    func testFixtureChallengePagesDetected() throws {
        // Real CF interstitials captured earlier (title "Just a moment...", `_cf_chl_opt`).
        let page = "<!DOCTYPE html><html lang=\"en-US\"><head><title>Just a moment...</title></head><body><script>(function(){window._cf_chl_opt={cvId: '3'}})();</script></body></html>"
        XCTAssertTrue(CFDetect.isChallenge(status: 403, headers: ["cf-mitigated": "challenge"], body: page))
    }

    // MARK: verify verdict (sheet must not auto-close on a localized interstitial)

    func testVerdictWaitsOnLocalizedChallengeAndNeedsClearance() {
        let clearance = HTTPCookie(properties: [.domain: ".missav.ws", .path: "/", .name: "cf_clearance", .value: "v", .secure: "TRUE",
                                                .expires: Date().addingTimeInterval(3600)])!
        XCTAssertEqual(CFDetect.verdict(title: "请稍候…", domChallenge: true, cookies: [], host: "missav.ws", elapsed: 10), .waiting)
        XCTAssertEqual(CFDetect.verdict(title: "", domChallenge: false, cookies: [clearance], host: "missav.ws", elapsed: 10), .waiting)
        XCTAssertEqual(CFDetect.verdict(title: "MissAV", domChallenge: true, cookies: [clearance], host: "missav.ws", elapsed: 10), .waiting)
        XCTAssertEqual(CFDetect.verdict(title: "MissAV", domChallenge: false, cookies: [clearance], host: "missav.ws", elapsed: 0.5), .passed)
        XCTAssertEqual(CFDetect.verdict(title: "MissAV", domChallenge: false, cookies: [], host: "missav.ws", elapsed: 1), .waiting)
        XCTAssertEqual(CFDetect.verdict(title: "MissAV", domChallenge: false, cookies: [], host: "missav.ws", elapsed: 5), .passedWithoutClearance)
        // clearance for another mirror doesn't count
        XCTAssertEqual(CFDetect.verdict(title: "MissAV", domChallenge: false, cookies: [clearance], host: "missav.fans", elapsed: 1), .waiting)
    }

    func testPartitionedCookieBecomesSendable() throws {
        let url = URL(string: "https://missav.ws/x")!
        var props: [HTTPCookiePropertyKey: Any] = [.domain: ".missav.ws", .path: "/", .name: "cf_clearance", .value: "p",
                                                   .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]
        props[HTTPCookiePropertyKey("StoragePartition")] = "https://missav.ws"
        let partitioned = try XCTUnwrap(HTTPCookie(properties: props))
        let synced = CFCookies.sync([partitioned])
        XCTAssertNil(synced.first?.properties?[HTTPCookiePropertyKey("StoragePartition")])
        XCTAssertTrue((HTTPCookieStorage.shared.cookies(for: url) ?? []).contains { $0.name == "cf_clearance" })
    }

    func testDomainMatch() {
        XCTAssertTrue(CFCookies.domain(".missav.ws", matches: "missav.ws"))
        XCTAssertTrue(CFCookies.domain("missav.ws", matches: "www.missav.ws"))
        XCTAssertFalse(CFCookies.domain(".missav.ws", matches: "missav.fans"))
        XCTAssertFalse(CFCookies.domain("av.ws", matches: "missav.ws"))
        XCTAssertEqual(DramaSource.site(forHost: "missav.fans"), .missav)
    }

    // MARK: end-to-end: WebKit store → URLSession jar → SiteHTTP request with learned UA

    @MainActor
    func testWebKitCookieAndUAReachSiteHTTP() async throws {
        CFStubProtocol.ua = webUA
        let http = SiteHTTP(protocolClasses: [CFStubProtocol.self])

        // 1. Before verification: challenge → needsVerification
        do {
            _ = try await http.get(.missav, mirrors: ["https://missav.ws"], path: "/dm539/cn/new", ttl: 0)
            XCTFail("expected challenge")
        } catch let e as SiteError {
            XCTAssertNotNil(e.verification)
        }

        // 2. The verify WebView's store gets cf_clearance (what Cloudflare sets after the user passes)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        let c = HTTPCookie(properties: [.domain: ".missav.ws", .path: "/", .name: "cf_clearance", .value: CFStubProtocol.clearance,
                                        .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
        await store.setCookie(c)
        let fromWebKit = await store.allCookies()
        XCTAssertEqual(CFCookies.sync(fromWebKit).map(\.name), ["cf_clearance"])
        withExtendedLifetime(dataStore) {}
        SiteUA.set(webUA, for: .missav)
        XCTAssertEqual(DramaSource.missav.userAgent, webUA)
        await http.clearPreferred()

        // 3. Same request now carries cookie + exact WebView UA and passes
        let r: SiteHTTP.Response
        do { r = try await http.get(.missav, mirrors: ["https://missav.ws"], path: "/dm539/cn/new", ttl: 0) }
        catch { return XCTFail("step 3 threw \(error)") }
        XCTAssertTrue(r.text.contains("thumbnail"))
        let last = try XCTUnwrap(CFStubProtocol.seen.last)
        XCTAssertTrue(last.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=good-token") == true)
        XCTAssertEqual(last.value(forHTTPHeaderField: "User-Agent"), webUA)

        // 4. Wrong UA (old static one) is rejected even with the cookie → proves UA must follow the WebView
        SiteUA.clear(.missav)
        await http.clearPreferred()
        do {
            _ = try await http.get(.missav, mirrors: ["https://missav.ws"], path: "/dm539/cn/new", ttl: 0)
            XCTFail("expected challenge with mismatched UA")
        } catch {}
    }

    /// Silent solver path: SiteHTTP asks the solver, which (here: a fake) syncs cookie + UA; the original
    /// request is then retried and succeeds without any UI.
    func testSilentSolverRetriesOriginalRequest() async throws {
        CFStubProtocol.ua = webUA
        let ua = webUA
        CFSolverHook.solveImpl = { s, _ in
            let c = HTTPCookie(properties: [.domain: ".hanime1.me", .path: "/", .name: "cf_clearance", .value: CFStubProtocol.clearance,
                                            .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
            CFCookies.sync([c]); SiteUA.set(ua, for: s); return true
        }
        let http = SiteHTTP(protocolClasses: [CFStubProtocol.self])
        let r = try await http.get(.hanime1, mirrors: ["https://hanime1.me"], path: "/search?sort=x", ttl: 0)
        XCTAssertTrue(r.text.contains("thumbnail"))
        XCTAssertEqual(CFStubProtocol.seen.count, 2)   // challenged once, retried once
        XCTAssertEqual(CFStubProtocol.seen.last?.value(forHTTPHeaderField: "User-Agent"), webUA)
    }

    func testLearnedUAPersistsInDefaults() {
        let d = UserDefaults(suiteName: "stv.tests")!
        SiteUA.set("UA-X", for: .hanime1, defaults: d)
        XCTAssertEqual(SiteUA.learned(.hanime1, defaults: d), "UA-X")
        SiteUA.clear(.hanime1, defaults: d)
        XCTAssertNil(SiteUA.learned(.hanime1, defaults: d))
    }
}
