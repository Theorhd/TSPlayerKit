import Foundation
import Network

final class LocalHTTPServer: @unchecked Sendable {

    private enum Mode {
        case legacyTS(streamer: FileStreamer)
        case multiSegmentTS(streamer: FileStreamer, segments: [SegmentInfo])
        case staticDirectory(url: URL)
    }

    private(set) var port: UInt16 = 0

    private let mode: Mode
    private var manifestData = Data()
    private let manifestLock = NSLock()
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.tsplayerkit.localserver", qos: .userInitiated)
    private let readySemaphore = DispatchSemaphore(value: 0)

    private static let chunkLimit = 1024 * 1024       // 1 MB
    private static let maxDirect  = 16 * 1024 * 1024  // 16 MB

    init(streamer: FileStreamer) throws {
        mode = .legacyTS(streamer: streamer)
        try start()
    }

    init(streamer: FileStreamer, segments: [SegmentInfo]) throws {
        mode = .multiSegmentTS(streamer: streamer, segments: segments)
        try start()
    }

    init(directoryURL: URL) throws {
        mode = .staticDirectory(url: directoryURL)
        try start()
    }

    deinit { stop() }

    func setManifest(_ data: Data) {
        manifestLock.lock(); manifestData = data; manifestLock.unlock()
    }

    private func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do { listener = try NWListener(using: params) }
        catch { throw FileStreamerError.systemError(error) }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port { self.port = p.rawValue }
                self.readySemaphore.signal()
            case .failed(let error):
                NSLog("[TSPlayerKit] Listener failed: \(error)")
                self.readySemaphore.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        listener.start(queue: serverQueue)
        self.listener = listener
        readySemaphore.wait()
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveRequest(from: connection)
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { NSLog("[TSPlayerKit] Receive: \(error)"); connection.cancel(); return }
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
              let path = requestLine.components(separatedBy: " ").dropFirst().first
        else { sendQuick(400, on: connection); return }

        let rangeHeader = extractHeader("Range", from: raw)

