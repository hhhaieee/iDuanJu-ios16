import SwiftUI
import AVFoundation

/// Persisted danmaku preferences (hongguo-open-player style: enabled / size / speed / opacity / area).
@MainActor
final class DanmakuSettings: ObservableObject {
    static let shared = DanmakuSettings()
    enum Speed: String, CaseIterable, Identifiable {
        case slow, medium, fast
        var id: String { rawValue }
        var label: String { switch self { case .slow: "慢"; case .medium: "中"; case .fast: "快" } }
        /// Seconds to cross the screen.
        var duration: Double { switch self { case .slow: 11; case .medium: 8.5; case .fast: 6.5 } }
    }
    /// 四档字号（0.8× / 1.0× / 1.25× / 1.5×，基准 16pt）。行数随字号自动决定，不再单独设置。
    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var label: String { switch self { case .small: "小 0.8×"; case .medium: "标准 1.0×"; case .large: "大 1.25×"; case .xlarge: "特大 1.5×" } }
        var points: CGFloat { switch self { case .small: 13; case .medium: 16; case .large: 20; case .xlarge: 24 } }
        /// 行数跟随字号：小 4 行、标准 3 行、大 2 行、特大 2 行。
        var rows: Int { switch self { case .small: 4; case .medium: 3; case .large: 2; case .xlarge: 2 } }
    }

    /// How much of the screen (below the top bar) danmaku lanes may use.
    enum Area: String, CaseIterable, Identifiable {
        case quarter, third, half, most
        var id: String { rawValue }
        var label: String { switch self { case .quarter: "1/4屏"; case .third: "1/3屏"; case .half: "半屏"; case .most: "3/4屏" } }
        var fraction: CGFloat { switch self { case .quarter: 0.25; case .third: 0.34; case .half: 0.5; case .most: 0.75 } }
    }

    @Published var enabled: Bool { didSet { save() } }
    @Published var area: Area { didSet { save() } }
    @Published var opacity: Double { didSet { save() } }
    @Published var speed: Speed { didSet { save() } }
    @Published var size: Size { didSet { save() } }
    /// Live status of the current episode (not persisted).
    @Published var status = ""
    /// 设置面板打开信号（不持久化）：面板期间冻结播放器弹幕的逐帧重绘，
    /// 把主线程让给面板的触摸响应——否则 60fps Canvas + 视频解码会挤掉面板点击，表现为「按钮时灵时不灵」。
    @Published var panelOpen = false

    private let d = UserDefaults.standard
    private init() {
        enabled = d.object(forKey: "stv.dm.enabled") as? Bool ?? true
        area = Area(rawValue: d.string(forKey: "stv.dm.area") ?? "") ?? .third
        opacity = d.object(forKey: "stv.dm.opacity") as? Double ?? 0.85
        speed = Speed(rawValue: d.string(forKey: "stv.dm.speed") ?? "") ?? .medium
        size = Size(rawValue: d.string(forKey: "stv.dm.size") ?? "") ?? .medium
    }
    private func save() {
        d.set(enabled, forKey: "stv.dm.enabled"); d.set(area.rawValue, forKey: "stv.dm.area")
        d.set(opacity, forKey: "stv.dm.opacity")
        d.set(speed.rawValue, forKey: "stv.dm.speed"); d.set(size.rawValue, forKey: "stv.dm.size")
    }
}

