import SwiftUI
import AVFoundation

/// Persisted danmaku preferences (hongguo-open-player: enabled / rows / speed / opacity / likes priority) + merge toggle.
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
    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String { switch self { case .small: "小"; case .medium: "中"; case .large: "大" } }
        var points: CGFloat { switch self { case .small: 14; case .medium: 16; case .large: 19 } }
    }

    /// How much of the screen (below the top bar) danmaku lanes may use.
    enum Area: String, CaseIterable, Identifiable {
        case quarter, third, half, most
        var id: String { rawValue }
        var label: String { switch self { case .quarter: "1/4"; case .third: "1/3"; case .half: "半屏"; case .most: "3/4" } }
        var fraction: CGFloat { switch self { case .quarter: 0.25; case .third: 0.34; case .half: 0.5; case .most: 0.75 } }
    }

    var enabled: Bool { didSet { save() } }
    var area: Area { didSet { save() } }
    var merge: Bool { didSet { save() } }
    var likesPriority: Bool { didSet { save() } }
    var rows: Int { didSet { save() } }
    var opacity: Double { didSet { save() } }
    var speed: Speed { didSet { save() } }
    var size: Size { didSet { save() } }
    /// Live status of the current episode (not persisted).
    @Published var status = ""

    private let d = UserDefaults.standard
    private init() {
        enabled = d.object(forKey: "stv.dm.enabled") as? Bool ?? true
        area = Area(rawValue: d.string(forKey: "stv.dm.area") ?? "") ?? .third
        merge = d.object(forKey: "stv.dm.merge") as? Bool ?? true
        likesPriority = d.object(forKey: "stv.dm.likes") as? Bool ?? true
        rows = d.object(forKey: "stv.dm.rows") as? Int ?? 4
        opacity = d.object(forKey: "stv.dm.opacity") as? Double ?? 0.85
        speed = Speed(rawValue: d.string(forKey: "stv.dm.speed") ?? "") ?? .medium
        size = Size(rawValue: d.string(forKey: "stv.dm.size") ?? "") ?? .medium
    }
    private func save() {
        d.set(enabled, forKey: "stv.dm.enabled"); d.set(area.rawValue, forKey: "stv.dm.area"); d.set(merge, forKey: "stv.dm.merge"); d.set(likesPriority, forKey: "stv.dm.likes")
        d.set(rows, forKey: "stv.dm.rows"); d.set(opacity, forKey: "stv.dm.opacity")
        d.set(speed.rawValue, forKey: "stv.dm.speed"); d.set(size.rawValue, forKey: "stv.dm.size")
    }
}

/// Where danmaku lanes go — relative to the SCREEN, not the (letterboxed) video. 1.4b10 framed the layer to
/// the video rect, so in portrait a 16:9 video put every comment in the middle of the screen.
/// Lanes start right under the top bar (+ tech strip), span the full width, use `area` of the remaining
/// height, never more than the user's row count, and never reach the bottom controls.
enum DanmakuRegion {
    struct Region: Equatable { var top: CGFloat; var rows: Int; var bottomLimit: CGFloat }
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
        let height = min(usable, max(laneHeight, (screen.height - top) * area))
        let rows = max(1, min(maxRows, Int(height / max(1, laneHeight))))
        return Region(top: top, rows: rows, bottomLimit: bottomLimit)
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

