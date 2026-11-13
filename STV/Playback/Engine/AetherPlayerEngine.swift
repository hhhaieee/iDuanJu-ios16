import AetherEngine
import AVFoundation
import AVKit
import Combine
import UIKit

/// AetherEngine (FFmpeg demux → loopback fMP4 / software decode, LGPL-3 + App Store exception).
/// Progressive files and MP4 URLs go through its own reader with our headers; TDLib videos through a
/// custom `IOReader`; HLS (our ad-stripping / SupJav loopback playlists) through its AVPlayer bypass.
@MainActor final class AetherPlayerEngine: PlayerEngine {
    let kind = PlayerEngineKind.aether
    var onFailed: ((Error?) -> Void)?
    var onEnded: (() -> Void)?
    /// Opening budget before the coordinator falls back to AVPlayer.
    static var loadTimeout: TimeInterval = 25

    let engine: AetherEngine
    private let view = AetherPlayerView()
    var surface: UIView { view }
    private var bag: Set<AnyCancellable> = []
    private var mounted = false
    private var generation = 0
    private var lastLoad: (source: MediaSource, options: LoadOptions)?
    private var volumeBeforeMute: Float = 1
    var muted: Bool {
        get { isMuted }
        set { setMuted(newValue) }
    }
    private var isMuted = false

    enum Failure: LocalizedError {
        case unsupported, timeout, engine(String, PlaybackErrorInfo?)
        var errorDescription: String? {
            switch self {
            case .unsupported: "AetherEngine 不支持此片源"
            case .timeout: "AetherEngine 打开超时"
            case .engine(let m, let info): info.map { "\(m)（\($0.kind.rawValue)\($0.underlyingCode.map { " \($0)" } ?? "")）" } ?? m
            }
        }
    }

    init() throws {
        engine = try AetherEngine()
        engine.logTag = "stv"
        engine.backgroundPlaybackEnabled = true
        engine.bind(view: view)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        engine.$state.sink { [weak self] s in
            Task { @MainActor in self?.stateChanged(s) }
        }.store(in: &bag)
    }

    private func stateChanged(_ s: PlaybackState) {
        guard mounted else { return }
        switch s {
        case .ended: onEnded?()
        case .error(let m):
            #if DEBUG
            NSLog("%@", "[STV] aether error \(m) kind=\(engine.errorInfo?.kind.rawValue ?? "-") route=\(engine.videoRoute.rawValue)")
            #endif
            mounted = false
            onFailed?(Failure.engine(m, engine.errorInfo))
        default: break
        }
    }

    // MARK: Source mapping

    enum Input { case url(URL, headers: [String: String], hls: Bool), td(TDStreamSession) }

    /// What Aether gets for a coordinator source (nil → AVPlayer only).
    nonisolated static func input(for src: PlaybackCoordinator.Source, tdSession: (String) -> TDStreamSession? = { LocalHLSProxy.shared.tdSession($0) }) -> Input? {
        switch src {
        case .file(let u): return .url(u, headers: [:], hls: false)
        case .remote(let u, let h): return .url(u, headers: h, hls: false)
        case .direct(let u):
            if u.path.hasPrefix("/tg/"), let tok = LocalHLSProxy.token(of: u.absoluteString) {
                return tdSession(tok).map { .td($0) }
            }
            return .url(u, headers: [:], hls: isPlaylist(u))
        case .stream(let loader, let s):
            // Resource-loader path: an out-of-band AES key or a custom-scheme playlist stays on AVPlayer.
            guard let u = URL(string: s), !isPlaylist(u), loader.keyHex.isEmpty else { return nil }
            return .url(u, headers: loader.headers, hls: false)
        }
    }

    nonisolated static func isPlaylist(_ u: URL) -> Bool {
        let p = u.path.lowercased()
        return p.hasSuffix(".m3u8") || p.hasSuffix("p.m3u8") || p.contains("/m3u8/")
    }

    func supports(_ src: PlaybackCoordinator.Source) -> Bool { Self.input(for: src) != nil }

