import SwiftUI

enum HomeTab: Hashable {
    case hongguo(HGRankGenre)
    case actorRank
    case huangguo(HuangguoSub)
    /// Opt-in long-video site (片源管理), listed after the built-in tabs.
    case site(DramaSource)
    var label: String {
        switch self {
        case .actorRank: "剧星榜"
        case .hongguo(let g): g == .all ? "红果榜单" : g.label
        case .huangguo(let s): "黄果" + s.label
        case .site(let s): s.label
        }
    }
    /// Label inside a source page's secondary chips.
    var subLabel: String {
        switch self {
        case .hongguo(.all): "全部榜单"
        case .hongguo(.ai): "红果 AI剧"
        case .huangguo(.ai): "黄果 AI 站"
        case .huangguo(let s): s.label
        default: label
        }
    }
}

/// Top-level home pages (横滑翻页 + 顶部分类条): one page per source; each source's own boards
/// (红果榜单 / 真人剧 / …) are secondary chips inside its page. Adult sites only appear once enabled in
/// 片源管理 (and unlocked with Face ID when the lock is on) — `SourceGate.visibleSites`.
enum HomeSource: Hashable, Identifiable {
    case hongguo, huangguo, ai
    case site(DramaSource)
    /// Telegram 频道 feed (not a drama source; its page is `ChannelFeedView`).
    case channels
    /// 漫画 (MangaHomeView).
    case manga
    /// 小说 (NovelHomeView: local TXT / EPUB bookshelf).
    case novel
    var id: String { label }
    var label: String {
        switch self {
        case .hongguo: "红果"
        case .huangguo: "黄果"
        case .ai: "AI剧"
        case .site(let s): s.label
        case .channels: "频道"
        case .manga: "漫画"
        case .novel: "小说"
        }
    }
    @MainActor var subs: [HomeTab] {
        switch self {
        case .hongguo: [.hongguo(.all), .hongguo(.human), .hongguo(.comic), .actorRank]
        case .huangguo: [.huangguo(.video), .huangguo(.legacy)]
        case .ai: SourceGate.shared.showHuangguo ? [.hongguo(.ai), .huangguo(.ai)] : [.hongguo(.ai)]
        case .site(let s): [.site(s)]
        case .channels, .manga, .novel: []
        }
    }
    @MainActor static var all: [HomeSource] {
        let g = SourceGate.shared
        return [.hongguo] + (g.showHuangguo ? [.huangguo] : []) + [.ai] + g.visibleSites.map { .site($0) } + [.channels, .manga, .novel]
    }
}

/// Caches the first page of each rank board for the home cards.
@MainActor
final class BoardCache: ObservableObject {
    static let shared = BoardCache()
    @Published var items: [String: [HGSeries]] = [:]
    @Published var loading: Set<String> = []
    @Published var failed: Set<String> = []
    @Published var errors: [String: Error] = [:]
    func load(_ b: BoardSpec, force: Bool = false) {
        guard !loading.contains(b.id), force || items[b.id] == nil else { return }
        loading.insert(b.id); failed.remove(b.id); errors[b.id] = nil
        Task {
            do { items[b.id] = try await b.fetch(HGPage(items: [], hasMore: true, nextOffset: nil), []).items; errors[b.id] = nil }
            catch { failed.insert(b.id); errors[b.id] = error }
            loading.remove(b.id)
        }
    }
}

/// 发现页：玻璃搜索栏/筛选 → 来源分类条（红果 / 黄果 / AI剧 / 已开启的长视频站）→ 下方按来源横滑翻页，
/// 分类条联动（选中项自动滚到居中、指示条跟随）。每页：二级榜单选择 → 竖海报 hero → 真实榜单分段。
/// 横滑冲突：hero 轮播区域内的横滑归轮播；其它区域横滑翻来源页；首页是根页面，没有系统侧滑返回。
struct HomeView: View {
    @State private var source: HomeSource
    @State private var subs: [HomeSource: HomeTab]
    @State private var heroCovers: [HomeSource: String] = [:]
    /// Header text sits on the blurred hero poster (dark) when there is one, else on the page colour.
    private var onPoster: Bool { heroCovers[source] != nil }
    private var headerInk: Color { onPoster ? .white : STVTheme.text }
    @State private var showChannels = false

