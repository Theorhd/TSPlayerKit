import Foundation
import Network

/// Internal HTTP plumbing shared by `LocalHTTPServer` and `AdStrippingProxy`:
/// request-head accumulation and parsing, case-insensitive header lookup,
/// response head building, and RFC 7233 range handling. Not public API.
enum HTTPServerCommon {

    // MARK: - Shared constants

    /// Connections idle longer than this (no complete request head) are dropped.
    static let idleConnectionTimeout: TimeInterval = 10
    /// Request heads larger than this are rejected with 431.
    static let maxRequestHeadSize = 64 * 1024

    private static let receiveChunkSize = 64 * 1024
    private static let requestHeadTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    // MARK: - Concurrency helpers

    /// Simple armed/disarmed flag so a receive callback can cancel the idle
    /// watchdog without capturing a non-Sendable `DispatchWorkItem`. The
    /// receive callback must capture it STRONGLY (its lifetime follows the
    /// pending receive); only the deadline block may hold it weakly.
    final class IdleWatchdog: @unchecked Sendable {
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

    /// Thread-safe one-shot slot used to propagate a listener failure out of
    /// `start()` once the ready semaphore fires (the failure arrives on the
    /// server queue, the throwing initializer waits on the caller's thread).
    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func set(_ error: Error) { lock.withLock { self.error = error } }
        func get() -> Error? { lock.withLock { error } }
    }

    // MARK: - Request head handling

