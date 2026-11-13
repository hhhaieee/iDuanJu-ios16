#if DEBUG
import Foundation

/// DEBUG-only stand-in for TDLib (unit + UI tests; no network, no Telegram account).
/// It mimics TDLib's persistence contract: a "session" exists only when `<dir>/db/td.binlog` was written by a
/// completed login **with the same database key**; starting again over that directory goes straight to ready.
/// `STV_TD_MOCK=ready` → logged in at once; `STV_TD_MOCK=session` → behaves like a fresh TDLib (phone → code).
final class TDMockEngine: TDEngine, @unchecked Sendable {
    var onState: ((TDAuthState) -> Void)?
    enum Mode: String { case ready, session }
    let mode: Mode
    private(set) var dir: URL?
    private var key = ""
    private(set) var logOutCalls = 0
    private(set) var startCalls = 0
    var sensitiveAllowed = true
    private var sensitiveOn = false
    /// Channels that report a restriction until sensitive content is enabled.
    var restrictedUsernames: Set<String> = ["restrictedsample"]

    init(mode: Mode) { self.mode = mode }

    static var environmentMode: Mode? { ProcessInfo.processInfo.environment["STV_TD_MOCK"].flatMap(Mode.init(rawValue:)) }
    static func fromEnvironment() -> TDMockEngine? { environmentMode.map(TDMockEngine.init(mode:)) }

    private var binlog: URL? { dir?.appendingPathComponent("db/td.binlog") }

    func start(_ c: TDCredentials, dir: URL, dbKey: String) async throws {
        startCalls += 1
        self.dir = dir; key = dbKey
        onState?(.starting)
        try? await Task.sleep(for: .milliseconds(150))
        if mode == .ready { writeSession(); onState?(.ready("测试账号")); return }
        if let b = binlog, let saved = try? String(contentsOf: b, encoding: .utf8) {
            if saved == "session:" + dbKey { onState?(.ready("测试账号")) }
            else { onState?(.failed("本地会话数据库无法用当前密钥打开（401 Wrong database encryption key）。请点「重置本地会话」后重新登录。")) }
        } else { onState?(.waitPhone) }
    }

    private func writeSession() {
        guard let b = binlog else { return }
        try? FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ("session:" + key).write(to: b, atomically: true, encoding: .utf8)
    }

    func sendPhone(_ phone: String) async throws { onState?(.waitCode("已发送到 \(phone)")) }
    func sendCode(_ code: String) async throws {
        guard code == "12345" else { throw ProviderError.invalid("PHONE_CODE_INVALID") }
        writeSession(); onState?(.ready("测试账号"))
    }
    func sendPassword(_ pw: String) async throws { writeSession(); onState?(.ready("测试账号")) }
    func logOut() async throws {
        logOutCalls += 1
        if let d = dir { try? FileManager.default.removeItem(at: d.appendingPathComponent("db")) }
        onState?(.loggingOut); onState?(.closed)
    }
    func chats(limit: Int) async throws -> [TDChat] { [TDChat(id: -1001, title: "示例私有频道", isChannel: true, unread: 0)] }

    func resolve(username: String) async throws -> TDChannelInfo {
        let restricted = restrictedUsernames.contains(username.lowercased()) && !sensitiveOn
        return TDChannelInfo(chatId: -100_000 - Int64(abs(username.lowercased().hashValue % 9999)), title: "TDLib · \(username)", memberCount: 1234,
                             restriction: restricted ? "This channel can't be displayed because it was used to spread pornographic content." : "",
                             hasSensitiveContent: restricted)
    }

    /// 45 synthetic posts (ids 300…256), colour placeholder images only; #290 is an ad sample, #295 a 3-photo album.
    static func all(_ channel: String) -> [TGPost] {
        let colours = ["3d5a80", "ee6c4d", "98c1d9", "6a994e", "bc4749", "8338ec"]
        return (256...300).reversed().map { id in
            var p = TGPost(channel: channel, msgId: id)
            p.date = Date(timeIntervalSince1970: 1_793_000_000 + TimeInterval(id * 600))
            p.text = "TDLib 示例帖 #\(id)（模拟数据，用于验证受限频道走 TDLib）"
            p.views = "\(id)"
            if id % 3 == 0 { p.media = [TGMedia(kind: .photo, thumb: "fixture://\(colours[id % colours.count])", link: "https://t.me/\(channel)/\(id)")] }
            if id == 295 { p.media = (0..<3).map { TGMedia(kind: .photo, thumb: "fixture://\(colours[$0])", link: "https://t.me/\(channel)/\(id + $0)") } }
            if id == 297 { p.media = [TGMedia(kind: .video, thumb: "fixture://264653", video: "tdfile://97", duration: 42, link: "https://t.me/\(channel)/297")] }
            if id == 290 {
                p.text = "#推广 每日博彩返水 加群领取 👉 https://promo.example.com/x"
                p.links = ["https://promo.example.com/x"]
                p.buttons = [TGButton(text: "立即加入", url: "https://promo.example.com/join")]
            }
            return p
        }
    }

    func history(chat: Int64, channel: String, from: Int64, limit: Int) async throws -> [TGPost] {
        if restrictedUsernames.contains(channel.lowercased()) && !sensitiveOn { return [] }   // TDLib hides restricted content
        let before = from == 0 ? Int.max : TDMsgId.server(from)
        return Array(Self.all(channel).filter { $0.msgId < before }.prefix(limit))
    }

    func search(chat: Int64, channel: String, query: String, from: Int64, limit: Int) async throws -> [TGPost] {
        if restrictedUsernames.contains(channel.lowercased()) && !sensitiveOn { return [] }
        let before = from == 0 ? Int.max : TDMsgId.server(from)
        return Array(Self.all(channel).filter { $0.msgId < before && $0.text.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    func startBot(username: String, payload: String, timeout: TimeInterval) async throws -> [TGPost] { [] }

    func download(fileId: Int32) async throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tdmock-\(fileId).bin")
        try Data(repeating: 0, count: 1024).write(to: u)
        return u
    }

    // Streaming: instantly "downloaded" zero bytes (UI flows only; byte-level tests use their own source).
    func fileState(_ id: Int32) async throws -> TDFileState { TDFileState(size: 1024, expectedSize: 1024, completed: true, path: "") }
    func requestDownload(_ id: Int32, offset: Int, limit: Int, priority: Int) async throws {}
    func downloadedPrefix(_ id: Int32, offset: Int) async throws -> Int { max(0, 1024 - offset) }
    func readPart(_ id: Int32, offset: Int, count: Int) async throws -> Data { Data(count: max(0, min(count, 1024 - offset))) }
    func cancelDownload(_ id: Int32) async {}

    func sensitiveContent() async -> (canChange: Bool, enabled: Bool) { (sensitiveAllowed, sensitiveOn) }
    func setSensitiveContent(_ on: Bool) async throws {
        guard sensitiveAllowed else { throw ProviderError.unsupported("400 Option can't be set") }
        sensitiveOn = on
    }
}
#endif
