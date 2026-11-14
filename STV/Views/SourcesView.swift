import SwiftUI

/// 我的 → 片源管理. 红果 is always on; 黄果 (18+) and long-video sites are opt-in and can be
/// hidden behind Face ID (`SourceGate`).
struct SourcesView: View {
    @ObservedObject private var gate = SourceGate.shared
    @ObservedObject private var proxy = ProxySettings.shared
    @State private var message: String?
    @State private var bufferMB = BufferSettings.megabytes
    @State private var cacheBytes: Int64 = 0
    @State private var adStrip = HLSAdFilter.enabled
    @State private var engineKind = PlayerEngineSettings.preferred

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if gate.lockEnabled && !gate.unlocked {
                    lockedCard
                } else {
                    group("内置") {
                        builtinRow(.hongguo, "play.rectangle.on.rectangle")
                    }
                    group("首页片源顺序") {
                        NavigationLink(value: Route.homeSourceOrder) {
                            HStack { label("调整首页标签顺序", "arrow.up.arrow.down", sub: "拖动调整红果、黄果、AI剧及各片源在首页顶部标签的排列顺序"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain).accessibilityIdentifier("sources.homeOrder")
                    }
                    group("网络代理") {
                        Toggle(isOn: $proxy.enabled) {
                            label("启用代理", "network", sub: "网页抓取、封面、接口请求与本地视频转发都走该代理；改动后需重启 App 生效")
                        }.padding(14).accessibilityIdentifier("proxy.enabled")
                        if proxy.enabled {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("代理类型", selection: $proxy.kind) {
                                    ForEach(ProxySettings.Kind.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier("proxy.kind")
                                HStack(spacing: 10) {
                                    Text("服务器").font(.subheadline).foregroundStyle(STVTheme.secondary).frame(width: 52, alignment: .leading)
                                    TextField("127.0.0.1", text: $proxy.host)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .keyboardType(.URL).foregroundStyle(STVTheme.text)
                                        .accessibilityIdentifier("proxy.host")
                                }
                                HStack(spacing: 10) {
                                    Text("端口").font(.subheadline).foregroundStyle(STVTheme.secondary).frame(width: 52, alignment: .leading)
                                    TextField("7890", text: $proxy.port)
                                        .keyboardType(.numberPad).foregroundStyle(STVTheme.text)
                                        .accessibilityIdentifier("proxy.port")
                                }
                            }.padding(14)
                        }
                    }
                    group("18+ 片源（默认隐藏）") {
                        Toggle(isOn: Binding(get: { gate.huangguo }, set: { gate.setHuangguo($0) })) {
                            label(DramaSource.huangguo.label, "film.stack", sub: "18+ · 视频站 / App 源 / AI 站；开启后出现在「发现」「搜索」和 AI剧")
                        }.padding(14).accessibilityIdentifier("sources.huangguo")
                        ForEach(Sites.all.filter(\.isAdult)) { s in siteRow(s) }
                    }
                    group("插件与采集站") {
                        NavigationLink(value: Route.plugins) {
                            HStack { label("插件管理", "puzzlepiece.extension", sub: "JS 插件、订阅、苹果 CMS 采集站；成人插件在这里解锁后才显示"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain).accessibilityIdentifier("sources.plugins")
                    }
                    group("频道与漫画（默认隐藏）") {
                        Toggle(isOn: Binding(get: { gate.adultChannels }, set: { gate.setAdultChannels($0) })) {
                            label("成人 Telegram 频道", "paperplane", sub: "预置 @bhg1232 / @NudefilmsTV 及你标记为成人的频道；开启后才出现在「频道」")
                        }.padding(14).accessibilityIdentifier("sources.adultChannels")
                        Toggle(isOn: Binding(get: { gate.adultManga }, set: { gate.setAdultManga($0) })) {
                            label("成人漫画源", "book.closed", sub: "控制成人漫画插件（内置推荐：Manga18fx / Komikindo / 18comic）；插件结果一律过滤未成年人相关标签")
                        }.padding(14)
                    }
                    Text("开启后，该站会出现在「发现」顶部标签和「搜索」结果来源里；关闭后收藏、观看记录仍保留在本机，只是不再显示。所有请求由本机直连站点，部分站点需要先在内置浏览器完成一次 Cloudflare 验证。")
                        .font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
                    group("播放设置") {
                        VStack(alignment: .leading, spacing: 10) {
                            label("长视频预缓冲", "arrow.down.circle", sub: "播放时从当前位置向后预先下载到本机，弱网下拖动/连续观看更流畅；短剧仍按预加载后续 3–4 集")
                            Picker("长视频预缓冲", selection: $bufferMB) {
                                ForEach(BufferSettings.options, id: \.self) { Text(BufferSettings.label($0)).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("settings.prebuffer")
                            .onChange(of: bufferMB) { v in BufferSettings.megabytes = v }
                        }.padding(14)
                        Toggle(isOn: Binding(get: { adStrip }, set: { adStrip = $0; HLSAdFilter.enabled = $0 })) {
                            label("去广告", "nosign", sub: "去掉 HLS 片源里插播的广告片段（adjump、异域名短片段、AES 片源中的明文短片段、重复片段）；不会整段丢弃正片的分段标记")
                        }.padding(14).accessibilityIdentifier("settings.adstrip")
                        VStack(alignment: .leading, spacing: 10) {
                            label("播放内核", "cpu", sub: "AetherEngine（FFmpeg 解封装，支持 MKV/FLV/AVI 等与真实音轨/字幕列表）；遇到 CENC/FairPlay 或加载失败自动回退系统播放器")
                            Picker("播放内核", selection: Binding(get: { engineKind }, set: { engineKind = $0; PlayerEngineSettings.preferred = $0 })) {
                                ForEach(PlayerEngineKind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("settings.engine")
                        }.padding(14)
                        actionRow("清空预缓冲缓存（\(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))，上限 2GB）", "externaldrive.badge.xmark") {
                            PrefetchStore.shared.clearAll()
                            cacheBytes = PrefetchStore.shared.totalBytes()
                            message = "已清空预缓冲缓存"
                        }
                    }
                    group("隐私") {
                        Toggle(isOn: Binding(get: { gate.lockEnabled }, set: { on in Task { await gate.setLock(on) } })) {
                            label("隐藏片源锁（Face ID）", "faceid", sub: "每次启动后需验证才显示 18+ 片源")
                        }.padding(14)
                        actionRow("清除站点验证 Cookie", "trash") {
                            await CFCookies.clearAll()
                            message = "已清除站点 Cookie"
                        }
                        NavigationLink { SiteLogView() } label: {
                            HStack { label("站点诊断日志", "stethoscope", sub: "Cloudflare 验证 / Cookie / UA 记录，可复制给开发者"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain)
                        NavigationLink(value: Route.licenses) {
                            HStack { label("开源许可", "doc.text"); Spacer(); chevron }.padding(14)
                        }.buttonStyle(.plain)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(STVTheme.accent).padding(.horizontal, 16) }
                }
            }.padding(.vertical, 12)
        }
        .compatDefaultScrollAnchor(DebugScroll.anchor)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("片源管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { if gate.lockEnabled { await gate.unlock() } }
        .task { cacheBytes = await Task.detached { PrefetchStore.shared.totalBytes() }.value }
    }

    static func rootDomain(_ s: DramaSource) -> String {
        let parts = s.siteHost.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : s.siteHost
    }

    private var lockedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(STVTheme.accent)
            Text("18+ 片源已锁定").font(.headline).foregroundStyle(STVTheme.text)
            Button("用 Face ID 解锁") { Task { await gate.unlock() } }
                .buttonStyle(.borderedProminent).tint(STVTheme.accent)
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    private func builtinRow(_ s: DramaSource, _ icon: String) -> some View {
        HStack {
            label(s.label, icon)
            Spacer()
            Text("内置").font(.caption.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3).background(STVTheme.glass, in: Capsule())
        }.padding(14)
    }

    private func siteRow(_ s: DramaSource) -> some View {
        Toggle(isOn: Binding(get: { gate.enabled.contains(s) }, set: { gate.set(s, on: $0) })) {
            label(s.label, "globe", sub: Self.note(s))
        }.padding(14)
    }

    static func note(_ s: DramaSource) -> String {
        switch s {
        case .jable: "HLS 直连 · 镜像 jable.tv / fs1.app"
        case .missav: "HLS 1080P/720P/480P/360P · 5 个镜像自动探测（.fans/.media 免验证）"
        case .hanime1: "MP4 直链（带签名）· 常需 Cloudflare 验证"
        case .supjav: "多线路（FST/VOE/TV/ST…，不含 LUC）· HLS 经本机代理去伪装头"
        case .eporner: "官方公开 API · HLS + MP4 多画质 · 大陆直连可达"
        case .xvideos: "HLS 自适应 + MP4 · 需代理"
        case .xnxx: "HLS 自适应 + MP4 · 需代理"
        case .pornhub: "HLS 1080P/720P/480P · 需代理"
        default: s.pluginID != nil ? "JS 插件 · " + (PluginStore.snapshot(s.pluginID!)?.manifest.httpDomains.first ?? "") :
                 s.cmsKey != nil ? "苹果 CMS 采集站 · " + (CMSStore.site(s.cmsKey!).flatMap { URL(string: $0.api)?.host } ?? "") : s.siteHost
        }
    }

    private func label(_ t: String, _ icon: String, sub: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(STVTheme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).foregroundStyle(STVTheme.text)
                if let sub { Text(sub).font(.caption).foregroundStyle(STVTheme.secondary) }
            }
        }
    }

    private var chevron: some View { Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary) }

    private func actionRow(_ t: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { HStack { label(t, icon); Spacer(); chevron }.padding(14) }.buttonStyle(.plain)
    }
}

/// 首页片源顺序调整（片源管理 → 首页片源顺序）：拖动右侧手柄排序，即时持久化。
struct HomeSourceOrderView: View {
    @State private var items: [HomeSource] = []

    var body: some View {
        List {
            Section {
                ForEach(items) { s in
                    HStack(spacing: 12) {
                        Image(systemName: Self.icon(s)).frame(width: 24).foregroundStyle(STVTheme.text)
                        Text(s.label).foregroundStyle(STVTheme.text)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    items.move(fromOffsets: from, toOffset: to)
                    HomeSourceOrder.shared.save(items.map(\.sortKey))
                }
            } footer: {
                Text("拖动右侧手柄调整首页顶部片源标签的顺序。改动即时保存，返回首页即可看到新顺序。")
                    .font(.caption).foregroundStyle(STVTheme.secondary)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("首页片源顺序")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = HomeSource.all }
    }

    static func icon(_ s: HomeSource) -> String {
        switch s {
        case .hongguo, .huangguo: "play.rectangle.fill"
        case .ai: "sparkles"
        case .site: "globe"
        case .channels: "paperplane.fill"
        case .manga: "book.fill"
        case .novel: "text.book.closed.fill"
        }
    }
}

/// AetherEngine (LGPL-3.0 + App Store exception, statically linked) and the libraries it brings:
/// FFmpeg/libzvbi (LGPL, dynamic AetherLib*.framework), dav1d, zimg, libdovi.
struct PlayerCoreLicenses: View {
    @State private var open: String?
    private struct Item: Identifiable {
        let id: String; let title: String; let license: String; let links: [(String, String)]; let note: String; let files: [String]
    }
    private let items: [Item] = [
        Item(id: "aether", title: "AetherEngine 7.62.0", license: "LGPL-3.0 + App Store / DRM Exception · Copyright © 2026 Vincent Herbst",
             links: [("源码（7.62.0 标签）", "https://github.com/superuser404notfound/AetherEngine/tree/7.62.0")],
             note: "播放内核，静态链接，未修改。依据其 App Store / DRM 例外条款分发；对应源码见上方 7.62.0 标签。",
             files: ["AetherEngine-LICENSE"]),
        Item(id: "ffmpeg", title: "FFmpeg（via FFmpegBuild 3.14.0）", license: "LGPL-2.1-or-later（未启用 GPL / version3）",
             links: [("FFmpegBuild 3.14.0 源码与构建脚本", "https://github.com/superuser404notfound/FFmpegBuild/tree/3.14.0"),
                     ("ffmpeg.org", "https://ffmpeg.org")],
             note: "以动态框架形式（Frameworks/AetherLib*.framework）随应用分发，可替换重链接；FFmpegBuild 的本地补丁与 libzvbi 修改见其 build.sh。libzvbi 库源码为 LGPL-2.0-or-later（按 LGPL-2.1 分发），ure.c 为 MIT。",
             files: ["FFmpeg-LGPL-2.1", "libzvbi-ure-MIT"]),
        Item(id: "dav1d", title: "dav1d", license: "BSD-2-Clause · Copyright © VideoLAN and dav1d authors",
             links: [("code.videolan.org/videolan/dav1d", "https://code.videolan.org/videolan/dav1d")], note: "AV1 解码（AetherLibdav1d）。", files: ["dav1d-BSD-2-Clause"]),
        Item(id: "zimg", title: "zimg", license: "WTFPL",
             links: [("github.com/sekrit-twc/zimg", "https://github.com/sekrit-twc/zimg")], note: "缩放 / 色彩转换（AetherLibzimg）。", files: ["zimg-WTFPL"]),
        Item(id: "dovi", title: "libdovi（dovi_tool dolby_vision crate，via LibDovi 2.2.0）", license: "MIT · Copyright (c) quietvoid and contributors",
             links: [("github.com/quietvoid/dovi_tool", "https://github.com/quietvoid/dovi_tool"), ("LibDovi 2.2.0", "https://github.com/superuser404notfound/LibDovi/tree/2.2.0")],
             note: "Dolby Vision RPU 解析（静态库，MIT 选项）。", files: ["LibDovi-LICENSE"]),
    ]
    private func text(_ f: String) -> String {
        Bundle.main.url(forResource: f, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? f
    }
    var body: some View {
        ForEach(items) { it in
            VStack(alignment: .leading, spacing: 8) {
                Text(it.title).font(.headline).foregroundStyle(STVTheme.text)
                Text(it.license).font(.subheadline).foregroundStyle(STVTheme.secondary)
                ForEach(it.links, id: \.1) { l in
                    Link(l.0, destination: URL(string: l.1)!).font(.subheadline).tint(STVTheme.accent)
                }
                Text(it.note).font(.caption).foregroundStyle(STVTheme.secondary)
                Button(open == it.id ? "收起许可证全文" : "查看许可证全文") { withAnimation { open = open == it.id ? nil : it.id } }
                    .font(.subheadline.weight(.semibold)).tint(STVTheme.accent)
                    .accessibilityIdentifier("licenses.\(it.id)")
                if open == it.id {
                    ForEach(it.files, id: \.self) { f in
                        Text(text(f)).font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 开源许可 — third-party code this app ports.
struct LicensesView: View {
    @State private var expanded = false
    @State private var qjsExpanded = false
    private var licenseText: String {
        Bundle.main.url(forResource: "UAV-Downloader-LICENSE", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Apache License 2.0 — https://www.apache.org/licenses/LICENSE-2.0"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("UAV-Downloader").font(.headline).foregroundStyle(STVTheme.text)
                    Text("Copyright © ALOS (github.com/Alos21750)\nLicensed under the Apache License, Version 2.0")
                        .font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/Alos21750/UAV-Downloader", destination: URL(string: "https://github.com/Alos21750/UAV-Downloader")!)
                        .font(.subheadline).tint(STVTheme.accent)
                    Text("i短剧 的 MissAV / Jable / SupJav / Hanime1 解析逻辑移植并改写自该项目（基于 commit de92300（2026-11-10 复查仍为最新），Python → Swift，HTML 解析改为正则）。修改内容：站点列表、详情与播放地址解析的 Swift 重写，以及与 i短剧 播放器的对接。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                    Button(expanded ? "收起许可证全文" : "查看 Apache-2.0 全文") { withAnimation { expanded.toggle() } }
                        .font(.subheadline.weight(.semibold)).tint(STVTheme.accent)
                    if expanded {
                        Text(licenseText).font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("yt-dlp").font(.headline).foregroundStyle(STVTheme.text)
                    Text("The Unlicense（公共领域）").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/yt-dlp/yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                        .font(.subheadline).tint(STVTheme.accent)
                    Text("Eporner / XVideos / XNXX / Pornhub 的页面结构与接口（Eporner xhr 哈希、html5player、mediaDefinitions）参考了 yt-dlp 的对应 extractor，代码为独立的 Swift 实现。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("TDLibKit / TDLib").font(.headline).foregroundStyle(STVTheme.text)
                    Text("TDLibKit：MIT · TDLib：Boost Software License 1.0").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/Swiftgram/TDLibKit", destination: URL(string: "https://github.com/Swiftgram/TDLibKit")!).font(.subheadline).tint(STVTheme.accent)
                    Link("github.com/tdlib/td", destination: URL(string: "https://github.com/tdlib/td")!).font(.subheadline).tint(STVTheme.accent)
                    Text("用于频道 TDLib 登录（私有频道、频道内搜索、机器人 /start）。只使用你自己填写的 api_id / api_hash。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("QuickJS-ng").font(.headline).foregroundStyle(STVTheme.text)
                    Text("MIT License · Copyright © 2017-2024 Fabrice Bellard, Charlie Gordon; © 2023-2025 Ben Noordhuis, Saúl Ibarra Corretgé").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/quickjs-ng/quickjs", destination: URL(string: "https://github.com/quickjs-ng/quickjs")!).font(.subheadline).tint(STVTheme.accent)
                    Text("插件运行时（v0.10.1，源码内置于 Packages/QuickJS，未修改；沙箱封装 idj_sandbox.c 为本应用代码）。").font(.caption).foregroundStyle(STVTheme.secondary)
                    Button(qjsExpanded ? "收起许可证全文" : "查看 MIT 全文") { withAnimation { qjsExpanded.toggle() } }
                        .font(.subheadline.weight(.semibold)).tint(STVTheme.accent)
                    if qjsExpanded {
                        Text(Bundle.main.url(forResource: "quickjs-ng-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT")
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                PlayerCoreLicenses()
                VStack(alignment: .leading, spacing: 8) {
                    Text("JMComic-Crawler-Python").font(.headline).foregroundStyle(STVTheme.text)
                    Text("MIT License · Copyright © hect0x7").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Link("github.com/hect0x7/JMComic-Crawler-Python", destination: URL(string: "https://github.com/hect0x7/JMComic-Crawler-Python")!).font(.subheadline).tint(STVTheme.accent)
                    Text("18comic 插件的图片分段还原（get_num / decode）参考该项目公开的算法，代码为独立的 Swift/JS 实现。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("MangaDex API · 包子漫画 · Telegram 网页预览").font(.headline).foregroundStyle(STVTheme.text)
                    Text("漫画与频道解析均为本应用独立实现；MangaDex 只请求全年龄/轻度分级内容。").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                .padding(14)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }.padding(16)
        }
        .compatDefaultScrollAnchor(DebugScroll.anchor)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 站点诊断日志 — what the app knows per site (UA, cookie names, cf_clearance expiry) + the CF event log.
struct SiteLogView: View {
    @State private var lines: [String] = SiteLog.all()
    @State private var copied = false

    private var summary: [String] {
        let jar = HTTPCookieStorage.shared.cookies ?? []
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return Sites.all.map { s in
            let hosts = s.siteHosts
            let cookies = jar.filter { c in hosts.contains { CFCookies.domain(c.domain, matches: $0) } }
            let cf = cookies.filter { $0.name == "cf_clearance" }
                .map { "\($0.domain) 至 \($0.expiresDate.map(f.string) ?? "会话")" }
            return "\(s.label)\n  UA：\(SiteLog.shortUA(s.userAgent))\(SiteUA.learned(s) == nil ? "（默认）" : "（验证页学到）")\n  Cookie：\(cookies.isEmpty ? "无" : Set(cookies.map(\.name)).sorted().joined(separator: ", "))\n  cf_clearance：\(cf.isEmpty ? "无" : cf.joined(separator: "；"))"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(summary, id: \.self) { s in
                    Text(s).font(.caption.monospaced()).foregroundStyle(STVTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("事件（最新在下）").font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.secondary).padding(.top, 6)
                if lines.isEmpty { Text("暂无记录").font(.caption).foregroundStyle(STVTheme.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption2.monospaced()).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                }
            }.padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("站点诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = (summary + [""] + lines).joined(separator: "\n"); copied = true
                }
                Button("清空") { SiteLog.clear(); lines = [] }
            }
        }
        .refreshable { lines = SiteLog.all() }
        .onAppear { lines = SiteLog.all() }
    }
}
