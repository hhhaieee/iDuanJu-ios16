import SwiftUI
import AVFoundation

/// Player design v3 (player-design-v3/SPEC_ZH.md): monochrome white chrome, brand blue only for the current
/// episode, the scrub delta and a non-1× rate.

// MARK: Glass

struct PlayerGlass: ViewModifier {
    var corner: CGFloat
    var strong = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(white: 0.09).opacity(strong ? 0.62 : 0.45)))
            }
            .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func playerGlass(_ corner: CGFloat, strong: Bool = false) -> some View { modifier(PlayerGlass(corner: corner, strong: strong)) }
}

// MARK: Tech strip

struct PlayerTechStrip: View {
    let tech: PlayerTech
    var landscape = false

    var body: some View {
        let fs: CGFloat = landscape ? 11 : 10.5
        HStack(spacing: landscape ? 12 : 10) {
            if !tech.resolution.isEmpty {
                Text(tech.resolution).font(.system(size: fs, weight: .heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.white, in: RoundedRectangle(cornerRadius: 3))
            }
            Text(tech.hdr ? "HDR" : "SDR").font(.system(size: fs, weight: .bold))
            if !tech.codec.isEmpty {
                Text(tech.codec).font(.system(size: fs - 1.5, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 0.5)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.8), lineWidth: 0.8) }
            }
            if landscape { pair("BIT", "\(tech.bitDepth)", fs) }
            if !tech.audio.isEmpty {
                let p = tech.audio.split(separator: " ", maxSplits: 1).map(String.init)
                pair(p[0], p.count > 1 ? p[1] : "", fs)
            }
            if tech.fps > 0 { pair("FPS", "\(tech.fps)", fs) }
            if landscape, tech.bitrate > 0 { pair("BPS", String(format: "%.1f", tech.bitrate), fs) }
            if !tech.engine.isEmpty {
                Text(tech.engine).font(.system(size: fs - 1.5, weight: .semibold)).opacity(0.7)
                    .accessibilityIdentifier("player.engine")
            }
            if tech.network > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "wifi").font(.system(size: fs, weight: .semibold))
                    Text(PlayerTech.speed(tech.network)).font(.system(size: fs, weight: .medium).monospacedDigit()).opacity(0.75)
                }
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1).fixedSize()
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.tech")
    }

    private func pair(_ k: String, _ v: String, _ fs: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: fs, weight: .bold))
            if !v.isEmpty { Text(v).font(.system(size: fs, weight: .medium).monospacedDigit()).opacity(0.75) }
        }
    }
}

// MARK: Centre controls

/// ⟲10 · ▶ (76 pt glass, the outer ring doubles as buffer / loading progress) · ⟳10.
struct PlayerCenterControls: View {
    let co: PlaybackCoordinator
    let onInteract: () -> Void
    @State private var spin = false

    var body: some View {
        let loading = co.readyIndex == nil || (co.waitingForMedia && !co.paused)
        let buffered = co.duration > 0 ? min(1, co.bufferedUntil / co.duration) : 0
        HStack(spacing: 46) {
            Button { co.seek(by: -10); onInteract() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 26, weight: .regular)).frame(width: 44, height: 44)
            }.accessibilityLabel("快退10秒").accessibilityIdentifier("player.back10")
            Button { co.togglePause(); onInteract() } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Circle().fill(.black.opacity(0.32))
                    Circle().stroke(.white.opacity(0.22), lineWidth: 2)
                    if loading {
                        Circle().trim(from: 0, to: 0.28).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                            .onAppear { spin = true }.onDisappear { spin = false }
                    } else {
                        Circle().trim(from: 0, to: buffered).stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: co.paused ? "play.fill" : "pause.fill").font(.system(size: 30, weight: .regular))
                        .offset(x: co.paused ? 2 : 0)
                }
                .frame(width: 76, height: 76)
            }
            .accessibilityLabel(co.paused ? "播放" : "暂停").accessibilityIdentifier("player.playPause")
            Button { co.seek(by: 10); onInteract() } label: {
                Image(systemName: "goforward.10").font(.system(size: 26, weight: .regular)).frame(width: 44, height: 44)
            }.accessibilityLabel("快进10秒").accessibilityIdentifier("player.fwd10")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 6)
    }
}

// MARK: Caption

