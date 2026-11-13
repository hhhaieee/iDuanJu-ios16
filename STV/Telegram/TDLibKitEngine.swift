#if canImport(TDLibKit)
import Foundation
import TDLibKit

/// TDLib engine (TDLibKit, MIT). Runs only with the user's own api_id / api_hash and only after the user
/// logs in on the TDLib settings page (or a session from that login is restored at launch).
/// Nothing here logs in or sends anything on its own.
final class TDLibKitEngine: TDEngine, @unchecked Sendable {
    var onState: ((TDAuthState) -> Void)?
    private let manager = TDLibClientManager()
    private var client: TDLibClient?
    private var params: (TDCredentials, URL, String)?
    private let lock = NSLock()
    /// chatId → collector for bot replies (`startBot`).
    private var collectors: [Int64: (Message) -> Void] = [:]
    /// Test DC (simulator experiments only; never set in release builds).
    var useTestDc = false

    func start(_ c: TDCredentials, dir: URL, dbKey: String) async throws {
        params = (c, dir, dbKey)
        client = manager.createClient { [weak self] data, client in
            guard let self, let update = try? client.decoder.decode(Update.self, from: data) else { return }
            self.handle(update)
        }
        // Kick TDLib so it emits updateAuthorizationState(waitTdlibParameters).
        _ = try? await client?.getAuthorizationState()
    }

    private func handle(_ u: Update) {
        switch u {
        case .updateAuthorizationState(let s): auth(s.authorizationState)
        case .updateNewMessage(let m):
            lock.lock(); let f = collectors[m.message.chatId]; lock.unlock()
            if !m.message.isOutgoing { f?(m.message) }
        default: break
        }
    }

    private func auth(_ s: AuthorizationState) {
        switch s {
        case .authorizationStateWaitTdlibParameters:
            guard let (c, dir, key) = params, let client else { return }
            Task {
                do {
                    // Persistent dirs (Application Support/tdlib/db, /files), all local databases on, the same
                    // encryption key every start → TDLib restores the session by itself.
                    _ = try await client.setTdlibParameters(
                        apiHash: c.apiHash, apiId: Int(c.apiId), applicationVersion: "1.4", databaseDirectory: dir.appendingPathComponent("db").path,
                        databaseEncryptionKey: Data(key.utf8), deviceModel: "iPhone", filesDirectory: dir.appendingPathComponent("files").path,
                        systemLanguageCode: "zh-hans", systemVersion: "iOS", useChatInfoDatabase: true, useFileDatabase: true,
                        useMessageDatabase: true, useSecretChats: false, useTestDc: useTestDc)
                } catch {
                    let m = Self.msg(error)
                    if m.localizedCaseInsensitiveContains("encryption") || m.localizedCaseInsensitiveContains("wrong") {
                        onState?(.failed("本地会话数据库无法用当前密钥打开（\(m)）。请点「重置本地会话」后重新登录。"))
                    } else { onState?(.failed(m)) }
                }
            }
        case .authorizationStateWaitPhoneNumber: onState?(.waitPhone)
        case .authorizationStateWaitCode(let w): onState?(.waitCode("已发送到 \(w.codeInfo.phoneNumber)"))
        case .authorizationStateWaitPassword(let w): onState?(.waitPassword(w.passwordHint))
        case .authorizationStateReady:
            Task {
                let me = try? await client?.getMe()
                onState?(.ready(me.map { [$0.firstName, $0.lastName].joined(separator: " ").trimmingCharacters(in: .whitespaces) } ?? ""))
            }
        case .authorizationStateLoggingOut, .authorizationStateClosing: onState?(.loggingOut)
        case .authorizationStateClosed: client = nil; onState?(.closed)
        default: onState?(.failed("需要在官方客户端完成的登录步骤（邮箱/注册等）"))
        }
    }

    static func msg(_ e: Swift.Error) -> String {
        if let t = e as? TDLibKit.Error { return "\(t.code) \(t.message)" }
        return e.localizedDescription
    }

    private func c() throws -> TDLibClient {
        guard let client else { throw ProviderError.unsupported("TDLib 未启动") }
        return client
    }

