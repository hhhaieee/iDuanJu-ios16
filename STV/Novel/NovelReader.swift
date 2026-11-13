import SwiftUI
import UIKit
import AVFoundation

// MARK: - Look (colours sampled from WeRead) and TextKit layout

enum NovelLayout {
    struct Palette {
        var bg: Color, panel: Color, track: Color, thumb: Color
        var text: UIColor, secondary: Color
        var ink: Color { Color(text) }
    }
    static let accent = Color(red: 0.19, green: 0.59, blue: 0.08)   // #309714

    @MainActor static func palette(_ t: NovelPrefs.Theme) -> Palette {
        switch t {
        case .white:
            Palette(bg: .white, panel: Color(white: 0.965), track: Color(white: 0.90), thumb: .white,
                text: UIColor(white: 0.12, alpha: 1), secondary: Color(white: 0.56))
        case .cream:
            Palette(bg: Color(hex: 0xF7F0DE), panel: Color(hex: 0xF1E8D0), track: Color(hex: 0xE6DABE), thumb: Color(hex: 0xFBF6EA),
                text: UIColor(red: 0.22, green: 0.18, blue: 0.13, alpha: 1), secondary: Color(hex: 0x9A8B70))
        case .green:
            Palette(bg: Color(hex: 0xBFEDC4), panel: Color(hex: 0xB8EDBD), track: Color(hex: 0xA9D9AF), thumb: Color(hex: 0xCCEFCF),
                text: UIColor(red: 0.12, green: 0.16, blue: 0.12, alpha: 1), secondary: Color(hex: 0x6E8E72))
        case .night:
            Palette(bg: Color(hex: 0x111111), panel: Color(hex: 0x1C1C1C), track: Color(hex: 0x2B2B2B), thumb: Color(hex: 0x4A4A4A),
                text: UIColor(white: 0.58, alpha: 1), secondary: Color(white: 0.40))
        }
    }

    static func font(_ size: CGFloat, serif: Bool, bold: Bool = false) -> UIFont {
        if serif, let f = UIFont(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size) { return f }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Horizontal page margin for the 边距 slider (0…1).
    static func margin(_ m: Double) -> CGFloat { 12 + 28 * m }

    /// Chapter text → styled string. Characters are not changed, so ranges map 1:1 to chapter offsets.
    /// The first paragraph is the chapter heading when it matches `title`.
    static func attributed(_ text: String, title: String, size: CGFloat, lineSpacing: Double, indent: Bool = true,
        serif: Bool, color: UIColor) -> NSAttributedString {
        attributed(text, title: title, size: size, lineSpacing: lineSpacing, indent: indent,
            font: font(size, serif: serif), bold: font(size * 1.3, serif: serif, bold: true), color: color)
    }

    static func attributed(_ text: String, title: String, size: CGFloat, lineSpacing: Double, indent: Bool,
        font: UIFont, bold: UIFont, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let gap = size * (0.25 + 0.75 * lineSpacing)          // WeRead 适中 ≈ 0.6 em between lines
        let body = NSMutableParagraphStyle()
        body.lineSpacing = gap
        body.paragraphSpacing = gap * 0.35
        body.firstLineHeadIndent = indent ? size * 2 : 0
        body.alignment = .justified
        let head = NSMutableParagraphStyle()
        head.lineSpacing = gap * 0.6
        head.paragraphSpacing = size * 1.4
        let ns = text as NSString
        var first = true
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let piece = ns.substring(with: enclosing)
            let isHead = first && piece.trimmingCharacters(in: .newlines) == title
            first = false
            out.append(NSAttributedString(string: piece, attributes: [
                            .font: isHead ? bold : font,
                            .foregroundColor: color,
                            .paragraphStyle: isHead ? head : body,
            ]))
        }
        return out
    }

    /// Back-compat for tests: `spacing` 0/1/2 = 紧凑 / 适中 / 宽松.
    static func attributed(_ text: String, title: String, size: CGFloat, spacing: Int, serif: Bool, color: UIColor) -> NSAttributedString {
        attributed(text, title: title, size: size, lineSpacing: [0.1, 0.5, 0.9][max(0, min(2, spacing))], serif: serif, color: color)
    }

