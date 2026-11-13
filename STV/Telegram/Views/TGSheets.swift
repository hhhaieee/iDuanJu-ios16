import SwiftUI
import UniformTypeIdentifiers

/// 长按「加入屏蔽…」: pick suggested words / domains from the post, scope global or this channel.
struct TGBlockSheet: View {
    let post: TGPost
    @ObservedObject private var store = TGStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int> = []
    @State private var custom = ""
    @State private var channelOnly = false
    private var suggestions: [TGRule] { TGFilter.suggestions(post) }

    var body: some View {
        NavigationStack {
            Form {
                Section("从这条消息提取") {
                    if suggestions.isEmpty { Text("没有可提取的词或链接").foregroundStyle(.secondary) }
                    ForEach(suggestions.indices, id: \.self) { i in
                        Button {
                            if picked.contains(i) { picked.remove(i) } else { picked.insert(i) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(i) ? "checkmark.circle.fill" : "circle")
                                Text(suggestions[i].kind.label).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                                Text(suggestions[i].pattern).lineLimit(1)
                            }
                        }.accessibilityIdentifier("block.suggest.\(i)")
                    }
                }
                Section("自定义关键词") {
                    TextField("关键词（以 re: 开头为正则，domain: 为域名）", text: $custom)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("block.custom")
                }
                Section { Toggle("只对 @\(post.channel) 生效", isOn: $channelOnly) }
            }
            .navigationTitle("加入屏蔽").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let scope = channelOnly ? post.channel.lowercased() : nil
                        for i in picked { var r = suggestions[i]; r.channel = scope; store.addRule(r) }
                        if let b = TGFilter.importRules(custom) { for var r in b.rules { r.channel = scope; store.addRule(r) } }
                        dismiss()
                    }.disabled(picked.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("block.add")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Bot deep link (`t.me/<bot>?start=<payload>`): only on explicit tap, only with a TDLib session.
struct TGBotSheet: View {
    let link: TGBotLink
    @ObservedObject private var td = TDLibService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var replies: [TGPost] = []
    @State private var running = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("@\(link.bot)").font(.title3.weight(.bold))
                    Text("参数：\(link.payload)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if td.state.isReady {
                        Text("将以你的 Telegram 账号向该机器人发送 /start \(link.payload)，并在这里显示它的回复。不会自动批量发送。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(running ? "等待回复…" : "发送 /start") {
                            running = true; error = nil
                            Task {
                                do { replies = try await td.startBot(link) } catch { self.error = error.localizedDescription }
                                running = false
                            }
                        }.buttonStyle(.borderedProminent).disabled(running)
                    } else {
                        Text("以账号身份与机器人交互需要先在「频道 → 管理 → TDLib 登录」登录（\(td.state.label)）。也可以直接在 Telegram 里打开。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("在 Telegram 中打开") {
                        if let u = link.tgURL { openURL(u) { ok in if !ok, let w = link.webURL { openURL(w) } } }
                    }.buttonStyle(.bordered).accessibilityIdentifier("bot.openInTelegram")
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    ForEach(replies) { p in TGPostCard(post: p, channel: nil) }
                }.padding(20)
            }
            .navigationTitle("机器人链接").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 频道管理: subscribe, presets, per-channel adult / ad-block, t.me access address, rules, TDLib.
struct TGManageView: View {
    @ObservedObject private var store = TGStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var addText = ""
    @State private var addAdult = false
    @State private var base = UserDefaults.standard.string(forKey: TGClient.baseKey) ?? ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("频道用户名 / t.me 链接", text: $addText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("tg.add.field")
                    Button("订阅") { add() }.disabled(addText.isEmpty).accessibilityIdentifier("tg.add.button")
                }
                Toggle("标记为成人频道", isOn: $addAdult)
                if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent) }
            } header: { Text("添加公开频道") } footer: {
                Text("通过 t.me/s/<频道> 网页预览读取，无需登录。关闭了网页预览的频道只能用 TDLib 登录后读取。")
            }
            Section("已订阅（\(store.channels.count)）") {
                ForEach(store.channels) { c in
                    if c.isAdult && !gate.showAdultChannels {
                        HStack { Image(systemName: "lock"); Text("成人频道（已隐藏）").foregroundStyle(.secondary) }
                    } else {
                        channelRow(c)
                    }
                }
                .onDelete { idx in idx.map { store.channels[$0] }.forEach(store.remove) }
                .onMove { store.move(from: $0, to: $1) }
            }
            Section("过滤") {
                NavigationLink(value: Route.tgRules) {
                    HStack { Text("屏蔽规则与广告过滤"); Spacer(); Text("\(store.rules.count) 条").foregroundStyle(.secondary) }
                }.accessibilityIdentifier("tg.rules")
            }
            Section {
                TextField("https://t.me", text: $base).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit { UserDefaults.standard.set(base, forKey: TGClient.baseKey) }
                Button("保存访问地址") { UserDefaults.standard.set(base, forKey: TGClient.baseKey); message = "已保存" }
            } header: { Text("t.me 访问地址") } footer: {
                Text("t.me 在部分网络不可达时，可填自建的 t.me 反向代理（路径与 t.me 相同）。留空 = https://t.me")
            }
            Section("账号（私有频道 / 机器人）") {
                NavigationLink(value: Route.tdlib) {
                    HStack { Text("TDLib 登录"); Spacer(); Text(TDLibService.shared.state.label).foregroundStyle(.secondary).lineLimit(1) }
                }.accessibilityIdentifier("tg.tdlib")
                NavigationLink(value: Route.downloads) { Text("下载管理") }
            }
            Section {
                Button("清空频道缓存", role: .destructive) { store.clearCache(); message = "已清空缓存" }
            }
        }
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("频道管理").navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.manageView")
    }

    private func add() {
        guard let n = store.add(addText, adult: addAdult) else { message = "无效的频道名"; return }
        addText = ""; message = "已订阅 @\(n)"
        Task { await store.refresh(n) }
    }

    private func channelRow(_ c: TGChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c.displayName).font(.body.weight(.semibold))
                Text("@" + c.username).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !c.subscribers.isEmpty { Text(c.subscribers).font(.caption).foregroundStyle(.secondary) }
            }
            if let why = c.previewUnavailable { Text(why).font(.caption).foregroundStyle(STVTheme.accentWarm) }
            HStack(spacing: 16) {
                Toggle("成人", isOn: Binding(get: { c.isAdult }, set: { var x = c; x.isAdult = $0; store.update(x) })).fixedSize()
                Toggle("去广告", isOn: Binding(get: { c.adBlock }, set: { var x = c; x.adBlock = $0; store.update(x) })).fixedSize()
                    .accessibilityIdentifier("tg.adblock.\(c.id)")
            }.font(.caption).toggleStyle(.switch).controlSize(.mini)
        }
        .accessibilityIdentifier("tg.channel.\(c.id)")
    }
}

