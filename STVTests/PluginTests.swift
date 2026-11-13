import XCTest
import UIKit
@testable import STV

/// 1.5 plugin runtime: sandbox isolation, host API, manifest validation, bundled comic plugins (offline fixtures),
/// JM stripe unscramble, 苹果 CMS parsing and the minors content filter.
final class PluginTests: XCTestCase {

    // MARK: helpers

    static func manifest(id: String = "com.test.sandbox", http: [String] = ["example.com", "*.example.com"], storage: Bool = false,
                         type: String = "comic", caps: [String] = ["detail", "pages"], extra: [String: Any] = [:]) -> PluginManifest {
        var o: [String: Any] = ["schema": 1, "id": id, "name": "T", "version": "1.0.0", "author": ["name": "t"], "type": type, "adult": false,
                                "minAppVersion": "1.5", "entry": "main.js", "permissions": ["http": http, "storage": storage], "capabilities": caps]
        for (k, v) in extra { o[k] = v }
        return try! PluginManifest.decode(try! JSONSerialization.data(withJSONObject: o))
    }

    static let stub = "export default { async detail(){ return {} }, async pages(){ return {images:[]} } };"

    func instance(_ src: String = PluginTests.stub, manifest m: PluginManifest = PluginTests.manifest()) throws -> PluginInstance {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PluginInstance(manifest: m, source: src, dir: dir, settings: [:], extraDomains: [], learnedUA: nil)
    }

    func code(_ e: Error) -> String {
        if case let PluginError.runtime(code, _) = e { return code }
        return "\(e)"
    }

    func expectCode(_ want: String, _ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do { let v = try await body(); XCTFail("expected \(want), got \(v)", file: file, line: line) }
        catch { XCTAssertEqual(code(error), want, "\(error)", file: file, line: line) }
    }

