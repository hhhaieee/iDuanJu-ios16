import Foundation
import Combine

/// Subscriptions, cached posts, filter rules and the merged 朋友圈-style feed.
@MainActor
final class TGStore: ObservableObject {
    static let shared = TGStore()

    /// Preset channels the user asked for. Both are adult → hidden until 片源管理 → 成人频道 is on.
    static let presets: [TGChannel] = [
        TGChannel(username: "bhg1232", title: "bhg1232", isAdult: true),
        TGChannel(username: "NudefilmsTV", title: "NudefilmsTV", isAdult: true),
    ]

    @Published private(set) var channels: [TGChannel] = []
    @Published private(set) var posts: [String: [TGPost]] = [:]
    @Published private(set) var cursors: [String: Int] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var rules: [TGRule] = []
    @Published var mode: TGFilterMode = .fold { didSet { saveSettings() } }
    @Published var heuristics = true { didSet { saveSettings() } }
    @Published var lastRefresh: Date? = nil

    private let d = UserDefaults.standard
    private let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("stv-tg", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private init() {
        if let data = d.data(forKey: "stv.tg.channels"), let c = try? JSONDecoder().decode([TGChannel].self, from: data) {
            channels = c
        } else {
            channels = Self.presets
        }
        #if DEBUG
        // UI tests / screenshots: STV_TG_CHANNELS=telegram,durov replaces the subscription list for this run.
        if let e = ProcessInfo.processInfo.environment["STV_TG_CHANNELS"] {
            channels = e.split(separator: ",").map { TGChannel(username: String($0)) }
        }
        if Self.isolated { return }   // fixture runs: in-memory rules / posts only
        #endif
        loadSettings()
        for c in channels { posts[c.id] = load(c.id) }
    }

    /// DEBUG fixture runs never read or write the user's saved rules / cache.
    static var isolated: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["STV_TG_FIXTURE_DIR"] != nil
        #else
        return false
        #endif
    }

    private func loadSettings() {
        if let data = d.data(forKey: "stv.tg.rules"), let r = try? JSONDecoder().decode([TGRule].self, from: data) { rules = r }
        mode = TGFilterMode(rawValue: d.string(forKey: "stv.tg.mode") ?? "") ?? .fold
        heuristics = d.object(forKey: "stv.tg.heuristics") as? Bool ?? true
    }

    // MARK: Visibility

    /// Adult channels only when enabled in 片源管理 and unlocked.
    var visibleChannels: [TGChannel] { channels.filter { !$0.isAdult || SourceGate.shared.showAdultChannels } }
    func channel(_ name: String) -> TGChannel? { channels.first { $0.id == name.lowercased() } }

    // MARK: Subscriptions

    @discardableResult
    func add(_ raw: String, adult: Bool = false) -> String? {
        guard let name = TGChannel.normalize(raw) else { return nil }
        if channel(name) == nil { channels.insert(TGChannel(username: name, isAdult: adult), at: 0); saveChannels() }
        return name
    }

    func remove(_ c: TGChannel) {
        channels.removeAll { $0.id == c.id }
        posts[c.id] = nil; cursors[c.id] = nil; errors[c.id] = nil
        try? FileManager.default.removeItem(at: file(c.id))
        rules.removeAll { $0.channel == c.id }; saveRules()
        saveChannels()
    }

    func update(_ c: TGChannel) {
        guard let i = channels.firstIndex(where: { $0.id == c.id }) else { return }
        channels[i] = c; saveChannels()
    }

    func move(from: IndexSet, to: Int) { channels.move(fromOffsets: from, toOffset: to); saveChannels() }

    // MARK: Loading

    func refresh(_ only: String? = nil) async {
        let targets = visibleChannels.filter { only == nil || $0.id == only!.lowercased() }
        await withTaskGroup(of: Void.self) { g in
            for c in targets { g.addTask { await self.load(c, older: false) } }
        }
        lastRefresh = Date()
    }

    func loadMore(_ only: String? = nil) async {
        let targets = visibleChannels.filter { (only == nil || $0.id == only!.lowercased()) && cursors[$0.id] != nil }
        await withTaskGroup(of: Void.self) { g in
            for c in targets { g.addTask { await self.load(c, older: true) } }
        }
    }

    func hasMore(_ only: String? = nil) -> Bool {
        visibleChannels.contains { (only == nil || $0.id == only!.lowercased()) && cursors[$0.id] != nil }
    }

    /// Where the current cursor of a channel came from (web `?before=` vs TDLib history).
    enum Backend: String { case web, tdlib }
    @Published private(set) var backend: [String: Backend] = [:]
    /// Channels whose last load failed because TDLib is not logged in (banner shows 「去登录 TDLib」).
    @Published private(set) var needsTDLogin: Set<String> = []
    /// Channels TDLib reports as restricted for this account (banner offers 「显示敏感内容」 when allowed).
    @Published private(set) var tdRestricted: Set<String> = []

