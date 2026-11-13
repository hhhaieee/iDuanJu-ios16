import SwiftUI
import UniformTypeIdentifiers

/// 我的 → 插件：已安装插件、添加（网址 / 文件 / 粘贴）、订阅、内置推荐、苹果 CMS 采集站、检查更新。
struct PluginsView: View {
    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var cms = CMSStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var pending: PendingInstall?
    @State private var updates: [PendingInstall] = []
    @State private var busy: String?
    @State private var message: String?
    @State private var showURL = false
    @State private var urlText = ""
    @State private var showPaste = false
    @State private var showFile = false
    @State private var showSub = false
    @State private var subText = ""
    @State private var showCMS = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("已安装（\(store.visiblePlugins.count)）") {
                    if store.visiblePlugins.isEmpty {
                        Text("还没有插件。可以从下面的网址 / 文件 / 订阅添加，或安装内置推荐。").font(.subheadline)
                            .foregroundStyle(STVTheme.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(store.visiblePlugins) { p in
                        NavigationLink { PluginDetailView(id: p.id) } label: { pluginRow(p) }.buttonStyle(.plain)
                            .accessibilityIdentifier("plugins.row.\(p.id)")
                        if p.id != store.visiblePlugins.last?.id { Divider().overlay(STVTheme.text.opacity(0.06)).padding(.leading, 48) }
                    }
                }
                if hiddenAdult > 0 {
                    note("另有 \(hiddenAdult) 个成人插件已隐藏：在「片源管理」解锁后显示。")
                }
                group("添加插件") {
                    action("从网址添加", "link", id: "plugins.add.url") { urlText = ""; showURL = true }
                    action("从文件导入（.idjplugin）", "doc.badge.plus", id: "plugins.add.file") { showFile = true }
                    action("粘贴插件内容", "doc.on.clipboard", id: "plugins.add.paste") { showPaste = true }
                    action(busy == "update" ? "正在检查更新…" : "检查更新", "arrow.triangle.2.circlepath", id: "plugins.update") { await checkUpdates() }
                }
                ForEach(updates) { u in
                    Button { pending = u } label: {
                        HStack { Image(systemName: "arrow.up.circle.fill").foregroundStyle(STVTheme.accent)
                            Text("\(u.manifest.name) 可更新到 \(u.manifest.version)").foregroundStyle(STVTheme.text); Spacer()
                            Text("查看权限变化").font(.caption).foregroundStyle(STVTheme.accent) }.padding(14)
                    }.buttonStyle(.plain).background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16)
                }
                group("订阅") {
                    ForEach(store.subscriptions) { s in subscriptionBlock(s) }
                    action("添加订阅地址", "plus.circle", id: "plugins.sub.add") { subText = ""; showSub = true }
                    if !store.subscriptions.isEmpty {
                        action(busy == "subs" ? "正在刷新…" : "刷新全部订阅", "arrow.clockwise", id: "plugins.sub.refresh") {
                            busy = "subs"; await store.refreshSubscriptions(); busy = nil
                        }
                    }
                }
                group("采集站（苹果 CMS）") {
                    ForEach(cms.visibleSites) { s in cmsRow(s) }
                    action("添加采集站", "server.rack", id: "plugins.cms.add") { showCMS = true }
                }
                note("采集站使用内置的苹果 CMS v10 适配器（?ac=list / ?ac=detail），不运行任何脚本；只播放线路里的 m3u8 / mp4 直链，接口需支持 https。")
                if !recommended.isEmpty {
                    group("推荐插件（App 内置）") {
                        ForEach(recommended, id: \.manifest.id) { b in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.manifest.name).foregroundStyle(STVTheme.text)
                                    Text(b.manifest.description ?? "").font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(2)
                                }
                                Spacer()
                                if store.plugin(b.manifest.id) != nil { Text("已安装").font(.caption).foregroundStyle(STVTheme.secondary) }
                                else {
                                    Button("安装") { prepare { try PluginInstaller.prepare(bundle: b.data, origin: "内置：" + b.name) } }
                                        .buttonStyle(.bordered).tint(STVTheme.accent).accessibilityIdentifier("plugins.bundled.\(b.name)")
                                }
                            }.padding(14)
                        }
                    }
                } else if !PluginInstaller.bundled().isEmpty {
                    note("App 内置了 \(PluginInstaller.bundled().count) 个漫画插件（成人内容），在「片源管理」打开「成人漫画源」后才会显示在这里。")
                }
                note("插件在独立沙箱里运行：没有 eval、不能访问未声明的域名和本机 / 局域网地址，每个插件的 cookie 与存储互相隔离，接触不到 Telegram、红果账号和钥匙串。所有插件结果都会过滤未成年人相关内容。")
                if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent).padding(.horizontal, 16).accessibilityIdentifier("plugins.message") }
            }.padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy == "prepare" { ProgressView("正在校验插件…").padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .sheet(item: $pending) { p in
            PluginConsentSheet(pending: p) { ok in
                pending = nil
                guard ok else { return }
                do {
                    try store.commit(p)
                    updates.removeAll { $0.manifest.id == p.manifest.id }
                    message = "已安装 \(p.manifest.name) \(p.manifest.version)"
                } catch { message = error.localizedDescription }
            }
        }
        .alert("插件网址", isPresented: $showURL) {
            TextField("https://…/manifest.json 或 .idjplugin", text: $urlText).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("下一步") { interpret(urlText) }
        } message: { Text("支持 manifest.json、.idjplugin 或订阅列表链接") }
        .alert("订阅地址", isPresented: $showSub) {
            TextField("https://…/plugins.json", text: $subText).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("添加") { Task { do { try await store.addSubscription(subText); message = "已添加订阅" } catch { message = error.localizedDescription } } }
        }
        .sheet(isPresented: $showPaste) { PasteSheet { text in showPaste = false; if let text { interpret(text) } } }
        .sheet(isPresented: $showCMS) { AddCMSSheet { showCMS = false; if let m = $0 { message = m } } }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .data, .plainText, .item]) { r in
            guard case let .success(url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: url), d.count < 4 << 20 else { message = "无法读取文件"; return }
            prepare { try PluginInstaller.prepare(bundle: d, origin: "文件：" + url.lastPathComponent) }
        }
        .accessibilityIdentifier("plugins.root")
        #if DEBUG
        .task { if ProcessInfo.processInfo.environment["STV_PLUGIN_CONSENT_DEMO"] == "1", pending == nil { pending = DebugPlugins.demoPending(update: true) } }
        #endif
    }

    private var hiddenAdult: Int { store.plugins.count - store.visiblePlugins.count }

    /// Bundled plugins offered for install; adult ones only behind the 成人漫画源 switch.
    private var recommended: [(name: String, manifest: PluginManifest, data: Data)] {
        PluginInstaller.bundled().filter { !$0.manifest.adult || ($0.manifest.type == .comic ? gate.showAdultManga : gate.unlocked) }
    }

    private func prepare(_ work: @escaping () async throws -> PendingInstall) {
        busy = "prepare"; message = nil
        Task {
            do { let p = try await Task.detached { try await work() }.value; pending = p }
            catch { message = error.localizedDescription }
            busy = nil
        }
    }

    private func interpret(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        busy = "prepare"; message = nil
        Task {
            do {
                switch try await Task.detached { try await PluginInstaller.interpret(t) }.value {
                case .plugin(let p): pending = p
                case .subscription(let u): try await store.addSubscription(u); message = "这是订阅列表，已添加到「订阅」"
                }
            } catch { message = error.localizedDescription }
            busy = nil
        }
    }

    private func checkUpdates() async {
        busy = "update"; message = nil
        updates = await store.checkUpdates()
        busy = nil
        message = updates.isEmpty ? "所有插件都是最新版本" : "\(updates.count) 个插件可更新"
    }

    private func pluginRow(_ p: InstalledPlugin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.manifest.type == .comic ? "book.closed" : "puzzlepiece.extension").frame(width: 24)
                .foregroundStyle(p.enabled ? STVTheme.accent : STVTheme.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.manifest.name).foregroundStyle(STVTheme.text)
                    badge(p.manifest.type.label)
                    if p.manifest.adult { badge("18+") }
                }
                Text(p.disabledReason ?? "v\(p.manifest.version) · \(p.manifest.author.name) · \(p.enabled ? "已启用" : "已停用")")
                    .font(.caption).foregroundStyle(p.disabledReason == nil ? STVTheme.secondary : STVTheme.accentWarm).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { p.enabled }, set: { store.setEnabled(p.id, $0) })).labelsHidden()
                .accessibilityIdentifier("plugins.toggle.\(p.id)")
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary)
        }.padding(14).contentShape(Rectangle())
    }

    @ViewBuilder private func subscriptionBlock(_ s: PluginSubscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? s.url : s.name).foregroundStyle(STVTheme.text)
                    Text(s.error ?? s.url).font(.caption2).foregroundStyle(s.error == nil ? STVTheme.secondary : STVTheme.accentWarm).lineLimit(1)
                }
                Spacer()
                Button(role: .destructive) { store.removeSubscription(s.url) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            ForEach(s.plugins.filter { !($0.adult ?? true) || gate.unlocked }) { e in
                HStack {
                    Text(e.name).font(.subheadline).foregroundStyle(STVTheme.text)
                    if e.adult ?? true { badge("18+") }
                    Spacer()
                    if let installed = store.plugin(e.id) {
                        Text(e.version.map { PluginManifest.compare($0, installed.manifest.version) > 0 ? "可更新 \($0)" : "已安装" } ?? "已安装")
                            .font(.caption).foregroundStyle(STVTheme.secondary)
                    } else {
                        Button("安装") { prepare { try await PluginInstaller.prepare(manifestURL: e.manifest, origin: "订阅：" + s.url) } }
                            .buttonStyle(.bordered).tint(STVTheme.accent)
                    }
                }
            }
            ForEach(s.cms.filter { !($0.adult ?? false) || gate.unlocked }) { c in
                HStack {
                    Image(systemName: "server.rack").font(.caption)
                    Text(c.name).font(.subheadline).foregroundStyle(STVTheme.text)
                    Spacer()
                    if cms.sites.contains(where: { $0.api == (try? CMSStore.normalize(c.api)) }) { Text("已添加").font(.caption).foregroundStyle(STVTheme.secondary) }
                    else {
                        Button("添加") {
                            Task { do { try await cms.add(name: c.name, api: c.api, adult: c.adult ?? false, origin: "订阅：" + s.url); message = "已添加采集站 \(c.name)" }
                                   catch { message = error.localizedDescription } }
                        }.buttonStyle(.bordered).tint(STVTheme.accent)
                    }
                }
            }
        }.padding(14)
    }

    private func cmsRow(_ s: CMSSite) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").frame(width: 24).foregroundStyle(s.enabled ? STVTheme.accent : STVTheme.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { Text(s.name).foregroundStyle(STVTheme.text); if s.adult { badge("18+") } }
                Text("\(URL(string: s.api)?.host ?? s.api) · \(s.categories.count) 个分类").font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { s.enabled }, set: { cms.setEnabled(s.key, $0) })).labelsHidden()
            Menu {
                Toggle("成人内容（需片源管理解锁）", isOn: Binding(get: { s.adult }, set: { cms.setAdult(s.key, $0) }))
                Button("删除", role: .destructive) { cms.remove(s.key) }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(STVTheme.secondary) }
        }.padding(14).accessibilityIdentifier("plugins.cms.\(s.key)")
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(STVTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2).background(STVTheme.glass, in: Capsule())
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    private func action(_ t: String, _ icon: String, id: String, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: {
            HStack { Image(systemName: icon).frame(width: 24); Text(t); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary) }
                .foregroundStyle(STVTheme.text).padding(14).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

/// Install / update consent: what the plugin is, which domains it may reach, extra powers, and the diff on update.
struct PluginConsentSheet: View {
    let pending: PendingInstall
    let done: (Bool) -> Void
    private var m: PluginManifest { pending.manifest }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(m.name).font(.title3.weight(.bold)); if m.adult { Text("18+").font(.caption.weight(.bold)).foregroundStyle(.red) } }
                        Text("\(m.type.label) · v\(m.version) · 作者 \(m.author.name)").font(.subheadline).foregroundStyle(.secondary)
                        if let d = m.description, !d.isEmpty { Text(d).font(.subheadline) }
                        Text("来源：\(pending.origin)").font(.caption).foregroundStyle(.secondary)
                        Label(pending.signedBy == nil ? "未签名（无法确认作者身份）" : "已验证作者签名", systemImage: pending.signedBy == nil ? "exclamationmark.shield" : "checkmark.shield")
                            .font(.caption).foregroundStyle(pending.signedBy == nil ? .orange : .green)
                    }
                }
                if let diff = pending.diff, pending.isUpdate {
                    Section("更新：从 v\(pending.existing?.manifest.version ?? "?") 到 v\(m.version) 的权限变化") {
                        if diff.isEmpty { Text("权限没有变化").foregroundStyle(.secondary) }
                        ForEach(diff.addedHTTP, id: \.self) { Label("新增网络域名 \($0)", systemImage: "plus.circle").foregroundStyle(.orange) }
                        ForEach(diff.addedMedia, id: \.self) { Label("新增图片/视频域名 \($0)", systemImage: "plus.circle").foregroundStyle(.orange) }
                        ForEach(diff.removedHTTP + diff.removedMedia, id: \.self) { Label("移除 \($0)", systemImage: "minus.circle").foregroundStyle(.secondary) }
                        ForEach(diff.flags, id: \.self) { Label($0, systemImage: $0.hasPrefix("新增") ? "exclamationmark.triangle" : "minus.circle") }
                    }
                }
                Section("允许访问的网站（只能访问这些域名）") {
                    ForEach(m.httpDomains, id: \.self) { Label($0, systemImage: "globe") }
                }
                if Set(m.mediaDomains) != Set(m.httpDomains) {
                    Section("图片 / 视频地址") { ForEach(m.mediaDomains, id: \.self) { Label($0, systemImage: "photo") } }
                }
                Section("额外能力") {
                    row("Cloudflare 验证（本插件独立的隐藏网页，cookie 不与其他插件共享）", m.allowsCF)
                    row("插件私有存储（≤1MB）", m.allowsStorage)
                    row("请你登录该站点", m.allowsLogin)
                    Text("插件始终不能：eval / 动态代码、访问本机或局域网地址、读取其他插件或 Telegram / 红果 / 钥匙串数据。").font(.caption).foregroundStyle(.secondary)
                }
                Section("脚本") {
                    Text("实现：\(pending.exported.joined(separator: " · "))").font(.caption)
                    Text(pending.fileHash).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .navigationTitle(pending.isUpdate ? "更新插件" : "安装插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done(false) } }
                ToolbarItem(placement: .confirmationAction) { Button(pending.isUpdate ? "更新" : "安装") { done(true) }.accessibilityIdentifier("plugins.consent.install") }
            }
        }
        .accessibilityIdentifier("plugins.consent")
    }

    private func row(_ t: String, _ on: Bool) -> some View {
        Label(t, systemImage: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? .primary : .secondary)
    }
}