    init() {
        let e = ProcessInfo.processInfo.environment["STV_HOME_TAB"] ?? ""
        var src = HomeSource.hongguo, sub: [HomeSource: HomeTab] = [:]
        if e == "actorRank" { sub[.hongguo] = .actorRank }
        #if DEBUG
        if let s = DramaSource(rawValue: e), s.isLongVideo { src = .site(s) }
        if e == "huangguo" { src = .huangguo }
        if e == "ai" { src = .ai }
        if e == "channels" { src = .channels }
        if e == "manga" { src = .manga }
        if e == "novel" { src = .novel }
        #endif
        _source = State(initialValue: src)
        _subs = State(initialValue: sub)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $source) {
                ForEach(HomeSource.all) { s in
                    if s == .channels {
                        ChannelFeedView(embedded: true).tag(s)
                    } else if s == .manga {
                        MangaHomeView(embedded: true).tag(s)
                    } else if s == .novel {
                        NovelHomeView(embedded: true).tag(s)
                    } else {
                        HomeFeedPage(source: s,
                                     tab: Binding(get: { subs[s] ?? s.subs[0] }, set: { subs[s] = $0 }),
                                     onHero: { heroCovers[s] = $0 })
                            .tag(s)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(alignment: .top) { atmosphere }
        .background(STVTheme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showChannels) { channelPanel }
        .onChange(of: SourceGate.shared.visibleSites) { _ in if !HomeSource.all.contains(source) { source = .hongguo } }
    }

    // MARK: Header (search + filter, source bar)

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                NavigationLink(value: Route.search) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium))
                        Text("搜索你想看的作品").font(.system(size: 16)).opacity(0.8).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 14).frame(height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("home.search")
                Button { showChannels = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .semibold))
                        Text("筛选").font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("筛选与全部频道").accessibilityIdentifier("home.filter")
            }
            .foregroundStyle(headerInk)
            .background(headerInk.opacity(onPoster ? 0.18 : 0.07), in: Capsule())
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .overlay { Capsule().strokeBorder(headerInk.opacity(0.14), lineWidth: 1) }
            .padding(.horizontal, 16)
            HomeChannelBar(items: HomeSource.all, selection: $source, label: \.label, ink: headerInk) { showChannels = true }
                .padding(.leading, 16)
        }
        .padding(.top, 6)
    }

    /// 当前来源页 hero 海报模糊铺在页面顶部，向页面底色淡出。
    @ViewBuilder private var atmosphere: some View {
        let url = heroCovers[source]
        ZStack {
            // Dark ground under the blurred poster keeps the white header legible; without a poster (漫画 / 频道)
            // it would be a dark band in light mode, so use a soft tint of the page colour instead.
            if url != nil { Color(red: 0.08, green: 0.10, blue: 0.15) } else { STVTheme.elevated }
            if let url {
                CoverView(url: url, corner: 0).blur(radius: 48).opacity(0.75).id(url)
                    .transition(.opacity)
            }
        }
        .frame(height: 420)
        .clipped()
        .mask(LinearGradient(colors: [.black, .black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
        .animation(.easeInOut(duration: 0.45), value: url)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var channelPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(HomeSource.all.filter { !$0.subs.isEmpty }) { s in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                                ForEach(s.subs, id: \.self) { t in
                                    let on = s == source && (subs[s] ?? s.subs[0]) == t
                                    Button { subs[s] = t; source = s; showChannels = false } label: {
                                        Text(t.subLabel).font(.subheadline.weight(on ? .semibold : .regular))
                                            .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                                            .frame(maxWidth: .infinity).frame(height: 40)
                                            .background(on ? STVTheme.accent.opacity(0.14) : STVTheme.glass,
                                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }.buttonStyle(.plain).accessibilityIdentifier("panel.\(s.label).\(t.subLabel)")
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(STVTheme.surface.ignoresSafeArea())
            .navigationTitle("频道").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("home.channelPanel")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChannels = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One source page: secondary board chips → hero → real board sections. Vertical scroll inside a horizontal pager.
private struct HomeFeedPage: View {
    let source: HomeSource
    @Binding var tab: HomeTab
    var onHero: (String) -> Void
    @State private var legacyChannels: [HuangguoChannel] = []
    @State private var legacyError: Error?
    @State private var heroIndex = 0
    @ObservedObject private var cache = BoardCache.shared
    @ObservedObject private var library = LibraryStore.shared
    private let gutter: CGFloat = 16
    /// DEBUG `STV_HOME_SCROLL=bottom` opens the feed scrolled to the end (simulator screenshots).
    private static var debugAnchor: UnitPoint? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HOME_SCROLL"] == "bottom" { return .bottom }
        #endif
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if source.subs.count > 1 { subChips } else if case .site = source { boardChips }
                if tab == .actorRank {
                    ActorRankList().padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        if !heroPicks.isEmpty {
                            PosterHero(board: boards.first?.title ?? "", picks: heroPicks, index: $heroIndex).id(tab).padding(.horizontal, gutter)
                        }
                        if source == .hongguo, !library.continueWatching.isEmpty { ContinueRow(items: library.continueWatching) }
                        sections
                    }.padding(.top, 4)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .compatDefaultScrollAnchor(Self.debugAnchor)
        .accessibilityIdentifier("home.page.\(source.label)")
        .refreshable { if tab == .actorRank { await ActorRankStore.shared.reload() } else { boards.forEach { cache.load($0, force: true) } } }
        .task(id: tab) {
            heroIndex = 0
            if case .huangguo(.legacy) = tab, legacyChannels.isEmpty { await loadLegacy() }
        }
        .onAppear { boards.prefix(1).forEach { cache.load($0) }; reportHero() }
        .onChange(of: tab) { _ in boards.prefix(1).forEach { cache.load($0) } }
        .onChange(of: heroKey) { _ in reportHero() }
    }

    private var heroKey: String { (heroPicks.indices.contains(heroIndex) ? heroPicks[heroIndex].cover : "") + "\(heroIndex)" }
    private func reportHero() { if heroPicks.indices.contains(heroIndex) { onHero(heroPicks[heroIndex].cover) } }

    private var subChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(source.subs, id: \.self) { t in
                    let on = t == tab
                    Button { withAnimation(.snappy) { tab = t } } label: {
                        Text(t.subLabel).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? STVTheme.bg : STVTheme.text.opacity(0.8))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(on ? STVTheme.text : STVTheme.text.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.sub.\(t.subLabel)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }.padding(.horizontal, gutter)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.top, 4).padding(.bottom, 12)
    }

    /// Long-video site pages: same chip row height as 红果/黄果 (top never jumps); each chip opens that board.
    private var boardChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { i, b in
                    NavigationLink(value: Route.board(b)) {
                        Text(b.title).font(.system(size: 13, weight: i == 0 ? .semibold : .regular))
                            .foregroundStyle(i == 0 ? STVTheme.bg : STVTheme.text.opacity(0.8))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(i == 0 ? STVTheme.text : STVTheme.text.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.sub.\(b.title)")
                }
            }.padding(.horizontal, gutter)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.top, 4).padding(.bottom, 12)
    }

    // MARK: Data

    private var boards: [BoardSpec] {
        switch tab {
        case .hongguo(let g): g.subs.map { BoardSpec(kind: .hongguo(g, $0)) }
        case .huangguo(.ai): HuangguoClient.aiChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.video): HuangguoClient.videoChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.legacy): legacyChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .site(let s): (Sites.provider(s)?.categories ?? []).map { BoardSpec(kind: .site(s, $0)) }
        case .actorRank: []
        }
    }

    private var heroPicks: [HGSeries] {
        guard let first = boards.first, let items = cache.items[first.id] else { return [] }
        return Array(items.prefix(5))
    }

    @ViewBuilder private var sections: some View {
        if case .huangguo(.legacy) = tab, legacyChannels.isEmpty {
            if let legacyError { ErrorStateView(error: legacyError) { Task { await loadLegacy() } } }
            else { cardsSkeleton }
        } else {
            if case .site = tab, let e = boards.lazy.compactMap({ cache.errors[$0.id] }).first(where: { $0.verifyTarget != nil }) {
                ErrorStateView(error: e) { boards.forEach { cache.load($0, force: true) } }
            }
            ForEach(Array(boards.enumerated()), id: \.element.id) { n, b in
                Group {
                    if let items = cache.items[b.id], !items.isEmpty {
                        // 第一个榜单一律跳过 hero 里已展示的剧（数据不够时也跳过，只剩标题和「全部」）。
                        let heroIds = Set(heroPicks.map(\.id))
                        let rest = n == 0 ? items.filter { !heroIds.contains($0.id) } : items
                        HomeSection(title: b.title, note: nil, items: Array(rest.prefix(HomeSection.count(for: rest))), more: b)
                    } else if cache.failed.contains(b.id) {
                        HomeSection(title: b.title, note: "加载失败，下拉重试", items: [], more: b)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(b.title).font(.system(size: 17, weight: .bold)).foregroundStyle(STVTheme.text)
                            cardsSkeleton
                        }
                    }
                }
                .padding(.horizontal, gutter)
                .onAppear { cache.load(b) }
            }
        }
    }

    private var cardsSkeleton: some View {
        let landscape: Bool = { if case .site(let s) = tab { return s.isLongVideo } else { return false } }()
        return LazyVGrid(columns: HomeSection.columns(landscape: landscape), spacing: 16) {
            ForEach(0..<(landscape ? 2 : 3), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBlock().aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    ShimmerBlock().frame(height: 12).frame(maxWidth: 90)
                }
            }
        }
    }

    private func loadLegacy() async {
        do { legacyChannels = try await HuangguoClient.shared.legacyChannels(); legacyError = nil } catch { legacyError = error }
    }
}

