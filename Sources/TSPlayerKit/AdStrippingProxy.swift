import Foundation
import Network

/// A local HTTP proxy that fetches a remote HLS stream, strips ad segments,
/// and serves the cleaned playlist to AVPlayer via a loopback HTTP server.
///
/// Segment serving is done via byte-stream proxying by default (safe for AVPlayer).
/// HTTP 302 redirect mode is also available via `segmentMode = .redirect`.
///
/// Usage:
/// ```swift
/// let proxy = try AdStrippingProxy(remoteURL: twitchURL, fetcher: fetcher)
/// let playerItem = AVPlayerItem(asset: AVURLAsset(url: proxy.localURL))
/// // Keep a strong reference to `proxy` for the playback lifetime.
/// ```
public final class AdStrippingProxy: @unchecked Sendable {

    public enum SegmentMode {
        /// Serve segments via HTTP 302 redirect to the real CDN URL.
        case redirect
        /// Fetch and stream segment bytes through the proxy (default).
        case stream
    }

    // MARK: - Public API

    /// The local URL AVPlayer should use: `http://127.0.0.1:{port}/master.m3u8`
    public var localURL: URL {
        URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
    }
    public var segmentMode: SegmentMode = .stream

    /// Creates and starts the proxy server.
    public init(remoteURL: URL, fetcher: RemotePlaylistFetcher) throws {
        self.remoteURL = remoteURL
        self.fetcher = fetcher
        try start()
    }

    deinit { stop() }

    public func stop() { listener?.cancel(); listener = nil }

    // MARK: - Private state

    private let remoteURL: URL
    private let fetcher: RemotePlaylistFetcher
    private var port: UInt16 = 0
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.tsplayerkit.adproxy", qos: .userInitiated)
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let cleaner = HLSPlaylistCleaner()

    private var variantURLs: [URL] = []
    private var segmentRedirects: [String: URL] = [:]
    private let stateLock = NSLock()
    private var isSingleVariant: Bool = false

    /// Tracks the hash of the last *cleaned* playlist served per variant index.
    /// When a poll returns the same content, we append a unique comment so
    /// AVPlayer never sees two identical responses — its "playlist unchanged"
    /// detection fires after 1.5 × TARGETDURATION and aborts with -12888.
    private var lastCleanedPlaylistHash: [Int: Int] = [:]
    private var playlistSeq: [Int: Int] = [:]

    private var isSingleVariantLocked: Bool {
        get { stateLock.withLock { isSingleVariant } }
        set { stateLock.withLock { isSingleVariant = newValue } }
    }

    // MARK: - Server lifecycle

    private func start() throws {
        let params = NWParameters.tcp
        // Enable TCP_NODELAY — our responses are small and latency matters.
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        // Keep connections alive briefly in case AVPlayer sends pipelined requests
        // (it doesn't, but the setting is harmless).
        params.allowFastOpen = true

        let listener: NWListener
        do { listener = try NWListener(using: params) }
        catch { throw error }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port { self.port = p.rawValue }
                self.readySemaphore.signal()
            case .failed(let err):
                print("🛡 AdStrippingProxy: NWListener failed — \(err.localizedDescription)")
                self.readySemaphore.signal()
            case .cancelled:
                print("🛡 AdStrippingProxy: NWListener cancelled")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        listener.start(queue: serverQueue)
        self.listener = listener
        readySemaphore.wait()
    }

    // MARK: - Connection handling

    /// Simple armed/disarmed flag so the receive callback can cancel the idle
    /// watchdog without capturing a non-Sendable `DispatchWorkItem`.
    private final class IdleWatchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true

        func disarm() {
            lock.lock(); armed = false; lock.unlock()
        }

