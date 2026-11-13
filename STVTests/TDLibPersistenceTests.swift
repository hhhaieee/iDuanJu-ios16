import XCTest
@testable import STV

/// Bug 1.4b7: TDLib login lost after restarting the app. These tests drive `TDLibService` through a mock engine
/// that follows TDLib's persistence contract (session = database written with the same key in the same dir).
@MainActor
final class TDLibPersistenceTests: XCTestCase {
    var base: URL!
    var secure: URL!
    var savedFallback: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("td-persist-\(UUID().uuidString)")
        secure = FileManager.default.temporaryDirectory.appendingPathComponent("td-secure-\(UUID().uuidString)")
        savedFallback = Keychain.fallbackDir
        Keychain.fallbackDir = secure
        Keychain.keychainDisabled = true          // isolate from the app's Keychain; exercises the file fallback
        UserDefaults.standard.set(false, forKey: "stv.tdlib.loggedIn")
        TDCredentials(apiId: "12345", apiHash: String(repeating: "a", count: 32)).save()
    }

    override func tearDown() async throws {
        TDCredentials.clear(); TDCredentials.clearDatabaseKey()
        Keychain.keychainDisabled = false
        Keychain.fallbackDir = savedFallback
        UserDefaults.standard.set(false, forKey: "stv.tdlib.loggedIn")
        try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: secure)
    }

    private func settle(_ s: TDLibService, until f: (TDAuthState) -> Bool, timeout: TimeInterval = 5) async {
        let t = Date()
        while !f(s.state), Date().timeIntervalSince(t) < timeout { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func login(_ s: TDLibService) async {
        await s.start()
        await settle(s) { $0 == .waitPhone }
        await s.submit(phone: "+10000000000")
        await settle(s) { if case .waitCode = $0 { return true } else { return false } }
        await s.submit(code: "12345")
        await settle(s) { $0.isReady }
    }

    func testSessionSurvivesColdStart() async {
        let e1 = TDMockEngine(mode: .session)
        let s1 = TDLibService(baseDir: base, makeEngine: { e1 }, available: true)
        XCTAssertEqual(s1.state, .idle)
        await login(s1)
        XCTAssertTrue(s1.state.isReady, "login: \(s1.state)")
        let key1 = TDCredentials.databaseKey

        // "Kill the app": a brand-new service + engine over the same directories.
        let e2 = TDMockEngine(mode: .session)
        let s2 = TDLibService(baseDir: base, makeEngine: { e2 }, available: true)
        XCTAssertEqual(s2.state, .starting, "cold start shows restoring, not 请输入手机号")
        await s2.bootstrap()
        await settle(s2) { $0.isReady }
        XCTAssertTrue(s2.state.isReady, "restored: \(s2.state)")
        XCTAssertEqual(e2.startCalls, 1)
        XCTAssertEqual(e2.logOutCalls, 0)
        XCTAssertEqual(TDCredentials.databaseKey, key1, "database key must be stable")
        print("TD-PERSIST cold start → \(s2.state.label)")
    }

    func testBootstrapWithoutSessionDoesNothing() async {
        let e = TDMockEngine(mode: .session)
        let s = TDLibService(baseDir: base, makeEngine: { e }, available: true)
        await s.bootstrap()
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(e.startCalls, 0, "no TDLib start (no network) without a saved session")
    }

    func testExplicitLogoutWipesAndStaysLoggedOut() async {
        let e1 = TDMockEngine(mode: .session)
        let s1 = TDLibService(baseDir: base, makeEngine: { e1 }, available: true)
        await login(s1)
        await s1.logOut()
        XCTAssertEqual(e1.logOutCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertEqual(s1.state, .idle)
        let e2 = TDMockEngine(mode: .session)
        let s2 = TDLibService(baseDir: base, makeEngine: { e2 }, available: true)
        await s2.bootstrap()
        XCTAssertEqual(s2.state, .idle)
        XCTAssertEqual(e2.startCalls, 0)
    }

    func testLostKeyFailsClearlyAndResetRecovers() async {
        let e1 = TDMockEngine(mode: .session)
        let s1 = TDLibService(baseDir: base, makeEngine: { e1 }, available: true)
        await login(s1)
        TDCredentials.clearDatabaseKey()          // e.g. signer wiped the Keychain
        let e2 = TDMockEngine(mode: .session)
        let s2 = TDLibService(baseDir: base, makeEngine: { e2 }, available: true)
        await s2.bootstrap()
        await settle(s2) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let m) = s2.state else { return XCTFail("expected failure, got \(s2.state)") }
        XCTAssertTrue(m.contains("重置本地会话"))
        s2.resetLocalSession()
        XCTAssertEqual(s2.state, .idle)
        XCTAssertFalse(s2.hasLocalSession)
    }

    func testKeychainFallbackKeepsValues() {
        Keychain.set("v1", "probe")
        XCTAssertEqual(Keychain.get("probe"), "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secure.appendingPathComponent("probe").path))
        Keychain.set(nil, "probe")
        XCTAssertNil(Keychain.get("probe"))
    }

    func testDefaultDatabaseDirIsPersistent() {
        let p = TDLibService.shared.baseDir.path
        XCTAssertTrue(p.contains("/Library/Application Support/tdlib"), p)
        XCTAssertFalse(p.contains("/tmp/") || p.contains("/Caches/"), p)
    }

    // Bug 2: restricted channel read through TDLib (searchPublicChat → getChatHistory paging, searchChatMessages).
    func testRestrictedChannelThroughTDLib() async throws {
        let e = TDMockEngine(mode: .ready)
        let s = TDLibService(baseDir: base, makeEngine: { e }, available: true)
        await s.start()
        await settle(s) { $0.isReady }
        do { _ = try await s.channelPage("restrictedSample", before: nil); XCTFail("restriction expected") }
        catch let err as TDError {
            guard case .restricted = err else { return XCTFail("\(err)") }
            XCTAssertTrue(err.localizedDescription.contains("敏感内容"))
        }
        await s.refreshSensitive()
        XCTAssertTrue(s.sensitive.canChange)
        try await s.setSensitive(true)
        let p1 = try await s.channelPage("restrictedSample", before: nil)
        XCTAssertEqual(p1.posts.count, 30)
        XCTAssertEqual(p1.posts.first?.msgId, 300)
        XCTAssertEqual(p1.before, 271)
        XCTAssertTrue(p1.posts.allSatisfy { $0.channel == "restrictedSample" })
        let p2 = try await s.channelPage("restrictedSample", before: p1.before)
        XCTAssertEqual(p2.posts.map(\.msgId).max(), 270)
        XCTAssertEqual(p2.posts.count, 15)
        let p3 = try await s.channelPage("restrictedSample", before: p2.before)
        XCTAssertTrue(p3.posts.isEmpty); XCTAssertNil(p3.before)
        let q = try await s.channelPage("restrictedSample", before: nil, query: "推广")
        XCTAssertEqual(q.posts.map(\.msgId), [290])
        // Filters apply exactly as for web posts.
        let ad = p1.posts.first { $0.msgId == 290 }!
        XCTAssertTrue(TGFilter.verdict(ad, rules: [], heuristics: true, channelAdBlock: true).blocked)
        XCTAssertFalse(TGFilter.verdict(p1.posts.first { $0.msgId == 299 }!, rules: [], heuristics: true, channelAdBlock: true).blocked)
        XCTAssertTrue(TGFilter.verdict(p1.posts.first { $0.msgId == 299 }!, rules: [TGRule(kind: .keyword, pattern: "#299")], heuristics: false, channelAdBlock: true).blocked)
    }

    func testNotLoggedInIsExplicit() async {
        let s = TDLibService(baseDir: base, makeEngine: { nil }, available: true)
        do { _ = try await s.channelPage("x", before: nil); XCTFail() }
        catch { XCTAssertEqual(error as? TDError, .notLoggedIn) }
    }

    func testMsgIdMapping() {
        XCTAssertEqual(TDMsgId.server(300 << 20), 300)
        XCTAssertEqual(TDMsgId.td(300), 300 << 20)
    }
}
