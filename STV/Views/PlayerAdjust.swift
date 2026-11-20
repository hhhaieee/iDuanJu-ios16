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

    // MARK: - 物理音量键
    // iOS 不提供拦截音量键的公开 API，且 HiddenVolumeView(MPVolumeView) 会抑制系统音量 HUD。
    // 三通道监听，保证到 0%/100% 边界继续按同方向键也弹 HUD：
    //  1) KVO 监听 outputVolume —— 常规调节（值变化）时触发；
    //  2) 通知 SystemVolumeDidChange —— iOS 15+ 的按键通知，userInfo["Volume"]，值不变（边界）也触发；
    //  3) 旧通知 AVSystemController_SystemVolumeDidChangeNotification —— iOS 14- 兼容，userInfo 取音频音量参数。
    // build86 只监听了旧通知名，iOS 16 上已被改名导致收不到，边界按键不弹——build87 改为新旧都监听。
    // 播放器内的 MPVolumeView（HiddenVolumeView）是收到这些通知的前提，已挂载。
    private var systemVolumeObservation: NSKeyValueObservation?
    private var systemVolumeNotificationTokens: [NSObjectProtocol] = []
    private var lastVolumeSequence: NSNumber? = nil

    func startSystemVolumeObservation() {
        guard systemVolumeObservation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // 1) KVO：常规音量变化
        systemVolumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = Double(session.outputVolume)
            Task { @MainActor [weak self] in
                self?.showSystemVolumeHUD(value)
            }
        }
        // 2)+3) 系统通知：边界按键（值不变）也触发。两者都注册，按系统版本各取所需。
        // 新通知可能非主线程回调、且一次按键回调两次（SequenceNumber 相同）→ 切主线程 + 去重。
        if systemVolumeNotificationTokens.isEmpty {
            systemVolumeNotificationTokens = [
                NotificationCenter.default.addObserver(
                    forName: NSNotification.Name("SystemVolumeDidChange"),
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    // 只响应实体音量键（Reason=ExplicitVolumeChange）：切集 / 音频会话切换等系统内部
                    // 音量变化不弹 HUD。Reason 缺失时放行，避免个别系统不带该字段时误伤按键提示。
                    if let reason = note.userInfo?["Reason"] as? String, reason != "ExplicitVolumeChange" { return }
                    let seq = note.userInfo?["SequenceNumber"] as? NSNumber
                    let vol = (note.userInfo?["Volume"] as? NSNumber)?.floatValue
                        ?? (note.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber)?.floatValue
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let seq, seq == self.lastVolumeSequence { return }  // 同一次按键的重复回调
                        self.lastVolumeSequence = seq
                        let value = vol.map(Double.init) ?? Double(AVAudioSession.sharedInstance().outputVolume)
                        self.showSystemVolumeHUD(value)
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    if let reason = note.userInfo?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String,
                       reason != "ExplicitVolumeChange" { return }
                    let value = (note.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber)?.floatValue
                        ?? AVAudioSession.sharedInstance().outputVolume
                    Task { @MainActor [weak self] in
                        self?.showSystemVolumeHUD(Double(value))
                    }
                }
            ]
        }
    }

    func stopSystemVolumeObservation() {
        systemVolumeObservation?.invalidate()
        systemVolumeObservation = nil
        systemVolumeNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        systemVolumeNotificationTokens.removeAll()
        lastVolumeSequence = nil
    }

    private func showSystemVolumeHUD(_ value: Double) {
        hideTask?.cancel()
        hud = (.volume, value)
        end() // 复用 0.8s 后淡出（连续按键会不断续期，停手后才消失）
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
