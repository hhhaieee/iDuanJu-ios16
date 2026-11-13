import SwiftUI

struct PlayerIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Design v3: 44 pt glass circle — black 55 % + blur + white 14 % 0.5 pt stroke.
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background { Circle().fill(.ultraThinMaterial).overlay(Circle().fill(.black.opacity(0.42))) }
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct PlayerCaption: View {
    let title: String
    let source: String
    let episode: Int
    let total: Int
    var compact = false
    /// Replaces "第N集 · 共M集" for single long videos (e.g. the 番号).
    var detailLine: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(source)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2)) }
                Text(detailLine ?? "第\(episode)集 · 共\(total)集").monospacedDigit()
            }
            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.86))
            Text(title)
                .font(compact ? .headline : .title2.weight(.bold)).lineLimit(compact ? 1 : 2)
                .foregroundStyle(.white)
        }
    }
}

struct PlayerOptionsSheet<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let selected: Option?
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title3.bold())
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                    ForEach(options, id: \.self) { option in
                        Button { onSelect(option) } label: {
                            Text(label(option)).font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(option == selected ? STVTheme.accent.opacity(0.16) : STVTheme.glass,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(option == selected ? STVTheme.accent : STVTheme.text)
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(option == selected ? .isSelected : [])
                    }
                }
            }.padding(20).padding(.top, 12)
        }
        .presentationDetents([.height(96 + CGFloat((options.count + 2) / 3) * 54), .large])
    }
}

/// Progress bar (design v3): full-width 3 pt track — played white, buffered white 40 %, rest white 22 % —
/// with a 4×16 bar knob. Dragging grows it to 8 pt with a 20 pt round knob and a bubble (thumbnail when the
/// asset allows it + "t / d" + blue ±delta). Drag or tap anywhere; seek happens on release.
struct PlayerProgressBar: View {
    let co: PlaybackCoordinator
    @Binding var scrubbing: Bool
    var onInteract: () -> Void = {}
    /// Non-interactive hairline shown when the chrome is hidden.
    var mini = false
    @State private var drag: Double?
    @State private var dragStart: Double = 0
    @State private var thumb: UIImage?

    private static let thin: CGFloat = 3, thick: CGFloat = 8, miniH: CGFloat = 2

    var body: some View {
        let duration = max(0, co.duration)
        let played = duration > 0 ? min(1, max(0, co.time / duration)) : 0
        let shown = drag ?? played
        let buffered = duration > 0 ? min(1, max(shown, co.bufferedUntil / duration)) : 0
        let h = mini ? Self.miniH : (drag != nil ? Self.thick : Self.thin)
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(mini ? 0.16 : 0.22))
                if !mini { Capsule().fill(.white.opacity(0.40)).frame(width: w * buffered) }
                Capsule().fill(.white.opacity(mini ? 0.9 : 1)).frame(width: max(h, w * shown))
            }
            .frame(height: h)
            .overlay(alignment: .leading) {
                if !mini {
                    Group {
                        if drag != nil { Circle().fill(.white).frame(width: 20, height: 20) }
                        else { RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 4, height: 16) }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: w * shown - (drag != nil ? 10 : 2))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let f = drag, duration > 0 {
                    bubble(f * duration, duration, delta: (f - dragStart) * duration)
                        .fixedSize()
                        .position(x: min(max(w * f, 86), w - 86), y: thumbAvailable ? -82 : -26)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("player.progress.bubble")
                }
            }
            .gesture(mini || duration <= 0 ? nil : DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if drag == nil {
                        dragStart = played; scrubbing = true
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    drag = min(1, max(0, v.location.x / max(1, w)))
                    co.scrubPreview = (drag ?? 0) * duration
                    onInteract()
                }
                .onEnded { _ in
                    if let f = drag { co.seek(fraction: f) }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { drag = nil }
                    co.scrubPreview = nil
                    scrubbing = false
                    onInteract()
                })
        }
        .frame(height: mini ? Self.miniH : 22)
        .task(id: drag.map { Int($0 * max(1, co.duration) / PlayerThumbnailer.bucket) }) {
            guard let f = drag, co.duration > 0, co.thumbnails.available else { return }
            if let c = co.thumbnails.cached(at: f * co.duration) { thumb = c; return }
            try? await Task.sleep(for: .milliseconds(60))
            if let img = await co.thumbnails.image(at: f * co.duration), drag != nil { thumb = img }
        }
        #if DEBUG
        .task(id: co.scrubDemo) {   // screenshots only: `STV_SCRUB_DEMO=0.62` freezes the dragging look (no seek)
            if !mini, let f = co.scrubDemo {
                dragStart = 0.2; drag = f; scrubbing = true; co.scrubPreview = f * co.duration
            }
        }
        .task {
            if !mini, co.scrubDemo == nil, let f = Double(ProcessInfo.processInfo.environment["STV_SCRUB_DEMO"] ?? "") {
                try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["STV_SCRUB_DELAY"] ?? "") ?? 3))
                if co.scrubDemo == nil { co.scrubDemo = f }
            }
        }
        #endif
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: drag != nil)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Fmt.duration(Int(shown * duration))) / \(Fmt.duration(Int(duration)))")
        .accessibilityIdentifier(mini ? "player.progress.mini" : "player.progress")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 10.0 : -10.0
            if duration > 0 { co.seek(fraction: max(0, min(1, (co.time + delta) / duration))) }
            onInteract()
        }
    }

    private var thumbAvailable: Bool { thumb != nil && co.thumbnails.available }

    private func bubble(_ t: Double, _ d: Double, delta: Double) -> some View {
        VStack(spacing: 4) {
            if let thumb, co.thumbnails.available {
                Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 168, height: 95).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 1.5) }
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("player.progress.thumb")
            }
            (Text(Fmt.clock(Int(t))).foregroundColor(.white) + Text(" / " + Fmt.clock(Int(d))).foregroundColor(.white.opacity(0.7)))
                .font(.system(size: 17, weight: .bold).monospacedDigit())
            Text(abs(delta) >= 1 ? (delta > 0 ? "+" : "−") + Fmt.clock(Int(abs(delta))) : " ")
                .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(STVTheme.accent)
        }
        .shadow(color: .black.opacity(0.55), radius: 4)
    }
}