enum HomeFmt {
    /// 次要信息：类型（最多两个标签）· 集数 / 热度；长视频是时长 · 观看。
    static func meta(_ s: HGSeries) -> String {
        if s.source.isLongVideo { return Fmt.meta(s) }
        let genres = s.tags.prefix(2).joined(separator: " · ")
        let parts = [genres.isEmpty ? nil : genres, s.episodeCount > 0 ? "\(s.episodeCount)集" : nil].compactMap { $0 }
        return parts.isEmpty ? Fmt.meta(s) : parts.joined(separator: " · ")
    }
    /// 右下角小角标：「更新至 N 集」/「全 N 集」/ 长视频时长。
    static func progress(_ s: HGSeries) -> String? {
        if let sub = s.subtitle, sub.contains("更新至") || sub.hasPrefix("全") { return sub }
        if s.source.isLongVideo { return s.duration > 0 ? Fmt.clock(s.duration) : nil }
        return s.episodeCount > 0 ? "全\(s.episodeCount)集" : nil
    }
}

/// 分类条：未选中 17pt 次要色，选中 20pt 粗体 + 品牌色短条（随选中项滑动）；点击或翻页时选中项自动滚到居中。
struct HomeChannelBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var ink: Color = .white
    var onExpand: () -> Void
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 22) {
                        ForEach(items, id: \.self) { it in
                            let on = it == selection
                            Button { withAnimation(.snappy) { selection = it } } label: {
                                Text(label(it))
                                    .font(.system(size: on ? 20 : 17, weight: on ? .bold : .regular))
                                    .foregroundStyle(on ? ink : ink.opacity(0.62))
                                    .frame(minHeight: 44)
                                    .overlay(alignment: .bottom) {
                                        if on { Capsule().fill(STVTheme.accent).frame(width: 18, height: 3).offset(y: -2)
                                                .matchedGeometryEffect(id: "indicator", in: ns) }
                                    }
                            }.buttonStyle(.plain).id(it).accessibilityIdentifier("home.channel.\(label(it))")
                                .accessibilityAddTraits(on ? .isSelected : [])
                        }
                        Color.clear.frame(width: 12, height: 1)
                    }
                }
                .accessibilityIdentifier("home.channels")
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .onChange(of: selection) { it in withAnimation(.snappy) { proxy.scrollTo(it, anchor: .center) } }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            Button(action: onExpand) {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.85)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("展开全部频道").accessibilityIdentifier("home.expand")
        }
        .padding(.top, 6).padding(.bottom, 8)
    }
}

