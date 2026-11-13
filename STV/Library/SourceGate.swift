import Foundation
import LocalAuthentication
import Combine

/// Which extra sources are visible. Adult long-video sites are OFF by default and only appear after
/// the user enables them in 我的 → 片源管理; an optional Face ID lock hides them again on every cold start.
@MainActor
final class SourceGate: ObservableObject {
    static let shared = SourceGate()

    @Published private(set) var enabled: Set<DramaSource> = []
    @Published private(set) var lockEnabled: Bool = false
    /// Session flag: Face ID passed since launch (always true when the lock is off).
    @Published private(set) var unlocked: Bool = false
    /// Adult Telegram channels (presets bhg1232 / NudefilmsTV, or channels the user marks adult).
    @Published private(set) var adultChannels: Bool = false
    /// Adult manga sources (none shipped yet; the switch gates any added later).
    @Published private(set) var adultManga: Bool = false
    /// 黄果 (视频站 / App 源 / AI 站) is 18+: hidden until switched on here, like the long-video sites.
    @Published private(set) var huangguo: Bool = false
    private let d = UserDefaults.standard

    private init() {
        let raw = d.stringArray(forKey: "stv.sources.enabled") ?? []
        enabled = Set(raw.compactMap(DramaSource.init(rawValue:)).filter { $0.isDynamic || $0.isAdult })
        lockEnabled = d.bool(forKey: "stv.sources.lock")
        unlocked = !d.bool(forKey: "stv.sources.lock")
        adultChannels = d.bool(forKey: "stv.sources.adultChannels")
        adultManga = d.bool(forKey: "stv.sources.adultManga")
        huangguo = d.bool(forKey: "stv.sources.huangguo")
        #if DEBUG
        // Simulator screenshot hook: STV_SOURCES=jable,missav enables those sites for this run.
        if let e = ProcessInfo.processInfo.environment["STV_SOURCES"], !e.isEmpty {
            enabled = Set(e.split(separator: ",").compactMap { DramaSource(rawValue: String($0)) })
            huangguo = e.split(separator: ",").contains("huangguo")
            unlocked = true
        }
        if ProcessInfo.processInfo.environment["STV_ADULT_CHANNELS"] == "1" { adultChannels = true; unlocked = true }
        #endif
    }

    /// Sites currently shown in 首页 / 搜索 / 继续观看.
    var visibleSites: [DramaSource] {
        Sites.all.filter { s in (s.isDynamic && !s.isAdult) || (unlocked && enabled.contains(s)) }
    }
    var enabledCount: Int { enabled.count }
    func isVisible(_ s: DramaSource) -> Bool { s == .huangguo ? showHuangguo : s.isBuiltin || (unlocked && enabled.contains(s)) }
    /// Series-level check: Telegram videos from adult channels follow the adult-channel switch.
    func isVisible(_ s: HGSeries) -> Bool {
        guard s.source == .telegram else { return isVisible(s.source) }
        return !(s.tags.contains(TGVideoProvider.adultTag)) || showAdultChannels
    }
    /// Sources offered in the search tab strip.
    var searchSources: [DramaSource] { [.hongguo] + (showHuangguo ? [.huangguo] : []) + visibleSites }

    var showAdultChannels: Bool { unlocked && adultChannels }
    var showAdultManga: Bool { unlocked && adultManga }
    var showHuangguo: Bool { unlocked && huangguo }
    func setHuangguo(_ on: Bool) { huangguo = on; d.set(on, forKey: "stv.sources.huangguo") }
    func setAdultChannels(_ on: Bool) { adultChannels = on; d.set(on, forKey: "stv.sources.adultChannels") }
    func setAdultManga(_ on: Bool) { adultManga = on; d.set(on, forKey: "stv.sources.adultManga") }

    func set(_ s: DramaSource, on: Bool) {
        guard s.isAdult else { return }
        if on { enabled.insert(s) } else { enabled.remove(s) }
        d.set(enabled.map(\.rawValue).sorted(), forKey: "stv.sources.enabled")
    }

    func setLock(_ on: Bool) async {
        if on {
            guard await authenticate(reason: "开启隐藏片源锁") else { return }
            lockEnabled = true; unlocked = true
        } else {
            if lockEnabled && !unlocked {
                guard await authenticate(reason: "关闭隐藏片源锁") else { return }
            }
            lockEnabled = false; unlocked = true
        }
        d.set(lockEnabled, forKey: "stv.sources.lock")
    }

    @discardableResult func unlock() async -> Bool {
        if unlocked { return true }
        unlocked = await authenticate(reason: "解锁隐藏片源")
        return unlocked
    }
    func relock() { if lockEnabled { unlocked = false } }

    private func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // Device passcode fallback keeps it usable without biometrics (and on the simulator).
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
