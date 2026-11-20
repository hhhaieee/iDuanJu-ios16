import SwiftUI

/// 关于页：版本信息、检查更新、项目与社区链接、开源许可。
struct AboutView: View {
    @State private var checking = false
    @State private var updateMessage: String?
    @State private var showUpdateAlert = false
    @State private var updateURL: URL?

    private var version: String { AppInfo.displayVersion }

    /// 从 AppIcon.appiconset 读取 1024 图标（系统不把 AppIcon 放进 UIImage(named:) 命名空间）。
    private var appIcon: UIImage? {
        if let url = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部版本卡片
                VStack(spacing: 8) {
                    if let icon = appIcon {
                        Image(uiImage: icon)
                            .resizable().scaledToFit()
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(LinearGradient(colors: [STVTheme.accent, STVTheme.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 84, height: 84)
                            .overlay(Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(.white))
                    }
                    Text("黑果夜剧").font(.title2.weight(.heavy)).foregroundStyle(STVTheme.text)
                    Text("版本 \(version)").font(.subheadline).foregroundStyle(STVTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 16))

                // 更新与开源
                VStack(spacing: 0) {
                    Button {
                        Task { await checkUpdate() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath").frame(width: 24)
                            Text("检查更新").foregroundStyle(STVTheme.text)
                            Spacer()
                            if checking {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary)
                            }
                        }.padding(14)
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)

                    aboutLink("GitHub · 重建版", "link", "https://github.com/hhhaieee/iDuanJu-ios16", sub: "github.com/hhhaieee/iDuanJu-ios16")
                    aboutLink("GitHub · 原作者", "link", "https://github.com/my-name-is-alan/iDuanJu", sub: "github.com/my-name-is-alan/iDuanJu")
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                // 社区
                VStack(spacing: 0) {
                    aboutLink("Telegram · 交流群组", "paperplane", "https://t.me/+YSqr4JMPdSg2YWJl", sub: "t.me/+YSqr4JMPdSg2YWJl")
                    aboutLink("Telegram · 更新频道", "paperplane", "https://t.me/+Wzj_vGsELV04OTc9", sub: "t.me/+Wzj_vGsELV04OTc9")
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                // 开源许可
                VStack(spacing: 0) {
                    NavigationLink(value: Route.licenses) {
                        HStack {
                            Image(systemName: "doc.text").frame(width: 24)
                            Text("开源许可").foregroundStyle(STVTheme.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(STVTheme.secondary)
                        }.padding(14)
                    }.buttonStyle(.plain)
                }
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                Text("黑果夜剧 由 my-name-is-alan/iDuanJu 修改而来\n尊重原作者开源贡献（GPL-3.0）")
                    .font(.caption).foregroundStyle(STVTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .alert("检查更新", isPresented: $showUpdateAlert) {
            if let u = updateURL {
                Button("前往下载") { UIApplication.shared.open(u) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(updateMessage ?? "")
        }
    }

    @ViewBuilder
    private func aboutLink(_ title: String, _ icon: String, _ url: String, sub: String) -> some View {
        if let u = URL(string: url) {
            Link(destination: u) {
                HStack {
                    Image(systemName: icon).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(STVTheme.text)
                        Text(sub).font(.caption).foregroundStyle(STVTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(STVTheme.secondary)
                }.padding(14)
            }
            .buttonStyle(.plain)
        }
    }

    /// 只比对主版本号（MARKETING_VERSION），避开 build 号 90<89 之外的历史倒退问题。
    @MainActor private func checkUpdate() async {
        checking = true
        defer { checking = false }
        let api = "https://api.github.com/repos/hhhaieee/iDuanJu-ios16/releases/latest"
        guard let url = URL(string: api),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            updateMessage = "无法连接 GitHub，请稍后重试。"
            updateURL = URL(string: "https://github.com/hhhaieee/iDuanJu-ios16/releases")
            showUpdateAlert = true
            return
        }
        // tag 形如 v2.0-90，取 v 后面、'-' 之前的主版本号
        let remote = tag.replacingOccurrences(of: "v", with: "").split(separator: "-").first.map(String.init) ?? tag
        let local = AppInfo.displayVersion
        if AppInfo.compareVersions(remote, local) > 0 {
            updateMessage = "发现新版本 \(remote)，当前 \(local)。前往 GitHub 下载后，用 TrollStore 覆盖安装即可（收藏与观看记录不会丢失）。"
            updateURL = URL(string: "https://github.com/hhhaieee/iDuanJu-ios16/releases/latest")
        } else {
            updateMessage = "已是最新版本 \(local)。"
            updateURL = nil
        }
        showUpdateAlert = true
    }
}
