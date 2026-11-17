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
    }

    struct RestoreResult {
        var ok: Bool
        var message: String
        var defaultsCount: Int = 0
        var pluginFilesCount: Int = 0
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
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                guard let d = try? Data(contentsOf: url) else { continue }
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let rel = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
                files[rel] = d.base64EncodedString()
            }
        }

        let info = Bundle.main.infoDictionary
        let payload = BackupPayload(
            format: formatVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            defaultsPlist: plist.base64EncodedString(),
            pluginFiles: files
        )
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func suggestedFilename() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        return "黑果备份-\(df.string(from: Date())).\(fileExtension)"
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

        return RestoreResult(ok: true,
                             message: "已恢复 \(count) 项数据、\(filesCount) 个插件文件。请重启 App 让设置生效。",
                             defaultsCount: count, pluginFilesCount: filesCount)
    }
}

/// 备份文件的 UTType（用于 .fileExporter / .fileImporter）。
extension UTType {
    static let idjBackup = UTType(exportedAs: "com.local.STV.backup", conformingTo: .data)
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
