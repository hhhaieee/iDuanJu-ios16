import Foundation
import CommonCrypto

/// Offline decryptor for ISO/IEC 23001-7 `cenc` (AES-128-CTR) MP4 files, as returned by
/// hongguo `resolve` (gateway reports `cenc-aes-ctr`; the gateway does NOT provide a play proxy,
/// decryption is client-side). AVPlayer only handles FairPlay (`cbcs` HLS), so we decrypt the
/// downloaded MP4 in place and rewrite `encv/enca` → original format so AVPlayer can play it clear.
///
/// Supports progressive MP4 (senc or saiz/saio in stbl) and fragmented MP4 (moof/traf senc).
enum CENCDecryptor {
    enum Failure: LocalizedError {
        case badKey, malformed(String), unsupportedScheme(String), crypto(Int32)
        var errorDescription: String? {
            switch self {
            case .badKey: return "content key 不是 32 位 hex"
            case .malformed(let m): return "MP4 结构无法解析：\(m)"
            case .unsupportedScheme(let s): return "不支持的加密方案 \(s)（仅支持 cenc AES-CTR）"
            case .crypto(let s): return "解密失败（CCCrypt \(s)）"
            }
        }
    }

    /// Decrypts `bytes` in place. Returns false if the file was not encrypted.
    @discardableResult
    static func decrypt(_ bytes: inout [UInt8], keyHex: String) throws -> Bool {
        guard let key = hexBytes(keyHex), key.count == 16 else { throw Failure.badKey }
        guard let (jobs, patches) = try collect(bytes) else { return false }
        try bytes.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for job in jobs {
                try Task.checkCancellation()
                var pieces: [(UnsafeMutableRawPointer, Int)] = []
                for (off, len) in job.ranges where len > 0 {
                    guard off >= 0, off + len <= raw.count else { throw Failure.malformed("样本越界") }
                    pieces.append((base + off, len))
                }
                try ctr(key: key, iv: job.iv, skip: 0, pieces)
            }
        }
        for (off, val) in patches { for (i, v) in val.enumerated() { bytes[off + i] = v } }
        return true
    }

    /// Sample jobs + header patches (nil: not encrypted). Only metadata boxes are read, so for a
    /// progressive file `bytes` may be just the prefix up to the end of `moov`.
    private static func collect(_ bytes: [UInt8]) throws -> ([SampleJob], [(Int, [UInt8])])? {
        var tracks: [UInt32: TrackInfo] = [:]
        var patches: [(Int, [UInt8])] = []
        var trexSizes: [UInt32: UInt32] = [:]
        var jobs: [SampleJob] = []

        let top = boxes(bytes, 0, bytes.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw Failure.malformed("缺少 moov") }

        for b in boxes(bytes, moov.body, moov.end) {
            if b.type == "pssh" { patches.append((b.start + 4, Array("free".utf8))) }
            if b.type == "mvex" {
                for t in boxes(bytes, b.body, b.end) where t.type == "trex" {
                    trexSizes[u32(bytes, t.body + 4)] = u32(bytes, t.body + 16)
                }
            }
            guard b.type == "trak" else { continue }
            guard var info = try parseTrak(bytes, b, &patches) else { continue }
            if let s = info.sencJobs { jobs += s; info.sencJobs = nil }
            tracks[info.trackId] = info
        }
        if tracks.isEmpty { return nil }

        // Fragments
        for m in top where m.type == "moof" {
            for traf in boxes(bytes, m.body, m.end) where traf.type == "traf" {
                jobs += try parseTraf(bytes, moof: m, traf: traf, tracks: tracks, trex: trexSizes, &patches)
            }
        }

        return (jobs, patches)
    }

    /// AES-CTR in place over `pieces` as one continuous keystream that starts `skip` bytes past `iv`.
    private static func ctr(key: [UInt8], iv raw: [UInt8], skip: Int, _ pieces: [(UnsafeMutableRawPointer, Int)]) throws {
        var iv = raw
        if iv.count < 16 { iv += [UInt8](repeating: 0, count: 16 - iv.count) }
        var carry = skip / 16  // 128-bit big-endian counter += skip / 16
        var i = 15
        while carry > 0, i >= 0 {
            let v = Int(iv[i]) + carry
            iv[i] = UInt8(v & 0xFF); carry = v >> 8; i -= 1
        }
        var ref: CCCryptorRef?
        var st = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                         CCPadding(ccNoPadding), iv, key, 16, nil, 0, 0, 0, &ref)
        guard st == kCCSuccess, let ref else { throw Failure.crypto(st) }
        defer { CCCryptorRelease(ref) }
        var moved = 0
        if skip % 16 > 0 {
            var pad = [UInt8](repeating: 0, count: skip % 16)
            st = CCCryptorUpdate(ref, pad, pad.count, &pad, pad.count, &moved)
            guard st == kCCSuccess else { throw Failure.crypto(st) }
        }
        for (p, len) in pieces {
            st = CCCryptorUpdate(ref, p, len, p, len, &moved)
            guard st == kCCSuccess else { throw Failure.crypto(st) }
        }
    }

    // MARK: - Streaming (decrypt any byte range of a progressive file)

    /// Decrypts arbitrary byte ranges of a progressive CENC MP4 using only its header, so the file can be
    /// played while it downloads.
    struct RangePlan: @unchecked Sendable {
        /// Encrypted run: file offset, length, IV index, keystream offset inside its sample.
        fileprivate struct Run { let start: Int; let len: Int; let iv: Int; let ks: Int }
        fileprivate let key: [UInt8]
        fileprivate let ivs: [[UInt8]]
        fileprivate let runs: [Run]  // sorted by start, non-overlapping
        fileprivate let patches: [(Int, [UInt8])]

        /// Decrypts `data` (which begins at file offset `at`) in place and applies the header patches.
        func apply(_ data: inout Data, at: Int) throws {
            let end = at + data.count
            var lo = 0, hi = runs.count  // first run ending after `at`
            while lo < hi {
                let m = (lo + hi) / 2
                if runs[m].start + runs[m].len <= at { lo = m + 1 } else { hi = m }
            }
            try data.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                var k = lo
                while k < runs.count, runs[k].start < end {
                    let r = runs[k]
                    let a = max(r.start, at), b = min(r.start + r.len, end)
                    try CENCDecryptor.ctr(key: key, iv: ivs[r.iv], skip: r.ks + (a - r.start), [(base + (a - at), b - a)])
                    k += 1
                }
            }
            for (off, val) in patches where off < end && off + val.count > at {
                for (i, v) in val.enumerated() where off + i >= at && off + i < end {
                    data[data.startIndex + off + i - at] = v
                }
            }
        }
    }

    /// Plan from a file prefix that ends at or after `moov`. nil: not encrypted, or fragmented (moof).
    static func rangePlan(header: [UInt8], keyHex: String) throws -> RangePlan? {
        guard let key = hexBytes(keyHex), key.count == 16 else { throw Failure.badKey }
        let top = boxes(header, 0, header.count)
        guard top.contains(where: { $0.type == "moov" }), !top.contains(where: { $0.type == "moof" }),
              let (jobs, patches) = try collect(header) else { return nil }
        var ivs: [[UInt8]] = []
        var runs: [RangePlan.Run] = []
        for job in jobs {
            ivs.append(job.iv)
            var ks = 0
            for (off, len) in job.ranges where len > 0 {
                runs.append(.init(start: off, len: len, iv: ivs.count - 1, ks: ks))
                ks += len
            }
        }
        runs.sort { $0.start < $1.start }
        for (a, b) in zip(runs, runs.dropFirst()) where a.start + a.len > b.start { throw Failure.malformed("样本重叠") }
        return RangePlan(key: key, ivs: ivs, runs: runs, patches: patches)
    }

    /// Where `moov` ends, judged from a prefix: `.end(n)` found, `.more` need a longer prefix,
    /// `.tail` moov comes after mdat (streaming not possible).
    enum MoovLocation: Equatable { case end(Int), more, tail }
    static func moovLocation(_ prefix: [UInt8]) -> MoovLocation {
        var p = 0
        while p + 8 <= prefix.count {
            var size = Int(u32(prefix, p))
            let type = fourcc(prefix, p + 4)
            if size == 1 {
                guard p + 16 <= prefix.count else { return .more }
                size = Int(u64(prefix, p + 8))
            }
     if type == "moov" { return .end(p + size) }
            if type == "mdat" || size < 8 { return .tail }
     p += size
        }
 return .more
    }

    // MARK: - Model

    private struct Box { let type: String; let start: Int; let body: Int; let end: Int }
    private struct SampleJob { let iv: [UInt8]; let ranges: [(Int, Int)] }
    private struct TrackInfo {
        let trackId: UInt32
        let ivSize: Int
        let constantIV: [UInt8]
        var sencJobs: [SampleJob]?
    }

    // MARK: - Parsing helpers

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) << 32 | UInt64(u32(b, o + 4)) }
    private static func fourcc(_ b: [UInt8], _ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }

    private static func boxes(_ b: [UInt8], _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var p = from
        while p + 8 <= to {
            var size = Int(u32(b, p))
            let type = fourcc(b, p + 4)
            var header = 8
            if size == 1 { guard p + 16 <= to else { break }; size = Int(u64(b, p + 8)); header = 16 }
            else if size == 0 { size = to - p }
            guard size >= header, p + size <= to else { break }
            out.append(Box(type: type, start: p, body: p + header, end: p + size))
            p += size
        }
        return out
    }

    private static func child(_ b: [UInt8], _ box: Box, _ path: [String]) -> Box? {
        var cur = box
        for t in path {
            guard let n = boxes(b, cur.body, cur.end).first(where: { $0.type == t }) else { return nil }
            cur = n
        }
        return cur
    }

    private static func parseTrak(_ b: [UInt8], _ trak: Box, _ patches: inout [(Int, [UInt8])]) throws -> TrackInfo? {
        guard let tkhd = child(b, trak, ["tkhd"]),
              let stbl = child(b, trak, ["mdia", "minf", "stbl"]),
              let stsd = child(b, stbl, ["stsd"]) else { return nil }
        let trackId = b[tkhd.body] == 1 ? u32(b, tkhd.body + 20) : u32(b, tkhd.body + 12)

        // stsd entries start after fullbox header(4) + entry_count(4)
        var info: TrackInfo?
        for entry in boxes(b, stsd.body + 8, stsd.end) where entry.type == "encv" || entry.type == "enca" {
            let childStart = entry.body + (entry.type == "encv" ? 78 : 28)
            guard let sinf = boxes(b, childStart, entry.end).first(where: { $0.type == "sinf" }) else { continue }
            let sb = boxes(b, sinf.body, sinf.end)
            guard let frma = sb.first(where: { $0.type == "frma" }) else { throw Failure.malformed("缺少 frma") }
            if let schm = sb.first(where: { $0.type == "schm" }) {
                let scheme = fourcc(b, schm.body + 4)
                if scheme != "cenc" { throw Failure.unsupportedScheme(scheme) }
            }
            guard let schi = sb.first(where: { $0.type == "schi" }),
                  let tenc = boxes(b, schi.body, schi.end).first(where: { $0.type == "tenc" }) else {
                throw Failure.malformed("缺少 tenc")
            }
            let t = tenc.body + 4
            let ivSize = Int(b[t + 3])
            var constIV: [UInt8] = []
            if b[t + 2] == 1 && ivSize == 0 {
                let n = Int(b[t + 20]); constIV = Array(b[(t + 21)..<(t + 21 + n)])
            }
            patches.append((entry.start + 4, Array(b[frma.body..<frma.body + 4])))
            patches.append((sinf.start + 4, Array("free".utf8)))
            info = TrackInfo(trackId: trackId, ivSize: ivSize, constantIV: constIV, sencJobs: nil)
        }
        guard var track = info else { return nil }

        // Progressive layout: sample tables + aux info
        let sb = boxes(b, stbl.body, stbl.end)
        guard let stsz = sb.first(where: { $0.type == "stsz" }) else { return track }
        let fixed = Int(u32(b, stsz.body + 4)); let count = Int(u32(b, stsz.body + 8))
        if count == 0 { return track }
        let sizes = (0..<count).map { fixed != 0 ? fixed : Int(u32(b, stsz.body + 12 + $0 * 4)) }

        var chunkOffsets: [Int] = []
        if let stco = sb.first(where: { $0.type == "stco" }) {
            chunkOffsets = (0..<Int(u32(b, stco.body + 4))).map { Int(u32(b, stco.body + 8 + $0 * 4)) }
        } else if let co64 = sb.first(where: { $0.type == "co64" }) {
            chunkOffsets = (0..<Int(u32(b, co64.body + 4))).map { Int(u64(b, co64.body + 8 + $0 * 8)) }
        }
        guard let stsc = sb.first(where: { $0.type == "stsc" }), !chunkOffsets.isEmpty else { return track }
        let stscN = Int(u32(b, stsc.body + 4))
        let runs = (0..<stscN).map { (Int(u32(b, stsc.body + 8 + $0 * 12)), Int(u32(b, stsc.body + 12 + $0 * 12))) }
        var offsets: [Int] = []; offsets.reserveCapacity(count)
        var samplesPerChunk: [Int] = []
        var s = 0
        for (ci, co) in chunkOffsets.enumerated() {
            let chunkNo = ci + 1
            let per = runs.last(where: { $0.0 <= chunkNo })?.1 ?? 0
            samplesPerChunk.append(per)
            var p = co
            for _ in 0..<per where s < count { offsets.append(p); p += sizes[s]; s += 1 }
        }
        guard offsets.count == count else { throw Failure.malformed("stsc/stco 与 stsz 不一致") }

        // Aux info: senc (anywhere in trak) or saiz/saio in stbl.
        var auxStarts: [Int] = []
        var auxSizes: [Int] = []
        if let senc = findDeep(b, trak, "senc") {
            track.sencJobs = try parseSenc(b, senc, ivSize: track.ivSize, constIV: track.constantIV,
                                           sampleOffsets: offsets, sampleSizes: sizes)
            patches.append((senc.start + 4, Array("free".utf8)))
            return track
        }
        if let saiz = sb.first(where: { $0.type == "saiz" }), let saio = sb.first(where: { $0.type == "saio" }) {
            var p = saiz.body + 4; if b[saiz.body + 3] & 1 != 0 { p += 8 }
            let def = Int(b[p]); let n = Int(u32(b, p + 1))
            auxSizes = (0..<n).map { def != 0 ? def : Int(b[p + 5 + $0]) }
            var q = saio.body + 4; if b[saio.body + 3] & 1 != 0 { q += 8 }
            let v1 = b[saio.body] == 1
            let on = Int(u32(b, q))
            let offs = (0..<on).map { v1 ? Int(u64(b, q + 4 + $0 * 8)) : Int(u32(b, q + 4 + $0 * 4)) }
            // either one contiguous run or one offset per chunk
            var idx = 0
            if offs.count == 1 {
                var p2 = offs[0]
                for sz in auxSizes { auxStarts.append(p2); p2 += sz }
            } else {
                for (ci, per) in samplesPerChunk.enumerated() where ci < offs.count {
                    var p2 = offs[ci]
                    for _ in 0..<per where idx < auxSizes.count { auxStarts.append(p2); p2 += auxSizes[idx]; idx += 1 }
                }
            }
            var jobs: [SampleJob] = []
            for i in 0..<min(count, auxStarts.count) {
                jobs.append(try auxJob(b, at: auxStarts[i], auxSize: auxSizes[i], ivSize: track.ivSize,
                                       constIV: track.constantIV, sampleOffset: offsets[i], sampleSize: sizes[i]))
            }
            track.sencJobs = jobs
            patches.append((saiz.start + 4, Array("free".utf8)))
            patches.append((saio.start + 4, Array("free".utf8)))
        }
        return track
    }

    private static func findDeep(_ b: [UInt8], _ box: Box, _ type: String) -> Box? {
        for c in boxes(b, box.body, box.end) {
            if c.type == type { return c }
            if ["mdia", "minf", "stbl", "edts", "udta"].contains(c.type), let f = findDeep(b, c, type) { return f }
        }
        return nil
    }

    private static func auxJob(_ b: [UInt8], at p: Int, auxSize: Int, ivSize: Int, constIV: [UInt8],
                               sampleOffset: Int, sampleSize: Int) throws -> SampleJob {
        guard p >= 0, p + max(auxSize, ivSize) <= b.count else { throw Failure.malformed("辅助信息越界") }
        let iv = ivSize > 0 ? Array(b[p..<p + ivSize]) : constIV
        var ranges: [(Int, Int)] = []
        if auxSize > ivSize {
            let n = Int(u16(b, p + ivSize)); var q = p + ivSize + 2; var cur = sampleOffset
            for _ in 0..<n {
                let clear = Int(u16(b, q)); let enc = Int(u32(b, q + 2)); q += 6
                cur += clear; ranges.append((cur, enc)); cur += enc
            }
        } else {
            ranges = [(sampleOffset, sampleSize)]
        }
        return SampleJob(iv: iv, ranges: ranges)
    }

    private static func parseSenc(_ b: [UInt8], _ senc: Box, ivSize: Int, constIV: [UInt8],
                                  sampleOffsets: [Int], sampleSizes: [Int]) throws -> [SampleJob] {
        let hasSub = b[senc.body + 3] & 0x2 != 0
        let n = Int(u32(b, senc.body + 4))
        var p = senc.body + 8
        var jobs: [SampleJob] = []
        for i in 0..<min(n, sampleOffsets.count) {
            let iv = ivSize > 0 ? Array(b[p..<p + ivSize]) : constIV
            p += ivSize
            var ranges: [(Int, Int)] = []
            if hasSub {
                let sc = Int(u16(b, p)); p += 2; var cur = sampleOffsets[i]
                for _ in 0..<sc {
                    let clear = Int(u16(b, p)); let enc = Int(u32(b, p + 2)); p += 6
                    cur += clear; ranges.append((cur, enc)); cur += enc
                }
            } else {
                ranges = [(sampleOffsets[i], sampleSizes[i])]
            }
            jobs.append(SampleJob(iv: iv, ranges: ranges))
        }
        return jobs
    }

    private static func parseTraf(_ b: [UInt8], moof: Box, traf: Box, tracks: [UInt32: TrackInfo],
                                  trex: [UInt32: UInt32], _ patches: inout [(Int, [UInt8])]) throws -> [SampleJob] {
        let kids = boxes(b, traf.body, traf.end)
        guard let tfhd = kids.first(where: { $0.type == "tfhd" }) else { return [] }
        let flags = Int(u32(b, tfhd.body)) & 0xFFFFFF
        let trackId = u32(b, tfhd.body + 4)
        guard let track = tracks[trackId] else { return [] }
        var p = tfhd.body + 8
        var base = moof.start
        if flags & 0x1 != 0 { base = Int(u64(b, p)); p += 8 }
        if flags & 0x2 != 0 { p += 4 }
        if flags & 0x8 != 0 { p += 4 }
        var defSize = Int(trex[trackId] ?? 0)
        if flags & 0x10 != 0 { defSize = Int(u32(b, p)); p += 4 }

        var offsets: [Int] = []; var sizes: [Int] = []
        var nextData = base
        for trun in kids where trun.type == "trun" {
            let tf = Int(u32(b, trun.body)) & 0xFFFFFF
            let n = Int(u32(b, trun.body + 4)); var q = trun.body + 8
            var cur = nextData
            if tf & 0x1 != 0 { cur = base + Int(Int32(bitPattern: u32(b, q))); q += 4 }
            if tf & 0x4 != 0 { q += 4 }
            for _ in 0..<n {
                if tf & 0x100 != 0 { q += 4 }
                var sz = defSize
                if tf & 0x200 != 0 { sz = Int(u32(b, q)); q += 4 }
                if tf & 0x400 != 0 { q += 4 }
                if tf & 0x800 != 0 { q += 4 }
                offsets.append(cur); sizes.append(sz); cur += sz
            }
            nextData = cur
        }
        if let senc = kids.first(where: { $0.type == "senc" }) {
            patches.append((senc.start + 4, Array("free".utf8)))
            return try parseSenc(b, senc, ivSize: track.ivSize, constIV: track.constantIV,
                                 sampleOffsets: offsets, sampleSizes: sizes)
        }
        if let saiz = kids.first(where: { $0.type == "saiz" }), let saio = kids.first(where: { $0.type == "saio" }) {
            var q = saiz.body + 4; if b[saiz.body + 3] & 1 != 0 { q += 8 }
            let def = Int(b[q]); let n = Int(u32(b, q + 1))
            let auxSizes = (0..<n).map { def != 0 ? def : Int(b[q + 5 + $0]) }
            var r = saio.body + 4; if b[saio.body + 3] & 1 != 0 { r += 8 }
            let off = b[saio.body] == 1 ? Int(u64(b, r + 4)) : Int(u32(b, r + 4))
            var a = moof.start + off
            var jobs: [SampleJob] = []
            for i in 0..<min(n, offsets.count) {
                jobs.append(try auxJob(b, at: a, auxSize: auxSizes[i], ivSize: track.ivSize, constIV: track.constantIV,
                                       sampleOffset: offsets[i], sampleSize: sizes[i]))
                a += auxSizes[i]
            }
            return jobs
        }
        return []
    }

    static func hexBytes(_ s: String) -> [UInt8]? {
        let chars = Array(s.trimmingCharacters(in: .whitespaces).utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            guard let h = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(h); i += 2
        }
        return out
    }
}
