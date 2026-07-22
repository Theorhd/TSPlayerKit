import Foundation
import Network

/// Minimal local HTTP server serving a virtual HLS manifest and TS file bytes over loopback.
final class LocalHTTPServer: @unchecked Sendable {

    private(set) var port: UInt16 = 0
    private var manifestData: Data = Data()
    private let manifestLock = NSLock()
    private let streamer: FileStreamer
    private var listener: NWListener?

    private let serverQueue = DispatchQueue(
        label: "com.tsplayerkit.localserver",
        qos: .userInitiated
    )

    // Blocks init until NWListener is ready and port is assigned.
    private let readySemaphore = DispatchSemaphore(value: 0)

    init(streamer: FileStreamer) throws {
        self.streamer = streamer
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
            serveSegment(rangeHeader: rangeHeader, on: connection)
        default:
            sendResponse(statusCode: 404, headers: [:], body: Data(), on: connection)
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

    // Parses HTTP Range headers ("bytes=start-end") for AVPlayer seeking and returns 206 Partial Content.
    private func serveSegment(rangeHeader: String?, on connection: NWConnection) {
        let fileSize = streamer.fileSize

        guard fileSize > 0 else {
            sendResponse(statusCode: 500, headers: [:], body: Data(), on: connection)
            return
        }

        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1
        var isRangeRequest = false

        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            isRangeRequest = true
            let rangeSpec = String(range.dropFirst("bytes=".count))
            let bounds = rangeSpec.components(separatedBy: "-")
            if let s = bounds.first, !s.isEmpty, let sv = UInt64(s) { start = sv }
            if bounds.count > 1, let e = bounds.last, !e.isEmpty, let ev = UInt64(e) {
                end = ev
            }
            end = min(end, fileSize - 1)
        }

        let length = end - start + 1

        Task { [streamer] in
            do {
                let data = try await streamer.readBytes(offset: start, length: length)
                let statusCode = isRangeRequest ? 206 : 200
                var responseHeaders: [String: String] = [
                    "Content-Type": "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache",
                ]
                if isRangeRequest {
                    responseHeaders["Content-Range"] =
                        "bytes \(start)-\(end)/\(fileSize)"
                }
                self.sendResponse(
                    statusCode: statusCode,
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
