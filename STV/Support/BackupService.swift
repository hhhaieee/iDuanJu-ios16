import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 本机数据备份与恢复：把 App 的 UserDefaults 域 + 插件目录打包成一个 JSON 文件。
/// 设计要点：
/// - 跨版本兼容：defaults 用二进制 plist 保真序列化，恢复时逐 key 写回；新增 key 自动包含，
///   某条解不出来不影响其他（宽松恢复）。
/// - 不备份易失效/环境相关的项：代理地址端口、cookie 文件由各插件自管，不在本备份范围。
/// - 恢复后需要重启 App：多数 Store 是启动时从 UserDefaults 读快照到内存。
enum BackupService {
    static let formatVersion = 1

    /// 备份文件名后缀（UTType 在 BackupDocument 里定义）。
    static let fileExtension = "idjbackup"

    // MARK: - Payload

    private struct BackupPayload: Codable {
        let format: Int
        let appVersion: String
        let build: String
        let createdAt: String
        /// UserDefaults 域的二进制 plist（base64）。
        let defaultsPlist: String
        /// 插件目录文件：相对路径 -> base64。
        let pluginFiles: [String: String]
        /// 导出自检发现的插件问题（脚本缺失/哈希不符）。旧备份无此字段，解码为 nil。
        let warnings: [String]?
    }

    struct RestoreResult {
        var ok: Bool
        var message: String
        var defaultsCount: Int = 0
        var pluginFilesCount: Int = 0
        /// 恢复后被剔除的"有记录但脚本缺失/损坏"的插件数量。
        var prunedPlugins: Int = 0
    }

    /// 这些 key 不写回：换网络环境后代理配置通常要重设，且属于环境相关而非用户数据。
    private static let skippedKeyPrefixes = ["stv.proxy."]
    private static func shouldSkip(_ key: String) -> Bool {
        skippedKeyPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - Export

    static func makeBackupData() -> Data {
        let domain = Bundle.main.bundleIdentifier ?? "com.local.STV"
        let prefs = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        var kept: [String: Any] = [:]
        for (k, v) in prefs where !shouldSkip(k) { kept[k] = v }

        let plist: Data
        let writeOpts = PropertyListSerialization.WriteOptions()
        if let d = try? PropertyListSerialization.data(fromPropertyList: kept as NSDictionary,
                                                       format: .binary, options: writeOpts) {
            plist = d
        } else {
            plist = Data()
        }

        var files: [String: String] = [:]
        let root = PluginPaths.root
        // 关键修复：用 subpaths(atPath:) 直接取得「相对根目录」的路径（系统保证相对路径正确，
        // 如 com.idj.a123/main.js）。旧实现用 root.path 字符串前缀匹配算相对路径，iOS 上
        // root.path(/var/...) 与枚举出的 url.path(/private/var/...) 前缀不一致，全部落到
        // url.lastPathComponent —— 各插件同名 main.js 互相覆盖，备份里只剩一份平铺脚本。
        // 写回时用 root.appendingPathComponent(rel) 拼回完整 URL，与 root 同源，读写一致。
        if let subpaths = FileManager.default.subpaths(atPath: root.path) {
            for rel in subpaths {
                let fileURL = root.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }
                guard let d = try? Data(contentsOf: fileURL) else { continue }
                files[rel] = d.base64EncodedString()
            }
        }

        // 导出自检：逐条核对每个已安装插件的脚本是否真实落盘、哈希是否匹配。
        // 把有问题的插件名写进备份，恢复时明确提示，避免再次产生"名单有、脚本无"的残缺备份。
        var warnings: [String] = []
        if let idxData = files["index.json"].flatMap({ Data(base64Encoded: $0) }),
           let records = try? JSONDecoder().decode([InstalledPlugin].self, from: idxData) {
            for rec in records {
                let scriptRel = "\(PluginPaths.safeID(rec.manifest.id))/\(rec.manifest.entry)"
                guard let scriptData = files[scriptRel].flatMap({ Data(base64Encoded: $0) }) else {
                    warnings.append("\(rec.manifest.name)（脚本未打进备份）")
                    continue
                }
                if let pinned = rec.fileHashes[rec.manifest.entry], !pinned.isEmpty,
                   PluginManifest.fileHash(scriptData) != pinned {
                    warnings.append("\(rec.manifest.name)（脚本校验不符）")
                }
            }
        }

        let info = Bundle.main.infoDictionary
        let payload = BackupPayload(
            format: formatVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            defaultsPlist: plist.base64EncodedString(),
            pluginFiles: files,
            warnings: warnings.isEmpty ? nil : warnings
        )
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func suggestedFilename() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        return "黑果备份-\(df.string(from: Date())).\(fileExtension)"
    }