    static func layout(_ items: [HGDanmaku], rows: Int, screen: CGFloat, font: CGFloat, duration: Double, likesPriority: Bool) -> [Placed] {
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
            if free >= 0 { tracks[free].append(c); continue }
            guard likesPriority, c.item.likes + c.item.count > 1 else { continue }
            let score = c.item.likes + c.item.count - 1
            var best = -1, minScore = score, maxBlock = -Double.infinity
            for k in 0..<rows {
                guard let inc = tracks[k].last else { continue }
                let incScore = inc.item.likes + inc.item.count - 1
                if incScore >= score { continue }
                if tracks[k].count >= 2 {
                    let before = tracks[k][tracks[k].count - 2]
                    if c.item.time < before.item.time + requiredGap(before.width, c.width, screen: screen, duration: duration) { continue }
                }
                let block = inc.item.time + requiredGap(inc.width, c.width, screen: screen, duration: duration) - c.item.time
                if incScore < minScore || (incScore == minScore && block > maxBlock) { minScore = incScore; maxBlock = block; best = k }
            }
            if best >= 0 { tracks[best].removeLast(); tracks[best].append(c) }
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
    @State private var raw: [HGDanmaku] = []
    @State private var placed: [DanmakuLayout.Placed] = []
    @State private var key = ""
    private var settings: DanmakuSettings { .shared }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: co.paused || placed.isEmpty)) { timeline in
                // Reading timeline.date inside the renderer forces a redraw every animation frame.
                let frame = timeline.date
                Canvas { ctx, canvas in
                    _ = frame
                    draw(&ctx, canvas)
                }
            }
            .onChange(of: layoutKey(size)) { k in relayout(size, k) }
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

    private func layoutKey(_ size: CGSize) -> String {
        "\(vid)|\(raw.count)|\(Int(size.width))|\(rows)|\(settings.speed.rawValue)|\(settings.size.rawValue)|\(settings.merge)|\(settings.likesPriority)"
    }

    private func relayout(_ size: CGSize, _ k: String) {
        guard size.width > 0, k != key else { return }
        key = k
        let src = settings.merge ? DanmakuMerger.merge(raw) : raw
        placed = DanmakuLayout.layout(src, rows: rows, screen: size.width, font: font,
                                      duration: settings.speed.duration, likesPriority: settings.likesPriority)
        if !raw.isEmpty {
            settings.status = settings.merge ? "本集 \(raw.count) 条 · 合并后 \(src.count) 条 · 上屏 \(placed.count) 条"
                                             : "本集 \(raw.count) 条 · 上屏 \(placed.count) 条"
        }
    }

    private func load() async {
        raw = []; placed = []; key = ""
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
        ctx.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.2, x: 0, y: 0.5))
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
            let y = topInset + CGFloat(p.lane) * laneHeight
            guard p.lane < rows else { continue }
            let x = W - CGFloat(elapsed / dur) * (W + p.width)
            let merged = p.item.count > 1
            let weight: Font.Weight = (merged || p.item.likes >= 50) ? .bold : .semibold
            let color = Color(hex: p.item.color) ?? .white
            let text = ctx.resolve(Text(p.text).font(.system(size: font, weight: weight)).foregroundColor(color))
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

struct DanmakuSettingsSheet: View {
    @ObservedObject var settings = DanmakuSettings.shared
    var available = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("弹幕").font(.title3.bold())
                if !available {
                    Text("当前片源不支持弹幕（仅红果）").font(.footnote).foregroundStyle(STVTheme.secondary)
                }
                Toggle("显示弹幕", isOn: $settings.enabled)
                Toggle(isOn: $settings.merge) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("合并重复弹幕")
                        Text("相近时间内相同/相似的弹幕合成一条，显示 ×次数").font(.caption).foregroundStyle(STVTheme.secondary)
                    }
                }
                Toggle(isOn: $settings.likesPriority) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高赞优先")
                        Text("轨道拥挤时优先显示点赞多的弹幕").font(.caption).foregroundStyle(STVTheme.secondary)
                    }
                }
                Stepper("显示行数：\(settings.rows)", value: $settings.rows, in: 1...8)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示区域")
                        Text("从屏幕顶部（顶栏下方）算起，不会遮挡底部控件").font(.caption).foregroundStyle(STVTheme.secondary)
                    }
                    Spacer()
                    Picker("显示区域", selection: $settings.area) {
                        ForEach(DanmakuSettings.Area.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("不透明度：\(Int(settings.opacity * 100))%")
                    Slider(value: $settings.opacity, in: 0.2...1).tint(STVTheme.accent)
                }
                HStack {
                    Text("滚动速度")
                    Spacer()
                    Picker("滚动速度", selection: $settings.speed) {
                        ForEach(DanmakuSettings.Speed.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 180)
                }
                HStack {
                    Text("字号")
                    Spacer()
                    Picker("字号", selection: $settings.size) {
                        ForEach(DanmakuSettings.Size.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 180)
                }
                if !settings.status.isEmpty {
                    Text(settings.status).font(.caption).foregroundStyle(STVTheme.secondary)
                }
            }
            .tint(STVTheme.accent)
            .padding(20).padding(.top, 8)
        }
        .presentationDetents([.medium, .large])
    }
}