/// 竖海报 hero：整块用当前海报模糊做底，左侧完整 3:4 竖海报（不裁成横图），
/// 右侧榜单名、片名、标签/集数/热度、简介或主演，以及「查看详情」。横滑切换，右上指示点。
/// 长视频站点（横版封面）同一布局里海报区按 16:9 显示在上方。
private struct PosterHero: View {
    @Environment(\.zoomNS) private var ns
    let board: String
    let picks: [HGSeries]
    @Binding var index: Int

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(picks.enumerated()), id: \.element.id) { i, s in
                NavigationLink(value: Route.series(s)) { page(s, rank: i + 1) }.buttonStyle(.plain).tag(i)
                    .accessibilityIdentifier("home.hero.page.\(i)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Same card height for every source so switching pages never makes the top jump.
        .frame(height: Self.height)
        .background { backdrop }
        .overlay(alignment: .bottomTrailing) { dots }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(STVTheme.glassBorder, lineWidth: 1) }
        // Auto-advance; the timer restarts on every page change, so a manual swipe gets a full 6 s.
        .task(id: "\(picks.count)-\(index)") {
            guard picks.count > 1, Self.autoAdvance else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % picks.count }
        }
    }

    static let height: CGFloat = 228
    /// DEBUG `STV_HERO_STILL=1` (UI tests) disables auto-advance so taps never race a page change.
    static var autoAdvance: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HERO_STILL"] == "1" { return false }
        #endif
        return true
    }
    private var landscape: Bool { picks.first?.isLandscapeCover ?? false }

    private var backdrop: some View {
        let url = picks.indices.contains(index) ? picks[index].cover : ""
        return ZStack {
            STVTheme.surface
            CoverView(url: url, corner: 0).blur(radius: 36).scaleEffect(1.3).opacity(0.7).id(url).transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: url)
        // Decorative only: the blurred, 1.3× scaled poster is larger than the card; never let it take touches.
        .allowsHitTesting(false)
    }

    @ViewBuilder private func page(_ s: HGSeries, rank: Int) -> some View {
        if landscape {
            // 横版封面：与竖海报 hero 同卡片/同高度/同信息层级 —— 左上 16:9 封面（时长角标）+ 右侧「榜单 · TOP」与标题，
            // 下方元信息、标签与白色「查看详情」，页码点仍在右下角。
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: s.cover, corner: 12)
                        .frame(width: 176, height: 99)
                        .zoomSource(s.id, ns)
                        .overlay(alignment: .bottomTrailing) { if let p = HomeFmt.progress(s) { HomeBadge(text: p).padding(5) } }
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                        .accessibilityIdentifier("home.hero.cover")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(board.isEmpty ? "TOP \(rank)" : "\(board) · TOP \(rank)").font(.system(size: 11, weight: .heavy)).tracking(0.6)
                            .foregroundStyle(STVTheme.accentWarm).lineLimit(1)
                        Text(s.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let chips = Array(s.tags.prefix(3))
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { c in
                            Text(c).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.lineLimit(1)
                }
                let line = [Fmt.meta(s), s.subtitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
                Spacer(minLength: 0)
                detailButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        } else {
            HStack(alignment: .center, spacing: 16) {
                CoverView(url: s.cover, corner: 12)
                    .frame(width: 147, height: 196)
                    .zoomSource(s.id, ns)
                    .overlay(alignment: .bottomTrailing) { if let p = HomeFmt.progress(s) { HomeBadge(text: p).padding(6) } }
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                info(s, rank: rank, lines: 3)
            }.padding(16)
        }
    }

    private func info(_ s: HGSeries, rank: Int, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(board.isEmpty ? "TOP \(rank)" : "\(board) · TOP \(rank)").font(.system(size: 11, weight: .heavy)).tracking(0.6)
                .foregroundStyle(STVTheme.accentWarm)
            Text(s.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            let chips = Array(s.tags.prefix(3))
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { c in
                        Text(c).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    }
                }.lineLimit(1)
            }
            let line = Fmt.meta(s)
            if !line.isEmpty { Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
            if let blurb = s.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !blurb.isEmpty, HomeFmt.progress(s) != blurb {
                Text(blurb).font(.system(size: 12)).foregroundStyle(.white.opacity(0.66)).lineLimit(lines)
            } else if !s.actors.isEmpty {
                Text("主演 " + s.actors.prefix(3).joined(separator: " / ")).font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.66)).lineLimit(1)
            }
            Spacer(minLength: 0)
            detailButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, landscape ? 0 : 4)
    }

    private var detailButton: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
            Text("查看详情").font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(Color(red: 0.067, green: 0.075, blue: 0.094))
        .padding(.horizontal, 14).frame(height: 32)
        .background(.white, in: Capsule())
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(picks.indices, id: \.self) { i in
                Capsule().fill(i == index ? Color.white : Color.white.opacity(0.4)).frame(width: i == index ? 14 : 5, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: index)
        .padding(.horizontal, 8).frame(height: 20)
        .background(.black.opacity(0.28), in: Capsule())
        .padding(12)
        .opacity(picks.count > 1 ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(index + 1) 部，共 \(picks.count) 部")
        .accessibilityIdentifier("home.hero.dots")
    }
}

