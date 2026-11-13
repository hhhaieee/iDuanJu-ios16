import SwiftUI

// MARK: Search bar

struct SearchBarButton: View {
    var placeholder = "搜索短剧 / 演员"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(STVTheme.secondary)
            Text(placeholder).foregroundStyle(STVTheme.secondary).lineLimit(1)
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 14).frame(height: 44)
        .background(STVTheme.glass, in: Capsule())
        .overlay { Capsule().strokeBorder(STVTheme.glassBorder) }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索短剧 / 演员"
    var onSubmit: () -> Void
    var onCancel: (() -> Void)?
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(STVTheme.secondary)
                TextField(placeholder, text: $text)
                    .focused($focused).submitLabel(.search).onSubmit(onSubmit)
                    .foregroundStyle(STVTheme.text)
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(STVTheme.secondary) }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14).frame(height: 38)
            .background(STVTheme.elevated, in: Capsule())
            if let onCancel {
                Button("取消", action: onCancel).foregroundStyle(STVTheme.text).font(.subheadline)
            } else {
                Button("搜索", action: onSubmit).foregroundStyle(STVTheme.text).font(.subheadline.weight(.semibold))
            }
        }
    }
}

// MARK: Tabs

struct TextTabStrip<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        GlassChip(title: label(item), selected: selection == item) { selection = item }
                            .id(item)
                    }
                }.padding(.horizontal, 16)
            }
            .onChange(of: selection) { item in withAnimation(.snappy) { proxy.scrollTo(item, anchor: .center) } }
        }
    }
}

/// Small pill tabs (热搜 / 电视剧 / …).
struct PillTabs<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { it in
                    let on = it == selection
                    Button { withAnimation(.snappy) { selection = it } } label: {
                        Text(label(it))
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? STVTheme.bg : STVTheme.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(on ? STVTheme.text : STVTheme.glass, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
    }
}

struct ChipFlow: View {
    let items: [String]
    var accent: (String) -> String? = { _ in nil }
    /// Non-nil → edit mode: each chip shows ✕ and tapping removes it (最近搜索单条删除).
    var onRemove: ((String) -> Void)? = nil
    let tap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { t in
                    Button { tap(t) } label: {
                        HStack(spacing: 2) {
                            Text(t).foregroundStyle(STVTheme.text)
                            if let a = accent(t) { Text("·" + a).foregroundStyle(STVTheme.accentWarm) }
                            if onRemove != nil {
                                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(STVTheme.secondary).padding(.leading, 4)
                            }
                        }
                        .font(.subheadline).lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(STVTheme.text.opacity(0.09), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
    }
}

// MARK: Rank numerals

enum RankStyle {
    static func color(_ r: Int) -> Color {
        switch r { case 1: Color(red: 1, green: 0.27, blue: 0.2); case 2: Color(red: 1, green: 0.55, blue: 0.15); case 3: Color(red: 1, green: 0.78, blue: 0.2); default: .white.opacity(0.85) }
    }
    static func gradient(_ r: Int) -> LinearGradient {
        let c: [Color] = switch r {
        case 1: [Color(red: 0.95, green: 0.25, blue: 0.3), Color(red: 0.75, green: 0.1, blue: 0.2)]
        case 2: [Color(red: 0.25, green: 0.35, blue: 0.95), Color(red: 0.15, green: 0.2, blue: 0.7)]
        default: [Color(red: 0.98, green: 0.45, blue: 0.25), Color(red: 0.85, green: 0.25, blue: 0.15)]
        }
        return LinearGradient(colors: c, startPoint: .top, endPoint: .bottom)
    }
}

struct RankNumeral: View {
    let rank: Int
    var size: CGFloat = 17
    var body: some View {
        Text("\(rank)")
            .font(.system(size: size, weight: .black, design: .rounded)).italic()
            .foregroundStyle(RankStyle.color(rank))
            .frame(minWidth: size * 0.9)
    }
}

// MARK: Home board

struct RankCard: View {
    let board: BoardSpec
    let items: [HGSeries]
    let loading: Bool
    var body: some View {
        HStack(spacing: 14) {
            if let first = items.first {
                CoverView(url: first.cover, corner: 10).frame(width: 76, height: 110)
            } else if loading {
                ShimmerBlock().frame(width: 76, height: 110)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(board.title).font(.headline).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                }
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1)).font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(i == 0 ? STVTheme.accent : STVTheme.secondary)
                        if items.indices.contains(i) {
                            Text(items[i].title).font(.subheadline).lineLimit(1)
                        } else if loading {
                            ShimmerBlock().frame(height: 12)
                        } else {
                            Text("—").font(.subheadline).foregroundStyle(STVTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(height: 22)
                }
            }
        }
        .foregroundStyle(STVTheme.text).padding(14)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(STVTheme.glassBorder) }
    }
}

// MARK: Grid cell with big italic rank

