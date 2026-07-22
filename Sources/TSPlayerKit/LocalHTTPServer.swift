import Foundation
import Network

/// Minimal local HTTP server serving a virtual HLS manifest and TS file bytes over loopback.
final class LocalHTTPServer: @unchecked Sendable {

    private(set) var port: UInt16 = 0
    private var manifestData: Data = Data()
    private let manifestLock = NSLock()
    private let streamer: FileStreamer?
    private var listener: NWListener?

    /// Segment metadata for multi-segment mode. When non-nil, `/segment_N.ts` URLs
    /// are routed to the corresponding byte range. When nil, the server operates in
    /// legacy single-segment mode (`/segment.ts` served via chunked transfer encoding).
    private let segments: [SegmentInfo]?

    /// When non-nil, the server operates in **static file directory** mode (fMP4).
    /// URL paths are mapped directly to files in this directory:
    ///   /playlist.m3u8 → directory/index.m3u8
    ///   /chunk_0.m4s  → directory/chunk_0.m4s
    private let directoryURL: URL?

    private let serverQueue = DispatchQueue(
        label: "com.tsplayerkit.localserver",
        qos: .userInitiated
    )

    // Blocks init until NWListener is ready and port is assigned.
    private let readySemaphore = DispatchSemaphore(value: 0)

    /// Legacy single-segment TS mode (chunked transfer via FileStreamer).
    init(streamer: FileStreamer) throws {
        self.streamer = streamer
        self.segments = nil
        self.directoryURL = nil
        try start()
    }

    /// Multi-segment TS mode (byte-range segments from a concatenated file).
    init(streamer: FileStreamer, segments: [SegmentInfo]) throws {
        self.streamer = streamer
        self.segments = segments
        self.directoryURL = nil
        try start()
    }

