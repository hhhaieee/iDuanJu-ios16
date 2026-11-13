import SwiftUI

struct LibraryListView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.zoomNS) private var ns
    @State private var confirmClear = false

    var body: some View {
        Group {
            if kind == .favorites {
                ScrollView {
                    if library.favorites.isEmpty { empty("还没有收藏", "heart") }
                    else { NumberedGrid(items: library.favorites, numbered: false).padding(.vertical, 8) }
                }
            } else if library.continueWatching.isEmpty {
                ScrollView { empty("还没有观看记录", "clock") }
            } else {
                // Deleting a record (issue #3): ✕ on every row, swipe left, or long-press anywhere on the row;
                // 清空 in the bar removes all of them after a confirmation.
                List {
                    ForEach(library.continueWatching) { p in historyRow(p) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle(kind == .favorites ? "我的收藏" : "观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if kind == .history, !library.continueWatching.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { confirmClear = true }.accessibilityIdentifier("history.clear")
                }
            }
        }
        .confirmationDialog("清空全部观看记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空 \(library.continueWatching.count) 条记录", role: .destructive) { withAnimation { library.clearHistory() } }
        } message: {
            Text("只删除本机的观看进度，收藏不受影响。")
        }
    }

    private func historyRow(_ p: WatchProgress) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverView(url: p.series.cover, corner: 8).frame(width: 64, height: 86).zoomSource(p.series.id, ns)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.series.title).font(.headline).foregroundStyle(STVTheme.text).lineLimit(1)
                    Text(p.series.source.isLongVideo ? p.resumeLabel : "看到第\(p.episodeNumber)集 · \(Fmt.duration(Int(p.seconds)))")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                    ProgressView(value: p.fraction).tint(STVTheme.accent)
                }
                Spacer(minLength: 0)
            }
            // Whole row is the hit area, not just the cover / text (long-press used to miss the gaps).
            .contentShape(Rectangle())
            // Hidden link: a NavigationLink directly in a List row adds a disclosure chevron next to the ✕.
            .background { NavigationLink(value: Route.series(p.series)) { EmptyView() }.opacity(0) }
            Button { withAnimation { library.removeProgress(p.series) } } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除观看记录")
            .accessibilityIdentifier("history.delete")
        }
        .contentShape(Rectangle())
        .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { library.removeProgress(p.series) } }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { library.removeProgress(p.series) } label: { Label("删除", systemImage: "trash") }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
    }

    @ViewBuilder
    private func empty(_ t: String, _ icon: String) -> some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(t, systemImage: icon).padding(.top, 80)
        } else {
            EmptyStateView(title: t, systemImage: icon).padding(.top, 80)
        }
    }
}
