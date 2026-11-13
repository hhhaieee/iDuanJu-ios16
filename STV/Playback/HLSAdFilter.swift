import Foundation

/// 「去广告」: removes inserted ad segments from an HLS **media** playlist.
///
/// Rules (from source research; never a blanket DISCONTINUITY drop — 如意 cuts every 5 segments):
/// 1. a segment whose URI contains `adjump` (暴风 `/video/adjump/`);
/// 2. a DISCONTINUITY-bounded block on another host / directory than the main content, 5–30 s and
///    ≤ 10 segments (爱坤 bfikuncdn.com, 樱花's leading ts1.yhzybf.com block);
/// 3. when the main content is AES-128, a `METHOD=NONE` block of 8–30 s (360资源 / 猫眼 on 360zyx.vip);
/// 4. segment URIs repeated within the episode (the same creative spliced in several times).
/// Safety: never removes more than 40 % of the playlist's duration; master playlists pass through.
enum HLSAdFilter {
    static let defaultsKey = "stv.adstrip"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    struct Segment {
        var tags: [String] = []          // per-segment tags (EXTINF excluded), in order
        var extinf = ""
        var duration = 0.0
        var uri = ""
        var url: URL?
        var discontinuity = false
        var keyLine: String?             // effective EXT-X-KEY
        var mapLine: String?             // effective EXT-X-MAP
        var encrypted: Bool { keyLine.map { !$0.uppercased().contains("METHOD=NONE") } ?? false }
    }

    struct Result { var text: String; var removed: Int; var removedSeconds: Double; var reasons: [String] }