    /// Restricted web preview → TDLib first (when logged in). Otherwise web first, TDLib as fallback.
    private func load(_ c: TGChannel, older: Bool) async {
        guard !loading.contains(c.id) else { return }
        let before = older ? cursors[c.id] : nil
        if older && before == nil { return }
        loading.insert(c.id); defer { loading.remove(c.id) }
        let td = TDLibService.shared
        if older, backend[c.id] == .tdlib { await loadTD(c, before: before); return }
        if !older, c.previewUnavailable != nil, await td.waitUntilSettled() { await loadTD(c, before: nil); return }
        do {
            let page = try await TGClient.shared.page(c.username, before: before)
            errors[c.id] = nil; needsTDLogin.remove(c.id); tdRestricted.remove(c.id)
            merge(page.posts, into: c.id)
            if older || cursors[c.id] == nil || (posts[c.id]?.count ?? 0) <= page.posts.count { cursors[c.id] = page.before; backend[c.id] = .web }
            if var cur = channel(c.id) {
                if let info = page.info {
                    cur.title = info.title; cur.avatar = info.avatar; cur.subscribers = info.subscribers; cur.about = info.about
                }
                cur.previewUnavailable = nil
                update(cur)
            }
        } catch {
            var webError = error.localizedDescription
            if case .previewDisabled(_, let why)? = error as? TGError, var cur = channel(c.id) {
                cur.previewUnavailable = why
                if let l = try? await TGClient.shared.landing(c.username), !l.title.isEmpty {
                    cur.title = l.title; cur.subscribers = l.subscribers; cur.about = l.about; cur.avatar = l.avatar
                }
                update(cur)
                webError = "@\(c.username) 的网页预览被 Telegram 限制（\(why)）。"
            }
            // Web failed (restricted preview, HTTP error, network) → TDLib if logged in.
            if await td.waitUntilSettled() { await loadTD(c, before: older ? before : nil); return }
            needsTDLogin.insert(c.id)
            errors[c.id] = webError + (channel(c.id)?.previewUnavailable != nil ? "登录 TDLib 后可直接在这里读取。" : "")
        }
    }

    /// TDLib: `searchPublicChat` → `getChatHistory` (paging by message id). Same post model / filters as web.
    private func loadTD(_ c: TGChannel, before: Int?) async {
        do {
            let r = try await TDLibService.shared.channelPage(c.username, before: before)
            errors[c.id] = nil; needsTDLogin.remove(c.id); tdRestricted.remove(c.id)
            merge(r.posts, into: c.id)
            if before != nil || cursors[c.id] == nil || backend[c.id] != .tdlib || (posts[c.id]?.count ?? 0) <= r.posts.count {
                cursors[c.id] = r.before; backend[c.id] = .tdlib
            }
            if var cur = channel(c.id) {
                if cur.title.isEmpty || cur.title == cur.username { cur.title = r.info.title }
                if cur.subscribers.isEmpty, r.info.memberCount > 0 { cur.subscribers = "\(r.info.memberCount) subscribers" }
                update(cur)
            }
        } catch let e as TDError {
            errors[c.id] = e.localizedDescription
            if case .restricted = e { tdRestricted.insert(c.id) }
            if case .notLoggedIn = e { needsTDLogin.insert(c.id) }
        } catch {
            errors[c.id] = "TDLib：" + error.localizedDescription
        }
    }

    func merge(_ new: [TGPost], into id: String) {
        var byId = Dictionary((posts[id] ?? []).map { ($0.msgId, $0) }, uniquingKeysWith: { a, _ in a })
        for p in new { byId[p.msgId] = p }
        let all = byId.values.sorted { $0.msgId > $1.msgId }
        posts[id] = Array(all.prefix(600))
        save(id)
    }

    // MARK: Feed

    struct Entry: Identifiable, Hashable {
        let post: TGPost
        let verdict: TGVerdict
        var id: String { post.id }
    }

    /// Newest first across channels; blocked posts are dropped (hide) or flagged (fold).
    func feed(_ only: String? = nil) -> [Entry] {
        let chans = visibleChannels.filter { only == nil || $0.id == only!.lowercased() }
        let all = chans.flatMap { c in (posts[c.id] ?? []).map { ($0, c) } }
        let sorted = all.sorted { ($0.0.date ?? .distantPast, $0.0.msgId) > ($1.0.date ?? .distantPast, $1.0.msgId) }
        return sorted.compactMap { p, c in
            let v = TGFilter.verdict(p, rules: rules, heuristics: heuristics, channelAdBlock: c.adBlock)
            if v.blocked && mode == .hide { return nil }
            return Entry(post: p, verdict: v)
        }
    }

