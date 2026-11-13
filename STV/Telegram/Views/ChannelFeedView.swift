import SwiftUI

/// 「频道」: merged newest-first feed of subscribed public channels (朋友圈 style).
/// Embedded as a home source page and also pushable from 我的.
struct ChannelFeedView: View {
    var embedded = false
    @ObservedObject private var store = TGStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var only: String?
    @State private var viewer: ViewerPayload?
    @State private var blockTarget: TGPost?
    @State private var botTarget: TGBotLink?
    @State private var toast: String?
    @State private var addText = ""
    @Environment(\.openURL) private var openURL

    struct ViewerPayload: Identifiable { let id = UUID(); let urls: [String]; let index: Int }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                toolbarRow
                channelChips.padding(.bottom, 6)
                errorBanners
                let entries = store.feed(only)
                if store.visibleChannels.isEmpty {
                    emptySubscriptions
                } else if entries.isEmpty {
                    if !store.loading.isEmpty {
                        ProgressView().tint(STVTheme.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        Text("下拉刷新，或点右上角 ↻").font(.subheadline).foregroundStyle(STVTheme.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                ForEach(entries) { e in
                    TGPostCard(post: e.post, channel: store.channel(e.post.channel), verdict: e.verdict, actions: actions)
                        .padding(.horizontal, e.verdict.blocked ? 16 : 0).padding(.vertical, e.verdict.blocked ? 4 : 0)
                    Divider().overlay(STVTheme.text.opacity(0.06)).padding(.leading, 66)
                }
                if !entries.isEmpty && store.hasMore(only) {
                    ProgressView().tint(STVTheme.secondary).frame(maxWidth: .infinity).padding(20)
                        .onAppear { Task { await store.loadMore(only) } }
                        .accessibilityIdentifier("tg.loadMore")
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh(only) }
        .background(embedded ? Color.clear : STVTheme.bg)
        .overlay(alignment: .bottom) {
            if let toast { Text(toast).font(.footnote).foregroundStyle(.white).padding(10).background(.black.opacity(0.75), in: Capsule()).padding(.bottom, 90) }
        }
        .navigationTitle(embedded ? "" : "频道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
        .task { if store.feed(only).isEmpty { await store.refresh() } }
        .task(id: toast) { if toast != nil { try? await Task.sleep(for: .seconds(2.2)); toast = nil } }
        .fullScreenCover(item: $viewer) { v in
            ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index, onSave: { try await TGDownloads.savePhoto($0.url) })
        }
        .sheet(item: $blockTarget) { p in TGBlockSheet(post: p) }
        .sheet(item: Binding(get: { botTarget.map { BotBox(link: $0) } }, set: { botTarget = $0?.link })) { b in TGBotSheet(link: b.link) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.feed")
    }

    private struct BotBox: Identifiable { let link: TGBotLink; var id: String { link.bot + link.payload } }

    private var actions: TGActions {
        TGActions(
            openImages: { p, i in
                let photos = p.media.enumerated().filter { $0.element.kind == .photo }
                let urls = photos.map(\.element.thumb)
                viewer = ViewerPayload(urls: urls, index: photos.firstIndex { $0.offset == i } ?? 0)
            },
            playVideo: { p, i in
                guard let s = TGVideoProvider.series(p, media: i, channel: store.channel(p.channel)) else {
                    toast = "视频过大，网页预览不提供直链，请在 Telegram 中打开"
                    if let u = URL(string: p.media[i].link.isEmpty ? p.permalink : p.media[i].link) { openURL(u) }
                    return
                }
                Router.push(.play(s, 0))
            },
            download: { p, i in
                if TGDownloads.shared.enqueue(post: p, media: i, channel: store.channel(p.channel)) != nil { toast = "已加入下载队列" }
                else { toast = "这条媒体没有可下载的直链" }
            },
            block: { blockTarget = $0 },
            bot: { botTarget = $0 })
    }

    private var toolbarRow: some View {
        HStack(spacing: 18) {
            if embedded {
                let c = store.blockedCount(only)
                Text(store.loading.isEmpty ? "\(c.total) 条 · 已屏蔽 \(c.blocked)" : "刷新中…").font(.caption).foregroundStyle(STVTheme.secondary)
                    .accessibilityIdentifier("tg.stats")
            }
            Spacer()
            NavigationLink(value: Route.tgSearch(only)) { Image(systemName: "magnifyingglass") }.accessibilityIdentifier("tg.search").accessibilityLabel("搜索频道")
            NavigationLink(value: Route.downloads) { Image(systemName: "arrow.down.circle") }.accessibilityIdentifier("tg.downloads").accessibilityLabel("下载管理")
            NavigationLink(value: Route.tgManage) { Image(systemName: "slider.horizontal.3") }.accessibilityIdentifier("tg.manage").accessibilityLabel("频道管理")
            Button { Task { await store.refresh(only) } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityIdentifier("tg.refresh").accessibilityLabel("刷新")
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(STVTheme.text)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var channelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GlassChip(title: "全部", selected: only == nil) { only = nil }
                ForEach(store.visibleChannels) { c in
                    GlassChip(title: c.displayName, selected: only == c.id) { only = c.id }
                        .accessibilityIdentifier("tg.chip.\(c.id)")
                }
            }.padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var errorBanners: some View {
        let errs = store.visibleChannels.filter { (only == nil || $0.id == only) && store.errors[$0.id] != nil }
        ForEach(errs) { c in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(STVTheme.accentWarm)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.displayName + (c.subscribers.isEmpty ? "" : " · " + c.subscribers)).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.text)
                    Text(store.errors[c.id] ?? "").font(.caption).foregroundStyle(STVTheme.secondary)
                    HStack(spacing: 14) {
                        if store.needsTDLogin.contains(c.id) && !TDLibService.shared.state.isReady {
                            Button("去登录 TDLib") { Router.push(.tdlib) }.accessibilityIdentifier("tg.error.login.\(c.id)")
                        }
                        if store.tdRestricted.contains(c.id), TDLibService.shared.sensitive.canChange, !TDLibService.shared.sensitive.enabled {
                            Button("显示敏感内容") {
                                Task { try? await TDLibService.shared.setSensitive(true); await store.refresh(c.id) }
                            }.accessibilityIdentifier("tg.error.sensitive.\(c.id)")
                        }
                        Button("在 Telegram 中打开") { if let u = URL(string: "https://t.me/\(c.username)") { openURL(u) } }
                    }.font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tg.error.\(c.id)")
        }
    }

    private var emptySubscriptions: some View {
        VStack(spacing: 14) {
            Image(systemName: "paperplane.circle").font(.system(size: 44)).foregroundStyle(STVTheme.secondary)
            Text("还没有订阅频道").font(.headline).foregroundStyle(STVTheme.text)
            Text("输入公开频道用户名或链接，例如 telegram、t.me/durov").font(.caption).foregroundStyle(STVTheme.secondary)
            HStack {
                TextField("频道用户名 / 链接", text: $addText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(height: 38).background(STVTheme.elevated, in: Capsule())
                    .accessibilityIdentifier("tg.empty.field")
                Button("订阅") {
                    if store.add(addText) != nil { addText = ""; Task { await store.refresh() } } else { toast = "无效的频道名" }
                }.buttonStyle(.borderedProminent).tint(STVTheme.accent).accessibilityIdentifier("tg.empty.add")
            }.padding(.horizontal, 30)
            if !gate.showAdultChannels && store.channels.contains(where: \.isAdult) {
                Text("预置的成人频道已隐藏：我的 → 片源管理 → 成人 Telegram 频道").font(.caption2).foregroundStyle(STVTheme.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }
}

/// Global navigation helper so cards deep in a feed can push routes on the active stack.
@MainActor enum Router {
    static var handler: (Route) -> Void = { _ in }
    static func push(_ r: Route) { handler(r) }
}
