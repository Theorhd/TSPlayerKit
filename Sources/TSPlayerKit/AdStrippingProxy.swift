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
        // Loopback host and a valid UInt16 port always form a valid URL.
        URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
    }
    /// How segments are served. Read/written under `stateLock`.
    public var segmentMode: SegmentMode {
        get { stateLock.withLock { _segmentMode } }
        set { stateLock.withLock { _segmentMode = newValue } }
    }

    /// Creates and starts the proxy server.
    public init(remoteURL: URL, fetcher: RemotePlaylistFetcher) throws {
        self.remoteURL = remoteURL
        self.fetcher = fetcher
        try start()
    }

    deinit { stop() }

    public func stop() {
        listener?.cancel()
        listener = nil
        // NWListener.cancel() does NOT cancel already-accepted connections:
        // close them all, and cancel the CDN downloads still feeding them.
        let (connections, streams) = stateLock.withLock { () -> ([NWConnection], [RemotePlaylistFetcher.SegmentStreamHandle]) in
            let c = Array(activeConnections.values), s = Array(activeStreams.values)
            activeConnections.removeAll()
            activeStreams.removeAll()
            return (c, s)
        }
        for connection in connections { connection.cancel() }
        for stream in streams { stream.cancel() }
    }

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
    private var _segmentMode: SegmentMode = .stream

    /// Accepted connections and their in-flight segment downloads — tracked so
    /// `stop()` can actually close them (NWListener.cancel() does not) and so a
    /// dead client connection cancels the CDN download feeding it.
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeStreams: [ObjectIdentifier: RemotePlaylistFetcher.SegmentStreamHandle] = [:]

    /// Tracks the hash of the last *cleaned* playlist served per variant index.
    /// When a poll returns the same content, we append a unique comment so
    /// AVPlayer never sees two identical responses — its "playlist unchanged"
    /// detection fires after 1.5 × TARGETDURATION and aborts with -12888.
    private var lastCleanedPlaylistHash: [Int: Int] = [:]
    private var playlistSeq: [Int: Int] = [:]

    /// Bandwidth hint for the synthetic master playlist of single-variant streams.
    private static let syntheticMasterBandwidth = 10_000_000

    /// Upper bound of the rewritten-slate cache: a couple of breaks' worth.
    private static let slateCacheLimit = 128

    private var isSingleVariantLocked: Bool {
        get { stateLock.withLock { isSingleVariant } }
        set { stateLock.withLock { isSingleVariant = newValue } }
    }

    // MARK: - Server lifecycle

    private func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        // Keep connections alive briefly in case AVPlayer sends pipelined requests
        // (it doesn't, but the setting is harmless).
        params.allowFastOpen = true

        let listener = try NWListener(using: params)

        let failure = HTTPServerCommon.FailureBox()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port { self.port = p.rawValue }
                self.readySemaphore.signal()
            case .failed(let err):
                print("🛡 AdStrippingProxy: NWListener failed — \(err.localizedDescription)")
                failure.set(err)
                self.readySemaphore.signal()
            case .cancelled:
                break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        listener.start(queue: serverQueue)
        self.listener = listener
        readySemaphore.wait()
        if let error = failure.get() {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        stateLock.withLock { _ = activeConnections[ObjectIdentifier(connection)] = connection }
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
                self.teardownConnection(connection)
            case .cancelled:
                self.teardownConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
    }

    /// A connection is done (failed or cancelled): forget it and cancel the
    /// segment download still feeding it, if any, so CDN bandwidth is not
    /// wasted on a client that went away.
    private func teardownConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let stream = stateLock.withLock { () -> RemotePlaylistFetcher.SegmentStreamHandle? in
            activeConnections.removeValue(forKey: key)
            return activeStreams.removeValue(forKey: key)
        }
        stream?.cancel()
        connection.cancel()
    }

    private func receiveRequest(from connection: NWConnection) {
        HTTPServerCommon.receiveRequest(
            on: connection,
            queue: serverQueue,
            idleTimeout: HTTPServerCommon.idleConnectionTimeout,
            maxHeadSize: HTTPServerCommon.maxRequestHeadSize,
            onHead: { [weak self] head in self?.processRequest(headers: head, on: connection) },
            onOversize: { HTTPServerCommon.sendQuick(431, on: connection) },
            onError: { error in
                // Expected teardown errors: ECONNRESET (54) = client hung up,
                // ENOTCONN (57) = timing race with cancellation.
                let code = (error as NSError).code
                if code != 54 && code != 57 {
                    print("🛡 AdStrippingProxy: receive error — \(error.localizedDescription)")
                }
            }
        )
    }

    private func processRequest(headers: Data, on connection: NWConnection) {
        guard let head = HTTPServerCommon.parseHead(headers),
              let rawPath = HTTPServerCommon.requestPath(from: head.line)
        else { HTTPServerCommon.sendQuick(400, on: connection); return }

        // Strip query string — AVPlayer appends ?av=1, ?session=..., etc.
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let rangeHeader = HTTPServerCommon.headerValue("Range", in: head.raw)

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
            HTTPServerCommon.sendQuick(404, on: connection)
        }
    }

    // MARK: - Route handlers

    private func serveMaster(on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (text, finalURL) = try await fetcher.fetchPlaylist(url: remoteURL)

                // Detect if this is already a variant playlist (no #EXT-X-STREAM-INF)
                if !text.contains("#EXT-X-STREAM-INF:") {
                    isSingleVariantLocked = true
                    stateLock.withLock { variantURLs = [finalURL] }
                    // Single-variant streams get a synthetic master: AVPlayer
                    // reads the variant through the same /variant/0 path as
                    // multi-quality masters. The bandwidth value only hints at
                    // the top bitrate — any plausible number works.
                    let fakeMaster = """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=\(Self.syntheticMasterBandwidth)
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
                print("🛡 AdStrippingProxy: master playlist fetch failed — \(error.localizedDescription)")
                HTTPServerCommon.sendQuick(502, on: connection)
            }
        }
    }

    private func serveVariant(path: String, on connection: NWConnection) {
        guard let idxStr = path.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".m3u8", with: ""),
              let idx = Int(idxStr) else {
            HTTPServerCommon.sendQuick(404, on: connection)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let variantURL: URL
                if isSingleVariantLocked {
                    // serveMaster stored the post-redirect URL — reuse it
                    // instead of re-following redirects on every poll.
                    variantURL = stateLock.withLock { variantURLs.first } ?? remoteURL
                } else {
                    let urls = stateLock.withLock { variantURLs }
                    guard idx < urls.count else { HTTPServerCommon.sendQuick(404, on: connection); return }
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
                    slatePathPrefix: SlateSegment.isAvailable ? "/slate" : nil,
                    variantBaseURL: variantFinalURL
                )

                storeRedirectMappings(result.redirectMappings, variantIdx: idx)
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
                print("🛡 AdStrippingProxy: variant \(idx) playlist fetch failed — \(error.localizedDescription)")
                HTTPServerCommon.sendQuick(502, on: connection)
            }
        }
    }

    private func serveSegment(path: String, rangeHeader: String?, on connection: NWConnection) {
        let (redirectURL, mode) = stateLock.withLock { (segmentRedirects[path], _segmentMode) }

        guard let realURL = redirectURL else {
            HTTPServerCommon.sendQuick(404, on: connection)
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
        let (redirectURL, mode) = stateLock.withLock { (segmentRedirects[path], _segmentMode) }

        guard let realURL = redirectURL else {
            HTTPServerCommon.sendQuick(404, on: connection)
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
            HTTPServerCommon.sendQuick(404, on: connection)
            return
        }
        let body: Data
        if let index = slateIndex(from: path), let rewritten = slateCopy(at: index) {
            body = rewritten
        } else {
            body = base
        }
        HTTPServerCommon.sendResponse(status: 200, fields: [
            "Content-Type": "video/mp2t",
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-cache",
        ], body: body, on: connection)
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
        // Double-checked: the cache read and the (cheap) PTS rewrite are never
        // both under the lock, so concurrent slate requests don't serialize.
        slateLock.lock()
        let cached = slateCopies[index]
        slateLock.unlock()
        if let cached { return cached }

        guard let base = SlateSegment.data else { return nil }
        let delta = Int64(index) * Int64(SlateSegment.duration * Double(SlateRewriter.ticksPerSecond))
        guard let rewritten = SlateRewriter.rewrite(base, adding: delta) else { return nil }

        slateLock.lock()
        // Keep the cache bounded. If two connections rewrote the same index
        // concurrently, the last one wins.
        if slateCopies.count > Self.slateCacheLimit { slateCopies.removeAll() }
        slateCopies[index] = rewritten
        slateLock.unlock()
        return rewritten
    }

    // MARK: - Redirect mapping

    /// Stores the proxy-path → CDN-URL mappings produced by the cleaner,
    /// replacing the previous window's entries for this variant. Content keys
    /// are `/seg/{variant}/{filename}` — the variant index keeps qualities
    /// apart (same segment filenames across variants), and the filename keeps
    /// URLs stable across reloads (AVPlayer identifies segments by URL). Init
    /// keys keep a positional index: the same init file can legitimately recur
    /// in one playlist (fMP4 re-init).
    ///
    /// Eviction is by sliding window: only the mappings of the latest poll
    /// survive per variant, so the dictionary stays bounded (~a window's worth
    /// of segments per quality) for the whole stream duration.
    private func storeRedirectMappings(_ mappings: [(path: String, url: URL)], variantIdx: Int) {
        let segPrefix = "/seg/\(variantIdx)/"
        let initPrefix = "/init/\(variantIdx)/"
        stateLock.withLock {
            segmentRedirects = segmentRedirects.filter {
                !$0.key.hasPrefix(segPrefix) && !$0.key.hasPrefix(initPrefix)
            }
            for mapping in mappings {
                segmentRedirects[mapping.path] = mapping.url
            }
        }
    }

    // MARK: - Response helpers

    private func serveManifest(text: String, on connection: NWConnection) {
        guard let data = text.data(using: .utf8) else {
            HTTPServerCommon.sendQuick(500, on: connection); return
        }
        HTTPServerCommon.sendResponse(status: 200, fields: [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
        ], body: data, on: connection)
    }

    private func sendRedirect(to url: URL, on connection: NWConnection) {
        HTTPServerCommon.sendResponse(status: 302, fields: ["Location": url.absoluteString],
                                      body: Data(), on: connection)
    }

    private func streamSegment(from url: URL, rangeHeader: String?, on connection: NWConnection) {
        // Syntactically valid ranges (closed, open, suffix) are forwarded
        // verbatim — the CDN handles them natively. Malformed specs are
        // stripped rather than proxied: serving the full body is the safest
        // fallback for AVPlayer.
        let forwardRange: String?
        switch HTTPServerCommon.parseRange(rangeHeader) {
        case .closed, .open, .suffix: forwardRange = rangeHeader
        case .absent, .invalid: forwardRange = nil
        }

        // STREAM the segment instead of buffering it: AVPlayer aborts a segment
        // request after ~2 s without a response (CoreMedia -12889) and retries
        // in a loop, so the response headers must reach it as soon as the CDN
        // responds (~0.5 s TTFB), not after the full body has downloaded.
        let state = SegmentStreamState()
        let connKey = ObjectIdentifier(connection)
        let handle = fetcher.streamSegment(
            url: url,
            rangeHeader: forwardRange,
            queue: serverQueue,
            onHeaders: { status, length, contentRange in
                if status >= 400 {
                    // CDN error (expired token 403, pruned segment 404…):
                    // answer 502 and drop the body — never stream an HTML
                    // error page to AVPlayer as if it were video/mp2t.
                    state.cdnFailed = true
                    HTTPServerCommon.sendQuick(502, on: connection)
                    return
                }
                state.responded = true
                var fields: [String: String] = [
                    "Content-Type": "video/mp2t",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                ]
                if length > 0 { fields["Content-Length"] = "\(length)" }
                // Relay the CDN's own 206 + Content-Range verbatim — never
                // invent a 206 ourselves (a forged partial response with a
                // missing/incorrect Content-Range corrupts the player).
                if status == 206, let contentRange {
                    fields["Content-Range"] = contentRange
                }
                HTTPServerCommon.sendHead(status: status, fields: fields, on: connection)
            },
            onData: { data in
                guard !state.cdnFailed else { return }
                connection.send(content: data, completion: .contentProcessed { _ in })
            },
            onFinish: { [weak self] error in
                guard let self else { return }
                stateLock.withLock { _ = activeStreams.removeValue(forKey: connKey) }
                if state.cdnFailed {
                    // 502 already sent in onHeaders — just make sure the
                    // connection is closed once the error body is drained.
                    connection.cancel()
                } else if error == nil {
                    // End of body — close (Connection: close is in the headers).
                    connection.send(content: nil, completion: .contentProcessed { _ in connection.cancel() })
                } else if !state.responded {
                    print("🛡 AdStrippingProxy: segment fetch failed — \(error?.localizedDescription ?? "unknown")")
                    HTTPServerCommon.sendQuick(502, on: connection)
                } else {
                    // Body truncated mid-stream — the player retries the segment.
                    connection.cancel()
                }
            }
        )
        // Registered after start() returns: all callbacks are dispatched on
        // serverQueue, which is busy running this block — they can only fire
        // after the registration below. teardownConnection (also on
        // serverQueue) uses this to cancel the download if the client dies.
        stateLock.withLock { activeStreams[connKey] = handle }
    }

    /// Mutable flags for an in-flight segment response: whether headers were
    /// forwarded (a failure can then no longer become a clean 502) and whether
    /// the CDN answered with an error status (body must be dropped). Only
    /// touched on `serverQueue`, where all stream callbacks are dispatched.
    private final class SegmentStreamState: @unchecked Sendable {
        var responded = false
        var cdnFailed = false
    }
}
