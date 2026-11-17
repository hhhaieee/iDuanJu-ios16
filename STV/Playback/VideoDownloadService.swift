import Foundation
import AVFoundation

/// Downloads the episode currently playing into a standalone MP4 in the app's Downloads folder,
/// so it shows up in 下载管理 (TGDownloads) and can be saved to the photo library.
///
/// Two stream families:
/// - Progressive MP4 (红果 clear/CENC, most sites): download the body, locally decrypt CENC, write MP4.
/// - HLS / AES-128 (黄果 etc.): let AVAssetExportSession mux into an MP4. AES streams go through the
///   local clear playlist proxy so iOS 16 never has to fetch the out-of-band key itself.
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

    /// Mux an HLS stream into a standalone MP4. AES-128 plays through the local clear proxy.
    private static func exportHLS(_ stream: HGStream, to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        var assetURL: URL
        if stream.kind == .hlsAES,
           let clear = LocalHLSProxy.shared.playlistURL(stream.url, headers: stream.headers, strip: true, budget: 0, aesKey: stream.key),
           let u = URL(string: clear) {
            assetURL = u
        } else {
            guard let u = URL(string: stream.url) else { throw DownloadError.badURL }
            assetURL = u
        }
        var opts: [String: Any] = [:]
        if stream.kind != .hlsAES, !stream.headers.isEmpty {
            opts["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        let asset = AVURLAsset(url: assetURL, options: opts)
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw DownloadError.exportFailed("无法创建导出器")
        }
        exporter.outputURL = dest
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        progress?(0.1) // HLS 导出无精确进度，先给个起始值让 UI 显示「下载中」
        do {
            try await exporter.export()
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch {
            throw DownloadError.exportFailed(error.localizedDescription)
        }
        progress?(1)
    }
}
