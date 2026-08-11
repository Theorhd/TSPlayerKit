import Foundation

/// A generic HTTP forward proxy (Squid, …) that `RemotePlaylistFetcher`
/// relays every upstream request through.
///
/// Applied at the URLSession level via `connectionProxyDictionary`: plain-HTTP
/// URLs are fetched through the proxy, HTTPS URLs are tunneled with CONNECT.
/// The proxy only sees the raw upstream traffic (usher, CDN playlists and
/// segments) — never the cleaned playlists served to AVPlayer, which stay on
/// the loopback server.
///
/// Proxy authentication is not supported: URLSession does not reliably honor
/// credentials in `connectionProxyDictionary`. Restrict the proxy by IP ACL
/// instead.
public struct HTTPProxy: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}
