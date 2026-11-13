import XCTest
@testable import STV

/// 1.4 (11): detail-page posters. One test per source on sample payloads shaped like the live 2026-11
/// responses (neutral placeholder titles / example hosts where the host doesn't matter).
final class CoverMappingTests: XCTestCase {
    func series(_ src: DramaSource, _ id: String, cover: String = "https://list.example.com/\(UUID().uuidString).jpg", page: String? = nil) -> HGSeries {
        HGSeries(source: src, seriesId: id, title: "Sample", cover: cover, page: page)
    }

    // 黄果 AI 站: og:image is a share host that serves an empty body; coverSrc/posterSrc hold the real cover.
    func testHuangguoAIDetailPrefersCoverSrcOverDeadOgImage() {
        let page = "https://00b4b.adihsppe.cc/video/12175/"
        let h = #"""
        <meta property="og:image" content="https://expose.eisees.com/upload_01/upload/20261107/a.jpeg?auth=1-x">
        <script>window.videoInitialData={"imageOrigin":"https://pic.drleao.cn","coverSrc":"https:\/\/pic.drleao.cn\/upload_01\/upload\/20261107\/a.jpeg?auth_key=1-0-0-ab","posterSrc":"https://pic.drleao.cn/upload_01/upload/20261107/a.jpeg?auth_key=1-0-0-ab"}</script>
        """#
        let c = HuangguoClient.aiDetailCover(h, page: page, listCover: "https://pic.drleao.cn/list.jpeg")
        XCTAssertEqual(c, "https://pic.drleao.cn/upload_01/upload/20261107/a.jpeg?auth_key=1-0-0-ab")
        XCTAssertEqual(CoverCrypto.kind(for: c), .aiAES, "AI covers must go through the AES path")
        // Only the dead og:image → fall back to the list card's cover.
        let onlyOG = #"<meta property="og:image" content="https://expose.eisees.com/x.jpeg?auth=1">"#
        XCTAssertEqual(HuangguoClient.aiDetailCover(onlyOG, page: page, listCover: "https://pic.drleao.cn/list.jpeg"), "https://pic.drleao.cn/list.jpeg")
        XCTAssertEqual(HuangguoClient.aiDetailCover(onlyOG, page: page, listCover: ""), "", "never return the empty-body host")
        // Relative posterSrc is absolutised against the page.
        XCTAssertEqual(HuangguoClient.aiDetailCover(#"{"posterSrc":"/static/p/1.jpg"}"#, page: page, listCover: ""), "https://00b4b.adihsppe.cc/static/p/1.jpg")
        // Bare drleao URL somewhere in the page.
        XCTAssertEqual(HuangguoClient.aiDetailCover(#"<img data-src="https://pic.drleao.cn/u/b.jpg?auth_key=2">"#, page: page, listCover: ""), "https://pic.drleao.cn/u/b.jpg?auth_key=2")
    }

    // 黄果 视频站: og:image may be relative (/uploads/…/cover.webp).
    func testHuangguoVideoRelativeOgImage() {
        let h = #"<meta property="og:image" content="/uploads/lib/series/1987/cover.webp?v=1">"#
        XCTAssertEqual(HTML.resolve("https://huangguo.video/series/s5wm9tsc", HTML.ogImage(h)), "https://huangguo.video/uploads/lib/series/1987/cover.webp?v=1")
    }

    // 黄果 App 源 (legacy JSON): relative cover → image CDN, http → https.
    func testHuangguoLegacyAbsCover() {
        XCTAssertEqual(HuangguoClient.absCover("cf230705/image/d3/x.jpg", base: "https://zzzznnn.lkkwip.cn/"), "https://zzzznnn.lkkwip.cn/cf230705/image/d3/x.jpg")
        XCTAssertEqual(HuangguoClient.absCover("http://a.example.com/x.jpg", base: "https://cdn"), "https://a.example.com/x.jpg")
        XCTAssertEqual(HuangguoClient.absCover("//a.example.com/x.jpg", base: "https://cdn"), "https://a.example.com/x.jpg")
        XCTAssertEqual(CoverCrypto.kind(for: "https://zzzznnn.lkkwip.cn/cf230705/image/d3/x.jpg"), .legacyXOR)
    }

    // 红果: detail cover is book_info.thumb_url; empty → hero falls back to the list cover.
    func testHongguoAndGenericFallback() {
        XCTAssertEqual(DetailCover.pick(detail: "https://p3-reading-sign.fqnovelpic.com/novel-pic/a~tplv.image", list: "https://l"), "https://p3-reading-sign.fqnovelpic.com/novel-pic/a~tplv.image")
        XCTAssertEqual(DetailCover.pick(detail: "  ", list: "https://l.example.com/c.jpg"), "https://l.example.com/c.jpg")
        XCTAssertEqual(DetailCover.pick(detail: "", list: ""), "")
    }

    // Jable: stored page URL keeps its trailing slash (URL.path dropped it → /videos/<id> 404 → no detail).
    func testJableDetailPathAndCover() {
        XCTAssertEqual(HTML.sitePath("https://jable.tv/videos/dsam-018/"), "/videos/dsam-018/")
        XCTAssertEqual(HTML.sitePath("https://missav.ws/cn/abc-123"), "/cn/abc-123")
        XCTAssertEqual(HTML.sitePath("https://www.pornhub.com/view_video.php?viewkey=6af0"), "/view_video.php?viewkey=6af0")
        XCTAssertNil(HTML.sitePath("not a url"))
        let h = #"<meta property="og:image" content="https://assets-cdn.jable.tv/contents/videos_screenshots/63000/63215/preview.jpg"><h4>DSAM-018 Sample</h4>"#
        let s = series(.jable, "dsam-018", page: "https://jable.tv/videos/dsam-018/")
        XCTAssertEqual(JableProvider.parseDetail(h, series: s, base: "https://jable.tv", url: "https://jable.tv/videos/dsam-018/").cover,
                       "https://assets-cdn.jable.tv/contents/videos_screenshots/63000/63215/preview.jpg")
        XCTAssertEqual(JableProvider.parseDetail("<h4>x</h4>", series: s, base: "https://jable.tv", url: "").cover, s.cover, "no og:image → list cover")
    }

    // MissAV: og:image on fourhoi.com is rewritten to the CF-free host; missing → rebuilt from the id.
    func testMissAVDetailCover() {
        let s = series(.missav, "abc-123")
        let h = #"<meta property="og:image" content="https://fourhoi.com/abc-123/cover-n.jpg"><meta property="og:title" content="ABC-123 Sample">"#
        XCTAssertEqual(MissAVProvider.parseDetail(h, series: s, url: "https://missav.ws/cn/abc-123").cover, "https://fourhoi.mrstcdn.store/abc-123/cover-n.jpg")
        XCTAssertEqual(MissAVProvider.parseDetail("<html></html>", series: s, url: "").cover, "https://fourhoi.mrstcdn.store/abc-123/cover-n.jpg")
    }

    // Hanime1: og:image, else <video poster>, else list cover.
    func testHanime1DetailCover() {
        let s = series(.hanime1, "409107")
        let og = #"<meta property="og:image" content="https://vdownload.hembed.com/image/thumbnail/409107h.jpg?secure=a==,1">"#
        XCTAssertEqual(Hanime1Provider.parseDetail(og, series: s, url: "").cover, "https://vdownload.hembed.com/image/thumbnail/409107h.jpg?secure=a==,1")
        XCTAssertEqual(Hanime1Provider.parseDetail(#"<video id="player" poster="https://vdownload.hembed.com/p.jpg">"#, series: s, url: "").cover, "https://vdownload.hembed.com/p.jpg")
        XCTAssertEqual(Hanime1Provider.parseDetail("<html></html>", series: s, url: "").cover, s.cover)
    }

    // SupJav: post-meta <img>, else list cover.
    func testSupJavDetailCover() {
        let s = series(.supjav, "471315")
        let h = #"<h1>FC2PPV-5005596 Sample</h1><div class="post-meta clearfix"><img src="https://img.supjav.com/images/FC2PPV-5005596.jpg" alt=""></div>"#
        XCTAssertEqual(SupJavProvider.parseDetail(h, series: s, url: "").cover, "https://img.supjav.com/images/FC2PPV-5005596.jpg")
        XCTAssertEqual(SupJavProvider.parseDetail("<h1>x</h1>", series: s, url: "").cover, s.cover)
    }

    // Eporner JSON API: default_thumb.src.
    func testEpornerItemCover() {
        let v: [String: Any] = ["id": "wiH3", "title": "Sample", "default_thumb": ["src": "https://static-ca-cdn.eporner.com/thumbs/static4/1/13_360.jpg"], "url": "https://www.eporner.com/video-wiH3/x/"]
        XCTAssertEqual(EpornerProvider.item(v)?.cover, "https://static-ca-cdn.eporner.com/thumbs/static4/1/13_360.jpg")
    }

    // XVideos / XNXX: setThumbUrl169 on the watch page; 2026-11 XNXX cards carry the title only on the link.
    func testXVXNDetailAndNewXNXXCards() {
        let s = series(.xvideos, "olkc")
        let w = #"html5player.setVideoTitle('Sample');html5player.setThumbUrl169('https://thumb-cdn77.xvideos-cdn.com/u/6/xv_30_p.avif');"#
        XCTAssertEqual(XVProvider.parseDetail(w, series: s, url: "").cover, "https://thumb-cdn77.xvideos-cdn.com/u/6/xv_30_p.avif")
        let xn = """
        <div id="video_1j2t" data-id="9" class="thumb-block  with-uploader"><div class="thumb-inside"><div class="thumb"><a href="/video-1j2ttm6e/58617703/0/sample_clip"><img src="https://assets-cdn77.xnxx-cdn.com/img/lightbox/lightbox-blank.gif"
        data-src="https://thumb-cdn77.xnxx-cdn.com/10b4/6/xn_1_t.jpg"
        data-src-avif="https://thumb-cdn77.xnxx-cdn.com/10b4/6/xn_1_t.avif"
        id="pic_9" /></a></div></div><div class="uploader"><a href="/porn-maker/x"><span class="name">Uploader</span></a></div><div class="thumb-under"><p><a href="/video-1j2ttm6e/58617703/0/sample_clip" title="Sample clip">Sample clip</a></p><p class="metadata">12 min</p></div></div>
        """
        let q = XVProvider.parseList(xn, source: .xnxx, base: "https://www.xnxx.com", page: 1)
        XCTAssertEqual(q.items.first?.title, "Sample clip")
        XCTAssertEqual(q.items.first?.cover, "https://thumb-cdn77.xnxx-cdn.com/10b4/6/xn_1_t.jpg")
    }

    // Pornhub: 2026-11 <img src=… alt=… data-image=… class="… videoThumb …"> (src before class).
    func testPornhubNewCardOrderAndRefererHeader() {
        let card = #"""
        <li class="pcVideoListItem" data-video-id="1" data-video-vkey="6acaf707"><div class="phimage"><a href="/view_video.php?viewkey=6acaf707"><img
            src="https://pix-fl.phncdn.com/c6531/videos/202610/13/1/original_1.mp4/plain/rs:fit:320:180/vts:100?hdnea=st=1~exp=2~hmac=ab"
            alt="Sample one" data-pix="" loading="lazy"
            data-image="https://pix-fl.phncdn.com/c6531/videos/202610/13/1/original_1.mp4/plain/rs:fit:480:270/vts:100?hdnea=x"
            class="js-videoThumb thumb js-videoPreview lazy videoThumb" width="320" height="180"></a></div><var class="duration">10:00</var></li>
        """#
        let p = PornhubProvider.parseList(card, page: 1)
        XCTAssertEqual(p.items.first?.cover, "https://pix-fl.phncdn.com/c6531/videos/202610/13/1/original_1.mp4/plain/rs:fit:320:180/vts:100?hdnea=st=1~exp=2~hmac=ab")
        let og = #"<meta property="og:image" content="https://pix-cdn77.phncdn.com/c6541/videos/a.jpg/plain/rs:fit:640:360?hash=F"><meta property="og:title" content="Sample">"#
        let d = PornhubProvider.parseDetail(og, series: series(.pornhub, "6acaf707"), url: "")
        XCTAssertEqual(d.cover, "https://pix-cdn77.phncdn.com/c6541/videos/a.jpg/plain/rs:fit:640:360?hash=F")
        XCTAssertEqual(CoverHeaders.for(url: d.cover)["Referer"], "https://www.pornhub.com/", "pix-cdn77 403s without Referer")
    }

    func testCoverHeadersMap() {
        XCTAssertEqual(CoverHeaders.for(url: "https://thumb-cdn77.xvideos-cdn.com/a.jpg")["Referer"], "https://www.xvideos.com/")
        XCTAssertEqual(CoverHeaders.for(url: "https://vdownload.hembed.com/image/x.jpg")["Referer"], "https://hanime1.me/")
        XCTAssertEqual(CoverHeaders.for(url: "https://assets-cdn.jable.tv/x.jpg")["Referer"], "https://jable.tv/")
        XCTAssertTrue(CoverHeaders.for(url: "https://p3-reading-sign.fqnovelpic.com/x").isEmpty)
        XCTAssertTrue(CoverHeaders.for(url: "https://notphncdn.com/x").isEmpty, "suffix must match on a label boundary")
    }

    // Telegram: detail reuses the post thumbnail.
    func testTelegramDetailKeepsThumb() async throws {
        let s = HGSeries(source: .telegram, seriesId: "fixture/x", title: "T", cover: "fixture://3D5A80")
        XCTAssertEqual(DetailCover.pick(detail: s.cover, list: s.cover), "fixture://3D5A80")
    }
}