struct HomeBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
            .lineLimit(1).padding(.horizontal, 5).frame(height: 17)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 分段：左写接口真实榜单名，右侧「全部」进完整榜单；下面按封面比例的网格。
struct HomeSection: View {
    static func columns(landscape: Bool) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: landscape ? 12 : 10, alignment: .top), count: landscape ? 2 : 3)
    }
    /// 竖海报 2 行 × 3，横版 2 行 × 2。
    static func count(for items: [HGSeries]) -> Int { (items.first?.isLandscapeCover ?? false) ? 4 : 6 }
    let title: String
    let note: String?
    let items: [HGSeries]
    var more: BoardSpec? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(STVTheme.text)
                Spacer(minLength: 0)
                if let note { Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(STVTheme.secondary) }
                if let more {
                    NavigationLink(value: Route.board(more)) {
                        HStack(spacing: 2) { Text("全部"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                            .font(.system(size: 13)).foregroundStyle(STVTheme.secondary)
                    }.buttonStyle(.plain).accessibilityIdentifier("home.more.\(title)")
                }
            }
            if !items.isEmpty {
                let landscape = items.first?.isLandscapeCover ?? false
                LazyVGrid(columns: Self.columns(landscape: landscape), alignment: .leading, spacing: 16) {
                    ForEach(items) { s in
                        NavigationLink(value: Route.series(s)) { HomePosterCard(series: s) }.buttonStyle(.plain)
                            .accessibilityIdentifier("home.card")
                    }
                }
            }
        }
    }
}

