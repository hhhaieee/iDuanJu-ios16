import Foundation
import Combine

/// iCloud 云端同步：通过 Apple 官方 iCloud 键值存储（NSUbiquitousKeyValueStore）在登录同一
/// Apple ID 的 iPhone / iPad / Mac / Apple TV 间双向同步观看记录、收藏（追剧）与关键配置。
///
/// 数据以 JSON 存放，key 与本地 UserDefaults 一一对应。合并策略：观看记录 / 收藏按元素合并（较新优先），
/// 配置标量以云端为准。未登录 iCloud 或未授权时 NSUbiquitousKeyValueStore 退化为本地存储，不会崩溃。
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    static let enabledKey = "stv.cloud.enabled"

    private let d = UserDefaults.standard
    private let kv = NSUbiquitousKeyValueStore.default

    @Published private(set) var enabled: Bool
    @Published private(set) var lastSync: Date?
    @Published private(set) var status = "未开启"
    @Published private(set) var syncing = false

    private init() {
        enabled = d.bool(forKey: Self.enabledKey)
        lastSync = d.object(forKey: "stv.cloud.lastSync") as? Date
        if enabled { status = "已开启 · 等待同步" }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyExternalChange() }
        }
        if enabled {
            kv.synchronize()
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
    }

    func setEnabled(_ on: Bool) async {
        guard enabled != on else { return }
        enabled = on
        d.set(on, forKey: Self.enabledKey)
        if on {
            status = "已开启 · 等待同步"
            await syncNow()
        } else {
            status = "未开启"
        }
    }

    /// 立即同步：先拉取云端合并到本地，再把本地推送回云端，保证两端一致。
    func syncNow() async {
        guard enabled, !syncing else { return }
        syncing = true
        defer { syncing = false }
        kv.synchronize()
        let (hist, fav) = pullFromCloud()
        pushToCloud()
        kv.synchronize()
        lastSync = Date()
        d.set(lastSync, forKey: "stv.cloud.lastSync")
        if hist > 0 || fav > 0 {
            status = "已合并（\(hist) 条历史记录，\(fav) 部收藏）"
        } else {
            status = "已同步"
        }
    }

    private func applyExternalChange() {
        guard enabled else { return }
        let (hist, fav) = pullFromCloud()
        lastSync = Date()
        d.set(lastSync, forKey: "stv.cloud.lastSync")
        if hist > 0 || fav > 0 { status = "已合并（\(hist) 条历史记录，\(fav) 部收藏）" }
    }

    // MARK: Pull（云端 → 本地，合并）

    @discardableResult
    private func pullFromCloud() -> (Int, Int) {
        var hist = 0, fav = 0

        // 观看记录：按 updatedAt 合并，较新优先。
        if let data = kv.data(forKey: "stv.progress") {
            let local: [String: WatchProgress] = d.data(forKey: "stv.progress").flatMap { try? JSONDecoder().decode([String: WatchProgress].self, from: $0) } ?? [:]
            let cloud: [String: WatchProgress] = (try? JSONDecoder().decode([String: WatchProgress].self, from: data)) ?? [:]
            var merged = local
            for (k, v) in cloud {
                if let cur = merged[k] {
                    if v.updatedAt > cur.updatedAt { merged[k] = v }
                } else {
                    merged[k] = v
                }
            }
            if let out = try? JSONEncoder().encode(merged) { d.set(out, forKey: "stv.progress") }
            hist = merged.count
        }

        // 收藏（追剧）：按 id 去重合并，本地在前、云端新增追加。
        if let data = kv.data(forKey: "stv.favorites") {
            let local: [HGSeries] = d.data(forKey: "stv.favorites").flatMap { try? JSONDecoder().decode([HGSeries].self, from: $0) } ?? []
            let cloud: [HGSeries] = (try? JSONDecoder().decode([HGSeries].self, from: data)) ?? []
            var merged = local
            var seen = Set(local.map(\.id))
            for s in cloud where !seen.contains(s.id) { merged.append(s); seen.insert(s.id) }
            if let out = try? JSONEncoder().encode(merged) { d.set(out, forKey: "stv.favorites") }
            fav = merged.count
        }

        // 搜索历史：去重合并，最多 10 条。
        if let data = kv.data(forKey: "stv.searchHistory") {
            let local: [String] = d.stringArray(forKey: "stv.searchHistory") ?? []
            let cloud: [String] = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            var merged = local
            var seen = Set(local)
            for s in cloud where !seen.contains(s) { merged.append(s); seen.insert(s) }
            if let out = try? JSONEncoder().encode(Array(merged.prefix(10))) { d.set(out, forKey: "stv.searchHistory") }
        }

        // 首页片源顺序（默认主源）：云端非空则覆盖本地。
        if let data = kv.data(forKey: "stv.home.order") {
            if let cloud: [String] = try? JSONDecoder().decode([String].self, from: data), !cloud.isEmpty {
                d.set(cloud, forKey: "stv.home.order")
            }
        }

        pullScalars()

        LibraryStore.shared.reloadFromDisk()
        HomeSourceOrder.shared.reload()
        DanmakuSettings.shared.reloadFromDisk()
        return (hist, fav)
    }

    private func pullScalars() {
        if kv.object(forKey: "stv.dm.enabled") != nil { d.set(kv.bool(forKey: "stv.dm.enabled"), forKey: "stv.dm.enabled") }
        if let v = kv.string(forKey: "stv.dm.area") { d.set(v, forKey: "stv.dm.area") }
        if kv.object(forKey: "stv.dm.merge") != nil { d.set(kv.bool(forKey: "stv.dm.merge"), forKey: "stv.dm.merge") }
        if kv.object(forKey: "stv.dm.likes") != nil { d.set(kv.bool(forKey: "stv.dm.likes"), forKey: "stv.dm.likes") }
        if kv.object(forKey: "stv.dm.rows") != nil { d.set(Int(kv.longLong(forKey: "stv.dm.rows")), forKey: "stv.dm.rows") }
        if kv.object(forKey: "stv.dm.opacity") != nil { d.set(kv.double(forKey: "stv.dm.opacity"), forKey: "stv.dm.opacity") }
        if let v = kv.string(forKey: "stv.dm.speed") { d.set(v, forKey: "stv.dm.speed") }
        if let v = kv.string(forKey: "stv.dm.size") { d.set(v, forKey: "stv.dm.size") }
    }

    // MARK: Push（本地 → 云端）

    private func pushToCloud() {
        // 观看记录：仅同步最近 40 条（按最后观看时间）。
        if let data = d.data(forKey: "stv.progress"),
           let all: [String: WatchProgress] = try? JSONDecoder().decode([String: WatchProgress].self, from: data) {
            let recent = all.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
            var top: [String: WatchProgress] = [:]
            for p in recent { top[p.series.id] = p }
            if let out = try? JSONEncoder().encode(top) { kv.set(out, forKey: "stv.progress") }
        }
        for key in ["stv.favorites", "stv.searchHistory"] {
            if let data = d.data(forKey: key) { kv.set(data, forKey: key) }
        }
        if let arr = d.stringArray(forKey: "stv.home.order") {
            if let out = try? JSONEncoder().encode(arr) { kv.set(out, forKey: "stv.home.order") }
        }
        pushScalars()
    }

    private func pushScalars() {
        if let v = d.object(forKey: "stv.dm.enabled") as? Bool { kv.set(v, forKey: "stv.dm.enabled") }
        if let v = d.object(forKey: "stv.dm.area") as? String { kv.set(v, forKey: "stv.dm.area") }
        if let v = d.object(forKey: "stv.dm.merge") as? Bool { kv.set(v, forKey: "stv.dm.merge") }
        if let v = d.object(forKey: "stv.dm.likes") as? Bool { kv.set(v, forKey: "stv.dm.likes") }
        if let v = d.object(forKey: "stv.dm.rows") as? Int { kv.set(Int64(v), forKey: "stv.dm.rows") }
        if let v = d.object(forKey: "stv.dm.opacity") as? Double { kv.set(v, forKey: "stv.dm.opacity") }
        if let v = d.object(forKey: "stv.dm.speed") as? String { kv.set(v, forKey: "stv.dm.speed") }
        if let v = d.object(forKey: "stv.dm.size") as? String { kv.set(v, forKey: "stv.dm.size") }
    }
}