struct PlayerMetaRow: View {
    let source: String?
    let line: String
    let lineStrong: String
    let rest: String
    var showSkip = false
    var onSkip: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let source {
                Text(source).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            }
            (Text(line).foregroundColor(.white.opacity(0.85)) + Text(lineStrong).foregroundColor(.white).bold() + Text(rest).foregroundColor(.white.opacity(0.55)))
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if showSkip {
                Button(action: onSkip) {
                    HStack(spacing: 4) { Text("跳过片头"); Image(systemName: "play.fill").font(.system(size: 8)) }
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("player.skipIntro")
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: Progress

/// v3 bar: full width 3 pt (played white, buffered white 40 %, track white 22 %), 4×16 bar knob; dragging grows
/// it to 8 pt with a 20 pt round knob and a thumbnail + time bubble. Time row underneath: elapsed · −remaining.
struct PlayerTimelineV3: View {
    let co: PlaybackCoordinator
    @Binding var scrubbing: Bool
    var onInteract: () -> Void = {}
    /// Max width of the bubble positioning area (screen coordinates).
    var landscape = false

    var body: some View {
        VStack(spacing: 2) {
            PlayerProgressBar(co: co, scrubbing: $scrubbing, onInteract: onInteract)
            HStack {
                let t = co.scrubPreview ?? co.time
                Text(Fmt.clock(Int(t))).accessibilityIdentifier("player.time")
                Spacer()
                Text("−" + Fmt.clock(Int(max(0, co.duration - t)))).accessibilityIdentifier("player.remaining")
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: Icon row

enum PlayerPanel: String, Identifiable {
    case episodes, quality, rates, audio, subtitles, danmaku
    var id: Self { self }
}

/// One 44 pt line icon (white 16 % rounded backing while its popover is open).
struct PlayerRowIcon<Label: View>: View {
    let id: String
    let a11y: String
    var active = false
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label.foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(active ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y).accessibilityIdentifier(id)
    }
}

struct OutlinedTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.2) }
    }
}

struct DanmakuGlyph: View {
    let on: Bool
    var body: some View {
        Text("弹").font(.system(size: 13, weight: .bold))
            .foregroundStyle(on ? .black : .white)
            .frame(width: 22, height: 22)
            .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay { if !on { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.2) } }
    }
}

// MARK: Popovers

struct PlayerPopoverRow: View {
    let title: String
    var detail: String = ""
    var subtitle: String? = nil
    let selected: Bool
    var id: String? = nil
    var rowHeight: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).opacity(selected ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)) }
                }
                Spacer(minLength: 8)
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(minHeight: subtitle == nil ? rowHeight : 54)
            .background(selected ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "player.option")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlayerSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }
}

struct SpeedPopover: View {
    let current: Double
    var landscape = false
    /// Active core's ceiling (AetherEngine clamps video to 2×; AVPlayer 3×).
    var maxRate: Double = 3
    let onPick: (Double) -> Void
    static let portraitSteps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !landscape { PlayerSectionTitle(text: "播放速度") }
            ForEach((landscape ? Array(Self.portraitSteps.prefix(6)) : Self.portraitSteps).filter { $0 <= maxRate + 0.001 }, id: \.self) { r in
                PlayerPopoverRow(title: Self.label(r), selected: abs(r - current) < 0.01, id: "player.rate.\(r)", rowHeight: landscape ? 37 : 44) { onPick(r) }
            }
            if !landscape {
                Text("长按画面可临时 2× 加速").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        .padding(7)
    }

    static func label(_ r: Double) -> String {
        let s = r == Double(Int(r)) ? "\(Int(r))×" : (String(format: "%g", r) + "×")
        return r == 1 ? s + " 正常速度" : s
    }
}

struct QualityPopover: View {
    let streams: [HGStream]
    let chosen: HGStream?
    let sources: [(title: String, detail: String, current: Bool, action: () -> Void)]
    var streamsTitle = "画质"
    let onPick: (HGStream) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PlayerSectionTitle(text: streamsTitle)
            ForEach(streams) { s in
                PlayerPopoverRow(title: s.quality ?? "自动", detail: Self.detail(s), selected: s == chosen, id: "player.stream") { onPick(s) }
            }
            if !sources.isEmpty {
                Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 12).padding(.vertical, 6)
                PlayerSectionTitle(text: "播放源")
                ForEach(sources.indices, id: \.self) { i in
                    let s = sources[i]
                    PlayerPopoverRow(title: s.title, detail: s.detail, selected: s.current, id: "player.source") { s.action() }
                }
            }
        }
        .padding(7)
    }

    static func detail(_ s: HGStream) -> String {
        var parts: [String] = []
        if let w = s.width, let h = s.height, w > 0, h > 0 { parts.append("\(w)×\(h)") }
        else if let c = s.codec, !c.isEmpty { parts.append(c.uppercased() == "H264" ? "H.264" : c) }
        if let b = s.bitrate, b > 0 { parts.append(String(format: "%.1fMbps", Double(b) / 1_000_000)) }
        return parts.joined(separator: " · ")
    }
}