        switch mode {
        case .staticDirectory(let dirURL):
            if path == "/playlist.m3u8" {
                serveFile(at: dirURL.appendingPathComponent("index.m3u8"),
                          contentType: "application/vnd.apple.mpegurl", on: connection)
            } else {
                serveFile(at: dirURL.appendingPathComponent(String(path.dropFirst())),
                          contentType: "video/mp2t", on: connection)
            }
        case .legacyTS(let streamer):
            switch path {
            case "/playlist.m3u8": serveManifest(on: connection)
            case "/segment.ts":    serveLegacySegment(streamer: streamer, rangeHeader: rangeHeader, on: connection)
            default:               sendQuick(404, on: connection)
            }
        case .multiSegmentTS(let streamer, let segments):
            switch path {
            case "/playlist.m3u8": serveManifest(on: connection)
            default:
                if let idx = parseSegmentIndex(from: path) {
                    serveSegment(streamer: streamer, segments: segments, index: idx,
                                 rangeHeader: rangeHeader, on: connection)
                } else { sendQuick(404, on: connection) }
            }
        }
    }

    private func serveManifest(on connection: NWConnection) {
        manifestLock.lock(); let data = manifestData; manifestLock.unlock()
        send(status: 200, body: data, extraHeaders: [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(data.count)", "Cache-Control": "no-cache",
        ], on: connection)
    }

    private func serveFile(at fileURL: URL, contentType: String, on connection: NWConnection) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            sendQuick(404, on: connection); return
        }
        if size <= Self.maxDirect, let data = try? Data(contentsOf: fileURL) {
            send(status: 200, body: data, extraHeaders: [
                "Content-Type": contentType, "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ], on: connection)
        } else {
            // Large file: stream via chunked transfer, reading sequentially from one FileHandle.
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                sendQuick(500, on: connection); return
            }
            let done: @Sendable () -> Void = { _ = try? handle.close() }
            let head = httpHead(status: 200, fields: [
                "Content-Type": contentType, "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ])
            guard let headData = head.data(using: .utf8) else { connection.cancel(); done(); return }
            connection.send(content: headData,
                            completion: .contentProcessed { [weak self] _ in self?.sendStaticChunks(handle: handle, on: connection, done: done) })
        }
    }

    private func sendStaticChunks(handle: FileHandle, on connection: NWConnection, done: @escaping () -> Void) {
        let data = handle.readData(ofLength: Self.chunkLimit)
        guard !data.isEmpty else {
            connection.send(content: Data("0\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel(); done() })
            return
        }
        let hex = String(format: "%X\r\n", data.count)
        guard let hexData = hex.data(using: .utf8) else { connection.cancel(); done(); return }
        var msg = Data(); msg.append(hexData); msg.append(data); msg.append(Data("\r\n".utf8))
        connection.send(content: msg,
                        completion: .contentProcessed { [weak self] _ in self?.sendStaticChunks(handle: handle, on: connection, done: done) })
    }

    private func parseSegmentIndex(from path: String) -> Int? {
        guard path.hasPrefix("/segment_"), path.hasSuffix(".ts") else { return nil }
        let s = path.index(path.startIndex, offsetBy: 9)
        let e = path.index(path.endIndex, offsetBy: -3)
        return s < e ? Int(path[s..<e]) : nil
    }

    private func serveSegment(streamer: FileStreamer, segments: [SegmentInfo], index: Int,
                              rangeHeader: String?, on connection: NWConnection) {
        guard index < segments.count else { sendQuick(404, on: connection); return }
        let seg = segments[index]
        let segStart = seg.offset, segEnd = seg.offset + seg.length - 1
        var start = segStart, end = segEnd, isRange = false

        if let rh = rangeHeader, rh.lowercased().hasPrefix("bytes=") {
            isRange = true
            let spec = String(rh.dropFirst(6))
            let bounds = spec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) { start = segStart + sv }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) { end = min(segStart + ev, segEnd) }
            end = min(end, segEnd); start = max(start, segStart)
        }

        Task {
            guard let data = try? await streamer.readBytes(offset: start, length: end - start + 1) else {
                sendQuick(500, on: connection); return
            }
            var hdrs: [String: String] = [
                "Content-Type": "video/mp2t", "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ]
            if isRange { hdrs["Content-Range"] = "bytes \(start)-\(end)/\(streamer.fileSize)" }
            send(status: isRange ? 206 : 200, body: data, extraHeaders: hdrs, on: connection)
        }
    }

    /// Serves the full TS file via chunked transfer encoding (1 MB chunks).
    /// Avoids the old 8 MB cap that caused ~6-second playback truncation.
    /// Small Range requests (≤ 16 MB) are served directly; everything else streams.
    private func serveLegacySegment(streamer: FileStreamer, rangeHeader: String?,
                                     on connection: NWConnection) {
        let fileSize = streamer.fileSize
        guard fileSize > 0 else { sendQuick(500, on: connection); return }

        var start: UInt64 = 0, end: UInt64 = fileSize - 1
        let isRange = (rangeHeader != nil)

        if let rh = rangeHeader, rh.lowercased().hasPrefix("bytes=") {
            let spec = String(rh.dropFirst(6))
            let bounds = spec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) { start = sv }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) { end = ev }
            end = min(end, fileSize - 1)
        }

        let requested = end - start + 1

        if isRange && requested <= Self.maxDirect {
            Task {
                guard let data = try? await streamer.readBytes(offset: start, length: requested) else {
                    sendQuick(500, on: connection); return
                }
                send(status: 206, body: data, extraHeaders: [
                    "Content-Type": "video/mp2t", "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
                    "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                ], on: connection)
            }
        } else {
            let head = httpHead(status: 200, fields: [
                "Content-Type": "video/mp2t", "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ])
            guard let headData = head.data(using: .utf8) else { connection.cancel(); return }
            let captureStart = start, captureRequested = requested
            connection.send(content: headData,
                            completion: .contentProcessed { [weak self] _ in
                                self?.sendNextLegacyChunk(streamer: streamer, offset: captureStart,
                                                          remaining: captureRequested, on: connection)
                            })
        }
    }

    private func sendNextLegacyChunk(streamer: FileStreamer, offset: UInt64, remaining: UInt64,
                                      on connection: NWConnection) {
        guard remaining > 0 else {
            connection.send(content: Data("0\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let readLen = min(remaining, UInt64(Self.chunkLimit))
        Task {
            guard let chunk = try? await streamer.readBytes(offset: offset, length: readLen), !chunk.isEmpty else {
                connection.cancel(); return
            }
            let hex = String(format: "%X\r\n", chunk.count)
            guard let hexData = hex.data(using: .utf8) else { connection.cancel(); return }
            var msg = Data(); msg.append(hexData); msg.append(chunk); msg.append(Data("\r\n".utf8))
            connection.send(content: msg,
                            completion: .contentProcessed { [weak self] _ in
                                self?.sendNextLegacyChunk(streamer: streamer,
                                                          offset: offset + UInt64(chunk.count),
                                                          remaining: remaining - UInt64(chunk.count),
                                                          on: connection)
                            })
        }
    }

    private func httpHead(status: Int, fields: [String: String]) -> String {
        var s = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in fields { s += "\(k): \(v)\r\n" }
        s += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        return s
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
        case 200: "OK"; case 206: "Partial Content"
        case 400: "Bad Request"; case 404: "Not Found"
        case 500: "Internal Server Error"; default: "Unknown"
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