/// Where danmaku lanes go — relative to the SCREEN, not the (letterboxed) video. 1.4b10 framed the layer to
/// the video rect, so in portrait a 16:9 video put every comment in the middle of the screen.
/// Lanes start right under the top bar (+ tech strip), span the full width, use `area` of the remaining
/// height, never more than the user's row count, and never reach the bottom controls.
enum DanmakuRegion {
    struct Region: Equatable { var top: CGFloat; var rows: Int; var bottomLimit: CGFloat; var laneSpacing: CGFloat }
    static let topBar: CGFloat = 44
    static func compute(screen: CGSize, safeTop: CGFloat, safeBottom: CGFloat, landscape: Bool, showTech: Bool,
                        area: CGFloat, laneHeight: CGFloat, maxRows: Int) -> Region {
        let top: CGFloat
        let bottomLimit: CGFloat
        if landscape {
            // Landscape top bar sits at max(safeTop, 14); the tech strip is inline in that row.
            top = max(safeTop, 14) + topBar + 6
            bottomLimit = screen.height - max(safeBottom, 8) - 116      // title + progress + icon row
        } else {
            top = safeTop + topBar + (showTech ? 34 : 10)
            bottomLimit = screen.height - safeBottom - 220             // meta + title + progress + icon row
        }
        let usable = max(0, bottomLimit - top)
        // 显示区域 = 弹幕覆盖「可用区」的高度比例（面板标注：顶栏下方起、不遮底部控件）。
        // 行数由「显示行数」设定决定；行距把这几行均匀铺满所选区域，于是 3/4 就真的覆盖到 3/4，
        // 而不是旧版那样被行高压成顶部一小条。
        let regionHeight = max(laneHeight, usable * area)
        let rows = max(1, min(maxRows, Int(regionHeight / max(1, laneHeight))))
        let spacing = max(laneHeight, regionHeight / CGFloat(rows))
        return Region(top: top, rows: rows, bottomLimit: bottomLimit, laneSpacing: spacing)
    }
}

/// Lane scheduler (port of hongguo-open-player prioritizeDanmakuItems): collision-free tracks,
/// higher-liked comments evict lower-liked blockers when every lane is busy.
enum DanmakuLayout {
    struct Placed: Identifiable {
        let item: HGDanmaku
        let text: String
        let badge: String
        let lane: Int
        let width: CGFloat
        var id: String { item.id }
    }

    static func estimateWidth(_ s: String, font: CGFloat) -> CGFloat {
        var w: CGFloat = 8
        for u in s.unicodeScalars {
            if u.value >= 0x20 && u.value <= 0x7E { w += font * 0.56 }
            else if u.properties.isEmojiPresentation || u.value >= 0x1F000 { w += font * 1.15 }
            else if u.value == 0xFE0F || u.value == 0x200D || (0x20E3 == u.value) { continue }
            else { w += font }
        }
        return w
    }

    static func requiredGap(_ wp: CGFloat, _ wn: CGFloat, screen: CGFloat, duration: Double) -> Double {
        max(duration * Double(wp + 12) / Double(screen + wp), duration * Double(wn + 12) / Double(screen + wn))
    }

    static func layout(_ items: [HGDanmaku], rows: Int, screen: CGFloat, font: CGFloat, duration: Double) -> [Placed] {
        let rows = max(1, rows)
        struct C { let item: HGDanmaku; let text: String; let badge: String; let width: CGFloat; let idx: Int }
        var cs: [C] = items.enumerated().map { i, it in
            let text = DanmakuText.display(it.text)
            let badge = it.count > 1 ? "×\(it.count)" : ""
            let w = estimateWidth(text, font: font) + (badge.isEmpty ? 0 : estimateWidth(badge, font: font * 0.8) + 6)
            return C(item: it, text: text, badge: badge, width: w, idx: i)
        }
        cs.sort { a, b in
            if a.item.time != b.item.time { return a.item.time < b.item.time }
            if a.item.likes != b.item.likes { return a.item.likes > b.item.likes }
            return a.idx < b.idx
        }
        var tracks = [[C]](repeating: [], count: rows)
        for c in cs {
            var free = -1
            var bestSlack = Double.infinity
            for k in 0..<rows {
                guard let prev = tracks[k].last else { free = k; break }
                let gap = requiredGap(prev.width, c.width, screen: screen, duration: duration)
                if c.item.time >= prev.item.time + gap {
                    let slack = c.item.time - (prev.item.time + gap)
                    if slack < bestSlack { bestSlack = slack; free = k }
                }
            }
            if free >= 0 { tracks[free].append(c) }
        }
        var out: [Placed] = []
        for k in 0..<rows { for c in tracks[k] { out.append(Placed(item: c.item, text: c.text, badge: c.badge, lane: k, width: c.width)) } }
        return out.sorted { $0.item.time < $1.item.time }
    }
}

