import SwiftUI
import UIKit

/// 播放调试日记：汇总应用运行/崩溃日志、站点事件日志与设备信息，供用户一键复制给开发者。
/// 只读取本机已有日志，不上传、不联网。
struct PlayDebugLogView: View {
    @State private var copied = false

    private var header: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        var lines = [
            "播放调试日记 · \(ProfileView.versionText) (build \(build))",
            "设备：\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)",
            "时间：\(Date())",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private var crashLog: String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("crash.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return "暂无崩溃记录" }
        // 只保留最近部分，避免报告过长
        let tail = text.suffix(6000)
        return String(tail)
    }

    private var siteLog: String {
        let lines = SiteLog.all()
        return lines.isEmpty ? "暂无站点事件记录" : lines.joined(separator: "\n")
    }

    private var fullReport: String {
        [header, "===== 崩溃 / 运行日志 =====", crashLog, "", "===== 站点事件日志 =====", siteLog].joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("把下面的内容复制发给开发者，可帮助定位闪退、播放失败、片源不可用等问题。日志只包含运行状态，不含账号密码等隐私信息。")
                    .font(.caption).foregroundStyle(STVTheme.secondary)

                logCard(title: "崩溃 / 运行日志", content: crashLog)
                logCard(title: "站点事件日志", content: siteLog)
            }
            .padding(16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("播放调试日记").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制全部") {
                    UIPasteboard.general.string = fullReport
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
        }
    }

    @ViewBuilder
    private func logCard(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.text)
            Text(content).font(.caption2.monospaced()).foregroundStyle(STVTheme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
