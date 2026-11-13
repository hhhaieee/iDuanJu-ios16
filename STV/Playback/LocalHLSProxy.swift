import Foundation
import Network

/// Tiny loopback HTTP server (127.0.0.1, random port) for SupJav-style HLS:
/// - playlists are fetched with the embed's Referer/Origin and every URI is rewritten back to us;
/// - TS segments disguised as images (fake PNG/JPEG header in front of the MPEG-TS) get the header stripped;
/// - keys / init maps pass through unchanged.
/// Port of UAV-Downloader `sites/supjav.py::_strip_fake_header` + its HLS fetch path (Apache-2.0).
/// Only listens on loopback; nothing is reachable from the LAN.
///
/// Also the byte-budget pre-buffer for long-video sources: segments (`s.ts`) and MP4 ranges (`v.mp4`) are
/// served from `PrefetchStore` first; a per-token `Prefetcher` fills it ahead of the playhead.
final class LocalHLSProxy: @unchecked Sendable {
    struct Route {
        var headers: [String: String]
        /// SupJav disguises TS as images; other sites must not be touched (fMP4 etc.).
        var strip: Bool
        var prefetcher: Prefetcher?
        /// MP4: total length once known.
        var length: Int?
        /// TDLib video streamed while it downloads (`/tg/<file id>`).
        var td: TDStreamSession?
        /// 红果 CENC MP4: content key, and the per-range decryptor once the header is read (`prepareCENC`).
        var cencKey: String?
        var cenc: CENCDecryptor.RangePlan?
        /// MP4 chunk size (CENC uses small chunks so the header and first frames arrive fast on slow links).
        var chunk = BufferSettings.mp4Chunk
    }
    static let shared = LocalHLSProxy()

    private let queue = DispatchQueue(label: "stv.hlsproxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// token → route (one token per resolved stream).
    private var routes: [String: Route] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = .shared
        return URLSession(configuration: c)
    }()

    /// Proxy URL for an upstream m3u8 (nil if the listener can't start).
    func playlistURL(_ upstream: String, headers: [String: String], strip: Bool = true, budget: Int = 0) -> String? {
        register(upstream, headers: headers, strip: strip, budget: budget, kind: "p.m3u8")
    }

    /// Proxy URL for a progressive MP4 (Range requests served chunk-wise from the prefetch cache).
    func mp4URL(_ upstream: String, headers: [String: String], budget: Int) -> String? {
        register(upstream, headers: headers, strip: false, budget: budget, kind: "v.mp4")
    }

    /// Proxy URL for an encrypted (CENC AES-CTR) progressive MP4, decrypted range by range as it is served,
    /// so playback starts without downloading the whole file. Call `prepareCENC` before handing it out.
    func cencMP4URL(_ upstream: String, headers: [String: String], key: String, budget: Int) -> String? {
        guard let u = register(upstream, headers: headers, strip: false, budget: budget, kind: "v.mp4"),
              let token = Self.token(of: u) else { return nil }
        lock.lock(); routes[token]?.cencKey = key; routes[token]?.chunk = 262_144; lock.unlock()
        return u
    }

    /// Reads the CENC header (`moov`) of a `cencMP4URL` and builds its decryptor. Throws when the file
    /// can't be streamed (moov after mdat, fragmented) — the caller then falls back to a full download.
    func prepareCENC(_ proxied: String) async throws {
        guard let token = Self.token(of: proxied), let rt = route(token), let key = rt.cencKey,
              let q = URL(string: proxied)?.query, q.hasPrefix("u="), let up = Self.unb64(String(q.dropFirst(2))),
              let url = URL(string: up) else { throw URLError(.badURL) }
        if rt.cenc != nil { return }
        let total = try await mp4Length(token, url, rt)
        let chunk = rt.chunk
        var header: [UInt8] = []
        for i in 0..<((total + chunk - 1) / chunk) {
            header += try await mp4Chunk(token, url, rt, i, total)
            switch CENCDecryptor.moovLocation(header) {
            case .more: continue
            case .tail: throw CENCDecryptor.Failure.malformed("moov 在 mdat 之后")
            case .end(let end):
                guard end <= header.count else { continue }
                guard let plan = try CENCDecryptor.rangePlan(header: Array(header.prefix(end)), keyHex: key) else {
                    throw CENCDecryptor.Failure.malformed("无法流式解密")
                }
                lock.lock(); routes[token]?.cenc = plan; lock.unlock()
                return
            }
        }
        throw CENCDecryptor.Failure.malformed("缺少 moov")
    }