    /// Parses a request head into its first line plus the raw text (for header
    /// lookups). Returns `nil` when the buffer is not valid UTF-8.
    static func parseHead(_ data: Data) -> (line: String, raw: String)? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let line = raw.components(separatedBy: "\r\n").first ?? ""
        return (line, raw)
    }

    /// The request target (path + optional query) of a request line, e.g.
    /// `/segment_0.ts` from `GET /segment_0.ts HTTP/1.1`.
    static func requestPath(from requestLine: String) -> String? {
        requestLine.components(separatedBy: " ").dropFirst().first
    }

    /// Case-insensitive header lookup. Splits without per-line allocations
    /// (Substrings) and anchors the match at the start of the line so a search
    /// for `Range` cannot match `X-Range`.
    static func headerValue(_ name: String, in raw: String) -> String? {
        let prefix = name + ":"
        for line in raw.split(separator: "\r\n") {
            if line.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Receives and accumulates a request head on `connection`, calling
    /// `onHead` with the complete head once `\r\n\r\n` arrives. Drops idle
    /// connections (probes that never send anything) after `idleTimeout`,
    /// cancels when the connection closes mid-head, and calls `onOversize`
    /// (→ 431) when the buffer exceeds `maxHeadSize`.
    ///
    /// The receive callback captures the watchdog STRONGLY, so it stays alive
    /// while a receive is pending; the deadline block holds it only weakly.
    static func receiveRequest(
        on connection: NWConnection,
        queue: DispatchQueue,
        idleTimeout: TimeInterval,
        maxHeadSize: Int,
        onHead: @escaping @Sendable (Data) -> Void,
        onOversize: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        receiveRequest(on: connection, queue: queue, idleTimeout: idleTimeout,
                       maxHeadSize: maxHeadSize, accumulated: Data(),
                       onHead: onHead, onOversize: onOversize, onError: onError)
    }

    private static func receiveRequest(
        on connection: NWConnection,
        queue: DispatchQueue,
        idleTimeout: TimeInterval,
        maxHeadSize: Int,
        accumulated: Data,
        onHead: @escaping @Sendable (Data) -> Void,
        onOversize: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        let watchdog = IdleWatchdog()
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak connection, weak watchdog] in
            guard let watchdog, watchdog.isArmed() else { return }
            connection?.cancel()
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkSize) { data, _, isComplete, error in
            watchdog.disarm()
            if let error {
                onError(error)
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.range(of: requestHeadTerminator) != nil {
                onHead(buffer)
            } else if isComplete {
                // Connection closed before the head was complete — nothing to serve.
                connection.cancel()
            } else if buffer.count > maxHeadSize {
                // A request head larger than 64 KB is not a playlist request.
                onOversize()
            } else {
                receiveRequest(on: connection, queue: queue, idleTimeout: idleTimeout,
                               maxHeadSize: maxHeadSize, accumulated: buffer,
                               onHead: onHead, onOversize: onOversize, onError: onError)
            }
        }
    }

    // MARK: - Response writing

    /// Reason phrase for a status code (the wire format requires one).
    static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 206: "Partial Content"; case 302: "Found"
        case 400: "Bad Request"; case 403: "Forbidden"; case 404: "Not Found"
        case 416: "Requested Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"; case 502: "Bad Gateway"
        default: "Unknown"
        }
    }

    /// Builds a response head: status line + fields + `Connection: close`
    /// (every response here is one-shot). `chunked` adds
    /// `Transfer-Encoding: chunked` for streamed bodies.
    static func responseHead(status: Int, fields: [String: String], chunked: Bool = false) -> String {
        var s = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in fields { s += "\(k): \(v)\r\n" }
        if chunked { s += "Transfer-Encoding: chunked\r\n" }
        s += "Connection: close\r\n\r\n"
        return s
    }

    /// Sends a complete response (head + body) and closes the connection once
    /// the content has been handed to the stack, so the full response reaches
    /// AVPlayer before the socket closes.
    static func sendResponse(status: Int, fields: [String: String], body: Data,
                             on connection: NWConnection) {
        var data = Data(responseHead(status: status, fields: fields).utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Sends response headers only — the body follows through subsequent
    /// `connection.send` calls (segment streaming). The connection is not
    /// closed here; the last body chunk must close it.
    static func sendHead(status: Int, fields: [String: String], on connection: NWConnection) {
        let data = Data(responseHead(status: status, fields: fields).utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    static func sendQuick(_ status: Int, on connection: NWConnection) {
        sendResponse(status: status, fields: [:], body: Data(), on: connection)
    }

    // MARK: - Range parsing (RFC 7233 §3.1)

    /// A parsed HTTP `Range` header (`bytes=...`). Only single-range specs are
    /// supported — multipart/byteranges is never sent by AVPlayer.
    enum Range: Equatable {
        /// No (or no usable) Range header — serve the full representation.
        case absent
        /// `bytes=A-B`
        case closed(start: UInt64, end: UInt64)
        /// `bytes=A-`
        case open(start: UInt64)
        /// `bytes=-N` — the LAST N bytes of the representation.
        case suffix(count: UInt64)
        /// Syntactically invalid spec — respond 416 rather than guessing.
        case invalid
    }

    /// Concrete byte bounds of a range against a known content size.
    struct ResolvedRange: Equatable {
        let start: UInt64
        let end: UInt64 // inclusive
        let isRange: Bool
        var length: UInt64 { end - start + 1 }
    }

    /// Parses a Range header value. Anything that is not exactly one
    /// `bytes=` spec is `.invalid`; a missing header is `.absent`.
    static func parseRange(_ header: String?) -> Range {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .absent }
        let spec = header.dropFirst(6)
        guard !spec.contains(",") else { return .invalid } // no multipart support
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .invalid }

        let first = bounds[0], second = bounds[1]
        switch (first.isEmpty, second.isEmpty) {
        case (false, false):
            guard let s = UInt64(first), let e = UInt64(second) else { return .invalid }
            return .closed(start: s, end: e)
        case (false, true):
            guard let s = UInt64(first) else { return .invalid }
            return .open(start: s)
        case (true, false):
            guard let n = UInt64(second) else { return .invalid }
            return .suffix(count: n)
        case (true, true):
            return .invalid
        }
    }

    /// Resolves a parsed range against a content size into concrete bounds.
    /// Returns `nil` when the range cannot be satisfied (caller answers 416):
    /// invalid spec, inverted bounds, start at/past the end, zero-length suffix,
    /// or empty content.
    static func resolve(_ range: Range, size: UInt64) -> ResolvedRange? {
        guard size > 0 else { return nil }
        let last = size - 1
        switch range {
        case .absent:
            return ResolvedRange(start: 0, end: last, isRange: false)
        case .closed(let s, let e):
            guard s <= e, s <= last else { return nil }
            return ResolvedRange(start: s, end: min(e, last), isRange: true)
        case .open(let s):
            guard s <= last else { return nil }
            return ResolvedRange(start: s, end: last, isRange: true)
        case .suffix(let n):
            guard n > 0 else { return nil }
            if n >= size { return ResolvedRange(start: 0, end: last, isRange: true) }
            return ResolvedRange(start: size - n, end: last, isRange: true)
        case .invalid:
            return nil
        }
    }
}
