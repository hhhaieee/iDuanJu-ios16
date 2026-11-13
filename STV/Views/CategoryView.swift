import SwiftUI

/// 找剧: 榜单 (pill sub-tabs + numbered grid) / 筛选找片 (hongguo filter panel).
struct CategoryView: View {
    enum Mode: String, CaseIterable { case rank = "榜单", filter = "筛选找片" }
    @State private var mode: Mode = .rank
    @State private var genre: HGRankGenre = .all
    @State private var sub: HGRankSub = .hotSearch
    @State private var panel: HGPanel?
    @State private var panelError: Error?
    @State private var selected: [String: String] = [:]
    @StateObject private var pager = Pager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button { withAnimation(.snappy) { mode = m } } label: {
                            Text(m.rawValue).font(mode == m ? .title2.weight(.heavy) : .body)
                                .foregroundStyle(mode == m ? STVTheme.accent : STVTheme.secondary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)

                if mode == .rank {
                    PillTabs(items: HGRankGenre.allCases, selection: $genre) { $0.label }
                    PillTabs(items: genre.subs, selection: $sub) { $0.label }
                } else if let panel {
                    ForEach(panel.rows) { row in
                        let opts = [HGFilterOption(id: "", name: "全部")] + row.items
                        PillTabs(items: opts, selection: Binding(
                            get: { opts.first { $0.id == (selected[row.type] ?? "") } ?? opts[0] },
                            set: { selected[row.type] = $0.id; reload() })) { $0.name }
                    }
                } else if let panelError {
                    ErrorStateView(error: panelError) { Task { await loadPanel() } }
                }

                if let e = pager.error, pager.items.isEmpty { ErrorStateView(error: e) { reload() } }
                else { NumberedGrid(items: pager.items, numbered: mode == .rank, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() } }
            }.padding(.vertical, 10)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { if pager.items.isEmpty { reload() } }
        .onChange(of: mode) { Task { if mode == .filter, panel == nil { await loadPanel() }; reload() } }
        .onChange(of: genre) { if !genre.subs.contains(sub) { sub = genre.subs[0] }; reload() }
        .onChange(of: sub) { reload() }
    }

    private func loadPanel() async {
        do { panel = try await HongguoClient.shared.panel(); panelError = nil } catch { panelError = error }
    }

    private func reload() {
        if mode == .rank {
            let b = BoardSpec(kind: .hongguo(genre, sub))
            pager.reset { try await b.fetch($0, $1) }
        } else {
            let ids = selected.values.filter { !$0.isEmpty }.sorted()
            pager.reset { prev, _ in try await HongguoClient.shared.category(filterIds: ids, offset: prev.nextOffset ?? 0, sessionId: prev.sessionId) }
        }
    }
}
