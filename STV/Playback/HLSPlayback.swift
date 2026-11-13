import AVFoundation

/// Plays huangguo HLS (incl. AES-128) through AVPlayer.
/// Playlists are fetched through a resourceLoader so we can attach Referer/Origin/X-User-Agent,
/// and EXT-X-KEY URIs are rewritten to a local scheme that serves the key we already resolved.
final class HLSPlayback: NSObject, AVAssetResourceLoaderDelegate {
    static let plScheme = "stvhls"
    static let keyScheme = "stvkey"

    let headers: [String: String]
    let keyHex: String
    private let queue = DispatchQueue(label: "stv.hls.loader")
    private let session = URLSession(configuration: .default)

    init(headers: [String: String], keyHex: String) {
        self.headers = headers
        self.keyHex = keyHex
    }

    func makeAsset(url: String) -> AVURLAsset? {
        guard var c = URLComponents(string: url) else { return nil }
        let isHLS = url.lowercased().contains(".m3u8") || url.contains("/m3u8/")
        if isHLS { c.scheme = c.scheme == "http" ? Self.plScheme + "-http" : Self.plScheme }
        guard let u = c.url else { return nil }
        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        if isHLS { asset.resourceLoader.setDelegate(self, queue: queue) }
        return asset
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = req.request.url, let scheme = url.scheme else { return false }
        if scheme == Self.keyScheme {
            guard let key = Bytes.fromHex(keyHex), key.count == 16 else {
                if !req.isCancelled && !req.isFinished { req.finishLoading(with: URLError(.userAuthenticationRequired)) }
                return true
            }
            // 请求可能在回调执行前已被取消（返回/切换视频），此时 finish 会触发 AVFoundation 异常崩溃。
            if !req.isCancelled && !req.isFinished {
                req.contentInformationRequest?.contentType = "public.data"
                req.contentInformationRequest?.contentLength = 16
                req.contentInformationRequest?.isByteRangeAccessSupported = false
                req.dataRequest?.respond(with: Data(key))
                req.finishLoading()
            }
            return true
        }
        guard scheme.hasPrefix(Self.plScheme), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        c.scheme = scheme.hasSuffix("-http") ? "http" : "https"
        guard let real = c.url else { return false }
        var r = URLRequest(url: real)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        session.dataTask(with: r) { [weak self] data, resp, err in
            // 返回/切季时 AVPlayer 会取消所有 pending 的 resource 请求，回调晚到时
            // 再 finish 会抛 NSException（SIGABRT）。先做取消/完成防御检查。
            guard !req.isCancelled && !req.isFinished else { return }
            guard let self, let data, err == nil, (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                req.finishLoading(with: err ?? URLError(.badServerResponse)); return
            }
            let text = self.rewrite(HLSAdFilter.apply(String(decoding: data, as: UTF8.self), base: real), base: real)
            req.contentInformationRequest?.contentType = "public.m3u-playlist"
            req.contentInformationRequest?.contentLength = Int64(text.utf8.count)
            req.dataRequest?.respond(with: Data(text.utf8))
            req.finishLoading()
        }.resume()
        return true
    }

    /// Absolutize URIs; nested playlists go back through the loader, keys go to the local key scheme.
    private func rewrite(_ pl: String, base: URL) -> String {
        func abs(_ s: String) -> URL? { URL(string: s, relativeTo: base)?.absoluteURL }
        func via(_ u: URL, _ scheme: String) -> String {
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.scheme = scheme == Self.plScheme && u.scheme == "http" ? Self.plScheme + "-http" : scheme
            return c?.url?.absoluteString ?? u.absoluteString
        }
        var expectPlaylist = false
        return pl.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("#EXT-X-STREAM-INF") { expectPlaylist = true; return line }
            if line.uppercased().hasPrefix("#EXT-X-KEY") || line.uppercased().hasPrefix("#EXT-X-MEDIA") || line.uppercased().hasPrefix("#EXT-X-MAP") {
                let isKey = line.uppercased().hasPrefix("#EXT-X-KEY")
                guard let m = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", line), let u = abs(m[1]) else { return line }
                let repl: String
                if isKey { repl = keyHex.isEmpty ? u.absoluteString : Self.keyScheme + "://key" }
                else if line.uppercased().hasPrefix("#EXT-X-MEDIA") { repl = via(u, Self.plScheme) }
                else { repl = u.absoluteString }
                return line.replacingOccurrences(of: m[1], with: repl)
            }
            if line.isEmpty || line.hasPrefix("#") { return line }
            guard let u = abs(line) else { return line }
            defer { expectPlaylist = false }
            return expectPlaylist || u.path.lowercased().hasSuffix(".m3u8") ? via(u, Self.plScheme) : u.absoluteString
        }.joined(separator: "\n")
    }
}
