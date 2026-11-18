import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Downloads the episode currently playing into a standalone MP4 in the app's Downloads folder,
/// so it shows up in 下载管理 (TGDownloads) and can be saved to the photo library.
///
/// Two stream families:
/// - Progressive MP4 (红果 clear/CENC, most sites): download the body, locally decrypt CENC, write MP4.
/// - HLS / AES-128 (黄果 etc.): 直下分片 → 本地 AES-128 解密 → 拼接明文 TS → 从本地文件 remux 成 MP4。
///   不再让 AVAssetExportSession 经 LocalHLSProxy 读加密流：iOS 16 对「代理 + 带外 key + 多段 m3u8」的
///   时序极不可靠（上游 m3u8/key/TS 与 ffmpeg 均正常，问题只在导出环节）。解密搬到本地后导出器只读
///   一个本地明文 TS，彻底绕开代理时序。
enum VideoDownloadService {

    enum DownloadError: LocalizedError {
        case noStream, badURL, emptyData, exportFailed(String), cancelled
        var errorDescription: String? {
            switch self {
            case .noStream: return "没有可用的视频流"
            case .badURL: return "视频地址无效"
            case .emptyData: return "下载内容为空"
            case .exportFailed(let m): return "导出失败：\(m)"
            case .cancelled: return "下载已暂停"
            }
        }
    }

    /// Resolve the episode, pick a stream, download/decrypt to a standalone MP4, return its URL.
    /// - progress: 0...1 进度回调（节流到每 256KB 一次），用于下载管理里显示进度。
    /// 取消通过 Task.checkCancellation()：coordinator 持有 Task，暂停/删除时 cancel 即可。
    static func download(series: HGSeries, episode: HGEpisode,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let resolved = try await Catalog.resolve(series, episode)
        try Task.checkCancellation()
        if let e = resolved.err, resolved.streams.isEmpty { throw ProviderError.upstream(e) }
        guard let stream = resolved.streams.first else { throw DownloadError.noStream }

        let dir = TGDownloads.dir
        let base = "video-\(series.id)-\(episode.id)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let dest = dir.appendingPathComponent(base + ".mp4")
        try? FileManager.default.removeItem(at: dest)

        switch stream.kind {
        case .mp4Cenc, .mp4Clear:
            var data = try await fetch(stream, progress: progress)
            guard !data.isEmpty else { throw DownloadError.emptyData }
            try Task.checkCancellation()
            if !stream.key.isEmpty {
                var bytes = [UInt8](data)
                _ = try CENCDecryptor.decrypt(&bytes, keyHex: stream.key)
                data = Data(bytes)
            }
            try data.write(to: dest, options: .atomic)
        case .hls, .hlsAES:
            try await exportHLS(stream, to: dest, progress: progress)
        }

        guard FileManager.default.fileExists(atPath: dest.path) else { throw DownloadError.emptyData }
        return dest
    }

