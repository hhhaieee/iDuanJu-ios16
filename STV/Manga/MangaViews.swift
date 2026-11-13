import SwiftUI

/// 漫画 home: source switch, category chips, cover grid, search, 继续阅读 / 收藏.
struct MangaHomeView: View {
    @Environment(\.zoomNS) private var ns
    var embedded = false
    @State private var source: MangaSourceID = .baozi
    @State private var category: MangaCategory?
    @State private var items: [MangaItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var searching: String?
    @ObservedObject private var store = MangaStore.shared

    private var provider: MangaProvider { MangaFixtures.provider ?? source.provider }
    private var cats: [MangaCategory] { _ = PluginStore.shared.revision; return provider.categories }
    /// Built-ins + enabled comic plugins; adult ones only behind the 成人漫画 switch.
    private var sources: [MangaSourceID] {
        _ = PluginStore.shared.revision
        return MangaSourceID.allCases.filter { !$0.isAdult || SourceGate.shared.showAdultManga }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sources) { s in
                                GlassChip(title: s.label, selected: s == source) { if s != source { category = nil; items = []; source = s } }
                                    .accessibilityIdentifier("manga.source.\(s.rawValue)")
                            }
                        }
                    }
                    NavigationLink(value: Route.mangaLibrary) { Image(systemName: "books.vertical").font(.system(size: 17)) }
                        .foregroundStyle(STVTheme.text).accessibilityIdentifier("manga.library").accessibilityLabel("书架")
                }.padding(.horizontal, 16).padding(.top, 6)
                SearchField(text: $query, placeholder: "搜索\(source.label)", onSubmit: { searching = query.isEmpty ? nil : query; reload() },
                            onCancel: searching == nil ? nil : { query = ""; searching = nil; reload() })
                    .padding(.horizontal, 16)
                if searching == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(cats) { c in GlassChip(title: c.title, selected: c.id == (category ?? cats.first)?.id) { category = c } }
                        }.padding(.horizontal, 16)
                    }
                }
                if !store.recent.isEmpty && searching == nil { continueRow }
                if let error { Text(error).font(.caption).foregroundStyle(STVTheme.accentWarm).padding(.horizontal, 16) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                    ForEach(items) { m in
                        NavigationLink(value: Route.manga(m)) { MangaCell(item: m) }.buttonStyle(.plain)
                            .accessibilityIdentifier("manga.cell.\(m.mangaId)")
                    }
                }.padding(.horizontal, 16)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                else if hasMore && !items.isEmpty {
                    Color.clear.frame(height: 30).onAppear { Task { await load(more: true) } }
                }
                Text("来源：\(source.note)").font(.caption2).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
            }.padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load(more: false) }
        .background(embedded ? Color.clear : STVTheme.bg)
        .navigationTitle(embedded ? "" : "漫画").navigationBarTitleDisplayMode(.inline)
        .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
        .task(id: "\(source.rawValue)|\(category?.id ?? "")") { await load(more: false) }
        .onChange(of: sources) { now in if !now.contains(source) { category = nil; source = .baozi } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manga.home")
    }

    private func reload() { Task { await load(more: false) } }

    private func load(more: Bool) async {
        if more && (loading || !hasMore) { return }
        loading = true; error = nil
        let p = more ? page + 1 : 1
        do {
            let r: MangaPage
            if let q = searching { r = try await provider.search(q, page: p) }
            else { r = try await provider.list(category ?? cats[0], page: p) }
            if more { let seen = Set(items.map(\.id)); items += r.items.filter { !seen.contains($0.id) } } else { items = r.items }
            page = p; hasMore = r.hasMore
        } catch { self.error = error.localizedDescription; if !more { items = [] } }
        loading = false
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("继续阅读").font(.headline).foregroundStyle(STVTheme.text).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.recent.filter { !$0.item.source.isAdult || SourceGate.shared.showAdultManga }.prefix(10), id: \.item.id) { p in
                        NavigationLink(value: Route.manga(p.item)) {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverView(url: p.item.cover, headers: p.item.source.provider.imageHeaders, corner: 8).frame(width: 84, height: 112)
                                    .zoomSource("manga:" + p.item.id, ns)
                                Text(p.item.title).font(.caption).lineLimit(1).foregroundStyle(STVTheme.text)
                                Text(p.chapterTitle).font(.caption2).lineLimit(1).foregroundStyle(STVTheme.secondary)
                            }.frame(width: 84)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
        }
    }
}

struct MangaCell: View {
    @Environment(\.zoomNS) private var ns
    let item: MangaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverView(url: item.cover, headers: item.source.provider.imageHeaders, corner: 10).aspectRatio(3 / 4, contentMode: .fit)
                .zoomSource("manga:" + item.id, ns)
            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
            Text(item.tags.prefix(2).joined(separator: " · ").isEmpty ? item.author : item.tags.prefix(2).joined(separator: " · "))
                .font(.caption2).foregroundStyle(STVTheme.secondary).lineLimit(1)
        }
    }
}

