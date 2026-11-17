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

    /// 直下 HLS 分片 → 本地 AES-128 解密 → 拼接明文 TS → 从本地文件 remux 成 MP4。
    /// 导出器只读一个本地明文 TS，不再经过代理 / 带外 key（iOS 16 上那条链路时序不可靠）。
    private static func exportHLS(_ stream: HGStream, to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let playlistURL = URL(string: stream.url) else { throw DownloadError.badURL }

        // 1) 拉 playlist（必要时 master → 码率最高的 variant），再过一遍广告过滤。
        var text = String(decoding: try await fetchBytes(playlistURL, headers: stream.headers), as: UTF8.self)
        if !text.localizedCaseInsensitiveContains("#EXTINF"),
           let variant = pickVariant(text, base: playlistURL) {
            text = String(decoding: try await fetchBytes(variant, headers: stream.headers), as: UTF8.self)
        }
        text = HLSAdFilter.apply(text, base: playlistURL)
        if Task.isCancelled { throw DownloadError.cancelled }

        // 2) 解析 KEY / MEDIA-SEQUENCE / 分片行。
        var seqBase: Int64 = 0
        var explicitIV: Data?
        var keyURI: URL?
        var method = ""
        var segments: [URL] = []
        var expectSegment = false
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
            } else if up.hasPrefix("#EXTINF") {
                expectSegment = true
            } else if !line.isEmpty, !line.hasPrefix("#"), expectSegment {
                expectSegment = false
                if let u = URL(string: line, relativeTo: playlistURL)?.absoluteURL { segments.append(u) }
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

        // 4) 逐片下载 → 去伪头 → AES-128-CBC 解密 → 追加进本地明文 TS。
        let merged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ts")
        defer { try? FileManager.default.removeItem(at: merged) }
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: merged) else {
            throw DownloadError.exportFailed("无法创建临时文件")
        }
        defer { try? handle.close() }

        let total = Double(segments.count)
        for (i, seg) in segments.enumerated() {
            if Task.isCancelled { throw DownloadError.cancelled }
            var chunk = LocalHLSProxy.stripFakeHeader(try await fetchBytes(seg, headers: stream.headers))
            if encrypted, let k = key {
                let segIV: Data
                if let explicit = explicitIV { segIV = explicit }
                else {
                    // HLS 规范：无 IV 时用 media sequence number 作 128-bit 大端整数。
                    let s = (seqBase + Int64(i)).bigEndian
                    segIV = Data(repeating: 0, count: 8) + withUnsafeBytes(of: s) { Data($0) }
                }
                guard let clear = LocalHLSProxy.aesCBCDecrypt(chunk, key: k, iv: segIV) else {
                    throw DownloadError.exportFailed("分片解密失败")
                }
                chunk = clear
            }
            try handle.write(contentsOf: chunk)
            progress?(0.05 + 0.85 * Double(i + 1) / total)
        }
        try handle.close()
        if Task.isCancelled { throw DownloadError.cancelled }

        // 5) 从本地明文 TS remux 成 MP4。
        //    iOS 16 的 AVAssetExportSession 对「分片拼接 TS」的 passthrough 极不稳定（用户看到的
        //    「导出失败：这项操作无法完成」就卡在这一步）。改用 AVAssetReader/Writer 逐 sample 直拷：
        //    不解码、不重编码、不生成新时间戳，最快且保画质；Reader/Writer 也不行时再回退到
        //    AVAssetExportSession 重编码导出，确保尽量产出可播放的 MP4。
        progress?(0.92)
        let asset = AVURLAsset(url: merged)
        do {
            try await remuxByReaderWriter(asset, to: dest)
        } catch {
            var last: Error = error
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
                if ex.status == .completed { progress?(1); return }
                last = ex.error ?? last
            }
            throw DownloadError.exportFailed(last.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: dest.path) else { throw DownloadError.emptyData }
        // 空壳校验：重编码可能「完成」但写出 0 帧（典型 9 KB 只有 moov）。用 AVAsset 复核时长，
        // 时长无效或过小一律判失败，避免坏文件被当成下载成功、也无法存相册。
        let probe = AVURLAsset(url: dest)
        let dur = try? await probe.load(.duration)
        let seconds = dur?.seconds ?? 0
        guard seconds.isFinite, seconds > 0.3 else {
            try? FileManager.default.removeItem(at: dest)
            throw DownloadError.exportFailed("导出文件无有效画面（时长异常）")
        }
        progress?(1)
    }

    /// 解码 → 重编码 remux：把明文 TS 的音视频解码为原始帧，再编码写进 MP4。
    /// 关键：TS 里的 H.264/AAC 用 passthrough（outputSettings: nil）直拷进 MP4，
    /// 在 iOS 16 上会产出只有 moov 头、没有 mdat 的「空壳」文件（典型 9 KB，看似成功却无法播放/存相册）。
    /// 解码重编码兼容性最好；同时统计实际写入帧数，零帧一律判失败，杜绝空壳被误判成功。
    private static func remuxByReaderWriter(_ asset: AVAsset, to dest: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)

        // 视频：解码为 BGRA 像素 → 重编码 H.264，保留方向变换。
        var videoOut: AVAssetReaderTrackOutput?
        var videoIn: AVAssetWriterInput?
        if let vt = asset.tracks(withMediaType: .video).first {
            let decode: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            let out = AVAssetReaderTrackOutput(track: vt, outputSettings: decode)
            out.alwaysCopiesSampleData = false
            let transform = vt.preferredTransform
            let disp = vt.naturalSize.applying(transform)
            let w = max(2, Int(abs(disp.width))), h = max(2, Int(abs(disp.height)))
            let encode: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: encode)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out); writer.add(input)
                videoOut = out; videoIn = input
            }
        }

        // 音频：解码为 44.1k/2ch LinearPCM → 重编码 AAC。
        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let at = asset.tracks(withMediaType: .audio).first {
            let decode: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
            let out = AVAssetReaderTrackOutput(track: at, outputSettings: decode)
            out.alwaysCopiesSampleData = false
            let encode: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encode)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out); writer.add(input)
                audioOut = out; audioIn = input
            }
        }

        guard videoIn != nil || audioIn != nil else { throw DownloadError.exportFailed("无可用音视频轨道") }
        guard reader.startReading(), writer.startWriting() else {
            throw DownloadError.exportFailed("无法启动导出")
        }
        writer.startSession(atSourceTime: .zero)

        struct Lane { let input: AVAssetWriterInput; let output: AVAssetReaderTrackOutput }
        var lanes: [Lane] = []
        if let vIn = videoIn, let vOut = videoOut { lanes.append(Lane(input: vIn, output: vOut)) }
        if let aIn = audioIn, let aOut = audioOut { lanes.append(Lane(input: aIn, output: aOut)) }

        let written = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let group = DispatchGroup()
            let lock = NSLock()
            var failure: Error?
            var count = 0
            for (i, lane) in lanes.enumerated() {
                group.enter()
                lane.input.requestMediaDataWhenReady(on: DispatchQueue(label: "stv.remux.\(i)")) {
                    while lane.input.isReadyForMoreMediaData {
                        guard let buf = lane.output.copyNextSampleBuffer() else {
                            lane.input.markAsFinished()
                            group.leave()
                            return
                        }
                        if !lane.input.append(buf) {
                            lock.lock()
                            failure = writer.error ?? DownloadError.exportFailed("写入媒体数据失败")
                            lock.unlock()
                            lane.input.markAsFinished()
                            group.leave()
                            return
                        }
                        lock.lock(); count += 1; lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) {
                if let e = failure {
                    writer.cancelWriting()
                    cont.resume(throwing: e)
                    return
                }
                writer.finishWriting { cont.resume(returning: count) }
            }
        }
        guard writer.status == .completed else {
            throw DownloadError.exportFailed(writer.error?.localizedDescription ?? "导出未完成")
        }
        guard written > 0 else { throw DownloadError.exportFailed("未写出任何媒体帧") }
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
