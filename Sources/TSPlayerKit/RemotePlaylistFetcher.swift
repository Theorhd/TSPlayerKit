import Foundation

/// Fetches remote HLS playlists and media segments from a CDN.
/// Uses URLSession with configurable User-Agent, optional extra headers,
/// and an optional upstream HTTP proxy (see `HTTPProxy`) every request
/// is relayed through.
public final class RemotePlaylistFetcher: @unchecked Sendable {

    /// Delay before the single retry after a transport-level playlist failure.
    private static let retryDelayNanoseconds: UInt64 = 500_000_000

    private let session: URLSession
    private let streamingCenter: StreamingCenter
    private let extraHeaders: [String: String]
    private let userAgent: String
    private let timeout: TimeInterval
    /// The upstream proxy every request is relayed through, if any.
    internal let proxy: HTTPProxy?

    /// - Parameters:
    ///   - userAgent: The User-Agent header value.
    ///   - extraHeaders: Additional headers to include in every request (e.g. Client-Id).
    ///   - timeout: Request timeout in seconds.
    ///   - proxy: Optional upstream HTTP proxy relayed through for every request.
    public init(userAgent: String, extraHeaders: [String: String] = [:], timeout: TimeInterval = 10, proxy: HTTPProxy? = nil) {
        self.extraHeaders = extraHeaders
        self.userAgent = userAgent
        self.timeout = timeout
        self.proxy = proxy
        let config = Self.makeConfiguration(userAgent: userAgent, timeout: timeout, proxy: proxy)
        self.session = URLSession(configuration: config)
        // Segments stream through ONE long-lived session: TCP/TLS keep-alive
        // between segment requests (~every 2 s) saves a full handshake per segment.
        self.streamingCenter = StreamingCenter(configuration: Self.makeConfiguration(userAgent: userAgent, timeout: timeout, proxy: proxy))
    }

