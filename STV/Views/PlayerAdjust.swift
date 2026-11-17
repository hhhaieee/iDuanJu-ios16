import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/// Brightness (left) / volume (right) vertical-swipe adjustment for the player.
/// Zones: landscape = left/right half; portrait = outer 1/5 strips only (the middle keeps 抖音式 paging),
/// always excluding the edge-back strip. Brightness is restored when the player goes away.
enum AdjustSide { case brightness, volume }

@MainActor
final class PlayerAdjuster: ObservableObject {
    @Published var hud: (side: AdjustSide, value: Double)? = nil
    @Published private var originalBrightness: CGFloat? = nil
    @Published private var startValue: Double = 0
    @Published private var hideTask: Task<Void, Never>? = nil
    /// Hidden MPVolumeView slider — the sanctioned way to set system volume.
    weak var volumeSlider: UISlider?
    /// App-level volume channel (preferred): read current, write new value (0...1).
    /// MPVolumeView 改系统音量在 iOS 16 上经常静默失效，这里直接改播放器音量。
    var appVolumeGet: (() -> Double)?
    var appVolumeSet: ((Double) -> Void)?

    static func zone(x: CGFloat, width: CGFloat, landscape: Bool, edge: CGFloat) -> AdjustSide? {
        guard width > 0, x >= edge, x <= width - 8 else { return nil }
        // 横竖屏一致：左边缘上下滑调亮度、右边缘调音量，中间区域留给切集 / 进度。
        // 横屏全屏较宽，边缘取固定拇指宽度；竖屏取外侧 1/5 窄条。
        let strip = landscape ? min(96, width * 0.16) : width * 0.2
        if x < strip { return .brightness }
        if x > width - strip { return .volume }
        return nil
    }

    func begin(_ side: AdjustSide) {
        hideTask?.cancel()
        switch side {
        case .brightness:
            if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
            startValue = Double(UIScreen.main.brightness)
        case .volume:
            startValue = appVolumeGet?() ?? Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
        }
        hud = (side, startValue)
    }

    /// `fraction` = total vertical travel / usable height (up = positive).
    func change(_ side: AdjustSide, fraction: Double) {
        let v = min(1, max(0, startValue + fraction))
        switch side {
        case .brightness: UIScreen.main.brightness = CGFloat(v)
        case .volume:
            if let set = appVolumeSet { set(v) }
            else { volumeSlider?.value = Float(v); volumeSlider?.sendActions(for: .valueChanged) }
        }
        hud = (side, v)
    }

    func end() {
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { hud = nil }
        }
    }

    func restoreBrightness() {
        if let b = originalBrightness { UIScreen.main.brightness = b }
        originalBrightness = nil
    }
}

/// Invisible MPVolumeView; hands its UISlider to the adjuster (also suppresses the system volume HUD).
struct HiddenVolumeView: UIViewRepresentable {
    let adjuster: PlayerAdjuster
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { adjuster.volumeSlider = v.subviews.compactMap { $0 as? UISlider }.first }
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if adjuster.volumeSlider == nil { adjuster.volumeSlider = uiView.subviews.compactMap { $0 as? UISlider }.first }
    }
}

/// Compact HUD in the player's OSD style: icon + thin bar + percentage.
struct PlayerAdjustHUD: View {
    let side: AdjustSide
    let value: Double
    private var icon: String {
        switch side {
        case .brightness: value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .volume: value <= 0.001 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 20)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: 120 * value)
            }.frame(width: 120, height: 4)
            Text("\(Int((value * 100).rounded()))").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 28, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.62), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(side == .brightness ? "亮度 \(Int(value * 100))%" : "音量 \(Int(value * 100))%")
    }
}
