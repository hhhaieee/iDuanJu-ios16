import Foundation
import Combine
import Photos

struct TGDownload: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, running, paused, done, failed }
    enum Kind: String, Codable { case video, photo }
    var id: String
    var kind: Kind
    var title: String
    var channel: String
    var remote: String
    var thumb: String
    var duration: Int = 0
    var isAdult = false
    var state: State = .queued
    var received: Int64 = 0
    var expected: Int64 = 0
    var fileName: String? = nil
    var error: String? = nil
    var createdAt = Date()
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : (state == .done ? 1 : 0) }
    var localURL: URL? { fileName.map { TGDownloads.dir.appendingPathComponent($0) } }
}

/// In-app download manager: FIFO queue (2 at a time), progress, pause/resume (resume data), delete,
/// offline playback, and 保存到相册.
@MainActor
final class TGDownloads: NSObject, ObservableObject {
    static let shared = TGDownloads()
    static let maxConcurrent = 2
    nonisolated static var dir: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Published private(set) var items: [TGDownload] = []
    @Published private var tasks: [String: URLSessionDownloadTask] = [:]
    @Published private var resumeData: [String: Data] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: Bridge(owner: self), delegateQueue: .main)
    }()
    private let key = "stv.downloads"

    override private init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([TGDownload].self, from: d) {
            // Interrupted transfers come back paused.
            items = v.map { var x = $0; if x.state == .running || x.state == .queued { x.state = .paused }; return x }
        }
    }

    var visible: [TGDownload] { items.filter { !$0.isAdult || SourceGate.shared.showAdultChannels } }

    // MARK: Enqueue

    @discardableResult
    func enqueue(post p: TGPost, media i: Int, channel: TGChannel?) -> String? {
        guard p.media.indices.contains(i) else { return nil }
        let m = p.media[i]
        let isVideo = m.kind != .photo
        guard let remote = isVideo ? m.video : m.thumb else { return nil }
        let id = "\(p.channel.lowercased())-\(p.msgId)-\(i)"
        if let existing = items.first(where: { $0.id == id }) {
            if existing.state == .failed || existing.state == .paused { resume(existing) }
            return id
        }
        let title = p.text.split(separator: "\n").first.map { String($0.prefix(50)) } ?? ""
        items.insert(TGDownload(id: id, kind: isVideo ? .video : .photo, title: title.isEmpty ? "@\(p.channel) #\(p.msgId)" : title,
                                channel: channel?.displayName ?? "@" + p.channel, remote: remote, thumb: m.thumb,
                                duration: m.duration, isAdult: channel?.isAdult ?? false), at: 0)
        save(); pump()
        return id
    }

    func pause(_ d: TGDownload) {
        guard let t = tasks[d.id] else { set(d.id) { $0.state = .paused }; return }
        t.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                if let data { self.resumeData[d.id] = data }
                self.tasks[d.id] = nil
                self.set(d.id) { $0.state = .paused }
                self.pump()
            }
        })
    }

    func resume(_ d: TGDownload) { set(d.id) { $0.state = .queued; $0.error = nil }; pump() }

    func delete(_ d: TGDownload) {
        tasks.removeValue(forKey: d.id)?.cancel()
        resumeData[d.id] = nil
        if let u = d.localURL { try? FileManager.default.removeItem(at: u) }
        items.removeAll { $0.id == d.id }
        save(); pump()
    }

    func item(_ id: String) -> TGDownload? { items.first { $0.id == id } }

    var totalBytes: Int64 { items.filter { $0.state == .done }.reduce(0) { $0 + max($1.received, $1.expected) } }

    // MARK: Queue

    private func pump() {
        let running = items.filter { $0.state == .running }.count
        guard running < Self.maxConcurrent else { return }
        for d in items.reversed() where d.state == .queued {
            guard items.filter({ $0.state == .running }).count < Self.maxConcurrent else { break }
            start(d)
        }
    }

    private func start(_ d: TGDownload) {
        if d.remote.hasPrefix("tdfile://") {
            // TDLib media: TDLib downloads into its own files dir; copy the result into Downloads.
            set(d.id) { $0.state = .running; $0.error = nil }
            Task {
                do {
                    let src = try await TDLibService.shared.file(d.remote, userDownload: true)
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: src, to: tmp)
                    finished(d.id, file: tmp, response: nil, error: nil)
                } catch { set(d.id) { $0.state = .failed; $0.error = error.localizedDescription }; pump() }
            }
            return
        }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: d.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            guard let u = URL(string: d.remote) else { set(d.id) { $0.state = .failed; $0.error = "地址无效" }; return }
            var r = URLRequest(url: u)
            r.setValue(TGClient.userAgent, forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: r)
        }
        task.taskDescription = d.id
        tasks[d.id] = task
        set(d.id) { $0.state = .running; $0.error = nil }
        task.resume()
    }

    fileprivate func progress(_ id: String, _ got: Int64, _ total: Int64) {
        set(id, persist: false) { $0.received = got; if total > 0 { $0.expected = total } }
    }

    fileprivate func finished(_ id: String, file: URL?, response: URLResponse?, error: Error?) {
        tasks[id] = nil
        if let error = error as NSError?, error.code == NSURLErrorCancelled { return }   // paused / deleted
        guard let d = item(id) else { return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        if let file, error == nil, (200..<300).contains(code) {
            let ext = d.kind == .video ? "mp4" : (!d.remote.hasPrefix("tdfile://") && URL(string: d.remote)?.pathExtension.isEmpty == false ? URL(string: d.remote)!.pathExtension : "jpg")
            let name = id + "." + ext
            let dest = Self.dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: file, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? d.received
                set(id) { $0.state = .done; $0.fileName = name; $0.received = size; $0.expected = size }
            } catch { set(id) { $0.state = .failed; $0.error = error.localizedDescription } }
        } else {
            let msg = error?.localizedDescription ?? "HTTP \(code)（链接可能已过期，刷新频道后重试）"
            if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[id] = data }
            set(id) { $0.state = .failed; $0.error = msg }
        }
        pump()
    }

    private func set(_ id: String, persist: Bool = true, _ f: (inout TGDownload) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
        if persist { save() }
    }

    private func save() { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) } }

    // MARK: Photos

    enum SaveError: LocalizedError { case denied, notDownloaded
        var errorDescription: String? { self == .denied ? "没有相册写入权限，请在 设置 → 隐私 → 照片 中允许" : "文件还没下载完" }
    }

    /// Saves a finished download (or any local file) to the photo library (add-only permission).
    static func saveToPhotos(_ file: URL, video: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let r = PHAssetCreationRequest.forAsset()
            r.addResource(with: video ? .video : .photo, fileURL: file, options: nil)
        }
    }

    /// Downloads a remote photo to a temp file then saves it (used from the image viewer).
    static func savePhoto(_ url: String) async throws {
        if url.hasPrefix("tdfile://") { try await saveToPhotos(try await TDLibService.shared.file(url), video: false); return }
        if url.hasPrefix("file://"), let u = URL(string: url) { try await saveToPhotos(u, video: false); return }
        guard let u = URL(string: url) else { throw SaveError.notDownloaded }
        let (tmp, _) = try await URLSession.shared.download(from: u)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try FileManager.default.moveItem(at: tmp, to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }
        try await saveToPhotos(dest, video: false)
    }
}

/// URLSession delegate trampoline (the manager is MainActor-isolated; delegate queue is main).
private final class Bridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: TGDownloads?
    init(owner: TGDownloads) { self.owner = owner }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        guard let id = t.taskDescription else { return }
        MainActor.assumeIsolated { owner?.progress(id, w, e) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = t.taskDescription else { return }
        // The temp file is deleted when this returns: move it somewhere stable first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: keep)
        let resp = t.response
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            owner?.finished(id, file: (200..<300).contains(code) ? keep : nil, response: resp, error: nil)
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = t.taskDescription else { return }
        MainActor.assumeIsolated { owner?.finished(id, file: nil, response: t.response, error: error) }
    }
}