/// 书架: favorites + offline chapters.
struct MangaLibraryView: View {
    @ObservedObject private var store = MangaStore.shared
    var body: some View {
        List {
            Section("收藏（\(store.favorites.count)）") {
                ForEach(store.favorites.filter { !$0.source.isAdult || SourceGate.shared.showAdultManga }) { m in
                    NavigationLink(value: Route.manga(m)) { Text(m.title) }
                }
            }
            Section("已下载章节（\(store.offlineList.count)）") {
                ForEach(store.offlineList.filter { !$0.item.source.isAdult || SourceGate.shared.showAdultManga }, id: \.chapter.id) { o in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(o.item.title).font(.subheadline)
                            Text(o.chapter.title + " · " + (o.state == .done ? "\(o.files.count) 页" : o.state == .running ? "下载中 \(o.files.count)/\(o.total)" : (o.error ?? "失败")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { store.deleteOffline(o.item, o.chapter) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("书架").navigationBarTitleDisplayMode(.inline)
    }
}

struct MangaDetailView: View {
    @Environment(\.zoomNS) private var ns
    let item: MangaItem
    @State private var detail: MangaDetail?
    @State private var error: String?
    @State private var ascending = true
    @State private var reader: ReaderTarget?
    @ObservedObject private var store = MangaStore.shared
    private var provider: MangaProvider { MangaFixtures.provider ?? item.source.provider }

    struct ReaderTarget: Identifiable { let chapters: [MangaChapter]; let index: Int; let page: Int; var id: Int { index } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: detail?.item.cover ?? item.cover, headers: provider.imageHeaders, corner: 10).frame(width: 110, height: 147)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail?.item.title ?? item.title).font(.title3.weight(.bold)).foregroundStyle(STVTheme.text)
                        if let a = detail?.item.author ?? Optional(item.author), !a.isEmpty { Text(a).font(.subheadline).foregroundStyle(STVTheme.secondary) }
                        Text(([detail?.status ?? ""] + (detail?.item.tags ?? item.tags)).filter { !$0.isEmpty }.prefix(5).joined(separator: " · "))
                            .font(.caption).foregroundStyle(STVTheme.secondary)
                        Text(item.source.label).font(.caption2).foregroundStyle(STVTheme.accent)
                        HStack {
                            Button { store.toggleFavorite(detail?.item ?? item) } label: {
                                Label(store.isFavorite(item) ? "已收藏" : "收藏", systemImage: store.isFavorite(item) ? "heart.fill" : "heart")
                            }.buttonStyle(.bordered).tint(STVTheme.accent).accessibilityIdentifier("manga.favorite")
                            if let d = detail, !d.chapters.isEmpty { readButton(d) }
                        }.padding(.top, 4)
                    }
                }
                if let d = detail, !d.desc.isEmpty { Text(d.desc).font(.footnote).foregroundStyle(STVTheme.secondary).lineLimit(6) }
                if let error { Text(error).font(.caption).foregroundStyle(STVTheme.accentWarm) }
                if let d = detail {
                    HStack {
                        Text("章节（\(d.chapters.count)）").font(.headline).foregroundStyle(STVTheme.text)
                        Spacer()
                        Button(ascending ? "正序" : "倒序") { ascending.toggle() }.font(.subheadline)
                    }
                    let list = ascending ? d.chapters : d.chapters.reversed()
                    LazyVStack(spacing: 0) {
                        ForEach(list) { c in chapterRow(d, c) }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }.padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .zoomDestination("manga:" + item.id, ns)
        .task {
            do { detail = try await provider.detail(item) } catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(item: $reader) { r in MangaReaderView(item: detail?.item ?? item, chapters: r.chapters, index: r.index, startPage: r.page) }
    }

    @ViewBuilder private func readButton(_ d: MangaDetail) -> some View {
        if let p = store.progress[item.id], let i = d.chapters.firstIndex(where: { $0.chapterId == p.chapterId }) {
            Button("续读 \(p.chapterTitle.prefix(8))") { reader = ReaderTarget(chapters: d.chapters, index: i, page: p.page) }
                .buttonStyle(.borderedProminent).tint(STVTheme.accent).accessibilityIdentifier("manga.read")
        } else {
            Button("开始阅读") { reader = ReaderTarget(chapters: d.chapters, index: 0, page: 0) }
                .buttonStyle(.borderedProminent).tint(STVTheme.accent).accessibilityIdentifier("manga.read")
        }
    }

    private func chapterRow(_ d: MangaDetail, _ c: MangaChapter) -> some View {
        let off = store.offlineState(d.item, c)
        let reading = store.progress[item.id]?.chapterId == c.chapterId
        return HStack {
            Button { reader = ReaderTarget(chapters: d.chapters, index: c.index, page: reading ? store.progress[item.id]!.page : 0) } label: {
                HStack {
                    Text(c.title).font(.subheadline).foregroundStyle(reading ? STVTheme.accent : STVTheme.text).lineLimit(1)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("manga.chapter.\(c.index)")
            Group {
                switch off?.state {
                case .done?: Button { store.deleteOffline(d.item, c) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                case .running?: Text("\(off!.files.count)/\(max(off!.total, 1))").font(.caption2.monospacedDigit()).foregroundStyle(STVTheme.secondary)
                case .failed?: Button { store.download(d.item, c) } label: { Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange) }
                case nil: Button { store.download(d.item, c) } label: { Image(systemName: "arrow.down.circle").foregroundStyle(STVTheme.secondary) }
                }
            }.buttonStyle(.borderless).accessibilityIdentifier("manga.dl.\(c.index)")
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().overlay(STVTheme.text.opacity(0.06)) }
    }
}

/// Reader: vertical webtoon scroll or horizontal paging, preloads the next pages, zoom, progress.
struct MangaReaderView: View {
    let item: MangaItem
    let chapters: [MangaChapter]
    @State var index: Int
    var startPage = 0
    /// Chapter `startPage` belongs to (the one the reader opened on); other chapters start at page 1.
    @State private var startChapter: Int?
    @AppStorage("stv.manga.vertical") private var vertical = true
    @State private var pages: [String] = []
    @State private var page = 0
    @State private var error: String?
    @State private var chrome = true
    @State private var zoomed = false
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var visible: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MangaStore.shared
    private var provider: MangaProvider { MangaFixtures.provider ?? item.source.provider }
    private var chapter: MangaChapter { chapters[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if pages.isEmpty {
                if let error { VStack(spacing: 12) { Text(error).foregroundStyle(.white); Button("重试") { Task { await load() } } } }
                else { ProgressView().tint(.white) }
            } else if vertical { verticalReader } else { pagedReader }
            if chrome { overlay }
        }
        .statusBarHidden(!chrome)
        .task(id: index) { await load() }
        .onChange(of: page) { p in
            store.record(item, chapter, page: p, of: pages.count)
            preload(from: p)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manga.reader")
        .preferredColorScheme(.dark)
        .onChange(of: vertical) { _ in visible = [] }
    }

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            // Zoom = wider content (pages fit width × scale), so both axes scroll to every edge.
            GeometryReader { geo in
                ScrollView(scale > 1.01 ? [.vertical, .horizontal] : .vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(pages.indices, id: \.self) { i in
                            MangaPageImage(url: pages[i], headers: provider.imageHeaders)
                                .id(i)
                                // Current page = topmost page on screen.
                                .onAppear { visible.insert(i); page = visible.min() ?? i }
                                .onDisappear { visible.remove(i); if let m = visible.min() { page = m } }
                                .accessibilityIdentifier("manga.page.\(i)")
                        }
                        chapterEnd
                    }
                    .frame(width: geo.size.width * scale)
                }
            }
            .gesture(MagnificationGesture().onChanged { scale = max(1, min(3, baseScale * $0)) }.onEnded { _ in baseScale = scale })
            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2; baseScale = scale } }
            .onTapGesture { withAnimation { chrome.toggle() } }
            .onAppear { let target = page; if target > 0 { proxy.scrollTo(target, anchor: .top) } }
        }
    }

    private var pagedReader: some View {
        TabView(selection: $page) {
            ForEach(pages.indices, id: \.self) { i in
                ZoomableImage(url: pages[i], headers: provider.imageHeaders, zoomed: $zoomed).tag(i)
                    .accessibilityIdentifier("manga.page.\(i)")
            }
            chapterEnd.tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Zoomed: drags pan the image instead of turning the page (zoom out, or double tap, to page again).
        .scrollDisabled(zoomed)
        .onTapGesture(coordinateSpace: .global) { p in pagedTap(p) }
    }

    /// Paged mode tap zones: left third = previous page, right third = next (past the last page → next
    /// chapter), middle = show / hide the bar. Zoomed pages leave taps to the image.
    private func pagedTap(_ p: CGPoint) {
        let w = UIScreen.main.bounds.width
        guard !zoomed, w > 0 else { withAnimation { chrome.toggle() }; return }
        let x = p.x / w
        if x < 1.0 / 3, page > 0 {
            withAnimation(.easeOut(duration: 0.22)) { page -= 1 }
        } else if x > 2.0 / 3 {
            if page < pages.count { withAnimation(.easeOut(duration: 0.22)) { page += 1 } }
            else if index + 1 < chapters.count { index += 1 }
        } else {
            withAnimation { chrome.toggle() }
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var chapterEnd: some View {
        VStack(spacing: 14) {
            Text("本章完").foregroundStyle(.white.opacity(0.7))
            if index + 1 < chapters.count {
                Button("下一章：\(chapters[index + 1].title)") { index += 1 }.buttonStyle(.borderedProminent).tint(STVTheme.accent)
                    .accessibilityIdentifier("manga.nextChapter")
            } else { Text("已是最新一章").font(.caption).foregroundStyle(.white.opacity(0.5)) }
        }.frame(maxWidth: .infinity, minHeight: 240)
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle()) }
                    .accessibilityIdentifier("manga.close").accessibilityLabel("关闭")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(chapter.title).font(.caption).lineLimit(1).opacity(0.7)
                }
                Spacer()
                Button { vertical.toggle() } label: {
                    Image(systemName: vertical ? "rectangle.split.1x2" : "rectangle.split.2x1").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                }.accessibilityIdentifier("manga.mode").accessibilityLabel(vertical ? "切换为左右翻页" : "切换为上下滚动")
            }.foregroundStyle(.white).padding(.horizontal, 14)
            Spacer()
            HStack {
                Button { if index > 0 { index -= 1 } } label: { Image(systemName: "backward.end.fill") }.disabled(index == 0)
                Spacer()
                Text(pages.isEmpty ? "" : "\(min(page, pages.count - 1) + 1) / \(pages.count)").font(.caption.monospacedDigit())
                    .accessibilityIdentifier("manga.pageCounter")
                Spacer()
                Button { if index + 1 < chapters.count { index += 1 } } label: { Image(systemName: "forward.end.fill") }.disabled(index + 1 >= chapters.count)
            }
            .foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule()).padding(.horizontal, 30).padding(.bottom, 10)
        }
    }

    private func load() async {
        pages = []; error = nil; page = 0; visible = []
        if let local = store.localPages(item, chapter) { pages = local }
        else {
            do { pages = try await provider.pages(item, chapter) } catch { self.error = error.localizedDescription; return }
        }
        if startChapter == nil { startChapter = index }
        page = index == startChapter ? min(startPage, max(0, pages.count - 1)) : 0
        store.record(item, chapter, page: page, of: pages.count)
        preload(from: page)
    }

    /// Warm the image cache for the next few pages.
    private func preload(from p: Int) {
        let next = pages.dropFirst(p + 1).prefix(4)
        let h = provider.imageHeaders
        for u in next { Task { _ = try? await CoverStore.shared.image(url: u, headers: h) } }
    }
}