    /// HTTP download with the stream's headers, backup-URL retry and chunked progress.
    private static func fetch(_ stream: HGStream, progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        func get(_ u: URL) async throws -> Data {
            var req = URLRequest(url: u, timeoutInterval: 30)
            req.allHTTPHeaderFields = stream.headers
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw ProviderError.upstream("HTTP \(code)") }
            let expected = (resp as? HTTPURLResponse)?.expectedContentLength ?? -1
            var data = Data()
            var lastReport = 0
            for try await chunk in bytes {
                try Task.checkCancellation()
                data.append(chunk)
                if let progress, expected > 0 {
                    let pct = Int(Double(data.count) / Double(expected) * 100)
                    if pct >= lastReport + 5 { lastReport = pct; progress(min(1, Double(pct) / 100)) }
                }
            }
            progress?(1)
            return data
        }
        guard let u = URL(string: stream.url) else { throw DownloadError.badURL }
        do { return try await get(u) }
        catch is CancellationError { throw DownloadError.cancelled }
        catch {
            if let backup = stream.backupURL { return try await get(backup) }
            throw error
        }
    }

    /// 直下 HLS 分片 → 本地 AES-128 解密 → 每片独立落盘 → 生成本地 m3u8 → 系统按 HLS 语义重编码导出 MP4。
    /// 关键：不再把多个分片拼成一个裸 TS。黄果等源的分片是 fMP4/CMAF（moof+mdat box），拼接后缺 init 段，
    /// AVAssetReader 会以 -11828 FormatNotRecognized 打不开。保留分片边界并让 AVFoundation 按 m3u8 语义读取，
    /// TS 与 fMP4 都能正确处理。
    private static func exportHLS(_ stream: HGStream, to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let playlistURL = URL(string: stream.url) else { throw DownloadError.badURL }

        // 1) 拉 playlist（master → 码率最高的 variant）+ 广告过滤。
        var text = String(decoding: try await fetchBytes(playlistURL, headers: stream.headers), as: UTF8.self)
        if !text.localizedCaseInsensitiveContains("#EXTINF"),
           let variant = pickVariant(text, base: playlistURL) {
            text = String(decoding: try await fetchBytes(variant, headers: stream.headers), as: UTF8.self)
        }
        text = HLSAdFilter.apply(text, base: playlistURL)
        if Task.isCancelled { throw DownloadError.cancelled }

        // 2) 解析 KEY / MEDIA-SEQUENCE / EXT-X-MAP / 分片行（带时长与原始序号用于 IV）。
        var seqBase: Int64 = 0
        var explicitIV: Data?
        var keyURI: URL?
        var method = ""
        var initURI: URL?
        var initRange: ClosedRange<Int>?
        struct Seg { let url: URL; let duration: Double; let sequence: Int64 }
        var segments: [Seg] = []
        var expectSegment = false
        var pendingDuration = 6.0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let up = line.uppercased()
            if up.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                seqBase = Int64(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            } else if up.hasPrefix("#EXT-X-KEY") {
                method = HTML.groups("METHOD\\s*=\\s*([A-Za-z0-9-]+)", line).map { $0[1].uppercased() } ?? "AES-128"
                if let m = HTML.groups("IV\\s*=\\s*(?:0[xX])?([0-9a-fA-F]{32})", line),
                   let b = Bytes.fromHex(m[1]), b.count == 16 { explicitIV = Data(b) }
                if let m = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", line),
                   let u = URL(string: m[1], relativeTo: playlistURL)?.absoluteURL { keyURI = u }
            } else if up.hasPrefix("#EXT-X-MAP") {
                if let m = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", line),
                   let u = URL(string: m[1], relativeTo: playlistURL)?.absoluteURL { initURI = u }
                if let m = HTML.groups("BYTERANGE\\s*=\\s*\"(\\d+)@(\\d+)\"", line),
                   let len = Int(m[1]), let off = Int(m[2]), len > 0 { initRange = off...(off + len - 1) }
            } else if up.hasPrefix("#EXTINF") {
                let v = line.split(separator: ":").last?.split(separator: ",").first ?? ""
                pendingDuration = Double(v) ?? 6.0
                expectSegment = true
            } else if !line.isEmpty, !line.hasPrefix("#"), expectSegment {
                expectSegment = false
                if let u = URL(string: line, relativeTo: playlistURL)?.absoluteURL {
                    // HLS 规范：无显式 IV 时，分片序号 = MEDIA-SEQUENCE + 播放列表内索引。
                    segments.append(Seg(url: u, duration: pendingDuration > 0 ? pendingDuration : 6.0,
                                        sequence: seqBase + Int64(segments.count)))
                }
                pendingDuration = 6.0
            }
        }
        guard !segments.isEmpty else { throw DownloadError.noStream }

        // 3) 密钥：优先 resolve 阶段已取到的 stream.key，否则按 KEY URI 取一次。
        var key: Data?
        if !stream.key.isEmpty, let b = Bytes.fromHex(stream.key), b.count == 16 { key = Data(b) }
        if key == nil, let ku = keyURI {
            let kd = try await fetchBytes(ku, headers: stream.headers)
            if kd.count == 16 { key = kd }
        }
        let encrypted = method == "AES-128" && key != nil
        // 不可变快照：供下方同步嵌套函数捕获，避免 async 上下文捕获可变 var 的并发告警。
        let finalKey = key, finalIV = explicitIV, isEncrypted = encrypted

        // 4) 逐片下载 → 去伪头 → AES-128-CBC 解密 → 每个分片独立落盘（保留分片边界，
        //    供本地 m3u8 按 HLS 语义读取；fMP4 分片靠 EXT-X-MAP 的 init 段还原容器）。
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        func segIV(_ sequence: Int64) -> Data {
            if let explicit = finalIV { return explicit }
            let s = sequence.bigEndian
            return Data(repeating: 0, count: 8) + withUnsafeBytes(of: s) { Data($0) }
        }
        // 解密后核对魔数：TS 以 0x47 起，fMP4/MP4 在偏移 4 处是 ftyp/moof/moov/styp/sidx。
        // 若解密结果不像媒体（说明该片本来就没加密或 IV 不对），退回未解密字节，避免把密文喂给系统。
        func looksLikeMedia(_ d: Data) -> Bool {
            let b = [UInt8](d.prefix(16))
            guard b.count >= 8 else { return false }
            if b[0] == 0x47 { return true }
            if b.count >= 12 {
                let tag = String(bytes: b[4..<8], encoding: .ascii) ?? ""
                if ["ftyp", "moof", "moov", "styp", "sidx", "free"].contains(tag) { return true }
            }
            return false
        }
        func decrypted(_ raw: Data, sequence: Int64) -> Data {
            let stripped = LocalHLSProxy.stripFakeHeader(raw)
            guard isEncrypted, let k = finalKey else { return stripped }
            if let clear = LocalHLSProxy.aesCBCDecrypt(stripped, key: k, iv: segIV(sequence)), looksLikeMedia(clear) {
                return clear
            }
            return stripped
        }

        // init segment（fMP4/CMAF 必需）：解析到的 EXT-X-MAP 单独下载解密并落盘。
        var initName: String?
        if let iu = initURI {
            let initData = try await fetchBytes(iu, headers: stream.headers)
            var payload = initData
            if let rg = initRange {
                let lo = max(0, rg.lowerBound)
                let hi = min(initData.count - 1, rg.upperBound)
                if lo <= hi { payload = initData.subdata(in: lo..<(hi + 1)) }
            }
            let clear = decrypted(payload, sequence: seqBase)
            let name = "init.mp4"
            try clear.write(to: tmpDir.appendingPathComponent(name))
            initName = name
        }

        let total = Double(segments.count)
        var segNames: [String] = []
        for (i, seg) in segments.enumerated() {
            if Task.isCancelled { throw DownloadError.cancelled }
            let raw = try await fetchBytes(seg.url, headers: stream.headers)
            let clear = decrypted(raw, sequence: seg.sequence)
            let isFMP4 = { () -> Bool in
                let b = [UInt8](clear.prefix(12))
                guard b.count >= 8, b[0] != 0x47 else { return false }
                let tag = String(bytes: b[4..<8], encoding: .ascii) ?? ""
                return ["ftyp", "moof", "styp", "sidx"].contains(tag)
            }()
            let name = String(format: "seg_%05d.%@", i, isFMP4 ? "m4s" : "ts")
            try clear.write(to: tmpDir.appendingPathComponent(name))
            segNames.append(name)
            progress?(0.05 + 0.85 * Double(i + 1) / total)
        }
        if Task.isCancelled { throw DownloadError.cancelled }

        // 5) 生成本地 m3u8：分片已解密，故不写 EXT-X-KEY；若有 init 段则补 EXT-X-MAP。
        var local = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:30\n"
        local += "#EXT-X-MEDIA-SEQUENCE:0\n"
        if let initName = initName { local += "#EXT-X-MAP:URI=\"\(initName)\"\n" }
        for (i, name) in segNames.enumerated() {
            local += "#EXTINF:\(String(format: "%.3f", segments[i].duration)),\n\(name)\n"
        }
        local += "#EXT-X-ENDLIST\n"
        let localPlist = tmpDir.appendingPathComponent("local.m3u8")
        try local.write(to: localPlist, atomically: true, encoding: .utf8)

        // 6) 关键：绝不把 file:// 的 m3u8 交给 AVFoundation——iOS16 会判 -11828 FormatNotRecognized。
        //    改为经 LocalHLSProxy 的 /x/<token>/ 路由以 http HLS 语义读取（在线播放同款、已验证可识别）。
        //    分片已全部解密落盘，代理只读本地文件，无网络时序问题。
        progress?(0.92)
        guard let serveBase = LocalHLSProxy.shared.serveLocalDir(tmpDir),
              let httpPlist = URL(string: serveBase + "local.m3u8") else {
            throw DownloadError.exportFailed("无法启动本地导出服务")
        }
        defer { LocalHLSProxy.shared.releaseLocalDir(serveBase) }
        let asset = AVURLAsset(url: httpPlist)
        var last: Error = DownloadError.exportFailed("未知导出错误")
        var exported = false
        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough] {
            if Task.isCancelled { throw DownloadError.cancelled }
            try? FileManager.default.removeItem(at: dest)
            guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            ex.outputURL = dest
            ex.outputFileType = .mp4
            ex.shouldOptimizeForNetworkUse = false
            do { try await ex.export() }
            catch is CancellationError { throw DownloadError.cancelled }
            catch { last = error; continue }
            if ex.status == .completed { exported = true; break }
            last = ex.error ?? last
        }
        guard exported else {
            let e = last as NSError
            throw DownloadError.exportFailed("本地 HLS 导出失败[\(e.domain)(\(e.code)) \(e.localizedDescription)]")
        }
        guard FileManager.default.fileExists(atPath: dest.path) else { throw DownloadError.emptyData }

        // 空壳校验：导出「完成」但写出 0 帧时，用 AVAsset 复核时长，避免坏文件被当成成功。
        let probe = AVURLAsset(url: dest)
        let dur = try? await probe.load(.duration)
        let seconds = dur?.seconds ?? 0
        guard seconds.isFinite, seconds > 0.3 else {
            try? FileManager.default.removeItem(at: dest)
            throw DownloadError.exportFailed("导出文件无有效画面（时长异常）")
        }
        progress?(1)
    }

    /// 下载字节（带 headers + UA），取消归一为 DownloadError.cancelled。
    private static func fetchBytes(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.allHTTPHeaderFields = headers
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(HuangguoClient.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw DownloadError.cancelled
        }
        return data
    }

    /// master playlist → 码率最高的 variant URL；非 master 返回 nil。
    private static func pickVariant(_ text: String, base: URL) -> URL? {
        var best: (URL, Int)?
        var pending = 0
        var expect = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let up = line.uppercased()
            if up.hasPrefix("#EXT-X-STREAM-INF") {
                expect = true
                pending = HTML.groups("BANDWIDTH=(\\d+)", line).flatMap { Int($0[1]) } ?? 0
                continue
            }
            if expect, !line.isEmpty, !line.hasPrefix("#") {
                expect = false
                if let u = URL(string: line, relativeTo: base)?.absoluteURL,
                   best == nil || pending >= best!.1 { best = (u, pending) }
                pending = 0
            }
        }
        return best?.0
    }
}
