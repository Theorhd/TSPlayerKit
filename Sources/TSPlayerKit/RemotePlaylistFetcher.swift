import Foundation

/// Fetches remote HLS playlists and media segments from a CDN.
/// Uses URLSession with configurable User-Agent and optional extra headers.
public final class RemotePlaylistFetcher: @unchecked Sendable {

    private let session: URLSession
    private let extraHeaders: [String: String]

    /// - Parameters:
    ///   - userAgent: The User-Agent header value.
    ///   - extraHeaders: Additional headers to include in every request (e.g. Client-Id).
    ///   - timeout: Request timeout in seconds.
    public init(userAgent: String, extraHeaders: [String: String] = [:], timeout: TimeInterval = 10) {
        self.extraHeaders = extraHeaders
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Bypass the cache entirely — segments are large and immutable, caching
        // them in URLCache only fills the disk for no reuse benefit.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let range = range {
            request.setValue("bytes=\(range.location)-\(range.location + range.length - 1)", forHTTPHeaderField: "Range")
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