    static func fixture(_ path: String) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Plugins/" + path))) ?? Data()
    }

    /// Longest-prefix URL → fixture file responder.
    static func responder(_ map: [String: String]) -> (URLRequest) -> PluginFixtures.Reply? {
        { req in
            let u = req.url?.absoluteString ?? ""
            guard let k = map.keys.filter({ u.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return PluginFixtures.Reply(status: 404, body: Data()) }
            return PluginFixtures.Reply(status: 200, headers: ["content-type": "text/html; charset=utf-8"], body: fixture(map[k]!))
        }
    }

    override func tearDown() {
        PluginFixtures.responder = nil
        PluginNet.testProtocolClasses = nil
        NetGuard.resolverOverride = nil
        super.tearDown()
    }

    // MARK: sandbox isolation

    func testEvalAndFunctionConstructorsAreBlocked() async throws {
        let p = try instance()
        defer { p.shutdown() }
        for src in ["eval('1+1')", "new Function('return 1')()", "Function('return 1')()",
                    "(async function(){}).constructor('return 1')()", "(function*(){}).constructor('yield 1')().next()"] {
            do { _ = try await p.evalForTest(src); XCTFail("\(src) should throw") }
            catch { XCTAssertTrue("\(error)".lowercased().contains("eval") || "\(error)".contains("not supported") || code(error) != "", "\(src): \(error)") }
        }
        let leaked = try await p.evalForTest("typeof __host + ',' + typeof require + ',' + typeof fetch + ',' + typeof XMLHttpRequest + ',' + typeof std + ',' + typeof os")
        XCTAssertEqual(leaked as? String, "undefined,undefined,undefined,undefined,undefined,undefined")
        let frozen = try await p.evalForTest("(() => { try { host.http.request = 1 } catch(e) {} ; return Object.isFrozen(host) && Object.isFrozen(host.http) })()")
        XCTAssertEqual(frozen as? Bool, true)
    }

    func testImportIsRejected() throws {
        XCTAssertThrowsError(try instance("import x from './lib.js'; export default { detail(){}, pages(){} };"))
        XCTAssertThrowsError(try instance("export default 42;"))
    }

    func testInfiniteLoopTimesOut() async throws {
        let p = try instance("export default { detail(){}, pages(){}, async home(){ for(;;){} } };")
        defer { p.shutdown() }
        let t = Date()
        await expectCode("E_TIMEOUT") { try await p.call("home", [:], timeout: 1) }
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        // The instance stays usable after an interrupt.
        let ok = try await p.evalForTest("1+2")
        XCTAssertEqual(ok as? Int, 3)
    }

    func testMemoryCap() async throws {
        let p = try instance("export default { detail(){}, pages(){}, async home(){ const a=[]; for(;;) a.push('x'.repeat(1<<20) + a.length) } };")
        defer { p.shutdown() }
        await expectCode("E_MEMORY") { try await p.call("home", [:], timeout: 20) }
    }

    func testHttpAllowListAndAddressGuards() async throws {
        PluginFixtures.responder = { _ in PluginFixtures.Reply(body: Data("ok".utf8)) }
        let p = try instance()
        defer { p.shutdown() }
        let ok = try await p.evalForTest("(async () => (await host.http.get('https://www.example.com/a')).body)()")
        XCTAssertEqual(ok as? String, "ok")
        for u in ["https://evil.test/", "https://127.0.0.1/", "https://[::1]/", "http://example.com:8080/", "file:///etc/passwd", "ftp://example.com/"] {
            do { _ = try await p.evalForTest("(async () => (await host.http.get('\(u)')).status)()"); XCTFail("\(u) should be blocked") }
            catch { XCTAssertEqual(code(error), "E_PERMISSION", "\(u): \(error)") }
        }
        let allowed = try await p.evalForTest("[host.http.allowed('https://example.com/'), host.http.allowed('https://example.com.evil.test/'), host.http.allowed('https://10.0.0.1/')]")
        XCTAssertEqual(allowed as? [Bool], [true, false, false])
    }

    func testPrivateDNSAndLoopbackResolutionBlocked() async throws {
        NetGuard.resolverOverride = { h in h.hasPrefix("lan.") ? ["192.168.1.10"] : h.hasPrefix("lo.") ? ["127.0.0.1"] : h.hasPrefix("v6.") ? ["fd00::1"] : ["93.184.216.34"] }
        for ip in ["10.1.2.3", "172.16.0.1", "192.168.0.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "::1", "fe80::1", "fd12::1", "0.0.0.0"] {
            XCTAssertTrue(NetGuard.isBlockedIP(ip), ip)
        }
        XCTAssertFalse(NetGuard.isBlockedIP("93.184.216.34"))
        XCTAssertFalse(NetGuard.isBlockedIP("198.18.0.5"), "Clash fake-ip range must stay usable")
        let p = try instance()
        defer { p.shutdown() }
        for h in ["lan.example.com", "lo.example.com", "v6.example.com"] {
            do { _ = try await p.evalForTest("(async () => (await host.http.get('https://\(h)/')).status)()"); XCTFail(h) }
            catch { XCTAssertEqual(code(error), "E_PERMISSION", "\(h): \(error)") }
        }
    }

    final class RedirectStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let u = request.url!
            if u.host == "a.example.com" {
                let to = URL(string: u.path == "/ok" ? "https://b.example.com/final" : "https://evil.test/steal")!
                let r = HTTPURLResponse(url: u, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString, "Set-Cookie": "sid=1; Path=/"])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: r)
                return
            }
            let r = HTTPURLResponse(url: u, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("final".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testRedirectToUnlistedHostIsBlocked() async throws {
        PluginNet.testProtocolClasses = [RedirectStub.self]
        NetGuard.resolverOverride = { _ in ["93.184.216.34"] }
        let p = try instance()
        defer { p.shutdown() }
        let ok = try await p.evalForTest("(async () => { const r = await host.http.get('https://a.example.com/ok'); return r.body + '@' + r.url })()")
        XCTAssertEqual(ok as? String, "final@https://b.example.com/final")
        await expectCode("E_PERMISSION") { try await p.evalForTest("(async () => (await host.http.get('https://a.example.com/bad')).body)()") }
    }

    func testForbiddenHeadersAndPerPluginCookies() async throws {
        var seen: [URLRequest] = []
        PluginFixtures.responder = { r in seen.append(r); return PluginFixtures.Reply(body: Data("x".utf8)) }
        let a = try instance(manifest: Self.manifest(id: "com.test.a"))
        let b = try instance(manifest: Self.manifest(id: "com.test.b"))
        defer { a.shutdown(); b.shutdown() }
        a.host.net.jar.add([HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "sid", .value: "A", .secure: "TRUE"])!])
        _ = try await a.evalForTest("(async () => (await host.http.get('https://example.com/', { headers: { Cookie: 'sid=forged', Host: 'evil.test', Referer: 'https://example.com/' } })).status)()")
        _ = try await b.evalForTest("(async () => (await host.http.get('https://example.com/')).status)()")
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].value(forHTTPHeaderField: "Cookie"), "sid=A", "own jar only, forged Cookie header dropped")
        XCTAssertNotEqual(seen[0].value(forHTTPHeaderField: "Host"), "evil.test")
        XCTAssertEqual(seen[0].value(forHTTPHeaderField: "Referer"), "https://example.com/")
        XCTAssertNil(seen[1].value(forHTTPHeaderField: "Cookie"), "plugin B must not see plugin A's cookies")
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == "sid" && $0.value == "A" })
    }

    func testStorageNeedsPermissionAndIsPerPlugin() async throws {
        let none = try instance()
        defer { none.shutdown() }
        await expectCode("E_PERMISSION") { try await none.evalForTest("host.storage.set('k', 1)") }
        let a = try instance(manifest: Self.manifest(id: "com.test.sa", storage: true))
        let b = try instance(manifest: Self.manifest(id: "com.test.sb", storage: true))
        defer { a.shutdown(); b.shutdown() }
        _ = try await a.evalForTest("host.storage.set('k', {v: 1})")
        let mine = try await a.evalForTest("host.storage.get('k').v")
        let other = try await b.evalForTest("host.storage.get('k')")
        XCTAssertEqual(mine as? Int, 1)
        XCTAssertTrue(other is NSNull)
        await expectCode("E_STORAGE_FULL") { try await a.evalForTest("host.storage.set('big', 'x'.repeat(1100000))") }
    }

    func testErrorsCarryCodes() async throws {
        let p = try instance("export default { detail(){ throw host.error('E_NOT_FOUND', 'gone') }, pages(){ return null.x } };")
        defer { p.shutdown() }
        await expectCode("E_NOT_FOUND") { try await p.call("detail", [:]) }
        await expectCode("E_INTERNAL") { try await p.call("pages", [:]) }
    }

    // MARK: host API

    func testCSSSelectorsAndHTML() async throws {
        let p = try instance()
        defer { p.shutdown() }
        let html = #"<div id='m'><ul class='l x'><li class='a'><a href='/p/1' data-x='1'>One</a></li><li><a href='/p/2' title='T2'>Two</a></li><li class='a b'><a href='https://cdn.example.com/3.jpg'>Three</a></li></ul><p>t <b>bold</b></p><img data-original='/media/photos/1/00001.webp'></div>"#
        let js = """
        (() => { const d = host.html.parse(\(String(decoding: try JSONSerialization.data(withJSONObject: [html], options: [.fragmentsAllowed]), as: UTF8.self))[0]);
          return [ d.select('li').length, d.select('ul.l.x > li.a a').map(a => a.text()).join('|'), d.select('a[href^="/p/"]').length,
                   d.select('a[href$=".jpg"]').length, d.select('a[href*="/p/2"]')[0].attr('title'), d.select('li:first-child a')[0].text(),
                   d.select('li:last-child a')[0].text(), d.select('li:nth-child(2) a')[0].text(), d.select('li:not(.a)').length,
                   d.selectFirst('#m p').text(), d.selectFirst('p').html(), d.select('a[data-x], img[data-original*="/media/photos/"]').length,
                   d.selectFirst('.nope') === null, d.select('li').map(li => li.select('a').length).join('') ] })()
        """
        let r = try await p.evalForTest(js) as? [Any]
        XCTAssertEqual(r?[0] as? Int, 3)
        XCTAssertEqual(r?[1] as? String, "One|Three")
        XCTAssertEqual(r?[2] as? Int, 2)
        XCTAssertEqual(r?[3] as? Int, 1)
        XCTAssertEqual(r?[4] as? String, "T2")
        XCTAssertEqual(r?[5] as? String, "One")
        XCTAssertEqual(r?[6] as? String, "Three")
        XCTAssertEqual(r?[7] as? String, "Two")
        XCTAssertEqual(r?[8] as? Int, 1)
        XCTAssertEqual(r?[9] as? String, "t bold")
        XCTAssertEqual(r?[10] as? String, "t <b>bold</b>")
        XCTAssertEqual(r?[11] as? Int, 2)
        XCTAssertEqual(r?[12] as? Bool, true)
        XCTAssertEqual(r?[13] as? String, "111")
    }

    func testCryptoAndCodec() async throws {
        let p = try instance()
        defer { p.shutdown() }
        let r = try await p.evalForTest("""
        (() => { const k = '0123456789abcdef', iv = 'fedcba9876543210';
          const enc = host.crypto.aes({ mode: 'cbc', op: 'encrypt', key: k, iv: iv, data: 'hello 世界', out: 'base64' });
          const dec = host.crypto.aes({ mode: 'cbc', op: 'decrypt', key: k, iv: iv, data: enc, in: 'base64' });
          return [ host.crypto.md5('abc'), host.crypto.sha256('abc').slice(0, 16), host.crypto.hmac('sha256', 'key', 'The quick brown fox jumps over the lazy dog').slice(0, 16),
                   dec, host.codec.base64Encode('hi'), host.codec.base64Decode('aGk='), host.url.resolve('https://example.com/a/b', '../c?x=1'),
                   host.url.encodeForm({ a: '1 2', b: '&' }) ] })()
        """) as? [String]
        XCTAssertEqual(r?[0], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(r?[1], "ba7816bf8f01cfea")
        XCTAssertEqual(r?[2], "f7bc83f430538424")
        XCTAssertEqual(r?[3], "hello 世界")
        XCTAssertEqual(r?[4], "aGk=")
        XCTAssertEqual(r?[5], "hi")
        XCTAssertEqual(r?[6], "https://example.com/c?x=1")
        XCTAssertEqual(r?[7], "a=1%202&b=%26")
    }

    // MARK: manifest

    func testManifestValidation() throws {
        let base: [String: Any] = ["schema": 1, "id": "com.test.m", "name": "M", "version": "1.0.0", "author": ["name": "a"], "type": "comic", "adult": true,
                                   "minAppVersion": "1.5", "entry": "main.js", "permissions": ["http": ["example.com"]], "capabilities": ["detail", "pages"]]
        func m(_ patch: [String: Any]) throws -> PluginManifest {
            var o = base; for (k, v) in patch { o[k] = v }
            return try PluginManifest.decode(try JSONSerialization.data(withJSONObject: o))
        }
        XCTAssertEqual(try m([:]).problems(appVersion: "1.5"), [])
        XCTAssertThrowsError(try m(["compat": "catvod"]), "CatVod compat mode is not supported")
        XCTAssertFalse(try m(["id": "Bad Id"]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["permissions": ["http": ["*"]]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["permissions": ["http": ["127.0.0.1"]]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["capabilities": ["detail"]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["minAppVersion": "9.0"]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["entry": "../x.js"]).problems(appVersion: "1.5").isEmpty)
        // Integrity mismatch
        let bad = try m(["integrity": ["files": ["main.js": "sha256-AAAA"]]])
        XCTAssertThrowsError(try PluginInstaller.validate(manifest: bad, source: Data(Self.stub.utf8), origin: "test"))
        // Permission diff
        let v2 = try m(["version": "1.1.0", "permissions": ["http": ["example.com", "new.example.net"], "cloudflare": true]])
        let diff = PermissionDiff(old: try m([:]), new: v2)
        XCTAssertTrue(diff.needsConsent)
    }

    func testBundledPluginsValidate() throws {
        let b = PluginInstaller.bundled()
        XCTAssertEqual(Set(b.map(\.manifest.id)), ["com.idj.bundled.manga18fx", "com.idj.bundled.komikindo", "com.idj.bundled.jm18comic"])
        for x in b {
            XCTAssertTrue(x.manifest.adult, "\(x.name) must sit behind the adult switch")
            let p = try PluginInstaller.prepare(bundle: x.data, origin: "test")
            XCTAssertTrue(Set(p.exported).isSuperset(of: ["home", "category", "search", "detail", "pages"]), "\(x.name): \(p.exported)")
        }
    }

    // MARK: bundled comic plugins against saved pages (offline)

    @MainActor func install(_ name: String) throws -> MangaSourceID {
        let b = try XCTUnwrap(PluginInstaller.bundled().first { $0.name == name })
        PluginRuntime.unload(b.manifest.id)
        try PluginStore.shared.commit(try PluginInstaller.prepare(bundle: b.data, origin: "test"))
        PluginStore.shared.setEnabled(b.manifest.id, true)
        return .plugin(b.manifest.id)
    }

    @MainActor func testManga18fxPlugin() async throws {
        PluginFixtures.responder = Self.responder([
            "https://manga18fx.com/manga/secret-class-01/chapter": "manga18fx/chapter.html", "https://manga18fx.com/manga/": "manga18fx/detail.html",
            "https://manga18fx.com/search": "manga18fx/search.html", "https://manga18fx.com/page/": "manga18fx/page2.html", "https://manga18fx.com/": "manga18fx/home.html"])
        let src = try install("manga18fx")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 10)
        XCTAssertTrue(home.items.allSatisfy { $0.cover.hasPrefix(PluginMedia.scheme) })
        XCTAssertGreaterThan(p.categories.count, 5, "categories cached from home()")
        let page2 = try await p.list(MangaCategory(id: "latest", title: ""), page: 2)
        XCTAssertFalse(page2.items.isEmpty)
        let s = try await p.search("love", page: 1)
        XCTAssertFalse(s.items.isEmpty)
        let d = try await p.detail(MangaItem(source: src, mangaId: "secret-class-01", title: "x", cover: ""))
        XCTAssertEqual(d.item.title, "Secret Class")
        XCTAssertGreaterThan(d.chapters.count, 10)
        XCTAssertEqual(d.chapters.first?.chapterId, "secret-class-01/chapter-1", "old → new order")
        let pages = try await p.pages(d.item, d.chapters[0])
        XCTAssertGreaterThan(pages.count, 5)
        let ref = try XCTUnwrap(PluginMedia.parse(pages[0]))
        XCTAssertEqual(ref.url.host, "img01.manga18fx.com")
        XCTAssertEqual(ref.headers["Referer"], "https://manga18fx.com/")
        XCTAssertNil(ref.transform)
    }

    @MainActor func testKomikindoPlugin() async throws {
        PluginFixtures.responder = Self.responder([
            "https://komikindo.click/manga/?": "komikindo/list.html", "https://komikindo.click/manga/": "komikindo/detail.html",
            "https://komikindo.click/?s=": "komikindo/search.html", "https://komikindo.click/ane-haha": "komikindo/chapter.html"])
        let src = try install("komikindo")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 10)
        XCTAssertTrue(home.hasMore)
        let s = try await p.search("love", page: 1)
        XCTAssertFalse(s.items.isEmpty)
        let d = try await p.detail(MangaItem(source: src, mangaId: "ane-haha-kankei-kai-hiroyuki", title: "x", cover: ""))
        XCTAssertEqual(d.chapters.count, 4)
        XCTAssertEqual(d.chapters.first?.chapterId, "ane-haha-kankei-kai-hiroyuki-chapter-1")
        XCTAssertEqual(d.status, "连载中")
        let pages = try await p.pages(d.item, d.chapters[3])
        XCTAssertGreaterThan(pages.count, 3)
        let ref = try XCTUnwrap(PluginMedia.parse(pages[0]))
        XCTAssertEqual(ref.url.scheme, "https", "http image URLs are upgraded")
        XCTAssertEqual(ref.url.host, "linksaya.com")
        XCTAssertEqual(ref.headers["Referer"], "https://komikindo.click/")
    }

    @MainActor func testJM18comicPluginWithScrambleDescriptor() async throws {
        PluginFixtures.responder = Self.responder([
            "https://18comic.ink/albums": "jm/albums.html", "https://18comic.ink/album/": "jm/album.html", "https://18comic.ink/photo/": "jm/photo.html",
            "https://18comic.ink/search/": "jm/search.html", "https://jmcomicgo.org/": "jm/publish.html"])
        let src = try install("jm18comic")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 20)
        XCTAssertTrue(home.hasMore)
        let d = try await p.detail(MangaItem(source: src, mangaId: "1254979", title: "x", cover: ""))
        XCTAssertFalse(d.item.title.isEmpty)
        XCTAssertGreaterThan(d.chapters.count, 5)
        XCTAssertEqual(d.chapters.first?.chapterId, "1254979")
        let pages = try await p.pages(d.item, d.chapters[0])
        XCTAssertGreaterThan(pages.count, 10)
        // Published algorithm (JMComic-Crawler-Python get_num): aid 1254979 ≥ 421926 → x = 8;
        // md5("1254979" + "00001") ends in "9" → (57 % 8) * 2 + 2 = 4; "00002" ends in "b" → (98 % 8) * 2 + 2 = 6.
        let segs = pages.prefix(3).map { (PluginMedia.parse($0)?.transform?["segments"] as? Int) ?? -1 }
        XCTAssertEqual(segs, [4, 6, 4])
        XCTAssertEqual(PluginMedia.parse(pages[0])?.transform?["type"] as? String, "stripes")
        XCTAssertTrue(PluginMedia.parse(pages[0])?.url.host?.hasSuffix("18comic.ink") ?? false)
    }

    // MARK: JM stripes (native)

    func testStripePlanMatchesReferenceAlgorithm() {
        // Reference (Python decode_and_save) for h = 1003, num = 8: over = 3, move = 125.
        let plan = ImageStripes.plan(height: 1003, segments: 8)
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan[0].src, 875); XCTAssertEqual(plan[0].dst, 0); XCTAssertEqual(plan[0].h, 128)
        XCTAssertEqual(plan[1].src, 750); XCTAssertEqual(plan[1].dst, 128); XCTAssertEqual(plan[1].h, 125)
        XCTAssertEqual(plan[7].src, 0); XCTAssertEqual(plan[7].dst, 878); XCTAssertEqual(plan[7].h, 125)
        XCTAssertEqual(plan.map(\.h).reduce(0, +), 1003)
        XCTAssertTrue(ImageStripes.plan(height: 100, segments: 0).isEmpty)
    }

    func testStripeUnscrambleRoundTrip() throws {
        // Synthetic image: every row has a distinct color, so any misplaced band shows up.
        let w = 7, h = 1003
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            for y in 0..<h {
                UIColor(red: CGFloat(y % 256) / 255, green: CGFloat((y / 256) * 60) / 255, blue: 0.5, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
            }
        }.cgImage!
        for n in [2, 4, 6, 8, 10, 16] {
            let scrambled = try XCTUnwrap(ImageStripes.scramble(img, segments: n))
            let restored = try XCTUnwrap(ImageStripes.unscramble(scrambled, segments: n))
            XCTAssertEqual(rows(restored), rows(img), "segments=\(n)")
            XCTAssertNotEqual(rows(scrambled), rows(img))
        }
        // Through the PluginMedia transform path (encoded → decoded image data).
        let png = UIImage(cgImage: try XCTUnwrap(ImageStripes.scramble(img, segments: 6))).pngData()!
        let out = try PluginMedia.apply(["type": "stripes", "segments": 6], png)
        let back = try XCTUnwrap(UIImage(data: out)?.cgImage)
        XCTAssertEqual(back.height, h)
        let a = rows(back), b = rows(img)
        let close = zip(a, b).filter { abs(Int($0.0) - Int($0.1)) <= 3 }.count   // JPEG re-encode tolerance
        XCTAssertGreaterThan(Double(close) / Double(h), 0.97)
    }

    /// Red channel of the middle pixel in each row.
    private func rows(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { buf[($0 * w + w / 2) * 4] }
    }

    func testMediaRefRoundTripDropsUnsafeHeaders() {
        let r = PluginMedia.ref(plugin: "com.a.b", url: "https://img.example.com/1.jpg?x=1", headers: ["Referer": "https://example.com/", "Cookie": "x", "Authorization": "y"],
                                transform: ["type": "stripes", "segments": 4])
        let p = PluginMedia.parse(r)
        XCTAssertEqual(p?.plugin, "com.a.b")
        XCTAssertEqual(p?.url.absoluteString, "https://img.example.com/1.jpg?x=1")
        XCTAssertEqual(p?.headers, ["Referer": "https://example.com/"])
        XCTAssertEqual(p?.transform?["segments"] as? Int, 4)
    }

    // MARK: 苹果 CMS

    static let cmsList: [String: Any] = [
        "code": 1, "page": 1, "pagecount": 3, "total": 60,
        "class": [["type_id": 1, "type_name": "电影"], ["type_id": 2, "type_name": "连续剧"], ["type_id": 9, "type_name": "萝莉"]],
        "list": [
            ["vod_id": 101, "vod_name": "示例电影", "vod_pic": "http://img.example.com/a.jpg", "vod_remarks": "HD", "type_name": "电影", "vod_actor": "甲,乙"],
            ["vod_id": 102, "vod_name": "不该出现", "vod_pic": "", "type_name": "萝莉", "vod_remarks": ""]
        ]
    ]

    func testMacCMSParsing() throws {
        let src = DramaSource.cms("abc")
        let cats = MacCMSProvider.parseCategories(Self.cmsList)
        XCTAssertEqual(cats.map(\.name), ["电影", "连续剧"], "minors categories are dropped")
        let page = MacCMSProvider.page(Self.cmsList, source: src, page: 1)
        XCTAssertEqual(page.items.map(\.seriesId), ["101"])
        XCTAssertEqual(page.items.first?.cover, "https://img.example.com/a.jpg")
        XCTAssertTrue(page.hasMore)
        let detail: [String: Any] = ["list": [[
            "vod_id": 7, "vod_name": "剧", "vod_pic": "https://x/a.jpg", "type_name": "连续剧", "vod_content": "<p>简介&nbsp;</p>",
            "vod_play_from": "share$$$m3u8a$$$mp4b",
            "vod_play_url": "第1集$https://share.example.com/p/1#第2集$https://share.example.com/p/2$$$第1集$https://cdn.example.com/1/index.m3u8#第2集$https://cdn.example.com/2/index.m3u8$$$第1集$http://v.example.com/1.mp4"
        ]]]
        let d = try MacCMSProvider.parseDetail(detail, series: HGSeries(source: src, seriesId: "7", title: "", cover: ""), source: src)
        XCTAssertEqual(d.episodes.count, 2, "longest direct line wins")
        XCTAssertEqual(d.episodes.first?.page, "m3u8a")
        let st = MacCMSProvider.streams(for: d.episodes[0])
        XCTAssertEqual(st.map(\.url), ["https://cdn.example.com/1/index.m3u8", "https://v.example.com/1.mp4"], "alt lines + https upgrade")
        XCTAssertEqual(st.first?.kind, .hls)
        let lines = MacCMSProvider.lines(from: "a$$$b", urls: "x$u1#y$u2$$$z$u3")
        XCTAssertEqual(lines.map(\.name), ["a", "b"])
        XCTAssertEqual(lines[0].eps.map(\.1), ["u1", "u2"])
        XCTAssertThrowsError(try CMSStore.normalize("http://127.0.0.1/api.php"))
        XCTAssertEqual(try CMSStore.normalize("http://cms.example.com/api.php/provide/vod/?ac=list"), "https://cms.example.com/api.php/provide/vod/")
    }

    // MARK: content filter

    func testMinorsFilter() {
        for blocked in [["Loli Collection"], ["x", "lolicon"], ["正太"], ["萝莉"], ["蘿莉"], ["Schoolgirl"], ["school-girl"], ["age_regression"],
                        ["未成年"], ["女子高生"], ["JK"], ["ロリ"], ["Hasunosora Jogakuin"], ["little girl"]] {
            XCTAssertTrue(ContentFilter.isBlocked(blocked), "\(blocked)")
        }
        for ok in [["Secret Class"], ["MILF"], ["Childhood Friend Romance"].map { _ in "Mature" }, ["Kids Return".replacingOccurrences(of: "Kids", with: "Adults")],
                   ["Minority Report".replacingOccurrences(of: "Minority", with: "Majority")], ["Jake"], ["Japanese"], ["school life"], ["女大學生"]] {
            XCTAssertFalse(ContentFilter.isBlocked(ok), "\(ok)")
        }
    }
}
