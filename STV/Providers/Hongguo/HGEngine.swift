import Foundation
import CQuickJS

/// 红果取流引擎：在 QuickJS 沙箱里直接运行上游已验证可播放的 hongguo.js（THL/jackotom
/// hongguo-drama 血统，GPL-3.0）。Swift 侧不再重写签名/设备注册，只提供受限 fetch polyfill，
/// 从而彻底规避 Swift 移植中 x-medusa / 请求头 / body 字节 / rticket 等任一处的细节偏差。
///
/// 取流链路（全部在 JS bundle 内完成）：
///   设备注册 device_register -> 签名 -> POST multi_video_model -> 解析 variants -> HEAD 探活。
/// 宿主只做两件事：把 fetch(method/headers/body) 同步发成网络请求（强制直连）；把响应包装成
/// Response 形态（status / headers.get / text）返回给 JS 的 async/await。
enum HGEngine {
    struct Stream {
        let url: String
        let quality: String
        let header: [String: String]
        let expiresAt: TimeInterval
        let contentKey: String
    }

    enum Failure: LocalizedError {
        case boot(String)
        case call(String)
        case badOutput
        var errorDescription: String? {
            switch self {
            case .boot(let m): return "红果引擎初始化失败: \(m)"
            case .call(let m): return "红果引擎调用失败: \(m)"
            case .badOutput: return "红果引擎输出无法解析"
            }
        }
    }

    // MARK: - 同步网络层
    // 取流域名（log.snssdk.com / api5-normal-sinfonlineb.fqnovel.com / vas-lf-x.snssdk.com）
    // 在部分网络下直连不通或被限速，必须与搜索走同一出口：跟随 App 代理配置。
    // 三次诊断证明：搜索（跟随代理）毫秒级，取流（强制直连）80–200s，与签名/引擎实现无关。