struct NumberedPosterCell: View {
    let series: HGSeries
    let rank: Int?
    @Environment(\.zoomNS) private var ns
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(url: series.cover, corner: 10)
                    .aspectRatio(series.isLandscapeCover ? 16/10 : 3/4, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text(String(format: "%02d", rank))
                                .font(.system(size: 26, weight: .black, design: .rounded)).italic()
                                .foregroundStyle(.white)
                                .shadow(color: rank <= 3 ? RankStyle.color(rank) : .black, radius: 0, x: 2, y: 2)
                                .padding(.leading, 4).offset(y: -4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if series.isNew {
                            Text("新剧").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        let m = Fmt.meta(series)
                        if !m.isEmpty {
                            Text(m).font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                    .zoomSource(series.id, ns)
                Text(series.title).font(.subheadline).foregroundStyle(STVTheme.text).lineLimit(series.isLandscapeCover ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct NumberedGrid: View {
    let items: [HGSeries]
    var numbered = true
    var hasMore = false
    var loading = false
    var loadMore: () -> Void = {}
    private var landscape: Bool { items.first?.isLandscapeCover ?? false }
    private var cols: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: landscape ? 2 : 3) }
    var body: some View {
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                NumberedPosterCell(series: s, rank: numbered ? i + 1 : nil)
                    .onAppear { if i == items.count - 1, hasMore, !loading { loadMore() } }
            }
            if loading {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerBlock().aspectRatio(landscape ? 16/10 : 3/4, contentMode: .fit)
                        ShimmerBlock().frame(height: 12)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        if !hasMore && !loading && !items.isEmpty {
            Text("没有更多了").font(.caption).foregroundStyle(STVTheme.secondary).frame(maxWidth: .infinity).padding()
        }
    }
}

// MARK: Search ranking

struct TopRankCard: View {
    let series: HGSeries
    let rank: Int
    @Environment(\.zoomNS) private var ns
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            ZStack(alignment: .bottom) {
                CoverView(url: series.cover, corner: 0)
                RankStyle.gradient(rank).mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom))
                VStack(spacing: 2) {
                    Text("TOP\(rank)").font(.system(size: 24, weight: .black, design: .rounded))
                    Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(Fmt.meta(series)).font(.caption2).opacity(0.8).lineLimit(1)
                }
                .foregroundStyle(.white).padding(.horizontal, 6).padding(.bottom, 10)
            }
            .aspectRatio(0.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .zoomSource(series.id, ns)
        }.buttonStyle(.plain)
    }
}

struct CompactRankRow: View {
    @Environment(\.zoomNS) private var ns
    let series: HGSeries
    let rank: Int
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            HStack(spacing: 10) {
                CoverView(url: series.cover, corner: 6)
                    .frame(width: 46, height: 62)
                    .zoomSource(series.id, ns)
                    .overlay(alignment: .topTrailing) {
                        Text("\(rank)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(rank <= 3 ? RankStyle.color(rank) : Color(red: 0.8, green: 0.15, blue: 0.25), in: RoundedRectangle(cornerRadius: 3))
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(series.title).font(.subheadline).foregroundStyle(STVTheme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        if series.playCount > 0 { Text(Fmt.count(series.playCount)).foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.3)) }
                        Text(series.episodeCount > 0 ? "\(series.episodeCount)集" : "短剧").foregroundStyle(STVTheme.secondary)
                    }.font(.caption)
                }
                Spacer(minLength: 0)
            }
        }.buttonStyle(.plain)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(STVTheme.text)
            Spacer()
            trailing
        }.padding(.horizontal, 16)
    }
}

// MARK: Continue watching

struct ContinueRow: View {
    @Environment(\.zoomNS) private var ns
    let items: [WatchProgress]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "继续观看", trailing: AnyView(NavigationLink(value: Route.history) {
                Text("全部").font(.subheadline).foregroundStyle(STVTheme.secondary)
            }))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items.prefix(10)) { p in
                        NavigationLink(value: Route.series(p.series)) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverView(url: p.series.cover, corner: 10)
                                    .frame(width: 112, height: 150)
                                    .zoomSource(p.series.id, ns)
                                    .overlay(alignment: .bottom) {
                                        VStack(spacing: 4) {
                                            Spacer()
                                            Text(p.resumeLabel).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            GeometryReader { g in
                                                Capsule().fill(.white.opacity(0.25))
                                                    .overlay(alignment: .leading) { Capsule().fill(STVTheme.accent).frame(width: g.size.width * p.fraction) }
                                            }.frame(height: 3).padding(.horizontal, 8).padding(.bottom, 8)
                                        }
                                        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                Text(p.series.title).font(.caption).foregroundStyle(STVTheme.text).lineLimit(1).frame(width: 112, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                        .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { LibraryStore.shared.removeProgress(p.series) } }
                    }
                }.padding(.horizontal, 16)
            }
            // Content narrower than the screen → don't grab horizontal drags (首页横滑翻来源页).
            .compatScrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}
