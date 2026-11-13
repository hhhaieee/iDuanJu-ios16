import Foundation
import Combine

/// 全局网络代理设置（HTTP / SOCKS5）。作用于 App 内的 URLSession 网络层（站点抓取、封面、
/// 红果/黄果接口、插件与本地视频转发代理等）。
/// 配置存 UserDefaults；由于各 URLSession 在启动时创建，改动后需重启 App 生效。
final class ProxySettings: ObservableObject {
    static let shared = ProxySettings()

    enum Kind: String, CaseIterable, Identifiable {
        case http = "HTTP 代理"
        case socks5 = "SOCKS5"
        var id: String { rawValue }
    }

    @Published var enabled: Bool { didSet { persist() } }
    @Published var kind: Kind { didSet { persist() } }
    @Published var host: String { didSet { persist() } }
    @Published var port: String { didSet { persist() } }

    private let d = UserDefaults.standard
    private init() {
        enabled = d.bool(forKey: "stv.proxy.enabled")
        kind = Kind(rawValue: d.string(forKey: "stv.proxy.kind") ?? "") ?? .http
        host = d.string(forKey: "stv.proxy.host") ?? ""
        port = d.string(forKey: "stv.proxy.port") ?? ""
    }

    private func persist() {
        d.set(enabled, forKey: "stv.proxy.enabled")
        d.set(kind.rawValue, forKey: "stv.proxy.kind")
        d.set(host, forKey: "stv.proxy.host")
        d.set(port, forKey: "stv.proxy.port")
    }

    /// 解析出有效的 (host, port)。支持把端口写在 host 字段里（如 `127.0.0.1:7890`），
    /// 也支持独立 port 字段；去掉 `http://` 前缀与 IPv6 方括号。
    private var resolved: (host: String, port: Int)? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        var p = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        // host 末尾若带 :port 则优先采用（127.0.0.1:7890 / [::1]:7890）。
        if let colon = h.lastIndex(of: ":"), colon > h.startIndex, let v = Int(h[h.index(after: colon)...]) {
            p = v
            h = String(h[..<colon])
        }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty, let port = p, (1...65535).contains(port) else { return nil }
        return (h, port)
    }

    /// 当前生效的 connectionProxyDictionary；未启用或地址/端口无效时返回 nil。
    var connectionProxyDictionary: [AnyHashable: Any]? {
        guard enabled, let r = resolved else { return nil }
        var dict: [AnyHashable: Any] = [:]
        switch kind {
        case .http:
            dict["HTTPEnable"] = 1
            dict["HTTPProxy"] = r.host
            dict["HTTPPort"] = r.port
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = r.host
            dict["HTTPSPort"] = r.port
        case .socks5:
            dict["SOCKSEnable"] = 1
            dict["SOCKSProxy"] = r.host
            dict["SOCKSProxyPort"] = r.port
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = r.host
            dict["HTTPSPort"] = r.port
        }
        return dict
    }

    /// 把代理应用到某个 URLSessionConfiguration（未启用时不动，保留调用方自己的代理设置）。
    func apply(to c: URLSessionConfiguration) {
        if let proxy = connectionProxyDictionary {
            c.connectionProxyDictionary = proxy
        }
    }
}
