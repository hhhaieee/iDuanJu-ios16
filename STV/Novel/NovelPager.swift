import UIKit

/// A page of the book: chapter index + page index inside that chapter (for the current layout).
struct NovelPageRef: Hashable {
    var chapter: Int
    var index: Int
}

/// Turn styles (WeRead / 阅读): page curl, slide, cover, none — plus continuous vertical scrolling (SwiftUI).
enum NovelTurnStyle: Int, CaseIterable, Identifiable {
    case curl, slide, cover, none, scroll
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .curl: "仿真"
        case .slide: "滑动"
        case .cover: "覆盖"
        case .none: "无动画"
        case .scroll: "上下滚动"
        }
    }
}

/// The sentence being read aloud (chapter-relative range).
struct NovelHighlight: Equatable { var chapter: Int; var range: NSRange }

/// Page text style + size; changing it invalidates every chapter's pagination.
struct NovelPageStyle: Equatable {
    var size: CGSize
    var fontSize: CGFloat
    var lineSpacing: Double
    var indent: Bool
    var fontID: String
    var text: UIColor
    var secondary: UIColor
    var background: UIColor
    var highlight: UIColor
}

/// Chapter text → (styled string, page ranges), cached per chapter for the current style.
@MainActor
final class NovelPaginator {
    let book: NovelBook
    private(set) var style: NovelPageStyle?
    private var cache: [Int: (NSAttributedString, [NSRange])] = [:]
    private let store = NovelStore.shared

    init(book: NovelBook) { self.book = book }

    var chapterCount: Int { book.chapters.count }

    /// Returns true when the layout changed (callers re-render).
    @discardableResult func configure(_ s: NovelPageStyle) -> Bool {
        guard s != style else { return false }
        style = s
        cache = [:]
        return true
    }

    func chapter(_ i: Int) -> (text: NSAttributedString, pages: [NSRange]) {
        if let c = cache[i] { return c }
        guard let s = style, book.chapters.indices.contains(i) else { return (NSAttributedString(), [NSRange(location: 0, length: 0)]) }
        let title = book.chapters[i].title
        var raw = store.chapterText(book, i)
        if book.isWeb && raw.isEmpty {
            // 书源 chapter not downloaded yet: placeholder page, fetched in the background (reader re-paginates on arrival).
            let loader = NovelWebLoader.shared
            loader.ensure(book, i)
            raw = title + "\n" + (loader.error(book, i).map { "加载失败：\($0)" } ?? "正在加载…")
        }
        let a = NovelLayout.attributed(raw, title: title, size: s.fontSize, lineSpacing: s.lineSpacing,
            indent: s.indent, font: NovelFonts.font(s.fontID, size: s.fontSize), bold: NovelFonts.font(s.fontID, size: s.fontSize * 1.3, bold: true), color: s.text)
        let p = NovelLayout.paginate(a, size: s.size)
        if cache.count > 6 { cache = cache.filter { abs($0.key - i) <= 2 } }   // keep neighbours only
        cache[i] = (a, p)
        return (a, p)
    }

    /// Drops cached layouts (a 书源 chapter arrived).
    func invalidate() { cache = [:] }

    func pageCount(_ chapter: Int) -> Int { self.chapter(chapter).pages.count }

    func range(_ r: NovelPageRef) -> NSRange {
        let p = chapter(r.chapter).pages
        return p.indices.contains(r.index) ? p[r.index] : NSRange(location: 0, length: 0)
    }

    func next(_ r: NovelPageRef) -> NovelPageRef? {
        if r.index + 1 < pageCount(r.chapter) { return NovelPageRef(chapter: r.chapter, index: r.index + 1) }
        return r.chapter + 1 < chapterCount ? NovelPageRef(chapter: r.chapter + 1, index: 0) : nil
    }