    // MARK: - Backup folder (App 内自建导入/导出列表，绕开侧载下失效的 UIDocumentPicker)

    /// 备份文件目录：位于 App 文档共享目录下，用户在「文件」App → 我的 iPhone → 黑果夜剧 → Backups 可见。
    static var backupDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 生成备份数据并写入备份目录，返回落盘的文件 URL。
    @discardableResult
    static func exportToBackupDir() -> URL? {
        let data = makeBackupData()
        let url = backupDir.appendingPathComponent(suggestedFilename())
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: - Restore

    @discardableResult
    static func restore(from data: Data) -> RestoreResult {
        guard let payload = try? JSONDecoder().decode(BackupPayload.self, from: data) else {
            return RestoreResult(ok: false, message: "无法识别备份文件，可能已损坏或不是本 App 的备份。")
        }
        guard payload.format <= formatVersion else {
            return RestoreResult(ok: false, message: "备份来自更高版本（格式 \(payload.format)），当前版本无法读取。")
        }

        var count = 0
        if let pdata = Data(base64Encoded: payload.defaultsPlist),
           let obj = try? PropertyListSerialization.propertyList(from: pdata, format: nil),
           let dict = obj as? [String: Any] {
            for (k, v) in dict {
                if shouldSkip(k) { continue }
                UserDefaults.standard.set(v, forKey: k)
                count += 1
            }
        }

        // 恢复后强制重新注入内置「在线仓库」：清除「用户已删除默认商店」标记，
        // 避免旧备份把这个标记写回、导致插件商店永远加不回来。
        UserDefaults.standard.removeObject(forKey: "stv.plugins.defaultStoreRemoved")

        var filesCount = 0
        let root = PluginPaths.root
        // 先清后写，保证恢复的是备份时刻的插件集合；失败项跳过，不影响其他文件。
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, b64) in payload.pluginFiles {
            guard let d = Data(base64Encoded: b64), !rel.isEmpty else { continue }
            let dest = root.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? d.write(to: dest, options: .atomic)) != nil { filesCount += 1 }
        }

        // 抢救：旧备份曾把某个插件的文件平铺在插件根目录（main.js / manifest.json 等，
        // 缺少 <id>/ 子目录）。加载时按 <id>/<entry> 查找，于是"有脚本却报脚本文件缺失"。
        // 用脚本哈希把平铺文件归位到匹配的插件目录，能救回这类插件。
        let rehomed = Self.rehomeFlattenedPluginFiles(in: root)

        // 治本：脚本写回后逐条校验安装记录。备份可能不完整（旧备份 / 当时脚本未打进包 /
        // 相对路径写回失败），导致 index.json 有记录但脚本文件缺失或哈希不符——这正是
        // "显示已安装却用不了、检测又检测不出来"的根因。这里把这类僵尸记录直接剔除，
        // 保证恢复后"已安装"列表与磁盘上真实可用的脚本严格一致。
        let pruned = Self.pruneBrokenPluginRecords(in: root)
        var msg = "已恢复 \(count) 项数据、\(filesCount) 个插件文件。"
        if rehomed > 0 {
            msg += "已自动修复 \(rehomed) 个放错位置的插件。"
        }
        if pruned > 0 {
            msg += "其中 \(pruned) 个插件的脚本在备份中缺失或损坏，已从已安装列表移除（请到插件页重新安装）。"
        }
        if let warns = payload.warnings, !warns.isEmpty {
            msg += "备份导出时检测到问题：" + warns.joined(separator: "、") + "。"
        }
        msg += "请重启 App 让设置生效。"

