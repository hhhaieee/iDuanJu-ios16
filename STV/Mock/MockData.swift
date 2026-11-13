import Foundation

/// Preview-only sample data. The running app always loads from the real upstreams.
extension HGSeries {
    static let previewSeries: [HGSeries] = (1...6).map {
        HGSeries(seriesId: "\(7_000_000 + $0)", title: ["霸总的秘密助理", "重生之嫡女归来", "校园恋爱手册", "末日求生日记", "闪婚后被宠上天", "女帝的贴身影卫"][$0 - 1],
                 cover: "https://picsum.photos/seed/stv\($0)/600/900", rank: $0, episodeCount: 60 + $0, playCount: 1_200_000 * $0)
    }
}

extension HGSeriesDetail {
    static let previewDetail = HGSeriesDetail(
        seriesId: "7000001", title: "霸总的秘密助理", cover: "https://picsum.photos/seed/stv1/600/900",
        desc: "闪婚第一天，他认出了我。", author: "示例出品", actors: ["演员甲", "演员乙"], onlineTime: 0, totalEps: 12,
        episodes: (1...12).map { HGEpisode(ep: $0, vid: "v\($0)", duration: 90, title: "第\($0)集") },
        relatedSeries: [
            HGSeries(seriesId: "7000001", title: "霸总的秘密助理", cover: "https://picsum.photos/seed/stv1/600/900", episodeCount: 12),
            HGSeries(seriesId: "7000002", title: "霸总的秘密助理 第二季", cover: "https://picsum.photos/seed/stv2/600/900", episodeCount: 16),
            HGSeries(seriesId: "7000003", title: "霸总的秘密助理 第三季", cover: "https://picsum.photos/seed/stv3/600/900", episodeCount: 20)
        ])
}
