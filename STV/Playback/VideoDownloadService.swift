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
        case noStream, badURL, emptyData, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noStream: return "没有可用的视频流"
            case .badURL: return "视频地址无效"
            case .emptyData: return "下载内容为空"
            case .exportFailed(let m): return "导出失败：\(m)"
            }
        }
    }

    /// Resolve the episode, pick a stream, download/decrypt to a standalone MP4, return its URL.
    static func download(series: HGSeries, episode: HGEpisode) async throws -> URL {
        let resolved = try await Catalog.resolve(series, episode)
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
            var data = try await fetch(stream)
            guard !data.isEmpty else { throw DownloadError.emptyData }
            if !stream.key.isEmpty {
                var bytes = [UInt8](data)
                _ = try CENCDecryptor.decrypt(&bytes, keyHex: stream.key)
                data = Data(bytes)
            }
            try data.write(to: dest, options: .atomic)
        case .hls, .hlsAES:
            try await exportHLS(stream, to: dest)
        }

        guard FileManager.default.fileExists(atPath: dest.path) else { throw DownloadError.emptyData }
        return dest
    }

    /// Plain HTTP download with the stream's headers and backup-URL retry.
    private static func fetch(_ stream: HGStream) async throws -> Data {
        func get(_ u: URL) async throws -> Data {
            var req = URLRequest(url: u, timeoutInterval: 30)
            req.allHTTPHeaderFields = stream.headers
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw ProviderError.upstream("HTTP \(code)") }
            return d
        }
        guard let u = URL(string: stream.url) else { throw DownloadError.badURL }
        do { return try await get(u) }
        catch {
            if let backup = stream.backupURL { return try await get(backup) }
            throw error
        }
    }

    /// Mux an HLS stream into a standalone MP4. AES-128 plays through the local clear proxy.
    private static func exportHLS(_ stream: HGStream, to dest: URL) async throws {
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
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw DownloadError.exportFailed("无法创建导出器")
        }
        exporter.outputURL = dest
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        do {
            try await exporter.export()
        } catch {
            throw DownloadError.exportFailed(error.localizedDescription)
        }
    }
}
