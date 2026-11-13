import Foundation

/// Parses Telegram's public web preview (`https://t.me/s/<channel>`, `?before=`, `?q=`).
/// Markup reference: the live pages of @telegram / @durov (saved as test fixtures).
enum TGParser {
    static func page(_ html: String, channel: String) -> TGChannelPage {
        let chunks = html.components(separatedBy: "<div class=\"tgme_widget_message_wrap")
        let posts = chunks.dropFirst().compactMap { post($0, channel: channel) }
        return TGChannelPage(info: info(html, channel: channel), posts: posts.sorted { $0.msgId > $1.msgId }, before: before(html, posts: posts))
    }

    static func info(_ html: String, channel: String) -> TGChannel? {
        let title = HTML.classText(html, "tgme_channel_info_header_title")
        guard !title.isEmpty else { return nil }
        var c = TGChannel(username: HTML.groups("class=\"tgme_channel_info_header_username\"[^>]*>\\s*<a[^>]*>@([A-Za-z0-9_]+)", html)?[1] ?? channel)
        c.title = title
        c.avatar = HTML.groups("<i class=\"tgme_page_photo_image[^\"]*\"[^>]*>\\s*<img src=\"([^\"]+)\"", html).map { HTML.unescape($0[1]) } ?? ""
        for m in HTML.all("<span class=\"counter_value\">([^<]*)</span>\\s*<span class=\"counter_type\">([^<]*)</span>", html)
            where m[2].hasPrefix("subscriber") { c.subscribers = m[1] }
        c.about = text(HTML.groups("<div class=\"tgme_channel_info_description\">(.*?)</div>", html)?[1] ?? "")
        return c
    }

    /// Cursor for the next older page.
    static func before(_ html: String, posts: [TGPost]) -> Int? {
        if let m = HTML.groups("data-before=\"(\\d+)\"", html), let n = Int(m[1]) { return n }
        if let m = HTML.groups("<link rel=\"prev\" href=\"[^\"]*before=(\\d+)", html), let n = Int(m[1]) { return n }
        return nil
    }

    static func post(_ raw: String, channel: String) -> TGPost? {
        guard let dp = HTML.groups("data-post=\"([^\"/]+)/(\\d+)\"", raw), let id = Int(dp[2]) else { return nil }
        var p = TGPost(channel: dp[1], msgId: id)
        p.isService = raw.contains("service_message")
        p.author = HTML.classText(raw, "tgme_widget_message_from_author")
        p.forwardedFrom = HTML.classText(raw, "tgme_widget_message_forwarded_from_name")
        if let t = HTML.groups("<time datetime=\"([^\"]+)\"", raw) { p.date = ISO8601DateFormatter().date(from: t[1]) }
        p.views = HTML.groups("class=\"tgme_widget_message_views\">([^<]*)<", raw)?[1] ?? ""
        // The post's own text is the last js-message_text (a reply quote comes first).
        if let body = HTML.all("<div class=\"tgme_widget_message_text[^\"]*js-message_text[^\"]*\"[^>]*>(.*?)</div>", raw).last?[1] {
            p.text = text(body)
            p.links = HTML.all("<a [^>]*href=\"([^\"]+)\"", body).map { HTML.unescape($0[1]) }
                .filter { $0.hasPrefix("http") || $0.hasPrefix("tg:") }
        }
        p.media = media(raw)
        p.buttons = HTML.all("<a class=\"tgme_widget_message_inline_button[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", raw)
            .map { TGButton(text: HTML.cleanText($0[2]), url: HTML.unescape($0[1])) }
        if let lp = HTML.groups("<a class=\"tgme_widget_message_link_preview\" href=\"([^\"]+)\"(.*?)</a>", raw) {
            p.preview = TGLinkPreview(site: HTML.classText(lp[2], "link_preview_site_name"),
                                      title: HTML.classText(lp[2], "link_preview_title"),
                                      desc: HTML.classText(lp[2], "link_preview_description"),
                                      image: bg(lp[2]), url: HTML.unescape(lp[1]))
        }
        if p.text.isEmpty, p.media.isEmpty, p.preview == nil, !p.isService {
            // Unsupported media (polls, stickers …): keep the post so paging ids stay contiguous.
            p.text = HTML.classText(raw, "message_media_not_supported_label")
        }
        return p
    }

    /// Photos / videos in document order (albums list each item).
    static func media(_ raw: String) -> [TGMedia] {
        let anchor = HTML.re("<a class=\"tgme_widget_message_(photo_wrap|video_player)([^\"]*)\"[^>]*>")
        let ns = raw as NSString
        let ms = anchor.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        return ms.enumerated().compactMap { i, m in
            let end = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            let tag = ns.substring(with: m.range)
            let seg = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            let kind = ns.substring(with: m.range(at: 1)), cls = ns.substring(with: m.range(at: 2))
            let link = HTML.unescape(HTML.attr(tag, "href")).replacingOccurrences(of: "?single", with: "")
            if kind == "photo_wrap" {
                let u = bg(tag); guard !u.isEmpty else { return nil }
                return TGMedia(kind: .photo, thumb: u, link: link, spoiler: cls.contains("blured"))
            }
            let thumb = bg(HTML.groups("<i class=\"tgme_widget_message_video_thumb\"[^>]*>", seg)?[0] ?? "")
            let src = HTML.groups("<video [^>]*src=\"([^\"]+)\"", seg).map { HTML.unescape($0[1]) }
            let dur = HTML.groups("message_video_duration[^\"]*\">([0-9:]+)<", seg).map { clock($0[1]) } ?? 0
            let gif = seg.contains("tgme_widget_message_gif") || (src != nil && dur == 0 && seg.contains(" loop"))
            return TGMedia(kind: gif ? .gif : .video, thumb: thumb, video: src, duration: dur, link: link, spoiler: cls.contains("blured"))
        }
    }

    static func bg(_ s: String) -> String {
        HTML.groups("background-image:url\\('([^']+)'\\)", s).map { HTML.unescape($0[1]) } ?? ""
    }

    static func clock(_ s: String) -> Int { s.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) } }

    /// Message HTML → plain text keeping line breaks.
    static func text(_ html: String) -> String {
        var t = HTML.replace("<br\\s*/?>", html, "\n")
        t = HTML.replace("<[^>]+>", t, "")
        t = HTML.unescape(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `t.me/s/<name>` answered with a redirect to `t.me/<name>`: read the landing page for the reason.
    static func landing(_ html: String, channel: String) -> TGChannel {
        var c = TGChannel(username: channel)
        c.title = HTML.classText(html, "tgme_page_title")
        c.subscribers = HTML.classText(html, "tgme_page_extra")
        c.about = HTML.classText(html, "tgme_page_description")
        c.avatar = HTML.groups("<img class=\"tgme_page_photo_image\" src=\"([^\"]+)\"", html).map { HTML.unescape($0[1]) } ?? ""
        return c
    }

    /// Single-message embed (`t.me/<c>/<id>?embed=1`) error banner, e.g. channels Telegram restricted.
    static func embedError(_ html: String) -> String? {
        let t = HTML.classText(html, "tgme_widget_message_error")
        return t.isEmpty ? nil : t
    }
}
