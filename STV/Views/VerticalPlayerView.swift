import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Route entry. Hosts one `PlayerScreen` per series so switching season (多季) rebuilds the coordinator cleanly.
struct VerticalPlayerView: View {
    let series: HGSeries
    let startIndex: Int?
    @State private var switched: HGSeries?

    var body: some View {
        let s = switched ?? series
        PlayerScreen(series: s, startIndex: switched == nil ? startIndex : nil) { next in switched = next }
            .id(s.id)
    }
}

struct PlayerScreen: View {
    let series: HGSeries
    let startIndex: Int?
    var onSwitchSeries: (HGSeries) -> Void = { _ in }
    @StateObject private var co: PlaybackCoordinator
    @State private var lastShownCurrent: Int?
    @State private var seasons: [HGSeries] = []
    @ObservedObject private var danmaku = DanmakuSettings.shared
    /// 画面铺满 (aspectFill) vs 完整自适应 (aspect) — hongguo-open-player fitMode.
    @AppStorage("stv.player.fill") private var fillScreen = false
    /// Technical info strip (⋯ → 技术信息).
    @AppStorage("stv.player.tech") private var showTech = true
    @State private var muted = false
    @State private var osd: String?
    @State private var verifyTarget: VerifyTarget?
    @StateObject private var adjuster = PlayerAdjuster()
    @State private var loadError: Error?
    @State private var showChrome = true
    @State private var lastInteraction = Date()
    @State private var scrubbing = false
    @State private var locked = false
    @State private var altSources: [HGSeries] = []
    /// nil = not searched yet, false = searching, true = done.
    @State private var altSearched: Bool?
    @State private var noAutoHide = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var panel: PlayerPanel?
    @State private var danmakuSheet = false
    @State private var speedMode = false
    @State private var previewRate: Double = 1.0
    @State private var pendingLock = false
    @State private var pendingCancel = false
    @State private var speedBaseIndex = 0
    @State private var lastStepOffset = 0
    /// Portrait feed content offset (pt): the shared video layer rides along with the page being swiped.
    @State private var feedScrollY: CGFloat = 0
    @State private var feedSettleWork: DispatchWorkItem?
    /// Running double-tap seek (+10/+20/… s) and which side it is on; drives the side bubble.
    @State private var seekRun: (total: Int, at: Date)?
    @Environment(\.verticalSizeClass) private var vClass
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryStore.shared

    private var landscape: Bool { vClass == .compact }

    init(series: HGSeries, startIndex: Int?, onSwitchSeries: @escaping (HGSeries) -> Void = { _ in }) {
        self.series = series; self.startIndex = startIndex; self.onSwitchSeries = onSwitchSeries
        _co = StateObject(wrappedValue: PlaybackCoordinator(series: series))
    }

    // MARK: Geometry

    /// Video aspect (w/h): the item's presentation size once known, else a guess from the series.
    private var aspect: CGFloat {
        if co.videoSize.width > 0, co.videoSize.height > 0 { return co.videoSize.width / co.videoSize.height }
        return series.orientation == "portrait" || (!series.source.isLongVideo && series.orientation != "landscape") ? 9.0 / 16 : 16.0 / 9
    }

    /// Where the player layer lives. Portrait + landscape-shaped video: the area above the bottom block
    /// (design v3: video centred in the top H−156 pt); otherwise the whole screen.
    private func videoArea(_ full: CGSize) -> CGRect {
        if !landscape, aspect > 1, !fillScreen { return CGRect(x: 0, y: 0, width: full.width, height: max(200, full.height - 156)) }
        return CGRect(origin: .zero, size: full)
    }