private struct PasteSheet: View {
    let done: (String?) -> Void
    @State private var text = ""
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).padding(8)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text("粘贴 .idjplugin 内容（JSON）或插件 / 订阅链接").foregroundStyle(.secondary).padding(14).allowsHitTesting(false) }
                }
                .navigationTitle("粘贴插件").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { done(nil) } }
                    ToolbarItem(placement: .principal) { Button("从剪贴板") { text = UIPasteboard.general.string ?? "" } }
                    ToolbarItem(placement: .confirmationAction) { Button("下一步") { done(text) }.disabled(text.isEmpty) }
                }
        }
    }
}

private struct AddCMSSheet: View {
    let done: (String?) -> Void
    @State private var name = ""
    @State private var api = ""
    @State private var adult = false
    @State private var busy = false
    @State private var error: String?
    @ObservedObject private var gate = SourceGate.shared
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选）", text: $name)
                    TextField("https://…/api.php/provide/vod/", text: $api).textInputAutocapitalization(.never).keyboardType(.URL)
                        .accessibilityIdentifier("cms.api")
                    if gate.unlocked { Toggle("成人内容（隐藏在片源管理之后）", isOn: $adult) }
                } footer: {
                    Text("苹果 CMS v10 采集接口。添加时会请求一次 ?ac=list 验证；http 地址会自动改用 https。")
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .navigationTitle("添加采集站").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("添加") {
                            busy = true; error = nil
                            Task {
                                do { let s = try await CMSStore.shared.add(name: name, api: api, adult: adult); done("已添加采集站 \(s.name)（\(s.categories.count) 个分类）") }
                                catch { self.error = error.localizedDescription }
                                busy = false
                            }
                        }.disabled(api.isEmpty)
                    }
                }
            }
        }
    }
}