    private static let netSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        ProxySettings.shared.apply(to: c)
        return URLSession(configuration: c)
    }()

    /// hostFn: name="http.request"，args=JSON {url,method,headers,body,redirect,timeoutMs}。
    /// 返回 JSON {status,headers,bodyBase64,url}；重定向按 manual 交给 JS 处理（返回 3xx + location）。
    private static let hostFn: idj_host_fn = { opaque, name, args, isErr in
        guard let name, let args else {
            isErr?.pointee = 1
            return strdup("{\"code\":\"E_HOST\",\"message\":\"nil host args\"}")
        }
        let n = String(cString: name)
        guard n == "http.request" else {
            isErr?.pointee = 1
            return strdup("{\"code\":\"E_UNSUPPORTED\",\"message\":\"\(n)\"}")
        }
        let a = (try? JSONSerialization.jsonObject(with: Data(String(cString: args).utf8), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        do {
            let r = try performRequest(a)
            let d = try JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed])
            return strdup(String(decoding: d, as: UTF8.self))
        } catch let e as Failure {
            isErr?.pointee = 1
            return strdup("{\"code\":\"E_NETWORK\",\"message\":\"\(e.errorDescription ?? "network")\"}")
        } catch {
            isErr?.pointee = 1
            return strdup("{\"code\":\"E_NETWORK\",\"message\":\"\(error)\"}")
        }
    }

    private static func performRequest(_ a: [String: Any]) throws -> [String: Any] {
        guard let url = URL(string: a["url"] as? String ?? "") else { throw Failure.call("地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = (a["method"] as? String ?? "GET").uppercased()
        let ms = a["timeoutMs"] as? Int ?? 12_000
        req.timeoutInterval = min(max(Double(ms) / 1000, 1), 30)
        if let hs = a["headers"] as? [String: Any] {
            for (k, v) in hs { req.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if let body = a["body"] as? String { req.httpBody = Data(body.utf8) }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(Failure.call("no response"))
        let task = netSession.dataTask(with: req) { d, r, e in
            if let e { result = .failure(e) }
            else if let h = r as? HTTPURLResponse { result = .success((d ?? Data(), h)) }
            sem.signal()
        }
        task.resume()
        sem.wait()
        switch result {
        case .failure(let e): throw Failure.call("\(url.host ?? "")：\(e.localizedDescription)")
        case .success((let data, let http)):
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k.lowercased()] = "\(v)" } }
            let ct = headers["content-type"] ?? ""
            let text = Self.decodeText(data, contentType: ct)
            return ["status": http.statusCode, "headers": headers,
                    "bodyText": text, "url": http.url?.absoluteString ?? url.absoluteString]
        }
    }

    private static func decodeText(_ d: Data, contentType: String) -> String {
        let ct = contentType.lowercased()
        if ct.contains("gbk") || ct.contains("gb2312") || ct.contains("gb18030") {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let s = String(data: d, encoding: enc) { return s }
        }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: - QuickJS 沙箱

    private static let thread = PluginThread(name: "hg.engine")
    private static var box: OpaquePointer?
    private static var bootFailure: String?
    private static var started = false
    private static let gate = NSLock()

    private static let prelude = """
    (function (h) {
      'use strict';
      const call = (n, a) => { const r = h(n, JSON.stringify(a === undefined ? null : a)); return r == null ? undefined : JSON.parse(r); };
      // bundle 用全局 fetch：把 host 的同步 http.request 包装成 Promise<Response>。
      // Swift 侧已把响应体按 Content-Type 解码为文本，text()/json() 直接用，零解码偏差。
      globalThis.fetch = function (url, opt) {
        opt = opt || {};
        const a = { url: String(url), method: opt.method || 'GET', headers: opt.headers || {},
                    redirect: opt.redirect || 'follow', timeoutMs: opt.timeoutMs || 12000 };
        if (opt.body !== undefined && opt.body !== null) {
          a.body = (typeof opt.body === 'string') ? opt.body : String(opt.body);
        }
        let r;
        try { r = call('http.request', a); }
        catch (e) { return Promise.reject(e); }
        if (!r) return Promise.reject(new Error('empty fetch response'));
        const lower = {}; const hs = r.headers || {};
        for (const k of Object.keys(hs)) lower[k.toLowerCase()] = hs[k];
        const bodyText = r.bodyText || '';
        const response = {
          status: r.status,
          url: r.url || String(url),
          headers: { get: (k) => { const v = lower[String(k).toLowerCase()]; return v === undefined ? null : v; } },
          text: async () => bodyText,
          json: async () => JSON.parse(bodyText),
        };
        return Promise.resolve(response);
      };
    })(globalThis.__host);
    delete globalThis.__host;
    """

    private static let adapter = """
    globalThis.__hgPlay = async function(arg) {
      const App = globalThis.HongguoApp;
      const r = await App.fetchAppPlayUrl(arg.vid, {
        deadline: Date.now() + 120000, refreshModel: false, includeFallback: true,
        quality: arg.quality || 0
      });
      const variants = r && r.variants ? r.variants : [r];
      const out = [];
      for (const v of variants) {
        if (!v || !v.url) continue;
        out.push({ url: String(v.url), quality: String(v.quality || ''),
                   header: v.header || (v.userAgent ? {'User-Agent': v.userAgent} : {}),
                   expiresAt: Number(v.expiresAt) || 0, contentKey: String(v.contentKey || '') });
      }
      return JSON.stringify({ streams: out });
    };
    """

    private static func scriptURL() -> URL? {
        if let u = Bundle.main.url(forResource: "hongguo_app", withExtension: "js") { return u }
        for b in Bundle.allBundles where b !== Bundle.main {
            if let u = b.url(forResource: "hongguo_app", withExtension: "js") { return u }
        }
        return nil
    }

    private static func bootedBox() throws -> OpaquePointer {
        if let b = box { return b }
        if let f = bootFailure { throw Failure.boot(f) }
        // bundle 用了 eval 吗？未使用；但保留 with_eval 以兼容其可能的动态代码。
        guard let b = idj_new_with_eval(256 << 20, 8 << 20, hostFn, nil) else {
            bootFailure = "QuickJS 运行时创建失败"
            throw Failure.boot(bootFailure!)
        }
        var err: UnsafeMutablePointer<CChar>?
        guard idj_eval_script(b, prelude, 10, &err) != nil else {
            let m = err.map { String(cString: $0) } ?? "prelude 失败"
            if let err { idj_str_free(err) }
            idj_free(b); bootFailure = m; throw Failure.boot(m)
        }
        guard let src = scriptURL().flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            bootFailure = "hongguo_app.js 资源缺失"
            idj_free(b); throw Failure.boot(bootFailure!)
        }
        guard idj_eval_script(b, src, 40, &err) != nil else {
            let m = err.map { String(cString: $0) } ?? "bundle 加载失败"
            if let err { idj_str_free(err) }
            idj_free(b); bootFailure = m; throw Failure.boot(m)
        }
        guard idj_eval_script(b, adapter, 10, &err) != nil else {
            let m = err.map { String(cString: $0) } ?? "adapter 失败"
            if let err { idj_str_free(err) }
            idj_free(b); bootFailure = m; throw Failure.boot(m)
        }
        box = b
        return b
    }

    /// 自检：确认 bundle 已加载且 HongguoApp 暴露了取流接口（不发网络请求）。
    static func selfCheck() async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            gate.lock(); if !started { thread.start(); started = true }; gate.unlock()
            thread.enqueue {
                do {
                    let b = try bootedBox()
                    var err: UnsafeMutablePointer<CChar>?
                    let src = "JSON.stringify(Object.keys(globalThis.HongguoApp || {}))"
                    guard let r = idj_eval_script(b, src, 10, &err) else {
                        let m = err.map { String(cString: $0) } ?? "selfCheck 失败"
                        if let err { idj_str_free(err) }
                        cont.resume(throwing: Failure.call(m)); return
                    }
                    let s = String(cString: r); idj_str_free(r)
                    let outer = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? String ?? s
                    let keys = try JSONSerialization.jsonObject(with: Data(outer.utf8)) as? [String] ?? []
                    cont.resume(returning: keys)
                } catch let e as Failure {
                    cont.resume(throwing: e)
                } catch {
                    cont.resume(throwing: Failure.call(String(describing: error)))
                }
            }
        }
    }

    /// 取流：返回可直接喂给播放器的流列表。
    static func playUrl(vid: String, quality: Int = 0) async throws -> [Stream] {
        try await withCheckedThrowingContinuation { cont in
            gate.lock()
            if !started { thread.start(); started = true }
            gate.unlock()
            thread.enqueue {
                do {
                    let b = try bootedBox()
                    let arg: [String: Any] = ["vid": vid, "quality": quality]
                    let argJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: arg)) ?? Data("{}".utf8), as: UTF8.self)
                    var err: UnsafeMutablePointer<CChar>?
                    guard let raw = idj_eval_script(b, "__hgPlay(\(argJSON))", 200, &err) else {
                        let m = err.map { String(cString: $0) } ?? "调用失败"
                        if let err { idj_str_free(err) }
                        cont.resume(throwing: Failure.call(m)); return
                    }
                    let s = String(cString: raw); idj_str_free(raw)
                    // idj_eval_script 返回完成值的 JSON 文本；await 后是 __hgPlay 的 JSON 字符串。
                    let outer = try JSONSerialization.jsonObject(with: Data(s.utf8))
                    let inner: String
                    if let str = outer as? String { inner = str }
                    else { inner = s }
                    guard let d = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
                          let arr = d["streams"] as? [[String: Any]] else {
                        cont.resume(throwing: Failure.badOutput); return
                    }
                    let streams: [Stream] = arr.compactMap { x in
                        guard let url = x["url"] as? String, !url.isEmpty else { return nil }
                        let exp = (x["expiresAt"] as? NSNumber)?.doubleValue ?? 0
                        return Stream(url: url,
                                      quality: x["quality"] as? String ?? "",
                                      header: x["header"] as? [String: String] ?? [:],
                                      expiresAt: exp,
                                      contentKey: x["contentKey"] as? String ?? "")
                    }
                    cont.resume(returning: streams)
                } catch let e as Failure {
                    cont.resume(throwing: e)
                } catch {
                    cont.resume(throwing: Failure.call(String(describing: error)))
                }
            }
        }
    }
}