/// 屏蔽规则: mode, built-in heuristics, rules (global / per channel), import / export.
struct TGRulesView: View {
    @ObservedObject private var store = TGStore.shared
    @State private var kind: TGRule.Kind = .keyword
    @State private var pattern = ""
    @State private var scope = ""
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Picker("屏蔽方式", selection: Binding(get: { store.mode }, set: { store.mode = $0 })) {
                    ForEach(TGFilterMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("内置广告识别", isOn: Binding(get: { store.heuristics }, set: { store.heuristics = $0 }))
                let c = store.blockedCount()
                Text("当前缓存 \(c.total) 条，命中 \(c.blocked) 条").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rules.stats")
            } footer: {
                Text("内置识别：#广告/#推广 等标记、博彩/引流类词、外链按钮、纯推广链接（短文 + 外链/邀请链接）、置顶推广。每个频道可在频道管理里单独关闭。")
            }
            Section("添加规则") {
                Picker("类型", selection: $kind) { ForEach(TGRule.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                TextField(kind == .domain ? "example.com" : kind == .regex ? "正则表达式" : "关键词", text: $pattern)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("rules.pattern")
                Picker("范围", selection: $scope) {
                    Text("全部频道").tag("")
                    ForEach(store.channels) { Text("@" + $0.username).tag($0.id) }
                }
                Button("添加") {
                    if kind == .regex, (try? NSRegularExpression(pattern: pattern)) == nil { message = "正则无效"; return }
                    store.addRule(TGRule(kind: kind, pattern: pattern.trimmingCharacters(in: .whitespaces), channel: scope.isEmpty ? nil : scope))
                    pattern = ""; message = "已添加"
                }.disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("rules.add")
                if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent) }
            }
            Section("规则（\(store.rules.count)）") {
                ForEach(store.rules) { r in
                    HStack {
                        Image(systemName: r.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(r.enabled ? STVTheme.accent : .secondary)
                            .onTapGesture { store.toggleRule(r) }
                        VStack(alignment: .leading) {
                            Text(r.pattern).lineLimit(1)
                            Text(r.kind.label + " · " + (r.channel.map { "@" + $0 } ?? "全部频道")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { store.removeRules(at: $0) }
            }
            Section("导入 / 导出") {
                ShareLink(item: store.exportText, preview: SharePreview("i短剧 频道屏蔽规则")) { Label("导出（JSON）", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.string = store.exportText; message = "已复制到剪贴板" } label: { Label("复制规则 JSON", systemImage: "doc.on.doc") }
                Button {
                    let n = store.importText(UIPasteboard.general.string ?? ""); message = n > 0 ? "已导入 \(n) 条" : "剪贴板里没有可识别的规则"
                } label: { Label("从剪贴板导入", systemImage: "doc.on.clipboard") }
                Button { importing = true } label: { Label("从文件导入", systemImage: "folder") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("屏蔽规则").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { r in
            guard let u = try? r.get() else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let n = store.importText((try? String(contentsOf: u, encoding: .utf8)) ?? "")
            message = "已导入 \(n) 条"
        }
    }
}

/// Search: online (t.me/s ?q=, paged) or local full-text over cached posts; one channel or all.
struct TGSearchView: View {
    @State var channel: String?
    @ObservedObject private var store = TGStore.shared
    @State private var q = ""
    @State private var online = true
    @State private var results: [TGPost] = []
    @State private var cursors: [String: Int] = [:]
    @State private var errors: [String] = []
    @State private var searching = false
    @State private var searched = false
    @State private var viewer: ChannelFeedView.ViewerPayload?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchField(text: $q, placeholder: "搜索频道消息", onSubmit: run).padding(.horizontal, 16).padding(.top, 8)
                    .accessibilityIdentifier("tgsearch.field")
                HStack {
                    Picker("", selection: $online) { Text("在线").tag(true); Text("本地缓存").tag(false) }.pickerStyle(.segmented).frame(width: 170)
                    Spacer()
                    Menu {
                        Button("全部订阅") { channel = nil }
                        ForEach(store.visibleChannels) { c in Button(c.displayName) { channel = c.id } }
                    } label: { Label(channel.flatMap { store.channel($0)?.displayName } ?? "全部订阅", systemImage: "line.3.horizontal.decrease.circle").font(.subheadline) }
                }.padding(16)
                ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(STVTheme.accentWarm).padding(.horizontal, 16) }
                if searched && results.isEmpty && !searching {
                    Text("没有结果").foregroundStyle(STVTheme.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(results) { p in
                    TGPostCard(post: p, channel: store.channel(p.channel), actions: TGActions(
                        openImages: { p, i in viewer = .init(urls: p.media.filter { $0.kind == .photo }.map(\.thumb), index: 0) },
                        playVideo: { p, i in if let s = TGVideoProvider.series(p, media: i, channel: store.channel(p.channel)) { Router.push(.play(s, 0)) } },
                        download: { p, i in TGDownloads.shared.enqueue(post: p, media: i, channel: store.channel(p.channel)) }))
                    Divider().overlay(STVTheme.text.opacity(0.06))
                }
                if searching { ProgressView().frame(maxWidth: .infinity).padding() }
                else if online && !cursors.isEmpty && !results.isEmpty {
                    Button("加载更多") { more() }.frame(maxWidth: .infinity).padding().accessibilityIdentifier("tgsearch.more")
                }
            }.padding(.bottom, 30)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("搜索频道").navigationBarTitleDisplayMode(.inline)
        .onChange(of: online) { _ in if searched { run() } }
        .onChange(of: channel) { _ in if searched { run() } }
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
    }

    private func run() {
        let t = q.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        searched = true; errors = []; cursors = [:]
        if !online { results = store.localSearch(t, channel: channel); return }
        searching = true
        Task {
            let r = await store.remoteSearch(t, channel: channel)
            results = r.posts; cursors = r.cursors; errors = r.errors; searching = false
        }
    }

    private func more() {
        searching = true
        Task {
            let r = await store.remoteSearch(q, channel: channel, cursors: cursors)
            let seen = Set(results.map(\.id))
            results += r.posts.filter { !seen.contains($0.id) }
            cursors = r.cursors; searching = false
        }
    }
}

/// 下载管理: queue, progress, pause/resume, delete, offline play, save to Photos.
struct DownloadsView: View {
    @ObservedObject private var dl = TGDownloads.shared
    @State private var viewer: ChannelFeedView.ViewerPayload?
    @State private var message: String?

    var body: some View {
        List {
            if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent) }
            if dl.visible.isEmpty {
                Text("还没有下载。在频道消息上点 ⬇︎ 或长按 → 下载。").foregroundStyle(.secondary)
            }
            ForEach(dl.visible) { d in row(d) }
                .onDelete { idx in idx.map { dl.visible[$0] }.forEach(dl.delete) }
            if dl.totalBytes > 0 {
                Text("已下载 \(ByteCountFormatter.string(fromByteCount: dl.totalBytes, countStyle: .file))，保存在本机「文稿/Downloads」").font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("下载管理").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.view")
    }

    private func row(_ d: TGDownload) -> some View {
        HStack(spacing: 12) {
            CoverView(url: d.state == .done && d.kind == .photo ? (d.localURL?.absoluteString ?? d.thumb) : d.thumb, corner: 8)
                .frame(width: 72, height: 54)
                .overlay { if d.kind == .video { Image(systemName: "play.fill").foregroundStyle(.white) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(d.title).font(.subheadline).lineLimit(1)
                Text(d.channel).font(.caption).foregroundStyle(.secondary)
                switch d.state {
                case .done: Text("已完成 · " + ByteCountFormatter.string(fromByteCount: d.received, countStyle: .file)).font(.caption).foregroundStyle(.green)
                case .failed: Text(d.error ?? "失败").font(.caption).foregroundStyle(.red).lineLimit(2)
                default:
                    ProgressView(value: d.progress).tint(STVTheme.accent)
                    Text(stateText(d)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            actions(d)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.row.\(d.id)")
    }

    private func stateText(_ d: TGDownload) -> String {
        let got = ByteCountFormatter.string(fromByteCount: d.received, countStyle: .file)
        let tot = d.expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: d.expected, countStyle: .file) : ""
        switch d.state { case .queued: return "排队中"; case .paused: return "已暂停 · \(got)\(tot)"; default: return "\(got)\(tot) · \(Int(d.progress * 100))%" }
    }

    @ViewBuilder private func actions(_ d: TGDownload) -> some View {
        HStack(spacing: 14) {
            switch d.state {
            case .running, .queued:
                Button { dl.pause(d) } label: { Image(systemName: "pause.circle") }.accessibilityLabel("暂停").accessibilityIdentifier("downloads.pause.\(d.id)")
            case .paused, .failed:
                Button { dl.resume(d) } label: { Image(systemName: "arrow.clockwise.circle") }.accessibilityLabel("继续").accessibilityIdentifier("downloads.resume.\(d.id)")
            case .done:
                Button { open(d) } label: { Image(systemName: d.kind == .video ? "play.circle" : "photo") }.accessibilityLabel("离线打开").accessibilityIdentifier("downloads.open.\(d.id)")
                Button {
                    guard let u = d.localURL else { return }
                    Task {
                        do { try await TGDownloads.saveToPhotos(u, video: d.kind == .video); message = "已保存到相册" }
                        catch { message = error.localizedDescription }
                    }
                } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("保存到相册").accessibilityIdentifier("downloads.save.\(d.id)")
            }
        }
        .font(.title3).buttonStyle(.borderless).foregroundStyle(STVTheme.accent)
    }

    private func open(_ d: TGDownload) {
        if d.kind == .video { Router.push(.play(TGVideoProvider.series(download: d), 0)) }
        else if let u = d.localURL { viewer = .init(urls: [u.absoluteString], index: 0) }
    }
}

/// TDLib login: the user's own api_id / api_hash (Keychain), phone → code → 2FA password.
/// Leaving this page never logs out; only 「退出登录」 (with confirmation) ends the session.
struct TDLibSettingsView: View {
    @ObservedObject private var td = TDLibService.shared
    @State private var apiId = TDCredentials.load()?.apiId ?? ""
    @State private var apiHash = TDCredentials.load()?.apiHash ?? ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var message: String?
    @State private var confirmLogout = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(td.state.label).accessibilityIdentifier("tdlib.state")
                    if td.state.isStarting { Spacer(); ProgressView() }
                }
                if case .unavailable = td.state {
                    Text("当前安装包没有链接 TDLib 原生库（TDLibKit）。频道的公开网页预览、搜索、下载不受影响；私有频道、搜索私有消息和机器人 /start 需要带 TDLib 的构建。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if case .failed = td.state, td.hasLocalSession {
                    Button("重置本地会话（只删本机数据，需重新登录）", role: .destructive) { td.resetLocalSession() }
                        .accessibilityIdentifier("tdlib.reset")
                }
            } header: { Text("状态") } footer: {
                Text("登录状态保存在本机（应用支持目录 + 钥匙串），杀掉 App 重进会自动恢复。")
            }
            Section {
                TextField("api_id（数字）", text: $apiId).keyboardType(.numberPad).accessibilityIdentifier("tdlib.apiId")
                SecureField("api_hash（32 位十六进制）", text: $apiHash).textInputAutocapitalization(.never).accessibilityIdentifier("tdlib.apiHash")
                Button("保存到钥匙串") {
                    let c = TDCredentials(apiId: apiId.trimmingCharacters(in: .whitespaces), apiHash: apiHash.trimmingCharacters(in: .whitespaces).lowercased())
                    guard c.isValid else { message = "api_id 应为数字，api_hash 应为 32 位十六进制"; return }
                    td.saveCredentials(c); message = "已保存（仅本机钥匙串）"
                }.accessibilityIdentifier("tdlib.saveCreds")
                if !td.state.isReady {
                    Button("清除凭据", role: .destructive) { TDCredentials.clear(); apiId = ""; apiHash = ""; message = "已清除" }
                }
            } header: { Text("API 凭据") } footer: {
                Text("在 my.telegram.org → API development tools 用你自己的账号申请。应用不内置任何人的 api_id / api_hash。")
            }
            if TDEngineFactory.available {
                Section("登录") {
                    switch td.state {
                    case .idle, .needsCredentials, .failed, .closed:
                        Button("启动 TDLib") { Task { await td.start() } }.accessibilityIdentifier("tdlib.start")
                    case .starting:
                        Text("正在连接…").foregroundStyle(.secondary)
                    case .waitPhone:
                        TextField("+86 手机号", text: $phone).keyboardType(.phonePad).accessibilityIdentifier("tdlib.phone")
                        Button("发送验证码") { Task { await td.submit(phone: phone) } }.disabled(phone.isEmpty).accessibilityIdentifier("tdlib.sendPhone")
                    case .waitCode:
                        TextField("验证码", text: $code).keyboardType(.numberPad).accessibilityIdentifier("tdlib.code")
                        Button("登录") { Task { await td.submit(code: code) } }.accessibilityIdentifier("tdlib.sendCode")
                    case .waitPassword:
                        SecureField("两步验证密码", text: $password)
                        Button("提交") { Task { await td.submit(password: password) } }
                    case .ready:
                        Button("刷新已加入的频道/群") { Task { await td.loadChats() } }
                        ForEach(td.chats) { c in NavigationLink(value: Route.tdChat(c.id, c.title)) { Text((c.isChannel ? "📢 " : "👥 ") + c.title) } }
                        Button("退出登录", role: .destructive) { confirmLogout = true }.accessibilityIdentifier("tdlib.logout")
                    default: EmptyView()
                    }
                }
                if td.state.isReady {
                    Section {
                        Toggle("显示敏感内容", isOn: Binding(get: { td.sensitive.enabled }, set: { on in
                            Task { do { try await td.setSensitive(on) } catch { message = "Telegram 不允许此账号更改：\(error.localizedDescription)" } }
                        })).disabled(!td.sensitive.canChange).accessibilityIdentifier("tdlib.sensitive")
                    } header: { Text("受限频道") } footer: {
                        Text(td.sensitive.canChange
                             ? "对应 Telegram 账号设置「显示敏感内容」（会同步到你的账号）。受限频道读不到时打开它。"
                             : "Telegram 暂不允许此账号在第三方客户端更改。请在 web.telegram.org 或桌面版 设置 → 隐私与安全 → 敏感内容 打开「显示敏感内容」，然后回来刷新。")
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent) }
        }
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("TDLib 登录").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tdlib.view")
        // Entering the page restores a saved session if launch-time bootstrap hasn't yet.
        .task { if case .idle = td.state, td.hasLocalSession { await td.start() } else { await td.refreshSensitive() } }
        .confirmationDialog("退出 Telegram 登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录并删除本机会话", role: .destructive) { Task { await td.logOut() } }
        } message: { Text("会在 Telegram 端结束这个登录设备，下次需要重新收验证码。只是离开页面或关掉 App 不需要退出。") }
    }
}

/// A joined (private) channel / group read through TDLib: history with paging + searchChatMessages.
struct TDChatView: View {
    let chatId: Int64
    let title: String
    @ObservedObject private var td = TDLibService.shared
    @State private var posts: [TGPost] = []
    @State private var q = ""
    @State private var error: String?
    @State private var loading = false
    @State private var viewer: ChannelFeedView.ViewerPayload?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchField(text: $q, placeholder: "搜索本频道（searchChatMessages）", onSubmit: { Task { await search() } }).padding(16)
                if let error { Text(error).font(.caption).foregroundStyle(STVTheme.accentWarm).padding(.horizontal, 16) }
                ForEach(posts) { p in
                    TGPostCard(post: p, channel: TGChannel(username: title), actions: TGActions(
                        openImages: { p, _ in viewer = .init(urls: p.media.filter { $0.kind == .photo }.map(\.thumb), index: 0) },
                        playVideo: { p, i in
                            guard let v = p.media[i].video else { return }
                            Router.push(.play(HGSeries(source: .telegram, seriesId: "td/\(p.channel)/\(p.msgId)/\(i)", title: title, cover: p.media[i].thumb,
                                                       duration: p.media[i].duration, orientation: "landscape", page: v), 0))
                        }))
                    Divider().overlay(STVTheme.text.opacity(0.06))
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                else if !posts.isEmpty && q.isEmpty {
                    Color.clear.frame(height: 20).onAppear { Task { await more() } }
                }
            }
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await more() }
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
    }

    private func more() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await td.history(chatId, channel: "td\(chatId)", before: posts.last?.msgId ?? 0)
            let seen = Set(posts.map(\.id)); posts += r.filter { !seen.contains($0.id) }
        } catch { self.error = error.localizedDescription }
    }

    private func search() async {
        if q.isEmpty { posts = []; await more(); return }
        loading = true; defer { loading = false }
        do { posts = try await td.search(chatId, channel: "td\(chatId)", q) } catch { self.error = error.localizedDescription }
    }
}