/// Scrolling bullet-comment layer synced to AVPlayer time. Never intercepts touches.
struct DanmakuOverlay: View {
    let co: PlaybackCoordinator
    let seriesId: String
    let vid: String
    var landscape = false
    /// Screen-space y of lane 0 (the overlay itself covers the whole screen).
    var laneTop: CGFloat = 96
    /// Lane count already bounded by area / bottom controls / the user's row setting.
    var laneCount: Int = 4
    /// Vertical distance between lanes — spread so `rows` lanes fill the selected 显示区域.
    var laneSpacing: CGFloat = 0
    @State private var raw: [HGDanmaku] = []
    @State private var placed: [DanmakuLayout.Placed] = []
    // 必须是 @ObservedObject：否则设置面板改 speed/size/area 时 overlay 不重绘，
    // layoutKey 的 onChange 不触发，表现为「弹幕开着时这几个控件没反应，关掉再开才生效」。
    @ObservedObject private var settings = DanmakuSettings.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // 30fps 对滚动弹幕足够顺滑，砍掉一半 Canvas 开销；设置面板打开时彻底冻结，
            // 否则逐帧重绘+视频解码抢主线程，面板按钮会「时灵时不灵」。关闭面板自动恢复。
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: placed.isEmpty || settings.panelOpen || co.paused)) { timeline in
                // Reading timeline.date inside the renderer forces a redraw every animation frame.
                let frame = timeline.date
                Canvas { ctx, canvas in
                    _ = frame
                    draw(&ctx, canvas)
                }
            }
            .onChange(of: layoutKeyValue) { _ in relayout(size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: vid) { await load() }
    }

    private var font: CGFloat { settings.size.points }
    private var laneHeight: CGFloat { font * 1.55 }
    private var topInset: CGFloat { laneTop }
    private var rows: Int { max(1, laneCount) }
    static func laneHeight(_ s: DanmakuSettings) -> CGFloat { s.size.points * 1.55 }

    private var layoutKeyValue: String {
        "\(vid)|\(raw.count)|\(settings.speed.rawValue)|\(settings.size.rawValue)|\(settings.area.rawValue)|\(Int(laneTop))|\(settings.opacity)"
    }

    private func relayout(_ size: CGSize) {
        guard size.width > 0 else { return }
        placed = DanmakuLayout.layout(raw, rows: rows, screen: size.width, font: font,
                                      duration: settings.speed.duration)
        if !raw.isEmpty {
            settings.status = "本集 \(raw.count) 条 · 上屏 \(placed.count) 条"
        }
    }

    private func load() async {
        raw = []; placed = []
        settings.status = "弹幕加载中…"
        let r = await HGDanmakuClient.shared.fetch(seriesId: seriesId, vid: vid)
        guard !Task.isCancelled else { return }
        raw = r.items
        settings.status = r.items.isEmpty ? r.notice : (r.notice.isEmpty ? "本集 \(r.items.count) 条" : r.notice)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let t = co.playhead
        guard t.isFinite, !placed.isEmpty else { return }
        let dur = settings.speed.duration
        let W = size.width
        ctx.opacity = settings.opacity
        // 不再对整屏 Canvas 施加 .shadow 高斯模糊滤镜：视频解码的同时每秒 30 次全屏模糊
        // 会把 GPU/渲染管线打满，播放器的其他按钮就会「时灵时不灵」。改为每条弹幕先画一层
        // 1pt 偏移的黑色底字当阴影，视觉等效而开销只有原滤镜的几十分之一。
        // Binary search for the first item that can still be on screen.
        var lo = 0, hi = placed.count
        while lo < hi { let m = (lo + hi) / 2; if placed[m].item.time < t - dur { lo = m + 1 } else { hi = m } }
        var i = lo
        while i < placed.count {
            let p = placed[i]
            if p.item.time > t { break }
            i += 1
            let elapsed = t - p.item.time
            guard elapsed >= 0, elapsed < dur else { continue }
            let spacing = laneSpacing > 0 ? laneSpacing : laneHeight
            let y = topInset + CGFloat(p.lane) * spacing
            guard p.lane < rows else { continue }
            let x = W - CGFloat(elapsed / dur) * (W + p.width)
            let merged = p.item.count > 1
            let weight: Font.Weight = (merged || p.item.likes >= 50) ? .bold : .semibold
            let color = Color(hex: p.item.color) ?? .white
            let fnt = Font.system(size: font, weight: weight)
            // 阴影：黑色底字向右下偏移 1pt，替代整屏模糊滤镜。
            let shadow = ctx.resolve(Text(p.text).font(fnt).foregroundColor(.black))
            ctx.draw(shadow, at: CGPoint(x: x + 0.8, y: y + 1), anchor: .leading)
            let text = ctx.resolve(Text(p.text).font(fnt).foregroundColor(color))
            ctx.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
            if merged {
                let tw = text.measure(in: CGSize(width: 2000, height: 100)).width
                let badge = ctx.resolve(Text(p.badge).font(.system(size: font * 0.8, weight: .heavy)).foregroundColor(STVTheme.accentWarm))
                ctx.draw(badge, at: CGPoint(x: x + tw + 4, y: y), anchor: .leading)
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// 设置面板内的效果预览：参考主流播放器的做法——固定一行示例字「这是一条弹幕效果预览🚀」，
/// 不滚动、不加动画。只会随字号 / 不透明度即时变化，所见即所得。
/// 之前这里跑 60fps TimelineView 滚动动画，是设置面板内按钮「时灵时不灵」的直接元凶之一。
struct DanmakuPreview: View {
    @ObservedObject var settings: DanmakuSettings

    var body: some View {
        Text("这是一条弹幕效果预览 🚀")
            .font(.system(size: settings.size.points, weight: .semibold))
            .foregroundColor(.white)
            .opacity(settings.opacity)
            .shadow(color: .black.opacity(0.8), radius: 1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DanmakuSettingsSheet: View {
    @ObservedObject var settings = DanmakuSettings.shared
    var available = true
    var onClose: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "tv.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(STVTheme.accent)
                    Text("弹幕设置").font(.headline)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                            .foregroundStyle(STVTheme.secondary)
                    }
                    .accessibilityLabel("关闭弹幕设置")
                }
                if !available {
                    Text("当前片源不支持弹幕（仅红果）").font(.footnote).foregroundStyle(STVTheme.secondary)
                }
                Toggle("显示弹幕", isOn: $settings.enabled)
                    .font(.subheadline)

                // 单行静态预览：固定示例字，仅随字号 / 不透明度变化，不滚动、不耗帧。
                DanmakuPreview(settings: settings)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("字体大小").font(.subheadline)
                        Spacer()
                        Text(sizeValue).font(.caption).foregroundStyle(STVTheme.accentWarm)
                    }
                    Picker("字体大小", selection: $settings.size) {
                        ForEach(DanmakuSettings.Size.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("不透明度").font(.subheadline)
                        Spacer()
                        Text("\(Int(settings.opacity * 100))%").font(.caption).foregroundStyle(STVTheme.accentWarm)
                    }
                    Picker("不透明度", selection: $settings.opacity) {
                        Text("40%").tag(0.4)
                        Text("60%").tag(0.6)
                        Text("80%").tag(0.8)
                        Text("100%").tag(1.0)
                    }.pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("显示区域").font(.subheadline)
                        Spacer()
                        Text(settings.area.label).font(.caption).foregroundStyle(STVTheme.accentWarm)
                    }
                    Picker("显示区域", selection: $settings.area) {
                        ForEach(DanmakuSettings.Area.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("滚动速度").font(.subheadline)
                        Spacer()
                        Text(settings.speed.label).font(.caption).foregroundStyle(STVTheme.accentWarm)
                    }
                    Picker("滚动速度", selection: $settings.speed) {
                        ForEach(DanmakuSettings.Speed.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if !settings.status.isEmpty {
                    Text(settings.status).font(.caption2).foregroundStyle(STVTheme.secondary)
                }
            }
            .tint(STVTheme.accent)
            .padding(14).padding(.top, 4)
        }
        // 面板期间冻结播放器弹幕逐帧重绘，主线程让给面板触摸响应（否则按钮「时灵时不灵」）。
        .onAppear { settings.panelOpen = true }
        .onDisappear { settings.panelOpen = false }
    }

    /// 字体大小右侧数值：与参考样式一致显示倍率（1.0x / 1.25x / 1.5x）。
    private var sizeValue: String {
        switch settings.size {
        case .small: "0.8x"
        case .medium: "1.0x"
        case .large: "1.25x"
        case .xlarge: "1.5x"
        }
    }
}
