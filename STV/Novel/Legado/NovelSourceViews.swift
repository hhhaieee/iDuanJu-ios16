import SwiftUI
import UniformTypeIdentifiers

/// 书源管理: import 「阅读」(Legado) JSON sources from a URL, the clipboard or a file; toggle / delete.
struct NovelSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LegadoSourceStore.shared
    @State private var askURL = false
    @State private var urlText = ""
    @State private var fileImport = false
    @State private var message: String?
    @State private var busy = false
    @State private var login: LegadoSource?

    var body: some View {
        NavigationStack {
            List {
                if store.sources.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView {
                            Label("还没有书源", systemImage: "books.vertical")
                        } description: {
                            Text("点右上角 ＋ 导入「阅读」(Legado) 的书源 JSON：网络地址、剪贴板或文件都可以。\nApp 不内置任何书源。")
                        }
                    } else {
                        EmptyStateView(title: "还没有书源", systemImage: "books.vertical", description: "点右上角 ＋ 导入「阅读」(Legado) 的书源 JSON：网络地址、剪贴板或文件都可以。App 不内置任何书源。")
                    }
                }
                Section {
                    ForEach(store.sources) { s in row(s) }
                        .onDelete { idx in store.remove(Set(idx.map { store.sources[$0].id })) }
                } footer: {
                    if !store.sources.isEmpty {
                        Text("共 \(store.sources.count) 个，启用 \(store.enabled.count) 个。需要登录的书源（带 👤 图标）长按或右滑选「登录」。支持「阅读」3.x 的文本书源（JSoup / CSS / XPath / JSONPath / 正则 / JS 规则）；需要网页渲染、登录的书源和有声书源暂不支持。")
                    }
                }
            }
            .navigationTitle("书源")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $login) { s in NovelSourceLoginView(source: s) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("网络导入", systemImage: "link") { urlText = ""; askURL = true }
                        Button("从剪贴板导入", systemImage: "doc.on.clipboard") { importClipboard() }
                        Button("从文件导入", systemImage: "folder") { fileImport = true }
                    } label: { if busy { ProgressView() } else { Image(systemName: "plus") } }
                    .accessibilityIdentifier("sources.add")
                }
            }
            .alert("网络导入", isPresented: $askURL) {
                TextField("https://…/sources.json", text: $urlText).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("取消", role: .cancel) {}
                Button("导入") { importURL() }
            } message: { Text("输入书源 JSON 的网址") }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") {} }
            .fileImporter(isPresented: $fileImport, allowedContentTypes: [.json, .plainText, .text]) { r in
                guard case .success(let url) = r else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                report { try store.add(LegadoSourceStore.parse(try Data(contentsOf: url))) }
            }
        }
    }

    private func row(_ s: LegadoSource) -> some View {
        Toggle(isOn: Binding(get: { s.isOn }, set: { store.setEnabled(s, $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.bookSourceName).font(.system(size: 16))
                    if s.hasLogin {
                        Image(systemName: LegadoSourceState.isLoggedIn(s.bookSourceUrl) ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                            .font(.caption).foregroundStyle(LegadoSourceState.isLoggedIn(s.bookSourceUrl) ? .green : .secondary)
                    }
                }
                Text([s.bookSourceGroup, URL(string: s.bookSourceUrl)?.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !s.supported { Text("暂不支持（非文本书源或没有搜索地址）").font(.caption).foregroundStyle(.orange) }
            }
        }
        .disabled(!s.supported)
        .swipeActions(edge: .leading) {
            if s.hasLogin { Button("登录") { login = s }.tint(.blue) }
        }
        .contextMenu {
            if s.hasLogin { Button("登录", systemImage: "person.crop.circle") { login = s } }
        }
    }

    private func report(_ f: () throws -> (added: Int, updated: Int, unsupported: Int)) {
        do {
            let r = try f()
            message = "新增 \(r.added) 个，更新 \(r.updated) 个" + (r.unsupported > 0 ? "，其中 \(r.unsupported) 个暂不支持" : "")
        } catch {
            message = "导入失败：不是有效的书源 JSON"
        }
    }

    private func importClipboard() {
        guard let t = UIPasteboard.general.string, !t.isEmpty else { message = "剪贴板是空的"; return }
        if let u = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true { urlText = u.absoluteString; importURL(); return }
        report { try store.importText(t) }
    }

    private func importURL() {
        guard let u = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true else { message = "网址无效"; return }
        busy = true
        Task {
            do { let r = try await store.importURL(u); report { r } }
            catch { message = "导入失败：\(error.localizedDescription)" }
            busy = false
        }
    }
}

// MARK: - 搜书

/// Searches every enabled 书源 at once; results are merged by 书名 + 作者 as sources answer.
struct NovelSearchView: View {
    var onRead: (NovelBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sources = LegadoSourceStore.shared
    @State private var query = ""
    @State private var groups: [Group] = []
    @State private var done = 0
    @State private var total = 0
    @State private var failures = 0
    @State private var task: Task<Void, Never>?
    @State private var manage = false

    struct Group: Identifiable, Hashable {
        var name: String
        var author: String
        var items: [LegadoSearchItem]
        var id: String { name + "|" + author }
    }

    var body: some View {
        NavigationStack {
            List {
                if sources.enabled.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView {
                            Label("还没有可用的书源", systemImage: "magnifyingglass")
                        } description: { Text("先在「书源」里导入「阅读」(Legado) 书源") } actions: {
                            Button("管理书源") { manage = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        EmptyStateView(title: "还没有可用的书源", systemImage: "magnifyingglass", description: "先在「书源」里导入「阅读」(Legado) 书源", actions: AnyView(Button("管理书源") { manage = true }.buttonStyle(.borderedProminent)))
                    }
                } else if total > 0 {
                    Section {
                        ForEach(groups) { g in
                            NavigationLink(value: g) { resultRow(g) }
                                .accessibilityIdentifier("search.result.\(g.name)")
                        }
                    } header: {
                        HStack {
                            Text(done < total ? "正在搜索 \(done)/\(total) 个书源" : "共 \(groups.count) 本 · \(total) 个书源" + (failures > 0 ? " · \(failures) 个失败" : ""))
                            if done < total { ProgressView().controlSize(.small) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("搜书")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "书名或作者")
            .onSubmit(of: .search) { run() }
            .navigationDestination(for: Group.self) { g in NovelWebDetailView(items: g.items, onRead: onRead) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("书源") { manage = true }.accessibilityIdentifier("search.sources") }
            }
            .sheet(isPresented: $manage) { NovelSourcesView() }
        }
    }

    private func resultRow(_ g: Group) -> some View {
        let first = g.items[0]
        return HStack(alignment: .top, spacing: 12) {
            WebCover(url: g.items.first { !$0.cover.isEmpty }?.cover, title: g.name).frame(width: 56, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(g.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text([g.author, first.kind].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !first.latest.isEmpty { Text("最新：" + first.latest).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text("\(g.items.count) 个书源 · \(first.sourceName)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        task?.cancel()
        groups = []; done = 0; failures = 0
        let list = sources.enabled
        total = list.count
        task = Task {
            await withTaskGroup(of: (Bool, [LegadoSearchItem]).self) { tg in
                var it = list.makeIterator()
                func add() -> Bool {
                    guard let s = it.next() else { return false }
                    tg.addTask {
                        do { return (true, try await LegadoClient.run { try LegadoClient.search(s, key: q) }) } catch { return (false, []) }
                    }
                    return true
                }
                for _ in 0..<8 { if !add() { break } }
                for await (ok, items) in tg {
                    if Task.isCancelled { tg.cancelAll(); return }
                    done += 1
                    if !ok { failures += 1 }
                    merge(items, query: q)
                    _ = add()
                }
            }
        }
    }

    private func merge(_ items: [LegadoSearchItem], query q: String) {
        for it in items {
            let author = it.author.trimmingCharacters(in: .whitespaces)
            if let i = groups.firstIndex(where: { $0.name == it.name && ($0.author == author || $0.author.isEmpty || author.isEmpty) }) {
                if !groups[i].items.contains(where: { $0.sourceURL == it.sourceURL }) { groups[i].items.append(it) }
            } else {
                groups.append(Group(name: it.name, author: author, items: [it]))
            }
        }
        // Exact title first, then titles containing the query, then by number of sources.
        groups.sort { a, b in
            func rank(_ g: Group) -> Int { g.name == q ? 0 : g.name.contains(q) || g.author == q ? 1 : 2 }
            return (rank(a), -a.items.count) < (rank(b), -b.items.count)
        }
    }
}

/// Cover from a URL with a generated fallback.
struct WebCover: View {
    var url: String?
    var title: String
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else {
                let h = abs(title.hashValue % 360)
                LinearGradient(colors: [Color(hue: Double(h) / 360, saturation: 0.35, brightness: 0.72), Color(hue: Double(h) / 360, saturation: 0.45, brightness: 0.48)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(4))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 详情

struct NovelWebDetailView: View {
    let items: [LegadoSearchItem]
    var onRead: (NovelBook) -> Void
    @State private var pick = 0
    @State private var info: LegadoBookInfo?
    @State private var toc: [LegadoChapter]?
    @State private var error: String?
    @State private var loading = false
    @ObservedObject private var store = NovelStore.shared

    private var item: LegadoSearchItem { items[min(pick, items.count - 1)] }
    private var source: LegadoSource? { LegadoSourceStore.shared.source(item.sourceURL) }
    private var onShelf: NovelBook? { store.webBook(source: item.sourceURL, url: item.bookURL) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    WebCover(url: (info?.cover).flatMap { $0.isEmpty ? nil : $0 } ?? item.cover, title: item.name).frame(width: 100, height: 136)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info?.name.isEmpty == false ? info!.name : item.name).font(.system(size: 21, weight: .bold))
                        Text(info?.author.isEmpty == false ? info!.author : item.author).foregroundStyle(.secondary)
                        let kind = info?.kind.isEmpty == false ? info!.kind : item.kind
                        if !kind.isEmpty { Text(kind).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let toc { Text("共 \(toc.count) 章").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Menu {
                    ForEach(items.indices, id: \.self) { i in
                        Button { pick = i; Task { await load() } } label: { Label(items[i].sourceName, systemImage: i == pick ? "checkmark" : "book") }
                    }
                } label: {
                    HStack { Text("书源：\(item.sourceName)"); Spacer(); Text(items.count > 1 ? "换源（\(items.count)）" : "").foregroundStyle(.secondary); Image(systemName: "chevron.up.chevron.down") }
                        .font(.system(size: 14)).padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                }
                .accessibilityIdentifier("detail.source")
                let intro = (info?.intro.isEmpty == false ? info!.intro : item.intro).trimmingCharacters(in: .whitespacesAndNewlines)
                if !intro.isEmpty { Text(intro).font(.system(size: 15)).lineSpacing(5) }
                if let latest = (info?.latest).flatMap({ $0.isEmpty ? nil : $0 }) ?? (item.latest.isEmpty ? nil : item.latest) {
                    Label("最新：\(latest)", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if loading { HStack { ProgressView(); Text("正在读取目录…").foregroundStyle(.secondary) } }
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.red).font(.callout)
                        Button("重试") { Task { await load() } }
                        if items.count > 1 { Text("也可以在上面换一个书源").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { read(open: false) } label: { Text(onShelf == nil ? "加入书架" : "已在书架").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered).disabled(toc == nil || onShelf != nil)
                    .accessibilityIdentifier("detail.add")
                Button { read(open: true) } label: { Text("开始阅读").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).disabled(toc?.isEmpty != false && onShelf == nil)
                    .accessibilityIdentifier("detail.read")
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let source else { error = "书源已删除"; return }
        loading = true; error = nil; info = nil; toc = nil
        let it = item
        do {
            let i = try await LegadoClient.run { try LegadoClient.info(source, bookURL: it.bookURL) }
            info = i
            let book: [String: String] = ["name": i.name, "author": i.author, "bookUrl": it.bookURL]
            let t = try await LegadoClient.run { try LegadoClient.toc(source, tocURL: i.tocURL, book: book) }
            if t.isEmpty { error = "这个书源没有返回目录" } else { toc = t }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func read(open: Bool) {
        let b = onShelf ?? store.addWeb(item, info: info, toc: toc ?? [])
        if open { onRead(b) }
    }
}