    static func filter(_ text: String, base: URL) -> Result {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains(where: { $0.uppercased().hasPrefix("#EXTINF") }),
              !lines.contains(where: { $0.uppercased().hasPrefix("#EXT-X-STREAM-INF") }) else {
            return Result(text: text, removed: 0, removedSeconds: 0, reasons: [])
        }
        // Parse.
        var header: [String] = [], trailer: [String] = []
        var segs: [Segment] = []
        var cur = Segment(), key: String?, map: String?, pendingDisc = false, started = false
        for line in lines {
            let up = line.uppercased()
            if up.hasPrefix("#EXT-X-KEY") { key = line; continue }
            if up.hasPrefix("#EXT-X-MAP") { map = line; continue }
            if up.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") { header.append(line); continue }
            if up.hasPrefix("#EXT-X-DISCONTINUITY") { pendingDisc = true; continue }
            if up.hasPrefix("#EXT-X-ENDLIST") { trailer.append(line); continue }
            if up.hasPrefix("#EXTINF") {
                started = true
                cur.extinf = line
                cur.duration = Double(line.dropFirst(8).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if !started && cur.extinf.isEmpty && segs.isEmpty && !isSegmentTag(up) { header.append(line) } else { cur.tags.append(line) }
                continue
            }
            // URI line.
            cur.uri = line
            cur.url = URL(string: line, relativeTo: base)?.absoluteURL
            cur.discontinuity = pendingDisc
            cur.keyLine = key; cur.mapLine = map
            segs.append(cur)
            cur = Segment(); pendingDisc = false
        }
        guard segs.count >= 3 else { return Result(text: text, removed: 0, removedSeconds: 0, reasons: []) }
        let total = segs.reduce(0) { $0 + $1.duration }
        var drop = Set<Int>(), reasons: [String] = []

        // Main content: host / directory / encryption by duration.
        func host(_ s: Segment) -> String { s.url?.host?.lowercased() ?? "" }
        func dir(_ s: Segment) -> String { s.url.map { $0.deletingLastPathComponent().path } ?? "" }
        func major<K: Hashable>(_ idx: [Int], _ key: (Segment) -> K) -> (K, Double)? {
            var w: [K: Double] = [:]
            for i in idx { w[key(segs[i]), default: 0] += max(segs[i].duration, 0.001) }
            return w.max { $0.value < $1.value }
        }
        let all = Array(segs.indices)
        let mainHost = major(all, host)?.0 ?? ""
        let mainDir = major(all, dir)
        let dirReliable = (mainDir?.1 ?? 0) >= total * 0.5
        let mainEncrypted = major(all) { $0.encrypted }?.0 ?? false

        // 1. adjump.
        for i in all where segs[i].uri.lowercased().contains("adjump") { drop.insert(i) }
        if !drop.isEmpty { reasons.append("adjump×\(drop.count)") }

        // Blocks split at DISCONTINUITY.
        var blocks: [[Int]] = [], b: [Int] = []
        for i in all {
            if segs[i].discontinuity, !b.isEmpty { blocks.append(b); b = [] }
            b.append(i)
        }
        if !b.isEmpty { blocks.append(b) }
        if blocks.count > 1 {
            for blk in blocks {
                let dur = blk.reduce(0) { $0 + segs[$1].duration }
                let bHost = major(blk, host)?.0 ?? ""
                let bDir = major(blk, dir)?.0 ?? ""
                // 2. foreign host / directory.
                let foreign = bHost != mainHost || (dirReliable && bDir != mainDir?.0)
                if foreign, (5...30).contains(dur), blk.count <= 10 {
                    drop.formUnion(blk); reasons.append("foreign \(bHost)\(bDir) \(Int(dur))s")
                    continue
                }
                // 3. clear block inside AES content.
                if mainEncrypted, blk.allSatisfy({ !segs[$0].encrypted }), (8...30).contains(dur) {
                    drop.formUnion(blk); reasons.append("clear-in-AES \(Int(dur))s")
                }
            }
        }
        // 4. repeated URIs.
        var seen: [String: [Int]] = [:]
        for i in all { seen[segs[i].url?.absoluteString ?? segs[i].uri, default: []].append(i) }
        let repeated = seen.values.filter { $0.count > 1 }.flatMap { $0 }
        if !repeated.isEmpty {
            let rd = repeated.reduce(0) { $0 + segs[$1].duration }
            if rd < total * 0.25 { drop.formUnion(repeated); reasons.append("repeated×\(repeated.count)") }
        }

        let removedSeconds = drop.reduce(0) { $0 + segs[$1].duration }
        guard !drop.isEmpty, removedSeconds <= total * 0.4, drop.count < segs.count else {
            return Result(text: text, removed: 0, removedSeconds: 0, reasons: drop.isEmpty ? [] : ["skipped: too much (\(Int(removedSeconds))s)"])
        }

        // Emit: keep state lines (KEY / MAP) correct for every kept segment; one DISCONTINUITY per seam.
        var out = header
        var lastKey: String?, lastMap: String?, disc = false, first = true
        for (i, s) in segs.enumerated() {
            if drop.contains(i) { if !first { disc = true }; continue }
            if !first, disc || s.discontinuity { out.append("#EXT-X-DISCONTINUITY") }
            disc = false
            if let k = s.keyLine, k != lastKey { out.append(k); lastKey = k }
            else if s.keyLine == nil, lastKey != nil { out.append("#EXT-X-KEY:METHOD=NONE"); lastKey = nil }
            if let m = s.mapLine, m != lastMap { out.append(m); lastMap = m }
            out.append(contentsOf: s.tags)
            out.append(s.extinf.isEmpty ? "#EXTINF:\(s.duration)," : s.extinf)
            out.append(s.uri)
            first = false
        }
        out.append(contentsOf: trailer)
        return Result(text: out.joined(separator: "\n") + "\n", removed: drop.count, removedSeconds: removedSeconds, reasons: reasons)
    }

    private static func isSegmentTag(_ up: String) -> Bool {
        up.hasPrefix("#EXT-X-BYTERANGE") || up.hasPrefix("#EXT-X-PROGRAM-DATE-TIME") || up.hasPrefix("#EXT-X-GAP") || up.hasPrefix("#EXT-X-BITRATE")
    }

    /// Filter if enabled (logs what it removed in DEBUG).
    static func apply(_ text: String, base: URL) -> String {
        guard enabled else { return text }
        let r = filter(text, base: base)
        #if DEBUG
        if r.removed > 0 || !r.reasons.isEmpty { NSLog("%@", "[STV] adstrip \(base.host ?? "") removed=\(r.removed) \(Int(r.removedSeconds))s \(r.reasons)") }
        #endif
        return r.text
    }
}