    func sendPhone(_ phone: String) async throws { _ = try await c().setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) }
    func sendCode(_ code: String) async throws { _ = try await c().checkAuthenticationCode(code: code) }
    func sendPassword(_ pw: String) async throws { _ = try await c().checkAuthenticationPassword(password: pw) }
    func logOut() async throws { _ = try await c().logOut() }

    func chats(limit: Int) async throws -> [TDChat] {
        let cl = try c()
        _ = try? await cl.loadChats(chatList: .chatListMain, limit: limit)
        let ids = try await cl.getChats(chatList: .chatListMain, limit: limit).chatIds
        var out: [TDChat] = []
        for id in ids {
            guard let chat = try? await cl.getChat(chatId: id) else { continue }
            var channel = false
            if case .chatTypeSupergroup(let s) = chat.type { channel = s.isChannel } else if case .chatTypeBasicGroup = chat.type {} else { continue }
            out.append(TDChat(id: chat.id, title: chat.title, isChannel: channel, unread: chat.unreadCount))
        }
        return out
    }

    func resolve(username: String) async throws -> TDChannelInfo {
        let cl = try c()
        let chat: Chat
        do { chat = try await cl.searchPublicChat(username: username) }
        catch {
            let m = Self.msg(error)
            if m.contains("CHANNEL_PRIVATE") { throw TDError.privateChannel(username) }
            if m.contains("USERNAME_NOT_OCCUPIED") || m.contains("USERNAME_INVALID") || m.contains("400") { throw TDError.notFound(username) }
            throw error
        }
        var info = TDChannelInfo(chatId: chat.id, title: chat.title)
        if case .chatTypeSupergroup(let s) = chat.type, let sg = try? await cl.getSupergroup(supergroupId: s.supergroupId) {
            info.memberCount = sg.memberCount
            info.restriction = sg.restrictionInfo?.restrictionReason ?? ""
            info.hasSensitiveContent = sg.restrictionInfo?.hasSensitiveContent ?? false
        }
        // Make sure TDLib has the chat open-able (no join, no message sent).
        _ = try? await cl.openChat(chatId: chat.id)
        return info
    }

    func history(chat: Int64, channel: String, from: Int64, limit: Int) async throws -> [TGPost] {
        let cl = try c()
        var r = try await cl.getChatHistory(chatId: chat, fromMessageId: from, limit: limit, offset: 0, onlyLocal: false)
        // TDLib may answer the first call from its local cache with only a few messages; ask once more.
        if (r.messages ?? []).count < 5 {
            if let again = try? await cl.getChatHistory(chatId: chat, fromMessageId: from, limit: limit, offset: 0, onlyLocal: false),
               (again.messages ?? []).count > (r.messages ?? []).count { r = again }
        }
        return Self.posts(r.messages ?? [], channel: channel)
    }

    func search(chat: Int64, channel: String, query: String, from: Int64, limit: Int) async throws -> [TGPost] {
        let r = try await c().searchChatMessages(chatId: chat, filter: .searchMessagesFilterEmpty, fromMessageId: from, limit: limit,
                                                 offset: 0, query: query, senderId: nil, topicId: nil)
        return Self.posts(r.messages, channel: channel)
    }

    func startBot(username: String, payload: String, timeout: TimeInterval) async throws -> [TGPost] {
        let cl = try c()
        let chat = try await cl.searchPublicChat(username: username)
        guard case .chatTypePrivate(let p) = chat.type else { throw ProviderError.invalid("@\(username) 不是机器人") }
        var got: [Message] = []
        let gotLock = NSLock()
        lock.lock(); collectors[chat.id] = { m in gotLock.lock(); got.append(m); gotLock.unlock() }; lock.unlock()
        defer { lock.lock(); collectors[chat.id] = nil; lock.unlock() }
        _ = try await cl.sendBotStartMessage(botUserId: p.userId, chatId: chat.id, parameter: payload)
        // Wait for replies: stop 3 s after the last one, or at `timeout`.
        let start = Date(); var lastCount = 0; var quietSince = Date()
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: .milliseconds(500))
            gotLock.lock(); let n = got.count; gotLock.unlock()
            if n != lastCount { lastCount = n; quietSince = Date() }
            if n > 0 && Date().timeIntervalSince(quietSince) > 3 { break }
        }
        gotLock.lock(); let msgs = got; gotLock.unlock()
        return Self.posts(msgs, channel: username)
    }

    func download(fileId: Int32) async throws -> URL {
        // A streaming window on the same file can re-target TDLib's download and end a synchronous call
        // early; ask again (TDLib keeps what it has) until the whole file is there.
        for _ in 0..<4 {
            let f = try await c().downloadFile(fileId: Int(fileId), limit: 0, offset: 0, priority: 16, synchronous: true)
            if f.local.isDownloadingCompleted, !f.local.path.isEmpty { return URL(fileURLWithPath: f.local.path) }
            try Task.checkCancellation()
        }
        throw ProviderError.upstream("下载未完成")
    }

    // MARK: Streaming (TDFileStreamSource)

    func fileState(_ id: Int32) async throws -> TDFileState {
        let f = try await c().getFile(fileId: Int(id))
        return TDFileState(size: Int(f.size), expectedSize: Int(f.expectedSize), completed: f.local.isDownloadingCompleted, path: f.local.path)
    }

    func requestDownload(_ id: Int32, offset: Int, limit: Int, priority: Int) async throws {
        _ = try await c().downloadFile(fileId: Int(id), limit: Int64(limit), offset: Int64(offset), priority: priority, synchronous: false)
    }

    func downloadedPrefix(_ id: Int32, offset: Int) async throws -> Int {
        Int(try await c().getFileDownloadedPrefixSize(fileId: Int(id), offset: Int64(offset)).size)
    }

    func readPart(_ id: Int32, offset: Int, count: Int) async throws -> Data {
        try await c().readFilePart(count: Int64(count), fileId: Int(id), offset: Int64(offset)).data
    }

    func cancelDownload(_ id: Int32) async {
        _ = try? await client?.cancelDownloadFile(fileId: Int(id), onlyIfPending: false)
    }

    func sensitiveContent() async -> (canChange: Bool, enabled: Bool) {
        guard let cl = client else { return (false, false) }
        func bool(_ name: String) async -> Bool {
            if case .optionValueBoolean(let b)? = try? await cl.getOption(name: name) { return b.value }
            return false
        }
        return (await bool("can_ignore_sensitive_content_restrictions"), await bool("ignore_sensitive_content_restrictions"))
    }

    func setSensitiveContent(_ on: Bool) async throws {
        _ = try await c().setOption(name: "ignore_sensitive_content_restrictions", value: .optionValueBoolean(OptionValueBoolean(value: on)))
    }

    // MARK: Message → feed post

    /// TDLib messages → feed posts in the same model as the web preview. Albums (same media_album_id) become
    /// one post. Media are `tdfile://<file id>` references, fetched lazily through TDLib `downloadFile`
    /// (thumbnails by CoverStore, videos by the player / download manager).
    static func posts(_ ms: [Message], channel: String) -> [TGPost] {
        var out: [TGPost] = []
        var albumIndex: [Int64: Int] = [:]
        for m in ms.sorted(by: { $0.id > $1.id }) {
            let server = m.id % (1 << 20) == 0 ? TDMsgId.server(m.id) : Int(m.id)
            var p = TGPost(channel: channel, msgId: server)
            p.date = Date(timeIntervalSince1970: TimeInterval(m.date))
            p.author = m.authorSignature
            if let v = m.interactionInfo?.viewCount, v > 0 { p.views = v >= 1000 ? String(format: "%.1fK", Double(v) / 1000) : "\(v)" }
            var caption: FormattedText?
            let link = "https://t.me/\(channel)/\(server)"
            switch m.content {
            case .messageText(let t):
                caption = t.text
                if let lp = t.linkPreview { p.preview = TGLinkPreview(site: lp.siteName, title: lp.title, desc: lp.description.text, image: "", url: lp.url) }
            case .messagePhoto(let ph):
                caption = ph.caption
                if let best = ph.photo.sizes.filter({ $0.width <= 1280 }).last ?? ph.photo.sizes.last {
                    p.media = [TGMedia(kind: .photo, thumb: "tdfile://\(best.photo.id)", link: link, spoiler: ph.hasSpoiler)]
                }
            case .messageVideo(let v):
                caption = v.caption
                let thumb = v.video.thumbnail.map { "tdfile://\($0.file.id)" } ?? ""
                let ref = TDFileRef(id: Int32(v.video.video.id), mime: v.video.mimeType, streaming: v.video.supportsStreaming,
                                    size: Int(v.video.video.size > 0 ? v.video.video.size : v.video.video.expectedSize))
                p.media = [TGMedia(kind: .video, thumb: thumb, video: ref.string, duration: v.video.duration, link: link, spoiler: v.hasSpoiler)]
            case .messageAnimation(let a):
                caption = a.caption
                let thumb = a.animation.thumbnail.map { "tdfile://\($0.file.id)" } ?? ""
                p.media = [TGMedia(kind: .gif, thumb: thumb, video: TDFileRef(id: Int32(a.animation.animation.id), mime: a.animation.mimeType,
                                                                                    size: Int(a.animation.animation.size)).string, duration: a.animation.duration, link: link)]
            case .messageDocument(let d):
                caption = d.caption
                p.text = "📎 " + d.document.fileName
            default:
                p.text = "[暂不支持的消息类型，可在 Telegram 中查看]"
            }
            if let caption {
                p.text = p.text.isEmpty ? caption.text : p.text + "\n" + caption.text
                p.links = urls(caption)
            }
            if case .replyMarkupInlineKeyboard(let k)? = m.replyMarkup {
                for row in k.rows { for b in row {
                    if case .inlineKeyboardButtonTypeUrl(let u) = b.type { p.buttons.append(TGButton(text: b.text, url: u.url)) }
                } }
            }
            // Album: fold into the first (newest) post of the group.
            if m.mediaAlbumId.rawValue != 0, let i = albumIndex[m.mediaAlbumId.rawValue] {
                out[i].media = p.media + out[i].media
                if out[i].text.isEmpty { out[i].text = p.text }
                out[i].links += p.links; out[i].buttons += p.buttons
                out[i].msgId = min(out[i].msgId, p.msgId)
                continue
            }
            if m.mediaAlbumId.rawValue != 0 { albumIndex[m.mediaAlbumId.rawValue] = out.count }
            out.append(p)
        }
        return out
    }

    static func urls(_ t: FormattedText) -> [String] {
        let ns = t.text as NSString
        return t.entities.compactMap { e in
            switch e.type {
            case .textEntityTypeTextUrl(let u): return u.url
            case .textEntityTypeUrl:
                // TDLib offsets are UTF-16 code units, same as NSString.
                guard e.offset >= 0, e.offset + e.length <= ns.length else { return nil }
                let s = ns.substring(with: NSRange(location: e.offset, length: e.length))
                return s.lowercased().hasPrefix("http") ? s : "https://" + s
            default: return nil
            }
        }
    }
}
#endif