    func prev(_ r: NovelPageRef) -> NovelPageRef? {
        if r.index > 0 { return NovelPageRef(chapter: r.chapter, index: r.index - 1) }
        return r.chapter > 0 ? NovelPageRef(chapter: r.chapter - 1, index: pageCount(r.chapter - 1) - 1) : nil
    }

    /// Page containing chapter offset `o` (Int.max → last page).
    func ref(chapter: Int, offset o: Int) -> NovelPageRef {
        let p = self.chapter(chapter).pages
        let i = o == .max ? p.count - 1 : (p.lastIndex { $0.location <= o } ?? 0)
        return NovelPageRef(chapter: chapter, index: max(0, i))
    }

    /// Whole-book page numbers estimated from this chapter's density (WeRead shows "19649 / 25070").
    func bookPageLabel(_ r: NovelPageRef) -> String {
        let c = chapter(r.chapter)
        let per = max(1, Double(c.text.length) / Double(max(1, c.pages.count)))
        let start = book.chapters.indices.contains(r.chapter) ? book.chapters[r.chapter].start : 0
        let total = book.chapters.last?.end ?? 0
        let off = c.pages.indices.contains(r.index) ? c.pages[r.index].location : 0
        return "\(Int(Double(start + off) / per) + 1) / \(Int(Double(total) / per) + 1)"
    }
}

// MARK: - Page view

/// One rendered page: chapter name on top, the text slice, whole-book page number bottom-right.
final class NovelPageView: UIView {
    let ref: NovelPageRef
    private let header = UILabel()
    private let footer = UILabel()
    private let textView = UITextView()
    private var insets: UIEdgeInsets = .zero

    init(ref: NovelPageRef, paginator: NovelPaginator, insets: UIEdgeInsets, highlight: NovelHighlight?) {
        self.ref = ref
        self.insets = insets
        super.init(frame: .zero)
        let s = paginator.style!
        backgroundColor = s.background
        header.font = .systemFont(ofSize: 12)
        header.textColor = s.secondary
        header.text = paginator.book.chapters.indices.contains(ref.chapter) ? paginator.book.chapters[ref.chapter].title : ""
        footer.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        footer.textColor = s.secondary
        footer.textAlignment = .right
        footer.text = paginator.bookPageLabel(ref)
        footer.accessibilityIdentifier = "novel.page"
        let chapter = paginator.chapter(ref.chapter)
        footer.accessibilityLabel = "\(ref.index + 1) / \(chapter.pages.count)"
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isUserInteractionEnabled = false
        let r = paginator.range(ref)
        if NSMaxRange(r) <= chapter.text.length {
            let t = NSMutableAttributedString(attributedString: chapter.text.attributedSubstring(from: r))
            // A page that starts mid-paragraph continues a line: no first-line indent (TextKit laid it out that way).
            if r.location > 0, (chapter.text.string as NSString).character(at: r.location - 1) != 10,
            let ps = t.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle, ps.firstLineHeadIndent > 0 {
                let m = ps.mutableCopy() as! NSMutableParagraphStyle
                m.firstLineHeadIndent = 0
                let first = (t.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                t.addAttribute(.paragraphStyle, value: m, range: first)
            }
            if let h = highlight?.range, highlight?.chapter == ref.chapter {
                let x = NSIntersectionRange(h, r)
                if x.length > 0 { t.addAttribute(.backgroundColor, value: s.highlight, range: NSRange(location: x.location - r.location, length: x.length)) }
            }
            textView.attributedText = t
        }
        [header, textView, footer].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width - insets.left - insets.right
        header.frame = CGRect(x: insets.left, y: insets.top, width: w, height: 22)
        textView.frame = CGRect(x: insets.left, y: insets.top + 32, width: w, height: bounds.height - insets.top - insets.bottom - 62)
        footer.frame = CGRect(x: insets.left, y: bounds.height - insets.bottom - 30, width: w, height: 30)
    }
}

final class NovelPageVC: UIViewController {
    let page: NovelPageView
    init(_ page: NovelPageView) { self.page = page; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = page }
}

// MARK: - Pager

/// Hosts the paged turn styles. 仿真 / 滑动 use UIPageViewController (interactive, follows the finger);
/// 覆盖 drags the top page over / off the next one; 无动画 swaps instantly. Taps: left / right third turn,
/// middle → `onCenterTap`; swipe up → `onSwipeUp`.
@MainActor
final class NovelPagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    let paginator: NovelPaginator
    var insets: UIEdgeInsets = .zero
    var onPageChange: ((NovelPageRef) -> Void)?
    var onCenterTap: (() -> Void)?
    var onSwipeUp: (() -> Void)?
    var highlight: NovelHighlight? { didSet { if highlight != oldValue { refreshCurrent() } } }
    private(set) var current: NovelPageRef
    private(set) var style: NovelTurnStyle = .slide

