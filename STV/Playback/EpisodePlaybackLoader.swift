import Foundation

/// Downloads a resolved hongguo MP4, decrypts CENC (AES-CTR) locally, and returns a playable file URL.
enum EpisodePlaybackLoader {
    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stv-playback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(vid: String, stream: HGStream) -> URL {
        let safeId = (stream.streamId ?? stream.quality ?? "default").filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return cacheDir.appendingPathComponent("\(vid)-\(safeId).mp4")
    }

    /// Previously decrypted copy of this stream, if still on disk.
    static func cachedFile(vid: String, stream: HGStream) -> URL? {
 let out = fileURL(vid: vid, stream: stream)
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }

    static func playableFile(vid: String, stream: HGStream) async throws -> URL {
        let out = fileURL(vid: vid, stream: stream)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let src = URL(string: stream.url) else { throw URLError(.badURL) }

        let tmp: URL
        do {
            tmp = try await download(src, headers: stream.headers)
        } catch {
            try Task.checkCancellation()
            guard let backup = stream.backupURL else { throw error }
            tmp = try await download(backup, headers: stream.headers)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Task.checkCancellation()
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        if stream.key.isEmpty {
            try data.write(to: out, options: .atomic)
        } else {
            var bytes = [UInt8](data)
            try CENCDecryptor.decrypt(&bytes, keyHex: stream.key)
            try Task.checkCancellation()
            try Data(bytes).write(to: out, options: .atomic)
        }
        pruneCache(keep: 8)
        return out
    }

    private static func download(_ url: URL, headers: [String: String]) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.allHTTPHeaderFields = headers
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }

    /// Keep only the most recent few decrypted episodes on disk.
    static func pruneCache(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(keep) { try? fm.removeItem(at: f) }
    }
}
