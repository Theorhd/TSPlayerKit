import Foundation
import Network

/// Minimal local HTTP server serving a virtual HLS manifest and TS file bytes over loopback.
final class LocalHTTPServer: @unchecked Sendable {

    private(set) var port: UInt16 = 0
    private var manifestData: Data = Data()
    private let manifestLock = NSLock()
    private let streamer: FileStreamer
    private var listener: NWListener?

    /// Segment metadata for multi-segment mode. When non-nil, `/segment_N.ts` URLs
    /// are routed to the corresponding byte range. When nil, the server operates in
    /// legacy single-segment mode (`/segment.ts` with the 8 MB response cap).
    private let segments: [SegmentInfo]?

    private let serverQueue = DispatchQueue(
        label: "com.tsplayerkit.localserver",
        qos: .userInitiated
    )

    // Blocks init until NWListener is ready and port is assigned.
    private let readySemaphore = DispatchSemaphore(value: 0)

    /// Legacy single-segment mode.
    init(streamer: FileStreamer) throws {
        self.streamer = streamer
        self.segments = nil
        try start()
    }

    /// Multi-segment mode — each segment is served by its exact byte range without
    /// any response-size cap, fixing the ~6-second truncation that occurred when a
    /// single-segment manifest was capped at 8 MB.
    init(streamer: FileStreamer, segments: [SegmentInfo]) throws {
        self.streamer = streamer
        self.segments = segments
        try start()
    }

    deinit {
        stop()
    }

    func setManifest(_ data: Data) {
        manifestLock.lock()
        manifestData = data
        manifestLock.unlock()
    }