    private var pvc: UIPageViewController?
    // 覆盖 / 无动画
    private var top: NovelPageView?
    private var under: NovelPageView?
    private var dragging: (forward: Bool, target: NovelPageRef)?

    init(paginator: NovelPaginator, start: NovelPageRef) {
        self.paginator = paginator
        current = start
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let up = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp))
        up.direction = .up
        up.delegate = self
        view.addGestureRecognizer(up)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        build()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let p = g as? UIPanGestureRecognizer, !(g is UIScreenEdgePanGestureRecognizer) {
            // Own pan only drives 覆盖 / 无动画, and only horizontally.
            guard pvc == nil else { return false }
            let v = p.velocity(in: view)
            return abs(v.x) > abs(v.y)
        }
        return true
    }

    func setStyle(_ s: NovelTurnStyle) {
        guard s != style else { return }
        style = s
        if isViewLoaded { build() }
    }

    private func makePage(_ r: NovelPageRef) -> NovelPageView {
        NovelPageView(ref: r, paginator: paginator, insets: insets, highlight: highlight)
    }

    /// Rebuilds the visible page(s), e.g. after a style or layout change.
    func build() {
        pvc?.willMove(toParent: nil); pvc?.view.removeFromSuperview(); pvc?.removeFromParent(); pvc = nil
        top?.removeFromSuperview(); under?.removeFromSuperview(); top = nil; under = nil
        switch style {
        case .curl, .slide:
            let p = UIPageViewController(transitionStyle: style == .curl ? .pageCurl : .scroll, navigationOrientation: .horizontal,
                options: style == .slide ? [.interPageSpacing: 0] : nil)
            p.dataSource = self
            p.delegate = self
            p.isDoubleSided = false
            // UIPageViewController's own edge taps would fight with ours.
            p.gestureRecognizers.filter { $0 is UITapGestureRecognizer }.forEach { $0.isEnabled = false }
            addChild(p)
            p.view.frame = view.bounds
            p.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(p.view, at: 0)
            p.didMove(toParent: self)
            p.setViewControllers([NovelPageVC(makePage(current))], direction: .forward, animated: false)
            pvc = p
        case .cover, .none, .scroll:
            let t = makePage(current)
            t.frame = view.bounds
            t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(t, at: 0)
            top = t
        }
    }

    func show(_ r: NovelPageRef) {
        current = r
        if isViewLoaded { build() }
    }

    private func refreshCurrent() {
        guard isViewLoaded else { return }
        if let p = pvc { p.setViewControllers([NovelPageVC(makePage(current))], direction: .forward, animated: false) }
        else if let t = top { let n = makePage(current); n.frame = t.frame; n.autoresizingMask = t.autoresizingMask; view.insertSubview(n, aboveSubview: t); t.removeFromSuperview(); top = n }
    }

    /// Animated turn in the current style (taps, 自动翻页, 听书).
    func turn(_ d: Int) {
        guard dragging == nil, let target = d > 0 ? paginator.next(current) : paginator.prev(current) else { return }
        switch style {
        case .curl, .slide:
            guard let p = pvc else { return }
            p.setViewControllers([NovelPageVC(makePage(target))], direction: d > 0 ? .forward : .reverse, animated: true) { [weak self] _ in
                self?.settle(target)
            }
        case .cover:
            beginCover(forward: d > 0, target: target)
            finishCover(commit: true, velocity: 0)
        case .none, .scroll:
            show(target)
            onPageChange?(target)
        }
    }

    private func settle(_ r: NovelPageRef) {
        current = r
        onPageChange?(r)
    }

    // MARK: Taps

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x, w = view.bounds.width
        if x < w / 3 { turn(-1) } else if x > w * 2 / 3 { turn(+1) } else { onCenterTap?() }
    }

    @objc private func swipedUp() { onSwipeUp?() }

    // MARK: UIPageViewController

    func pageViewController(_ p: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let r = (vc as? NovelPageVC)?.page.ref, let t = paginator.prev(r) else { return nil }
        return NovelPageVC(makePage(t))
    }

    func pageViewController(_ p: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let r = (vc as? NovelPageVC)?.page.ref, let t = paginator.next(r) else { return nil }
        return NovelPageVC(makePage(t))
    }

    func pageViewController(_ p: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let r = (p.viewControllers?.first as? NovelPageVC)?.page.ref else { return }
        settle(r)
    }

    // MARK: 覆盖 / 无动画 (pan)

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: view).x
        switch g.state {
        case .began:
            let forward = g.velocity(in: view).x < 0
            guard let target = forward ? paginator.next(current) : paginator.prev(current) else { return }
            if style == .none { dragging = (forward, target); return }
            beginCover(forward: forward, target: target)
        case .changed:
            guard let d = dragging, style == .cover else { return }
            let w = view.bounds.width
            if d.forward { top?.frame.origin.x = min(0, tx) } else { under?.frame.origin.x = min(0, -w + max(0, tx)) }
        case .ended, .cancelled:
            guard let d = dragging else { return }
            let v = g.velocity(in: view).x
            let commit = g.state == .ended && (d.forward ? (tx < -40 || v < -300) : (tx > 40 || v > 300))
            if style == .none {
                dragging = nil
                if commit { show(d.target); onPageChange?(d.target) }
            } else {
                finishCover(commit: commit, velocity: v)
            }
        default: break
        }
    }

    /// Forward: the current page lies on top and slides off to the left, revealing the next one underneath.
    /// Backward: the previous page enters from the left on top of the current one.
    private func beginCover(forward: Bool, target: NovelPageRef) {
        guard let t = top else { return }
        let w = view.bounds.width
        let n = makePage(target)
        n.frame = view.bounds
        n.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if forward {
            view.insertSubview(n, belowSubview: t)
            shadow(t)
        } else {
            n.frame.origin.x = -w
            view.insertSubview(n, aboveSubview: t)
            shadow(n)
        }
        under = n
        dragging = (forward, target)
    }

    private func finishCover(commit: Bool, velocity: CGFloat) {
        guard let d = dragging, let t = top, let n = under else { dragging = nil; return }
        let w = view.bounds.width
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            if d.forward { t.frame.origin.x = commit ? -w : 0 } else { n.frame.origin.x = commit ? 0 : -w }
        } completion: { [weak self] _ in
            guard let self else { return }
            if commit {
                t.removeFromSuperview()
                n.layer.shadowOpacity = 0
                n.frame = self.view.bounds
                self.top = n
                self.settle(d.target)
            } else {
                n.removeFromSuperview()
                t.layer.shadowOpacity = 0
            }
            self.under = nil
            self.dragging = nil
        }
    }

    private func shadow(_ v: UIView) {
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.25
        v.layer.shadowRadius = 8
        v.layer.shadowOffset = CGSize(width: 2, height: 0)
    }
}
