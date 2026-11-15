import SwiftUI

@main
struct STVApp: App {
    @UIApplicationDelegateAdaptor(OrientationGate.self) private var orientation
    init() {
        CrashReporter.install()
        CFSolver.install()
        // 底部导航用的是自定义玻璃胶囊（GlassTabBar），系统 TabBar 永远不该出现。
        // 仅靠 .toolbar(.hidden, for: .tabBar) 在 iOS 16 上不可靠：push 详情页等页面时
        // TabBar 占位会偶发残留——表现为底部一条空白、点上去正好落在透明 TabBar 的按钮上
        // 触发切 tab、播放器画面也被这条占位挤得底部留黑条。窗口根部挂 TabBarHider
        // （UIKit 层强隐藏 + 禁点，定时兜底扫描），见 RootTabView.swift。
        // Load plugin / 采集站 indexes before anything reads `Sites.all` or `SourceGate`.
        MainActor.assumeIsolated { _ = CMSStore.shared; _ = PluginStore.shared }
    }
    private var shotMode: Bool {
        ProcessInfo.processInfo.environment["STV_SHOTS"] == "1"
    }
    private var detailShot: Bool {
        ProcessInfo.processInfo.environment["STV_DETAIL_SHOT"] == "1"
    }
    private var probeRelated: Bool {
        ProcessInfo.processInfo.environment["STV_PROBE_RELATED"] == "1"
    }
    private var probeResolve: Bool {
        ProcessInfo.processInfo.environment["STV_PROBE_RESOLVE"] == "1"
    }
    /// Simulator smoke test: open the player straight on a hongguo series (`STV_PLAY_SERIES=<sid>`).
    private var playSeries: String { ProcessInfo.processInfo.environment["STV_PLAY_SERIES"] ?? "" }
    /// Simulator smoke test: open an actor page (`STV_ACTOR=<celebrity_id>`).
    private var actorShot: String { ProcessInfo.processInfo.environment["STV_ACTOR"] ?? "" }
    var body: some Scene {
        WindowGroup {
            Group {
                if let r = DebugRoute.current {
                    DebugRouteHost(route: r)
                } else if !playSeries.isEmpty {
                    NavigationStack { VerticalPlayerView(series: HGSeries(seriesId: playSeries, title: "", cover: ""), startIndex: 0).routes() }
                } else if !actorShot.isEmpty {
                    NavigationStack { ActorView(actor: HGCelebrity(id: actorShot, name: "", role: ProcessInfo.processInfo.environment["STV_ACTOR_ROLE"] ?? "")).routes() }
                } else if probeResolve {
                    ResolveProbeHost()
                } else if probeRelated {
                    RelatedProbeHost()
                } else if detailShot {
                    DetailRelatedShotHost()
                } else if shotMode {
                    PlayerChromeShotHost()
                } else {
                    RootTabView()
                }
            }
            .tint(STVTheme.accent)
            .task {
                await CFCookies.restoreFromWebKit()
                #if DEBUG
                // `STV_CF_SELFTEST=<url>`: run the silent solver against a public CF JS-challenge page and
                // re-request it with URLSession (synced cookie + learned UA); results go to 站点诊断日志.
                if let u = ProcessInfo.processInfo.environment["STV_CF_SELFTEST"], !u.isEmpty {
                    SiteUA.clear(.hanime1)
                    let before = try? await SiteHTTP.shared.raw(u, referer: nil, headers: ["User-Agent": DramaSource.hanime1.userAgent])
                    SiteLog.add("自测 前：HTTP \(before?.1 ?? -1) challenge=\(before.map { CFDetect.isChallenge(status: $0.1, headers: $0.2, body: $0.0) } ?? true)")
                    let ok = await CFSolver.shared.solve(.hanime1, u)
                    let after = try? await SiteHTTP.shared.raw(u, referer: nil, headers: ["User-Agent": DramaSource.hanime1.userAgent])
                    SiteLog.add("自测 后：solver=\(ok) HTTP \(after?.1 ?? -1) challenge=\(after.map { CFDetect.isChallenge(status: $0.1, headers: $0.2, body: $0.0) } ?? true) title=\(after.map { CFDetect.title($0.0) } ?? "-") cookies=\(CFCookies.names(for: u).joined(separator: ","))")
                    if !(after.map { !CFDetect.isChallenge(status: $0.1, headers: $0.2, body: $0.0) } ?? false) {
                        let viaWeb = await CFSolver.shared.fetch(.hanime1, u)
                        SiteLog.add("自测 WebView fetch：\(viaWeb.map { "len \($0.count) title=\(CFDetect.title($0)) challenge=\(CFDetect.isChallenge(status: 200, headers: [:], body: $0))" } ?? "nil")")
                    }
                }
                #endif
            }
            .background(STVTheme.bg)
            .background(TabBarHider())
        }
    }
}

