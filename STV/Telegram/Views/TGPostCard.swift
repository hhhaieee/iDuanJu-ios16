import SwiftUI

enum TGFmt {
    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
        return f.string(from: d)
    }
}

/// What a post card asks its feed to do.
struct TGActions {
    var openImages: (TGPost, Int) -> Void = { _, _ in }
    var playVideo: (TGPost, Int) -> Void = { _, _ in }
    var download: (TGPost, Int) -> Void = { _, _ in }
    var block: (TGPost) -> Void = { _ in }
    var bot: (TGBotLink) -> Void = { _ in }
}

/// One post in the 朋友圈-style feed: avatar · name · time, text, media grid, buttons, link preview.
struct TGPostCard: View {
    let post: TGPost
    let channel: TGChannel?
    var verdict: TGVerdict = .pass
    var actions = TGActions()
    @State private var expanded = false
    @State private var unfolded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if verdict.blocked && !unfolded {
            folded
        } else {
            card
        }
    }

    private var folded: some View {
        Button { withAnimation(.snappy) { unfolded = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.caption)
                Text("已屏蔽 · \(channel?.displayName ?? "@" + post.channel)").font(.caption.weight(.semibold))
                Text(verdict.reason).font(.caption).lineLimit(1)
                Spacer()
                Text("展开").font(.caption)
            }
            .foregroundStyle(STVTheme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tg.folded.\(post.id)")
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(channel?.displayName ?? "@" + post.channel).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.accent).lineLimit(1)
                    if channel?.isAdult == true { Text("18+").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 4).background(Color.red.opacity(0.7), in: Capsule()) }
                    Spacer(minLength: 0)
                    if verdict.blocked { Label("已屏蔽", systemImage: "eye.slash").font(.caption2).foregroundStyle(STVTheme.secondary) }
                }
                if !post.forwardedFrom.isEmpty {
                    Text("转发自 \(post.forwardedFrom)").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                if !post.text.isEmpty { textBlock }
                if !post.media.isEmpty { TGMediaGrid(post: post, actions: actions) }
                if let p = post.preview, !(p.title.isEmpty && p.desc.isEmpty) { previewCard(p) }
                if !post.buttons.isEmpty { buttons }
                footer
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.post.\(post.id)")
    }

    private var avatar: some View {
        Group {
            if let a = channel?.avatar, !a.isEmpty { CoverView(url: a, corner: 20) }
            else {
                Circle().fill(STVTheme.elevated)
                    .overlay(Text(String((channel?.displayName ?? post.channel).prefix(1))).font(.headline).foregroundStyle(STVTheme.text))
            }
        }
        .frame(width: 40, height: 40).clipShape(Circle())
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributed).font(.body).foregroundStyle(STVTheme.text).lineLimit(expanded ? nil : 8)
                .tint(STVTheme.accent)
                .textSelection(.enabled)
            if !expanded && (post.text.count > 260 || post.text.filter { $0 == "\n" }.count > 7) {
                Button("全文") { expanded = true }.font(.subheadline).foregroundStyle(STVTheme.accent)
            }
        }
    }

    /// Plain text with tappable URLs.
    private var attributed: AttributedString {
        var a = AttributedString(post.text)
        let ns = post.text as NSString
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: post.text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url, let r = Range(m.range, in: post.text),
                      let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
                a[lo..<hi].link = url
            }
        }
        return a
    }

    private func previewCard(_ p: TGLinkPreview) -> some View {
        Button { if let u = URL(string: p.url) { openURL(u) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(STVTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    if !p.site.isEmpty { Text(p.site).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.accent) }
                    if !p.title.isEmpty { Text(p.title).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.text).lineLimit(2) }
                    if !p.desc.isEmpty { Text(p.desc).font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(3) }
                }
                Spacer(minLength: 0)
                if !p.image.isEmpty { CoverView(url: p.image, corner: 6).frame(width: 54, height: 54) }
            }
            .padding(8)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            ForEach(Array(post.buttons.enumerated()), id: \.offset) { _, b in
                Button {
                    if let bot = TGBotLink(url: b.url) { actions.bot(bot) } else if let u = URL(string: b.url) { openURL(u) }
                } label: {
                    Text(b.text).font(.subheadline).foregroundStyle(STVTheme.text).frame(maxWidth: .infinity).frame(height: 34)
                        .background(STVTheme.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(TGFmt.date(post.date)).font(.caption).foregroundStyle(STVTheme.secondary)
            if !post.views.isEmpty { Label(post.views, systemImage: "eye").font(.caption).foregroundStyle(STVTheme.secondary) }
            Spacer()
            ForEach(post.botLinks, id: \.self) { b in
                Button { actions.bot(b) } label: { Label("@\(b.bot)", systemImage: "cpu").font(.caption) }
                    .foregroundStyle(STVTheme.accent).buttonStyle(.plain)
            }
            if post.media.contains(where: { $0.video != nil || $0.kind == .photo }) {
                Button { actions.download(post, firstDownloadable) } label: { Image(systemName: "arrow.down.circle") }
                    .foregroundStyle(STVTheme.secondary).buttonStyle(.plain)
                    .accessibilityLabel("下载").accessibilityIdentifier("tg.download.\(post.id)")
            }
            Button { if let u = URL(string: post.permalink) { openURL(u) } } label: { Image(systemName: "paperplane") }
                .foregroundStyle(STVTheme.secondary).buttonStyle(.plain).accessibilityLabel("在 Telegram 中打开")
        }
    }

    private var firstDownloadable: Int { post.media.firstIndex { $0.video != nil } ?? 0 }

    @ViewBuilder private var menu: some View {
        Button { actions.block(post) } label: { Label("加入屏蔽…", systemImage: "hand.raised") }
        if !post.media.isEmpty {
            Button { for i in post.media.indices { actions.download(post, i) } } label: { Label("下载全部媒体（\(post.media.count)）", systemImage: "arrow.down.circle") }
        }
        Button { UIPasteboard.general.string = post.permalink } label: { Label("复制链接", systemImage: "link") }
        if !post.text.isEmpty { Button { UIPasteboard.general.string = post.text } label: { Label("复制文字", systemImage: "doc.on.doc") } }
        Button { if let u = URL(string: post.permalink) { openURL(u) } } label: { Label("在 Telegram 中打开", systemImage: "paperplane") }
    }
}

/// 1 item: full width; 2–4: 2 columns; 5+: 3 columns (朋友圈 grid).
struct TGMediaGrid: View {
    let post: TGPost
    var actions: TGActions
    var body: some View {
        let m = post.media
        if m.count == 1 {
            cell(0).aspectRatio(m[0].kind == .photo ? 4 / 3 : 16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
        } else {
            let cols = m.count <= 4 ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                ForEach(m.indices, id: \.self) { i in cell(i).aspectRatio(1, contentMode: .fit) }
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        let it = post.media[i]
        return Button {
            if it.kind == .photo { actions.openImages(post, i) } else { actions.playVideo(post, i) }
        } label: {
            ZStack {
                CoverView(url: it.thumb, corner: 8).blur(radius: it.spoiler ? 18 : 0)
                if it.kind != .photo {
                    Image(systemName: it.video == nil ? "paperplane.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                    if it.duration > 0 {
                        Text(Fmt.clock(it.duration)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tg.media.\(post.id).\(i)")
    }
}
