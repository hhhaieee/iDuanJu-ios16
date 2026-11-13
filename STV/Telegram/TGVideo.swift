import Foundation

/// Telegram videos reuse the long-video player (`VerticalPlayerView`, landscape + loopback pre-buffer).
/// `seriesId` = "<channel>/<msgId>/<mediaIndex>", `page` = direct MP4 URL (or a downloaded file URL).
struct TGVideoProvider: SiteProvider {
    static let adultTag = "tg-adult"
    var source: DramaSource { .telegram }
    var categories: [SiteCategory] { [] }

    static func series(_ p: TGPost, media i: Int, channel: TGChannel?) -> HGSeries? {
        guard p.media.indices.contains(i), let v = p.media[i].video else { return nil }
        let m = p.media[i]
        let title = p.text.split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""
        return HGSeries(source: .telegram, seriesId: "\(p.channel)/\(p.msgId)/\(i)",
                        title: title.isEmpty ? "\(channel?.displayName ?? "@" + p.channel) · 视频" : title,
                        cover: m.thumb, subtitle: channel?.displayName ?? "@" + p.channel, author: p.channel,
                        duration: m.duration, onlineTime: Int(p.date?.timeIntervalSince1970 ?? 0), orientation: "landscape",
                        tags: channel?.isAdult == true ? [adultTag] : [], page: v)
    }

    /// Offline copy from the download manager.
    static func series(download d: TGDownload) -> HGSeries {
        HGSeries(source: .telegram, seriesId: "dl/\(d.id)", title: d.title, cover: d.thumb, subtitle: "已下载 · " + d.channel,
                 author: d.channel, duration: d.duration, orientation: "landscape",
                 tags: d.isAdult ? [adultTag] : [], page: d.localURL?.absoluteString ?? d.remote)
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage { HGPage(items: [], hasMore: false) }
    func search(_ q: String, page: Int) async throws -> HGPage { HGPage(items: [], hasMore: false) }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        #if DEBUG
        // UI tests / screenshots: `STV_FX_EPISODES=4` turns the local test stream into a 4-part long video.
        if s.seriesId.hasPrefix("fixture/"), let n = Int(ProcessInfo.processInfo.environment["STV_FX_EPISODES"] ?? ""), n > 1 {
            let names = ["彩条与色块", "动态色环", "灰阶过渡", "同步信号", "测试音轨", "收尾画面"]
            return HGSeriesDetail(source: .telegram, seriesId: s.seriesId, title: s.title, cover: s.cover, desc: s.subtitle ?? "",
                                  author: s.author, actors: [], onlineTime: s.onlineTime, totalEps: n,
                                  episodes: (1...n).map { HGEpisode(ep: $0, vid: s.seriesId + "#\($0)", duration: 60 * (15 + $0 * 2),
                                                                     title: names[($0 - 1) % names.count], page: s.page, media: s.page) })
        }
        #endif
        return HGSeriesDetail(source: .telegram, seriesId: s.seriesId, title: s.title, cover: s.cover, desc: s.subtitle ?? "",
                       author: s.author, actors: [], onlineTime: s.onlineTime, totalEps: 1,
                       episodes: [HGEpisode(ep: 1, vid: s.seriesId, duration: s.duration, title: s.title, page: s.page, media: s.page)])
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        guard var url = s.page, !url.isEmpty else { throw ProviderError.upstream("视频地址为空") }
        if let ref = TDFileRef(url) {
            // TDLib video: streamed while it downloads (PlaybackCoordinator → loopback proxy /tg/<id>).
            let stream = HGStream(streamId: "tg", quality: ref.streaming ? "原画" : "原画·整段", url: ref.string, key: "", kind: .mp4Clear, headers: [:])
            return HGResolvedVideo(vid: s.seriesId, url: ref.string, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: [stream])
        }
        if !url.hasPrefix("file://") {
            // CDN links carry an expiring token: refetch the post for a fresh one (falls back to the cached link).
            let parts = s.seriesId.split(separator: "/")
            if parts.count == 3, let id = Int(parts[1]), let i = Int(parts[2]),
               let fresh = try? await TGClient.shared.post(String(parts[0]), id), fresh.media.indices.contains(i),
               let v = fresh.media[i].video { url = v }
        }
        let stream = HGStream(streamId: "tg", quality: "原画", url: url, key: "", kind: .mp4Clear,
                              headers: url.hasPrefix("file://") ? [:] : ["User-Agent": TGClient.userAgent])
        return HGResolvedVideo(vid: s.seriesId, url: url, key: nil, duration: Double(s.duration), expiresAt: nil, err: nil, streams: [stream])
    }
}