    func blockedCount(_ only: String? = nil) -> (total: Int, blocked: Int) {
        let chans = visibleChannels.filter { only == nil || $0.id == only!.lowercased() }
        var t = 0, b = 0
        for c in chans { for p in posts[c.id] ?? [] {
            t += 1
            if TGFilter.verdict(p, rules: rules, heuristics: heuristics, channelAdBlock: c.adBlock).blocked { b += 1 }
        } }
        return (t, b)
    }

    // MARK: Search

    /// Local full-text search over cached posts.
    func localSearch(_ q: String, channel only: String? = nil) -> [TGPost] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let terms = t.split(separator: " ").map(String.init)
        return visibleChannels.filter { only == nil || $0.id == only!.lowercased() }
            .flatMap { posts[$0.id] ?? [] }
            .filter { p in
                let hay = p.text + " " + p.buttons.map(\.text).joined(separator: " ") + " " + (p.preview?.title ?? "")
                return terms.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Remote search through `t.me/s/<c>?q=`; returns posts + per-channel cursors for paging.
    func remoteSearch(_ q: String, channel only: String? = nil, cursors: [String: Int]? = nil) async -> (posts: [TGPost], cursors: [String: Int], errors: [String]) {
        let chans = visibleChannels.filter { only == nil || $0.id == only!.lowercased() }
            .filter { cursors == nil || cursors?[$0.id] != nil }
        var out: [TGPost] = [], next: [String: Int] = [:], errs: [String] = []
        // searchChatMessages for channels read through TDLib (restricted preview / web unreachable).
        let tdReady = await TDLibService.shared.waitUntilSettled()
        let useTD: Set<String> = tdReady ? Set(chans.filter { $0.previewUnavailable != nil || backend[$0.id] == .tdlib }.map(\.id)) : []
        await withTaskGroup(of: (String, Result<TGChannelPage, Error>).self) { g in
            for c in chans {
                let before = cursors?[c.id]
                let viaTD = useTD
                g.addTask {
                    do {
                        if viaTD.contains(c.id) {
                            let r = try await TDLibService.shared.channelPage(c.username, before: before, query: q)
                            return (c.id, .success(TGChannelPage(info: nil, posts: r.posts, before: r.before)))
                        }
                        return (c.id, .success(try await TGClient.shared.page(c.username, before: before, query: q)))
                    }
                    catch { return (c.id, .failure(error)) }
                }
            }
            for await (id, r) in g {
                switch r {
                case .success(let p): out += p.posts; if let b = p.before { next[id] = b }
                case .failure(let e): errs.append("@\(id): \(e.localizedDescription)")
                }
            }
        }
        for p in out { merge([p], into: p.channel.lowercased()) }
        return (out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, next, errs)
    }

    // MARK: Rules

    func addRule(_ r: TGRule) {
        guard !rules.contains(where: { $0.kind == r.kind && $0.pattern == r.pattern && $0.channel == r.channel }) else { return }
        rules.insert(r, at: 0); saveRules()
    }
    func removeRules(at o: IndexSet) { rules.remove(atOffsets: o); saveRules() }
    func removeRule(_ r: TGRule) { rules.removeAll { $0.id == r.id }; saveRules() }
    func toggleRule(_ r: TGRule) { if let i = rules.firstIndex(where: { $0.id == r.id }) { rules[i].enabled.toggle(); saveRules() } }

    var exportText: String { TGFilter.export(TGRuleBundle(mode: mode, heuristics: heuristics, rules: rules)) }

    @discardableResult func importText(_ s: String) -> Int {
        guard let b = TGFilter.importRules(s) else { return 0 }
        var n = 0
        for r in b.rules where !rules.contains(where: { $0.kind == r.kind && $0.pattern == r.pattern && $0.channel == r.channel }) {
            rules.append(r); n += 1
        }
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("{") { mode = b.mode; heuristics = b.heuristics }
        saveRules()
        return n
    }

    // MARK: Persistence

    private func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }
    private func load(_ id: String) -> [TGPost]? { (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode([TGPost].self, from: $0) } }
    private func save(_ id: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_TG_FIXTURE_DIR"] != nil { return }
        #endif
        if let data = try? JSONEncoder().encode(posts[id] ?? []) { try? data.write(to: file(id), options: .atomic) }
    }
    private func saveChannels() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_TG_CHANNELS"] != nil { return }
        #endif
        if let data = try? JSONEncoder().encode(channels) { d.set(data, forKey: "stv.tg.channels") }
    }
    private func saveRules() { if Self.isolated { return }; if let data = try? JSONEncoder().encode(rules) { d.set(data, forKey: "stv.tg.rules") } }
    private func saveSettings() { if Self.isolated { return }; d.set(mode.rawValue, forKey: "stv.tg.mode"); d.set(heuristics, forKey: "stv.tg.heuristics") }

    func clearCache() {
        for c in channels { try? FileManager.default.removeItem(at: file(c.id)) }
        posts = [:]; cursors = [:]; backend = [:]
    }
}
