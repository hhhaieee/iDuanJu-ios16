import SwiftUI
import UIKit

struct EpisodeRange: Hashable {
    let start: Int
    let end: Int
    init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
}

enum EpisodeGroups {
    /// Group size: 30 (≤300 eps), 50 (≤600), 60 (more). Small totals stay in one group.
    static func size(for total: Int) -> Int {
        if total <= 60 { return max(total, 1) }
        if total <= 300 { return 30 }
        if total <= 600 { return 50 }
        return 60
    }
    static func ranges(total: Int) -> [EpisodeRange] {
        guard total > 0 else { return [] }
        let g = size(for: total)
        if total <= g { return [EpisodeRange(0, total - 1)] }
        var out: [EpisodeRange] = []
        var i = 0
        while i < total {
            out.append(EpisodeRange(i, min(i + g - 1, total - 1)))
            i += g
        }
        return out
    }
    static func label(_ r: EpisodeRange, episodes: [HGEpisode]) -> String {
        let a = episodes.indices.contains(r.start) ? episodes[r.start].ep : r.start + 1
        let b = episodes.indices.contains(r.end) ? episodes[r.end].ep : r.end + 1
        return a == b ? "\(a)" : "\(a)-\(b)"
    }
}

struct DramaDetailView: View {
    let series: HGSeries
    var seededDetail: HGSeriesDetail? = nil
    @State private var detail: HGSeriesDetail?
    @State private var error: Error?
    @State private var group = 0
    @State private var seasons: [HGSeries] = []
    /// Long-video sites: resolved 播放源 list (preloaded so the player starts instantly).
    @State private var sources: [HGStream] = []
    @State private var sourcesError: String?
    @State private var sourcesVerify: VerifyTarget?
    @State private var verifySheet: VerifyTarget?
    @Environment(\.zoomNS) private var ns
    @ObservedObject private var library = LibraryStore.shared


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if let d = detail { detailBody(d) }
                else if let error { ErrorStateView(error: error) { Task { await load() } } }
                else {
                    VStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in ShimmerBlock().frame(height: 16) }
                    }.padding(.horizontal, 20)
                }
            }
        }
        .compatDefaultScrollAnchor(DebugScroll.anchor)
        .accessibilityIdentifier("screen.detail")
        .ignoresSafeArea(edges: .top)
        .background(STVTheme.bg.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .zoomDestination(series.id, ns)
        .task {
            if let seededDetail { detail = seededDetail; selectResumeGroup() }
            else if detail == nil { await load() }
        }
        .onChange(of: detail?.episodes.count) { _ in selectResumeGroup() }
        .task(id: detail?.seriesId) {
            guard let d = detail else { return }
            if series.source.isLongVideo {
                await loadSources(d)
            } else {
                seasons = await SeasonStore.seasons(for: d, series: series)
            }
        }

    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            CoverView(url: DetailCover.pick(detail: detail?.cover ?? "", list: series.cover), corner: 0, fallback: series.cover, a11yID: "detail.poster")
                .frame(height: 440)
                // White title / meta sit on the poster in both schemes: a dark scrim under them, then a short fade
                // into the page background so the hero blends into the light or dark page below.
                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .clear, location: 0.3),
                           .init(color: .black.opacity(0.62), location: 0.9), .init(color: STVTheme.bg, location: 1)],
                          startPoint: .top, endPoint: .bottom))
            VStack(spacing: 8) {
                Text(detail?.title ?? series.title).font(.largeTitle.weight(.bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
                    .contextMenu {
                        Button("复制剧名", systemImage: "doc.on.doc") { UIPasteboard.general.string = detail?.title ?? series.title }
                    }
                Text([series.source.label,
                      detail.map { $0.episodeLabel.isEmpty ? "共\(max($0.totalEps, $0.episodes.count))集" : $0.episodeLabel },
                      detail.flatMap { $0.favoriteCount > 0 ? Fmt.count($0.favoriteCount) + "收藏" : nil },
                      detail?.author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                if let d = detail, d.rating > 0 || !d.hotText.isEmpty { SocialStats(detail: d) }
            }.padding(.horizontal, 20).padding(.bottom, 44)
        }
    }

    @ViewBuilder private func detailBody(_ d: HGSeriesDetail) -> some View {
        let resume = library.progress(for: series)
        let ranges = EpisodeGroups.ranges(total: d.episodes.count)
        let g = ranges.indices.contains(group) ? group : 0
        let range = ranges.isEmpty ? EpisodeRange(0, -1) : ranges[g]

        HStack(spacing: 12) {
            NavigationLink(value: Route.play(series, resume?.episodeIndex)) {
                Label(resume.map { series.source.isLongVideo ? "继续 " + Fmt.clock(Int($0.seconds)) : "继续第\($0.episodeNumber)集" } ?? "开始播放", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(STVTheme.text, in: Capsule()).foregroundStyle(STVTheme.bg)
            }.disabled(d.episodes.isEmpty)
            Button { withAnimation(.spring) { library.toggleFavorite(series) } } label: {
                Image(systemName: library.isFavorite(series) ? "heart.fill" : "heart")
                    .font(.title3).frame(width: 50, height: 50)
                    .foregroundStyle(library.isFavorite(series) ? STVTheme.accent : STVTheme.text)
                    .background(STVTheme.elevated, in: Circle())
                    .compatSymbolReplaceTransition()
            }
        }.padding(.horizontal, 20)

        if !d.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(d.tags, id: \.self) { t in
                        Text(t).font(.caption.weight(.medium)).foregroundStyle(STVTheme.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(STVTheme.glass, in: Capsule())
                    }
                }.padding(.horizontal, 20)
            }
        }
        if d.cast.isEmpty && !d.actors.isEmpty {
            Text("主演：" + d.actors.joined(separator: " / "))
                .font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
        }
        if !d.desc.isEmpty {
            Text(d.desc).font(.subheadline).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
                .textSelection(.enabled)
        }

        let shelf = d.relatedSeries.count > 1 ? d.relatedSeries : seasons
        if shelf.count > 1 {
            relatedShelf(shelf, currentId: d.seriesId)
        }

        if !d.cast.isEmpty {
            CastShelf(cast: d.cast)
        }

        if series.source.isLongVideo {
            sourcesSection
        } else {
        SectionHeader(title: "选集").padding(.top, 4)

        if ranges.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ranges.indices, id: \.self) { i in
                        let on = i == g
                        Button {
                            withAnimation(.snappy) { group = i }
                        } label: {
                            Text(EpisodeGroups.label(ranges[i], episodes: d.episodes))
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(on ? STVTheme.text.opacity(0.14) : STVTheme.text.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
        }

        if range.end >= range.start {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(range.start...range.end, id: \.self) { i in
                    let ep = d.episodes[i]
                    NavigationLink(value: Route.play(series, i)) {
                        Text("\(ep.ep)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(resume?.episodeIndex == i ? STVTheme.accent.opacity(0.17) : STVTheme.glass,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(resume?.episodeIndex == i ? STVTheme.accent : STVTheme.text)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
            .id(g)
        }
        }
    }

    /// 播放源 — same look as the 选集 buttons, 3 columns, small status line under the name.
    @ViewBuilder private var sourcesSection: some View {
        SectionHeader(title: series.source.streamSectionTitle).padding(.top, 4)
        if sources.isEmpty {
            if let sourcesError {
                Text(sourcesError).font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
                if let t = sourcesVerify {
                    Button("去验证") { verifySheet = t }.buttonStyle(.borderedProminent).tint(STVTheme.accent)
                        .padding(.horizontal, 20)
                        .sheet(item: $verifySheet) { t in SiteVerifySheet(target: t, onDone: retrySources) }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in ShimmerBlock().frame(height: 52) }
                }.padding(.horizontal, 20)
            }
        } else {
            let current = SitePrefs.preferredStream[series.id] ?? sources.first?.id
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(sources) { s in
                    let on = s.id == current
                    NavigationLink(value: Route.play(series, 0)) {
                        VStack(spacing: 3) {
                            Text(s.quality ?? "默认").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(s.kind == .hls || s.kind == .hlsAES ? "HLS" : "MP4").font(.caption2)
                                .foregroundStyle(on ? STVTheme.accent.opacity(0.8) : STVTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(on ? STVTheme.accent.opacity(0.17) : STVTheme.glass, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { SitePrefs.preferredStream[series.id] = s.id })
                }
            }
            .padding(.horizontal, 20)
        }
        Spacer(minLength: 30)
    }

    private func retrySources() {
        guard let d = detail else { return }
        sourcesError = nil
        sourcesVerify = nil
        Task { await loadSources(d) }
    }

    private func loadSources(_ d: HGSeriesDetail) async {
        guard let ep = d.episodes.first else { return }
        do {
            let r = try await Catalog.resolve(series, ep)
            sources = r.streams
            sourcesError = r.streams.isEmpty ? (r.err ?? "暂无可用播放源") : nil
            sourcesVerify = nil
        } catch { sourcesError = error.localizedDescription; sourcesVerify = error.verifyTarget }
    }

    /// Apple TV+ style horizontal franchise shelf.
    @ViewBuilder private func relatedShelf(_ items: [HGSeries], currentId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "系列 · 共\(items.count)季", trailing: AnyView(
                NavigationLink(value: Route.searchFor(SeasonParser.parse(detail?.title ?? series.title).base)) {
                    Label("搜全系列", systemImage: "magnifyingglass").font(.subheadline).foregroundStyle(STVTheme.secondary)
                }))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { s in
                        let on = s.seriesId == currentId
                        Group {
                            if on {
                                relatedPoster(s, current: true, label: SeasonStore.label(s, in: items))
                            } else {
                                NavigationLink(value: Route.series(s)) {
                                    relatedPoster(s, current: false, label: SeasonStore.label(s, in: items))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
    }

    private func relatedPoster(_ s: HGSeries, current: Bool, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(url: s.cover, corner: 10)
                .frame(width: 104, height: 139)
                .zoomSource(s.id, ns)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(current ? STVTheme.accent : STVTheme.text.opacity(0.12), lineWidth: current ? 2.5 : 0.8)
                }
                .overlay(alignment: .topLeading) {
                    if current || label != nil {
                        Text(current ? (label.map { $0 + " · 当前" } ?? "当前") : label!)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(STVTheme.bg.opacity(0.85), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if s.episodeCount > 0 {
                        Text("\(s.episodeCount)集")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
            Text(s.title)
                .font(.caption.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? STVTheme.text : STVTheme.secondary)
                .lineLimit(2)
                .frame(width: 104, alignment: .leading)
        }
        .opacity(current ? 1 : 0.92)
    }

    private func selectResumeGroup() {
        guard let d = detail, let r = library.progress(for: series) else { return }
        let ranges = EpisodeGroups.ranges(total: d.episodes.count)
        if let i = ranges.firstIndex(where: { r.episodeIndex >= $0.start && r.episodeIndex <= $0.end }) {
            group = i
        }
    }

    private func load() async {
        do {
            let d = try await Catalog.detail(series)
            detail = d
            error = nil
            selectResumeGroup()
            if series.source == .hongguo {
                // Warm the play URL of the episode a tap would open (resume point, else episode 1).
                let i = library.progress(for: series)?.episodeIndex ?? 0
                if d.episodes.indices.contains(i) { HongguoClient.shared.prefetch(vids: [d.episodes[i].vid]) }
                // Second pass: cast / tags / rating from the official site.
                if let e = await Catalog.enriched(series, d), detail?.seriesId == e.seriesId { detail = e }
            }
        } catch { self.error = error }
    }
}


/// Simulator screenshot host for the related-seasons shelf (`STV_DETAIL_SHOT=1`).
/// Set `STV_LIVE_SERIES=<seriesId>` to load a real franchise instead of mock data.
struct DetailRelatedShotHost: View {
    @State private var series = HGSeries(
        seriesId: "7000001", title: "霸总的秘密助理",
        cover: "https://picsum.photos/seed/stv1/600/900", episodeCount: 12)
    @State private var seed: HGSeriesDetail?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            Group {
                if let seed {
                    DramaDetailView(series: series, seededDetail: seed)
                        .id(seed.seriesId + "-\(seed.relatedSeries.count)")
                } else if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DramaDetailView(series: series, seededDetail: .previewDetail)
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(STVTheme.bg)
        .task {
            let live = ProcessInfo.processInfo.environment["STV_LIVE_SERIES"] ?? ""
            if HongguoClient.looksSID(live), let d = try? await HongguoClient.shared.detail(seriesId: live) {
                series = HGSeries(seriesId: d.seriesId, title: d.title, cover: d.cover, episodeCount: max(d.totalEps, d.episodes.count))
                seed = d
            } else {
                seed = .previewDetail
            }
            loading = false
        }
    }
}


/// One-shot live probe: franchise landing for a known multi-season stick_id.
struct ResolveProbeHost: View {
    @State private var lines: [String] = ["probing…"]
    private var vid: String {
        let e = ProcessInfo.processInfo.environment["STV_PROBE_VID"] ?? ""
        return e.isEmpty ? "7683440834066271256" : e
    }
    var body: some View {
        ScrollView { Text(lines.joined(separator: "\n")).font(.system(.footnote, design: .monospaced)).padding() }
            .task { await run() }
    }
    private func run() async {
        var out: [String] = []
        let d = HGPlayerDevice.current()
        out.append("player device src=\(d.source ?? "?") did=\(d.deviceId) (len=\(d.deviceId.count))")
        do {
            let r = try await HongguoClient.shared.resolve(vid: vid)
            out.append("OK streams=\(r.streams.count) err=\(r.err ?? "nil") duration=\(r.duration.map(String.init(describing:)) ?? "nil")")
            NSLog("[HG] probe resolve OK streams=%d", r.streams.count)
        } catch {
            out.append("FAIL \(error.localizedDescription)")
            NSLog("[HG] probe resolve FAIL %@", error.localizedDescription)
        }
        lines = out
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("resolve-probe.txt")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSLog("[HG] probe wrote %@", url.path)
    }
}

struct RelatedProbeHost: View {
    @State private var text = "probing…"
    var body: some View {
        ScrollView {
            Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Color.black)
        .task { await run() }
    }
    private func run() async {
        let sid = "7661844828728085528" // 被贬北凉… S1 from gateway tests
        var lines: [String] = ["stick_ids=" + sid]
        do {
            let items = try await HongguoClient.shared.seriesLanding(stickIds: sid)
            lines.append("landing count=\(items.count)")
            for s in items.prefix(20) {
                lines.append("\(s.seriesId) | \(s.title) | eps=\(s.episodeCount)")
            }
            let d = try await HongguoClient.shared.detail(seriesId: sid)
            lines.append("detail related=\(d.relatedSeries.count) title=\(d.title)")
            for s in d.relatedSeries.prefix(20) {
                lines.append("rel \(s.seriesId) | \(s.title)")
            }
            // Dump raw relate keys from a fresh detail post is inside client; summarize here.
        } catch {
            lines.append("ERR \(error)")
        }
        text = lines.joined(separator: "\n")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("related-probe.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lines.append("wrote \(url.path)")
        text = lines.joined(separator: "\n")
    }
}

/// 观众评分 + 全网热度 pills (官网 seriesSocialInfo, hongguo-open-player 详情弹窗).
struct SocialStats: View {
    let detail: HGSeriesDetail
    var body: some View {
        HStack(spacing: 8) {
            if detail.rating > 0 {
                pill(Image(systemName: "star.fill"), String(format: "%.1f", detail.rating) + " 观众评分" +
                     (detail.ratingCount.isEmpty ? "" : " · \(detail.ratingCount)人"), STVTheme.accentWarm)
            }
            if !detail.hotText.isEmpty { pill(Image(systemName: "flame.fill"), "全网热度 " + detail.hotText, STVTheme.accent) }
        }
    }
    private func pill(_ icon: Image, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) { icon.foregroundStyle(tint); Text(text).foregroundStyle(.white) }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.12)) }
    }
}
