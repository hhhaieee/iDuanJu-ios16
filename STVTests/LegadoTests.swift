import XCTest
@testable import STV

/// 「阅读」书源引擎: rule syntaxes, URL rules, and the search → 详情 → 目录 → 正文 flow against fake sites.
final class LegadoTests: XCTestCase {
    private var requests: [URLRequest] = []

    override func setUp() {
        requests = []
        let pages: [String: (String, String)] = [
            // HTML site (GBK keyword, UTF-8 pages)
            "https://book.test/search?q=%CE%ED%B8%DB&p=1": ("""
                <html><head><meta charset="utf-8"></head><body><div class="result-list">
                <div class="item"><a class="title" href="/book/1/">雾港</a><span class="author">作者：测试</span><img src="/cover/1.jpg">
                <p class="intro">海边的故事</p><span>最新：第三章 灯塔</span></div>
                <div class="item"><a class="title" href="/book/2/">雾港外传</a><span class="author">作者：别人</span><img src="/cover/2.jpg">
                <p class="intro">番外</p><span>最新：后记</span></div>
                </div></body></html>
                """, "text/html"),
                "https://book.test/book/1/": ("""
                <html><body><h1>雾港</h1><div id="info"><p>作者：测试</p><p>状态：完结</p></div><div id="intro">一个港口的故事</div>
                <a id="toc" href="/book/1/list_1.html">目录</a></body></html>
                """, "text/html"),
                    "https://book.test/book/1/list_1.html": ("""
                <ul id="list"><li><a href="1.html">第一章 雨夜</a></li><li><a href="/book/1/2.html">第二章 渡口</a></li></ul>
                <a class="next" href="list_2.html">下一页</a>
                """, "text/html"),
                        "https://book.test/book/1/list_2.html": ("""
                <ul id="list"><li><a href="3.html">第三章 灯塔</a></li></ul><a class="next" href="list_2.html">下一页</a>
                """, "text/html"),
                            "https://book.test/book/1/1.html": ("""
                <div id="content">　　第一段<br>　　第二段<script>ad()</script></div><a id="next" href="1_2.html">下一页</a>
                """, "text/html"),
                                "https://book.test/book/1/1_2.html": ("""
                <div id="content"><p>第三段 广告abc</p></div><a id="next" href="2.html">下一章</a>
                """, "text/html"),
                                    // JSON API site
                                    "https://api.test/s": (#"{"data":{"list":[{"bookName":"雾港","authorName":"测试","id":7,"cover":"c.jpg","tags":["海","港"]}]}}"#, "application/json"),
                                    "https://api.test/book/7": (#"{"name":"雾港","toc":"https://api.test/toc/7"}"#, "application/json"),
                                    "https://api.test/toc/7": (#"{"chapters":[{"t":"一","u":"/c/1"},{"t":"二","u":"/c/2","vip":true}]}"#, "application/json"),
                                    "https://api.test/c/2": (#"{"content":"<p>甲</p><p>乙</p>"}"#, "application/json"),
                                ]
                                LegadoHTTP.transport = { [weak self] req in
                                    self?.requests.append(req)
                                    let u = req.url!.absoluteString
                                    guard let (body, ct) = pages[u] else {
                                        return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                                    }
                                    return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": ct])!)
                                }
                            }

                            override func tearDown() { LegadoHTTP.transport = nil }

                            private var htmlSource: LegadoSource {
                                LegadoSource(bookSourceUrl: "https://book.test", bookSourceName: "测试书站",
                                    searchUrl: "/search?q={{key}}&p={{page}},{\"charset\":\"gbk\"}",
                                    ruleSearch: ["bookList": "class.result-list@class.item", "name": "class.title@text", "author": "class.author@text",
                                        "bookUrl": "class.title@href", "coverUrl": "tag.img@src", "intro": "@css:p.intro@text",
                                        "lastChapter": "tag.span.1@text##最新："],
                                    ruleBookInfo: ["name": "tag.h1@text", "author": "id.info@tag.p.0@text", "intro": "id.intro@text", "tocUrl": "id.toc@href",
                                        "kind": "id.info@tag.p.-1@text"],
                                    ruleToc: ["chapterList": "id.list@tag.li", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href", "nextTocUrl": "class.next@href"],
                                    ruleContent: ["content": "id.content@html", "nextContentUrl": "id.next@href", "replaceRegex": "##广告\\S*"])
                            }

                            private var jsonSource: LegadoSource {
                                LegadoSource(bookSourceUrl: "https://api.test", bookSourceName: "接口站",
                                    searchUrl: "https://api.test/s,{\"method\":\"POST\",\"body\":\"kw={{key}}&page={{page}}\"}",
                                    ruleSearch: ["bookList": "$.data.list[*]", "name": "$.bookName", "author": "$.authorName",
                                        "bookUrl": "https://api.test/book/{$.id}", "coverUrl": "$.cover@js:'https://img.test/' + result",
                                        "kind": "{{$.authorName}}-作者", "intro": "@js:java.md5Encode('a')", "lastChapter": "$.tags[*]"],
                                    ruleBookInfo: ["name": "$.name", "tocUrl": "$.toc"],
                                    ruleToc: ["chapterList": "-$.chapters[*]", "chapterName": "$.t", "chapterUrl": "$.u"],
                                    ruleContent: ["content": "$.content"])
                            }

                            func testHTMLSourceFlow() throws {
                                let s = htmlSource
                                let hits = try LegadoClient.search(s, key: "雾港")
                                XCTAssertEqual(requests.first?.url?.absoluteString, "https://book.test/search?q=%CE%ED%B8%DB&p=1", "keyword must be GBK-encoded")
                                XCTAssertEqual(hits.map(\.name), ["雾港", "雾港外传"])
                                XCTAssertEqual(hits[0].author, "测试", "作者： prefix stripped")
                                XCTAssertEqual(hits[0].bookURL, "https://book.test/book/1/")
                                XCTAssertEqual(hits[0].cover, "https://book.test/cover/1.jpg")
                                XCTAssertEqual(hits[0].intro, "海边的故事")
                                XCTAssertEqual(hits[0].latest, "第三章 灯塔")

                                let info = try LegadoClient.info(s, bookURL: hits[0].bookURL)
                                XCTAssertEqual(info.name, "雾港")
                                XCTAssertEqual(info.author, "测试")
                                XCTAssertEqual(info.kind, "状态：完结")
                                XCTAssertEqual(info.tocURL, "https://book.test/book/1/list_1.html")

                                let toc = try LegadoClient.toc(s, tocURL: info.tocURL)
                                XCTAssertEqual(toc.map(\.title), ["第一章 雨夜", "第二章 渡口", "第三章 灯塔"], "follows nextTocUrl once, no loop")
                                XCTAssertEqual(toc.map(\.url), ["https://book.test/book/1/1.html", "https://book.test/book/1/2.html", "https://book.test/book/1/3.html"])

                                let text = try LegadoClient.content(s, chapter: toc[0], nextChapterURL: toc[1].url)
                                XCTAssertEqual(text, "第一段\n第二段\n第三段", "page 2 joined, script dropped, replaceRegex applied, stops before next chapter")
                            }

                            func testJSONSourceFlow() throws {
                                let s = jsonSource
                                let hits = try LegadoClient.search(s, key: "雾港")
                                let req = try XCTUnwrap(requests.first)
                                XCTAssertEqual(req.httpMethod, "POST")
                                XCTAssertEqual(String(decoding: req.httpBody ?? Data(), as: UTF8.self), "kw=%E9%9B%BE%E6%B8%AF&page=1")
                                XCTAssertEqual(hits.count, 1)
                                let h = hits[0]
                                XCTAssertEqual(h.name, "雾港")
                                XCTAssertEqual(h.bookURL, "https://api.test/book/7", "{$.id} template")
                                XCTAssertEqual(h.cover, "https://img.test/c.jpg", "rule then @js: with result")
                                XCTAssertEqual(h.kind, "测试-作者", "{{ }} rule template")
                                XCTAssertEqual(h.intro, "0cc175b9c0f1b6a831c399e269772661", "java.md5Encode")
                                XCTAssertEqual(h.latest, "海\n港")

                                let info = try LegadoClient.info(s, bookURL: h.bookURL)
                                XCTAssertEqual(info.tocURL, "https://api.test/toc/7")
                                let toc = try LegadoClient.toc(s, tocURL: info.tocURL)
                                XCTAssertEqual(toc.map(\.title), ["二", "一"], "- reverses the list")
                                XCTAssertEqual(toc[0].url, "https://api.test/c/2")
                                XCTAssertEqual(try LegadoClient.content(s, chapter: toc[0], nextChapterURL: nil), "甲\n乙")
                            }

                            // MARK: Rule pieces

                            private func an(_ html: String) -> LegadoAnalyzer {
                                LegadoAnalyzer(html, baseURL: "https://x.test/a/", ctx: LegadoContext(source: htmlSource))
                            }

                            func testJsoupIndexesAndAttributes() throws {
                                let a = an("<ul><li class='c a'>1</li><li class='c'>2</li><li class='c'>3</li><li>4 <b>x</b></li></ul>")
                                XCTAssertEqual(try a.strings("tag.li.0@text"), ["1"])
                                XCTAssertEqual(try a.strings("tag.li.-1@ownText"), ["4"])
                                XCTAssertEqual(try a.strings("tag.li!0@text"), ["2", "3", "4 x"])
                                XCTAssertEqual(try a.strings("tag.li[1:2]@text"), ["2", "3"])
                                XCTAssertEqual(try a.strings("tag.li[0,2]@text"), ["1", "3"])
                                // Rules written for longer lists must not crash on short ones.
                                XCTAssertEqual(try a.strings("tag.li[5:9]@text"), [])
                                XCTAssertEqual(try a.strings("tag.li[2:9]@text"), ["3", "4 x"])
                                XCTAssertEqual(try a.strings("tag.li[9:2]@text"), ["4 x", "3"])
                                XCTAssertEqual(try a.strings("tag.p[0:3]@text"), [])
                                XCTAssertEqual(try a.strings("tag.li.7@text"), [])
                                XCTAssertEqual(try a.strings("class.c a@text"), ["1"], "multiple classes")
                                XCTAssertEqual(try a.strings("li.c:eq(1)@text"), ["2"], "css segment with :eq (sibling index)")
                                XCTAssertEqual(try a.strings("@css:ul li:has(b)@text"), ["4 x"], ":has")
                                XCTAssertEqual(try a.strings("@css:li:last-of-type@ownText"), ["4"])
                                XCTAssertEqual(try a.strings("@css:li:containsOwn(3)@text"), ["3"])
                                XCTAssertEqual(try a.strings("@css:li:gt(1)@text"), ["3", "4 x"])
                                XCTAssertEqual(try a.elements("tag.ul@children").count, 4)
                                XCTAssertEqual(try a.string("tag.li.0@text&&tag.li.1@text"), "1\n2")
                                XCTAssertEqual(try a.string("tag.p@text||tag.li.2@text"), "3")
                                XCTAssertEqual(try a.string("@XPath://li[2]/text()"), "2")
                                XCTAssertEqual(try a.string("//li[last()]/b/text()"), "x")
                            }

                            func testRegexAndPutGet() throws {
                                let a = an("<div id='n' data-id='42'>书名：雾港</div>")
                                XCTAssertEqual(try a.string("id.n@text##书名："), "雾港")
                                XCTAssertEqual(try a.string("id.n@text##书名：(.*)##《$1》###"), "《雾港》", "### keeps the first match, replaced")
                                    _ = try a.string("@put:{\"bid\":\"id.n@data-id\"}id.n@text")
                                    XCTAssertEqual(try a.string("@get:{bid}"), "42")
                                    // `@put` at the end of a rule (七猫: `title@put:{"bid":"$.id"}`), visible to a later operation on the same book.
                                    let ctx1 = LegadoContext(source: htmlSource); ctx1.book = ["bookUrl": "https://x.test/b/9"]
                                    let j = LegadoAnalyzer(["title": "雾港", "id": 9] as [String: Any], baseURL: "", ctx: ctx1)
                                    XCTAssertEqual(try j.string("title@put:{\"bid\":\"$.id\"}"), "雾港")
                                    let ctx2 = LegadoContext(source: htmlSource); ctx2.book = ["bookUrl": "https://x.test/b/9"]
                                    XCTAssertEqual(try LegadoAnalyzer("", baseURL: "", ctx: ctx2).string("@js:java.get('bid')"), "9")
                                    let list = LegadoAnalyzer("a=1;b=2;", baseURL: "", ctx: LegadoContext(source: htmlSource))
                                    let items = try list.elements(":(\\w)=(\\d);")
                                    XCTAssertEqual(items.count, 2)
                                    let g = LegadoAnalyzer(items[1], baseURL: "", ctx: LegadoContext(source: htmlSource))
                                    XCTAssertEqual(try g.string("$1-$2"), "b-2")
                                }

                                func testContentCleanup() {
                                    XCTAssertEqual(LegadoContent.clean("前世&lt;br/&gt;今生&lt;p&gt;第三段&lt;/p&gt;"), "前世\n今生\n第三段")
                                    XCTAssertEqual(LegadoContent.clean("<p>甲&amp;乙</p><br>　　丙"), "甲&乙\n丙")
                                }

                                func testJSONPathFeatures() {
                                    let j: [String: Any] = ["a": [["k": 1, "n": "x"], ["k": 2, "n": "y"], ["k": 3, "n": "z"]], "deep": ["b": ["n": "w"]]]
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$.a[-1].n").map(LegadoJSONPath.text), ["z"])
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$.a[0:2].n").map(LegadoJSONPath.text), ["x", "y"])
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$.a[?(@.k > 1)].n").map(LegadoJSONPath.text), ["y", "z"])
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$.a[?(@.n == 'x')].k").map(LegadoJSONPath.text), ["1"])
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$..n").map(LegadoJSONPath.text).sorted(), ["w", "x", "y", "z"])
                                    XCTAssertEqual(LegadoJSONPath.read(j, "deep.b.n").map(LegadoJSONPath.text), ["w"], "no leading $")
                                    XCTAssertEqual(LegadoJSONPath.read(j, "$['deep']['b']['n']").map(LegadoJSONPath.text), ["w"])
                                    XCTAssertEqual(LegadoJSONPath.read([1, 2], "$.[*]").map(LegadoJSONPath.text), ["1", "2"], "dot before bracket")
                                }

                                func testJSSloppyModeAndJavaHelpers() throws {
                                    let a = an("<p>hi</p>")
                                    // Undeclared assignment (sloppy mode), base64, getString re-entry, top-level let in two evaluations.
                                    XCTAssertEqual(try a.string("@js:x = 2; let y = 3; String(x * y)"), "6")
                                    XCTAssertEqual(try a.string("@js:let y = 4; java.base64Decode(java.base64Encode('雾港' + y))"), "雾港4")
                                    XCTAssertEqual(try a.string("@js:java.getString('tag.p@text') + '!'"), "hi!")
                                    XCTAssertEqual(try a.string("<js>result.length > 0 ? 'ok' : 'no'</js>"), "ok")
                                    // Snippets may redeclare the injected names with let / const (光遇聚合 does `let key`).
                                    XCTAssertEqual(try a.string("@js:let key = 'k'; const result2 = key + '!'; result2"), "k!")
                                    XCTAssertEqual(try a.string("@js:var imp = new JavaImporter(); with (imp) { 'ok' }"), "ok")
                                    XCTAssertEqual(try a.string("@js:eval('1 + 2') + new Function('return 4')()"), "7", "eval allowed for book sources")
                                    XCTAssertEqual(try a.string("@js:java.t2s('簡體轉換與龍')"), "简体转换与龙")
                                    XCTAssertEqual(try a.string("@js:java.s2t('简体')"), "簡體")
                                    XCTAssertEqual(try a.string("@js:java.randomUUID().toString().length"), "36")
                                    XCTAssertEqual(try a.string("@js:source.key"), "https://book.test")
                                    XCTAssertEqual(try a.string("@js:var m = source.getLoginHeaderMap(); String(m.get('x')) + ',' + m.containsKey('x')"), "null,false")
                                    // Object.defineProperty keeps working (no accessor keys leak onto Object.prototype).
                                    XCTAssertEqual(try a.string("@js:var o = new Object(); Object.defineProperty(o, 'v', { value: 3 }); o.v"), "3")
                                    // NaN / huge numbers as bytes, empty inflate: no crash.
                                    XCTAssertEqual(LegadoBytes.data([Double.nan, 1e300, 65]), Data([0, 0, 65]))
                                    XCTAssertEqual(try LegadoBytes.inflate(Data(), raw: true), Data())
                                    // 长佩-style chapter name: template, then <js> with {{rule}} filled from the item, then ## cleanup.
                                    let item = LegadoAnalyzer(["order": 3, "name": "第3章 雨夜", "type": "item"] as [String: Any], baseURL: "", ctx: LegadoContext(source: htmlSource))
                                    XCTAssertEqual(try item.string("第{{$.order}}章 {{$.name}}\n<js>\nvol = \"{{$.type}}\"==\"volume\"?\" 📖 \":\"\"\nvol+result+vol\n</js>\n##第\\d+章\\s*(?=第\\d+章)"), "第3章 雨夜")
                                    XCTAssertEqual(try item.string("第{{$.order}}章##第"), "3章", "template then ##")
                                }

                                func testURLRules() throws {
                                    let ctx = LegadoContext(source: htmlSource)
                                    ctx.key = "a b"
                                    ctx.page = 2
                                    XCTAssertEqual(try LegadoURL.request("/s/<x,y,z>?k={{key}}&p={{page * 10}}", ctx: ctx, base: "https://book.test").request.url?.absoluteString,
                                        "https://book.test/s/y?k=a%20b&p=20")
                                    let r = try LegadoURL.request("https://h.test/q,{\"method\":\"POST\",\"body\":{\"k\":\"{{key}}\"},\"headers\":{\"X-A\":\"1\"}}", ctx: ctx, base: "")
                                    XCTAssertEqual(r.request.httpMethod, "POST")
                                    XCTAssertEqual(r.request.value(forHTTPHeaderField: "X-A"), "1")
                                    XCTAssertEqual(String(decoding: r.request.httpBody ?? Data(), as: UTF8.self), #"{"k":"a b"}"#, "JSON bodies keep the raw keyword")
                                    XCTAssertEqual(try LegadoURL.request("@js:'https://j.test/' + page", ctx: ctx, base: "").request.url?.absoluteString, "https://j.test/2")
                                    // The whole URL is a {{JS}} expression containing `,{` and `}}`-like text, followed by options (久久小说).
                                    let jj = try LegadoURL.request("{{(function(){var o={a:1};if(o.a){return 'http://j.test/s'}return ''})()}},{\"method\":\"POST\",\"body\":\"k={{key}}\"}", ctx: ctx, base: "")
                                    XCTAssertEqual(jj.request.url?.absoluteString, "http://j.test/s")
                                    XCTAssertEqual(jj.request.httpMethod, "POST")
                                    XCTAssertEqual(String(decoding: jj.request.httpBody ?? Data(), as: UTF8.self), "k=a%20b")
                                    // Non-strict options (single quotes, line breaks) like PO18.
                                    let po = try LegadoURL.request("https://p.test/s.php,{\n'charset':'utf-8',\n'method':'POST',\n'body':'searchkey={{key}}'\n}", ctx: ctx, base: "")
                                    XCTAssertEqual(po.request.url?.absoluteString, "https://p.test/s.php")
                                    XCTAssertEqual(po.request.httpMethod, "POST")
                                    XCTAssertEqual(String(decoding: po.request.httpBody ?? Data(), as: UTF8.self), "searchkey=a%20b")
                                }

                                func testImportParsesLegadoExport() throws {
                                    let json = #"""
            [{"bookSourceUrl":"https://a.test","bookSourceName":"A","bookSourceType":0,"enabled":true,"searchUrl":"/s?k={{key}}",
                    "ruleSearch":{"bookList":"class.item","name":"tag.a@text","checkKeyWord":123}, "weight": 0},
                {"bookSourceUrl":"https://audio.test","bookSourceName":"听书","bookSourceType":1,"searchUrl":"/s"},
                {"broken": true}]
            """#
                                    let list = try LegadoSourceStore.parse(Data(json.utf8))
                                    XCTAssertEqual(list.map(\.bookSourceName), ["A", "听书"], "broken entries skipped")
                                    XCTAssertEqual(list[0].ruleSearch?["checkKeyWord"], "123", "non-string rule values kept as text")
                                    XCTAssertTrue(list[0].supported)
                                    XCTAssertFalse(list[1].supported, "audio sources not supported")
                                }

                                /// Rhino `Packages.*` shim and Legado crypto helpers (as used by API sources such as 七猫).
                                func testJavaCompatibilityShim() throws {
                                    let a = an("<p/>")
                                    // MD5 through MessageDigest + java.lang.String bytes (signed bytes → hex).
                                    XCTAssertEqual(try a.string("""
                    @js:var b = Packages.java.security.MessageDigest.getInstance('MD5').digest(new Packages.java.lang.String('a').getBytes('UTF-8'));
                    var h = ''; for (var i = 0; i < b.length; i++) { var x = (b[i] & 0xff).toString(16); h += (x.length < 2 ? '0' : '') + x; } h
                    """), "0cc175b9c0f1b6a831c399e269772661")
                                            // AES-CBC round trip with IV prefix, like 七猫's qmDecode.
                                            XCTAssertEqual(try a.string("""
                        @js:var A = Packages.java.util.Arrays, B = Packages.java.util.Base64;
                        var key = new Packages.javax.crypto.spec.SecretKeySpec(new Packages.java.lang.String('242ccb8230d709e1').getBytes('UTF-8'), 'AES');
                        var iv = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16];
                        var c = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
                        c.init(1, key, new Packages.javax.crypto.spec.IvParameterSpec(iv));
                        var enc = iv.concat(c.doFinal(new Packages.java.lang.String('雾港·第一章').getBytes('UTF-8')));
                        var raw = B.getDecoder().decode(B.getEncoder().encodeToString(enc));
                        var d = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
                        d.init(2, key, new Packages.javax.crypto.spec.IvParameterSpec(A.copyOfRange(raw, 0, 16)));
                        String(new Packages.java.lang.String(d.doFinal(A.copyOfRange(raw, 16, raw.length)), 'UTF-8'))
                        """), "雾港·第一章")
                                                    // Legado helper: createSymmetricCrypto (ECB, Base64 in/out).
                                                    XCTAssertEqual(try a.string("@js:var c = java.createSymmetricCrypto('AES/ECB/PKCS5Padding', '1234567890abcdef'); c.decryptStr(c.encryptBase64('hello'))"), "hello")
                                                    // Raw deflate through Inflater(true): data compressed by Apple's zlib (raw deflate).
                                                    let src = Data("一段压缩过的正文。".utf8)
                                                    let comp = try (src as NSData).compressed(using: .zlib) as Data
                                                    let js = "@js:var b = [\(LegadoBytes.json(comp).map(String.init).joined(separator: ","))]; var inf = new Packages.java.util.zip.Inflater(true); inf.setInput(b, 0, b.length); var out = Packages.java.util.Arrays.copyOf(b, \(src.count)); inf.inflate(out); inf.end(); String(new Packages.java.lang.String(out, 'UTF-8'))"
                                                    XCTAssertEqual(try a.string(js), "一段压缩过的正文。")
                                                }

                                                /// Login: loginUi parsing (non-strict JSON), login() → login header on later requests, cache expiry.
                                                func testLoginFlow() throws {
                                                    var src = htmlSource
                                                    src.bookSourceUrl = "https://login.test"
                                                    src.loginUrl = """
function login() {
var info = source.getLoginInfoMap();
source.putLoginHeader(JSON.stringify({ Authorization: 'Bearer ' + info['账号'] }));
cache.put('t', 'v', 1);
return 'ok:' + info['账号'];
}
function hello() { return 'hi' }
"""
                                                    src.loginUi = "[{name:'账号',type:'text'},{name:'密码',type:'password'},{name:'模式',type:'select',chars:['快','慢'],default:'慢'},{name:'打招呼',type:'button',action:'hello()'}]"
                                                    LegadoSourceState.logout(src.bookSourceUrl)
                                                    let f = LegadoClient.loginFields(src)
                                                    XCTAssertEqual(f.map(\.name), ["账号", "密码", "模式", "打招呼"])
                                                    XCTAssertEqual(f[2].options, ["快", "慢"])
                                                    XCTAssertEqual(f[2].defaultValue, "慢")
                                                    XCTAssertEqual(f[3].action, "hello()")
                                                    XCTAssertEqual(try LegadoClient.runLogin(src, "hello()"), "hi")
                                                    LegadoSourceState.setLoginInfo(src.bookSourceUrl, ["账号": "u1"])
                                                    XCTAssertEqual(try LegadoClient.runLogin(src, "login()"), "ok:u1")
                                                    XCTAssertTrue(LegadoSourceState.isLoggedIn(src.bookSourceUrl))
                                                    // Every request of the source now carries the login header.
                                                    let r = try LegadoURL.request("/s", ctx: LegadoContext(source: src), base: src.bookSourceUrl)
                                                    XCTAssertEqual(r.request.value(forHTTPHeaderField: "Authorization"), "Bearer u1")
                                                    XCTAssertEqual(LegadoSourceState.cacheGet(src.bookSourceUrl, "t"), "v")
                                                    Thread.sleep(forTimeInterval: 1.2)
                                                    XCTAssertNil(LegadoSourceState.cacheGet(src.bookSourceUrl, "t"), "cache entry expired")
                                                    LegadoSourceState.logout(src.bookSourceUrl)
                                                    XCTAssertFalse(LegadoSourceState.isLoggedIn(src.bookSourceUrl))
                                                }

                                                /// java.webView runs page JS in a hidden WKWebView (长佩 reads its token from sessionStorage this way).
                                                func testHiddenWebView() async throws {
                                                    let s = htmlSource
                                                    let v = try await LegadoClient.run {
                                                        try LegadoAnalyzer("", baseURL: "", ctx: LegadoContext(source: s)).string(
                                                            "@js:java.webView(\"<script>sessionStorage.setItem('token','abc123')</script>\", 'https://example.invalid/', \"sessionStorage.getItem('token')\")")
                                                    }
                                                    XCTAssertEqual(v, "abc123")
                                                }

                                                /// org.jsoup / java.getElement / result.toArray() as used by 晋江-style sources.
                                                func testJsoupFromScripts() throws {
                                                    let a = an("<div id='n'><h1>雾港</h1><span itemprop='author'>测试</span><a class='x' href='/b/1'>一</a><a class='x' href='/b/2'>二</a></div>")
                                                    XCTAssertEqual(try a.string("@js:var J = org.jsoup.Jsoup.parse(result); J.select('h1').text() + '/' + J.select('span[itemprop=\"author\"]').text()"), "雾港/测试")
                                                    XCTAssertEqual(try a.string("@js:var J = org.jsoup.Jsoup.parse(result); J.select('a.x').attr('href') + ',' + J.select('a.x').size() + ',' + J.select('a.x').get(1).text()"), "/b/1,2,二")
                                                    XCTAssertEqual(try a.string("@js:java.getElement('id.n@tag.a.-1').text()"), "二")
                                                    XCTAssertEqual(try a.string("@js:java.getElement('@css:a.x').first().absUrl('href')"), "https://x.test/b/1")
                                                    XCTAssertEqual(try a.string("tag.a@href<js>result.toArray().map(function (x) { return x.split('/').pop() }).join('+')</js>"), "1+2")
                                                }

                                                /// hutool AsymmetricCrypto("RSA").setPublicKey(x509).decryptStr(data): text "encrypted" with the private key,
                                                /// 3 blocks of a 1024-bit key (乐读's chapter text). Fixture made with openssl (sign, PKCS#1 v1.5).
                                                func testRSAPublicKeyDecrypt() throws {
                                                    let pub = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDoGQyCVF2rCBkJfGfvDXnKrYJcYOn2v75xyKBhHdXM4gEvYIyv8DYhW/jGHpMyaFVdLKeEaSIAoy7UWuGfYk4gt/2fKfcsYu+V/ZKL8ZOeUC9wJNZZQTijILzH3Fi7gYqFZQ3QiDoTjlWl52OhueKjxH2uiBMIuo3QyOgDFPMnNQIDAQAB"
                                                    let ct = "Z8FX7L57KL173hhYS5GzbJ7VwFwHV6S/HYlEhYdytTbaz1oTUAKulKLG+RAEjCF+6Ste1APN2MOIt1Xi4vs6QQj0YM12GOyZy83FYjvgrlO/9dfH2D1RlqV2zfbsWrdFHqwKMXl3ksYNSvdyb0As9iavX9u0zdwL1ReXudAW7ZhGS+ICcMNIE4LDwxkHv98Hz1kJIwt+3QvYsG+ipgEU8tnPpwoQCHop5wZVhlIA7HMsbGHqMe0ihz3srB8VTeUe5Konjxamwr/LBV7ttBxfT8KqQc9pCmbV0bU8yr4CBiRns/7mR/7IKzyFvejS5Ivmrg+v6mylTxJhbp/YJG11NlaYx+M3NvHrf5N5KAeFqxuxGHVoYyhmuuHJ0HDctGFtaWktiqCUNH/FYK+PPQdj6YK8QRrMTI++Dtiyh3OHhi/V5rBLPhJBObPfV8fzZOLaia420gW3YCSCVCbuxgTPWQVgoBU6Gh1puYduGmiceJrouBWWwdOYiE0kQDe4uwgt"
                                                    let a = an("<p/>")
                                                    let out = try a.string("@js:java.createAsymmetricCrypto('RSA').setPublicKey(java.base64DecodeToByteArray('\(pub)')).decryptStr(java.base64DecodeToByteArray('\(ct)'))")
                                                    XCTAssertEqual(out, String(repeating: "雾港的灯塔在岛的最北边，白色的墙皮已经剥落了大半。守塔人每天傍晚爬上一百二十级台阶去点灯。", count: 2))
                                                }
                                            }