/// 卡片按来源封面比例：短剧 3:4 竖海报（三列），长视频站 16:9（两列）。
/// 封面下方片名（两行内）+ 一行类型/集数；右下角只保留「全 N 集 / 更新至 N 集」小角标。
struct HomePosterCard: View {
    @Environment(\.zoomNS) private var ns
    let series: HGSeries
    var body: some View {
        let landscape = series.isLandscapeCover
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit)
                .overlay { CoverView(url: series.cover, corner: 0) }
                .clipShape(RoundedRectangle(cornerRadius: landscape ? 12 : 10, style: .continuous))
                .zoomSource(series.id, ns)
                .overlay(alignment: .bottomTrailing) {
                    if let p = HomeFmt.progress(series) { HomeBadge(text: p).padding(5) }
                }
                .overlay { RoundedRectangle(cornerRadius: landscape ? 12 : 10, style: .continuous).strokeBorder(STVTheme.glassBorder, lineWidth: 0.6) }
            Text(series.title)
                .font(.system(size: landscape ? 14 : 13, weight: .semibold)).foregroundStyle(STVTheme.text)
                .lineLimit(landscape ? 1 : 2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
            let meta = HomeFmt.meta(series)
            if !meta.isEmpty {
                Text(meta).font(.system(size: 11)).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Full list of one board, 3-column numbered grid with infinite paging.
struct BoardListView: View {
    let board: BoardSpec
    @StateObject private var pager = Pager()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = pager.error, pager.items.isEmpty { ErrorStateView(error: e) { reload() } }
                else { NumberedGrid(items: pager.items, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() } }
            }.padding(.vertical, 8)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .accessibilityIdentifier("screen.board")
        .navigationTitle(board.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if pager.items.isEmpty { reload() } }
    }
    private func reload() { let b = board; pager.reset { try await b.fetch($0, $1) } }
}