/// Full-width page that keeps the image's aspect ratio.
struct MangaPageImage: View {
    let url: String
    var headers: [String: String] = [:]
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit) }
            else if failed {
                Button { failed = false; Task { await load() } } label: { Label("加载失败，点我重试", systemImage: "arrow.clockwise").foregroundStyle(.white.opacity(0.6)) }
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else { ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 420) }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        do { image = try await CoverStore.shared.image(url: url, headers: headers) } catch { failed = true }
    }
}

/// DEBUG `STV_MANGA_FIXTURE=1`: an offline provider with solid-colour pages (UI tests / screenshots).
enum MangaFixtures {
    static var provider: MangaProvider? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_MANGA_FIXTURE"] == "1" { return FixtureMangaProvider() }
        #endif
        return nil
    }
}

#if DEBUG
struct FixtureMangaProvider: MangaProvider {
    var source: MangaSourceID { .baozi }
    var categories: [MangaCategory] { [MangaCategory(id: "all|all", title: "全部")] }
    var imageHeaders: [String: String] { [:] }
    static let colors = ["3D5A80", "98C1D9", "EE6C4D", "293241", "6A994E", "BC4749", "F2CC8F", "81B29A"]
    func list(_ c: MangaCategory, page: Int) async throws -> MangaPage {
        MangaPage(items: (0..<9).map { MangaItem(source: .baozi, mangaId: "fx\($0)", title: "示例漫画 \($0 + 1)", cover: "fixture://" + Self.colors[$0 % 8], tags: ["示例"]) }, hasMore: false)
    }
    func search(_ q: String, page: Int) async throws -> MangaPage { try await list(categories[0], page: 1) }
    func detail(_ m: MangaItem) async throws -> MangaDetail {
        MangaDetail(item: m, desc: "占位数据，用于界面测试。", status: "连载中", chapters: (0..<3).map { MangaChapter(chapterId: "0_\($0)", title: "第\($0 + 1)话", index: $0) })
    }
    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String] { (0..<5).map { "fixture://" + Self.colors[($0 + c.index) % 8] } }
}
#endif