/// Bottom chrome under the caption: progress bar, then one quiet row (play · time … actions).
struct PlayerTimeline<Trailing: View>: View {
    let co: PlaybackCoordinator
    @Binding var scrubbing: Bool
    let onInteract: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 2) {
            PlayerProgressBar(co: co, scrubbing: $scrubbing, onInteract: onInteract)
            HStack(spacing: 4) {
                Button { co.togglePause(); onInteract() } label: {
                    Image(systemName: co.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 30, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(co.paused ? "播放" : "暂停").accessibilityIdentifier("player.playPause")
                Text("\(Fmt.duration(Int(co.time))) / \(Fmt.duration(Int(max(0, co.duration))))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).fixedSize().layoutPriority(2)
                    .accessibilityIdentifier("player.time")
                Spacer(minLength: 4)
                trailing
            }
        }
        .foregroundStyle(.white)
    }
}

/// Small glass pill used in the player's bottom row.
struct PlayerPill: View {
    let title: String
    var symbol: String? = nil
    var accent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accent ? STVTheme.accent : .white)
            .padding(.horizontal, 9).frame(height: 28)
            .background(.white.opacity(accent ? 0.1 : 0.12), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
            .frame(minHeight: 40).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// On-screen speed-control HUD while long-pressing.
struct PlayerSpeedHUD: View {
    var rate: Double
    var pendingLock: Bool
    var pendingCancel: Bool
    var hasLockedRate: Bool

    private var hint: String {
        if pendingCancel { return "松开取消锁定 · 恢复 1x" }
        if pendingLock { return "松开后锁定此倍速" }
        if hasLockedRate { return "← → 调速 · ↑ 改锁定 · ↓ 取消锁定" }
        return "← → 调速 · ↑ 锁定 · ↓ 取消"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: pendingCancel ? "xmark.circle.fill"
                      : (pendingLock || hasLockedRate ? "lock.fill" : "gauge.with.dots.needle.67percent"))
                    .font(.system(size: 18, weight: .semibold))
                Text(PlaybackCoordinator.formatRate(rate))
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(pendingCancel ? Color.orange : (pendingLock ? STVTheme.accent : .white))

            Text(hint)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                Label("减慢", systemImage: "chevron.left")
                Label("加快", systemImage: "chevron.right")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

/// Headless chrome states for simulator screenshots (`STV_SHOTS=1`).
struct PlayerChromeShotHost: View {
    enum Phase: Int, CaseIterable { case rightMenu, speedHUD, locked }

    @State private var phase: Phase = .rightMenu

    var body: some View {
        ZStack {
            LinearGradient(colors: [STVTheme.surface, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(alignment: .leading) {
                HStack {
                    PlayerIconButton(symbol: "chevron.left", label: "返回") {}
                    Spacer()
                    PlayerIconButton(symbol: "heart", label: "收藏") {}
                    PlayerIconButton(symbol: "pip.enter", label: "画中画") {}
                }
                Spacer()
                PlayerCaption(title: "霸总的秘密助理", source: "红果短剧", episode: 3, total: 80)
                Capsule().fill(.white.opacity(0.2)).frame(height: 3)
                    .overlay(alignment: .leading) { Capsule().fill(STVTheme.accent).frame(width: 140, height: 3) }.padding(.vertical)
            }.padding(.horizontal, 20)
            if phase != .rightMenu {
                PlayerSpeedHUD(rate: phase == .locked ? 2 : 1.5, pendingLock: phase == .locked,
                               pendingCancel: false, hasLockedRate: phase == .locked)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            // Timed phases so an external script can screenshot each state.
            // Stay on each phase long enough for simctl screenshots.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            phase = .speedHUD
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            phase = .locked
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
    }
}