    private func videoRect(_ area: CGRect) -> CGRect {
        if fillScreen { return area }
        let a = aspect
        var w = area.width, h = w / a
        if h > area.height { h = area.height; w = h * a }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    var body: some View {
        GeometryReader { outer in
            let ins = outer.safeAreaInsets
            GeometryReader { geo in
                let full = geo.size
                let area = videoArea(full)
                let rect = videoRect(area)
                ZStack(alignment: .topLeading) {
                    Color.black
                    // A single in-window layer remains the PiP source across paging, rotation and buffering.
                    PlayerLayerView(coordinator: co, fill: fillScreen, engine: co.engineKind)
                        .accessibilityElement().accessibilityIdentifier("player.video").accessibilityValue(fillScreen ? "fill" : "fit")
                        .frame(width: area.width, height: area.height).offset(x: area.minX, y: area.minY - pageDrift(co.current ?? 0, page: full.height))
                        .allowsHitTesting(false)
                    if let held = co.heldFrame, !landscape {
                        // Previous episode's last frame, riding with the swipe until the next one is on screen.
                        Image(uiImage: held.image).resizable()
                            .frame(width: area.width, height: area.height).offset(x: area.minX, y: area.minY - pageDrift(held.index, page: full.height))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    Group {
                        if co.current != nil {
                            if landscape { stage(co.current!) } else { portraitFeed }
                        } else if let loadError {
                            ErrorStateView(error: loadError) { Task { await load() } }
                        } else {
                            PosterBackdrop(url: series.cover).overlay(ProgressView().tint(.white))
                        }
                    }
                    .frame(width: full.width, height: full.height)
                    if let sub = co.subtitleText, !co.pipActive {
                        // Aether loopback / software routes: the host draws the selected track's cues.
                        VStack {
                            Spacer()
                            Text(sub).font(.system(size: landscape ? 18 : 16, weight: .semibold)).foregroundStyle(.white)
                                .multilineTextAlignment(.center).shadow(color: .black, radius: 2).shadow(color: .black.opacity(0.8), radius: 4)
                                .padding(.horizontal, 24)
                                .padding(.bottom, (landscape ? 70 : 200) + ins.bottom)
                                .accessibilityIdentifier("player.subtitle")
                        }
                        .frame(width: full.width, height: full.height).allowsHitTesting(false)
                    }
                    if series.source == .hongguo, danmaku.enabled, !co.pipActive, !speedMode,
                       let i = co.current, co.readyIndex == i, co.episodes.indices.contains(i) {
                        danmakuLayer(i, full: full, ins: ins)
                    }
                    if !co.pipActive, controlsVisible, !locked {
                        gradients(full).transition(.opacity)
                    }
                    if panel != nil {
                        Color.black.opacity(0.5).frame(width: full.width, height: full.height)
                            .contentShape(Rectangle()).onTapGesture { closePanel() }
                            .accessibilityIdentifier("player.scrim")
                    }
                    if co.pipActive {
                        Button { co.togglePiP() } label: {
                            Label("返回播放器", systemImage: "pip.exit")
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(STVTheme.surface, in: Capsule())
                        }
                        .foregroundStyle(.white)
                        .position(x: full.width / 2, y: full.height / 2)
                    } else if locked {
                        if controlsVisible { lockOnly(full, ins: ins).transition(.opacity) }
                    } else if controlsVisible {
                        if co.current != nil, !scrubbing, panel == nil {
                            PlayerCenterControls(co: co, onInteract: flashChrome)
                                .position(x: landscape ? full.width / 2 : rect.midX, y: landscape ? full.height / 2 : rect.midY)
                                .transition(.opacity)
                        }
                        controls(full, ins: ins).transition(.opacity)
                    } else if co.readyIndex != nil, !speedMode {
                        // Chrome hidden: a 2 pt hairline at the bottom edge (played white 90 % / track white 16 %).
                        PlayerProgressBar(co: co, scrubbing: .constant(false), mini: true)
                            .frame(width: full.width - (landscape ? 120 : 0))
                            .position(x: full.width / 2, y: full.height - (landscape ? max(ins.bottom, 6) : 1))
                            .allowsHitTesting(false).transition(.opacity)
                    }
                    if let p = panel, !locked {
                        popover(p, full: full, ins: ins)
                    }
                    if let run = seekRun {
                        Label("\(run.total > 0 ? "+" : "−")\(abs(run.total)) 秒", systemImage: run.total > 0 ? "forward.fill" : "backward.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: Capsule())
                            .position(x: run.total > 0 ? full.width * 0.75 : full.width * 0.25, y: landscape ? full.height / 2 - 70 : rect.midY - 70)
                            .transition(.opacity).allowsHitTesting(false)
                            .accessibilityIdentifier("player.seekRun")
                    }
                    if let osd {
                        Text(osd).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.black.opacity(0.62), in: Capsule())
                            .position(x: full.width / 2, y: landscape ? full.height / 2 : rect.midY - 70)
                            .transition(.opacity).allowsHitTesting(false).accessibilityIdentifier("player.osd")
                    }
                    if let h = adjuster.hud, !speedMode {
                        PlayerAdjustHUD(side: h.side, value: h.value)
                            .position(x: full.width / 2, y: (landscape ? 24 : ins.top + 64) + 30)
                            .transition(.opacity).allowsHitTesting(false)
                    }
                    HiddenVolumeView(adjuster: adjuster).frame(width: 1, height: 1).allowsHitTesting(false)
                    if speedMode {
                        PlayerSpeedHUD(rate: previewRate, pendingLock: pendingLock, pendingCancel: pendingCancel,
                                       hasLockedRate: co.lockedRate != nil)
                            .position(x: full.width / 2, y: full.height / 2).allowsHitTesting(false)
                    }
                }
                .frame(width: full.width, height: full.height)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .background(InteractivePopEnabler())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(landscape)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.18), value: panel)
        .task {
            // Portrait by default for everything (landscape videos play centred). Rotating the phone (when
            // the system rotation lock is off) or the 横屏 button switches to landscape.
            OrientationGate.unlock()
            co.start()
            if co.current == nil { await load() }
        }
        .task { await screenshotHooks() }
        .task(id: lastInteraction) {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !noAutoHide, !co.paused || locked else { return }
            withAnimation(.easeOut(duration: 0.2)) { showChrome = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            co.didEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            co.didBecomeActive()
            flashChrome()
        }
        .alert("画中画暂不可用", isPresented: Binding(get: { co.pipError != nil }, set: { if !$0 { co.pipError = nil } })) {
            Button("好") { co.pipError = nil }
        } message: { Text(co.pipError ?? "") }
        .onAppear { OrientationGate.unlock() }
        .onDisappear { co.teardown(); adjuster.restoreBrightness(); OrientationGate.lockPortrait() }
        .onChange(of: co.current) { _ in scrubbing = false; flashChrome() }
        .onChange(of: co.readyIndex) { index in if index != nil { flashChrome() } }
        .onChange(of: landscape) { l in if !l { locked = false }; panel = nil }
        .sheet(item: $verifyTarget) { t in SiteVerifySheet(target: t) { if let c = co.current { co.activate(c) } } }
        .sheet(isPresented: $danmakuSheet, onDismiss: flashChrome) {
            DanmakuSettingsSheet(available: series.source == .hongguo)
                .presentationDragIndicator(.visible).compatPresentationBackground(STVTheme.surface)
        }
    }

    // MARK: Layers

    private func gradients(_ full: CGSize) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 120 : 150)
            Spacer(minLength: 0)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.5),
                                   .init(color: .black.opacity(0.86), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 200 : 300)
        }
        .frame(width: full.width, height: full.height)
        .allowsHitTesting(false)
    }

    /// Danmaku is laid out on the SCREEN (not the letterboxed video): full width, lanes from just under the
    /// top bar, `DanmakuRegion` decides how many fit above the bottom controls. 14 pt fade at both sides.
    private func danmakuLayer(_ i: Int, full: CGSize, ins: EdgeInsets) -> some View {
        let r = DanmakuRegion.compute(screen: full, safeTop: ins.top, safeBottom: ins.bottom, landscape: landscape, showTech: showTech,
                                      area: danmaku.area.fraction, laneHeight: DanmakuOverlay.laneHeight(danmaku), maxRows: danmaku.rows)
        return DanmakuOverlay(co: co, seriesId: series.seriesId, vid: co.episodes[i].vid, landscape: landscape, laneTop: r.top, laneCount: r.rows)
            .frame(width: full.width, height: full.height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 14 / max(1, full.width)),
                                         .init(color: .black, location: 1 - 14 / max(1, full.width)), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                // Invisible marker so UI tests can check the lane region (top / rows / bottom limit).
                Color.clear.frame(width: full.width, height: max(1, CGFloat(r.rows) * DanmakuOverlay.laneHeight(danmaku)))
                    .offset(y: r.top - DanmakuOverlay.laneHeight(danmaku) / 2)
                    .accessibilityElement().accessibilityIdentifier("player.danmaku.region")
                    .accessibilityValue("top=\(Int(r.top)) rows=\(r.rows) limit=\(Int(r.bottomLimit))")
                    .allowsHitTesting(false)
            }
    }

    // MARK: Portrait feed

    @ViewBuilder
    private var portraitFeed: some View {
        if #available(iOS 17.0, *) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(co.episodes.indices, id: \.self) { i in
                        stage(i).compatContainerRelativeFrame([.horizontal, .vertical]).id(i)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: Binding(get: { co.current }, set: { co.select($0) }))
            .compatScrollFeedback(onOffset: { feedScrollY = $0 }, onSettled: { feedSettled = $0; releaseHeldIfSettled() })
            .compatSelectionFeedback(trigger: co.current)
            .onChange(of: co.readyIndex) { _ in releaseHeldIfSettled() }
            .onChange(of: co.current) { new in
                if lastShownCurrent != nil, let new, co.episodes.indices.contains(new) { showOSD("第\(co.episodes[new].ep)集") }
                lastShownCurrent = new
            }
            .scrollDisabled(speedMode || scrubbing || co.pipActive || panel != nil)
        } else {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(co.episodes.indices, id: \.self) { i in
                                stage(i).frame(height: geo.size.height).id(i)
                            }
                        }
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("feed")).minY)
                            }
                        )
                    }
                    .coordinateSpace(name: "feed")
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(ScrollOffsetKey.self) { minY in
                        let y = -minY
                        feedScrollY = y
                        feedSettleWork?.cancel()
                        let work = DispatchWorkItem {
                            let pageHeight = geo.size.height
                            guard pageHeight > 0 else { return }
                            let idx = Int(round(y / pageHeight))
                            if idx >= 0, idx < co.episodes.count, idx != co.current {
                                co.select(idx)
                                withAnimation { proxy.scrollTo(idx, anchor: .top) }
                            }
                        }
                        feedSettleWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                    }
                    .onAppear { proxy.scrollTo(co.current, anchor: .top) }
                    .onChange(of: co.current) { new in
                        if let new { withAnimation { proxy.scrollTo(new, anchor: .top) } }
                        if lastShownCurrent != nil, let new, co.episodes.indices.contains(new) { showOSD("第\(co.episodes[new].ep)集") }
                        lastShownCurrent = new
                        releaseHeldIfSettled()
                    }
                    .scrollDisabled(speedMode || scrubbing || co.pipActive || panel != nil)
                }
            }
            .compatSelectionFeedback(trigger: co.current)
            .onChange(of: co.readyIndex) { _ in releaseHeldIfSettled() }
        }
    }

    /// Drop the previous episode's still once the new one is playing and the page has stopped moving.
    private func releaseHeldIfSettled() {
        guard co.heldFrame != nil, let r = co.readyIndex, r == co.current, feedSettled else { return }
        co.releaseHeldFrame()
    }
    @State private var feedSettled = true

    /// Offset of page `index` from rest (portrait), capped at one page either way.
    private func pageDrift(_ index: Int, page: CGFloat) -> CGFloat {
        guard !landscape, page > 0 else { return 0 }
        return max(-page, min(page, feedScrollY - CGFloat(index) * page))
    }

    private func stage(_ i: Int) -> some View {
        ZStack {
            if co.readyIndex == i {
                PlayerTouchCatcher(
                    edgeBackWidth: edgeBackWidth, speedMode: speedMode, locked: locked,
                    onTap: handleTap,
                    onDoubleTap: handleDoubleTap,
                    onSpeedBegan: enterSpeedMode,
                    onSpeedChanged: handleSpeedTranslation,
                    onSpeedEnded: endSpeedMode,
                    landscape: landscape,
                    onAdjustBegan: { adjuster.begin($0) },
                    onAdjustChanged: { adjuster.change($0, fraction: $1) },
                    onAdjustEnded: { adjuster.end() },
                    onPinchFill: { fill in
                        guard fill != fillScreen else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { fillScreen = fill }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showOSD(fill ? "画面：铺满全屏" : "画面：完整自适应")
                    }
                )
            } else {
                // Held still on the episode being left; the new episode's page stays see-through so the video
                // layer (riding with it) is visible the moment its first frame lands — no poster cutting in.
                if (i == co.heldFrame?.index || i == co.current) && co.errors[i] == nil {
                    Color.clear
                } else {
                    PosterBackdrop(url: series.cover)
                }
                if let error = co.errors[i] {
                    VStack(spacing: 12) {
                        Text(error).font(.footnote).multilineTextAlignment(.center)
                        if let t = co.verifyTargets[i] {
                            Button("去验证") { verifyTarget = t }.buttonStyle(.borderedProminent)
                        }
                        Button("重试") { co.activate(i) }.buttonStyle(.borderedProminent)
                    }.padding(32)
                } else if i == co.current {
                    ProgressView("正在载入分集").tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlsVisible: Bool {
        !speedMode && (showChrome || co.readyIndex == nil || scrubbing || panel != nil || voiceOver)
    }

    // MARK: Chrome

    /// Dim factor for everything but the progress bar while scrubbing (design: 28 %).
    private var dim: Double { scrubbing ? 0.28 : 1 }

    @ViewBuilder private func controls(_ full: CGSize, ins: EdgeInsets) -> some View {
        if landscape { landscapeControls(full, ins: ins) } else { portraitControls(full, ins: ins) }
    }

    private func portraitControls(_ full: CGSize, ins: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PlayerIconButton(symbol: "chevron.left", label: "返回") { dismiss() }
                Spacer()
                PlayerIconButton(symbol: "pip.enter", label: "画中画") { co.togglePiP() }
                    .disabled(!co.pipPossible).opacity(co.pipPossible ? 1 : 0.55)
                    .accessibilityIdentifier("player.pip")
                PlayerIconButton(symbol: library.isFavorite(series) ? "heart.fill" : "heart",
                                 label: library.isFavorite(series) ? "取消收藏" : "收藏") {
                    library.toggleFavorite(series); flashChrome()
                }
                moreMenu
            }
            .padding(.horizontal, 16).padding(.top, ins.top)
            .opacity(dim)
            if showTech, let t = co.tech {
                PlayerTechStrip(tech: t).padding(.top, 14).opacity(dim)
            }
            Spacer(minLength: 0)
            if let i = co.current, co.episodes.indices.contains(i) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        meta(i, skip: true).padding(.bottom, 10)
                        Text(co.detail?.title ?? series.title)
                            .font(.system(size: 23, weight: .bold)).lineLimit(1)
                            .accessibilityIdentifier("player.title")
                            .padding(.bottom, 30)
                    }
                    .opacity(scrubbing ? 0 : 1)
                    .opacity(panel != nil ? 0.35 : 1)
                    if co.readyIndex == i {
                        PlayerTimelineV3(co: co, scrubbing: $scrubbing, onInteract: flashChrome).id(i)
                            .opacity(panel != nil ? 0.35 : 1)
                    }
                }
                .padding(.horizontal, 20)
                iconRow(i).padding(.horizontal, 5).padding(.top, 6)
                    .padding(.bottom, max(0, ins.bottom - 6))
                    .opacity(dim)
            }
        }
        .foregroundStyle(.white)
        .frame(width: full.width, height: full.height)
    }

    private func landscapeControls(_ full: CGSize, ins: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PlayerIconButton(symbol: "chevron.left", label: "返回") { dismiss() }
                Button { co.autoNext.toggle(); showOSD(co.autoNext ? "连播：开" : "连播：关") } label: {
                    Image(systemName: "repeat").font(.system(size: 19, weight: .medium))
                        .opacity(co.autoNext ? 1 : 0.4).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(co.autoNext ? "关闭连播" : "开启连播").accessibilityIdentifier("player.autoNext")
                Spacer()
                PlayerIconButton(symbol: "lock.open", label: "锁屏") { locked = true; panel = nil; flashChrome() }
                    .accessibilityIdentifier("player.lock")
                PlayerIconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "退出横屏") {
                    OrientationGate.exitLandscape(); flashChrome()
                }
                .accessibilityIdentifier("player.exitFullscreen")
            }
            .overlay { if showTech, let t = co.tech { PlayerTechStrip(tech: t, landscape: true) } }
            .padding(.horizontal, 60).padding(.top, 18)
            .opacity(dim)
            Spacer(minLength: 0)
            if let i = co.current, co.episodes.indices.contains(i) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom) {
                        meta(i, skip: false)
                        if showSkip {
                            Button { skipIntro() } label: {
                                HStack(spacing: 4) { Text("跳过片头"); Image(systemName: "play.fill").font(.system(size: 8)) }
                                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            }.buttonStyle(.plain).accessibilityIdentifier("player.skipIntro")
                        }
                    }
                    .opacity(scrubbing ? 0 : 1).opacity(panel != nil ? 0.35 : 1)
                    .padding(.bottom, 8)
                    HStack(spacing: 8) {
                        Text(co.detail?.title ?? series.title)
                            .font(.system(size: 22, weight: .bold)).lineLimit(1)
                            .accessibilityIdentifier("player.title")
                            .opacity(scrubbing ? 0.28 : 1).opacity(panel != nil ? 0.35 : 1)
                        Spacer(minLength: 12)
                        iconRow(i).opacity(dim)
                    }
                    .padding(.bottom, 14)
                    if co.readyIndex == i {
                        PlayerTimelineV3(co: co, scrubbing: $scrubbing, onInteract: flashChrome, landscape: true).id(i)
                            .opacity(panel != nil ? 0.35 : 1)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, max(ins.bottom, 8))
            }
        }
        .foregroundStyle(.white)
        .frame(width: full.width, height: full.height)
    }

    private func lockOnly(_ full: CGSize, ins: EdgeInsets) -> some View {
        PlayerIconButton(symbol: "lock.fill", label: "解锁") { locked = false; flashChrome() }
            .accessibilityIdentifier("player.unlock")
            .position(x: max(ins.leading, 16) + 44, y: full.height / 2)
    }

    private var moreMenu: some View {
        Menu {
            Toggle(isOn: $showTech) { Label("技术信息", systemImage: "info.circle") }
            Toggle(isOn: Binding(get: { co.autoNext }, set: { co.autoNext = $0 })) { Label("自动连播", systemImage: "repeat") }
            Button { fillScreen.toggle(); showOSD(fillScreen ? "画面：铺满全屏" : "画面：完整自适应") } label: {
                Label(fillScreen ? "完整自适应" : "铺满全屏", systemImage: fillScreen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            Button { muted.toggle(); co.setMuted(muted); showOSD(muted ? "已静音" : "已取消静音") } label: {
                Label(muted ? "取消静音" : "静音", systemImage: muted ? "speaker.wave.2" : "speaker.slash")
            }
            if series.source == .hongguo {
                Button { danmakuSheet = true } label: { Label("弹幕设置", systemImage: "slider.horizontal.3") }
            }
            Button { UIPasteboard.general.string = co.detail?.title ?? series.title; showOSD("已复制剧名") } label: {
                Label("复制剧名", systemImage: "doc.on.doc")
            }
            if let pb = co.prebuffer {
                Section(pb.lowStorage ? "存储不足，已停止预缓冲" : "已预缓冲 \(pb.bytes / 1_048_576)MB") {}
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background { Circle().fill(.ultraThinMaterial).overlay(Circle().fill(.black.opacity(0.42))) }
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
        }
        .accessibilityLabel("更多").accessibilityIdentifier("player.more")
        .simultaneousGesture(TapGesture().onEnded { flashChrome() })
    }

    // MARK: Caption pieces

    /// Season number: 「第N季」-style titles, else a trailing number (「…为神8」), else 1.
    static func seasonNo(_ title: String) -> Int {
        let i = SeasonParser.parse(title)
        if i.explicit { return i.number }
        let tail = String(title.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        if (1...2).contains(tail.count), let n = Int(tail), n > 0 { return n }
        return 1
    }

    /// 季 chips, newest first (design: 第8季 · 第7季 …); titles if the numbers don't tell them apart.
    private var seasonChips: [(id: String, title: String)] {
        let nums = seasons.map { Self.seasonNo($0.title) }
        guard Set(nums).count == seasons.count else { return seasons.map { ($0.seriesId, SeasonStore.label($0, in: seasons) ?? $0.title) } }
        return zip(seasons, nums).sorted { $0.1 > $1.1 }.map { ($0.0.seriesId, "第\($0.1)季") }
    }

    private var seasonTag: String? {
        guard seasons.count > 1 else { return nil }
        let nums = seasons.map { Self.seasonNo($0.title) }
        guard Set(nums).count == seasons.count else { return nil }
        return "S\(Self.seasonNo(seasons.first { $0.seriesId == series.seriesId }?.title ?? series.title))"
    }

    private func meta(_ i: Int, skip: Bool) -> some View {
        let e = co.episodes[i]
        let longList = series.source.isLongVideo
        let line: String, strong: String, rest: String
        if longList {
            if co.episodes.count > 1 { line = ""; strong = "S1:E\(e.ep)"; rest = e.title.isEmpty ? "" : " · " + e.title }
            else { line = series.subtitle ?? Fmt.meta(series); strong = ""; rest = "" }
        } else {
            line = seasonTag.map { $0 + " · " } ?? ""; strong = "第\(e.ep)集"; rest = " / 共\(co.episodes.count)集"
        }
        return PlayerMetaRow(source: longList && co.episodes.count > 1 ? nil : series.source.label, line: line, lineStrong: strong, rest: rest,
                             showSkip: skip && showSkip, onSkip: skipIntro)
    }

    private var introEnd: Double { series.source.isLongVideo ? 90 : 15 }
    private var showSkip: Bool { co.readyIndex != nil && co.time < introEnd - 1 && co.duration > introEnd + 30 }
    private func skipIntro() {
        guard co.duration > 0 else { return }
        co.seek(fraction: introEnd / co.duration); showOSD("已跳过片头")
    }

    // MARK: Icon row

    private var qualityTag: String {
        if let t = co.tech, !t.resolution.isEmpty { return t.resolution }
        if let i = co.current, let q = co.chosen[i]?.quality, !q.isEmpty { return String(q.prefix(5)) }
        return "画质"
    }

    @ViewBuilder private func iconRow(_ i: Int) -> some View {
        let items = HStack(spacing: landscape ? 6 : 0) {
            slot { PlayerRowIcon(id: "player.rate", a11y: "播放倍速 " + SpeedPopover.label(co.playbackRate), active: panel == .rates, action: { toggle(.rates) }) {
                if co.playbackRate == 1 { Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 19)) }
                else { Text(SpeedPopover.label(co.playbackRate)).font(.system(size: 14, weight: .bold)).foregroundStyle(STVTheme.accent) }
            } }
            slot { PlayerRowIcon(id: "player.quality", a11y: "画质与播放源", active: panel == .quality, action: { toggle(.quality) }) { OutlinedTag(text: qualityTag) } }
            slot { PlayerRowIcon(id: "player.audio", a11y: "音轨", active: panel == .audio, action: { toggle(.audio) }) {
                Image(systemName: "waveform").font(.system(size: 19))
            } }
            slot { PlayerRowIcon(id: "player.subtitles", a11y: "字幕", active: panel == .subtitles, action: { toggle(.subtitles) }) {
                Image(systemName: "text.bubble").font(.system(size: 19))
            } }
            slot { PlayerRowIcon(id: "player.danmaku", a11y: danmaku.enabled ? "关闭弹幕" : "开启弹幕", action: {
                guard series.source == .hongguo else { showOSD("当前片源不支持弹幕"); return }
                danmaku.enabled.toggle(); flashChrome()
            }) { DanmakuGlyph(on: danmaku.enabled && series.source == .hongguo).opacity(series.source == .hongguo ? 1 : 0.4) } }
            slot { PlayerRowIcon(id: "player.episodes", a11y: "选集", active: panel == .episodes, action: { toggle(.episodes) }) {
                Image(systemName: "square.grid.2x2").font(.system(size: 19))
            } }
            if !landscape {
                slot { PlayerRowIcon(id: "player.fullscreen", a11y: "横屏全屏", action: { OrientationGate.enterLandscape(); flashChrome() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18))
                } }
            }
        }
        items.frame(maxWidth: landscape ? nil : .infinity)
    }

    @ViewBuilder private func slot<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if landscape { c() } else { c().frame(maxWidth: .infinity) }
    }

    private func toggle(_ p: PlayerPanel) {
        withAnimation(.easeOut(duration: 0.18)) { panel = panel == p ? nil : p }
        flashChrome()
        if p == .quality, altSearched == nil { altSearched = false; Task { await findAltSources(); altSearched = true } }
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.18)) { panel = nil }
        flashChrome()
    }

    // MARK: Popovers

    @ViewBuilder private func popover(_ p: PlayerPanel, full: CGSize, ins: EdgeInsets) -> some View {
        let width: CGFloat = {
            switch p {
            case .episodes: return landscape ? 380 : full.width - 24
            case .rates: return landscape ? 230 : 220
            default: return 270
            }
        }()
        let maxH: CGFloat = landscape ? (p == .episodes ? 270 : full.height - 44 - 110)
                                      : min(p == .episodes ? 372 : 420, full.height * 0.5)
        let body = popoverContent(p)
            .frame(width: width)
            .frame(maxHeight: maxH, alignment: .top)
            .fixedSize(horizontal: false, vertical: p != .episodes)
            .playerGlass(20, strong: true)
            .gesture(DragGesture(minimumDistance: 24).onEnded { v in if v.translation.height > 60 { closePanel() } })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.popover.\(p.rawValue)")
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: landscape ? .topTrailing : .bottomLeading)))
        if landscape {
            VStack { HStack { Spacer(); body }; Spacer() }
                .padding(.top, p == .episodes ? 14 : 44).padding(.trailing, 48)
                .frame(width: full.width, height: full.height)
        } else {
            VStack { Spacer(); HStack { body; Spacer(minLength: 0) } }
                .padding(.horizontal, 12).padding(.bottom, max(0, ins.bottom - 6) + 44 + 12)
                .frame(width: full.width, height: full.height)
        }
    }

    @ViewBuilder private func popoverContent(_ p: PlayerPanel) -> some View {
        let i = co.current ?? 0
        switch p {
        case .rates:
            SpeedPopover(current: co.playbackRate, landscape: landscape, maxRate: co.engine.maxRate) { r in co.lockRate(r); closePanel() }
        case .quality:
            ScrollView {
                QualityPopover(streams: co.streams[i] ?? [], chosen: co.chosen[i], sources: sourceRows,
                               streamsTitle: series.source.isLongVideo ? series.source.streamSectionTitle : "画质") { s in
                    co.choose(s, for: i); closePanel()
                }
            }.scrollIndicators(.hidden)
        case .audio:
            TrackPopover(title: "音轨", options: co.audioOptions, selected: co.audioSelected, allowsOff: false,
                         emptyText: "当前视频只有一条音轨") { o in if let o { co.selectAudio(o) }; closePanel() }
        case .subtitles:
            TrackPopover(title: "字幕", options: co.subtitleOptions, selected: co.subtitleSelected, allowsOff: true,
                         emptyText: "当前视频没有可选字幕") { o in co.selectSubtitle(o); closePanel() }
        case .episodes:
            EpisodesPopover(episodes: co.episodes, current: co.current ?? 0,
                            seasons: seasonChips,
                            currentSeason: series.seriesId, listStyle: series.source.isLongVideo,
                            dateLine: series.onlineTime > 0 ? Self.date(series.onlineTime) : nil,
                            onPick: { idx in closePanel(); co.select(idx) },
                            onSeason: { id in
                                guard id != series.seriesId, let s = seasons.first(where: { $0.seriesId == id }) else { return }
                                panel = nil; onSwitchSeries(s)
                            })
        case .danmaku:
            EmptyView()
        }
    }

    private static func date(_ t: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy年MM月dd日"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// 播放源 rows: the current source, plus the same title on the other short-drama source (红果 ⇄ 黄果).
    private var sourceRows: [(title: String, detail: String, current: Bool, action: () -> Void)] {
        // 红果 ⇄ 黄果 only while 黄果 is switched on in 片源管理 (18+).
        guard series.source == .huangguo || (series.source == .hongguo && SourceGate.shared.showHuangguo) else { return [] }
        var rows: [(title: String, detail: String, current: Bool, action: () -> Void)] = [(series.source.label, "当前", true, {})]
        for s in altSources.prefix(2) {
            rows.append((s.source.label, "备用", false, { panel = nil; onSwitchSeries(s) }))
        }
        if altSources.isEmpty {
            let other: DramaSource = series.source == .hongguo ? .huangguo : .hongguo
            rows.append((other.label, altSearched == true ? "无同名剧集" : "查找中…", false, {}))
        }
        return rows
    }

    private func findAltSources() async {
        let title = co.detail?.title ?? series.title
        guard !title.isEmpty else { return }
        func norm(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "").lowercased() }
        var found: [HGSeries] = []
        if series.source == .hongguo {
            if SourceGate.shared.showHuangguo, let r = try? await HuangguoClient.shared.search(title) { found = r.filter { norm($0.title) == norm(title) } }
        } else if series.source == .huangguo {
            if let r = try? await HongguoClient.shared.search(title) { found = r.items.filter { norm($0.title) == norm(title) } }
        }
        altSources = Array(found.prefix(1))
    }

    // MARK: Taps

    private func handleTap() {
        if panel != nil { closePanel(); return }
        if locked { flashChrome(); return }
        if showChrome && controlsVisible { withAnimation(.easeOut(duration: 0.2)) { showChrome = false } }
        else { flashChrome() }
    }

    /// Double tap: left third −10 s, right third +10 s, middle play / pause.
    private func handleDoubleTap(_ x: CGFloat) {
        guard !locked else { return }
        if x < 1.0 / 3 || x > 2.0 / 3 {
            let step = x > 2.0 / 3 ? 10 : -10, now = Date()
            // Same direction within the streak window adds up: +10, +20, +30 …
            let total = (seekRun.flatMap { now.timeIntervalSince($0.at) < 0.9 && ($0.total > 0) == (step > 0) ? $0.total : nil } ?? 0) + step
            co.seek(by: Double(step))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { seekRun = (total, now) }
            flashChrome()
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if seekRun?.at == now { withAnimation(.easeIn(duration: 0.2)) { seekRun = nil } }
            }
        }
        else { co.togglePause(); flashChrome() }
    }

    private func showOSD(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { osd = text }
        flashChrome()
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if osd == text { withAnimation(.easeIn(duration: 0.25)) { osd = nil } }
        }
    }

    // MARK: Speed gesture
    // Priority: edge-back (nav) > vertical page swipe > long-press speed > tap.
    // Implemented in PlayerTouchCatcher (UIKit) so ScrollView paging / interactive pop are not stolen.
    // Speed drag only runs after long-press succeeds; scrollDisabled(speedMode) then locks paging.

    private let edgeBackWidth: CGFloat = 36

    private func enterSpeedMode() {
        let base = co.lockedRate ?? co.playbackRate
        previewRate = base
        speedBaseIndex = PlaybackCoordinator.stepIndex(of: base)
        lastStepOffset = 0
        pendingLock = false
        pendingCancel = false
        speedMode = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if co.paused { co.togglePause() }
        co.applyRate(previewRate)
    }

    private func handleSpeedTranslation(_ translation: CGSize) {
        let dx = translation.width
        let dy = translation.height
        let absX = abs(dx)
        let absY = abs(dy)
        if absY > 56, absY > absX * 1.15 {
            if dy < -56 {
                pendingLock = true
                pendingCancel = false
            } else if dy > 56 {
                pendingCancel = true
                pendingLock = false
            }
        } else if absX > 28 {
            pendingLock = false
            pendingCancel = false
            let stepPts: CGFloat = 44
            let offset = Int((dx / stepPts).rounded(.towardZero))
            if offset != lastStepOffset {
                lastStepOffset = offset
                let top = PlaybackCoordinator.rateSteps.lastIndex { $0 <= co.engine.maxRate + 0.001 } ?? PlaybackCoordinator.rateSteps.count - 1
                let idx = max(0, min(top, speedBaseIndex + offset))
                let next = PlaybackCoordinator.rateSteps[idx]
                if next != previewRate {
                    previewRate = next
                    co.applyRate(next)
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
        }
    }

    private func endSpeedMode() {
        defer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                speedMode = false
                pendingLock = false
                pendingCancel = false
            }
        }
        if pendingCancel {
            co.unlockRate()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if pendingLock {
            co.lockRate(previewRate)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        co.restoreLockedOrNormal()
    }

    private func flashChrome() {
        showChrome = true
        lastInteraction = Date()
    }

    private func load() async {
        do {
            let d = try await Catalog.detail(series)
            try Task.checkCancellation()
            loadError = nil
            guard !d.episodes.isEmpty else { throw ProviderError.upstream("暂无可播放分集") }
            let start = min(max(0, startIndex ?? library.progress(for: series)?.episodeIndex ?? 0), d.episodes.count - 1)
            co.detail = d
            co.select(start)
            flashChrome()
            seasons = await SeasonStore.seasons(for: d, series: series)
        } catch { if !Task.isCancelled { loadError = error } }
    }

    /// DEBUG / screenshot hooks (design-v3 state shots):
    /// STV_PANEL=episodes|rates|quality|audio|subtitles|osd, STV_PANEL_DELAY, STV_PAUSE=1, STV_HIDE_CHROME=1,
    /// STV_LANDSCAPE=1, STV_FILL=1, STV_KEEP_CHROME=1.
    private func screenshotHooks() async {
        let env = ProcessInfo.processInfo.environment
        if let v = env["STV_FILL"] { fillScreen = v == "1" }
        if env["STV_KEEP_CHROME"] == "1" { noAutoHide = true }
        #if DEBUG
        if let a = env["STV_ADJUST"], !a.isEmpty {
            try? await Task.sleep(for: .seconds(6))
            let parts = a.split(separator: ":"); let side: AdjustSide = parts.first == "volume" ? .volume : .brightness
            adjuster.begin(side); adjuster.change(side, fraction: (Double(parts.last ?? "") ?? 0.5) - (adjuster.hud?.value ?? 0))
        }
        #endif
        let wantsState = env["STV_PANEL"] != nil || env["STV_PAUSE"] == "1" || env["STV_HIDE_CHROME"] == "1" || env["STV_LANDSCAPE"] == "1"
            || env["STV_SEEK"] != nil
        guard wantsState else { return }
        if let t = Double(env["STV_SEEK"] ?? "") {
            for _ in 0..<80 where co.duration <= 0 || co.readyIndex == nil { try? await Task.sleep(for: .milliseconds(250)) }
            if co.duration > 0 { co.seek(fraction: t / co.duration) }
        }
        try? await Task.sleep(for: .seconds(Double(env["STV_PANEL_DELAY"] ?? "") ?? 8))
        if env["STV_LANDSCAPE"] == "1" { OrientationGate.enterLandscape(); try? await Task.sleep(for: .seconds(1.5)) }
        if env["STV_PAUSE"] == "1", !co.paused { co.togglePause() }
        if env["STV_HIDE_CHROME"] == "1" { noAutoHide = false; withAnimation { showChrome = false }; return }
        flashChrome()
        if let p = env["STV_PANEL"], !p.isEmpty {
            if p == "osd" { showOSD(env["STV_OSD"] ?? "画面：铺满全屏") }
            else if let panelKind = PlayerPanel(rawValue: p) { toggle(panelKind) }
        }
    }
}

struct EpisodePickerSheet: View {
    let episodes: [HGEpisode]
    let ranges: [EpisodeRange]
    let current: Int
    let onPick: (Int) -> Void
    @State private var group = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选集 · 共\(episodes.count)集").font(.headline).padding(.top, 18).padding(.horizontal, 20)
            if ranges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ranges.indices, id: \.self) { i in
                            let on = i == group
                            Button { withAnimation(.snappy) { group = i } } label: {
                                Text(EpisodeGroups.label(ranges[i], episodes: episodes))
                                    .font(.subheadline.weight(on ? .semibold : .regular))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(on ? Color.white.opacity(0.18) : Color.white.opacity(0.06), in: Capsule())
                                    .foregroundStyle(.white)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            let r = ranges.indices.contains(group) ? ranges[group] : EpisodeRange(0, max(0, episodes.count - 1))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(r.start...r.end, id: \.self) { i in
                        Button { onPick(i) } label: {
                            Text("\(episodes[i].ep)").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(current == i ? STVTheme.accent.opacity(0.17) : STVTheme.glass, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(current == i ? STVTheme.accent : STVTheme.text)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
        }
        .onAppear {
            if let i = ranges.firstIndex(where: { current >= $0.start && current <= $0.end }) { group = i }
        }
    }
}

struct PosterBackdrop: View {
    let url: String
    var body: some View {
        CoverView(url: url, corner: 0)
            .overlay(LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.7)],
                                    startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
    }
}

/// Hosts the active core's video surface (AetherPlayerView or an AVPlayerLayer view); swapped when an
/// episode falls back from AetherEngine to AVPlayer.
struct PlayerLayerView: UIViewRepresentable {
    let coordinator: PlaybackCoordinator
    var fill: Bool = false
    var engine: PlayerEngineKind = .aether

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        mount(in: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { mount(in: view) }

    private func mount(in container: UIView) {
        coordinator.fill = fill
        let surface = coordinator.engine.surface
        guard surface.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        surface.frame = container.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(surface)
    }
}

// MARK: - Player touch catcher (UIKit)

/// Clear overlay that owns tap + long-press speed without blocking UIScrollView paging
/// or UINavigationController interactive pop.
///
/// Why UIKit: SwiftUI `LongPressGesture.sequenced(before: DragGesture)` — even as
/// `simultaneousGesture` — still delays/fails ScrollView pans and edge-back. A
/// `UILongPressGestureRecognizer` with `shouldRecognizeSimultaneouslyWith == true`
/// and `hitTest` returning nil on the left edge cooperates cleanly.
struct PlayerTouchCatcher: UIViewRepresentable {
    var edgeBackWidth: CGFloat
    var speedMode: Bool
    var locked: Bool = false
    var onTap: () -> Void
    /// x as a fraction of the width.
    var onDoubleTap: (CGFloat) -> Void = { _ in }
    var onSpeedBegan: () -> Void
    var onSpeedChanged: (CGSize) -> Void
    var onSpeedEnded: () -> Void
    var landscape: Bool = false
    var onAdjustBegan: (AdjustSide) -> Void = { _ in }
    var onAdjustChanged: (AdjustSide, Double) -> Void = { _, _ in }
    var onAdjustEnded: () -> Void = {}
    /// Pinch out → fill the screen, pinch in → fit (true = fill).
    var onPinchFill: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isMultipleTouchEnabled = true   // pinch to fill / fit
        v.backgroundColor = .clear
        context.coordinator.bind(to: v)
        return v
    }

    func updateUIView(_ uiView: CatcherView, context: Context) {
        uiView.edgeBackWidth = edgeBackWidth
        let c = context.coordinator
        c.onTap = onTap
        c.onDoubleTap = onDoubleTap
        c.onSpeedBegan = onSpeedBegan
        c.onSpeedChanged = onSpeedChanged
        c.onSpeedEnded = onSpeedEnded
        c.landscape = landscape
        c.speedMode = speedMode
        c.onAdjustBegan = onAdjustBegan
        c.onAdjustChanged = onAdjustChanged
        c.onAdjustEnded = onAdjustEnded
        c.onPinchFill = onPinchFill
        c.pinch.isEnabled = !locked && !speedMode
        // While speed HUD is up, keep catcher receiving the finger; chrome is hit-disabled.
        uiView.isUserInteractionEnabled = true
        c.longPress.isEnabled = !locked
        c.adjustPan.isEnabled = !locked
        c.doubleTapEnabled = !speedMode && !locked
        c.tap.isEnabled = !speedMode
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void = {}
        var onDoubleTap: (CGFloat) -> Void = { _ in }
        var onSpeedBegan: () -> Void = {}
        var onSpeedChanged: (CGSize) -> Void = { _ in }
        var onSpeedEnded: () -> Void = {}
        var landscape = false
        var speedMode = false
        var onAdjustBegan: (AdjustSide) -> Void = { _ in }
        var onAdjustChanged: (AdjustSide, Double) -> Void = { _, _ in }
        var onAdjustEnded: () -> Void = {}
        var onPinchFill: (Bool) -> Void = { _ in }
        let pinch = UIPinchGestureRecognizer()
        let tap = UITapGestureRecognizer()
        /// Double taps are recognised from single-tap timing (no UITapGestureRecognizer(2)), so a single tap
        /// acts at once instead of waiting ~0.3 s for a second tap that may never come.
        var doubleTapEnabled = true
        private var lastTap: (at: Date, x: CGFloat)?
        /// After a side double tap, further taps on that side keep seeking until this time.
        private var streak: (until: Date, right: Bool)?
        let longPress = UILongPressGestureRecognizer()
        /// Brightness / volume vertical pan (edge strips in portrait, half screens in landscape).
        let adjustPan = UIPanGestureRecognizer()
        private var adjustSide: AdjustSide?
        private var speedOrigin: CGPoint = .zero
        private var speedArmed = false
        private weak var view: CatcherView?

        func bind(to view: CatcherView) {
            self.view = view
            tap.addTarget(self, action: #selector(handleTap))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            longPress.addTarget(self, action: #selector(handleLongPress))
            longPress.delegate = self
            longPress.minimumPressDuration = 0.45
            // Small movement tolerance so a vertical page flick cancels speed long-press quickly.
            longPress.allowableMovement = 10
            longPress.cancelsTouchesInView = false
            adjustPan.addTarget(self, action: #selector(handleAdjust))
            adjustPan.delegate = self
            adjustPan.maximumNumberOfTouches = 1
            adjustPan.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(longPress)
            view.addGestureRecognizer(adjustPan)
            pinch.addTarget(self, action: #selector(handlePinch))
            pinch.delegate = self
            pinch.cancelsTouchesInView = false
            view.addGestureRecognizer(pinch)
            // Prefer long-press over tap when both could fire (hold, don't tap).
            tap.require(toFail: longPress)
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let view else { return }
            tapped(at: g.location(in: view), in: view)
        }

        /// Single tap now; second tap within 0.3 s near the first = double tap; side streak keeps seeking.
        private func tapped(at p: CGPoint, in view: UIView) {
            let x = p.x / max(1, view.bounds.width), now = Date()
            let side: Bool? = x < 1.0 / 3 ? false : (x > 2.0 / 3 ? true : nil)
            guard doubleTapEnabled else { onTap(); return }
            if let s = streak, now < s.until, side == s.right {
                streak = (now.addingTimeInterval(0.7), s.right)
                onDoubleTap(x); return
            }
            streak = nil
            if let l = lastTap, now.timeIntervalSince(l.at) < 0.3, abs(l.x - x) < 0.2 {
                lastTap = nil
                if let side { streak = (now.addingTimeInterval(0.7), side) }
                onDoubleTap(x); return
            }
            lastTap = (now, x)
            onTap()
        }

        @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard let view else { return }
            let loc = g.location(in: view)
            switch g.state {
            case .began:
                speedArmed = true
                speedOrigin = loc
                onSpeedBegan()
            case .changed:
                guard speedArmed else { return }
                let t = CGSize(width: loc.x - speedOrigin.x, height: loc.y - speedOrigin.y)
                onSpeedChanged(t)
            case .ended, .cancelled, .failed:
                // Only end if we actually entered speed mode — a cancelled/failed press
                // (vertical flick) must not call restoreLockedOrNormal().
                if speedArmed {
                    speedArmed = false
                    onSpeedEnded()
                }
            default:
                break
            }
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            // Decide once per pinch, as soon as it is clearly in or out.
            guard g.state == .changed, abs(g.scale - 1) > 0.12 else { return }
            onPinchFill(g.scale > 1)
            g.isEnabled = false; g.isEnabled = true   // cancel the rest of this pinch
        }

        @objc private func handleAdjust(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            switch g.state {
            case .began:
                adjustSide = Coordinator.side(g, in: view, landscape: landscape)
                if let s = adjustSide { onAdjustBegan(s) }
            case .changed:
                guard let s = adjustSide else { return }
                let usable = max(200, view.bounds.height * 0.75)
                onAdjustChanged(s, Double(-g.translation(in: view).y / usable))
            case .ended, .cancelled, .failed:
                if adjustSide != nil { onAdjustEnded() }
                adjustSide = nil
            default: break
            }
        }

        static func side(_ g: UIGestureRecognizer, in view: CatcherView, landscape: Bool) -> AdjustSide? {
            PlayerAdjuster.zone(x: g.location(in: view).x, width: view.bounds.width, landscape: landscape, edge: view.edgeBackWidth)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The adjust pan owns its touch exclusively (no paging/speed at the same time);
            // tap + long-press always coexist with UIScrollView pan + interactive pop.
            if gestureRecognizer === adjustPan || otherGestureRecognizer === adjustPan { return false }
            return true
        }

        /// In the edge strips the feed's paging pan waits for the adjust pan to fail; in the middle the
        /// adjust pan fails on its first move (gestureRecognizerShouldBegin) so paging is not delayed.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === adjustPan && otherGestureRecognizer.view is UIScrollView
                && otherGestureRecognizer is UIPanGestureRecognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view else { return true }
            let x = gestureRecognizer.location(in: view).x
            // Left strip reserved for interactive pop — never claim it.
            if x < view.edgeBackWidth { return false }
            if gestureRecognizer === adjustPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                guard !speedMode, Coordinator.side(pan, in: view, landscape: landscape) != nil else { return false }
                let v = pan.velocity(in: view)
                return abs(v.y) > abs(v.x) * 1.2
            }
            return true
        }
    }

    final class CatcherView: UIView {
        var edgeBackWidth: CGFloat = 36

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Pass left-edge touches through so nav interactivePop can begin.
            if point.x < edgeBackWidth { return nil }
            guard self.point(inside: point, with: event) else { return nil }
            return self
        }
    }
}

