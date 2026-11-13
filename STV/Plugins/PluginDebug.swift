import Foundation

#if DEBUG
/// Simulator / UI-test hooks (DEBUG only; nothing here exists in Release):
/// - `STV_PLUGINS_RESET=1` wipes installed plugins + 采集站 first.
/// - `STV_PLUGINS=bundled` installs the bundled `.idjplugin`s (non-adult ones unless `STV_PLUGINS_ADULT=1`).
/// - `STV_PLUGIN_DEMO=1` installs a neutral demo comic plugin (example domains, used for screenshots).
/// - `STV_CMS_FIXTURE=1` adds a fixture 采集站 answered offline by `PluginFixtures` (neutral titles, solid-color covers).
/// - `STV_PLUGIN_CONSENT_DEMO=1` opens the update consent sheet for the demo plugin (permission diff screenshot).
enum DebugPlugins {
    static let demoID = "com.example.demo.comics"

    static func demoManifest(version: String, extra: Bool) -> [String: Any] {
        var http = ["demo-comics.example.com"]
        if extra { http.append("cdn.demo-comics.example.net") }
        return ["schema": 1, "id": demoID, "name": "示例漫画（演示）", "version": version, "author": ["name": "i短剧示例"],
                "description": "演示用的全年龄漫画插件：只访问示例域名，用来展示安装 / 权限 / 更新流程。",
                "type": "comic", "adult": false, "language": ["zh"], "minAppVersion": "1.5", "entry": "main.js",
                "permissions": ["http": http, "media": http, "cloudflare": extra, "storage": true, "login": false],
                "capabilities": ["home", "category", "search", "detail", "pages"],
                "settings": [["key": "lang", "name": "语言", "type": "select", "default": "简体", "options": ["简体", "繁體"]]]]
    }
    static let demoJS = """
    export default {
      async home() { return { categories: [{ id: 'new', name: '最新' }], items: [] }; },
      async category() { return { items: [], hasMore: false }; },
      async search() { return { items: [], hasMore: false }; },
      async detail({ id }) { return { title: id, chapters: [] }; },
      async pages() { return { images: [] }; }
    };
    """

    static func demoBundle(version: String, extra: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["manifest": demoManifest(version: version, extra: extra), "files": ["main.js": demoJS]])) ?? Data()
    }

    static func demoPending(update: Bool) -> PendingInstall? {
        try? PluginInstaller.prepare(bundle: demoBundle(version: update ? "1.1.0" : "1.0.0", extra: update), origin: "https://demo-comics.example.com/plugin.idjplugin")
    }

    @MainActor static func seedIfRequested(_ store: PluginStore) {
        let env = ProcessInfo.processInfo.environment
        if env["STV_PLUGINS_RESET"] == "1" {
            for p in store.plugins { store.uninstall(p.id) }
            for s in CMSStore.shared.sites { CMSStore.shared.remove(s.key) }
            for s in store.subscriptions { store.removeSubscription(s.url) }
        }
        if env["STV_PLUGINS"] == "bundled" {
            let adult = env["STV_PLUGINS_ADULT"] == "1"
            for b in PluginInstaller.bundled() where adult || !b.manifest.adult {
                guard store.plugin(b.manifest.id) == nil else { continue }
                do { try store.commit(try PluginInstaller.prepare(bundle: b.data, origin: "bundled:" + b.name)) }
                catch { NSLog("[DebugPlugins] \(b.name): \(error)") }
            }
        }
        if env["STV_PLUGIN_DEMO"] == "1" || env["STV_PLUGIN_CONSENT_DEMO"] == "1", store.plugin(demoID) == nil, let p = demoPending(update: false) {
            try? store.commit(p)
            PluginLog.add(demoID, "200 GET demo-comics.example.com/ · 18342B · 212ms")
            PluginLog.add(demoID, "✕ 拦截 192.168.1.1 · 不允许直接访问 IP：192.168.1.1")
            PluginLog.add(demoID, "✕ 跳转被拦截 demo-comics.example.com → tracker.example.org")
        }
        if env["STV_CMS_FIXTURE"] == "1" { seedCMS() }
    }

    static let cmsAPI = "https://cms.demo.example.com/api.php/provide/vod/"

    @MainActor static func seedCMS() {
        let cats = [PluginCategory(id: "1", name: "电影"), PluginCategory(id: "2", name: "连续剧"), PluginCategory(id: "3", name: "综艺"), PluginCategory(id: "4", name: "动漫")]
        CMSStore.shared.debugInsert(CMSSite(key: CMSSite.key(for: cmsAPI), name: "示例采集站", api: cmsAPI, adult: false, categories: cats, origin: "fixture"))
        let colors = ["3a6ea5", "c0504d", "9bbb59", "8064a2", "4bacc6", "f79646", "2c4d75", "772c2a", "5f7530", "4d3b62", "276a7c", "b65708"]
        let names = ["山海之间", "城市夜跑", "雾中灯塔", "海边小镇", "星河旅人", "春日来信", "北方以北", "风起时", "长街", "归途", "晴天日记", "白鸟"]
        let list: [[String: Any]] = names.enumerated().map { i, n in
            ["vod_id": 1000 + i, "vod_name": n, "vod_pic": "fixture://\(colors[i % colors.count])", "vod_remarks": i % 3 == 0 ? "HD" : "更新至\(i + 8)集",
             "type_name": i % 2 == 0 ? "电影" : "连续剧", "vod_actor": "演员甲,演员乙", "vod_year": "2026", "vod_area": "大陆",
             "vod_content": "示例简介：这是离线测试数据。", "vod_play_from": "demo",
             "vod_play_url": "第1集$https://cdn.demo.example.com/\(i)/1.m3u8#第2集$https://cdn.demo.example.com/\(i)/2.m3u8"]
        }
        let body: [String: Any] = ["code": 1, "page": 1, "pagecount": 1, "total": list.count,
                                   "class": cats.map { ["type_id": Int($0.id)!, "type_name": $0.name] }, "list": list]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let previous = PluginFixtures.responder
        PluginFixtures.responder = { req in
            if req.url?.host == "cms.demo.example.com" { return PluginFixtures.Reply(headers: ["content-type": "application/json"], body: data) }
            return previous?(req)
        }
    }
}
#endif