    /// Static file directory mode (fMP4). Serves an `index.m3u8` and all segment
    /// files from a single directory over HTTP. Each URL path is mapped directly
    /// to the corresponding file on disk.
    init(directoryURL: URL) throws {
        self.streamer = nil
        self.segments = nil
        self.directoryURL = directoryURL
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
            sendError(statusCode: 400, on: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(statusCode: 400, on: connection)
            return
        }

        let path = parts[1]

        // Directory mode (fMP4): route paths to files on disk.
        if let dirURL = directoryURL {
            switch path {
            case "/playlist.m3u8":
                serveStaticFile(at: dirURL.appendingPathComponent("index.m3u8"),
                                contentType: "application/vnd.apple.mpegurl",
                                on: connection)
            default:
                // Strip leading "/" and serve the corresponding file.
                let relativePath = String(path.dropFirst())
                let fileURL = dirURL.appendingPathComponent(relativePath)
                serveStaticFile(at: fileURL,
                                contentType: "video/mp2t",
                                on: connection)
            }
            return
        }

        // TS modes (single-segment or multi-segment).
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
                sendError(statusCode: 404, on: connection)
            }
        }
    }

    // MARK: - Static file serving (directory mode / fMP4)

    /// Serves a file from disk. For small files (≤ 16 MB), reads the entire file
    /// and sends it in one response. For larger files, uses chunked transfer encoding.
    private func serveStaticFile(at fileURL: URL, contentType: String, on connection: NWConnection) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sendError(statusCode: 404, on: connection)
            return
        }

        let fileSize: UInt64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            sendError(statusCode: 500, on: connection)
            return
        }

        // Small files (m3u8, init segments): serve directly.
        // Segment files are typically 2–10 MB, also fine for direct serving.
        let maxDirectServe: UInt64 = 16 * 1024 * 1024 // 16 MB
        if fileSize <= maxDirectServe {
            do {
                let data = try Data(contentsOf: fileURL)
                let responseHeaders: [String: String] = [
                    "Content-Type": contentType,
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                ]
                sendResponse(statusCode: 200, headers: responseHeaders, body: data, on: connection)
            } catch {
                sendError(statusCode: 500, on: connection)
            }
        } else {
            // Large file — stream with chunked transfer.
            streamStaticFileChunked(fileURL: fileURL, contentType: contentType, on: connection)
        }
    }

    /// Streams a large static file using chunked transfer encoding, 1 MB at a time.
    private func streamStaticFileChunked(fileURL: URL, contentType: String, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendError(statusCode: 500, on: connection)
            return
        }

        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard let headData = head.data(using: .utf8) else {
            try? handle.close()
            connection.cancel()
            return
        }

        connection.send(content: headData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[TSPlayerKit] Head send error: \(error)")
                try? handle.close()
                connection.cancel()
                return
            }
            self?.sendNextStaticChunk(handle: handle, on: connection)
        })
    }

    /// Recursively sends one chunk of a static file, then schedules the next.
    private func sendNextStaticChunk(handle: FileHandle, on connection: NWConnection) {
        let chunkSize = 1024 * 1024 // 1 MB
        let data = handle.readData(ofLength: chunkSize)

        if data.isEmpty {
            // End of file — send terminating chunk.
            try? handle.close()
            let terminator = Data("0\r\n\r\n".utf8)
            connection.send(content: terminator, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let hexSize = String(format: "%X\r\n", data.count)
        guard let hexData = hexSize.data(using: .utf8) else {
            try? handle.close()
            connection.cancel()
            return
        }

        var chunkMessage = Data()
        chunkMessage.append(hexData)
        chunkMessage.append(data)
        chunkMessage.append(Data("\r\n".utf8))

        connection.send(content: chunkMessage, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[TSPlayerKit] Chunk send error: \(error)")
                try? handle.close()
                connection.cancel()
                return
            }
            self?.sendNextStaticChunk(handle: handle, on: connection)
        })
    }

    // MARK: - Manifest

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

    // MARK: - Segment index parsing

    /// Parses a segment index from a path like `/segment_42.ts`.
    private func parseSegmentIndex(from path: String) -> Int? {
        guard path.hasPrefix("/segment_"), path.hasSuffix(".ts") else { return nil }
        let start = path.index(path.startIndex, offsetBy: "/segment_".count)
        let end = path.index(path.endIndex, offsetBy: -".ts".count)
        guard start < end else { return nil }
        return Int(path[start..<end])
    }

    // MARK: - Multi-segment serving (no cap, complete segments)

    /// Multi-segment mode: serves the exact byte range for segment `index`.
    ///
    /// Individual HLS segments are small (typically 2–10 s, < 10 MB), so the full
    /// byte range is read into memory and served as 200 OK — no 8 MB cap, no 206
    /// Partial Content. AVPlayer sees a normal complete HLS segment.
    private func serveSegment(
        index: Int,
        rangeHeader: String?,
        on connection: NWConnection
    ) {
        guard let segments, index >= 0, index < segments.count else {
            sendError(statusCode: 404, on: connection)
            return
        }

        let segment = segments[index]
        let segmentStart = segment.offset
        let segmentEnd = segment.offset + segment.length - 1

        // If the client sends a Range header (seeking within a segment), honour it.
        var start: UInt64 = segmentStart
        var end: UInt64 = segmentEnd
        var isRangeRequest = false

        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            isRangeRequest = true
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
            guard let streamer else { connection.cancel(); return }
            do {
                let data = try await streamer.readBytes(offset: start, length: requestedLength)

                if isRangeRequest {
                    // Seeking within a segment — return 206 with Content-Range.
                    let responseHeaders: [String: String] = [
                        "Content-Type": "video/mp2t",
                        "Content-Length": "\(data.count)",
                        "Accept-Ranges": "bytes",
                        "Cache-Control": "no-cache",
                        "Content-Range": "bytes \(start)-\(end)/\(streamer.fileSize)",
                    ]
                    self.sendResponse(statusCode: 206, headers: responseHeaders, body: data, on: connection)
                } else {
                    // Complete segment — return 200 OK, no Content-Range needed.
                    let responseHeaders: [String: String] = [
                        "Content-Type": "video/mp2t",
                        "Content-Length": "\(data.count)",
                        "Accept-Ranges": "bytes",
                        "Cache-Control": "no-cache",
                    ]
                    self.sendResponse(statusCode: 200, headers: responseHeaders, body: data, on: connection)
                }
            } catch {
                self.sendError(statusCode: 500, on: connection)
            }
        }
    }

    // MARK: - Legacy single-segment serving (chunked transfer, no cap)

    /// Serves the entire TS file as one segment using **chunked transfer encoding**.
    ///
    /// The old implementation capped responses at 8 MB to avoid reading multi-GB
    /// files into memory. This caused the ~6-second playback bug because AVPlayer
    /// treats a truncated HLS segment as complete and stops.
    ///
    /// The fix: use `Transfer-Encoding: chunked` to stream the file in 1 MB chunks
    /// over a single HTTP response. AVPlayer receives the full segment data without
    /// the server ever holding more than 1 MB in memory at once.
    ///
    /// If the client sends a Range header (seeking), the response is capped to the
    /// requested range — no chunked encoding needed for small seek probes.
    private func serveLegacySegment(rangeHeader: String?, on connection: NWConnection) {
        guard let streamer else { connection.cancel(); return }
        let fileSize = streamer.fileSize

        guard fileSize > 0 else {
            sendError(statusCode: 500, on: connection)
            return
        }

        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1
        let isRangeRequest = (rangeHeader != nil)

        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            let rangeSpec = String(range.dropFirst("bytes=".count))
            let bounds = rangeSpec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) { start = sv }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) {
                end = ev
            }
            end = min(end, fileSize - 1)
        }

        let requestedLength = end - start + 1

        // For small Range requests (seek probes, typically a few KB), serve directly.
        // For full-segment requests (no Range header) or large ranges, use chunked
        // transfer encoding to stream without blowing memory.
        let maxDirectServe: UInt64 = 16 * 1024 * 1024 // 16 MB
        if isRangeRequest && requestedLength <= maxDirectServe {
            Task { [streamer] in
                do {
                    let data = try await streamer.readBytes(offset: start, length: requestedLength)
                    let responseHeaders: [String: String] = [
                        "Content-Type": "video/mp2t",
                        "Content-Length": "\(data.count)",
                        "Accept-Ranges": "bytes",
                        "Cache-Control": "no-cache",
                        "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                    ]
                    self.sendResponse(statusCode: 206, headers: responseHeaders, body: data, on: connection)
                } catch {
                    self.sendError(statusCode: 500, on: connection)
                }
            }
        } else {
            // Full segment or large range — stream using chunked transfer encoding.
            streamFileChunked(
                startOffset: start,
                totalLength: requestedLength,
                on: connection
            )
        }
    }

    /// Streams a byte range of the TS file to the client using HTTP chunked transfer
    /// encoding. Each chunk is at most 1 MB to keep memory usage low. The method
    /// sends chunks sequentially via NWConnection, chaining completions.
    ///
    /// HTTP chunked format:
    ///   <hex-size>\r\n<data>\r\n ... 0\r\n\r\n
    private func streamFileChunked(
        startOffset: UInt64,
        totalLength: UInt64,
        on connection: NWConnection
    ) {
        let chunkSizeLimit: UInt64 = 1024 * 1024 // 1 MB per chunk

        // Send HTTP response head with Transfer-Encoding: chunked.
        let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nTransfer-Encoding: chunked\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard let headData = head.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: headData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[TSPlayerKit] Head send error: \(error)")
                connection.cancel()
                return
            }
            self?.sendNextChunk(
                offset: startOffset,
                remaining: totalLength,
                chunkLimit: chunkSizeLimit,
                on: connection
            )
        })
    }

    /// Recursively sends one chunk then schedules the next.
    private func sendNextChunk(
        offset: UInt64,
        remaining: UInt64,
        chunkLimit: UInt64,
        on connection: NWConnection
    ) {
        guard remaining > 0 else {
            // All data sent — write the terminating chunk.
            let terminator = Data("0\r\n\r\n".utf8)
            connection.send(content: terminator, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let readLen = min(remaining, chunkLimit)

        Task { [weak self] in
            guard let self, let streamer = self.streamer else { connection.cancel(); return }
            let chunk: Data
            do {
                chunk = try await streamer.readBytes(offset: offset, length: readLen)
            } catch {
                NSLog("[TSPlayerKit] Chunk read error: \(error)")
                connection.cancel()
                return
            }

            // Format: <hex-size>\r\n<data>\r\n
            let hexSize = String(format: "%X\r\n", chunk.count)
            guard let hexData = hexSize.data(using: .utf8) else {
                connection.cancel()
                return
            }

            var chunkMessage = Data()
            chunkMessage.append(hexData)
            chunkMessage.append(chunk)
            chunkMessage.append(Data("\r\n".utf8))

            connection.send(content: chunkMessage, completion: .contentProcessed { [weak self] error in
                if let error {
                    NSLog("[TSPlayerKit] Chunk send error: \(error)")
                    connection.cancel()
                    return
                }
                let newOffset = offset + UInt64(chunk.count)
                let newRemaining = remaining - UInt64(chunk.count)
                self?.sendNextChunk(
                    offset: newOffset,
                    remaining: newRemaining,
                    chunkLimit: chunkLimit,
                    on: connection
                )
            })
        }
    }

    // MARK: - HTTP response helpers

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

    private func sendError(statusCode: Int, on connection: NWConnection) {
        sendResponse(statusCode: statusCode, headers: [:], body: Data(), on: connection)
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
