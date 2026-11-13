import Foundation

/// Which upstream a series comes from. All requests go directly from the device to that upstream.
/// Built-in sources are fixed; plugin sources are `p.<plugin id>` (JS plugins) or `cms.<key>` (苹果 CMS 采集站).
struct DramaSource: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard Self.builtins.contains(where: { $0.rawValue == rawValue })
                || (rawValue.hasPrefix("p.") && rawValue.count > 2) || (rawValue.hasPrefix("cms.") && rawValue.count > 4) else { return nil }
        self.rawValue = rawValue
    }
    private init(_ raw: String) { rawValue = raw }

    static let hongguo = DramaSource("hongguo")
    static let huangguo = DramaSource("huangguo")
    static let jable = DramaSource("jable")
    static let missav = DramaSource("missav")
    static let hanime1 = DramaSource("hanime1")
    static let supjav = DramaSource("supjav")
    static let eporner = DramaSource("eporner")
    static let xvideos = DramaSource("xvideos")
    static let xnxx = DramaSource("xnxx")
    static let pornhub = DramaSource("pornhub")
    static let telegram = DramaSource("telegram")
    static let builtins: [DramaSource] = [.hongguo, .huangguo, .jable, .missav, .hanime1, .supjav, .eporner, .xvideos, .xnxx, .pornhub, .telegram]

    static func plugin(_ id: String) -> DramaSource { DramaSource("p." + id) }
    static func cms(_ key: String) -> DramaSource { DramaSource("cms." + key) }
    /// JS plugin id when this is a plugin source.
    var pluginID: String? { rawValue.hasPrefix("p.") ? String(rawValue.dropFirst(2)) : nil }
    /// 苹果 CMS site key when this is a 采集站.
    var cmsKey: String? { rawValue.hasPrefix("cms.") ? String(rawValue.dropFirst(4)) : nil }
    var isDynamic: Bool { pluginID != nil || cmsKey != nil }

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hongguo: "红果短剧"
        case .huangguo: "黄果短剧"
        case .jable: "Jable"
        case .missav: "MissAV"
        case .hanime1: "Hanime1"
        case .supjav: "SupJav"
        case .eporner: "Eporner"
        case .xvideos: "XVideos"
        case .xnxx: "XNXX"
        case .pornhub: "Pornhub"
        case .telegram: "Telegram"
        default:
            if let p = pluginID { PluginStore.snapshot(p)?.manifest.name ?? "插件（已移除）" }
            else if let k = cmsKey { CMSStore.site(k)?.name ?? "采集站（已移除）" }
            else { rawValue }
        }
    }
}

struct HGSeries: Identifiable, Hashable, Codable {
    var source: DramaSource = .hongguo
    /// hongguo: numeric seriesId. huangguo: "<sub-source>:<sourceId>" reference.
    var seriesId: String
    var title: String
    var cover: String
    var rank: Int? = nil
    var subtitle: String? = nil
    var author: String? = nil
    var actors: [String] = []
    var episodeCount: Int = 0
    var duration: Int = 0
    var playCount: Int = 0
    var followCount: Int = 0
    var onlineTime: Int = 0
    var orientation: String? = nil
    var isNew: Bool = false
    var tags: [String] = []
    /// huangguo detail page URL, if any.
    var page: String? = nil
    var id: String { source.rawValue + ":" + seriesId }
    /// Long-video sites use 16:9 thumbnails; grids switch to 2 columns.
    /// Long-video sites use 16:9 thumbnails, except items that say otherwise (Hanime1 裏番/泡麵番 portrait covers).
    var isLandscapeCover: Bool { orientation == "portrait" ? false : source.isLongVideo }
}

struct HGEpisode: Identifiable, Hashable {
    let ep: Int
    /// hongguo: vid. huangguo: episode key.
    let vid: String
    let duration: Int
    let title: String
    var page: String? = nil
    var media: String? = nil
    var id: String { vid.isEmpty ? "ep\(ep)" : vid }
}

struct HGSeriesDetail: Hashable {
    var source: DramaSource = .hongguo
    let seriesId: String
    let title: String
    var cover: String = ""
    var desc: String = ""
    let author: String?
    let actors: [String]
    let onlineTime: Int
    let totalEps: Int
    let episodes: [HGEpisode]
    /// Same-franchise seasons / related series (hongguo). Empty when upstream has none.
    var relatedSeries: [HGSeries] = []
    /// Cast with celebrity ids (hongguo official web page). Empty when unknown.
    var cast: [HGCelebrity] = []
    var tags: [String] = []
    var favoriteCount: Int = 0
    var episodeLabel: String = ""
    /// 观众评分 / 评分人数 / 全网热度 (官网 seriesSocialInfo)
    var rating: Double = 0
    var ratingCount: String = ""
    var hotText: String = ""
}

/// A hongguo celebrity (actor). `id` is the numeric celebrity_id used by the homepage / works APIs.
struct HGCelebrity: Hashable, Codable, Identifiable {
    var id: String
    var name: String
    var avatar: String = ""
    /// e.g. "饰 霍衍"
    var role: String = ""
    var intro: String = ""
}

struct HGActorProfile: Hashable {
    var actor: HGCelebrity
    var related: [HGCelebrity]
}

struct HGActorWorks: Hashable {
    var items: [HGSeries]
    var total: Int
}

struct HGFilterOption: Hashable, Identifiable { let id: String; let name: String }
struct HGFilterRow: Hashable, Identifiable { let type: String; let name: String; let selectType: Int?; let items: [HGFilterOption]; var id: String { type } }
struct HGPanel { let rows: [HGFilterRow] }

struct HGPage {
    var items: [HGSeries]
    var hasMore: Bool
    var nextOffset: Int?
    var nextCursor: String?
    var sessionId: String?
}

struct HGStreamAudio: Hashable {
    var codec: String?; var profile: String?; var language: String?; var channels: Int?; var sampleRate: Int?; var bitrate: Int?
}

enum MediaKind: String, Hashable {
    case mp4Cenc = "MP4 (CENC AES-CTR)", mp4Clear = "MP4", hls = "HLS", hlsAES = "HLS (AES-128)"
    var isProgressiveMP4: Bool { self == .mp4Clear || self == .mp4Cenc }
}

struct HGStream: Hashable, Identifiable {
    var streamId: String?
    var quality: String?
    var url: String
    /// hongguo: 32-hex CENC content key ("" = clear). huangguo: HLS AES-128 key hex if known.
    var key: String
    var width: Int? = nil
    var height: Int? = nil
    var codec: String? = nil
    var size: Int? = nil
    var bitrate: Int? = nil
    var audio: HGStreamAudio? = nil
    var kind: MediaKind = .mp4Cenc
    var backupURL: URL? = nil
    var headers: [String: String] = [:]
    var id: String { streamId ?? quality ?? url }
}

struct HGResolvedVideo: Hashable {
    let vid: String
    let url: String?
    let key: String?
    let duration: Double?
    let expiresAt: Int?
    let err: String?
    let streams: [HGStream]
    var note: String? = nil
}