/// One installed plugin: switch, settings, domains, data, logs, uninstall.
struct PluginDetailView: View {
    let id: String
    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var askDomain = false
    @State private var confirmUninstall = false
    @State private var message: String?
    @State private var secretDrafts: [String: String] = [:]
    @State private var verify: URL?

    var body: some View {
        Group {
            if let p = store.plugin(id) { content(p) } else { Text("插件已卸载").foregroundStyle(STVTheme.secondary) }
        }
        .navigationTitle(store.plugin(id)?.manifest.name ?? "插件")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
    }

    private func content(_ p: InstalledPlugin) -> some View {
        List {
            Section {
                Toggle("启用", isOn: Binding(get: { p.enabled }, set: { store.setEnabled(id, $0) })).accessibilityIdentifier("plugin.enabled")
                if let r = p.disabledReason { Text(r).font(.caption).foregroundStyle(.orange) }
                LabeledContent("版本", value: p.manifest.version)
                LabeledContent("类型", value: p.manifest.type.label + (p.manifest.adult ? " · 18+" : ""))
                LabeledContent("作者", value: p.manifest.author.name)
                LabeledContent("来源", value: p.origin)
                LabeledContent("签名", value: p.publicKey == nil ? "未签名" : "已固定作者公钥")
            }
            if let settings = p.manifest.settings, !settings.isEmpty {
                Section("设置") {
                    ForEach(settings) { s in settingRow(p, s) }
                }
            }
            Section {
                ForEach(p.manifest.httpDomains, id: \.self) { Label($0, systemImage: "globe") }
                ForEach(p.extraDomains, id: \.self) { d in
                    Label(d + "（你添加的）", systemImage: "globe.badge.chevron.backward")
                        .swipeActions { Button("移除", role: .destructive) { store.removeDomain(id, d) } }
                }
                Button("添加域名…") { newDomain = ""; askDomain = true }
            } header: { Text("可访问的域名") } footer: { Text("站点换了新镜像时，可以在这里手动授权新域名（只允许 example.com 或 *.example.com）。") }
            Section("数据") {
                if p.manifest.allowsCF, let host = p.manifest.httpDomains.first(where: { !$0.hasPrefix("*") }), let u = URL(string: "https://\(host)/") {
                    Button("打开验证页（Cloudflare / 登录）") { verify = u }
                }
                Button("清除 cookie 与存储") { store.clearData(id); message = "已清除" }
                NavigationLink("运行日志") { PluginLogView(id: id) }.accessibilityIdentifier("plugin.logs")
            }
            Section {
                Button("卸载插件", role: .destructive) { confirmUninstall = true }
            }
            if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent) }
        }
        .alert("授权新域名", isPresented: $askDomain) {
            TextField("mirror.example.com", text: $newDomain).textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("授权") { message = store.addDomain(id, newDomain.lowercased()) ? "已授权 \(newDomain)" : "域名格式不对" }
        } message: { Text("插件之后可以访问这个域名（包括图片）。只在你信任这个插件时授权。") }
        .confirmationDialog("卸载后会删除脚本、设置、cookie 和存储", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("卸载", role: .destructive) { store.uninstall(id); dismiss() }
        }
        .sheet(item: Binding(get: { verify.map(VerifyTarget.init) }, set: { verify = $0?.url })) { t in
            PluginVerifySheet(pluginID: id, url: t.url) { verify = nil; Task { await store.importWebCookies(id) } }
        }
    }

    private struct VerifyTarget: Identifiable { let url: URL; var id: String { url.absoluteString } }

    @ViewBuilder private func settingRow(_ p: InstalledPlugin, _ s: PluginManifest.Setting) -> some View {
        switch s.type {
        case "select":
            Picker(s.name, selection: Binding(get: { p.settings[s.key] ?? s.default ?? "" }, set: { store.setSetting(id, s.key, $0) })) {
                ForEach(s.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case "secret":
            HStack {
                SecureField(s.name + (PluginSecrets.get(id, s.key) == nil ? "" : "（已保存）"), text: Binding(get: { secretDrafts[s.key] ?? "" }, set: { secretDrafts[s.key] = $0 }))
                Button("保存") { store.setSetting(id, s.key, secretDrafts[s.key] ?? ""); secretDrafts[s.key] = nil; message = "已保存到钥匙串（插件只看到占位符）" }
            }
        default:
            TextField(s.name, text: Binding(get: { p.settings[s.key] ?? s.default ?? "" }, set: { store.setSetting(id, s.key, $0) }))
        }
    }
}

struct PluginLogView: View {
    let id: String
    @State private var lines: [String] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty { Text("暂无日志").foregroundStyle(STVTheme.secondary) }
                ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, l in
                    Text(l).font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.text).textSelection(.enabled)
                }
            }.padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("运行日志").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem { Button { UIPasteboard.general.string = lines.joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") } } }
        .task { lines = PluginLog.lines(id) }
        .onReceive(NotificationCenter.default.publisher(for: PluginLog.changed)) { _ in lines = PluginLog.lines(id) }
        .accessibilityIdentifier("plugin.logview")
    }
}
