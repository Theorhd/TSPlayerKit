import Foundation

/// Fetches remote HLS playlists and media segments from a CDN.
/// Uses URLSession with configurable User-Agent and optional extra headers.
public final class RemotePlaylistFetcher: @unchecked Sendable {

    private let session: URLSession
    private let extraHeaders: [String: String]
    private let userAgent: String
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - userAgent: The User-Agent header value.
    ///   - extraHeaders: Additional headers to include in every request (e.g. Client-Id).
    ///   - timeout: Request timeout in seconds.
    public init(userAgent: String, extraHeaders: [String: String] = [:], timeout: TimeInterval = 10) {
        self.extraHeaders = extraHeaders
        self.userAgent = userAgent
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetches a remote HLS playlist (master or variant) and returns its text content
    /// along with the final URL after redirects (needed for resolving relative segment URIs).
    ///
    /// Transport-level failures (dropped connection, timeout) get exactly one
    /// retry after 500 ms — a transient CDN hiccup must not surface to AVPlayer
    /// as a 502, which it treats as a fatal playlist error. HTTP-level errors
    /// (4xx/5xx) fail immediately: retrying them just delays the failure signal.
    public func fetchPlaylist(url: URL) async throws -> (text: String, finalURL: URL) {
        do {
            return try await performPlaylistFetch(url: url)
        } catch let error as URLError where error.code != .cancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
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
        let header = range.map { "bytes=\($0.location)-\($0.location + $0.length - 1)" }
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

    /// Streams a remote segment. `onHeaders` fires as soon as the CDN responds
    /// — the caller forwards the response headers to AVPlayer IMMEDIATELY,
    /// because it aborts after ~2 s without a response (CoreMedia -12889).
    /// Then `onData` delivers the body chunks and `onFinish` fires once, with
    /// `nil` on success or the transport error otherwise. All callbacks are
    /// delivered on `queue` in order, before `onFinish` is ever called
    /// `onHeaders` may or may not have fired.
    public func streamSegment(
        url: URL,
        rangeHeader: String?,
        queue: DispatchQueue,
        onHeaders: @escaping @Sendable (Int, Int64) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        let streamer = SegmentStreamer(
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            timeout: timeout,
            queue: queue,
            onHeaders: onHeaders,
            onData: onData,
            onFinish: onFinish
        )
        streamer.start(url: url, rangeHeader: rangeHeader)
    }

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

/// Drives a single segment download as a `URLSessionDataDelegate`, forwarding
/// the response headers as soon as they arrive (before the body finishes
/// downloading) and then the body chunks. Retains itself until the task
/// completes, so the caller can fire-and-forget.
private final class SegmentStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let queue: DispatchQueue
    private let onHeaders: @Sendable (Int, Int64) -> Void
    private let onData: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private var session: URLSession?
    private var selfRetain: SegmentStreamer?

    init(
        userAgent: String,
        extraHeaders: [String: String],
        timeout: TimeInterval,
        queue: DispatchQueue,
        onHeaders: @escaping @Sendable (Int, Int64) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.queue = queue
        self.onHeaders = onHeaders
        self.onData = onData
        self.onFinish = onFinish
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        // Delegate callbacks land on `queue`, serialized with the caller's
        // connection writes.
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, rangeHeader: String?) {
        selfRetain = self
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Bypass the cache entirely — segments are large and immutable.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        session?.dataTask(with: request).resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        queue.async { [weak self] in
            self?.onHeaders(http?.statusCode ?? 500, http?.expectedContentLength ?? -1)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let chunk = data
        queue.async { [weak self] in
            self?.onData(chunk)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finishError = error
        queue.async { [weak self] in
            guard let self else { return }
            self.onFinish(finishError)
            self.session?.invalidateAndCancel()
            self.session = nil
            self.selfRetain = nil
        }
    }
}
