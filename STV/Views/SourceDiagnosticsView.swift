import SwiftUI
import UIKit

/// 我的 → 数据源诊断。对每个片源依次探测：搜索/列表 → 详情 → 播放解析 → 媒体可达，
/// 记录每步耗时与结果；支持单选或全选资源一起诊断，可复制纯文本报告。
struct SourceDiagnosticsView: View {
    struct Step: Identifiable {
        let name: String
        let ok: Bool
        let ms: Int
        let info: String
        var id: String { name }
    }

    struct SourceResult {
        var steps: [Step] = []
        var running = false
        var done = false
        var allOK: Bool { done && !steps.isEmpty && steps.allSatisfy(\.ok) }
        var summary: String {
            if running { return "检测中…" }
            guard done else { return "未检测" }
            let ok = steps.filter(\.ok).count
            return ok == steps.count ? "全部通过 · \(steps.reduce(0) { $0 + $1.ms })ms" : "\(ok)/\(steps.count) 通过"
        }
    }

    @State private var results: [String: SourceResult] = [:]
    @State private var selected: Set<String> = []
    @State private var running = false
    @State private var copied = false

    /// 内置源（红果/黄果/各站点/Telegram）+ 插件 + 采集站，去重。
    private var sources: [DramaSource] {
        var seen = Set<String>()
        var out: [DramaSource] = []
        for s in DramaSource.builtins + Sites.all where seen.insert(s.rawValue).inserted { out.append(s) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                if running {
                    HStack(spacing: 8) {
                        ProgressView().tint(STVTheme.accent)
                        Text("正在逐个检测，每个源大约需要几秒…").font(.subheadline).foregroundStyle(STVTheme.secondary)
                    }.padding(.horizontal, 16)
                }
                ForEach(sources) { s in
                    let r = results[s.rawValue] ?? SourceResult()
                    sourceRow(s, r)
                }
                Text("红果为深度检测：会话 → 搜索 → 分页 → 详情 → 播放解析 → 流参数 → 取流吞吐（前 512 KB）→ 榜单，可定位卡在哪一环。\n其他源为标准检测：搜索/列表 → 详情 → 播放解析 → 媒体可达。")
                    .font(.caption).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
            }.padding(.vertical, 12)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("数据源诊断").navigationBarTitleDisplayMode(.inline)
        .onAppear { if selected.isEmpty { selected = Set(sources.map(\.rawValue)) } }
    }

