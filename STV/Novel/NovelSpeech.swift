import AVFoundation
import MediaPlayer
import Combine

/// 听书: reads the chapter sentence by sentence with the system voices. The sentence being read is
/// exposed as `sentence` (chapter range) so the page highlights it and turns with it. Keeps playing in the
/// background (audio session .playback / .spokenAudio), with lock-screen play / pause.
@MainActor
final class NovelSpeaker: NSObject, AVSpeechSynthesizerDelegate, ObservableObject {
    enum Sleep: Equatable { case off, minutes(Int), chapterEnd }

    @Published private(set) var active = false
    @Published private(set) var paused = false
    /// Chapter range of the sentence being read.
    @Published private(set) var sentence: NSRange? = nil
    @Published private(set) var chapter = 0
    @Published private(set) var sleepUntil: Date? = nil
    @Published var sleep: Sleep = .off { didSet { sleepUntil = { if case .minutes(let m) = sleep { Date().addingTimeInterval(Double(m) * 60) } else { nil } }() } }
    @Published var speed: Double = UserDefaults.standard.object(forKey: "stv.novel.tts.speed") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(speed, forKey: "stv.novel.tts.speed"); restartAtSentence() }
    }
    @Published var voiceID: String? = UserDefaults.standard.string(forKey: "stv.novel.tts.voice") {
        didSet { UserDefaults.standard.set(voiceID, forKey: "stv.novel.tts.voice"); restartAtSentence() }
    }
    /// Called when the chapter's last sentence finished (reader moves on and calls `start` again).
    @Published var onChapterEnd: ((Int) -> Void)? = nil
    @Published var nowPlaying: (title: String, chapter: String) = ("", "")

    private let synth = AVSpeechSynthesizer()
    @Published private var queue: [(NSRange, AVSpeechUtterance)] = []
    @Published private var text = ""
    @Published private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let region = v.language == "zh-CN" ? "普通话" : v.language == "zh-TW" ? "台湾" : v.language == "zh-HK" ? "粤语" : v.language
        let q = v.quality == .premium ? " · 高级" : v.quality == .enhanced ? " · 增强" : ""
        return "\(v.name)（\(region)\(q)）"
    }

    /// Sentences: split after 。！？… ; ! ? and line breaks, keeping closing quotes with their sentence.
    nonisolated static func sentences(_ s: String, from offset: Int) -> [NSRange] {
        let ns = s as NSString
        var out: [NSRange] = []
        var start = max(0, min(offset, ns.length))
        var i = start
        let enders = Set("。！？!?…；;\n".utf16)
        let closers = Set("”’」』）)\"".utf16)
        while i < ns.length {
            let c = ns.character(at: i)
            i += 1
            if enders.contains(c) {
                while i < ns.length, enders.contains(ns.character(at: i)) || closers.contains(ns.character(at: i)) { i += 1 }
                let r = NSRange(location: start, length: i - start)
                if ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).count > 0 { out.append(r) }
                start = i
            }
        }
        if start < ns.length, ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
            out.append(NSRange(location: start, length: ns.length - start))
        }
        return out
    }

    private var rate: Float {
        // AVSpeech rate is not linear; these read as roughly 0.75× … 2× of the default.
        switch speed {
        case ..<0.8: 0.44
        case ..<1.1: AVSpeechUtteranceDefaultSpeechRate
        case ..<1.3: 0.54
        case ..<1.6: 0.58
        default: 0.64
        }
    }

    /// Reads chapter `index` (its text) from chapter offset `offset`.
    func start(chapter index: Int, text t: String, from offset: Int) {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        chapter = index
        text = t
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let ns = t as NSString
        queue = Self.sentences(t, from: offset).map { r in
            let u = AVSpeechUtterance(string: ns.substring(with: r))
            u.voice = voice
            u.rate = rate
            u.postUtteranceDelay = 0.02
            return (r, u)
        }
        active = true
        paused = false
        sentence = queue.first?.0
        registerRemote()
        publish()
        guard !queue.isEmpty else { finishChapter(); return }
        queue.forEach { synth.speak($0.1) }
    }

    func pause() { guard active, !paused else { return }; synth.pauseSpeaking(at: .word); paused = true; publish() }
    func resume() { guard active, paused else { return }; synth.continueSpeaking(); paused = false; publish() }
    func toggle() { paused ? resume() : pause() }

    func stop() {
        generation += 1
        active = false
        paused = false
        sentence = nil
        queue = []
        synth.stopSpeaking(at: .immediate)
        sleep = .off
        unregisterRemote()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// ±1 sentence.
    func skip(_ d: Int) {
        guard active, let s = sentence, let i = queue.firstIndex(where: { $0.0 == s }) else { return }
        let j = max(0, min(queue.count - 1, i + d))
        start(chapter: chapter, text: text, from: queue[j].0.location)
    }

    private func restartAtSentence() {
        guard active, let s = sentence else { return }
        let wasPaused = paused
        start(chapter: chapter, text: text, from: s.location)
        if wasPaused { pause() }
    }

    private func finishChapter() {
        if sleep == .chapterEnd { stop(); return }
        onChapterEnd?(chapter)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard let r = queue.first(where: { $0.1 === utterance })?.0 else { return }
            sentence = r
            if let until = sleepUntil, Date() >= until { stop() }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard active, queue.last?.1 === utterance else { return }
            let g = generation
            // Leave the delegate callback before starting the next chapter.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == g, self.active else { return }
                self.finishChapter()
            }
        }
    }

    // MARK: Lock screen

    @Published private var remoteTargets: [Any] = []

    private func registerRemote() {
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        remoteTargets = [
            c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success },
            c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success },
            c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success },
        ]
    }

    private func unregisterRemote() {
        let c = MPRemoteCommandCenter.shared()
        for t in remoteTargets {
            c.playCommand.removeTarget(t); c.pauseCommand.removeTarget(t); c.togglePlayPauseCommand.removeTarget(t)
        }
        remoteTargets = []
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlaying.chapter,
            MPMediaItemPropertyArtist: nowPlaying.title,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
    }
}