    private static func makeConfiguration(userAgent: String, timeout: TimeInterval, proxy: HTTPProxy?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(30, 3 * timeout)
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let proxy {
            // Relay every request through the upstream proxy: plain HTTP goes
            // directly, HTTPS is tunneled via CONNECT. On iOS the HTTP keys
            // alone cover HTTPS; the HTTPS keys are macOS-only constants
            // (unavailable on iOS) and macOS needs them explicitly or https
            // bypasses the proxy.
            var proxyDict: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: proxy.host,
                kCFNetworkProxiesHTTPPort: proxy.port,
            ]
            #if os(macOS)
            proxyDict[kCFNetworkProxiesHTTPSEnable] = true
            proxyDict[kCFNetworkProxiesHTTPSProxy] = proxy.host
            proxyDict[kCFNetworkProxiesHTTPSPort] = proxy.port
            #endif
            config.connectionProxyDictionary = proxyDict
        }
        return config
    }

    /// Fetches a remote HLS playlist (master or variant) and returns its text content
    /// along with the final URL after redirects (needed for resolving relative segment URIs).
    ///
    /// Transport-level failures (dropped connection) get exactly one retry after
    /// 500 ms — a transient CDN hiccup must not surface to AVPlayer as a 502,
    /// which it treats as a fatal playlist error. Timeouts are NOT retried: a
    /// live window is ~2 s and a second slow attempt would blow past AVPlayer's
    /// abort threshold. HTTP-level errors (4xx/5xx) fail immediately.
    public func fetchPlaylist(url: URL) async throws -> (text: String, finalURL: URL) {
        do {
            return try await performPlaylistFetch(url: url)
        } catch let error as URLError where error.code != .cancelled && error.code != .timedOut {
            try await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            return try await performPlaylistFetch(url: url)
        }
    }

    private func performPlaylistFetch(url: URL) async throws -> (text: String, finalURL: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Playlists must never come from the cache: a cached live media playlist is
        // a stale sliding window whose segments have already expired (404 storm).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.decodingFailed
        }

        // Dead or degraded proxies (TTV endpoints, expired usher tokens) can
        // return HTML/JSON error pages with HTTP 200. Validating the signature
        // tag turns those into a clean 502 → AVPlayer .failed → app-side
        // fallback, instead of serving garbage that AVPlayer fails to parse
        // (CoreMedia -12646 "Playlist parse error").
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("#EXTM3U") else {
            throw FetchError.invalidPlaylist
        }

        // response.url is the final URL after redirects — needed to resolve relative URIs
        return (text, response.url ?? url)
    }

    /// Fetches a media segment and returns its data and content type.
    public func fetchSegment(url: URL, range: NSRange? = nil) async throws -> (data: Data, contentType: String?) {
        let header = range.map {
            $0.length > 0
                ? "bytes=\($0.location)-\($0.location + $0.length - 1)"
                : "bytes=\($0.location)-"
        }
        return try await fetchSegment(url: url, rangeHeader: header)
    }

    /// Fetches a media segment, forwarding a raw HTTP `Range` header verbatim.
    /// Prefer this over the `NSRange` variant: open-ended ranges (`bytes=0-`)
    /// cannot be represented as an `NSRange` without overflow, and the CDN
    /// handles the raw syntax natively.
    public func fetchSegment(url: URL, rangeHeader: String?) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Bypass the cache entirely — segments are large and immutable, caching
        // them in URLCache only fills the disk for no reuse benefit.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        // 206 Partial Content is valid for range requests
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        let contentType = (httpResponse.allHeaderFields["Content-Type"] as? String)
            ?? (httpResponse.allHeaderFields["content-type"] as? String)
        return (data, contentType)
    }

    // MARK: - Segment streaming

    /// Handle on an in-flight segment stream, allowing the caller to cancel
    /// the download (e.g. when the player closed its connection).
    public struct SegmentStreamHandle: Sendable {
        private let cancelBox: @Sendable () -> Void
        fileprivate init(cancel: @escaping @Sendable () -> Void) { cancelBox = cancel }
        public func cancel() { cancelBox() }
    }

    /// Streams a remote segment. `onHeaders` fires as soon as the CDN responds
    /// — the caller forwards the response headers to AVPlayer IMMEDIATELY,
    /// because it aborts after ~2 s without a response (CoreMedia -12889).
    /// Then `onData` delivers the body chunks and `onFinish` fires once, with
    /// `nil` on success or the transport error otherwise. All callbacks are
    /// delivered on `queue` in order; `onFinish` is always last.
    ///
    /// `onHeaders` receives the CDN status, the expected body length (-1 when
    /// unknown) and the `Content-Range` value for 206 responses (nil otherwise).
    @discardableResult
    public func streamSegment(
        url: URL,
        rangeHeader: String?,
        queue: DispatchQueue,
        onHeaders: @escaping @Sendable (Int, Int64, String?) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) -> SegmentStreamHandle {
        let task = streamingCenter.start(
            url: url,
            rangeHeader: rangeHeader,
            extraHeaders: extraHeaders,
            handler: .init(queue: queue, onHeaders: onHeaders, onData: onData, onFinish: onFinish)
        )
        return SegmentStreamHandle { task.cancel() }
    }

    /// Test seam: the configuration the fetcher's sessions were built from,
    /// so proxy wiring can be asserted without hitting the network.
    internal var sessionConfiguration: URLSessionConfiguration { session.configuration }

    // MARK: - Error

    public enum FetchError: Error, LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int)
        case decodingFailed
        case invalidPlaylist

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid HTTP response from CDN."
            case .httpError(let code):
                return "CDN returned HTTP \(code)."
            case .decodingFailed:
                return "Failed to decode playlist text."
            case .invalidPlaylist:
                return "Response is not a valid HLS playlist (missing #EXTM3U)."
            }
        }
    }
}

/// Owns the single streaming URLSession and dispatches delegate callbacks to
/// the per-request handlers, keyed by `task.taskIdentifier`. All segment
/// downloads share this session, so connections to the CDN stay alive between
/// segments (no per-segment TCP/TLS handshake).
private final class StreamingCenter: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    struct Handler {
        let queue: DispatchQueue
        let onHeaders: @Sendable (Int, Int64, String?) -> Void
        let onData: @Sendable (Data) -> Void
        let onFinish: @Sendable (Error?) -> Void
    }

    // IUO: URLSession needs `self` as delegate, so the session can only be
    // created after super.init() — assigned exactly once in init below.
    private var session: URLSession!
    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]

    init(configuration: URLSessionConfiguration) {
        super.init()
        // Serial delegate queue: callbacks for a task arrive in order, and the
        // re-dispatch to each handler's queue preserves that order.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func start(url: URL, rangeHeader: String?, extraHeaders: [String: String], handler: Handler) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Bypass the cache entirely — segments are large and immutable.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        lock.withLock { handlers[task.taskIdentifier] = handler }
        task.resume()
        return task
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let handler = lock.withLock { handlers[dataTask.taskIdentifier] }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 500
        let length = http?.expectedContentLength ?? -1
        let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        completionHandler(.allow)
        if let handler { handler.queue.async { handler.onHeaders(status, length, contentRange) } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let handler = lock.withLock { handlers[dataTask.taskIdentifier] }
        if let handler { handler.queue.async { handler.onData(data) } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        if let handler { handler.queue.async { handler.onFinish(error) } }
    }
}
