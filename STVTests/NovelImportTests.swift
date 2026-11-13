import XCTest
import UIKit
@testable import STV

/// 小说 phase 1: encoding detection, chapter splitting, EPUB parsing, TextKit pagination.
final class NovelImportTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name))
    }

    func testGBKTextChapters() throws {
        let p = try NovelImport.parse(try fixture("novel_sample_gbk.txt"), fileName: "雾港.txt")
        XCTAssertEqual(p.title, "雾港")
        XCTAssertEqual(p.chapters.map(\.title), ["第一章 雨夜", "第二章 渡口", "第三章 灯塔"])
        // A short intro (书名 / 作者) stays with chapter 1 instead of becoming its own stub chapter.
        XCTAssertEqual(p.chapters.first?.start, 0)
        XCTAssertEqual(p.chapters.last?.end, (p.text as NSString).length)
        let ns = p.text as NSString
        for (a, b) in zip(p.chapters, p.chapters.dropFirst()) { XCTAssertEqual(a.end, b.start, "chapters must be contiguous") }
        XCTAssertTrue(ns.substring(with: NSRange(location: p.chapters[1].start, length: p.chapters[1].length)).hasPrefix("第二章 渡口"))
        // Full-width indents are stripped (the reader indents paragraphs itself).
        XCTAssertFalse(p.text.contains("\u{3000}"))
    }

    func testUTF16BOMMatchesGBK() throws {
        let a = try NovelImport.parse(try fixture("novel_sample_gbk.txt"), fileName: "a.txt")
        let b = try NovelImport.parse(try fixture("novel_sample_utf16.txt"), fileName: "b.txt")
        XCTAssertEqual(a.text, b.text)
        XCTAssertEqual(a.chapters, b.chapters)
    }

    func testNoHeadingsSplitsIntoSections() throws {
        let p = try NovelImport.parse(try fixture("novel_noheading.txt"), fileName: "x.txt")
        XCTAssertGreaterThan(p.chapters.count, 3)
        XCTAssertEqual(p.chapters.first?.title, "第 1 节")
        XCTAssertEqual(p.chapters.last?.end, (p.text as NSString).length)
        XCTAssertTrue(p.chapters.allSatisfy { $0.length <= 10_000 })
        // Cuts land on paragraph ends.
        let ns = p.text as NSString
        for c in p.chapters.dropLast() { XCTAssertEqual(ns.substring(with: NSRange(location: c.end - 1, length: 1)), "\n") }
    }

    func testEPUB() throws {
        let p = try NovelImport.parse(try fixture("novel_sample.epub"), fileName: "file.epub")
        XCTAssertEqual(p.title, "雾港")
        XCTAssertEqual(p.author, "测试作者")
        XCTAssertEqual(p.chapters.map(\.title), ["第一章 雨夜", "第二章 渡口"], "spine order, percent-encoded href resolved")
        XCTAssertNotNil(p.cover)
        XCTAssertNotNil(UIImage(data: p.cover ?? Data()))
        let ns = p.text as NSString
        let c2 = ns.substring(with: NSRange(location: p.chapters[1].start, length: p.chapters[1].length))
        XCTAssertTrue(c2.hasPrefix("第二章 渡口\n"), c2.prefix(20).description)
        XCTAssertTrue(c2.contains("灯&雾 — 完"), "entities decoded")
        XCTAssertFalse(p.text.contains("<"), "tags stripped")
        XCTAssertFalse(p.text.contains("margin"), "style removed")
    }

    func testRejectsUnknownFormat() {
        XCTAssertThrowsError(try NovelImport.parse(Data("x".utf8), fileName: "a.pdf"))
        XCTAssertThrowsError(try NovelImport.parse(Data("not a zip".utf8), fileName: "a.epub"))
    }

    func testPaginationCoversChapterExactly() throws {
        let p = try NovelImport.parse(try fixture("novel_sample_gbk.txt"), fileName: "a.txt")
        let c = p.chapters[0]
        let text = (p.text as NSString).substring(with: NSRange(location: c.start, length: c.length))
        let s = NovelLayout.attributed(text, title: c.title, size: 19, spacing: 1, serif: true, color: .black)
        XCTAssertEqual(s.string, text, "styling must not change characters (offsets are saved as progress)")
        let pages = NovelLayout.paginate(s, size: CGSize(width: 330, height: 600))
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(pages.first?.location, 0)
        for (a, b) in zip(pages, pages.dropFirst()) { XCTAssertEqual(NSMaxRange(a), b.location) }
        XCTAssertEqual(pages.last.map(NSMaxRange), s.length)
        // Bigger type → more pages.
        let big = NovelLayout.paginate(NovelLayout.attributed(text, title: c.title, size: 26, spacing: 2, serif: true, color: .black), size: CGSize(width: 330, height: 600))
        XCTAssertGreaterThan(big.count, pages.count)
    }

    func testSentenceSplitForListening() {
        let t = "她说：“走吧。”他没回答！雨还在下……\n第二段没有句号"
        let ns = t as NSString
        let parts = NovelSpeaker.sentences(t, from: 0).map { ns.substring(with: $0) }
        XCTAssertEqual(parts, ["她说：“走吧。”", "他没回答！", "雨还在下……\n", "第二段没有句号"])
        // Starting mid-text begins at that offset.
        XCTAssertEqual(NovelSpeaker.sentences(t, from: 8).first.map { ns.substring(with: $0) }, "他没回答！")
    }

    /// Pages render their slice alone; a slice that starts mid-paragraph must still fit the page height.
    @MainActor func testPageSliceFitsWhenStartingMidParagraph() throws {
        let p = try NovelImport.parse(try fixture("novel_sample_gbk.txt"), fileName: "a.txt")
        let c = p.chapters[0]
        let text = (p.text as NSString).substring(with: NSRange(location: c.start, length: c.length))
        let s = NovelLayout.attributed(text, title: c.title, size: 19, lineSpacing: 0.5, serif: false, color: .black)
        let size = CGSize(width: 330, height: 600)
        let pages = NovelLayout.paginate(s, size: size)
        let ns = s.string as NSString
        let mid = try XCTUnwrap(pages.dropFirst().first { ns.character(at: $0.location - 1) != 10 }, "fixture should have a page starting mid-paragraph")
        // Render the slice the way NovelPageView does and measure it.
        let t = NSMutableAttributedString(attributedString: s.attributedSubstring(from: mid))
        if let ps = t.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            let m = ps.mutableCopy() as! NSMutableParagraphStyle
            m.firstLineHeadIndent = 0
            t.addAttribute(.paragraphStyle, value: m, range: (t.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
        }
        XCTAssertEqual(NovelLayout.paginate(t, size: size).count, 1, "the page's own text must fit on one page")
    }
}
