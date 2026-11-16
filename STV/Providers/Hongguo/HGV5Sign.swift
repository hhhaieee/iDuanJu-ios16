import Foundation
import CQuickJS

/// 红果 V5 本地签名（THL/jackotom hongguo-drama 血统，GPL-3.0，资源内嵌签名档案）。
///
/// hgv5sign.js 是纯浏览器向 webpack bundle（自带 Buffer/CryptoJS），在 QuickJS 沙箱里自举后暴露
/// globalThis.__hongguoLocalSign。真正的 x-medusa 签名由内置签名档案（id+material）算出，
/// x-argus/x-ladon/x-gorgon/x-helios 为配套头。自举与签名全程在本枚举的专用线程串行执行。
enum HGV5Sign {
    struct Device {
        let iid: String
        let deviceId: String
        let cdid: String
    }

    enum Failure: LocalizedError {
        case boot(String)
        case sign(String)
        case badOutput
        var errorDescription: String? {
            switch self {
            case .boot(let m): return "V5 签名器初始化失败: \(m)"
            case .sign(let m): return "V5 签名失败: \(m)"
            case .badOutput: return "V5 签名输出无法解析"
            }
        }
    }

    private static let thread = PluginThread(name: "hg.v5sign")
    private static var box: OpaquePointer?
    private static var bootFailure: String?
    private static var started = false
    private static let gate = NSLock()

    /// 宿主回调：签名脚本不调用任何宿主能力。
    private static let hostFn: idj_host_fn = { _, _, _, _ in nil }

    static var scriptURL: URL? {
        if let u = Bundle.main.url(forResource: "hgv5sign", withExtension: "js") { return u }
        for b in Bundle.allBundles where b !== Bundle.main {
            if let u = b.url(forResource: "hgv5sign", withExtension: "js") { return u }
        }
        return nil
    }

    /// 在签名线程上确保沙箱已就绪（幂等）。
    private static func bootedBox() throws -> OpaquePointer {
        if let b = box { return b }
        if let f = bootFailure { throw Failure.boot(f) }
        guard let b = idj_new(64 << 20, 2 << 20, hostFn, nil) else {
            bootFailure = "QuickJS 运行时创建失败"
            throw Failure.boot(bootFailure!)
        }
        // 加载签名 bundle（302KB，一次性）。单元测试环境下资源可能在测试宿主之外的 bundle 里，逐个回退。
        guard let src = Self.scriptURL.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            bootFailure = "hgv5sign.js 资源缺失"
            idj_free(b)
            throw Failure.boot(bootFailure!)
        }
        var err: UnsafeMutablePointer<CChar>?
        guard idj_eval_script(b, src, 30, &err) != nil else {
            let m = err.map { String(cString: $0) } ?? "未知错误"
            if let err { idj_str_free(err) }
            idj_free(b)
            bootFailure = m
            throw Failure.boot(m)
        }
        // 包一层适配：Swift 侧把 body 以 base64 传入（JSC/QuickJS 沙箱里没有 Buffer 全局）。
        // __hongguoLocalSign 内部对 body 只做 body==null 判断和 body.toString('base64')。
        let wrapper = """
        globalThis.__hgV5Sign = function(a) {
          var body = (a.bodyB64 == null) ? null : { toString: function() { return a.bodyB64; } };
          return JSON.stringify(globalThis.__hongguoLocalSign(a.url, body, a.epoch, a.device));
        };
        """
        guard idj_eval_script(b, wrapper, 5, &err) != nil else {
            let m = err.map { String(cString: $0) } ?? "wrapper 安装失败"
            if let err { idj_str_free(err) }
            idj_free(b)
            bootFailure = m
            throw Failure.boot(m)
        }
        box = b
        return b
    }

    /// 对一次取流请求产出全套签名头（x-gorgon / x-khronos / x-ladon / x-argus / x-helios / x-medusa）。
    /// - Parameters:
    ///   - url: 完整请求地址（含 query，与 wire 上发送的逐字节一致）。
    ///   - bodyBase64: 请求体 wire 字节的 base64；GET（无 body）传 nil。
    ///   - epoch: 秒级时间戳（x-khronos）。
    ///   - device: 注册设备身份（device_id 会进入签名 proto）。
    static func sign(url: String, bodyBase64: String?, epoch: UInt32, device: Device) throws -> [String: String] {
        gate.lock()
        defer { gate.unlock() }
        if !started { thread.start(); started = true }

        let args: [String: Any] = [
            "url": url,
            "bodyB64": bodyBase64 ?? NSNull(),
            "epoch": UInt64(epoch),
            "device": ["iid": device.iid, "device_id": device.deviceId, "cdid": device.cdid],
        ]
        let argJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
        let snippet = "__hgV5Sign(\(argJSON))"

        let sem = DispatchSemaphore(value: 0)
        var out: [String: String]?
        var failure: Failure?
        thread.enqueue {
            do {
                let b = try bootedBox()
                var err: UnsafeMutablePointer<CChar>?
                guard let r = idj_eval_script(b, snippet, 10, &err) else {
                    let m = err.map { String(cString: $0) } ?? "未知错误"
                    if let err { idj_str_free(err) }
                    failure = .sign(m)
                    sem.signal()
                    return
                }
                let s = String(cString: r)
                idj_str_free(r)
                // idj_eval_script 返回完成值的 JSON 文本；我们的完成值本身是 JSON 字符串。
                guard let outer = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
                      let inner = outer as? String,
                      let dict = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: String] else {
                    failure = .badOutput
                    sem.signal()
                    return
                }
                out = dict
            } catch let e as Failure {
                failure = e
            } catch {
                failure = .sign(String(describing: error))
            }
            sem.signal()
        }
        sem.wait()
        if let failure { throw failure }
        guard let out else { throw Failure.badOutput }
        return out
    }
}
