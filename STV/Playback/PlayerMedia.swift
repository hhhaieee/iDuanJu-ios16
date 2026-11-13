import AVFoundation
import CoreMedia
import UIKit

/// Technical info strip (design v3): resolution / dynamic range / codec / fps / audio / bitrate / network.
struct PlayerTech: Equatable {
    var resolution = ""      // "1080P"
    var hdr = false
    var codec = ""           // "H.264"
    var fps = 0
    var bitDepth = 8
    var audio = ""           // "AAC 2.0"
    var bitrate: Double = 0  // Mbps (indicated / estimated)
    var network: Double = 0  // bytes per second observed (0 = unknown / local file)
    var engine = ""          // "Aether" / "AVPlayer"

    static func channelLabel(_ channels: Int) -> String {
        channels >= 8 ? "7.1" : channels >= 6 ? "5.1" : channels == 1 ? "1.0" : channels > 0 ? "2.0" : ""
    }

    /// Audio label from an FFmpeg codec name ("aac", "eac3", "opus").
    static func audioName(codec: String, channels: Int) -> String {
        let n: String
        switch codec.lowercased() {
        case "aac": n = "AAC"
        case "ac3": n = "AC3"
        case "eac3": n = "E-AC3"
        case "mp3", "mp3float": n = "MP3"
        case "opus": n = "Opus"
        case "flac": n = "FLAC"
        case "truehd": n = "TrueHD"
        case "dts", "dca": n = "DTS"
        case "": return ""
        default: n = codec.uppercased()
        }
        let ch = channelLabel(channels)
        return ch.isEmpty ? n : "\(n) \(ch)"
    }

    static func resolutionLabel(_ size: CGSize) -> String {
        let s = Int(min(size.width, size.height).rounded())
        guard s > 0 else { return "" }
        switch s {
        case 2000...: return "4K"
        case 1400..<2000: return "2K"
        case 1000..<1400: return "1080P"
        case 700..<1000: return "720P"
        case 460..<700: return "480P"
        default: return "\(s)P"
        }
    }

    static func codecName(_ fourCC: FourCharCode) -> String {
        switch fourCC {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, 0x68657631 /* hev1 */: "HEVC"
        case 0x61763031 /* av01 */: "AV1"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        default: fourCC == 0 ? "" : String(bytes: [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xff) }, encoding: .ascii)?.uppercased() ?? ""
        }
    }

    static func audioName(_ fourCC: FourCharCode, channels: Int) -> String {
        let n: String
        switch fourCC {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: n = "AAC"
        case kAudioFormatAC3: n = "AC3"
        case kAudioFormatEnhancedAC3: n = "E-AC3"
        case kAudioFormatMPEGLayer3: n = "MP3"
        case kAudioFormatOpus: n = "Opus"
        case 0: return ""
        default: n = "Audio"
        }
        let ch = channels >= 6 ? "5.1" : channels == 1 ? "1.0" : channels > 0 ? "2.0" : ""
        return ch.isEmpty ? n : "\(n) \(ch)"
    }

    /// "3.2MB/s" / "820KB/s".
    static func speed(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1fMB/s", bps / 1_000_000) : String(format: "%.0fKB/s", max(1, bps / 1000))
    }

    @MainActor static func read(_ item: AVPlayerItem, stream: HGStream?) async -> PlayerTech {
        var t = PlayerTech()
        t.resolution = resolutionLabel(item.presentationSize)
        for track in item.tracks {
            guard let at = track.assetTrack else { continue }
            let descs = (try? await at.load(.formatDescriptions)) ?? []
            guard let d = descs.first else { continue }
            if at.mediaType == .video {
                t.codec = codecName(CMFormatDescriptionGetMediaSubType(d))
                let fps = track.currentVideoFrameRate > 0 ? track.currentVideoFrameRate : ((try? await at.load(.nominalFrameRate)) ?? 0)
                t.fps = Int(fps.rounded())
                if let tf = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                   tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    t.hdr = true
                }
                if let depth = CMFormatDescriptionGetExtension(d, extensionKey: "BitsPerComponent" as CFString) as? Int, depth > 0 { t.bitDepth = depth }
                else { t.bitDepth = t.hdr ? 10 : 8 }
            } else if at.mediaType == .audio {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee
                t.audio = audioName(asbd?.mFormatID ?? CMFormatDescriptionGetMediaSubType(d), channels: Int(asbd?.mChannelsPerFrame ?? 0))
            }
        }
        if t.codec.isEmpty, let c = stream?.codec, !c.isEmpty { t.codec = c.lowercased().contains("265") || c.lowercased().contains("hev") ? "HEVC" : c.uppercased() == "H264" ? "H.264" : c }
        if t.resolution.isEmpty, let h = stream?.height, let w = stream?.width { t.resolution = resolutionLabel(CGSize(width: w, height: h)) }
        if let e = item.accessLog()?.events.last {
            if e.indicatedBitrate > 0 { t.bitrate = e.indicatedBitrate / 1_000_000 }
            if e.observedBitrate > 0, e.observedBitrate.isFinite { t.network = e.observedBitrate / 8 }
        }
        if t.bitrate <= 0, let b = stream?.bitrate, b > 0 { t.bitrate = Double(b) / 1_000_000 }
        if t.bitrate <= 0, let s = stream?.size, s > 0, item.duration.seconds.isFinite, item.duration.seconds > 0 {
            t.bitrate = Double(s) * 8 / item.duration.seconds / 1_000_000
        }
        return t
    }
}

