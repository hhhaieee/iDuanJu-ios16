import SwiftUI

/// 四个根页面 + PlutoFish 式底部悬浮玻璃胶囊导航（系统 TabBar 隐藏）。
/// 胶囊只在根页面显示；进入详情 / 播放器等二级页面时隐藏。
struct RootTabView: View {
    @State private var tab = Int(ProcessInfo.processInfo.environment["STV_TAB"] ?? "") ?? 0
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath()]
    static let items: [(String, String)] = [("首页", "play.house.fill"), ("搜索", "magnifyingglass"),
                                            ("找剧", "square.grid.2x2.fill"), ("我的", "person.crop.circle.fill")]
    var body: some View {
        // 不用系统 TabView：iOS 16 上 `.toolbar(.hidden, for: .tabBar)` 有时序 bug，
        // 切 tab 时系统 TabBar 会短暂"重建"露出浅色背景——即底部那根闪一下的挡板。
        // 这里改用 ZStack 自绘切换：四个 NavigationStack 常驻（opacity/zIndex 控制显示），
        // 从根上杜绝 UITabBar 的参与，彻底消除挡板闪现。
        ZStack {
            Stack(path: $paths[0]) { HomeView() }
                .opacity(tab == 0 ? 1 : 0).zIndex(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0)
            Stack(path: $paths[1]) { SearchView() }
                .opacity(tab == 1 ? 1 : 0).zIndex(tab == 1 ? 1 : 0).allowsHitTesting(tab == 1)
            Stack(path: $paths[2]) { CategoryView() }
                .opacity(tab == 2 ? 1 : 0).zIndex(tab == 2 ? 1 : 0).allowsHitTesting(tab == 2)
            Stack(path: $paths[3]) { ProfileView() }
                .opacity(tab == 3 ? 1 : 0).zIndex(tab == 3 ? 1 : 0).allowsHitTesting(tab == 3)
        }
        .tint(STVTheme.accent)
        .overlay(alignment: .bottom) {
            if paths[tab].isEmpty {
                GlassTabBar(selection: $tab, items: Self.items) { i in
                    if i == tab { paths[i] = NavigationPath() }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: paths[tab].isEmpty)
        .onAppear {
            bindRouter()
            #if DEBUG
            if ProcessInfo.processInfo.environment["STV_TD_OPEN"] == "1" { Router.push(.tdlib) }
            #endif
        }
        .onChange(of: tab) { _ in bindRouter() }
        // Cold start: restore a saved TDLib login (no network login, nothing is sent).
        .task { await TDLibService.shared.bootstrap() }
    }

    /// 全局路由始终追加到「当前 tab」的导航栈（切 tab 后重新绑定，避免 push 到旧栈）。
    private func bindRouter() {
        let currentTab = tab
        Router.handler = { r in paths[currentTab].append(r) }
    }
}

private struct Stack<V: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder var content: V
    @Namespace private var ns
    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: GlassTabBar.clearance) }
                .routes()
        }.environment(\.zoomNS, ns)
    }
}

struct GlassTabBar: View {
    static let clearance: CGFloat = 72
    @Binding var selection: Int
    let items: [(String, String)]
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == selection
                Button {
                    if on { onReselect(i) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = i } }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: items[i].1).font(.system(size: 18, weight: on ? .semibold : .regular))
                        Text(items[i].0).font(.system(size: 11, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background {
                        if on { Capsule().fill(STVTheme.text.opacity(0.1)).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[i].0)
                .accessibilityIdentifier("tab.\(i)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(maxWidth: 400)
        .background(.ultraThinMaterial, in: Capsule())
        .background(STVTheme.surface.opacity(0.55), in: Capsule())
        .overlay {
            Capsule().strokeBorder(LinearGradient(colors: [STVTheme.text.opacity(0.18), STVTheme.text.opacity(0.05)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

/// UIKit 层全局兜底：找到任何 UITabBar 实例就强制隐藏并禁止交互。
/// App 的底部导航是自定义玻璃胶囊（GlassTabBar），系统 TabBar 永远不该出现。
/// `.toolbar(.hidden, for: .tabBar)` 在 iOS 16 上有时序 bug——push 二级页面时 TabBar 占位
/// 偶发残留：详情页底部出现一条空白、点上去正好落在透明 TabBar 的按钮上触发切 tab，
/// 播放器画面也会被这条占位挤得底部留黑条（横竖屏随机出现）。这里定时扫描整棵视图树，
/// 任何冒出来的 TabBar 一律 isHidden + isUserInteractionEnabled=false。
struct TabBarHider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { HiderView() }
    func updateUIView(_ uiView: UIView, context: Context) { HiderView.hideTabBars(from: uiView) }

    final class HiderView: UIView {
        private var timer: Timer?
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            // 立即扫一次；iOS 16 的系统 TabBar 占位常在首帧之后才冒出来（顶部遮挡板/底部白条），
            // 所以在启动后的关键时间点密集补扫，避免"过一会才消失"。
            Self.hideTabBars(from: self)
            for delay in [0.05, 0.15, 0.4, 0.8, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    Self.hideTabBars(from: self)
                }
            }
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                Self.hideTabBars(from: self)
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { timer?.invalidate() }

        static func hideTabBars(from start: UIView) {
            var root: UIView = start
            while let p = root.superview { root = p }   // 顶到 UIWindow
            var queue: [UIView] = [root]
            while let cur = queue.popLast() {
                if let bar = cur as? UITabBar, !bar.isHidden || bar.isUserInteractionEnabled {
                    bar.isHidden = true
                    bar.isUserInteractionEnabled = false
                }
                queue.append(contentsOf: cur.subviews)
            }
        }
    }
}
