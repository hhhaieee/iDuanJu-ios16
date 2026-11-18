import Foundation

/// 插件导入文件夹（App 内自建导入列表，绕开侧载下失效的 UIDocumentPicker）。
/// 与 BackupService.backupDir 同一套模式：文档共享目录下的 PluginImports 文件夹，
/// 用户在「文件」App → 我的 iPhone → 黑果夜剧 → PluginImports 里放入 .idjplugin 后，
/// 插件页即可扫描列出、点选安装。
enum PluginImportService {
    static let fileExtension = "idjplugin"

    static var importDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PluginImports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    struct ImportFile: Identifiable {
        let url: URL
        var id: String { url.lastPathComponent }
        var name: String { url.lastPathComponent }
        var size: Int64 {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var date: Date {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
    }

    /// 列出导入目录（含文档根目录）下所有 .idjplugin，按修改时间倒序。
    static func listFiles() -> [ImportFile] {
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in [importDir, fm.urls(for: .documentDirectory, in: .userDomainMask)[0]] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for u in items where u.pathExtension.lowercased() == fileExtension {
                guard !urls.contains(where: { $0.lastPathComponent == u.lastPathComponent }) else { continue }
                urls.append(u)
            }
        }
        return urls.map(ImportFile.init).sorted { $0.date > $1.date }
    }

    static func read(_ file: ImportFile) -> Data? {
        let accessed = file.url.startAccessingSecurityScopedResource()
        defer { if accessed { file.url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: file.url)
    }
}