    /// Page ranges for a page of `size` (same container settings as `NovelTextView`).
    static func paginate(_ s: NSAttributedString, size: CGSize) -> [NSRange] {
        guard s.length > 0, size.width > 20, size.height > 20 else { return [NSRange(location: 0, length: s.length)] }
        let storage = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        var pages: [NSRange] = []
        while true {
            let tc = NSTextContainer(size: size)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let g = lm.glyphRange(for: tc)
            if g.length == 0 { break }
            pages.append(lm.characterRange(forGlyphRange: g, actualGlyphRange: nil))
            if NSMaxRange(g) >= lm.numberOfGlyphs { break }
        }
        return pages.isEmpty ? [NSRange(location: 0, length: s.length)] : pages
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Reader

/// Commands from SwiftUI into the UIKit pager (taps / swipes are handled inside the pager itself).
@MainActor final class NovelPagerHandle {
    weak var controller: NovelPagerController?
    var version = 0
}

/// Paged reading (仿真 / 滑动 / 覆盖 / 无动画).
struct NovelPagedView: UIViewControllerRepresentable {
    let paginator: NovelPaginator
    let handle: NovelPagerHandle
    var start: NovelPageRef
    var style: NovelTurnStyle
    var insets: UIEdgeInsets
    var highlight: NovelHighlight?
    var version: Int
    var onPage: (NovelPageRef) -> Void
    var onCenter: () -> Void
    var onSwipeUp: () -> Void

    func makeUIViewController(context: Context) -> NovelPagerController {
        let c = NovelPagerController(paginator: paginator, start: start)
        c.insets = insets
        c.setStyle(style)
        handle.controller = c
        handle.version = version
        return c
    }

    func updateUIViewController(_ c: NovelPagerController, context: Context) {
        c.onPageChange = onPage
        c.onCenterTap = onCenter
        c.onSwipeUp = onSwipeUp
        let relayout = handle.version != version || c.insets != insets
        c.insets = insets
        handle.version = version
        c.setStyle(style)
        c.highlight = highlight
        if relayout || c.current != start { c.show(start) }
    }
}

/// Reader after WeRead (iOS): chapter name top-left, page number bottom-right, interactive page turning,
/// tap the middle or swipe up for the toolbar (目录 · 书籍 · 进度 · 亮度 · 字体) and 听书.
struct NovelReaderView: View {
    let book: NovelBook
    @ObservedObject private var store = NovelStore.shared
    @ObservedObject private var prefs = NovelPrefs.shared
    @ObservedObject private var fonts = NovelFonts.shared
    @ObservedObject private var loader = NovelWebLoader.shared
    @Environment(\.dismiss) private var dismiss

    @State private var paginator: NovelPaginator
    @State private var handle = NovelPagerHandle()
    @State private var ref = NovelPageRef(chapter: 0, index: 0)
    @State private var version = 0
    @State private var insets = UIEdgeInsets.zero
    @State private var ready = false
    @State private var menu = false
    @State private var tab: Tab?
    @State private var hint = true
    @State private var lastLight: NovelPrefs.Theme = .white
    @State private var autoTurn = false
    @StateObject private var speaker = NovelSpeaker()
    @State private var opened = Date()
    @State private var brightness = 0.5
    @State private var tocSearch = false
    @State private var query = ""
    @State private var hits: [(chapter: Int, offset: Int, snippet: String)] = []
    enum Tab: Equatable { case toc, info, progress, light, font, fonts, turn, listen }

    init(book: NovelBook) {
        self.book = book
        _paginator = State(initialValue: NovelPaginator(book: book))
    }

    private var pal: NovelLayout.Palette { NovelLayout.palette(prefs.theme) }
    private var hMargin: CGFloat { NovelLayout.margin(prefs.margin) }
    private var totalChars: Int { book.chapters.last?.end ?? 0 }
    private var offsetInChapter: Int { paginator.style == nil ? 0 : paginator.range(ref).location }
    private var bookOffset: Int { (book.chapters.indices.contains(ref.chapter) ? book.chapters[ref.chapter].start : 0) + offsetInChapter }
    private var fraction: Double { totalChars > 0 ? Double(bookOffset) / Double(totalChars) : 0 }
    private var highlight: NovelHighlight? { speaker.sentence.map { NovelHighlight(chapter: speaker.chapter, range: $0) } }
    private func title(_ i: Int) -> String { book.chapters.indices.contains(i) ? book.chapters[i].title : "" }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                pal.bg.ignoresSafeArea()
                if ready {
                    if prefs.turn == .scroll {
                        scrollReader(geo)
                    } else {
                        NovelPagedView(paginator: paginator, handle: handle, start: ref, style: prefs.turn, insets: insets,
                            highlight: highlight, version: version,
                            onPage: { r in ref = r; save() },
                            onCenter: { menu ? hideMenu() : showMenu() },
                            onSwipeUp: { showMenu() })
                            .ignoresSafeArea()
                    }
                }
                if hint && !menu {
                    Text("↑上滑显示工具栏").font(.system(size: 12)).foregroundStyle(pal.secondary)
                        .padding(.bottom, 8).transition(.opacity).allowsHitTesting(false)
                }
                if book.isWeb, let err = loader.error(book, ref.chapter), !menu {
                    Button { loader.retry(book, ref.chapter) } label: {
                        Label("重新加载本章", systemImage: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 16).frame(height: 40).background(Capsule().fill(pal.panel))
                    }
                    .buttonStyle(.plain).foregroundStyle(pal.ink).padding(.bottom, 90)
                    .accessibilityHint(err)
                    .accessibilityIdentifier("novel.retry")
                }
                if speaker.active && !menu { miniPlayer.padding(.trailing, 16).padding(.bottom, 40).frame(maxWidth: .infinity, alignment: .trailing) }
                if menu { menuLayer.transition(.opacity) }
            }
            .onAppear {
                configure(geo); restore(); brightness = Double(screen?.brightness ?? 0.5)
                if book.isWeb {
                    loader.prefetch(book, around: ref.chapter)
                    Task { _ = try? await loader.refreshToc(book) }
                }
            }
            .onChange(of: layoutKey(geo)) { _ in relayout(geo) }
        }
        .statusBarHidden(!menu)
        .preferredColorScheme(prefs.theme == .night ? .dark : .light)
        .onChange(of: speaker.sentence) { s in if let s { follow(s) } }
        .onChange(of: loader.revision) { _ in
            guard book.isWeb else { return }
            let c = ref.chapter, o = offsetInChapter
            paginator.invalidate()
            ref = paginator.ref(chapter: c, offset: o)
            version += 1
        }
        .onChange(of: ref.chapter) { c in if book.isWeb { loader.prefetch(book, around: c) } }
        .onDisappear { store.addReadTime(book, Date().timeIntervalSince(opened)); speaker.stop() }
        .task {
            // WeRead shows the hint briefly when a book opens.
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.6)) { hint = false }
        }
        .task(id: autoTurn) {
            while autoTurn, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if autoTurn, !menu { handle.controller?.turn(+1) }
            }
        }
    }

    // MARK: Layout

    private func layoutKey(_ geo: GeometryProxy) -> String {
        "\(prefs.fontSize)-\(prefs.lineSpacing)-\(prefs.margin)-\(prefs.fontID)-\(prefs.indent)-\(prefs.theme.rawValue)-\(fonts.revision)-\(Int(geo.size.width))x\(Int(geo.size.height))"
    }

    private func pageStyle(_ geo: GeometryProxy) -> NovelPageStyle {
        let p = pal
        return NovelPageStyle(size: CGSize(width: geo.size.width - 2 * hMargin, height: geo.size.height - 62),
            fontSize: prefs.fontSize, lineSpacing: prefs.lineSpacing, indent: prefs.indent, fontID: prefs.fontID,
            text: p.text, secondary: UIColor(p.secondary), background: UIColor(p.bg),
            highlight: UIColor(NovelLayout.accent).withAlphaComponent(0.22))
    }

    private func configure(_ geo: GeometryProxy) {
        _ = fonts.isReady(prefs.fontID)
        insets = UIEdgeInsets(top: geo.safeAreaInsets.top, left: hMargin + geo.safeAreaInsets.leading,
            bottom: geo.safeAreaInsets.bottom, right: hMargin + geo.safeAreaInsets.trailing)
        paginator.configure(pageStyle(geo))
    }

    /// Re-paginates and stays on the page holding the same text.
    private func relayout(_ geo: GeometryProxy) {
        let chapter = ref.chapter, offset = offsetInChapter
        configure(geo)
        ref = paginator.ref(chapter: chapter, offset: offset)
        version += 1
    }

    // MARK: Scroll mode (continuous across chapters)

    private func scrollReader(_ geo: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    ForEach(book.chapters.indices, id: \.self) { i in
                        NovelTextView(text: scrollText(i))
                            .id(i)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("novel.scroll")) } action: { f in
                            trackScroll(i, f)
                        }
                    }
                }
                .padding(.horizontal, hMargin).padding(.top, 36).padding(.bottom, 80)
            }
            .coordinateSpace(name: "novel.scroll")
            .scrollIndicators(.hidden)
            .overlay(alignment: .topLeading) {
                Text(title(ref.chapter)).font(.system(size: 12)).foregroundStyle(pal.secondary)
                    .padding(.horizontal, hMargin).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).background(pal.bg)
            }
            .onAppear { proxy.scrollTo(ref.chapter, anchor: .top) }
            .onChange(of: version) { _ in proxy.scrollTo(ref.chapter, anchor: .top) }
            .onTapGesture { menu ? hideMenu() : showMenu() }
            .onChange(of: speaker.sentence) { s in
                // 听书 in scroll mode: keep the sentence on screen (anchor at the same relative position).
                guard let s, book.chapters.indices.contains(speaker.chapter) else { return }
                let len = max(1, book.chapters[speaker.chapter].length)
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(speaker.chapter, anchor: UnitPoint(x: 0, y: min(1, Double(s.location) / Double(len)))) }
            }
        }
    }

    private func scrollText(_ i: Int) -> NSAttributedString {
        let t = paginator.chapter(i).text
        guard let h = highlight, h.chapter == i, NSMaxRange(h.range) <= t.length else { return t }
        let m = NSMutableAttributedString(attributedString: t)
        m.addAttribute(.backgroundColor, value: UIColor(NovelLayout.accent).withAlphaComponent(0.22), range: h.range)
        return m
    }

    private func trackScroll(_ i: Int, _ f: CGRect) {
        guard f.minY <= 40, f.maxY > 40, f.height > 0 else { return }
        let len = book.chapters.indices.contains(i) ? book.chapters[i].length : 0
        let r = paginator.ref(chapter: i, offset: Int(Double(len) * Double((40 - f.minY) / f.height)))
        if r != ref { ref = r; save() }
    }

    // MARK: Toolbar and panels

    private var menuLayer: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("novel.back")
                Spacer()
            }
            .foregroundStyle(pal.ink)
            .padding(.horizontal, 6)
            .background(pal.bg.ignoresSafeArea(edges: .top))
            Color.clear.contentShape(Rectangle()).onTapGesture { hideMenu() }
                .overlay(alignment: .bottomTrailing) { if tab != .listen { listenButton.padding(.trailing, 16).padding(.bottom, 12) } }
            VStack(spacing: 0) {
                if let tab { panel(tab).padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6) }
                toolbar
            }
            .background(pal.panel.ignoresSafeArea(edges: .bottom))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: tab == nil ? 0 : 16, topTrailingRadius: tab == nil ? 0 : 16))
            .shadow(color: .black.opacity(tab == nil ? 0.04 : 0.10), radius: 8, y: -2)
        }
    }

    private var toolbar: some View {
        HStack {
            toolIcon(.toc, "list.bullet", "目录")
            toolIcon(.info, tab == .info ? "safari.fill" : "safari", "书籍")
            toolIcon(.progress, "circle.and.line.horizontal", "进度")
            toolIcon(.light, tab == .light ? "sun.max.fill" : "sun.max", "亮度")
            toolIcon(.font, nil, "设置")
        }
        .padding(.horizontal, 12).frame(height: 56)
    }

    private func toolIcon(_ t: Tab, _ icon: String?, _ name: String) -> some View {
        let on = tab == t || (t == .font && (tab == .fonts || tab == .turn))
        return Button { withAnimation(.easeOut(duration: 0.18)) { tab = on ? nil : t } } label: {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 21, weight: .light)) }
                else { Text("A").font(.system(size: 23, weight: .light)) }
            }
            .foregroundStyle(on ? NovelLayout.accent : pal.ink.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(name).accessibilityIdentifier("novel.menu.\(name)")
    }

    @ViewBuilder private func panel(_ t: Tab) -> some View {
        switch t {
        case .toc: tocPanel
        case .info: infoPanel
        case .progress: progressPanel
        case .light: lightPanel
        case .font: fontPanel
        case .fonts: fontsPanel
        case .turn: turnPanel
        case .listen: listenPanel
        }
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(pal.ink)
                .frame(maxWidth: .infinity, minHeight: 40).background(Capsule().fill(pal.track.opacity(0.75)))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, on: Bool, id: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? NovelLayout.accent : pal.ink)
                .padding(.horizontal, 12).frame(minHeight: 32)
                .background(Capsule().fill(on ? NovelLayout.accent.opacity(0.12) : pal.track.opacity(0.6)))
                .overlay(Capsule().stroke(on ? NovelLayout.accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "novel.chip.\(title)")
    }

    private func subHeader(_ t: String) -> some View {
        HStack {
            Button { withAnimation(.easeOut(duration: 0.18)) { tab = .font } } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Text(t).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(pal.ink)
    }

    // 进度
    private var progressPanel: some View {
        let read = store.readTime[book.id] ?? 0
        let left = Double(totalChars - bookOffset) / 450 / 60      // ~450 字/分钟
        return VStack(spacing: 18) {
            HStack(spacing: 0) {
                stat("\(Int((fraction * 100).rounded()))", "%", book.isWeb ? "还剩 \(book.chapters.count - ref.chapter - 1) 章"
                    : left >= 1 ? "约\(Int(left.rounded()))小时后读完" : "约\(max(1, Int(left * 60)))分钟后读完")
                Divider().frame(height: 34)
                stat(read >= 3600 ? "\(Int(read / 3600))" : "\(Int(read / 60))", read >= 3600 ? "小时\(Int(read.truncatingRemainder(dividingBy: 3600) / 60))分钟" : "分钟", "阅读时长")
                Divider().frame(height: 34)
                stat("\(ref.chapter + 1)", "/\(book.chapters.count)", "章节")
            }
            HStack(spacing: 0) {
                Button { go(ref.chapter - 1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 44) }.disabled(ref.chapter == 0)
                PillSlider(value: Binding(get: { fraction }, set: { jump(toFraction: $0) }), track: .clear, thumb: pal.thumb)
                Button { go(ref.chapter + 1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 44) }.disabled(ref.chapter + 1 >= book.chapters.count)
            }
            .foregroundStyle(pal.ink).background(Capsule().fill(pal.track))
            HStack(spacing: 14) {
                pill("回到本章开头") { go(ref.chapter) }
                if prefs.turn != .scroll {
                    pill(autoTurn ? "关闭自动翻页" : "开启自动翻页") { autoTurn.toggle(); if autoTurn { hideMenu() } }
                }
            }
        }
    }

    private func stat(_ big: String, _ unit: String, _ sub: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(big).font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(unit).font(.system(size: 12))
            }
            .foregroundStyle(pal.ink)
            Text(sub).font(.system(size: 11)).foregroundStyle(pal.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // 亮度 / 颜色
    private var lightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            PillSlider(value: Binding(get: { brightness }, set: { brightness = $0; screen?.brightness = CGFloat($0) }),
                track: pal.track, thumb: pal.thumb, leading: AnyView(Image(systemName: "sun.min").font(.system(size: 14)).foregroundStyle(pal.ink)))
            Text("颜色").font(.system(size: 12)).foregroundStyle(pal.secondary)
            HStack(spacing: 12) {
                ForEach(NovelPrefs.Theme.allCases, id: \.self) { t in
                    let on = t == prefs.theme
                    RoundedRectangle(cornerRadius: 10).fill(NovelLayout.palette(t).bg)
                        .overlay { if t == .night { Image(systemName: "moon.fill").foregroundStyle(Color(hex: 0x4D7CFE)) } }
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? NovelLayout.accent : .black.opacity(0.06), lineWidth: on ? 1.5 : 1))
                        .frame(height: 40)
                        .onTapGesture { prefs.theme = t }
                        .accessibilityIdentifier("novel.theme.\(t.rawValue)")
                }
            }
        }
    }

    // 字体
    private var fontPanel: some View {
        VStack(spacing: 14) {
            PillSlider(value: Binding(get: { (prefs.fontSize - 12) / 18 }, set: { prefs.fontSize = (12 + $0 * 18).rounded() }),
                track: pal.track, thumb: pal.thumb, label: "\(Int(prefs.fontSize))",
                leading: AnyView(Text("A").font(.system(size: 12)).foregroundStyle(pal.ink)),
                trailing: AnyView(Text("A").font(.system(size: 17)).foregroundStyle(pal.ink)))
                .accessibilityIdentifier("novel.font.size")
            HStack(spacing: 14) {
                PillSlider(value: $prefs.margin, track: pal.track, thumb: pal.thumb, label: "边距",
                    trailing: AnyView(Text("大").font(.system(size: 13)).foregroundStyle(pal.ink)))
                PillSlider(value: $prefs.lineSpacing, track: pal.track, thumb: pal.thumb, label: "行距",
                    leading: AnyView(Text("紧").font(.system(size: 13)).foregroundStyle(pal.ink)),
                    trailing: AnyView(Text("松").font(.system(size: 13)).foregroundStyle(pal.ink)))
            }
            HStack(spacing: 12) {
                menuPill(NovelFonts.all.first { $0.id == prefs.fontID }?.name ?? "字体样式", id: "novel.fonts") { tab = .fonts }
                menuPill(prefs.indent ? "首行缩进" : "不缩进", id: "novel.indent") { prefs.indent.toggle() }
                menuPill(prefs.turn.label, id: "novel.turn") { tab = .turn }
            }
        }
    }

    private func menuPill(_ t: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) { Text(t).lineLimit(1); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(pal.ink)
                .frame(maxWidth: .infinity, minHeight: 40).background(Capsule().fill(pal.track.opacity(0.75)))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    // 字体样式
    private var fontsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            subHeader("字体样式")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(NovelFonts.all) { f in fontRow(f) }
                }
            }
            .frame(maxHeight: 330)
        }
    }

    private func fontRow(_ f: NovelFonts.Entry) -> some View {
        let ready = fonts.isReady(f.id)
        let on = prefs.fontID == f.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(f.name).font(Font(NovelFonts.font(f.id, size: 17) as CTFont)).foregroundStyle(pal.ink)
                Text(fonts.errors[f.id] ?? f.note).font(.system(size: 11)).foregroundStyle(fonts.errors[f.id] == nil ? pal.secondary : .red)
            }
            Spacer()
            if let p = fonts.progress[f.id] {
                ProgressView(value: p).frame(width: 60).tint(NovelLayout.accent)
            } else if on {
                Image(systemName: "checkmark").foregroundStyle(NovelLayout.accent)
            } else if !ready {
                Text(f.bytes > 0 ? "下载 \(f.bytes / 1_000_000)MB" : "下载").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NovelLayout.accent)
                    .padding(.horizontal, 10).frame(minHeight: 28).overlay(Capsule().stroke(NovelLayout.accent, lineWidth: 1))
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if ready { prefs.fontID = f.id } else { fonts.fetch(f.id) } }
        .contextMenu { if fonts.downloaded(f.id) { Button("删除已下载的字体", role: .destructive) { if on { prefs.fontID = "system" }; fonts.delete(f.id) } } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("novel.font.\(f.id)")
    }

    // 翻页方式
    private var turnPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            subHeader("翻页方式")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(NovelTurnStyle.allCases) { t in
                    chip(t.label, on: prefs.turn == t, id: "novel.turn.\(t.rawValue)") {
                        let c = ref.chapter, o = offsetInChapter
                        prefs.turn = t
                        autoTurn = false
                        ref = paginator.ref(chapter: c, offset: o)
                        version += 1
                    }
                }
            }
            Text("仿真：像纸书一样卷页；滑动：两页并排滑过；覆盖：当前页盖在下一页上被拖走；上下滚动：整本书连续滚动。左右轻点也能翻页。")
                .font(.system(size: 11)).foregroundStyle(pal.secondary)
        }
    }

    // 书籍信息
    private var infoPanel: some View {
        let read = store.readTime[book.id] ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.system(size: 18, weight: .bold)).foregroundStyle(pal.ink).lineLimit(2)
                    Text("\(book.author.map { $0 + " · " } ?? "")时长 \(Int(read / 3600))时\(Int(read.truncatingRemainder(dividingBy: 3600) / 60))分")
                        .font(.system(size: 13)).foregroundStyle(pal.secondary)
                }
                Spacer()
                NovelCover(book: book).frame(width: 52, height: 72)
            }
            Divider()
            HStack {
                infoCell("\(book.chapters.count)", "章节")
                if book.isWeb {
                    infoCell(LegadoSourceStore.shared.source(book.sourceURL ?? "")?.bookSourceName ?? "已删除", "书源")
                } else {
                    infoCell(totalChars >= 10_000 ? String(format: "%.1f万", Double(totalChars) / 10_000) : "\(totalChars)", "字数")
                    infoCell(book.format.uppercased(), "格式")
                }
                infoCell(book.addedAt.formatted(.dateTime.month().day()), "导入")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.bg.opacity(0.7)))
    }

    private func infoCell(_ v: String, _ k: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.ink)
            Text(k).font(.system(size: 11)).foregroundStyle(pal.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // 目录 / 搜本书
    private var tocPanel: some View {
        VStack(spacing: 10) {
            Capsule().fill(pal.secondary.opacity(0.4)).frame(width: 36, height: 4)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13))
                    TextField("搜本书", text: $query).font(.system(size: 14)).submitLabel(.search)
                        .onSubmit { search() }
                        .simultaneousGesture(TapGesture().onEnded { tocSearch = true })
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(tocSearch ? pal.bg : .clear))
                Text("目录").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Capsule().fill(tocSearch ? .clear : pal.bg))
                    .onTapGesture { tocSearch = false; query = ""; hits = [] }
            }
            .foregroundStyle(pal.ink).padding(3).background(Capsule().fill(pal.track.opacity(0.7)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if tocSearch {
                            ForEach(hits.indices, id: \.self) { i in
                                let h = hits[i]
                                Button { jump(chapter: h.chapter, offset: h.offset) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(title(h.chapter)).font(.system(size: 12)).foregroundStyle(pal.secondary)
                                        Text(h.snippet).font(.system(size: 15)).foregroundStyle(pal.ink).lineLimit(2)
                                    }
                                    .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                            if hits.isEmpty, !query.isEmpty { Text("没有找到").foregroundStyle(pal.secondary).padding(.top, 20) }
                        } else {
                            ForEach(book.chapters.indices, id: \.self) { i in tocRow(i) }
                        }
                    }
                }
                .onAppear { proxy.scrollTo(ref.chapter, anchor: .center) }
            }
        }
        .frame(height: 460)
    }

    private func tocRow(_ i: Int) -> some View {
        let cur = i == ref.chapter
        let per = max(1, Double(paginator.chapter(ref.chapter).text.length) / Double(max(1, paginator.pageCount(ref.chapter))))
        return VStack(alignment: .leading, spacing: 0) {
            Button { go(i); hideMenu() } label: {
                HStack {
                    Text(title(i)).font(.system(size: 16, weight: cur ? .bold : .regular)).foregroundStyle(pal.ink).lineLimit(1)
                    Spacer()
                    Text("\(Int(Double(book.chapters[i].start) / per) + 1)").font(.system(size: 13).monospacedDigit()).foregroundStyle(pal.secondary)
                }
                .padding(.vertical, 13).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title(i))
            if cur {
                HStack(spacing: 6) {
                    Image(systemName: "book").font(.system(size: 13))
                    Text("当前读到").font(.system(size: 14))
                    Spacer()
                    Text("\(Int(Double(bookOffset) / per) + 1)").font(.system(size: 13).monospacedDigit()).foregroundStyle(pal.secondary)
                }
                .foregroundStyle(NovelLayout.accent).padding(.leading, 14).padding(.bottom, 12)
            }
            Divider().opacity(0.5)
        }
        .id(i)
    }

    // 听书
    private var listenButton: some View {
        Button { if !speaker.active { startListening() }; withAnimation(.easeOut(duration: 0.18)) { tab = .listen } } label: {
            Text("听").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Circle().fill(Color(white: 0.2).opacity(0.88)))
        }
        .buttonStyle(.plain).accessibilityIdentifier("novel.listen")
    }

    /// While reading aloud with the menu closed: state + play / pause, tap to open the 听书 panel.
    private var miniPlayer: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").compatWaveformSymbolEffect(isActive: !speaker.paused)
                .font(.system(size: 15)).foregroundStyle(NovelLayout.accent)
            Text(speaker.paused ? "已暂停" : "朗读中").font(.system(size: 13, weight: .medium)).foregroundStyle(pal.ink)
            Button { speaker.toggle() } label: {
                Image(systemName: speaker.paused ? "play.fill" : "pause.fill").font(.system(size: 13)).foregroundStyle(pal.ink)
                    .frame(width: 30, height: 30).background(Circle().fill(pal.track))
            }
            .buttonStyle(.plain).accessibilityIdentifier("novel.mini.toggle")
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 42)
        .background(Capsule().fill(pal.panel).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        .onTapGesture { showMenu(); tab = .listen }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("novel.miniplayer")
    }

    private var listenPanel: some View {
        let voices = NovelSpeaker.voices
        let current = voices.first { $0.identifier == speaker.voiceID } ?? voices.first { $0.language == "zh-CN" }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(speaker.chapter)).font(.system(size: 16, weight: .semibold)).foregroundStyle(pal.ink).lineLimit(1)
                    Text(!speaker.active ? "未开始" : speaker.paused ? "已暂停" : "正在朗读 · 读到的句子会高亮")
                        .font(.system(size: 12)).foregroundStyle(pal.secondary)
                        .accessibilityIdentifier("novel.listen.state")
                }
                Spacer()
                Button("退出听书") { speaker.stop(); withAnimation { tab = nil } }
                    .font(.system(size: 13)).foregroundStyle(pal.secondary)
                    .accessibilityIdentifier("novel.listen.stop")
            }
            HStack {
                listenControl("backward.end.fill", "上一章", 17) { listenChapter(-1) }
                listenControl("gobackward", "上一句", 19) { speaker.skip(-1) }
                Button { speaker.active ? speaker.toggle() : startListening() } label: {
                    Image(systemName: speaker.active && !speaker.paused ? "pause.fill" : "play.fill").font(.system(size: 22))
                        .foregroundStyle(.white).frame(width: 58, height: 58).background(Circle().fill(NovelLayout.accent))
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity)
                .accessibilityLabel(speaker.active && !speaker.paused ? "暂停" : "播放").accessibilityIdentifier("novel.listen.toggle")
                listenControl("goforward", "下一句", 19) { speaker.skip(+1) }
                listenControl("forward.end.fill", "下一章", 17) { listenChapter(+1) }
            }
            optionRow("语速") {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { v in
                    chip(v == 1 ? "1.0x" : "\(v.formatted())x", on: abs(speaker.speed - v) < 0.01) { speaker.speed = v }
                }
            }
            optionRow("定时") {
                chip("关闭", on: speaker.sleep == .off) { speaker.sleep = .off }
                ForEach([15, 30, 60], id: \.self) { m in chip("\(m)分钟", on: speaker.sleep == .minutes(m)) { speaker.sleep = .minutes(m) } }
                chip("本章结束", on: speaker.sleep == .chapterEnd) { speaker.sleep = .chapterEnd }
            }
            if let until = speaker.sleepUntil {
                Text("将于 \(until.formatted(date: .omitted, time: .shortened)) 停止").font(.system(size: 11)).foregroundStyle(pal.secondary)
            }
            HStack(spacing: 10) {
                Text("音色").font(.system(size: 13)).foregroundStyle(pal.secondary).frame(width: 34, alignment: .leading)
                Menu {
                    Picker("音色", selection: Binding(get: { current?.identifier ?? "" }, set: { speaker.voiceID = $0 })) {
                        ForEach(voices, id: \.identifier) { v in Text(NovelSpeaker.label(v)).tag(v.identifier) }
                    }
                } label: {
                    HStack { Text(current.map(NovelSpeaker.label) ?? "系统默认").lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)) }
                        .font(.system(size: 14)).foregroundStyle(pal.ink)
                        .padding(.horizontal, 14).frame(minHeight: 36).background(Capsule().fill(pal.track.opacity(0.6)))
                }
            }
            Text("想要更自然的声音：iOS 设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下载「增强 / 高级」音色。锁屏或切到后台会继续朗读。")
                .font(.system(size: 11)).foregroundStyle(pal.secondary)
        }
    }

    private func listenControl(_ icon: String, _ label: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(pal.ink).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain).disabled(!speaker.active && label.hasSuffix("句")).accessibilityLabel(label)
    }

    private func optionRow<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 13)).foregroundStyle(pal.secondary).frame(width: 34, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content() } }
        }
    }

    // MARK: Logic

    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    private func showMenu() { withAnimation(.easeOut(duration: 0.2)) { menu = true; hint = false } }
    private func hideMenu() { withAnimation(.easeOut(duration: 0.2)) { menu = false; tab = nil; tocSearch = false } }

    private func restore() {
        let p = store.progress[book.id]
        let c = min(max(0, p?.chapter ?? 0), max(0, book.chapters.count - 1))
        ref = paginator.ref(chapter: c, offset: p?.offset ?? 0)
        ready = true
    }

    private func go(_ i: Int) {
        guard book.chapters.indices.contains(i) else { return }
        jump(chapter: i, offset: 0, keepMenu: true)
    }

    private func jump(chapter i: Int, offset: Int, keepMenu: Bool = false) {
        ref = paginator.ref(chapter: i, offset: offset)
        version += 1
        save()
        if speaker.active { startListening() }
        if !keepMenu { hideMenu() }
    }

    private func jump(toFraction f: Double) {
        let target = Int(f * Double(totalChars))
        let i = book.chapters.lastIndex { $0.start <= target } ?? 0
        ref = paginator.ref(chapter: i, offset: target - book.chapters[i].start)
        version += 1
        save()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; return }
        let ns = store.text(book) as NSString
        var found: [(Int, Int, String)] = []
        var r = NSRange(location: 0, length: ns.length)
        while found.count < 200 {
            let m = ns.range(of: q, options: [.caseInsensitive], range: r)
            if m.location == NSNotFound { break }
            let ci = book.chapters.lastIndex { $0.start <= m.location } ?? 0
            let s = max(0, m.location - 16)
            let snippet = ns.substring(with: NSRange(location: s, length: min(60, ns.length - s))).replacingOccurrences(of: "\n", with: " ")
            found.append((ci, m.location - book.chapters[ci].start, snippet))
            r = NSRange(location: NSMaxRange(m), length: ns.length - NSMaxRange(m))
        }
        hits = found.map { (chapter: $0.0, offset: $0.1, snippet: $0.2) }
    }

    /// 听书 from the top of the visible page; at a chapter's end continues with the next one.
    private func startListening() {
        speaker.nowPlaying = (book.title, title(ref.chapter))
        speaker.onChapterEnd = { ch in
            guard ch + 1 < book.chapters.count else { speaker.stop(); return }
            speaker.nowPlaying = (book.title, title(ch + 1))
            speaker.start(chapter: ch + 1, text: store.chapterText(book, ch + 1), from: 0)
        }
        speaker.start(chapter: ref.chapter, text: store.chapterText(book, ref.chapter), from: offsetInChapter)
    }

    private func listenChapter(_ d: Int) {
        let c = (speaker.active ? speaker.chapter : ref.chapter) + d
        guard book.chapters.indices.contains(c) else { return }
        ref = paginator.ref(chapter: c, offset: 0)
        version += 1
        startListening()
    }

    /// Keeps the page on the sentence being read (turning with the current animation when it is the next page).
    private func follow(_ s: NSRange) {
        let target = paginator.ref(chapter: speaker.chapter, offset: s.location)
        guard target != ref else { return }
        if prefs.turn == .scroll {
            ref = target // the scroll view follows the sentence itself (scrollReader)
        } else if paginator.next(ref) == target, let c = handle.controller {
            c.turn(+1)
        } else {
            ref = target
        }
        save()
    }

    private func save() { store.record(book, chapter: ref.chapter, offset: offsetInChapter) }
}


/// WeRead's capsule slider: a full-height round thumb (optionally labelled) on a pill track.
struct PillSlider: View {
    @Binding var value: Double
    var track: Color
    var thumb: Color
    var label: String? = nil
    var leading: AnyView? = nil
    var trailing: AnyView? = nil

    var body: some View {
        GeometryReader { g in
            let h = g.size.height, d = h - 6
            let x = 3 + (g.size.width - d - 6) * CGFloat(value.clamped)
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                HStack {
                    leading.padding(.leading, 16)
                    Spacer()
                    trailing.padding(.trailing, 16)
                }
                Circle().fill(thumb).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .overlay { if let label { Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary) } }
                    .frame(width: d, height: d)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    value = ((v.location.x - d / 2 - 3) / (g.size.width - d - 6)).clamped
            })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityValue(label ?? "\(Int(value * 100))%")
        .accessibilityAdjustableAction { dir in
            value = (value + (dir == .increment ? 0.05 : -0.05)).clamped
        }
    }
}

private extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}
private extension CGFloat {
    var clamped: Double { Swift.min(1, Swift.max(0, Double(self))) }
}
