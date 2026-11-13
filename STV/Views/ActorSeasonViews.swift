import SwiftUI
import UIKit

// MARK: - Seasons (多季)

/// Franchise seasons for a series: upstream 系列剧 landing first, then title-search discovery (cached).
@MainActor enum SeasonStore {
    private static var cache: [String: [HGSeries]] = [:]

    static func cached(_ seriesId: String) -> [HGSeries]? { cache[seriesId] }

    static func seasons(for d: HGSeriesDetail, series: HGSeries) async -> [HGSeries] {
        guard series.source == .hongguo else { return [] }
        if d.relatedSeries.count > 1 { remember(d.relatedSeries); return d.relatedSeries }
        if let c = cache[d.seriesId] { return c }
        let current = HGSeries(seriesId: d.seriesId, title: d.title.isEmpty ? series.title : d.title,
                               cover: d.cover.isEmpty ? series.cover : d.cover, episodeCount: max(d.totalEps, d.episodes.count))
        let found = await HongguoClient.shared.discoverSeasons(title: current.title, current: current)
        if found.count > 1 { remember(found) } else { cache[d.seriesId] = [] }
        return found
    }

    private static func remember(_ list: [HGSeries]) { for s in list { cache[s.seriesId] = list } }

    /// "第N季" only when the franchise actually numbers its seasons.
    static func label(_ s: HGSeries, in list: [HGSeries]) -> String? {
        guard list.contains(where: { SeasonParser.parse($0.title).explicit }) else { return nil }
        return SeasonParser.label(s)
    }
}

struct SeasonPickerSheet: View {
    let seasons: [HGSeries]
    let currentId: String
    let onPick: (HGSeries) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("系列全季 · 共\(seasons.count)季").font(.headline).padding(.top, 18).padding(.horizontal, 20)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(seasons) { s in
                        let on = s.seriesId == currentId
                        Button { if !on { onPick(s) } } label: {
                            HStack(spacing: 12) {
                                CoverView(url: s.cover, corner: 8).frame(width: 54, height: 72)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if let l = SeasonStore.label(s, in: seasons) {
                                            Text(l).font(.caption.weight(.bold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background((on ? STVTheme.accent : STVTheme.text).opacity(0.12), in: Capsule())
                                        }
                                        if on { Text("正在播放").font(.caption2.weight(.semibold)).foregroundStyle(STVTheme.accent) }
                                    }
                                    Text(s.title).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if s.episodeCount > 0 {
                                        Text("\(s.episodeCount)集").font(.caption).foregroundStyle(STVTheme.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: on ? "play.circle.fill" : "chevron.right")
                                    .foregroundStyle(on ? STVTheme.accent : STVTheme.secondary)
                            }
                            .padding(10)
                            .background(on ? STVTheme.accent.opacity(0.12) : STVTheme.glass, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(STVTheme.text)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Cast (演员)

struct CastShelf: View {
    let cast: [HGCelebrity]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "演员")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { c in
                        if c.id.isEmpty { cell(c) }
                        else { NavigationLink(value: Route.actor(c)) { cell(c) }.buttonStyle(.plain) }
                    }
                }.padding(.horizontal, 16)
            }
        }.padding(.top, 4)
    }

    private func cell(_ c: HGCelebrity) -> some View {
        VStack(spacing: 6) {
            ActorAvatar(url: c.avatar, size: 64)
            Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
            if !c.role.isEmpty {
                Text(c.role).font(.caption2).foregroundStyle(STVTheme.secondary).lineLimit(1)
            }
        }.frame(width: 76)
    }
}

struct ActorAvatar: View {
    let url: String
    var size: CGFloat = 64
    var body: some View {
        CoverView(url: url, corner: size / 2)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(STVTheme.text.opacity(0.12), lineWidth: 0.8) }
    }
}

/// Actor homepage + filmography (hongguo-open-player 演员主页 / 参演短剧).
struct ActorView: View {
    let actor: HGCelebrity
    @State private var profile: HGActorProfile?
    @State private var works: [HGSeries] = []
    @State private var total = 0
    @State private var error: Error?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    ActorAvatar(url: profile?.actor.avatar.isEmpty == false ? profile!.actor.avatar : actor.avatar, size: 104)
                    Text(profile?.actor.name.isEmpty == false ? profile!.actor.name : actor.name)
                        .font(.title.weight(.bold)).foregroundStyle(STVTheme.text)
                        .contextMenu { Button("复制名字", systemImage: "doc.on.doc") { UIPasteboard.general.string = actor.name } }
                    if !actor.role.isEmpty { Text(actor.role).font(.subheadline).foregroundStyle(STVTheme.secondary) }
                }
                .frame(maxWidth: .infinity).padding(.top, 12)

                if let intro = profile?.actor.intro, !intro.isEmpty {
                    Text(intro).font(.subheadline).foregroundStyle(STVTheme.secondary)
                        .textSelection(.enabled).padding(.horizontal, 20)
                }

                if let rel = profile?.related, !rel.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "合作演员")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(rel) { c in
                                    NavigationLink(value: Route.actor(c)) {
                                        VStack(spacing: 6) {
                                            ActorAvatar(url: c.avatar, size: 56)
                                            Text(c.name).font(.caption).foregroundStyle(STVTheme.text).lineLimit(1)
                                        }.frame(width: 68)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
                }

                SectionHeader(title: total > 0 ? "参演作品 · \(total)" : "参演作品")
                if loading && works.isEmpty {
                    VStack(spacing: 10) { ForEach(0..<3, id: \.self) { _ in ShimmerBlock().frame(height: 16) } }.padding(.horizontal, 20)
                } else if let error, works.isEmpty {
                    ErrorStateView(error: error) { Task { await load() } }
                } else if works.isEmpty {
                    Text("暂无作品").font(.subheadline).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
                } else {
                    NumberedGrid(items: works, numbered: false).padding(.bottom, 30)
                }
            }
        }
        .compatDefaultScrollAnchor(DebugScroll.anchor)
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle(actor.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if profile == nil && works.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        async let p = try? HongguoClient.shared.celebrity(id: actor.id)
        async let w: Result<HGActorWorks, Error> = {
            do { return .success(try await HongguoClient.shared.celebrityWorks(id: actor.id)) } catch { return .failure(error) }
        }()
        profile = await p
        switch await w {
        case .success(let r): works = r.items; total = r.total; error = nil
        case .failure(let e): error = e
        }
        loading = false
    }
}