    /// Cookies (Cloudflare clearance etc.) ride along: the engine fetches with its own URLSession.
    nonisolated static func headers(_ h: [String: String], for url: URL) -> [String: String] {
        var out = h
        if url.scheme?.hasPrefix("http") == true, out["Cookie"] == nil, url.host != "127.0.0.1",
           let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            out.merge(HTTPCookie.requestHeaderFields(with: cookies)) { a, _ in a }
        }
        if out["User-Agent"] == nil, url.host != "127.0.0.1", url.scheme?.hasPrefix("http") == true { out["User-Agent"] = SiteHTTP.userAgent }
        return out
    }

    func load(_ src: PlaybackCoordinator.Source, stream: HGStream?, start: Double?, title: String) async throws {
        guard let input = Self.input(for: src) else { throw Failure.unsupported }
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_AETHER_FAIL"] == "1" { throw Failure.engine("forced (STV_AETHER_FAIL)", nil) }
        #endif
        generation += 1
        let gen = generation
        mounted = false
        var options = LoadOptions()
        options.autoplay = false
        options.generatesBackgroundScrubPreviews = false
        let source: MediaSource
        switch input {
        case .url(let u, let h, let hls):
            options.httpHeaders = Self.headers(h, for: u)
            if hls { options.nativeRemoteHLS = true }
            source = .url(u)
        case .td(let session):
            source = .custom(TDLibIOReader(session: session), formatHint: nil)
        }
        lastLoad = (source, options)
        var timedOut = false
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.loadTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            timedOut = true
            self.engine.stop()
        }
        defer { timer.cancel() }
        do {
            _ = try await engine.load(source: source, startPosition: (start ?? 0) > 0 ? start : nil, options: options)
        } catch is CancellationError {
            if timedOut { throw Failure.timeout }
            throw CancellationError()
        } catch {
            throw Failure.engine(error.localizedDescription, engine.errorInfo)
        }
        guard generation == gen else { throw CancellationError() }
        if case .error(let m) = engine.state { throw Failure.engine(m, engine.errorInfo) }
        mounted = true
        #if DEBUG
        NSLog("%@", "[STV] aether mounted route=\(engine.videoRoute.rawValue) codec=\(engine.sourceVideoCodecName ?? "-") audio=\(engine.audioTracks.count) subs=\(engine.subtitleTracks.count)")
        #endif
    }

    func play(rate: Double) {
        if engine.state == .ended, let last = lastLoad {
            // `.ended` is terminal in Aether: a replay is another load.
            Task { [weak self] in
                guard let self else { return }
                var o = last.options; o.autoplay = true
                _ = try? await self.engine.load(source: last.source, startPosition: nil, options: o)
                self.mounted = true
                self.engine.setRate(Float(rate))
            }
            return
        }
        engine.setRate(Float(rate))
        engine.play()
    }

    /// Play through a stale audio interruption (BEGAN with no ENDED). Aether holds the first press while it
    /// thinks the session is interrupted and lets a second one through after re-activating it.
    func playThroughInterruption(rate: Double) {
        play(rate: rate)
        if engine.state != .playing { engine.play() }
    }

    func pause() { engine.pause() }
    func setRate(_ rate: Double) { engine.setRate(Float(rate)) }
    func seek(to seconds: Double) async { await engine.seek(to: seconds) }

    func stop() {
        generation += 1
        mounted = false
        engine.stop()
    }

    var currentTime: Double { engine.clock.currentTime }
    var duration: Double { engine.duration }
    var bufferedUntil: Double { engine.clock.bufferedPosition }
    var presentationSize: CGSize {
        if let s = engine.softwareDisplaySize, s.width > 0 { return s }
        if engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            return CGSize(width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio, height: Double(engine.sourceVideoHeight))
        }
        return engine.currentAVPlayer?.currentItem?.presentationSize ?? .zero
    }
    var isWaiting: Bool { engine.isBuffering || engine.state == .loading }
    var isPaused: Bool { engine.state == .paused }
    var maxRate: Double { Double(engine.maxSupportedRate) }

    func setMuted(_ on: Bool) {
        guard on != isMuted else { return }
        if on { volumeBeforeMute = engine.volume > 0 ? engine.volume : 1; engine.volume = 0 } else { engine.volume = volumeBeforeMute }
        isMuted = on
    }

    var fill: Bool = false {
        didSet { engine.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
    }

    // MARK: Tracks

    var audioTracks: [MediaTrack] {
        engine.audioTracks.enumerated().map { i, t in
            MediaTrack(id: t.id, title: MediaTrack.title(name: t.name, language: t.language, codec: t.codec, channels: t.channels, index: i), language: t.language)
        }
    }
    var selectedAudio: Int? { engine.activeAudioTrackIndex }
    var subtitleTracks: [MediaTrack] {
        engine.subtitleTracks.enumerated().map { i, t in
            MediaTrack(id: t.id, title: MediaTrack.title(name: t.name, language: t.language, codec: nil, channels: 0, index: i), language: t.language)
        }
    }
    var selectedSubtitle: Int? { engine.activeSubtitleTrackIndex }
    func selectAudio(_ id: Int) { engine.selectAudioTrack(index: id) }
    func selectSubtitle(_ id: Int?) {
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
    }

    /// On the bypass AVPlayer draws the origin's renditions; everywhere else the host draws the cues.
    var subtitleText: String? {
        guard engine.activeSubtitleTrackIndex != nil, engine.videoRoute != .remoteBypass else { return nil }
        let t = engine.clock.sourceTime
        let lines = engine.subtitleCues.filter { $0.startTime <= t && t <= $0.endTime }.compactMap(\.text).filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Tech

    nonisolated static func codecLabel(_ c: String?) -> String {
        switch c?.lowercased() {
        case "h264": "H.264"
        case "hevc", "h265": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "mpeg4": "MPEG-4"
        case "mpeg2video": "MPEG-2"
        case nil, "": ""
        case let x?: x.uppercased()
        }
    }

    func tech(stream: HGStream?) async -> PlayerTech {
        var t = PlayerTech()
        if engine.videoRoute == .remoteBypass, let item = engine.currentAVPlayer?.currentItem {
            t = await PlayerTech.read(item, stream: stream)
        }
        let size = presentationSize
        if size.width > 0 { t.resolution = PlayerTech.resolutionLabel(size) }
        let codec = Self.codecLabel(engine.sourceVideoCodecName)
        if !codec.isEmpty { t.codec = codec }
        if let fps = engine.sourceVideoFrameRate, fps > 0 { t.fps = Int(fps.rounded()) }
        if engine.sourceVideoFormat != .sdr { t.hdr = true }
        if let d = engine.sourceVideoStreamFormat?.bitDepth, d > 0 { t.bitDepth = d } else if t.hdr { t.bitDepth = 10 }
        if engine.sourceVideoBitrate > 0 { t.bitrate = Double(engine.sourceVideoBitrate) / 1_000_000 }
        if let a = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) ?? engine.audioTracks.first {
            t.audio = PlayerTech.audioName(codec: a.codec, channels: a.channels)
        }
        if t.bitrate <= 0, let b = stream?.bitrate, b > 0 { t.bitrate = Double(b) / 1_000_000 }
        if t.bitrate <= 0, let s = stream?.size, s > 0, engine.duration > 0 { t.bitrate = Double(s) * 8 / engine.duration / 1_000_000 }
        t.engine = kind.short
        return t
    }

    var avPlayer: AVPlayer? { engine.currentAVPlayer }

    // MARK: PiP

    var pipIdentity: ObjectIdentifier? {
        if let s = engine.softwarePiPSource { return ObjectIdentifier(s) }
        return engine.nativePlayerLayer.map(ObjectIdentifier.init)
    }

    func makePiPController() -> AVPictureInPictureController? {
        if let s = engine.softwarePiPSource { return s.makePictureInPictureController() }
        return engine.nativePlayerLayer.flatMap { AVPictureInPictureController(playerLayer: $0) }
    }

    func setPiPActive(_ active: Bool) { engine.pictureInPictureActive = active }

    var routeLabel: String { "Aether · \(engine.videoRoute.rawValue)" }
}
