import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @State private var message: String?
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @ObservedObject private var proxy = ProxySettings.shared
    @ObservedObject private var downloads = TGDownloads.shared
    @EnvironmentObject private var appearance: AppearanceModel
    @State private var showBackup = false
    @State private var sharingURL: URL?
    @State private var showRestorePicker = false
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("我的").font(.largeTitle.weight(.heavy)).foregroundStyle(STVTheme.text).padding(.horizontal, 16)
                if !library.continueWatching.isEmpty { ContinueRow(items: library.continueWatching) }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "我的收藏", trailing: AnyView(NavigationLink(value: Route.favorites) {
                        Text("全部 \(library.favorites.count)").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    }))
                    if library.favorites.isEmpty {
                        Text("在播放页右侧点 ♥ 收藏").font(.subheadline).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
                    } else {
                        NumberedGrid(items: Array(library.favorites.prefix(6)), numbered: false)
                    }
                }
                VStack(spacing: 0) {
                    link("观看历史", "clock.arrow.circlepath", .history, trailing: library.continueWatching.isEmpty ? nil : "\(library.continueWatching.count)")
                    link("剧星榜", "star.circle", .actorRank)
                    link("我的收藏", "heart", .favorites, trailing: "\(library.favorites.count)")
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                VStack(spacing: 0) {
                    link("Telegram 频道", "paperplane", .channels, trailing: "\(TGStore.shared.visibleChannels.count) 个")
                    link("漫画", "book", .mangaHome, trailing: MangaStore.shared.favorites.isEmpty ? nil : "收藏 \(MangaStore.shared.favorites.count)")
                    link("下载管理", "arrow.down.circle", .downloads, trailing: downloads.visible.isEmpty ? nil : "\(downloads.visible.count)")
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                VStack(spacing: 0) {
                    link("片源管理", "square.stack.3d.down.right", .sources,
                         trailing: gate.enabledCount > 0 ? "已启用 \(gate.enabledCount) 个" : "红果")
                    link("外观与主题", "paintpalette", .appearance, trailing: appearance.theme.label)
                    link("开源许可", "doc.text", .licenses)
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 0) {
                    link("数据源诊断", "stethoscope", .diagnostics)
                    Button { showBackup = true } label: {
                        HStack {
                            Image(systemName: "archivebox").frame(width: 24)
                            Text("备份与恢复").foregroundStyle(STVTheme.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary)
                        }.padding(14)
                    }.buttonStyle(.plain).accessibilityIdentifier("profile.backup")
                    HStack {
                        Image(systemName: "network").frame(width: 24)
                        Text("网络代理").foregroundStyle(STVTheme.text)
                        Spacer()
                        Toggle("", isOn: $proxy.enabled).labelsHidden()
                    }.padding(14)
                    if proxy.enabled {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("代理类型", selection: $proxy.kind) {
                                ForEach(ProxySettings.Kind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            HStack(spacing: 10) {
                                Text("服务器").font(.subheadline).foregroundStyle(STVTheme.secondary).frame(width: 52, alignment: .leading)
                                TextField("127.0.0.1", text: $proxy.host)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.URL).foregroundStyle(STVTheme.text)
                            }
                            HStack(spacing: 10) {
                                Text("端口").font(.subheadline).foregroundStyle(STVTheme.secondary).frame(width: 52, alignment: .leading)
                                TextField("7890", text: $proxy.port)
                                    .keyboardType(.numberPad).foregroundStyle(STVTheme.text)
                            }
                            Text("网页抓取、封面、接口请求与本地视频转发都走该代理；改动后需重启 App 生效")
                                .font(.caption).foregroundStyle(STVTheme.secondary)
                        }.padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                VStack(spacing: 0) {
                    row("重置红果设备注册", "arrow.counterclockwise") { await HongguoClient.shared.resetDevice(); message = "已重置红果设备" }
                    if gate.huangguo {
                        row("重置黄果访客会话", "person.badge.key") { await HuangguoClient.shared.resetSession(); message = "已清除黄果会话" }
                    }
                    row("清空封面缓存", "photo.stack") { await CoverStore.shared.clear(); message = "封面缓存已清空" }
                    row("清空播放缓存", "trash") { try? FileManager.default.removeItem(at: EpisodePlaybackLoader.cacheDir); await HongguoClient.shared.clearResolveCache(); message = "播放缓存已清空" }
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                Text(message ?? "所有数据由本机直连上游，观看记录和收藏只保存在本机。\n\(Self.versionText)")
                    .font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
            }.padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showBackup) { backupPanel }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var backupPanel: some View {
        NavigationStack {
            List {
                Section {
                    Text("把收藏、观看记录、片源开关、插件、红果设备身份、小说书架等打包备份为 .idjbackup 文件。点「导出备份」后在系统分享面板里选「存储到文件」保存；恢复时点「从文件恢复」直接选择备份文件。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                }
                Section {
                    Button {
                        isExporting = true
                        // 后台生成，避免主线程同步编码大量插件文件导致白屏卡顿。
                        DispatchQueue.global(qos: .userInitiated).async {
                            let url = BackupService.exportToBackupDir()
                            DispatchQueue.main.async {
                                isExporting = false
                                if let url = url {
                                    // 直接弹系统分享面板，把备份文件存到「文件」App 长期保存。
                                    sharingURL = url
                                } else {
                                    message = "生成备份文件失败，请重试。"
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Label("导出备份", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting { ProgressView() }
                        }
                    }
                    Button { showRestorePicker = true } label: {
                        Label("从文件恢复（.idjbackup）", systemImage: "square.and.arrow.down")
                    }
                }
                Section {
                    Text("恢复会覆盖同名数据，建议先导出一份当前备份。代理地址与登录态不在备份范围；恢复后需重启 App 生效。")
                        .font(.caption).foregroundStyle(STVTheme.secondary)
                }
            }
            .navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showBackup = false } } }
            .sheet(isPresented: $showRestorePicker) {
                NativeDocumentPicker(contentTypes: [.idjBackup]) { url in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else {
                        showRestorePicker = false
                        message = "无法读取所选备份文件。"
                        return
                    }
                    showRestorePicker = false
                    message = BackupService.restore(from: data).message
                }
            }
            .sheet(isPresented: Binding(
                get: { sharingURL != nil },
                set: { if !$0 { sharingURL = nil } }
            )) {
                if let url = sharingURL { BackupShareSheet(url: url) { sharingURL = nil } }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    static var versionText: String {
        let i = Bundle.main.infoDictionary
        return "黑果夜剧 \(i?["CFBundleShortVersionString"] as? String ?? "") (\(i?["CFBundleVersion"] as? String ?? ""))"
    }

    private func link(_ t: String, _ icon: String, _ r: Route, trailing: String? = nil) -> some View {
        NavigationLink(value: r) {
            HStack {
                Image(systemName: icon).frame(width: 24); Text(t); Spacer()
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(STVTheme.secondary) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary)
            }.foregroundStyle(STVTheme.text).padding(14)
        }.buttonStyle(.plain)
    }

    private func row(_ t: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack { Image(systemName: icon).frame(width: 24); Text(t); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary) }
                .foregroundStyle(STVTheme.text).padding(14)
        }.buttonStyle(.plain)
    }
}
