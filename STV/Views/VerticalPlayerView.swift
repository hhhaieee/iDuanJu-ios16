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
            // 只在全屏播放页隐藏底部白色 Home 指示条（首页保持系统默认）。
            .persistentSystemOverlays(.hidden)
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
    /// 默认铺满：自适应模式下横屏视频四周露黑边，用户看到的是一条"一直不消失的黑色挡板"。
    /// 播放器菜单里仍可一键切回"完整自适应"。
    @AppStorage("stv.player.fill") private var fillScreen = true
    /// Technical info strip (⋯ → 技术信息).
    @AppStorage("stv.player.tech") private var showTech = true
    @ObservedObject private var sleepTimer = SleepTimerStore.shared
    @State private var sleepTask: Task<Void, Never>?
    @State private var osd: String?
    @State private var verifyTarget: VerifyTarget?
    @StateObject private var adjuster = PlayerAdjuster()
    @State private var loadError: Error?
    @State private var showChrome = true
    @State private var lastInteraction = Date()
    /// 切集前的控制栏可见状态：自动连播切集时若原本在沉浸观看（控制栏隐藏），切完保持隐藏，
    /// 不让菜单栏在新集弹出打扰观感；若原本可见则照常显示并走自动隐藏。
    @State private var chromeVisibleBeforeSwitch = true
    /// 本次切集是否由「沉浸观看（控制栏隐藏）」发起；加载期间用它屏蔽 readyIndex==nil 的强制显示，
    /// 否则连播切集时控制栏会在加载瞬间弹出。新集 ready 后清除。
    @State private var switchingFromHidden = false
    /// 切集/自动连播时抑制中心大播放按钮，直到新集 ready 后用户显式交互；避免切换瞬间按钮闪现。
    /// 仅控制「中心播放/暂停按钮」在新集加载期间是否显示（避免加载中闪现）。
    /// 不再参与控制栏显隐判断——单击/控制栏响应统一由 showChrome 驱动，避免状态残留导致点屏幕无反应。
    @State private var centerSuppressed = false
    /// 记录是否已完成首次加载，用于区分「首载」与「切集」（iOS 16 单参数 onChange 无 old 值）。
    @State private var didInitialLoad = false
    @State private var scrubbing = false
    @State private var locked = false
    @State private var altSources: [HGSeries] = []
    /// nil = not searched yet, false = searching, true = done.
    @State private var altSearched: Bool?
    @State private var noAutoHide = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var panel: PlayerPanel?
    @State private var speedMode = false
    @State private var previewRate: Double = 1.0
    @State private var pendingLock = false
    @State private var pendingCancel = false
    /// 竖屏视频点「全屏」时进入的沉浸全屏态（锁定竖屏 + 隐藏 chrome，不旋转成横屏）。
    @State private var portraitFullscreen = false
    /// Portrait feed content offset (pt): the shared video layer rides along with the page being swiped.
    @State private var feedScrollY: CGFloat = 0
    @State private var feedSettleWork: DispatchWorkItem?
    /// 初始布局/程序性 scrollTo 会触发 onPreferenceChange(y=0)，若此时 current 已被 load() 设为
    /// 用户点选的集，0.2s 后的 select(0) 会把它拉回第一集。等初始滚动落地后再开始响应手势。
    @State private var feedInitialized = false
    /// 横屏转竖屏时 portraitFeed 重新挂载、ScrollView 从 y=0 起步滚到 co.current 的过渡态。
    /// anchoring 期间完全禁用 settle，等 y 真正到达目标页再启用，避免把选集误拉回第一集。
    @State private var feedAnchoring = false
    /// Running double-tap seek (+10/+20/… s) and which side it is on; drives the side bubble.
    @State private var seekRun: (total: Int, at: Date)?
    /// 屏幕左右滑动调进度：t0 = 起始时间, cur = 当前预览时间, active 控制气泡显示。
    @State private var seekSlide: (t0: Double, cur: Double, active: Bool)? = nil
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

    /// Where the player layer lives — always the whole screen. `videoRect(_:)` handles fit/fill centring,
    /// so a landscape video letterboxes centred instead of hugging the top edge with a dead 156 pt block below.
    private func videoArea(_ full: CGSize) -> CGRect {
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
                        PiPPlaceholder(
                            title: co.detail?.title ?? series.title,
                            backdrop: co.pipBackdrop,
                            cover: series.cover,
                            onResume: { co.togglePiP() },
                            onExit: { co.exitPlayback(); dismiss() }
                        )
                        .frame(width: full.width, height: full.height)
                        .transition(.opacity)
                    } else if locked {
                        if controlsVisible { lockOnly(full, ins: ins).transition(.opacity) }
                    } else if controlsVisible {
                        if !centerSuppressed, co.current != nil, !scrubbing, panel == nil {
                            PlayerCenterControls(co: co, onInteract: flashChrome)
                                .position(x: landscape ? full.width / 2 : rect.midX, y: landscape ? full.height / 2 : rect.midY)
                                .transition(.opacity)
                        }
                        controls(full, ins: ins).transition(.opacity)
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
                    // 屏幕左右滑动调进度的中间提示：方向+秒数 / 当前·总时长 / 进度条（仿播放器 seek 气泡）。
                    if let s = seekSlide, s.active, co.duration > 0 {
                        let delta = s.cur - s.t0
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                                Text("\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded()))s")
                            }
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            Text("\(Fmt.clock(Int(s.cur))) / \(Fmt.clock(Int(co.duration)))")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.22))
                                    Capsule().fill(STVTheme.accent)
                                        .frame(width: g.size.width * CGFloat(min(1, max(0, s.cur / co.duration))))
                                }
                            }.frame(height: 3).frame(width: 150)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .position(x: full.width / 2, y: landscape ? full.height / 2 - 84 : rect.midY - 84)
                        .transition(.opacity).allowsHitTesting(false)
                        .accessibilityIdentifier("player.seekSlide")
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
                    // 长按 = 固定 2 倍速，不再弹出 2X 提示窗（用户要求）。
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
        .onAppear {
            startSleepCountdown()
            OrientationGate.unlock()
            // 全屏播放期间隐藏底部白色 Home 指示条（首页不受影响）。
            HomeIndicatorSuppress.set(true)
            // 竖屏边缘上下滑调音量 → 直接写播放器音量（MPVolumeView 在 iOS16 不生效）。
            adjuster.appVolumeGet = { Double(co.volume) }
            adjuster.appVolumeSet = { v in co.setVolume(Float(v)) }
            // 物理音量键：KVO 监听系统输出音量，变化时弹自定义 HUD（系统 HUD 被 HiddenVolumeView 抑制）。
            adjuster.startSystemVolumeObservation()
        }
        .onDisappear {
            sleepTask?.cancel()
            sleepTask = nil
            HomeIndicatorSuppress.set(false)
            adjuster.stopSystemVolumeObservation()
            adjuster.restoreBrightness()
            OrientationGate.lockPortrait()
            let coordinator = co
            // 1) 同步：先停掉引擎渲染，确保 surface 被移出视图层级前已停止向渲染层写帧（避免返回闪退）。
            coordinator.haltPlayback()
            // 2) 延后：清理观察者 / 改 @Published 状态，避免在视图销毁过程中触发重渲染。
            DispatchQueue.main.async { coordinator.teardown() }
        }
        .onChange(of: co.current) { new in
            scrubbing = false
            if didInitialLoad, new != nil {
                // 切集 / 自动连播：记住切集前控制栏状态，切完恢复到该状态。
                // 沉浸观看（控制栏本就隐藏）时连播切集不再弹出菜单栏打扰观感。
                chromeVisibleBeforeSwitch = showChrome
                switchingFromHidden = !showChrome
                centerSuppressed = true
                showChrome = chromeVisibleBeforeSwitch
                lastInteraction = Date()
            } else {
                // 首载：正常显示中心按钮。
                didInitialLoad = true
                flashChrome()
            }
        }
        .onChange(of: co.readyIndex) { index in
            guard index != nil else { return }
            if centerSuppressed {
                // 新集就绪：恢复到切集前的控制栏状态，不无条件显示。
                // 若切集前在沉浸观看，这里保持隐藏；否则显示并重置 auto-hide 计时。
                showChrome = chromeVisibleBeforeSwitch
                switchingFromHidden = false
                lastInteraction = Date()
            } else {
                flashChrome()
            }
        }
        .onChange(of: landscape) { l in
            if !l { locked = false }
            // 旋转时关闭其它面板，但保留弹幕设置面板：弹幕横竖屏各有对应布局（横屏右半边 / 竖屏底部半屏）。
            if panel != .danmaku { panel = nil }
            scrubbing = false
            // 横竖屏切换后强制恢复控制栏并清除中心按钮抑制：否则切屏瞬间 centerSuppressed
            // 可能残留为 true、showChrome 为 false，表现为「切到竖屏后点屏幕唤不醒控制栏」。
            flashChrome()
        }
        .onChange(of: co.pipActive) { active in
            // 退出画中画回到全屏（含系统原生 PiP 返回）时自动解开锁屏；
            // 不再强制恢复播放——暂停状态保留为用户在画中画里的选择（第2项回退）。
            if !active { locked = false; flashChrome() }
        }
        .onChange(of: co.downloadMessage) { msg in if let msg { showOSD(msg) } }
        .onChange(of: locked) { isLocked in
            if isLocked { OrientationGate.lockCurrent(landscape: landscape) }
            else { OrientationGate.unlockRotation() }
        }
        .sheet(item: $verifyTarget) { t in SiteVerifySheet(target: t) { if let c = co.current { co.activate(c) } } }
    }

    // MARK: Layers

    private func gradients(_ full: CGSize) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 120 : 150)
            Spacer(minLength: 0)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.65), location: 0.5),
                                   .init(color: .black.opacity(0.94), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 220 : 320)
        }
        .frame(width: full.width, height: full.height)
        .allowsHitTesting(false)
    }

    /// Danmaku is laid out on the SCREEN (not the letterboxed video): full width, lanes from just under the
    /// top bar, `DanmakuRegion` decides how many fit above the bottom controls. 14 pt fade at both sides.
    private func danmakuLayer(_ i: Int, full: CGSize, ins: EdgeInsets) -> some View {
        let r = DanmakuRegion.compute(screen: full, safeTop: ins.top, safeBottom: ins.bottom, landscape: landscape, showTech: showTech,
                                      area: danmaku.area.fraction, laneHeight: DanmakuOverlay.laneHeight(danmaku), maxRows: danmaku.size.rows)
        // 不用 .id() 按 settings 重建覆盖层：重建会把已加载的弹幕清空并重新走网络，
        // 弹幕开着时改设置反而「没反应」。overlay 内部是 @ObservedObject(DanmakuSettings)
        // + onChange(layoutKey) + Canvas 每帧实时读取，设置一变即在内存里重排重绘，即时生效；
        // 换集由 .task(id: vid) 负责，区域几何变化时 laneTop/laneSpacing 参数原地更新。
        return DanmakuOverlay(co: co, seriesId: series.seriesId, vid: co.episodes[i].vid, landscape: landscape,
                              laneTop: r.top, laneCount: r.rows, laneSpacing: r.laneSpacing)
            .frame(width: full.width, height: full.height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 14 / max(1, full.width)),
                                         .init(color: .black, location: 1 - 14 / max(1, full.width)), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                // Invisible marker so UI tests can check the lane region (top / rows / bottom limit).
                Color.clear.frame(width: full.width, height: max(1, CGFloat(r.rows - 1) * r.laneSpacing + DanmakuOverlay.laneHeight(danmaku)))
                    .offset(y: r.top - DanmakuOverlay.laneHeight(danmaku) / 2)
                    .accessibilityElement().accessibilityIdentifier("player.danmaku.region")
                    .accessibilityValue("top=\(Int(r.top)) rows=\(r.rows) spacing=\(Int(r.laneSpacing)) limit=\(Int(r.bottomLimit))")
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
            .scrollPosition(id: Binding(
                get: { co.current },
                // 单向：绝不把 ScrollView 的 id 写回 co。横竖屏切换 / 初始化时 ScrollView 从 y=0
                // 起步，双向绑定会把 id=0 写回 co.select(0) 导致跳回第一集重播。用户滑动切集由
                // 下方 compatScrollFeedback 的落页 settle 逻辑（相邻页 co.select）负责，不依赖此 set。
                set: { _ in }
            ))
            .compatScrollFeedback(onOffset: { feedScrollY = $0 }, onSettled: { feedSettled = $0; releaseHeldIfSettled() })
            .compatSelectionFeedback(trigger: co.current)
            .onChange(of: co.readyIndex) { _ in releaseHeldIfSettled() }
            .onChange(of: co.current) { new in
                lastShownCurrent = new
            }
            .scrollDisabled(locked || speedMode || scrubbing || co.pipActive || panel != nil || co.readyIndex != co.current)
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
                        let rawY = -minY
                        let pageHeight = geo.size.height
                        guard pageHeight > 0 else { return }
                        // 边界锁：上滑只进下一集、下滑只进上一集；第一集不能再下滑、最后一集不能再
                        // 上滑（没有上/下集就滑不动，不露出封面占位或黑边）。越界即拉回边界页。
                        let maxY = CGFloat(max(0, co.episodes.count - 1)) * pageHeight
                        let y = min(max(rawY, 0), maxY)
                        if y != rawY {
                            feedScrollY = y
                            proxy.scrollTo(y == 0 ? 0 : co.episodes.count - 1, anchor: .top)
                            return
                        }
                        // 程序性 scrollTo 未落地时，实际滚动位置 y 与当前集相差会超过 1 页（横竖屏切换、
                        // 选集面板跨页跳转时，ScrollView 从旧位置起步还没滚到目标页）。此时视频层锁死在
                        // 当前集，不跟随 y——否则会被 y 拉走，出现「画面跳到第一集 / 整屏错位」。用户上下滑
                        // 换集一次只跨 1 页，跟手效果不受影响。
                        let curPage = CGFloat(co.current ?? 0) * pageHeight
                        if abs(y - curPage) > pageHeight * 1.5 {
                            feedScrollY = curPage
                        } else {
                            feedScrollY = y
                        }
                        // 初始定位：等 ScrollView 滚到 co.current 对应页后（y 与目标页偏移 < 2pt）
                        // 才启用 settle。iOS 16 的远距离 scrollTo 对 LazyVStack 可能延迟，若在 y 仍停在
                        // 第 1 集时就 settle，会把选集误拉回第一集。
                        if feedAnchoring {
                            if abs(y - curPage) < 2 {
                                feedAnchoring = false
                                feedInitialized = true
                            }
                            return
                        }
                        guard feedInitialized else { return }
                        feedSettleWork?.cancel()
                        let work = DispatchWorkItem {
                            let pageHeight = geo.size.height
                            guard pageHeight > 0 else { return }
                            let idx = min(max(Int(round(y / pageHeight)), 0), max(0, co.episodes.count - 1))
                            let cur = co.current ?? 0
                            if idx != cur {
                                // 只有相邻页的用户滑动才换集；跨页跳变来自程序性 scrollTo 未落地
                                // （横竖屏切换 / 初始化 / 选集面板），一律吸附回当前集，绝不 select——
                                // 否则会把选集误拉回第一集（co.select(0)），连播也随之失效。
                                if abs(idx - cur) == 1 {
                                    co.select(idx)
                                    withAnimation { proxy.scrollTo(idx, anchor: .top) }
                                } else {
                                    withAnimation { proxy.scrollTo(cur, anchor: .top) }
                                }
                            } else {
                                // 停在半页（没过半回弹）也吸附回整页，避免视频层与页面错位。
                                withAnimation { proxy.scrollTo(idx, anchor: .top) }
                            }
                            // 兜底：iOS 16 的 scrollTo 有时落不了地，feedScrollY 停在上次位置会把
                            // 视频层整屏推出可视区（有声音、画面全黑）。滚动停止后强制对齐到目标页。
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if co.current == idx { feedScrollY = CGFloat(idx) * pageHeight }
                            }
                        }
                        feedSettleWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                    }
                    .onAppear {
                        // 横屏切回竖屏时 portraitFeed 重新挂载，ScrollView 从 y=0 起步需滚到 co.current。
                        // iOS 16 的远距离 scrollTo 对 LazyVStack 可能延迟/失效，若在落地前就启用 settle，
                        // 会把 co.current 误判成第 1 集拉回。这里进入 anchoring：settle 先禁用，
                        // 等 y 真正到达 co.current 对应位置后再启用（见 onPreferenceChange 的检测）。
                        feedAnchoring = true
                        feedInitialized = false
                        let target = co.current ?? 0
                        // 画面层立即对齐到目标页，避免 scrollTo 未落地时视频层整屏偏出（黑屏/错位）。
                        feedScrollY = CGFloat(target) * geo.size.height
                        proxy.scrollTo(target, anchor: .top)
                        // 兜底：极端情况下 scrollTo 迟迟不落地，0.6 秒后强制结束 anchoring 并补一次滚动，
                        // 避免一直锁死导致用户无法上下滑换集（横屏切竖屏后切集失效的主因）。
                        // 用最新 co.current（可能已随 load 变化）。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            guard feedAnchoring else { return }
                            feedAnchoring = false
                            feedInitialized = true
                            let t = co.current ?? 0
                            feedScrollY = CGFloat(t) * geo.size.height
                            proxy.scrollTo(t, anchor: .top)
                        }
                    }
                    .onChange(of: co.current) { new in
                        if let new { withAnimation { proxy.scrollTo(new, anchor: .top) } }
                        lastShownCurrent = new
                        releaseHeldIfSettled()
                        // 兜底：换集后把画面层对齐到目标页。iOS 16 上 scrollTo 可能不生效，
                        // feedScrollY 停留在旧集会让视频层整屏偏出（有声音、画面全黑）。
                        if let new, co.episodes.indices.contains(new) {
                            let ph = geo.size.height
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if co.current == new, ph > 0 { feedScrollY = CGFloat(new) * ph }
                            }
                        }
                        // 初始定位的 scrollTo 落地后再开始响应手势滚动，避免初始 y=0 把选集拉回第一集。
                        // 若仍在 anchoring（等 y 到达目标页），不在这里强行启用，交给到达检测 / 2s 兜底。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !feedAnchoring { feedInitialized = true } }
                    }
                    .scrollDisabled(locked || speedMode || scrubbing || co.pipActive || panel != nil || co.readyIndex != co.current)
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
        let raw = feedScrollY - CGFloat(index) * page
        // iOS 16 的 ScrollView 在 scrollTo 没能真正落地时，feedScrollY 会停在上一次的位置，
        // raw 变成整页 / 跨页的错位值 → 视频层被整屏推出可视区，表现就是「有声音、画面全黑」。
        // 横屏不走 pageDrift（guard !landscape），所以横屏画面正常。这类失效偏移一律归零。
        if abs(raw) > page + 4 { return 0 }
        if abs(raw - (raw / page).rounded() * page) < 1.5 { return 0 }   // 页边界（含静止）本就应归位
        return max(-page, min(page, raw))
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
                    },
                    onVerticalSwipe: handleVerticalSwipe,
                    onSwipeToPage: handleSwipeToPage,
                    onSeekSlideBegan: seekSlideBegan,
                    onSeekSlideChanged: seekSlideChanged,
                    onSeekSlideEnded: seekSlideEnded,
                    pagingEnabled: co.readyIndex == co.current
                )
            } else {
                // 非就绪页：只在「首次加载当前集」（尚无任何就绪页）时显示封面预览；
                // 换集过渡、以及竖屏分页拖动中相邻页滚进可视区，一律透明，绝不闪封面。
                let firstLoad = co.readyIndex == nil && co.prevIndex == nil && i == co.current
                if firstLoad && co.errors[i] == nil {
                    PosterBackdrop(url: series.cover)
                } else {
                    Color.clear
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
        // readyIndex==nil 通常在加载时显示控制栏；但沉浸观看中连播切集时保持隐藏，
        // 避免新集加载瞬间菜单栏弹出（由 switchingFromHidden 屏蔽）。
        let loadingShow = co.readyIndex == nil && !switchingFromHidden
        return !speedMode && (showChrome || loadingShow || scrubbing || panel != nil || voiceOver)
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
            Toggle(isOn: Binding(get: { sleepTimer.isOn }, set: { setSleep($0) })) {
                Label(sleepTimer.isOn ? "定时开关（\(SleepTimerSettings.minutes) 分）" : "定时开关", systemImage: "timer")
            }
            if series.source == .hongguo {
                Button { toggle(.danmaku) } label: { Label("弹幕设置", systemImage: "slider.horizontal.3") }
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

    /// 睡眠定时：开启后到点暂停视频（暂停后 iOS 可正常自动熄屏）。
    /// 开关状态由 SleepTimerStore 全局保持，换剧 / 换资源不自动关闭（除非手动关闭或重启 App）。
    private func startSleepCountdown() {
        sleepTask?.cancel()
        sleepTask = nil
        guard sleepTimer.isOn else { return }
        let minutes = SleepTimerSettings.minutes
        let coord = co
        sleepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            coord.pause()
            sleepTimer.isOn = false
            sleepTask = nil
            showOSD("定时结束，已暂停")
        }
    }

    private func setSleep(_ on: Bool) {
        if on {
            sleepTimer.isOn = true
            startSleepCountdown()
            showOSD("已开启定时（\(SleepTimerSettings.minutes) 分）")
        } else {
            sleepTimer.isOn = false
            sleepTask?.cancel()
            sleepTask = nil
            showOSD("已关闭定时")
        }
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
                // 始终显示当前倍速文字（如 1×/1.5×），让入口一眼可见；非 1× 时高亮。
                Text(SpeedPopover.short(co.playbackRate))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(co.playbackRate == 1 ? Color.white : STVTheme.accent)
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
                if portraitFullscreen {
                    slot { PlayerRowIcon(id: "player.fullscreen", a11y: "退出全屏", action: { exitFullscreen() }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 18))
                    } }
                } else {
                    slot { PlayerRowIcon(id: "player.fullscreen", a11y: "全屏", action: { enterSmartFullscreen() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18))
                    } }
                }
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
        let isDanmaku = p == .danmaku
        let width: CGFloat = {
            switch p {
            case .episodes: return landscape ? 380 : full.width - 24
            case .rates: return landscape ? 230 : 220
            case .danmaku: return landscape ? full.width / 2 : full.width - 24
            default: return 270
            }
        }()
        // 横屏弹幕：底部给进度条/控制栏留空间，卡片绝不碰到进度条；内容已压紧可一屏放下。
        let danmakuLandscapeBottom: CGFloat = 56 + max(0, ins.bottom)
        let maxH: CGFloat = isDanmaku
            ? (landscape ? full.height - 12 - danmakuLandscapeBottom : full.height * 0.5)
            : (landscape ? (p == .episodes ? 270 : full.height - 44 - 110)
                         : min(p == .episodes ? 372 : 420, full.height * 0.5))
        let body = popoverContent(p)
            .frame(width: width)
            .frame(maxHeight: maxH, alignment: .top)
            .fixedSize(horizontal: false, vertical: !(p == .episodes || isDanmaku))
            .playerGlass(20, strong: true)
            // 横屏弹幕内容可滚动，整卡下拉手势会和滚动冲突，改由标题栏 X 关闭；其它面板保留下拉关闭。
            .gesture(landscape && isDanmaku ? nil :
                DragGesture(minimumDistance: 24).onEnded { v in if v.translation.height > 60 { closePanel() } })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.popover.\(p.rawValue)")
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: landscape ? .topTrailing : .bottomLeading)))
        if isDanmaku && landscape {
            // 横屏弹幕：占右半边（横向一半）、从顶部展开，底部留出进度条区，卡片不碰进度条。
            VStack(spacing: 0) {
                HStack(spacing: 0) { Spacer(minLength: 0); body }
                Spacer(minLength: 0)
            }
            .padding(.top, 8).padding(.trailing, 12)
            .padding(.bottom, danmakuLandscapeBottom)
            .frame(width: full.width, height: full.height)
        } else if !landscape {
            // 竖屏弹幕及其它面板：底部弹出（弹幕全宽半屏）。
            VStack { Spacer(); HStack { body; Spacer(minLength: 0) } }
                .padding(.horizontal, 12).padding(.bottom, max(0, ins.bottom - 6) + 44 + 12)
                .frame(width: full.width, height: full.height)
        } else {
            // 横屏其它面板：右上角。
            VStack { HStack { Spacer(); body }; Spacer() }
                .padding(.top, p == .episodes ? 14 : 44).padding(.trailing, 48)
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
            VStack(alignment: .leading, spacing: 0) {
                TrackPopover(title: "音轨", options: co.audioOptions, selected: co.audioSelected, allowsOff: false,
                             emptyText: "当前视频只有一条音轨") { o in if let o { co.selectAudio(o) }; closePanel() }
            }
        case .subtitles:
            VStack(alignment: .leading, spacing: 0) {
                TrackPopover(title: "字幕", options: co.subtitleOptions, selected: co.subtitleSelected, allowsOff: true,
                             emptyText: "当前视频没有可选字幕") { o in co.selectSubtitle(o); closePanel() }
                Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 12).padding(.vertical, 4)
                // 黄果等 HLS 源下载后无法播放：与弹幕"当前片源不支持弹幕"一致，直接标注不支持，不给出错入口。
                let downloadSupported = series.source != .huangguo
                Button {
                    guard downloadSupported else { showOSD("当前片源不支持下载"); return }
                    co.downloadCurrentEpisode()
                    closePanel()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: co.isDownloading ? "arrow.down.circle.dotted" : "arrow.down.circle")
                            .font(.system(size: 16)).foregroundStyle(downloadSupported ? STVTheme.accent : STVTheme.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(co.isDownloading ? "正在下载本集…" : (downloadSupported ? "下载本集" : "当前片源不支持下载"))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(downloadSupported ? .white : STVTheme.secondary)
                            Text(downloadSupported ? "下载后可离线观看，也能存到手机相册" : "黄果短剧暂不支持离线下载")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(co.isDownloading)
                .accessibilityLabel(downloadSupported ? "下载本集" : "当前片源不支持下载").accessibilityIdentifier("player.download")
            }
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
            DanmakuSettingsSheet(available: series.source == .hongguo) { closePanel() }
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
        // 单击的显隐只由 showChrome 决定，不再掺入 centerSuppressed：
        // 后者只负责「中心播放按钮在新集加载期间是否显示」，不该干扰整条控制栏的触摸响应，
        // 否则切集后 centerSuppressed 残留 true 时点击会永远走 else 再 flash，表现为「点了没反应」。
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

    // MARK: 屏幕左右滑动调进度（水平 pan，中间区域）

    /// dx 为水平位移占屏宽比例。手感：滑满半屏 ≈ 前进/后退 60 秒（可随视频时长自适应）。
    private func seekSlideBegan() {
        guard co.duration > 0, !locked, panel == nil, !speedMode else { return }
        let t0 = co.time
        withAnimation(.easeOut(duration: 0.12)) { seekSlide = (t0, t0, true) }
        scrubbing = true
    }

    private func seekSlideChanged(_ dxFraction: Double) {
        guard var s = seekSlide, s.active, co.duration > 0 else { return }
        // 半屏 = min(duration, 90s) 的进度跨度；超出时长自动夹紧，短片也能滑完。
        let window = min(co.duration, 90)
        let target = min(max(0, s.t0 + dxFraction * 2 * window), co.duration)
        s.cur = target
        seekSlide = s
        co.scrubPreview = target
    }

    private func seekSlideEnded() {
        guard let s = seekSlide, s.active else { return }
        if co.duration > 0 { co.seek(fraction: s.cur / co.duration) }
        co.scrubPreview = nil
        withAnimation(.easeIn(duration: 0.2)) { seekSlide = nil }
        scrubbing = false
    }

    private func showOSD(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { osd = text }
        flashChrome()
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if osd == text { withAnimation(.easeIn(duration: 0.25)) { osd = nil } }
        }
    }

    /// 竖屏手势接管分页落页：切到目标集并同步视频层位置。
    private func handleSwipeToPage(_ idx: Int) {
        guard !locked, panel == nil, !scrubbing, !speedMode else { return }
        guard co.episodes.indices.contains(idx) else { return }
        feedSettleWork?.cancel()
        if idx != co.current {
            co.select(idx)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            lastShownCurrent = idx
        }
    }

    /// 全屏（横屏）垂直轻扫换集：上滑下一集、下滑上一集；没有相邻集时提示并保持不动。
    private func handleVerticalSwipe(_ up: Bool) {
        guard !locked, panel == nil, !scrubbing, !speedMode else { return }
        let cur = co.current ?? 0
        let target = up ? cur + 1 : cur - 1
        guard co.episodes.indices.contains(target) else {
            showOSD(up ? "已经是最后一集" : "已经是第一集")
            return
        }
        co.select(target)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Speed gesture
    // Priority: edge-back (nav) > vertical page swipe > long-press speed > tap.
    // Implemented in PlayerTouchCatcher (UIKit) so ScrollView paging / interactive pop are not stolen.
    // Speed drag only runs after long-press succeeds; scrollDisabled(speedMode) then locks paging.

    private let edgeBackWidth: CGFloat = 36

    private func enterSpeedMode() {
        // 长按 = 固定 2 倍速（不再拖拽调速），松开恢复原倍速/1x。
        previewRate = 2.0
        pendingLock = false
        pendingCancel = false
        speedMode = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if co.paused { co.togglePause() }
        co.applyRate(previewRate)
    }

    private func handleSpeedTranslation(_ translation: CGSize) {
        // 长按固定 2x，拖拽不再改变倍速。
    }

    private func endSpeedMode() {
        defer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                speedMode = false
                pendingLock = false
                pendingCancel = false
            }
        }
        co.restoreLockedOrNormal()
    }

    private func flashChrome() {
        centerSuppressed = false
        switchingFromHidden = false
        showChrome = true
        lastInteraction = Date()
    }

    // MARK: Smart fullscreen
    // 点「全屏」时按视频宽高比自动决定方向：横屏视频旋转横屏，竖屏视频保持竖屏进入沉浸全屏。

    private func enterSmartFullscreen() {
        if aspect > 1.0 {
            OrientationGate.enterLandscape()
            flashChrome()
        } else {
            OrientationGate.lockPortrait()
            portraitFullscreen = true
            withAnimation(.easeOut(duration: 0.2)) { showChrome = false }
        }
    }

    private func exitFullscreen() {
        portraitFullscreen = false
        OrientationGate.unlock()
        flashChrome()
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

/// 应用内画中画占位页：以切换瞬间的画面截图为底，显示剧名与「恢复应用内播放 / 退出播放」。
struct PiPPlaceholder: View {
    let title: String
    let backdrop: UIImage?
    let cover: String
    let onResume: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                PosterBackdrop(url: cover)
            }
            Color.black.opacity(0.42).allowsHitTesting(false)

            VStack(spacing: 12) {
                Image(systemName: "pip")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(STVTheme.accent)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text("正在画中画窗口中")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 4)
                Button(action: onResume) {
                    Label("恢复应用内播放", systemImage: "pip.exit")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(STVTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("player.pipResume")
                Button(action: onExit) {
                    Label("退出播放", systemImage: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("player.pipExit")
            }
            .padding(22)
            .frame(maxWidth: 330)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 36)
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
    /// 全屏（横屏）垂直轻扫：true = 上滑（下一集），false = 下滑（上一集）。
    var onVerticalSwipe: (Bool) -> Void = { _ in }
    /// 竖屏手势接管分页：落到哪一集（绝对页码）。
    var onSwipeToPage: (Int) -> Void = { _ in }
    /// 屏幕左右滑动调进度（水平 pan，中间区域）。dx 为位移/屏宽比例。
    var onSeekSlideBegan: () -> Void = {}
    var onSeekSlideChanged: (Double) -> Void = { _ in }
    var onSeekSlideEnded: () -> Void = {}
    /// 当前集已就绪时才允许上下滑换集（加载中锁死，避免拖动拉出封面）。
    var pagingEnabled: Bool = true

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
        c.locked = locked
        c.onAdjustBegan = onAdjustBegan
        c.onAdjustChanged = onAdjustChanged
        c.onAdjustEnded = onAdjustEnded
        c.onPinchFill = onPinchFill
        c.onVerticalSwipe = onVerticalSwipe
        c.onSwipeToPage = onSwipeToPage
        c.onSeekSlideBegan = onSeekSlideBegan
        c.onSeekSlideChanged = onSeekSlideChanged
        c.onSeekSlideEnded = onSeekSlideEnded
        c.pagingEnabled = pagingEnabled
        c.pinch.isEnabled = !locked && !speedMode
        // While speed HUD is up, keep catcher receiving the finger; chrome is hit-disabled.
        uiView.isUserInteractionEnabled = true
        c.longPress.isEnabled = !locked
        c.adjustPan.isEnabled = !locked
        /// 全屏（横屏）垂直轻扫 = 上下集；竖屏由手势接管分页（跟手 + 到位翻页）。
        /// 当前集未就绪（加载中）时锁死，避免拖动拉出封面。
        c.epPan.isEnabled = !locked && !speedMode && pagingEnabled
        c.seekPan.isEnabled = !locked && !speedMode
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
        var locked = false
        var onAdjustBegan: (AdjustSide) -> Void = { _ in }
        var onAdjustChanged: (AdjustSide, Double) -> Void = { _, _ in }
        var onAdjustEnded: () -> Void = {}
        var onPinchFill: (Bool) -> Void = { _ in }
        var onVerticalSwipe: (Bool) -> Void = { _ in }
        /// 竖屏手势接管分页：落到哪一集（绝对页码）。
        var onSwipeToPage: (Int) -> Void = { _ in }
        /// 屏幕左右滑动调进度（水平 pan，中间区域）。
        var onSeekSlideBegan: () -> Void = {}
        var onSeekSlideChanged: (Double) -> Void = { _ in }
        var onSeekSlideEnded: () -> Void = {}
        /// 当前集是否已就绪（就绪才允许上下滑换集）。
        var pagingEnabled = true
        private weak var feedScroll: UIScrollView?
        private var feedBase: CGFloat = 0
        private var feedHeight: CGFloat = 0
        let pinch = UIPinchGestureRecognizer()
        /// 全屏（横屏）垂直轻扫 → 上一集 / 下一集。
        let epPan = UIPanGestureRecognizer()
        /// 屏幕左右滑动调进度（水平，中间区域，与垂直的切集/亮度音量手势互斥）。
        let seekPan = UIPanGestureRecognizer()
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
            epPan.addTarget(self, action: #selector(handleEpisodeSwipe))
            epPan.delegate = self
            epPan.maximumNumberOfTouches = 1
            epPan.cancelsTouchesInView = false
            seekPan.addTarget(self, action: #selector(handleSeekSlide))
            seekPan.delegate = self
            seekPan.maximumNumberOfTouches = 1
            seekPan.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(longPress)
            view.addGestureRecognizer(adjustPan)
            view.addGestureRecognizer(epPan)
            view.addGestureRecognizer(seekPan)
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

        /// Single tap now; second tap within 0.4 s near the first = double tap; side streak keeps seeking.
        /// 放宽判定窗口（0.3s→0.4s、x 差 0.2→0.28）：手指稍慢或略抖也不至于被拆成两次单击。
        private func tapped(at p: CGPoint, in view: UIView) {
            let x = p.x / max(1, view.bounds.width), now = Date()
            let side: Bool? = x < 1.0 / 3 ? false : (x > 2.0 / 3 ? true : nil)
            guard doubleTapEnabled else { onTap(); return }
            if let s = streak, now < s.until, side == s.right {
                streak = (now.addingTimeInterval(0.7), s.right)
                onDoubleTap(x); return
            }
            streak = nil
            if let l = lastTap, now.timeIntervalSince(l.at) < 0.4, abs(l.x - x) < 0.28 {
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

        /// 屏幕左右滑动调进度（水平 pan）。dx 为位移占屏宽比例。
        @objc private func handleSeekSlide(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            switch g.state {
            case .began:
                onSeekSlideBegan()
            case .changed:
                onSeekSlideChanged(Double(g.translation(in: view).x / max(1, view.bounds.width)))
            case .ended, .cancelled, .failed:
                onSeekSlideEnded()
            default: break
            }
        }

        static func side(_ g: UIGestureRecognizer, in view: CatcherView, landscape: Bool) -> AdjustSide? {
            PlayerAdjuster.zone(x: g.location(in: view).x, width: view.bounds.width, landscape: landscape, edge: view.edgeBackWidth)
        }

    /// 全屏（横屏）垂直轻扫 → 上滑下一集 / 下滑上一集（到位即切，不做拖拽预览）。
    /// 竖屏：手势直接接管 iOS 16 的分页（SwiftUI ScrollView 没有原生 paging）——
    /// 跟手拖动 ScrollView，松手按位移/速度翻页；第一集下滑 / 最后一集上滑原位回弹。
    @objc private func handleEpisodeSwipe(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            feedScroll = Self.findScrollView(from: view)
            if !landscape {
                feedBase = feedScroll?.contentOffset.y ?? 0
                feedHeight = feedScroll?.bounds.height ?? 0
                feedScroll?.panGestureRecognizer.isEnabled = false   // 跟手期间由我们独占滚动
            }
        case .changed where !landscape:
            guard let sv = feedScroll, feedHeight > 0 else { return }
            let maxY = max(0, sv.contentSize.height - feedHeight)
            sv.contentOffset.y = min(max(0, feedBase - g.translation(in: view).y), maxY)
        case .ended, .cancelled, .failed:
            if landscape {
                let t = g.translation(in: view)
                let vertical = abs(t.y) > 55 && abs(t.y) > abs(t.x) * 1.6
                guard vertical else { return }
                onVerticalSwipe(t.y < 0)
            } else {
                defer { feedScroll = nil }
                guard let sv = feedScroll, feedHeight > 0, sv.contentSize.height >= feedHeight else {
                    // guard 的 else 里拿不到已绑定的 sv，回退用属性本身恢复滚动。
                    feedScroll?.panGestureRecognizer.isEnabled = true
                    return
                }
                let t = g.translation(in: view)
                let v = g.velocity(in: view)
                let page = feedHeight
                let pageCount = max(0, Int(round(sv.contentSize.height / page)) - 1)
                let current = Int(min(max(0, feedBase / page), CGFloat(pageCount)))
                let flick = abs(v.y) > 500
                let drag = abs(t.y) > page * 0.25
                let forward = t.y < 0   // 上滑 = 下一集
                var target = current
                if flick || drag {
                    target = forward ? current + 1 : current - 1
                }
                let clamped = min(max(0, target), pageCount)
                sv.panGestureRecognizer.isEnabled = true
                if clamped == current {
                    // 没有相邻集或拖动不足：原位回弹；撞到边界给提示。
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: CGFloat(current) * page), animated: true)
                    if flick || drag {
                        if forward, current >= pageCount { onVerticalSwipe(true) }      // 已是最后一集
                        if !forward, current <= 0 { onVerticalSwipe(false) }            // 已是第一集
                    }
                } else {
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: CGFloat(clamped) * page), animated: true)
                    onSwipeToPage(clamped)
                }
            }
        default:
            break
        }
    }

    /// 向上遍历宿主视图找到 SwiftUI ScrollView 的 UIScrollView。
    static func findScrollView(from view: UIView) -> UIScrollView? {
        var cur: UIView? = view
        while let v = cur {
            if let sv = v as? UIScrollView { return sv }
            cur = v.superview
        }
        return nil
    }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // adjust pan / seek pan own their touch exclusively (no paging/speed at the same time);
            // tap + long-press always coexist with UIScrollView pan + interactive pop.
            if gestureRecognizer === adjustPan || otherGestureRecognizer === adjustPan ||
               gestureRecognizer === seekPan || otherGestureRecognizer === seekPan { return false }
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

        /// 手势主轴判定：优先用累计位移 translation（手指起落全过程稳定），
        /// 仅当位移还很小时（< 6pt，刚开始）才退回瞬时 velocity，避免起手抖动抢错手势。
        private func axis(_ pan: UIPanGestureRecognizer, in view: UIView) -> (h: CGFloat, v: CGFloat) {
            let t = pan.translation(in: view)
            var ax = abs(t.x), ay = abs(t.y)
            if max(ax, ay) < 6 {
                let vel = pan.velocity(in: view)
                ax = abs(vel.x); ay = abs(vel.y)
            }
            return (ax, ay)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view else { return true }
            let x = gestureRecognizer.location(in: view).x
            // Left strip reserved for interactive pop — never claim it.
            if x < view.edgeBackWidth { return false }
            if gestureRecognizer === adjustPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                guard !speedMode, Coordinator.side(pan, in: view, landscape: landscape) != nil else { return false }
                let a = axis(pan, in: view)
                return a.v > a.h * 1.15
            }
            if gestureRecognizer === epPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                // 切集只在中间区域生效：两侧边缘让给亮度/音量，避免竖屏切集与侧滑抢手势。
                guard !speedMode, Coordinator.side(pan, in: view, landscape: landscape) == nil else { return false }
                // 垂直为主才切集，水平交给 seekPan。
                let a = axis(pan, in: view)
                return a.v >= a.h
            }
            if gestureRecognizer === seekPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                // 进度手势只在中间区域、水平为主时接管；锁屏 / 倍速模式下禁用。
                guard !speedMode, !locked, Coordinator.side(pan, in: view, landscape: landscape) == nil else { return false }
                let a = axis(pan, in: view)
                return a.h > a.v * 1.15
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

