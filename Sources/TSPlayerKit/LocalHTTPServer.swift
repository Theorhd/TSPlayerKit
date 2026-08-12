import Foundation
import Network

enum LocalHTTPServerError: Error, LocalizedError {
    case listenerFailed(Error)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let error):
            return "Local HTTP listener failed: \(error.localizedDescription)"
        }
    }
}

final class LocalHTTPServer: @unchecked Sendable {

    private enum Mode {
        case legacyTS(streamer: FileStreamer)
        case multiSegmentTS(streamer: FileStreamer, segments: [SegmentInfo])
        case multiFileTS(streamers: [String: FileStreamer], segments: [SegmentInfo])
        case staticDirectory(url: URL)
    }

    private(set) var port: UInt16 = 0

    private let mode: Mode
    private var manifestData = Data()
    private let manifestLock = NSLock()
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.tsplayerkit.localserver", qos: .userInitiated)
    private let readySemaphore = DispatchSemaphore(value: 0)
    /// Accepted connections, so `stop()` can close them (listener.cancel() does not).
    private let connectionsLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

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

    init(streamers: [String: FileStreamer], segments: [SegmentInfo]) throws {
        mode = .multiFileTS(streamers: streamers, segments: segments)
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
        catch { throw LocalHTTPServerError.listenerFailed(error) }

        let failure = HTTPServerCommon.FailureBox()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port { self.port = p.rawValue }
                self.readySemaphore.signal()
            case .failed(let error):
                NSLog("[TSPlayerKit] Listener failed: \(error)")
                failure.set(error)
                self.readySemaphore.signal()
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
            throw LocalHTTPServerError.listenerFailed(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let connections = connectionsLock.withLock { () -> [NWConnection] in
            let c = Array(activeConnections.values)
            activeConnections.removeAll()
            return c
        }
        for connection in connections { connection.cancel() }
    }

    private func handleConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connectionsLock.withLock { _ = activeConnections[key] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                NSLog("[TSPlayerKit] Connection failed: \(error)")
                connectionsLock.withLock { _ = activeConnections.removeValue(forKey: key) }
                connection.cancel()
            case .cancelled:
                connectionsLock.withLock { _ = activeConnections.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
        receiveRequest(from: connection)
    }

    private func receiveRequest(from connection: NWConnection) {
        HTTPServerCommon.receiveRequest(
            on: connection,
            queue: serverQueue,
            idleTimeout: HTTPServerCommon.idleConnectionTimeout,
            maxHeadSize: HTTPServerCommon.maxRequestHeadSize,
            onHead: { [weak self] head in self?.processRequest(headers: head, on: connection) },
            onOversize: { HTTPServerCommon.sendQuick(431, on: connection) },
            onError: { error in NSLog("[TSPlayerKit] Receive: \(error)") }
        )
    }

    private func processRequest(headers: Data, on connection: NWConnection) {
        guard let head = HTTPServerCommon.parseHead(headers),
              let path = HTTPServerCommon.requestPath(from: head.line)
        else { HTTPServerCommon.sendQuick(400, on: connection); return }

        let rangeHeader = HTTPServerCommon.headerValue("Range", in: head.raw)

        switch mode {
        case .staticDirectory(let dirURL):
            if path == "/playlist.m3u8" {
                serveFile(at: dirURL.appendingPathComponent("index.m3u8"),
                          contentType: "application/vnd.apple.mpegurl", on: connection)
            } else {
                // Percent-decode, then refuse anything escaping the served
                // directory (`GET /../../etc/passwd` must not resolve).
                let decoded = String(path.dropFirst()).removingPercentEncoding ?? ""
                guard !decoded.isEmpty else { HTTPServerCommon.sendQuick(404, on: connection); return }
                let root = dirURL.standardizedFileURL
                let resolved = root.appendingPathComponent(decoded).standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else {
                    HTTPServerCommon.sendQuick(403, on: connection); return
                }
                serveFile(at: resolved, contentType: Self.contentType(for: resolved), on: connection)
            }
        case .legacyTS(let streamer):
            switch path {
            case "/playlist.m3u8": serveManifest(on: connection)
            case "/segment.ts":    serveLegacySegment(streamer: streamer, rangeHeader: rangeHeader, on: connection)
            default:               HTTPServerCommon.sendQuick(404, on: connection)
            }
        case .multiSegmentTS(let streamer, let segments):
            switch path {
            case "/playlist.m3u8": serveManifest(on: connection)
            default:
                if let idx = parseSegmentIndex(from: path) {
                    serveSegment(streamer: streamer, segments: segments, index: idx,
                                 rangeHeader: rangeHeader, on: connection)
                } else { HTTPServerCommon.sendQuick(404, on: connection) }
            }
        case .multiFileTS(let streamers, let segments):
            switch path {
            case "/playlist.m3u8": serveManifest(on: connection)
            default:
                if let idx = parseSegmentIndex(from: path), idx < segments.count {
                    let seg = segments[idx]
                    guard let filename = seg.file, let streamer = streamers[filename] else {
                        HTTPServerCommon.sendQuick(500, on: connection); return
                    }
                    serveSegment(streamer: streamer, segments: segments, index: idx,
                                 rangeHeader: rangeHeader, on: connection)
                } else { HTTPServerCommon.sendQuick(404, on: connection) }
            }
        }
    }

    private func serveManifest(on connection: NWConnection) {
        manifestLock.lock(); let data = manifestData; manifestLock.unlock()
        HTTPServerCommon.sendResponse(status: 200, fields: [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(data.count)", "Cache-Control": "no-cache",
        ], body: data, on: connection)
    }

    private func serveFile(at fileURL: URL, contentType: String, on connection: NWConnection) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            HTTPServerCommon.sendQuick(404, on: connection); return
        }
        // Reads happen on the FileStreamer's own queue (via Task), never on
        // serverQueue — a slow disk must not stall every other connection.
        guard let streamer = try? FileStreamer(fileURL: fileURL) else {
            HTTPServerCommon.sendQuick(500, on: connection); return
        }
        if size <= Self.maxDirect {
            Task {
                guard let data = try? await streamer.readBytes(offset: 0, length: size) else {
                    HTTPServerCommon.sendQuick(500, on: connection); return
                }
                HTTPServerCommon.sendResponse(status: 200, fields: [
                    "Content-Type": contentType, "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
                ], body: data, on: connection)
            }
        } else {
            // Large file: stream via chunked transfer, 1 MB at a time.
            let head = HTTPServerCommon.responseHead(status: 200, fields: [
                "Content-Type": contentType, "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ], chunked: true)
            guard let headData = head.data(using: .utf8) else { connection.cancel(); return }
            connection.send(content: headData,
                            completion: .contentProcessed { [weak self] _ in
                                self?.sendNextLegacyChunk(streamer: streamer, offset: 0,
                                                          remaining: size, on: connection)
                            })
        }
    }

    private func parseSegmentIndex(from path: String) -> Int? {
        guard path.hasPrefix("/segment_"), path.hasSuffix(".ts") else { return nil }
        let s = path.index(path.startIndex, offsetBy: 9)
        let e = path.index(path.endIndex, offsetBy: -3)
        return s < e ? Int(path[s..<e]) : nil
    }

    /// Content type by file extension for the static directory mode (fMP4
    /// segments are `video/mp4`, not MPEG-TS).
    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "m4s", "mp4": "video/mp4"
        case "ts": "video/mp2t"
        case "aac": "audio/aac"
        default: "application/octet-stream"
        }
    }