        func isArmed() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return armed
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveRequest(from: connection)
            case .failed(let error):
                // POSIX errors that are expected during normal teardown:
                // 54 = ECONNRESET (client disconnected), 57 = ENOTCONN
                let code = (error as NSError).code
                if code != 54 && code != 57 {
                    print("🛡 AdStrippingProxy: connection failed — \(error.localizedDescription)")
                }
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data = Data()) {
        // AVPlayer occasionally opens a connection without sending anything
        // (reachability probe). Drop it after 10 s instead of letting the stack
        // hold it until its own timeout.
        let watchdog = IdleWatchdog()
        serverQueue.asyncAfter(deadline: .now() + 10) { [weak connection, weak watchdog] in
            guard let watchdog, watchdog.isArmed() else { return }
            connection?.cancel()
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak watchdog] data, _, isComplete, error in
            watchdog?.disarm()
            guard let self else { return }
            if let error {
                // Expected teardown errors: ECONNRESET (54) = client hung up,
                // ENOTCONN (57) = timing race with cancellation.
                let code = (error as NSError).code
                if code != 54 && code != 57 {
                    print("🛡 AdStrippingProxy: receive error — \(error.localizedDescription)")
                }
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.processRequest(headers: buffer, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(from: connection, accumulated: buffer)
            }
        }
    }

    private func processRequest(headers: Data, on connection: NWConnection) {
        guard let raw = String(data: headers, encoding: .utf8),
              let requestLine = raw.components(separatedBy: "\r\n").first,
              let rawPath = requestLine.components(separatedBy: " ").dropFirst().first
        else { sendQuick(400, on: connection); return }

        // Strip query string — AVPlayer appends ?av=1, ?session=..., etc.
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let rangeHeader = extractHeader("Range", from: raw)

        switch path {
        case "/master.m3u8":
            serveMaster(on: connection)
        case let p where p.hasPrefix("/variant/") && p.hasSuffix(".m3u8"):
            serveVariant(path: p, on: connection)
        case let p where p.hasPrefix("/seg/"):
            serveSegment(path: p, rangeHeader: rangeHeader, on: connection)
        case let p where p.hasPrefix("/init/"):
            serveInit(path: p, on: connection)
        case let p where p.hasPrefix("/slate/"):
            serveSlate(path: p, on: connection)
        default:
            sendQuick(404, on: connection)
        }
    }

    // MARK: - Route handlers

    private func serveMaster(on connection: NWConnection) {
        Task {
            do {
                let (text, finalURL) = try await fetcher.fetchPlaylist(url: remoteURL)

                // Detect if this is already a variant playlist (no #EXT-X-STREAM-INF)
                if !text.contains("#EXT-X-STREAM-INF:") {
                    isSingleVariantLocked = true
                    stateLock.withLock { variantURLs = [finalURL] }
                    let fakeMaster = """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=10000000
                    http://127.0.0.1:\(port)/variant/0.m3u8
                    """
                    serveManifest(text: fakeMaster, on: connection)
                    return
                }

                // Master playlist — rewrite variant URLs (streams + renditions).
                // The cleaner returns the original URLs in document order; index i
                // is served back at /variant/<i>.m3u8. Resolve relative URLs against
                // the final (post-redirect) URL, not the request URL.
                let base = "http://127.0.0.1:\(port)"
                let (rewritten, rawVariants) = cleaner.rewriteMasterPlaylist(text, proxyBaseURL: base)
                let resolved = rawVariants.compactMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
                stateLock.withLock { variantURLs = resolved }
                serveManifest(text: rewritten, on: connection)
            } catch {
                sendQuick(502, on: connection)
            }
        }
    }

    private func serveVariant(path: String, on connection: NWConnection) {
        guard let idxStr = path.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".m3u8", with: ""),
              let idx = Int(idxStr) else {
            sendQuick(404, on: connection)
            return
        }

        Task {
            do {
                let variantURL: URL
                if isSingleVariantLocked {
                    variantURL = remoteURL
                } else {
                    let urls = stateLock.withLock { variantURLs }
                    guard idx < urls.count else { sendQuick(404, on: connection); return }
                    variantURL = urls[idx]
                }

                let (text, variantFinalURL) = try await fetcher.fetchPlaylist(url: variantURL)
                let result = cleaner.cleanVariantPlaylist(
                    text,
                    proxyBaseURL: "http://127.0.0.1:\(port)",
                    segmentPathPrefix: "/seg/\(idx)",
                    initPathPrefix: "/init/\(idx)",
                    // Live ad breaks are filled with the local slate placeholder so
                    // the playlist never stalls (CoreMedia -12888). `nil` → removal.
                    slatePathPrefix: SlateSegment.isAvailable ? "/slate" : nil
                )

                cacheRedirectMappings(from: text, variantBaseURL: variantFinalURL, variantIdx: idx)
                if result.adSegmentCount > 0 {
                    let how = result.replacedIndices.isEmpty ? "stripped" : "replaced with slate"
                    print("🛡 AdStrippingProxy: \(how) \(result.adSegmentCount) ad segment(s) on variant \(idx)")
                }

                // Prevent AVPlayer -12888: if the cleaned playlist is byte-identical
                // to the last one we served for this variant, append a unique comment
                // so AVPlayer never sees "playlist unchanged for 1.5 × target duration".
                var finalPlaylist = result.playlist
                let playlistHash = finalPlaylist.hashValue
                let needsSeq = stateLock.withLock { () -> Int? in
                    if lastCleanedPlaylistHash[idx] == playlistHash {
                        let next = (playlistSeq[idx] ?? 0) + 1
                        playlistSeq[idx] = next
                        return next
                    }
                    lastCleanedPlaylistHash[idx] = playlistHash
                    return nil
                }
                if let seq = needsSeq {
                    // Plain comment line (starts with `#` but not `#EXT`): tags
                    // we invent would be invalid HLS. Comments change the bytes
                    // AVPlayer receives so it never sees "unchanged" content.
                    finalPlaylist += "\n#proxy-seq=\(seq)"
                }
                serveManifest(text: finalPlaylist, on: connection)
            } catch {
                sendQuick(502, on: connection)
            }
        }
    }

    private func serveSegment(path: String, rangeHeader: String?, on connection: NWConnection) {
        let (redirectURL, mode) = stateLock.withLock { (segmentRedirects[path], segmentMode) }

        guard let realURL = redirectURL else {
            sendQuick(404, on: connection)
            return
        }

        switch mode {
        case .redirect:
            sendRedirect(to: realURL, on: connection)
        case .stream:
            streamSegment(from: realURL, rangeHeader: rangeHeader, on: connection)
        }
    }

    private func serveInit(path: String, on connection: NWConnection) {
        let (redirectURL, mode) = stateLock.withLock { (segmentRedirects[path], segmentMode) }

        guard let realURL = redirectURL else {
            sendQuick(404, on: connection)
            return
        }

        switch mode {
        case .redirect:
            sendRedirect(to: realURL, on: connection)
        case .stream:
            streamSegment(from: realURL, rangeHeader: nil, on: connection)
        }
    }

    /// Serves the embedded slate placeholder segment. The path is the
    /// occurrence's GLOBAL segment index (`/slate/{index}.ts`) — stable across
    /// reloads (AVPlayer stalls if a live segment's URL changes between polls)
    /// and the basis for the PTS shift: each copy is shifted by `index ×
    /// duration` ticks so its timestamps land on the content timeline (Twitch
    /// content PTS ≈ uptime + the same ~1.4 s encoder base the slate carries).
    /// Unshifted, the copy's near-zero PTS sits BEHIND the playhead and
    /// AVPlayer refuses to schedule it (CoreMedia -12312).
    private func serveSlate(path: String, on connection: NWConnection) {
        guard let base = SlateSegment.data else {
            sendQuick(404, on: connection)
            return
        }
        let body: Data
        if let index = slateIndex(from: path), let rewritten = slateCopy(at: index) {
            body = rewritten
        } else {
            body = base
        }
        send(status: 200, body: body, extraHeaders: [
            "Content-Type": "video/mp2t",
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-cache",
        ], on: connection)
    }

    /// Parses the global segment index from `/slate/{index}.ts`.
    private func slateIndex(from path: String) -> Int? {
        let component = path.components(separatedBy: "/").last ?? ""
        let noExt = component.hasSuffix(".ts") ? String(component.dropLast(3)) : component
        return Int(noExt)
    }

    /// Rewritten slate copies, keyed by global index — the same occurrence is
    /// requested repeatedly while it stays in the window.
    private var slateCopies: [Int: Data] = [:]
    private let slateLock = NSLock()

    private func slateCopy(at index: Int) -> Data? {
        slateLock.lock()
        defer { slateLock.unlock() }
        if let cached = slateCopies[index] { return cached }
        guard let base = SlateSegment.data else { return nil }
        let delta = Int64(index) * Int64(SlateSegment.duration * Double(SlateRewriter.ticksPerSecond))
        guard let rewritten = SlateRewriter.rewrite(base, adding: delta) else { return nil }
        // Keep the cache bounded: a couple of breaks' worth is plenty.
        if slateCopies.count > 128 { slateCopies.removeAll() }
        slateCopies[index] = rewritten
        return rewritten
    }

    // MARK: - Redirect mapping

    /// Maps proxy paths to real CDN URLs. Content keys are
    /// `/seg/{variant}/{filename}` — the variant index keeps qualities apart
    /// (same segment filenames across variants), and the filename keeps URLs
    /// stable across reloads (AVPlayer identifies segments by URL). Init keys
    /// keep a positional index: the same init file can legitimately recur in
    /// one playlist (fMP4 re-init), and init segments are never the stall
    /// vector — they are tiny and re-fetching is harmless.
    private func cacheRedirectMappings(from originalPlaylist: String, variantBaseURL: URL, variantIdx: Int) {
        let lines = originalPlaylist.components(separatedBy: .newlines)
        var mapIdx = 0

        stateLock.withLock {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#EXT-X-MAP:URI=\"") {
                    if let uri = extractURI(from: trimmed),
                       let resolved = URL(string: uri, relativeTo: variantBaseURL)?.absoluteURL {
                        let filename = HLSPlaylistCleaner.segmentFilename(uri)
                        segmentRedirects["/init/\(variantIdx)/\(mapIdx)/\(filename)"] = resolved
                        mapIdx += 1
                    }
                    continue
                }
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                if let resolved = URL(string: trimmed, relativeTo: variantBaseURL)?.absoluteURL {
                    segmentRedirects["/seg/\(variantIdx)/\(resolved.lastPathComponent)"] = resolved
                }
            }
        }
    }

    private func extractURI(from line: String) -> String? {
        guard let start = line.range(of: "URI=\"")?.upperBound,
              let end = line[start...].range(of: "\"")?.lowerBound else { return nil }
        return String(line[start..<end])
    }

    // MARK: - Response helpers

    private func serveManifest(text: String, on connection: NWConnection) {
        guard let data = text.data(using: .utf8) else { sendQuick(500, on: connection); return }
        send(status: 200, body: data, extraHeaders: [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
        ], on: connection)
    }

    private func sendRedirect(to url: URL, on connection: NWConnection) {
        let s = "HTTP/1.1 302 Found\r\nLocation: \(url.absoluteString)\r\nConnection: close\r\n\r\n"
        guard let data = s.data(using: .utf8) else { connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func streamSegment(from url: URL, rangeHeader: String?, on connection: NWConnection) {
        // Closed ranges (bytes=A-B) are forwarded as-is. Open-ended ranges
        // (bytes=A-) also pass through verbatim — an NSRange cannot express
        // them without overflowing (`Int.max + 1`). Suffix ranges (bytes=-N)
        // and malformed specs are rejected.
        let isClosedRange: Bool
        if let rh = rangeHeader, rh.lowercased().hasPrefix("bytes=") {
            let spec = String(rh.dropFirst(6))
            let bounds = spec.components(separatedBy: "-")
            isClosedRange = bounds.count == 2 && !(bounds.first?.isEmpty ?? true) && !(bounds.last?.isEmpty ?? true)
        } else {
            isClosedRange = false
        }

        Task {
            do {
                let (data, contentType) = try await fetcher.fetchSegment(url: url, rangeHeader: rangeHeader)
                send(status: isClosedRange ? 206 : 200, body: data, extraHeaders: [
                    "Content-Type": contentType ?? "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                ], on: connection)
            } catch {
                print("🛡 AdStrippingProxy: segment fetch failed — \(error.localizedDescription)")
                sendQuick(502, on: connection)
            }
        }
    }

    private func send(status: Int, body: Data, extraHeaders: [String: String], on connection: NWConnection) {
        var s = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in extraHeaders { s += "\(k): \(v)\r\n" }
        s += "Connection: close\r\n\r\n"
        var data = Data(s.utf8); data.append(body)
        let conn = connection
        connection.send(content: data, completion: .contentProcessed { _ in
            // Small delay before cancel so AVPlayer has time to finish reading
            // the response — avoids ECONNRESET races on loopback.
            conn.cancel()
        })
    }

    private func sendQuick(_ status: Int, on connection: NWConnection) {
        send(status: status, body: Data(), extraHeaders: [:], on: connection)
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 206: "Partial Content"; case 302: "Found"
        case 400: "Bad Request"; case 404: "Not Found"
        case 500: "Internal Server Error"; case 502: "Bad Gateway"
        default: "Unknown"
        }
    }

    private func extractHeader(_ name: String, from raw: String) -> String? {
        let key = name.lowercased() + ":"
        for line in raw.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(key) {
                return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