    /// Proxy URL for a TDLib video: `http://127.0.0.1:<port>/tg/<file id>`, served to AVPlayer as a plain
    /// progressive file. Range requests download only the requested window through TDLib (any offset, so
    /// `moov` at the end works); `budget` bytes are read ahead.
    func tdURL(_ ref: TDFileRef, budget: Int, source: TDFileStreamSource, chunk: Int = 1_048_576) -> String? {
        guard let port = start() else { return nil }
        let session = TDStreamSession(ref: ref, source: source, chunk: chunk, readAhead: budget > 0 ? budget : 16 * 1_048_576)
        lock.lock()
        let old = routes["tg-\(ref.id)"]?.td
        routes["tg-\(ref.id)"] = Route(headers: [:], strip: false, prefetcher: nil, td: session)
        lock.unlock()
        if let old { Task { await old.cancel() } }
        // `.mp4` extension: AVFoundation picks the container from the URL/Content-Type; extensionless URLs
        // are a classic "Cannot Open" (-11829) on device.
        return "http://127.0.0.1:\(port)/tg/\(ref.id).mp4"
    }

    #if DEBUG
    /// Fault injection for reproducing on-device failures in the simulator (`STV_PROXY_FAULT=probe|chunk`).
    static var fault: String? = ProcessInfo.processInfo.environment["STV_PROXY_FAULT"]
    #endif

    func tdSession(_ token: String) -> TDStreamSession? { route(token)?.td }

    private func register(_ upstream: String, headers: [String: String], strip: Bool, budget: Int, kind: String) -> String? {
        guard let port = start() else { return nil }
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let pf = budget > 0 ? makePrefetcher(token, budget, headers, strip) : nil
        lock.lock()
        if routes.count > 64 { routes.values.forEach { $0.prefetcher?.stop() }; routes = [:] }
        routes[token] = Route(headers: headers, strip: strip, prefetcher: pf)
        lock.unlock()
        return "http://127.0.0.1:\(port)/\(token)/\(kind)?u=\(Self.b64(upstream))"
    }

    private func makePrefetcher(_ token: String, _ budget: Int, _ headers: [String: String], _ strip: Bool) -> Prefetcher {
        let session = self.session
        return Prefetcher(token: token, budget: budget, headers: headers) { unit, headers in
            var r = URLRequest(url: unit.url)
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            if r.value(forHTTPHeaderField: "User-Agent") == nil { r.setValue(SiteHTTP.userAgent, forHTTPHeaderField: "User-Agent") }
            if let rg = unit.range { r.setValue("bytes=\(rg.lowerBound)-\(rg.upperBound)", forHTTPHeaderField: "Range") }
            let (d, resp) = try await session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            if let rg = unit.range, status == 200, d.count > rg.count { // server ignored Range
                return d.subdata(in: rg.lowerBound..<min(d.count, rg.upperBound + 1))
            }
            return strip ? Self.stripFakeHeader(d) : d
        }
    }

    /// Token of a proxy URL we issued (nil for anything else).
    static func token(of url: String) -> String? {
        guard let u = URL(string: url), u.host == "127.0.0.1" else { return nil }
        let segs = u.path.split(separator: "/")
        guard segs.count == 2 else { return nil }
        return segs[0] == "tg" ? "tg-\(tdFileId(segs[1]))" : String(segs[0])
    }

    /// `/tg/<id>` or `/tg/<id>.mp4` → `<id>`.
    static func tdFileId<S: StringProtocol>(_ seg: S) -> String {
        let s = String(seg)
        return s.hasSuffix(".mp4") ? String(s.dropLast(4)) : s
    }

    /// Turn on byte pre-buffering for an already issued token (SupJav resolves through the proxy itself).
    func enablePrefetch(_ token: String, budget: Int) {
        lock.lock(); defer { lock.unlock() }
        guard budget > 0, var r = routes[token], r.prefetcher == nil else { return }
        r.prefetcher = makePrefetcher(token, budget, r.headers, r.strip)
        routes[token] = r
    }

    func setPosition(_ token: String, _ seconds: Double) { route(token)?.prefetcher?.setPosition(seconds) }

    func status(_ token: String) -> (bytes: Int, until: Double, total: Int, lowStorage: Bool)? {
        guard let p = route(token)?.prefetcher else { return nil }
        let s = p.status()
        return (s.bytes, s.until, s.total, p.lowStorage)
    }

    /// MP4 chunk count (0 until the length is known).
    func mp4Chunks(_ token: String) -> Int {
        guard let r = route(token), let n = r.length else { return 0 }
        return (n + r.chunk - 1) / r.chunk
    }

