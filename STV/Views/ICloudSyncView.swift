import SwiftUI

/// 我的 → iCloud 云端同步：展示同步开关、同步状态与可同步的数据范围。
struct ICloudSyncView: View {
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud.fill").font(.title2).foregroundStyle(STVTheme.accent)
                        Text("Apple 生态无缝互通").font(.headline).foregroundStyle(STVTheme.text)
                    }
                    Text("通过 Apple 官方 iCloud 键值存储，在登录同一 Apple ID 的 iPhone、iPad、Mac 与 Apple TV 设备间实时双向同步。")
                        .font(.subheadline).foregroundStyle(STVTheme.secondary)
                }

                card {
                    Toggle(isOn: Binding(get: { sync.enabled }, set: { on in Task { await sync.setEnabled(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("启用 iCloud 同步", systemImage: "icloud").foregroundStyle(STVTheme.text)
                            Text(sync.enabled ? "已开启 · 自动在云端同步配置信息、观看记录与追剧信息" : "关闭 · 数据仅保存在本机")
                                .font(.caption).foregroundStyle(STVTheme.secondary)
                        }
                    }.padding(14).tint(STVTheme.accent)
                }

                section("同步状态") {
                    card {
                        statusRow("当前状态", icon: "info.circle", value: sync.status)
                        statusRow("上次同步", icon: "clock", value: sync.lastSync.map(Self.dateText) ?? "从未")
                        Button { Task { await sync.syncNow() } } label: {
                            HStack(spacing: 10) {
                                if sync.syncing { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 24) }
                                Text(sync.syncing ? "同步中…" : "立即与云端同步").foregroundStyle(STVTheme.text)
                                Spacer()
                            }.padding(14)
                        }.buttonStyle(.plain).disabled(sync.syncing)
                    }
                }

                section("同步数据范围") {
                    card {
                        scopeRow("观看记录", "clock.arrow.circlepath",
                                 sub: "短剧播放集数、进度秒数与最后观看时间（同步最近 40 条），跨端自动接续起播")
                        scopeRow("追剧信息", "bookmark",
                                 sub: "收藏与追剧列表，多设备无缝保持更新")
                        scopeRow("配置信息", "slider.horizontal.3",
                                 sub: "默认主源顺序、弹幕开启偏好设置")
                    }
                }
            }.padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("iCloud 云端同步")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static func dateText(_ d: Date) -> String { dateFormatter.string(from: d) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(STVTheme.accent).padding(.horizontal, 20)
            content()
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
    }

    private func statusRow(_ t: String, icon: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(STVTheme.text)
            Text(t).foregroundStyle(STVTheme.secondary)
            Spacer()
            Text(value).foregroundStyle(STVTheme.text).multilineTextAlignment(.trailing)
        }
    }

    private func scopeRow(_ t: String, _ icon: String, sub: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(STVTheme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).foregroundStyle(STVTheme.text)
                Text(sub).font(.caption).foregroundStyle(STVTheme.secondary)
            }
        }
    }
}
