import Foundation
import Combine
import Security

/// Minimal Keychain wrapper (generic passwords, this device only) with a file fallback.
///
/// Sideloaded builds are re-signed by AltStore / Sideloadly / TrollStore etc.; depending on the signer the
/// Keychain may refuse writes or return a different access group after a re-sign. If the Keychain can't
/// hold a value we keep it in a protected file under Application Support instead, so the TDLib database key
/// (and therefore the login session) survives app restarts either way.
enum Keychain {
    static let service = "com.local.STV.tdlib"
    /// Tests point this at a temp dir.
    nonisolated(unsafe) static var fallbackDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tdlib-secure", isDirectory: true)
        return u
    }()
    nonisolated(unsafe) static var keychainDisabled = false   // tests: simulate a signer without Keychain access

    static func set(_ v: String?, _ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if !keychainDisabled { SecItemDelete(q as CFDictionary) }
        let file = fallbackDir.appendingPathComponent(account)
        guard let v, !v.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        var ok = false
        if !keychainDisabled {
            var add = q
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess && keychainGet(account) == v
        }
        if ok { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var dir = fallbackDir; try? dir.setResourceValues(rv)
        try? Data(v.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func get(_ account: String) -> String? {
        if !keychainDisabled, let v = keychainGet(account) { return v }
        return (try? Data(contentsOf: fallbackDir.appendingPathComponent(account))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The user's own Telegram API credentials (my.telegram.org → API development tools). Never bundled.
struct TDCredentials: Equatable {
    var apiId: String
    var apiHash: String
    var isValid: Bool { Int(apiId) != nil && apiHash.count == 32 && apiHash.allSatisfy(\.isHexDigit) }
    static func load() -> TDCredentials? {
        guard let i = Keychain.get("api_id"), let h = Keychain.get("api_hash") else { return nil }
        return TDCredentials(apiId: i, apiHash: h)
    }
    func save() { Keychain.set(apiId, "api_id"); Keychain.set(apiHash, "api_hash") }
    /// Clears api_id / api_hash only. The database key stays as long as the local TDLib database exists
    /// (it is removed together with the database on 退出登录 / 重置).
    static func clear() { Keychain.set(nil, "api_id"); Keychain.set(nil, "api_hash") }
    /// Random key for TDLib's local database encryption. Created once and reused on every start —
    /// a new key would make TDLib unable to open the existing session database.
    static var databaseKey: String {
        if let k = Keychain.get("db_key") { return k }
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let k = b.map { String(format: "%02x", $0) }.joined()
        Keychain.set(k, "db_key")
        return k
    }
    static func clearDatabaseKey() { Keychain.set(nil, "db_key") }
}

enum TDAuthState: Equatable {
    case unavailable(String)
    case needsCredentials
    case idle            // credentials saved, TDLib not started yet
    case starting
    case waitPhone
    case waitCode(String)
    case waitPassword(String)
    case ready(String)
    case loggingOut
    case closed
    case failed(String)
    var label: String {
        switch self {
        case .unavailable(let m): m
        case .needsCredentials: "未填写 api_id / api_hash"
        case .idle: "未启动"
        case .starting: "正在启动 / 恢复登录…"
        case .waitPhone: "请输入手机号"
        case .waitCode(let h): "请输入验证码" + (h.isEmpty ? "" : "（\(h)）")
        case .waitPassword(let h): "请输入两步验证密码" + (h.isEmpty ? "" : "（提示：\(h)）")
        case .ready(let u): "已登录" + (u.isEmpty ? "" : " \(u)")
        case .loggingOut: "正在退出…"
        case .closed: "TDLib 已关闭"
        case .failed(let m): "出错：\(m)"
        }
    }
    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var isStarting: Bool { self == .starting }
}

struct TDChat: Identifiable, Hashable { var id: Int64; var title: String; var isChannel: Bool; var unread: Int }

/// A public channel resolved through TDLib (`searchPublicChat` + `getSupergroup`).
struct TDChannelInfo: Hashable {
    var chatId: Int64
    var title: String
    var memberCount: Int = 0
    /// Telegram's restriction text for this account / platform (empty = none).
    var restriction: String = ""
    var hasSensitiveContent = false
}

enum TDError: LocalizedError, Equatable {
    case notLoggedIn
    case restricted(String, String)      // channel, reason
    case privateChannel(String)
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "未登录 TDLib"
        case .restricted(let c, let why):
            "@\(c) 对当前账号受限" + (why.isEmpty ? "" : "：\(why)") + "。如果是敏感内容限制：在 TDLib 登录页打开「显示敏感内容」（账号允许时可用），或在 Telegram 官方 App/网页 设置 → 隐私与安全 → 敏感内容 打开「显示敏感内容」（iOS 官方客户端需在 web.telegram.org 或桌面版设置），然后回来刷新。"
        case .privateChannel(let c): "@\(c) 是私有频道或你没有访问权限（CHANNEL_PRIVATE），需要先用这个账号加入。"
        case .notFound(let c): "TDLib 找不到 @\(c)（用户名不存在或已更改）"
        }
    }
}

/// What the app needs from TDLib. A concrete engine wraps TDLibKit (`TDLibKitEngine`) when that package is linked.
protocol TDEngine: TDFileStreamSource {
    var onState: ((TDAuthState) -> Void)? { get set }
    func start(_ c: TDCredentials, dir: URL, dbKey: String) async throws
    func sendPhone(_ phone: String) async throws
    func sendCode(_ code: String) async throws
    func sendPassword(_ pw: String) async throws
    func logOut() async throws
    /// Joined channels / groups (main chat list).
    func chats(limit: Int) async throws -> [TDChat]
    /// `searchPublicChat` + `getSupergroup` (restriction info).
    func resolve(username: String) async throws -> TDChannelInfo
    /// Newest first; `from` = TDLib message id to continue below (0 = latest). Posts are attributed to `channel`.
    func history(chat: Int64, channel: String, from: Int64, limit: Int) async throws -> [TGPost]
    /// `searchChatMessages`.
    func search(chat: Int64, channel: String, query: String, from: Int64, limit: Int) async throws -> [TGPost]
    /// Sends `/start <payload>` to a bot as the user and returns the bot's replies (waits up to `timeout`).
    func startBot(username: String, payload: String, timeout: TimeInterval) async throws -> [TGPost]
    /// Downloads a TDLib file id; returns a local path.
    func download(fileId: Int32) async throws -> URL
    /// `getOption can_ignore_sensitive_content_restrictions` / `ignore_sensitive_content_restrictions`.
    func sensitiveContent() async -> (canChange: Bool, enabled: Bool)
    func setSensitiveContent(_ on: Bool) async throws
}

enum TDEngineFactory {
    /// nil when this build does not link a TDLib engine.
    static func make() -> TDEngine? {
        #if DEBUG
        if let m = TDMockEngine.fromEnvironment() { return m }
        #endif
        #if canImport(TDLibKit)
        return TDLibKitEngine()
        #else
        return nil
        #endif
    }
    static var available: Bool {
        #if DEBUG
        if TDMockEngine.environmentMode != nil { return true }
        #endif
        #if canImport(TDLibKit)
        return true
        #else
        return false
        #endif
    }
}

/// TDLib message ids are server ids << 20 (for server-side messages). Feed posts use server ids, the same
/// ids the web preview uses, so both sources merge into one channel timeline.
enum TDMsgId {
    static func server(_ td: Int64) -> Int { Int(td >> 20) }
    static func td(_ server: Int) -> Int64 { Int64(server) << 20 }
}

/// App-facing TDLib session (settings page, restricted / private channel reading, bot deep links).
///
/// Session persistence: the TDLib database lives in Application Support/tdlib (db + files), message / chat /
/// file databases are on, the encryption key is created once (Keychain, file fallback), and `bootstrap()`
/// (called at app launch) restarts TDLib with the saved api_id / api_hash whenever a local database exists,
/// so TDLib reports `authorizationStateReady` on its own. Only the explicit 「退出登录」 / 「重置本地会话」
/// buttons delete the database.
@MainActor
final class TDLibService: ObservableObject {
    static let shared = TDLibService()
    @Published private(set) var state: TDAuthState = .idle
    @Published private(set) var chats: [TDChat] = []
    @Published private(set) var sensitive: (canChange: Bool, enabled: Bool) = (false, false)
    @Published private var engine: TDEngine? = nil
    private let makeEngine: () -> TDEngine?
    let baseDir: URL
    @Published private var explicitLogout = false
    @Published private var restarts = 0
    @Published private var resolved: [String: TDChannelInfo] = [:]

    init(baseDir: URL? = nil, makeEngine: @escaping () -> TDEngine? = TDEngineFactory.make, available: Bool = TDEngineFactory.available) {
        self.baseDir = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tdlib", isDirectory: true)
        self.makeEngine = makeEngine
        #if DEBUG
        if baseDir == nil, ProcessInfo.processInfo.environment["STV_TD_RESET"] == "1" {   // UI tests: clean slate
            try? FileManager.default.removeItem(at: self.baseDir)
            TDCredentials.clear(); TDCredentials.clearDatabaseKey()
            UserDefaults.standard.set(false, forKey: "stv.tdlib.loggedIn")
        }
        #endif
        if !available { state = .unavailable("本构建未内置 TDLib 引擎") }
        else if TDCredentials.load() == nil { state = .needsCredentials }
        else { state = .idle }
        if available, Self.hasLocalSession(self.baseDir), TDCredentials.load()?.isValid == true { state = .starting }
    }

    var credentials: TDCredentials? { TDCredentials.load() }

    /// Saved credentials; DEBUG `STV_TD_MOCK=ready` runs use a dummy pair (never saved, not anyone's real id).
    private var effectiveCredentials: TDCredentials? {
        if let c = TDCredentials.load(), c.isValid { return c }
        #if DEBUG
        if TDMockEngine.environmentMode == .ready { return TDCredentials(apiId: "1", apiHash: String(repeating: "0", count: 32)) }
        #endif
        return nil
    }

    /// Persistent location (Application Support, excluded from iCloud backup). Never tmp / Caches.
    var databaseDir: URL {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var u = baseDir; try? u.setResourceValues(rv)
        return baseDir
    }

    /// A TDLib database exists → there may be a logged-in session to restore.
    static func hasLocalSession(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("db/td.binlog").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("db/td_test.binlog").path)
            || UserDefaults.standard.bool(forKey: "stv.tdlib.loggedIn")
    }
    var hasLocalSession: Bool { Self.hasLocalSession(baseDir) }

    func saveCredentials(_ c: TDCredentials) {
        c.save()
        if case .needsCredentials = state { state = .idle }
    }

    /// App launch: silently restore a saved session (no network login, no messages sent).
    func bootstrap() async {
        #if DEBUG
        if TDMockEngine.environmentMode == .ready, engine == nil { await start(); return }
        #endif
        guard engine == nil, hasLocalSession, TDCredentials.load()?.isValid == true else {
            if state == .starting { state = .idle }
            return
        }
        await start()
    }

    /// Starts the engine. With an existing database TDLib goes straight to `authorizationStateReady`.
    func start() async {
        guard let c = effectiveCredentials else { state = .needsCredentials; return }
        guard engine == nil else { return }
        guard let e = makeEngine() else { state = .unavailable("本构建未内置 TDLib 引擎"); return }
        engine = e
        explicitLogout = false
        e.onState = { [weak self] s in Task { @MainActor in self?.apply(s) } }
        state = .starting
        do { try await e.start(c, dir: databaseDir, dbKey: TDCredentials.databaseKey) }
        catch { state = .failed(error.localizedDescription); engine = nil }
    }

    private func apply(_ s: TDAuthState) {
        switch s {
        case .ready:
            UserDefaults.standard.set(true, forKey: "stv.tdlib.loggedIn")
            restarts = 0
            state = s
            Task { await refreshSensitive() }
        case .closed:
            // TDLib closed (logOut finished, or an internal error). Drop the dead client; restart unless
            // the user logged out on purpose.
            engine = nil; resolved = [:]
            if explicitLogout || restarts >= 2 { state = TDCredentials.load() == nil ? .needsCredentials : .idle }
            else { restarts += 1; Task { await start() } }
        case .waitPhone:
            // A database without a session: forget the "logged in" hint.
            UserDefaults.standard.set(false, forKey: "stv.tdlib.loggedIn")
            state = s
        default:
            state = s
        }
    }

    /// Waits while a launch-time restore is in flight (≤ timeout). Returns whether TDLib is ready.
    func waitUntilSettled(timeout: TimeInterval = 12) async -> Bool {
        let start = Date()
        while state.isStarting, Date().timeIntervalSince(start) < timeout { try? await Task.sleep(for: .milliseconds(200)) }
        return state.isReady
    }

    func submit(phone: String) async { await run { try await $0.sendPhone(phone) } }
    func submit(code: String) async { await run { try await $0.sendCode(code) } }
    func submit(password: String) async { await run { try await $0.sendPassword(password) } }

    /// Explicit 「退出登录」 only (never called from view lifecycle). Ends the session on Telegram's side and
    /// deletes the local database + its key.
    func logOut() async {
        explicitLogout = true
        state = .loggingOut
        if let e = engine { try? await e.logOut() }
        engine = nil; chats = []; resolved = [:]
        wipeLocal()
    }

    /// Recovery when the local database can't be opened (e.g. the key was lost by a re-sign). Local only.
    func resetLocalSession() {
        explicitLogout = true
        engine = nil; chats = []; resolved = [:]
        wipeLocal()
    }

    private func wipeLocal() {
        try? FileManager.default.removeItem(at: baseDir)
        TDCredentials.clearDatabaseKey()
        UserDefaults.standard.set(false, forKey: "stv.tdlib.loggedIn")
        state = TDCredentials.load() == nil ? .needsCredentials : .idle
    }

    func loadChats() async { guard let e = engine, state.isReady else { return }; chats = (try? await e.chats(limit: 200)) ?? [] }

    private func ready() throws -> TDEngine {
        guard let e = engine, state.isReady else { throw TDError.notLoggedIn }
        return e
    }

    /// Public channel by username (cached per session).
    func channel(_ username: String) async throws -> TDChannelInfo {
        let key = username.lowercased()
        if let r = resolved[key] { return r }
        let r = try await ready().resolve(username: username)
        resolved[key] = r
        return r
    }

    /// Joined-chat history (TDChatView). `before` = server message id of the oldest post shown (0 = newest).
    func history(_ chat: Int64, channel: String, before: Int) async throws -> [TGPost] {
        try await ready().history(chat: chat, channel: channel, from: before == 0 ? 0 : TDMsgId.td(before), limit: 30)
    }
    func search(_ chat: Int64, channel: String, _ q: String, before: Int = 0) async throws -> [TGPost] {
        try await ready().search(chat: chat, channel: channel, query: q, from: before == 0 ? 0 : TDMsgId.td(before), limit: 30)
    }

    /// Feed page for a public channel read through TDLib (restricted web preview / web failure fallback).
    /// Returns posts newest-first and the cursor for the next older page (nil at the start).
    func channelPage(_ username: String, before: Int?, query: String? = nil) async throws -> (info: TDChannelInfo, posts: [TGPost], before: Int?) {
        let info = try await channel(username)
        let e = try ready()
        let from = before.map(TDMsgId.td) ?? 0
        let posts: [TGPost]
        if let q = query, !q.isEmpty { posts = try await e.search(chat: info.chatId, channel: username, query: q, from: from, limit: 30) }
        else { posts = try await e.history(chat: info.chatId, channel: username, from: from, limit: 30) }
        if posts.isEmpty, before == nil, !info.restriction.isEmpty { throw TDError.restricted(username, info.restriction) }
        return (info, posts, posts.isEmpty ? nil : posts.map(\.msgId).min())
    }

    /// Only called from an explicit user tap on a bot deep link.
    func startBot(_ link: TGBotLink) async throws -> [TGPost] {
        try await ready().startBot(username: link.bot, payload: link.payload, timeout: 20)
    }

    /// Local file for a `tdfile://<id>` media reference (downloads through TDLib).
    /// `userDownload`: the 「下载」 button — the full file, and streaming leaves that download alone.
    func file(_ ref: String, userDownload: Bool = false) async throws -> URL {
        if state.isStarting { _ = await waitUntilSettled() }
        guard let id = TDFileRef(ref)?.id else { throw ProviderError.invalid(ref) }
        let e = try ready()
        if userDownload { TDFullDownloads.shared.begin(id) }
        defer { if userDownload { TDFullDownloads.shared.end(id) } }
        return try await e.download(fileId: id)
    }

    /// TDLib file access for streaming playback (waits for a restoring session).
    func streamSource() async throws -> TDFileStreamSource {
        if state.isStarting { _ = await waitUntilSettled() }
        return try ready()
    }

    func refreshSensitive() async {
        guard let e = engine, state.isReady else { return }
        sensitive = await e.sensitiveContent()
    }

    /// User-initiated only (TDLib login page / restricted-channel banner). Mirrors Telegram's account
    /// setting 「显示敏感内容」 and is only possible when Telegram allows it for this account.
    func setSensitive(_ on: Bool) async throws {
        try await ready().setSensitiveContent(on)
        resolved = [:]
        await refreshSensitive()
    }

    private func run(_ f: (TDEngine) async throws -> Void) async {
        guard let e = engine else { state = .failed("TDLib 未启动"); return }
        do { try await f(e) } catch { state = .failed(error.localizedDescription) }
    }

    #if DEBUG
    /// Tests: inject an engine directly.
    func _testInstall(_ e: TDEngine) { engine = e; e.onState = { [weak self] s in Task { @MainActor in self?.apply(s) } } }
    #endif
}