/// Simulator screenshot hooks (`STV_ROUTE=...`), used to capture 设计图 for each screen.
enum DebugRoute {
    case root(Int), detail(String), search(String), searchEdit, actorRank, profile
    /// Multi-source hooks: `site:<source>:<id>`, `siteplay:<source>:<id>`, `board:<source>:<categoryId>`, `sources`, `licenses`.
    case site(DramaSource, String, play: Bool), board(DramaSource, String), sources, licenses, siteLog, plugins, history
    /// `fxplay:/abs/file.mp4` — player on a local test stream (UI tests for orientation / progress bar).
    case fixturePlay(String)
    /// `tgplay:<channel>/<msgId>/<mediaIndex>` — a public channel video (t.me/s) straight in the player.
    case tgPlay(String)
    #if DEBUG
    nonisolated(unsafe) private static var seededWatch = false
    #endif
    static var current: DebugRoute? {
        let env = ProcessInfo.processInfo.environment
        if let seed = env["STV_SEED_HISTORY"], !seed.isEmpty {
            MainActor.assumeIsolated { seed.split(separator: ",").reversed().forEach { LibraryStore.shared.addSearch(String($0)) } }
        }
        #if DEBUG
        // `STV_SEED_WATCH=N`: N fake 观看历史 records (UI tests for deleting records).
        if let n = env["STV_SEED_WATCH"].flatMap(Int.init), n > 0, !seededWatch {
            seededWatch = true   // `current` is re-read on every render: seed once, or deletions come back
            MainActor.assumeIsolated {
                for i in 0..<n {
             let s = HGSeries(seriesId: "seed\(i)", title: "测试记录 \(i + 1)", cover: "", episodeCount: 10)
             LibraryStore.shared.record(s, index: i % 10, ep: i % 10 + 1, seconds: Double(30 + i), duration: 120)
                }
            }
        }
        #endif
        guard let raw = env["STV_ROUTE"], !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "tab": return .root(Int(arg) ?? 0)
        case "detail": return .detail(arg)
        case "search": return .search(arg)
        case "searchedit": return .searchEdit
        case "actorrank": return .actorRank
        case "profile": return .profile
        #if DEBUG
        // Multi-source hooks are simulator-only: in Release they would bypass 片源管理 (hidden adult sources).
        case "sources": return .sources
        case "licenses": return .licenses
        case "history": return .history
        case "plugins": return .plugins
        case "sitelog": return .siteLog
        case "fxplay": return .fixturePlay(arg)
        case "tgplay": return .tgPlay(arg)
        case "site", "siteplay", "board":
            let a = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard a.count == 2, let s = DramaSource(rawValue: a[0]) else { return nil }
            // `STV_STREAM=supjav-ST` pre-selects a 播放源 (same as tapping it on the detail page).
            if let want = env["STV_STREAM"], !want.isEmpty {
                MainActor.assumeIsolated { SitePrefs.preferredStream[s.rawValue + ":" + a[1]] = want }
            }
            return parts[0] == "board" ? .board(s, a[1]) : .site(s, a[1], play: parts[0] == "siteplay")
        #endif
        default: return nil
        }
    }
}

struct DebugRouteHost: View {
    let route: DebugRoute
    var body: some View {
        switch route {
        case .root: RootTabView()
        case .detail(let sid): NavigationStack { DramaDetailView(series: HGSeries(seriesId: sid, title: "", cover: "")).routes() }
        case .search(let q): NavigationStack { SearchView(initialQuery: q).routes() }
        case .searchEdit: NavigationStack { SearchView(startEditingHistory: true).routes() }
        case .actorRank: NavigationStack { ActorRankView().routes() }
        case .profile: NavigationStack { ProfileView().routes() }
        case .sources: NavigationStack { SourcesView().routes() }
        case .licenses: NavigationStack { LicensesView().routes() }
        case .history: NavigationStack { LibraryListView(kind: .history).routes() }
        case .plugins: NavigationStack { PluginsView().routes() }
        case .siteLog: NavigationStack { SiteLogView().routes() }
        case .fixturePlay(let path):
            NavigationStack {
                VerticalPlayerView(series: HGSeries(source: .telegram, seriesId: "fixture/1/0", title: ProcessInfo.processInfo.environment["STV_FX_TITLE"] ?? "公开测试流 · 横版 1280×720", cover: "",
                                                    duration: 60, onlineTime: 1_586_390_400, orientation: "landscape", page: URL(fileURLWithPath: path).absoluteString),
                                   startIndex: 0).routes()
            }
        case .tgPlay(let ref):
            NavigationStack { TGPlayRouteHost(ref: ref).routes() }
        case .site(let s, let id, let play):
            let series = HGSeries(source: s, seriesId: id, title: id.uppercased(), cover: "", orientation: "landscape")
            NavigationStack {
                Group { if play { VerticalPlayerView(series: series, startIndex: 0) } else { DramaDetailView(series: series) } }.routes()
            }
        case .board(let s, let c):
            NavigationStack {
                if let cat = Sites.provider(s)?.categories.first(where: { $0.id == c }) { BoardListView(board: BoardSpec(kind: .site(s, cat))).routes() }
            }
        }
    }
}

enum DebugScroll {
    /// `STV_SCROLL=0.5` → initial scroll anchor for screenshot of lower sections.
    static var anchor: UnitPoint {
        guard let v = Double(ProcessInfo.processInfo.environment["STV_SCROLL"] ?? "") else { return .top }
        return UnitPoint(x: 0.5, y: v)
    }
}

/// Loads one public post (t.me/s) and opens its video in the player — used to reproduce TG playback.
struct TGPlayRouteHost: View {
    let ref: String
    @State private var series: HGSeries?
    @State private var error = ""
    var body: some View {
        Group {
            if let series { VerticalPlayerView(series: series, startIndex: 0) }
            else { Text(error.isEmpty ? "加载帖子…" : error).foregroundStyle(.white) }
        }
        .task {
            let p = ref.split(separator: "/").map(String.init)
            guard p.count >= 2, let id = Int(p[1]) else { error = "bad ref"; return }
            let i = p.count > 2 ? Int(p[2]) ?? 0 : 0
            do {
                guard let post = try await TGClient.shared.post(p[0], id), let s = TGVideoProvider.series(post, media: i, channel: nil) else { error = "帖子无视频"; return }
                NSLog("%@", "[STV] tgplay \(ref) page=\(s.page?.prefix(60) ?? "-")")
                series = s
            } catch { self.error = error.localizedDescription }
        }
    }
}