struct TrackPopover: View {
    let title: String
    let options: [MediaTrack]
    let selected: Int?
    let allowsOff: Bool
    let emptyText: String
    /// Track id; nil = off.
    let onPick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PlayerSectionTitle(text: title)
            if options.isEmpty {
                Text(emptyText).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 12).frame(minHeight: 44)
            } else {
                if allowsOff { PlayerPopoverRow(title: "关闭", selected: selected == nil) { onPick(nil) } }
                ForEach(options) { o in
                    PlayerPopoverRow(title: o.title, selected: o.id == selected) { onPick(o.id) }
                }
            }
        }
        .padding(7)
    }
}

/// Short drama: season chips → 30-episode group chips → 6-column grid. Long video: a list (ref_2).
struct EpisodesPopover: View {
    let episodes: [HGEpisode]
    let current: Int
    let seasons: [(id: String, title: String)]
    let currentSeason: String?
    let listStyle: Bool
    var dateLine: String? = nil
    let onPick: (Int) -> Void
    var onSeason: (String) -> Void = { _ in }
    @State private var group = 0

    var body: some View {
        let ranges = EpisodeGroups.ranges(total: episodes.count)
        VStack(alignment: .leading, spacing: 12) {
            if episodes.isEmpty {
                Text("分集还在加载").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).frame(minHeight: 44)
            } else if !listStyle {
                HStack {
                    Text("选集 · 共\(episodes.count)集").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Text("更新至 \(episodes.last?.ep ?? episodes.count) 集").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                if seasons.count > 1 {
                    chips(seasons.map(\.title), selected: seasons.firstIndex { $0.id == currentSeason }, height: 34, font: 14, id: "player.season") { i in
                        onSeason(seasons[i].id)
                    }
                }
                if ranges.count > 1 {
                    chips(ranges.map { EpisodeGroups.label($0, episodes: episodes) }, selected: group, height: 28, font: 13, id: "player.epgroup") { i in
                        withAnimation(.snappy) { group = i }
                    }
                }
                let r = ranges.indices.contains(group) ? ranges[group] : EpisodeRange(0, max(0, episodes.count - 1))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                        ForEach(Array(r.start...min(r.end, episodes.count - 1)), id: \.self) { i in
                            let on = i == current
                            Button { onPick(i) } label: {
                                Text("\(episodes[i].ep)").font(.system(size: 16, weight: on ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? STVTheme.accent.opacity(0.2) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay { if on { RoundedRectangle(cornerRadius: 10).strokeBorder(STVTheme.accent, lineWidth: 1) } }
                                    .foregroundStyle(on ? STVTheme.accent : .white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("player.ep.\(episodes[i].ep)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(episodes.indices, id: \.self) { i in
                                let e = episodes[i]
                                PlayerPopoverRow(title: "S1:E\(e.ep)  " + (e.title.isEmpty ? "第\(e.ep)集" : e.title),
                                                 detail: e.duration > 0 ? "\(max(1, e.duration / 60)) 分钟" : "",
                                                 subtitle: dateLine, selected: i == current, id: "player.ep.\(e.ep)") { onPick(i) }
                                    .id(i)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(listStyle ? 7 : 16)
        .onAppear { if let i = ranges.firstIndex(where: { current >= $0.start && current <= $0.end }) { group = i } }
    }

    private func chips(_ titles: [String], selected: Int?, height: CGFloat, font: CGFloat, id: String, onTap: @escaping (Int) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(titles.indices, id: \.self) { i in
                        let on = i == selected
                        Button { onTap(i) } label: {
                            Text(titles[i]).font(.system(size: font, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(height: height)
                                .background(on ? Color(red: 0.933, green: 0.941, blue: 0.953) : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(on ? .black : .white)
                        }
                        .buttonStyle(.plain).id(i)
                        .accessibilityIdentifier("\(id).\(i)")
                    }
                }
            }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .leading) } }
        }
    }
}
