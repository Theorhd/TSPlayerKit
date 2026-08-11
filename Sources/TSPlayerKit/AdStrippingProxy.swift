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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveRequest(from: connection)
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let _ = error { connection.cancel(); return }
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
            serveSlate(on: connection)
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
                serveManifest(text: result.playlist, on: connection)
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

    /// Serves the embedded slate placeholder segment. The path suffix (segment
    /// index) only exists to keep URLs unique across polls — the bytes are
    /// always the same, served straight from memory with no network round-trip.
    private func serveSlate(on connection: NWConnection) {
        guard let data = SlateSegment.data else {
            sendQuick(404, on: connection)
            return
        }
        send(status: 200, body: data, extraHeaders: [
            "Content-Type": "video/mp2t",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
        ], on: connection)
    }

    // MARK: - Redirect mapping

    /// Maps proxy paths to real CDN URLs. Keys include the variant index
    /// (`/seg/{variant}/{index}/{file}`) because different qualities reuse the
    /// same segment filenames — without it, a quality switch would serve the
    /// previous variant's segments.
    private func cacheRedirectMappings(from originalPlaylist: String, variantBaseURL: URL, variantIdx: Int) {
        let lines = originalPlaylist.components(separatedBy: .newlines)
        var segIdx = 0
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
                    segmentRedirects["/seg/\(variantIdx)/\(segIdx)/\(resolved.lastPathComponent)"] = resolved
                }
                segIdx += 1
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
        Task {
            do {
                var nsRange: NSRange?
                if let rh = rangeHeader, rh.lowercased().hasPrefix("bytes=") {
                    let spec = String(rh.dropFirst(6))
                    let bounds = spec.components(separatedBy: "-")
                    if let s = bounds.first, !s.isEmpty, let sv = Int(s) {
                        var end = Int.max
                        if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = Int(e) { end = ev }
                        nsRange = NSRange(location: sv, length: end - sv + 1)
                    }
                }
                let (data, contentType) = try await fetcher.fetchSegment(url: url, range: nsRange)
                send(status: nsRange != nil ? 206 : 200, body: data, extraHeaders: [
                    "Content-Type": contentType ?? "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                ], on: connection)
            } catch {
                sendQuick(502, on: connection)
            }
        }
    }

    private func send(status: Int, body: Data, extraHeaders: [String: String], on connection: NWConnection) {
        var s = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in extraHeaders { s += "\(k): \(v)\r\n" }
        s += "Connection: close\r\n\r\n"
        var data = Data(s.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
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