    private func serveSegment(streamer: FileStreamer, segments: [SegmentInfo], index: Int,
                              rangeHeader: String?, on connection: NWConnection) {
        guard index < segments.count, segments[index].length > 0 else {
            HTTPServerCommon.sendQuick(404, on: connection); return
        }
        let seg = segments[index]

        let range = HTTPServerCommon.parseRange(rangeHeader)
        guard let resolved = HTTPServerCommon.resolve(range, size: seg.length) else {
            HTTPServerCommon.sendResponse(status: 416, fields: [
                "Content-Range": "bytes */\(seg.length)",
            ], body: Data(), on: connection)
            return
        }
        let start = seg.offset + resolved.start
        let end = seg.offset + resolved.end

        Task {
            guard let data = try? await streamer.readBytes(offset: start, length: resolved.length) else {
                HTTPServerCommon.sendQuick(500, on: connection); return
            }
            var fields: [String: String] = [
                "Content-Type": "video/mp2t", "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ]
            if resolved.isRange { fields["Content-Range"] = "bytes \(start)-\(end)/\(streamer.fileSize)" }
            HTTPServerCommon.sendResponse(status: resolved.isRange ? 206 : 200, fields: fields,
                                          body: data, on: connection)
        }
    }

    /// Serves the full TS file via chunked transfer encoding (1 MB chunks).
    /// Avoids the old 8 MB cap that caused ~6-second playback truncation.
    /// Range requests (≤ 16 MB) are served directly with 206 + Content-Range;
    /// larger ones are streamed with the same 206 head; full requests stream as 200.
    private func serveLegacySegment(streamer: FileStreamer, rangeHeader: String?,
                                     on connection: NWConnection) {
        let fileSize = streamer.fileSize
        guard fileSize > 0 else { HTTPServerCommon.sendQuick(500, on: connection); return }

        let range = HTTPServerCommon.parseRange(rangeHeader)
        guard let resolved = HTTPServerCommon.resolve(range, size: fileSize) else {
            HTTPServerCommon.sendResponse(status: 416, fields: [
                "Content-Range": "bytes */\(fileSize)",
            ], body: Data(), on: connection)
            return
        }
        let start = resolved.start, requested = resolved.length

        if resolved.isRange && requested <= Self.maxDirect {
            Task {
                guard let data = try? await streamer.readBytes(offset: start, length: requested) else {
                    HTTPServerCommon.sendQuick(500, on: connection); return
                }
                HTTPServerCommon.sendResponse(status: 206, fields: [
                    "Content-Type": "video/mp2t", "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
                    "Content-Range": "bytes \(start)-\(resolved.end)/\(fileSize)",
                ], body: data, on: connection)
            }
        } else {
            var fields: [String: String] = [
                "Content-Type": "video/mp2t", "Accept-Ranges": "bytes", "Cache-Control": "no-cache",
            ]
            if resolved.isRange {
                fields["Content-Range"] = "bytes \(start)-\(resolved.end)/\(fileSize)"
            }
            let head = HTTPServerCommon.responseHead(status: resolved.isRange ? 206 : 200,
                                                     fields: fields, chunked: true)
            guard let headData = head.data(using: .utf8) else { connection.cancel(); return }
            connection.send(content: headData,
                            completion: .contentProcessed { [weak self] _ in
                                self?.sendNextLegacyChunk(streamer: streamer, offset: start,
                                                          remaining: requested, on: connection)
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

}