    private func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw FileStreamerError.systemError(error)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port {
                    self.port = port.rawValue
                }
                self.readySemaphore.signal()
            case .failed(let error):
                NSLog("[TSPlayerKit] Listener failed: \(error)")
                self.readySemaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: serverQueue)
        self.listener = listener

        readySemaphore.wait()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveRequest(from: connection)
    }

    // Accumulates bytes until HTTP header boundary (\r\n\r\n) is received.
    private func receiveRequest(
        from connection: NWConnection,
        accumulated: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("[TSPlayerKit] Receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if buffer.range(of: separator) != nil {
                self.processRequest(headers: buffer, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(from: connection, accumulated: buffer)
            }
        }
    }

    private func processRequest(headers: Data, on connection: NWConnection) {
        guard
            let rawHeaders = String(data: headers, encoding: .utf8),
            let requestLine = rawHeaders.components(separatedBy: "\r\n").first
        else {
            sendResponse(statusCode: 400, headers: [:], body: Data(), on: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(statusCode: 400, headers: [:], body: Data(), on: connection)
            return
        }

        let path = parts[1]

        switch path {
        case "/playlist.m3u8":
            serveManifest(on: connection)
        case "/segment.ts":
            let rangeHeader = extractHeader("Range", from: rawHeaders)
            serveLegacySegment(rangeHeader: rangeHeader, on: connection)
        default:
            // Multi-segment routing: /segment_<index>.ts
            if let index = parseSegmentIndex(from: path) {
                let rangeHeader = extractHeader("Range", from: rawHeaders)
                serveSegment(index: index, rangeHeader: rangeHeader, on: connection)
            } else {
                sendResponse(statusCode: 404, headers: [:], body: Data(), on: connection)
            }
        }
    }

    private func serveManifest(on connection: NWConnection) {
        manifestLock.lock()
        let data = manifestData
        manifestLock.unlock()

        let responseHeaders = [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
        ]
        sendResponse(
            statusCode: 200,
            headers: responseHeaders,
            body: data,
            on: connection
        )
    }

    // MARK: - Segment serving

    /// Parses a segment index from a path like `/segment_42.ts`.
    /// Returns nil if the path doesn't match the expected pattern.
    private func parseSegmentIndex(from path: String) -> Int? {
        // Pattern: "/segment_" + digits + ".ts"
        guard path.hasPrefix("/segment_"), path.hasSuffix(".ts") else { return nil }
        let start = path.index(path.startIndex, offsetBy: "/segment_".count)
        let end = path.index(path.endIndex, offsetBy: -".ts".count)
        guard start < end else { return nil }
        return Int(path[start..<end])
    }

    /// Multi-segment mode: serves the exact byte range for segment `index`.
    ///
    /// Individual HLS segments are small (typically 2–10 s, < 10 MB), so the
    /// full byte range is read into memory and served in one response — no 8 MB
    /// cap needed. This is what fixes the ~6-second truncation bug: with a
    /// single-segment manifest the cap prevented AVPlayer from receiving more
    /// than a few seconds of video, but with a multi-segment manifest each
    /// segment fits comfortably within memory limits.
    private func serveSegment(
        index: Int,
        rangeHeader: String?,
        on connection: NWConnection
    ) {
        guard let segments, index >= 0, index < segments.count else {
            sendResponse(statusCode: 404, headers: [:], body: Data(), on: connection)
            return
        }

        let segment = segments[index]
        let segmentStart = segment.offset
        let segmentEnd = segment.offset + segment.length - 1

        // If the client sends a Range header, honour it within the segment bounds.
        var start: UInt64 = segmentStart
        var end: UInt64 = segmentEnd

        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            let rangeSpec = String(range.dropFirst("bytes=".count))
            let bounds = rangeSpec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) {
                start = segmentStart + sv
            }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) {
                end = min(segmentStart + ev, segmentEnd)
            }
            end = min(end, segmentEnd)
            start = max(start, segmentStart)
        }

        let requestedLength = end - start + 1

        Task { [streamer] in
            do {
                let data = try await streamer.readBytes(offset: start, length: requestedLength)

                let responseHeaders: [String: String] = [
                    "Content-Type": "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                    "Content-Range": "bytes \(start)-\(end)/\(streamer.fileSize)",
                ]
                self.sendResponse(
                    statusCode: 206,
                    headers: responseHeaders,
                    body: data,
                    on: connection
                )
            } catch {
                self.sendResponse(
                    statusCode: 500,
                    headers: [:],
                    body: Data(),
                    on: connection
                )
            }
        }
    }

    /// Legacy single-segment mode: serves the entire TS file as one segment.
    ///
    /// Responses are capped at `maxChunkSize` (8 MB) to avoid reading a multi-GB
    /// file into memory. This cap is the root cause of the ~6-second playback bug
    /// (8 MB / ~10 Mbps ≈ 6.4 s). New downloads use the multi-segment mode above;
    /// this path remains for backward compatibility with downloads that don't have
    /// a `video.segments.json` sidecar.
    private func serveLegacySegment(rangeHeader: String?, on connection: NWConnection) {
        let fileSize = streamer.fileSize

        guard fileSize > 0 else {
            sendResponse(statusCode: 500, headers: [:], body: Data(), on: connection)
            return
        }

        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1

        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            let rangeSpec = String(range.dropFirst("bytes=".count))
            let bounds = rangeSpec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) { start = sv }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) {
                end = ev
            }
            end = min(end, fileSize - 1)
        }

        // Cap each response to 8 MB. If the caller requested a smaller range (e.g. for
        // a seek probe) we honour that exact range. If the requested range is larger we
        // serve only the first maxChunkSize bytes and report the real file size in
        // Content-Range so AVPlayer knows there is more data to fetch.
        let maxChunkSize: UInt64 = 8 * 1024 * 1024 // 8 MB
        let requestedLength = end - start + 1
        let servedLength = min(requestedLength, maxChunkSize)
        let actualEnd = start + servedLength - 1

        Task { [streamer] in
            do {
                let data = try await streamer.readBytes(offset: start, length: servedLength)
                // Always respond 206 so AVPlayer sees Content-Range and knows the total
                // file size, enabling it to make follow-up requests for remaining bytes.
                let responseHeaders: [String: String] = [
                    "Content-Type": "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                    "Content-Range": "bytes \(start)-\(actualEnd)/\(fileSize)",
                ]
                self.sendResponse(
                    statusCode: 206,
                    headers: responseHeaders,
                    body: data,
                    on: connection
                )
            } catch {
                self.sendResponse(
                    statusCode: 500,
                    headers: [:],
                    body: Data(),
                    on: connection
                )
            }
        }
    }

    private func sendResponse(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        on connection: NWConnection
    ) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 206: statusText = "Partial Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default:  statusText = "Unknown"
        }

        var responseString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (key, value) in headers {
            responseString += "\(key): \(value)\r\n"
        }
        responseString += "Connection: close\r\n\r\n"

        var responseData = Data(responseString.utf8)
        responseData.append(body)

        connection.send(
            content: responseData,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func extractHeader(_ name: String, from rawHeaders: String) -> String? {
        for line in rawHeaders.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            let key = name.lowercased() + ":"
            if lower.hasPrefix(key) {
                return String(line.dropFirst(key.count)).trimmingCharacters(
                    in: .whitespaces
                )
            }
        }
        return nil
    }
}