    // MARK: UI pieces

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "检测中…" : "开始检测", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(STVTheme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(running)
                .accessibilityIdentifier("diag.run")
                Button {
                    UIPasteboard.general.string = report()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: "doc.on.doc")
                        .font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(STVTheme.glass, in: Capsule())
                        .foregroundStyle(STVTheme.text)
                }
                .disabled(results.values.allSatisfy { !$0.done })
                .accessibilityIdentifier("diag.copy")
                Spacer(minLength: 0)
                if !running {
                    Button("全选") { selected = Set(sources.map(\.rawValue)) }
                        .font(.subheadline).foregroundStyle(STVTheme.secondary)
                    Button("全不选") { selected = [] }
                        .font(.subheadline).foregroundStyle(STVTheme.secondary)
                }
            }
            Text("已选 \(selected.count)/\(sources.count) 个片源 · 点条目可单选/取消")
                .font(.caption).foregroundStyle(STVTheme.secondary)
        }
        .padding(14)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func sourceRow(_ s: DramaSource, _ r: SourceResult) -> some View {
        let isOn = selected.contains(s.rawValue)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(dotColor(r)).frame(width: 10, height: 10)
                Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.text)
                Spacer()
                Text(r.summary).font(.caption).foregroundStyle(r.done ? (r.allOK ? Color.green : .orange) : STVTheme.secondary)
                if !running {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isOn ? STVTheme.accent : STVTheme.secondary)
                }
            }.contentShape(Rectangle())
            if !r.steps.isEmpty {
                ForEach(r.steps) { st in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: st.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(st.ok ? .green : .red).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(st.name).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.text)
                                Spacer()
                                Text("\(st.ms)ms").font(.caption.monospacedDigit()).foregroundStyle(STVTheme.secondary)
                            }
                            Text(st.info).font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(3)
                        }
                    }.padding(.leading, 18)
                }
            }
        }
        .padding(14)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .opacity(isOn || running ? 1 : 0.45)
        .padding(.horizontal, 16)
        .onTapGesture { if !running { if isOn { selected.remove(s.rawValue) } else { selected.insert(s.rawValue) } } }
    }

    private func dotColor(_ r: SourceResult) -> Color {
        if r.running { return STVTheme.accent }
        guard r.done else { return STVTheme.secondary }
        return r.allOK ? .green : .orange
    }

    // MARK: Probing

    private func timed(_ name: String, _ op: @escaping () async throws -> String) async -> Step {
        let t0 = Date()
        do {
            let info = try await op()
            return Step(name: name, ok: true, ms: Int(Date().timeIntervalSince(t0) * 1000), info: info)
        } catch {
            return Step(name: name, ok: false, ms: Int(Date().timeIntervalSince(t0) * 1000), info: error.localizedDescription)
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        let targets = sources.filter { selected.contains($0.rawValue) }
        for s in targets {
            results[s.rawValue] = SourceResult(running: true)
            let steps = await probe(s)
            results[s.rawValue] = SourceResult(steps: steps, done: true)
        }
    }

    private func probe(_ s: DramaSource) async -> [Step] {
        // 红果走「深度诊断」：会话/搜索/分页/详情/解析/取流吞吐/榜单，对齐官方 App 的调用链。
        if s == .hongguo { return await probeHongguo() }
        var steps: [Step] = []
        var first: HGSeries?
        var detail: HGSeriesDetail?
        var resolved: HGResolvedVideo?

        steps.append(await timed("搜索 / 列表") {
            switch s {
            case .hongguo:
                let p = try await HongguoClient.shared.search("爱情")
                first = p.items.first
                return "返回 \(p.items.count) 条"
            case .huangguo:
                let r = try await HuangguoClient.shared.search("爱")
                first = r.first
                return "返回 \(r.count) 条"
            default:
                guard let p = Sites.provider(s) else { throw ProviderError.unsupported(s.label) }
                let r = try await p.search("a", page: 1)
                if r.items.isEmpty, let c = p.categories.first {
                    let l = try await p.list(c, page: 1)
                    first = l.items.first
                    return "\(c.title) 返回 \(l.items.count) 条"
                }
                first = r.items.first
                return "返回 \(r.items.count) 条"
            }
        })

        if let f = first {
            steps.append(await timed("详情") {
                let d: HGSeriesDetail
                switch s {
                case .hongguo: d = try await HongguoClient.shared.detail(seriesId: f.seriesId, web: false)
                case .huangguo: d = try await HuangguoClient.shared.detail(f)
                default:
                    guard let p = Sites.provider(s) else { throw ProviderError.unsupported(s.label) }
                    d = try await p.detail(f)
                }
                detail = d
                return "《\(d.title)》共 \(d.episodes.count) 集"
            })
        } else {
            return steps
        }

        if let f = first, let d = detail, let ep = d.episodes.first {
            steps.append(await timed("播放解析") {
                let r: HGResolvedVideo
                switch s {
                case .hongguo: r = try await HongguoClient.shared.resolve(vid: ep.vid)
                case .huangguo: r = try await HuangguoClient.shared.resolve(seriesId: f.seriesId, episode: ep)
                default:
                    guard let p = Sites.provider(s) else { throw ProviderError.unsupported(s.label) }
                    r = try await p.resolve(f, ep)
                }
                resolved = r
                let st = r.streams
                guard !st.isEmpty else { throw ProviderError.upstream("没有可用流") }
                return "\(st.count) 条流 · \(st.first?.quality ?? "自动") · \(st.first?.kind.rawValue ?? "")"
            })
        } else {
            return steps
        }

        if let r = resolved, let stream = r.streams.first {
            steps.append(await timed("媒体可达") {
                let resp = try await SiteHTTP.shared.raw(stream.url, referer: stream.headers["Referer"], headers: stream.headers)
                let code = resp.1
                guard (200..<400).contains(code) else { throw ProviderError.upstream("HTTP \(code)") }
                return "HTTP \(code) · 响应 \(resp.0.count) 字节"
            })
        }
        return steps
    }

    // MARK: Hongguo deep probe

    /// 红果深度检测：会话 → 搜索 → 分页 → 详情 → 播放解析 → 流参数 → 取流吞吐 → 榜单。
    /// 每一步都记录真实耗时，卡在哪一环一眼能看出来。
    private func probeHongguo() async -> [Step] {
        var steps: [Step] = []
        var first: HGSeries?
        var page: HGPage?
        var detail: HGSeriesDetail?
        var resolved: HGResolvedVideo?

        steps.append(await timed("游客会话 / 设备") {
            guard let dev = HGDevice.load() else {
                throw ProviderError.upstream("未注册设备（首次使用会现场注册）")
            }
            let age = dev.registeredAt.map { Int(Date().timeIntervalSince1970 - $0) } ?? -1
            let ageText = age < 0 ? "注册时间未知" : (age > 3600 ? "\(age / 3600) 小时前" : "\(max(0, age)) 秒前")
            let stale = dev.isStaleForPlayback
            return "device \(dev.deviceId.prefix(6))… · 注册于\(ageText)" + (stale ? " · ⚠️ 超过 7 分钟，取流可能被软拒" : " · 会话新鲜")
        })

        steps.append(await timed("搜索") {
            let p = try await HongguoClient.shared.search("爱情")
            first = p.items.first
            page = p
            guard !p.items.isEmpty else { throw ProviderError.upstream("返回 0 条") }
            return "\(p.items.count) 条" + (p.hasMore ? " · 有下一页" : "")
        })

        steps.append(await timed("搜索分页") {
            guard let cursor = page?.nextCursor ?? page?.nextOffset.map({ String($0) }) else {
                return "单页结果，跳过"
            }
            let p = try await HongguoClient.shared.search("爱情", cursor: cursor)
            return "第 2 页 \(p.items.count) 条" + (p.hasMore ? " · 仍有更多" : "")
        })

        guard let f = first else { return steps }

        steps.append(await timed("剧集详情") {
            let d = try await HongguoClient.shared.detail(seriesId: f.seriesId, web: false)
            detail = d
            guard !d.episodes.isEmpty else { throw ProviderError.upstream("没有分集") }
            return "《\(d.title)》· \(d.episodes.count) 集"
        })

        guard let d = detail, let ep = d.episodes.first else { return steps }

        steps.append(await timed("播放解析") {
            let r = try await HongguoClient.shared.resolve(vid: ep.vid)
            resolved = r
            guard !r.streams.isEmpty else {
                throw ProviderError.upstream(r.err ?? "没有可用流")
            }
            return "\(r.streams.count) 条流" + (r.key?.isEmpty == false ? " · CENC" : " · 明文")
        })

        if let s = resolved?.streams.first {
            steps.append(await timed("流参数") {
                var parts: [String] = []
                if let q = s.quality { parts.append(q) }
                if let w = s.width, let h = s.height { parts.append("\(w)×\(h)") }
                if let b = s.bitrate { parts.append(String(format: "%.1f Mbps", Double(b) / 1_000_000)) }
                if let c = s.codec { parts.append(c) }
                parts.append(s.kind.rawValue)
                parts.append(s.key.isEmpty ? "未加密" : "加密(key \(s.key.count) 位)")
                if let host = URL(string: s.url)?.host { parts.append(host) }
                return parts.joined(separator: " · ")
            })

            steps.append(await timed("取流吞吐（前 512 KB）") {
                let r = try await Self.measure(stream: s, bytes: 512 * 1024)
                return r
            })
        }

        steps.append(await timed("榜单") {
            let p = try await HongguoClient.shared.rank(sub: .hot, genre: .all)
            return "热播 \(p.items.count) 条" + (p.items.first.map { " · 首位《\($0.title)》" } ?? "")
        })

        return steps
    }

    /// 只读前 N 字节就断开，用来测真实 CDN 首发速度与带宽（不浪费流量）。
    private static func measure(stream: HGStream, bytes limit: Int) async throws -> String {
        guard let url = URL(string: stream.url), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw ProviderError.upstream("流地址无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        for (k, v) in stream.headers { req.setValue(v, forHTTPHeaderField: k) }
        let t0 = Date()
        let (seq, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(code) else { throw ProviderError.upstream("HTTP \(code)") }
        var got = 0
        var firstByteMS: Double = -1
        for try await _ in seq {
            if got == 0 { firstByteMS = Date().timeIntervalSince(t0) * 1000 }
            got += 1
            if got >= limit { break }
        }
        let dt = max(Date().timeIntervalSince(t0), 0.001)
        guard got > 0 else { throw ProviderError.upstream("连接成功但没有数据") }
        let mbps = Double(got) * 8 / dt / 1_000_000
        return String(format: "HTTP %d · %.0f KB · 首字节 %.0f ms · %.1f Mbps", code, Double(got) / 1024, firstByteMS, mbps)
    }

    private func report() -> String {
        var lines = ["数据源诊断报告 · \(ProfileView.versionText)", "时间：\(Date())", ""]
        for s in sources {
            guard let r = results[s.rawValue], r.done else { continue }
            lines.append("【\(s.label)】\(r.summary)")
            for st in r.steps { lines.append("  \(st.ok ? "✓" : "✗") \(st.name) \(st.ms)ms · \(st.info)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