    /// Leaving the player: stop downloads and drop this stream's cache.
    func release(_ token: String) {
        lock.lock(); let r = routes.removeValue(forKey: token); lock.unlock()
        r?.prefetcher?.stop()
        if r?.prefetcher != nil { PrefetchStore.shared.remove(token) }
        if let td = r?.td { Task { await td.cancel() } }
    }

    private func start() -> UInt16? {
        lock.lock()
        if port != 0 { defer { lock.unlock() }; return port }
        lock.unlock()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled:
                ready.signal()
                // iOS tears the socket down after long backgrounding; next playlistURL() restarts it.
                self?.lock.lock(); if self?.listener === l { self?.listener = nil; self?.port = 0 }; self?.lock.unlock()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let p = l.port?.rawValue, p != 0 else { l.cancel(); return nil }
        lock.lock(); listener = l; port = p; lock.unlock()
        return p
    }

    // MARK: Connection

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = acc
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                Task { await self.handle(c, head) }
            } else if done || err != nil || buf.count > 65_536 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func handle(_ c: NWConnection, _ head: String) async {
        let lines = head.split(separator: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return reply(c, 405, "text/plain", Data()) }
        let target = String(parts[1])
        #if DEBUG
        NSLog("%@", "[STV] proxy \(parts[0]) \(target.prefix(40)) range=\(rangeHeader ?? "-")")
        #endif
        let comps = target.split(separator: "?", maxSplits: 1).map(String.init)
        let segs = comps[0].split(separator: "/").map(String.init)
        if segs.count == 2, segs[0] == "tg" {
            guard let td = route("tg-\(Self.tdFileId(segs[1]))")?.td else { return reply(c, 404, "text/plain", Data()) }
            return await serveTD(c, td, range: rangeHeader, head: parts[0] == "HEAD")
        }
        guard segs.count == 2, comps.count == 2, comps[1].hasPrefix("u="),
              let upstream = Self.unb64(String(comps[1].dropFirst(2))), let url = URL(string: upstream),
              url.scheme == "https" || url.scheme == "http" else { return reply(c, 404, "text/plain", Data()) }
        guard let rt = route(segs[0]) else { return reply(c, 404, "text/plain", Data()) }
        let headers = rt.headers
        if segs[1] == "v.mp4" { return await serveMP4(c, token: segs[0], url: url, route: rt, range: rangeHeader, head: parts[0] == "HEAD") }
        if segs[1] == "s.ts", let pf = rt.prefetcher {
            let unit = PrefetchUnit(key: PrefetchStore.key(upstream), url: url, range: nil, start: 0, duration: 0)
            do { return reply(c, 200, "video/mp2t", try await pf.data(for: unit.key, fallback: unit)) }
            catch { return reply(c, 502, "text/plain", Data(error.localizedDescription.utf8)) }
        }
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "User-Agent") == nil { r.setValue(SiteHTTP.userAgent, forHTTPHeaderField: "User-Agent") }
        do {
            let (d, resp) = try await session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return reply(c, 502, "text/plain", Data("upstream \(status)".utf8)) }
            let final = resp.url ?? url
            switch segs[1] {
            case "p.m3u8":
                let original = HLSAdFilter.apply(String(decoding: d, as: UTF8.self), base: final)
                if let pf = rt.prefetcher, let units = HLSMedia.parse(original, base: final), units.allSatisfy({ $0.range == nil }) {
                    pf.setUnits(units)   // the variant AVPlayer actually chose
                }
                let text = rewrite(original, base: final, token: segs[0])
                reply(c, 200, "application/vnd.apple.mpegurl", Data(text.utf8))
            case "s.ts":
                reply(c, 200, "video/mp2t", rt.strip ? Self.stripFakeHeader(d) : d)
            default:
                reply(c, 200, (resp as? HTTPURLResponse)?.mimeType ?? "application/octet-stream", d)
            }
        } catch {
            reply(c, 502, "text/plain", Data(error.localizedDescription.utf8))
        }
    }

    private func route(_ token: String) -> Route? {
        lock.lock(); defer { lock.unlock() }
        return routes[token]
    }

    // MARK: MP4 (Range → fixed chunks through the prefetch cache)

    static func parseRange(_ h: String?, length: Int) -> ClosedRange<Int>? {
        guard let h, h.lowercased().hasPrefix("bytes="), length > 0 else { return nil }
        let spec = h.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let p = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return nil }
        if p[0].isEmpty, let n = Int(p[1]) { return max(0, length - n)...(length - 1) }   // suffix
        guard let a = Int(p[0]), a < length else { return nil }
        let b = Int(p[1]).map { min($0, length - 1) } ?? (length - 1)
        return b >= a ? a...b : nil
    }

    static func chunks(covering r: ClosedRange<Int>, chunk: Int) -> ClosedRange<Int> { (r.lowerBound / chunk)...(r.upperBound / chunk) }

    private func mp4Length(_ token: String, _ url: URL, _ rt: Route) async throws -> Int {
        if let n = rt.length { return n }
        #if DEBUG
        if Self.fault == "probe" { throw URLError(.cannotConnectToHost) }
        #endif
        var r = URLRequest(url: url)
        for (k, v) in rt.headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "User-Agent") == nil { r.setValue(SiteHTTP.userAgent, forHTTPHeaderField: "User-Agent") }
        r.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        // One retry: a single dropped probe would otherwise fail the whole item (-1008 "resource unavailable").
        var probe: (Data, URLResponse)?
        for attempt in 0..<2 where probe == nil {
            do { probe = try await session.data(for: r) }
            catch { if attempt == 1 { throw error }; try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        guard let h = probe?.1 as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw URLError(.badServerResponse) }
        let total = (h.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
            ?? (h.statusCode == 200 ? Int(h.expectedContentLength) : nil)
        guard let total, total > 0 else { throw URLError(.cannotParseResponse) }
        lock.lock(); routes[token]?.length = total; lock.unlock()
        if let pf = rt.prefetcher {
            let chunk = rt.chunk
            let n = (total + chunk - 1) / chunk
            pf.setUnits((0..<n).map { i in
                let lo = i * chunk, hi = min(total, lo + chunk) - 1
                return PrefetchUnit(key: PrefetchStore.key(url.absoluteString + "#c\(i)"), url: url, range: lo...hi, start: Double(i), duration: 1)
            })
        }
        return total
    }

    private func serveMP4(_ c: NWConnection, token: String, url: URL, route rt: Route, range: String?, head: Bool) async {
        let total: Int
        do { total = try await mp4Length(token, url, rt) }
        catch { return reply(c, 502, "text/plain", Data(error.localizedDescription.utf8)) }
        let partial = range != nil
        guard let want = partial ? Self.parseRange(range, length: total) : 0...(total - 1) else {
            let out = Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            return c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
        let chunk = rt.chunk
        let indices = Array(Self.chunks(covering: want, chunk: chunk))
        // Fetch the first chunk BEFORE committing a 206: an upstream failure becomes a clean 502 instead of
        // a 206 header followed by an error body / truncated body (AVPlayer: "Cannot Open" -11829/-11850).
        var first: Data?
        if !head {
            do { first = try await mp4Chunk(token, url, rt, indices[0], total) }
            catch { return reply(c, 502, "text/plain", Data(error.localizedDescription.utf8)) }
        }
        var out = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
        out += "Content-Length: \(want.count)\r\n"
        if partial { out += "Content-Range: bytes \(want.lowerBound)-\(want.upperBound)/\(total)\r\n" }
        out += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard await send(c, Data(out.utf8)), !head else { return c.cancel() }
        for i in indices {
            let lo = i * chunk, hi = min(total, lo + chunk) - 1
            var data: Data
            if i == indices[0], let first { data = first }
            else {
                // Headers are out: on failure just close — AVPlayer re-requests the missing range.
                guard let d = try? await mp4Chunk(token, url, rt, i, total) else { break }
                data = d
            }
            // CENC: the pre-buffer keeps ciphertext; decrypt each chunk on its way out.
            if let plan = route(token)?.cenc { guard (try? plan.apply(&data, at: lo)) != nil else { break } }
            let a = max(want.lowerBound, lo) - lo, b = min(want.upperBound, hi) - lo
            guard a <= b, b < data.count else { break }
            if !(await send(c, data.subdata(in: a..<(b + 1)))) { break }   // player hung up (seek)
        }
        c.cancel()
    }

    /// One MP4 chunk: pre-buffer first, then up to two direct upstream retries (a single flaky CDN request
    /// or a prefetch unit marked failed must not kill playback).
    private func mp4Chunk(_ token: String, _ url: URL, _ rt: Route, _ i: Int, _ total: Int) async throws -> Data {
        let chunk = rt.chunk
        let lo = i * chunk, hi = min(total, lo + chunk) - 1
        #if DEBUG
        if Self.fault == "chunk", i >= 1 { throw URLError(.networkConnectionLost) }
        #endif
        let key = PrefetchStore.key(url.absoluteString + "#c\(i)")
        let unit = PrefetchUnit(key: key, url: url, range: lo...hi, start: Double(i), duration: 1)
        var last: Error = URLError(.unknown)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                if attempt == 0, let pf = route(token)?.prefetcher { return try await pf.data(for: key, fallback: unit) }
                return try await fetchRange(url, lo...hi, rt.headers)
            } catch {
                last = error
                if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000) }
            }
        }
        throw last
    }

    // MARK: TDLib (Range → TDLib download window → readFilePart)

    private func serveTD(_ c: NWConnection, _ td: TDStreamSession, range: String?, head: Bool) async {
        let total: Int
        do { total = try await td.totalLength() } catch { return reply(c, 502, "text/plain", Data(error.localizedDescription.utf8)) }
        guard let want = range == nil ? 0...(total - 1) : Self.parseRange(range, length: total) else {
            var out = Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            return c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
        let partial = range != nil
        var out = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(td.mime)\r\nAccept-Ranges: bytes\r\n"
        out += "Content-Length: \(want.count)\r\n"
        if partial { out += "Content-Range: bytes \(want.lowerBound)-\(want.upperBound)/\(total)\r\n" }
        out += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard await send(c, Data(out.utf8)), !head else { return c.cancel() }
        // AVPlayer hangs up on seek: stop waiting for the old offset so the download moves to the new one.
        let body = Task {
            var pos = want.lowerBound
            while pos <= want.upperBound, !Task.isCancelled {
                let n = min(td.chunk - pos % td.chunk, want.upperBound - pos + 1)   // chunk-aligned pieces
                let d = try await td.read(pos, n)
                guard !d.isEmpty, await self.send(c, d) else { break }
                pos += d.count
            }
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, done, err in
            if done || err != nil { body.cancel() }
        }
        _ = await body.result
        c.cancel()
    }

    private func fetchRange(_ url: URL, _ rg: ClosedRange<Int>, _ headers: [String: String]) async throws -> Data {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "User-Agent") == nil { r.setValue(SiteHTTP.userAgent, forHTTPHeaderField: "User-Agent") }
        r.setValue("bytes=\(rg.lowerBound)-\(rg.upperBound)", forHTTPHeaderField: "Range")
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw URLError(.badServerResponse) }
        return h.statusCode == 200 && d.count > rg.count ? d.subdata(in: rg.lowerBound..<min(d.count, rg.upperBound + 1)) : d
    }

    private func send(_ c: NWConnection, _ d: Data) async -> Bool {
        await withCheckedContinuation { cont in
            c.send(content: d, completion: .contentProcessed { err in cont.resume(returning: err == nil) })
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 502: "Bad Gateway"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Playlist rewrite

    private func rewrite(_ pl: String, base: URL, token: String) -> String {
        func local(_ raw: String, _ kind: String) -> String {
            guard let u = URL(string: raw, relativeTo: base)?.absoluteURL else { return raw }
            return "http://127.0.0.1:\(port)/\(token)/\(kind)?u=\(Self.b64(u.absoluteString))"
        }
        var expectPlaylist = false
        return pl.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let up = line.uppercased()
            if up.hasPrefix("#EXT-X-STREAM-INF") { expectPlaylist = true; return line }
            if up.hasPrefix("#EXT-X-KEY") || up.hasPrefix("#EXT-X-MAP") || up.hasPrefix("#EXT-X-MEDIA") || up.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                guard let m = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", line) else { return line }
                let kind = up.hasPrefix("#EXT-X-MEDIA") || up.hasPrefix("#EXT-X-I-FRAME") ? "p.m3u8" : "r"
                return line.replacingOccurrences(of: m[1], with: local(m[1], kind))
            }
            if line.isEmpty || line.hasPrefix("#") { return line }
            defer { expectPlaylist = false }
            let isPlaylist = expectPlaylist || line.lowercased().contains(".m3u8")
            return local(line, isPlaylist ? "p.m3u8" : "s.ts")
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Drop junk in front of the first MPEG-TS sync byte that repeats on a 188-byte stride 5×.
    /// Plain TS (already starting with 0x47) is returned unchanged.
    static func stripFakeHeader(_ data: Data) -> Data {
        let d = [UInt8](data)
        guard d.count > 188 * 5, d[0] != 0x47 else { return data }
        let limit = min(d.count - 188 * 4 - 1, 8000)
        guard limit > 0 else { return data }
        for i in 0..<limit where d[i] == 0x47 {
            if (1..<5).allSatisfy({ d[i + 188 * $0] == 0x47 }) { return Data(d[i...]) }
        }
        return data
    }

    static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { String(decoding: $0, as: UTF8.self) }
    }
}
