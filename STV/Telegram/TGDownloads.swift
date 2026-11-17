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
    /// 播放器「下载本集」等外部下载的进度（0...1）。为 nil 时走 received/expected。
    var fraction: Double? = nil
    var progress: Double { if let fraction { return min(1, max(0, fraction)) }; return expected > 0 ? min(1, Double(received) / Double(expected)) : (state == .done ? 1 : 0) }
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
    /// 播放器「下载本集」走的是普通 async Task（不是 URLSessionDownloadTask），暂停/删除靠这里的取消闭包。
    private var externalCancel: [String: () -> Void] = [:]
    /// 外部下载暂停/失败后的重试闭包（由 coordinator 注册：重新下载该集）。
    private var externalRetry: [String: () -> Void] = [:]
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
        // 播放器「下载本集」这类外部下载：调用取消闭包并标记暂停。
        if let cancel = externalCancel[d.id] {
            cancel(); externalCancel[d.id] = nil
            set(d.id) { $0.state = .paused; $0.fraction = nil }
            return
        }
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

    func resume(_ d: TGDownload) {
        // 外部下载暂停后不保留进度数据，重新从触发方下载。
        if let retry = externalRetry[d.id] {
            set(d.id) { $0.state = .running; $0.error = nil; $0.fraction = 0 }
            retry()
            return
        }
        set(d.id) { $0.state = .queued; $0.error = nil }; pump()
    }

    func delete(_ d: TGDownload) {
        externalCancel[d.id]?()
        externalCancel[d.id] = nil
        externalRetry[d.id] = nil
        tasks.removeValue(forKey: d.id)?.cancel()
        resumeData[d.id] = nil
        if let u = d.localURL { try? FileManager.default.removeItem(at: u) }
        items.removeAll { $0.id == d.id }
        save(); pump()
    }

    func item(_ id: String) -> TGDownload? { items.first { $0.id == id } }

    // MARK: 播放器「下载本集」外部下载
    // 这些下载由 VideoDownloadService 用普通 async Task 完成，不进 URLSessionDownloadTask 队列，
    // 但同样登记进下载管理以显示进度、支持暂停/删除。

    /// 下载开始时登记一条 running 记录（文件名先占位，完成后由 finishVideo 固化）。
    @discardableResult
    func beginVideo(id: String, title: String, channel: String, remote: String, thumb: String,
                    fileName: String, duration: Int = 0) -> String {
        var d = TGDownload(id: id, kind: .video, title: title, channel: channel, remote: remote, thumb: thumb,
                           duration: duration, state: .running, received: 0, expected: 0, fileName: fileName)
        d.isAdult = false
        d.fraction = 0
        items.removeAll { $0.id == id }
        items.insert(d, at: 0)
        save()
        return id
    }

    /// 绑定该外部下载的取消闭包（coordinator 持有 Task，cancel 即中止）。
    func bindCancel(_ id: String, _ cancel: @escaping () -> Void) { externalCancel[id] = cancel }
    /// 绑定重试闭包：暂停/失败后点「继续」时重新下载该集。
    func bindRetry(_ id: String, _ retry: @escaping () -> Void) { externalRetry[id] = retry }

    /// 更新进度 0...1。
    func updateVideo(_ id: String, fraction: Double) {
        set(id) { $0.fraction = fraction; $0.state = .running }
    }

    /// 下载完成：固化状态与文件大小。
    func finishVideo(_ id: String, fileName: String) {
        let size = (try? Self.dir.appendingPathComponent(fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        set(id) { d in
            d.state = .done; d.fileName = fileName; d.received = size; d.expected = size
            d.error = nil; d.fraction = nil
        }
        externalCancel[id] = nil
        externalRetry[id] = nil
        save()
    }

    /// 下载失败：标记为 failed 并展示原因。保留 retry 以支持点「继续」重试。
    func failVideo(_ id: String, error: String) {
        set(id) { $0.state = .failed; $0.error = error; $0.fraction = nil }
        externalCancel[id] = nil
        save()
    }

    /// Registers an already-downloaded video file (from the player's 下载本集) in 下载管理.
    /// The file must already live in `TGDownloads.dir` under `fileName`.
    @discardableResult
    func registerVideo(id: String, title: String, channel: String, remote: String, thumb: String,
                       fileName: String, duration: Int = 0) -> String {
        let size = (try? Self.dir.appendingPathComponent(fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var d = TGDownload(id: id, kind: .video, title: title, channel: channel, remote: remote, thumb: thumb,
                           duration: duration, state: .done, received: size, expected: size, fileName: fileName)
        d.isAdult = false
        items.removeAll { $0.id == id }
        items.insert(d, at: 0)
        save()
        return id
    }

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