/// Scrub-bubble thumbnails: `AVAssetImageGenerator` in 10 s buckets (MP4 / local / proxied files).
/// HLS without frames to grab fails fast → the bubble shows the time only.
@MainActor final class PlayerThumbnailer {
    static let bucket = 10.0
    private var asset: AVAsset?
    private var generator: AVAssetImageGenerator?
    private var cache: [Int: UIImage] = [:]
    private var failures = 0
    private var inFlight: Set<Int> = []

    func attach(_ asset: AVAsset?) {
        guard asset !== self.asset else { return }
        self.asset = asset; cache = [:]; failures = 0; inFlight = []
        guard let asset else { generator = nil; return }
        if let u = (asset as? AVURLAsset)?.url, u.pathExtension.lowercased() == "m3u8" || u.path.hasSuffix("p.m3u8") {
            generator = nil   // HLS: no I-frame access through AVAssetImageGenerator
            return
        }
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 336, height: 190)
        g.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
        generator = g
    }

    var available: Bool { generator != nil && failures < 3 }

    func cached(at seconds: Double) -> UIImage? { cache[Int(seconds / Self.bucket)] }

    /// Thumbnail for the bucket around `seconds` (nil if not available); neighbours are pre-fetched.
    func image(at seconds: Double) async -> UIImage? {
        let b = Int(max(0, seconds) / Self.bucket)
        if let c = cache[b] { prefetch(b + 1); prefetch(b - 1); return c }
        let img = await generate(b)
        prefetch(b + 1); prefetch(b - 1)
        return img
    }

    private func prefetch(_ b: Int) {
        guard b >= 0, cache[b] == nil, !inFlight.contains(b), available else { return }
        Task { _ = await generate(b) }
    }

    private func generate(_ b: Int) async -> UIImage? {
        guard let g = generator, failures < 3, !inFlight.contains(b) else { return cache[b] }
        inFlight.insert(b); defer { inFlight.remove(b) }
        let t = CMTime(seconds: Double(b) * Self.bucket + Self.bucket / 2, preferredTimescale: 600)
        do {
            let (cg, _) = try await g.image(at: t)
            let img = UIImage(cgImage: cg)
            if cache.count > 120 { cache.removeAll() }
            cache[b] = img
            return img
        } catch {
            failures += 1
            return nil
        }
    }
}
