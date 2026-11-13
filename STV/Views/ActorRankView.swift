import SwiftUI

// MARK: - 剧星榜 (hongguo-open-player 顶部「剧星榜」入口：演员排名、人气、升降、性别筛选 → 演员主页)

@MainActor
final class ActorRankStore: ObservableObject {
    static let shared = ActorRankStore()
    @Published private(set) var actors: [HGRankedActor] = []
    @Published private(set) var rankDate = ""
    @Published private(set) var hasMore = true
    @Published private(set) var loading = false
    @Published private(set) var error: Error? = nil
    @Published private var nextOffset = 0
    @Published private var sessionId = ""
    @Published private var loadedAt = Date.distantPast

    var stale: Bool { actors.isEmpty || Date().timeIntervalSince(loadedAt) > 900 }

    func filtered(_ g: HGRankedActor.Gender) -> [HGRankedActor] { g == .all ? actors : actors.filter { $0.gender == g } }

    func reload() async {
        actors = []; nextOffset = 0; sessionId = ""; hasMore = true; error = nil
        await loadMore()
    }

    func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let p = try await HongguoClient.shared.actorRank(offset: nextOffset, sessionId: sessionId, startRank: actors.count)
            let seen = Set(actors.map(\.id))
            actors += p.actors.filter { !seen.contains($0.id) }
            if !p.rankDate.isEmpty { rankDate = p.rankDate }
            NSLog("[HG] 剧星榜 page n=%d date=%@ more=%d", p.actors.count, p.rankDate, p.hasMore ? 1 : 0)
            hasMore = p.hasMore && !p.actors.isEmpty && actors.count < 300
            nextOffset = p.nextOffset; sessionId = p.sessionId
            loadedAt = Date(); error = nil
        } catch { self.error = error }
    }

    /// Gender filter is client-side; keep paging until a page's worth matches (max 15 upstream pages, like theirs).
    func ensure(_ g: HGRankedActor.Gender, count: Int = 20) async {
        var guardPages = 0
        while filtered(g).count < count, hasMore, error == nil, guardPages < 15 { guardPages += 1; await loadMore() }
    }
}

/// Embeddable list (Home tab) — no own ScrollView.
struct ActorRankList: View {
    @State private var gender: HGRankedActor.Gender = .all
    @ObservedObject private var store = ActorRankStore.shared

    var body: some View {
        let list = store.filtered(gender)
        VStack(alignment: .leading, spacing: 14) {
            header
            if let e = store.error, store.actors.isEmpty {
                ErrorStateView(error: e) { Task { await store.reload() } }
            } else if list.isEmpty && store.loading {
                VStack(spacing: 12) { ForEach(0..<6, id: \.self) { _ in ShimmerBlock().frame(height: 64) } }.padding(.horizontal, 16)
            } else {
                if list.count >= 3 { podium(Array(list.prefix(3))).padding(.horizontal, 16) }
                LazyVStack(spacing: 10) {
                    ForEach(Array(list.dropFirst(list.count >= 3 ? 3 : 0).enumerated()), id: \.element.id) { i, a in
                        NavigationLink(value: Route.actor(a.celebrity)) { ActorRankRow(actor: a, shownRank: gender == .all ? a.rank : i + 4) }
                            .buttonStyle(.plain)
                            .onAppear { if a.id == list.last?.id { Task { await store.loadMore() } } }
                    }
                    if store.loading { ProgressView().padding() }
                    else if !store.hasMore { Text("已经到底了").font(.caption).foregroundStyle(STVTheme.secondary).padding() }
                }.padding(.horizontal, 16)
            }
        }
        .task(id: gender) {
            if store.stale { await store.reload() }
            await store.ensure(gender)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("剧星榜", systemImage: "star.circle.fill").font(.title3.weight(.bold)).foregroundStyle(STVTheme.text)
                Spacer()
                if !store.rankDate.isEmpty { Text("统计截至 \(store.rankDate)").font(.caption).foregroundStyle(STVTheme.secondary) }
            }
            Picker("性别", selection: $gender) {
                ForEach(HGRankedActor.Gender.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
        }.padding(.horizontal, 16)
    }

    private func podium(_ top: [HGRankedActor]) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach([1, 0, 2], id: \.self) { i in
                NavigationLink(value: Route.actor(top[i].celebrity)) { PodiumCell(actor: top[i], place: i + 1) }.buttonStyle(.plain)
            }
        }
    }
}

struct ActorRankView: View {
    var body: some View {
        ScrollView { ActorRankList().padding(.vertical, 8) }
            .background(STVTheme.bg.ignoresSafeArea())
            .navigationTitle("剧星榜")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await ActorRankStore.shared.reload() }
    }
}

private struct PodiumCell: View {
    let actor: HGRankedActor
    let place: Int
    private var tint: Color {
        switch place { case 1: Color(red: 1, green: 0.78, blue: 0.25); case 2: Color(red: 0.78, green: 0.82, blue: 0.9); default: Color(red: 0.86, green: 0.55, blue: 0.32) }
    }
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                ActorAvatar(url: actor.avatar, size: place == 1 ? 84 : 66)
                    .overlay { Circle().strokeBorder(tint, lineWidth: 2.5) }
                    .padding(.top, 14)
                Image(systemName: place == 1 ? "crown.fill" : "medal.fill")
                    .font(.system(size: place == 1 ? 20 : 15)).foregroundStyle(tint)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            Text(actor.name).font(.subheadline.weight(.bold)).foregroundStyle(STVTheme.text).lineLimit(1)
            Text(actor.score).font(.caption2.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
            ChangeBadge(actor: actor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.top, place == 1 ? 0 : 18)
        .background(
            LinearGradient(colors: [tint.opacity(0.22), STVTheme.glass], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.35)) }
    }
}

struct ChangeBadge: View {
    let actor: HGRankedActor
    var body: some View {
        switch actor.change {
        case .up where actor.changeNum > 0:
            Label("\(actor.changeNum)", systemImage: "arrowtriangle.up.fill").font(.caption2.weight(.bold)).foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
        case .down where actor.changeNum > 0:
            Label("\(actor.changeNum)", systemImage: "arrowtriangle.down.fill").font(.caption2.weight(.bold)).foregroundStyle(Color(red: 0.35, green: 0.8, blue: 0.5))
        default:
            Text("—").font(.caption2.weight(.bold)).foregroundStyle(STVTheme.secondary)
        }
    }
}

struct ActorRankRow: View {
    let actor: HGRankedActor
    let shownRank: Int
    var body: some View {
        HStack(spacing: 12) {
            RankNumeral(rank: shownRank, size: 18).frame(width: 30)
            ActorAvatar(url: actor.avatar, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(actor.name).font(.headline).foregroundStyle(STVTheme.text).lineLimit(1)
                    if actor.gender != .all {
                        Text(actor.gender == .female ? "女" : "男").font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background((actor.gender == .female ? Color.pink : STVTheme.accent).opacity(0.2), in: Capsule())
                            .foregroundStyle(actor.gender == .female ? Color.pink : STVTheme.accent)
                    }
                    ChangeBadge(actor: actor)
                }
                if !actor.subTitles.isEmpty {
                    Text(actor.subTitles.joined(separator: " · ")).font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(1)
                }
                if !actor.intro.isEmpty {
                    Text(actor.intro).font(.caption2).foregroundStyle(STVTheme.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(actor.score).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(STVTheme.accentWarm)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(STVTheme.secondary)
            }
        }
        .padding(10)
        .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