        return RestoreResult(ok: true,
                             message: msg,
                             defaultsCount: count, pluginFilesCount: filesCount,
                             prunedPlugins: pruned)
    }

    /// 兼容旧备份：把平铺在插件根目录的脚本文件，按哈希匹配归位到对应的 <id>/ 子目录。
    /// 返回成功归位的插件数。只在检测到"根目录同时有 index.json 和脚本文件"时才动作。
    private static func rehomeFlattenedPluginFiles(in root: URL) -> Int {
        let fm = FileManager.default
        let indexURL = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else { return 0 }

        // 根目录里"疑似被拍平"的插件文件（index.json 是安装记录本身，不算脚本）。
        let flatNames = ["main.js", "manifest.json", "storage.json", "cookies.plist", "log.txt"]
        var flat: [String: Data] = [:]
        for name in flatNames {
            if let d = try? Data(contentsOf: root.appendingPathComponent(name)) { flat[name] = d }
        }
        // 没有任何平铺脚本，说明备份结构正常，无需归位。
        guard let flatScript = flat["main.js"] else { return 0 }

        // 用哈希找到这份平铺脚本属于哪条安装记录。
        var matched: InstalledPlugin?
        for rec in records {
            if let pinned = rec.fileHashes[rec.manifest.entry], !pinned.isEmpty,
               PluginManifest.fileHash(flatScript) == pinned {
                matched = rec
                break
            }
        }
        guard let rec = matched else { return 0 }

        let dest = PluginPaths.dir(rec.manifest.id)
        var moved = 0
        for (name, d) in flat {
            if (try? d.write(to: dest.appendingPathComponent(name), options: .atomic)) != nil { moved += 1 }
            try? fm.removeItem(at: root.appendingPathComponent(name))  // 移走，避免残留干扰校验
        }
        if moved > 0 {
            PluginLog.add("__system__", "备份恢复：已将 \(rec.manifest.name) 的 \(moved) 个平铺脚本归位到插件目录")
        }
        return moved > 0 ? 1 : 0
    }

    /// 读取插件目录内的 index.json，剔除"脚本文件缺失或与安装时哈希不符"的记录并写回。
    /// 返回被剔除的记录数。任何读写失败都按 0 处理，不影响恢复主流程。
    private static func pruneBrokenPluginRecords(in root: URL) -> Int {
        let indexURL = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              var records = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else { return 0 }
        let before = records.count
        records.removeAll { rec in
            let file = PluginPaths.dir(rec.manifest.id).appendingPathComponent(rec.manifest.entry)
            guard let script = try? Data(contentsOf: file) else { return true }  // 脚本文件缺失
            if let pinned = rec.fileHashes[rec.manifest.entry], !pinned.isEmpty,
               PluginManifest.fileHash(script) != pinned {
                return true  // 哈希不符（备份损坏或被改动）
            }
            return false
        }
        let removed = before - records.count
        if removed > 0, let out = try? JSONEncoder().encode(records) {
            try? out.write(to: indexURL, options: .atomic)
        }
        return removed
    }
}

/// 备份文件的 UTType（用于 .fileExporter / .fileImporter）。
extension UTType {
    static let idjBackup = UTType(exportedAs: "com.local.stv.backup", conformingTo: .data)
}

/// SwiftUI 文件导出用的可导出文档。
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.idjBackup, .json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 用 UIKit 的 UIDocumentPicker 导出：asCopy=true 时右上角显示「存储/保存」而非 SwiftUI
/// fileExporter 固定显示的「移动」（后者是系统文案，无法通过 UTI 配置改变）。
struct UIKitDocumentExporter: UIViewControllerRepresentable {
    let url: URL
    var asCopy: Bool = true
    let onFinish: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: asCopy)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Result<URL, Error>) -> Void
        init(onFinish: @escaping (Result<URL, Error>) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(.success(urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(.failure(CancellationError()))
        }
    }
}

/// 原生文件选择器（导入用）：直接弹系统文件列表点选 .idjplugin / .idjbackup。
/// 走 UIKit UIDocumentPickerViewController（与 guoapp 同款），不用 SwiftUI .fileImporter——
/// 后者在 TrollStore 侧载环境下存在「点了没反应」的问题。
struct NativeDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: (() -> Void)?
        init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}

/// 系统分享面板：把备份文件分享到「文件」App / 其他 App / 存储到云端。
/// 用 UIActivityViewController 而非 UIDocumentPicker，绕开 TrollStore 侧载下选择器失效的问题。
struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    var onFinish: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onFinish?() }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// App 入口用：外部「文件」App 点开 .idjbackup 时接收 URL → 恢复 → 弹结果提示。
struct BackupOpenURLHandler: ViewModifier {
    @State private var message: String?
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                let ext = url.pathExtension.lowercased()
                guard ext == BackupService.fileExtension || ext == "json" else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    message = "无法读取该备份文件。"
                    return
                }
                message = BackupService.restore(from: data).message
            }
            .alert("恢复结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
    }
}
