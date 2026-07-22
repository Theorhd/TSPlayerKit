import AVFoundation
import Foundation
import Testing
@testable import TSPlayerKit

// MARK: - HLSManifestGenerator Tests

@Suite("HLSManifestGenerator")
struct HLSManifestGeneratorTests {

    @Test("Manifest URL uses http scheme on loopback")
    func manifestURLScheme() {
        let url = HLSManifestGenerator.manifestURL(port: 8080)
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
        #expect(url.path == "/playlist.m3u8")
    }

    @Test("Segment URL uses http scheme on loopback")
    func segmentURLScheme() {
        let url = HLSManifestGenerator.segmentURL(port: 8080, index: 0)
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
        #expect(url.path == "/segment_0.ts")
    }

    @Test("Generated playlist contains required HLS tags")
    func playlistContainsRequiredTags() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, totalDuration: 30.0)

        #expect(playlist.contains("#EXTM3U"))
        #expect(playlist.contains("#EXT-X-VERSION:3"))
        #expect(playlist.contains("#EXT-X-TARGETDURATION:30"))
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(playlist.contains("#EXTINF:30.000,"))
        #expect(playlist.contains("http://127.0.0.1:9000/segment.ts"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
    }

    @Test("Generated playlist uses rounded-up target duration")
    func targetDurationRoundedUp() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, totalDuration: 9.3)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:10"))
    }

    @Test("Generated playlist enforces minimum target duration of 1")
    func targetDurationMinimum() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, totalDuration: 0.0)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:1"))
    }

    @Test("generatePlaylistData returns valid UTF-8 data")
    func playlistDataIsValidUTF8() {
        let data = HLSManifestGenerator.generatePlaylistData(port: 9000, totalDuration: 10.0)
        #expect(!data.isEmpty)
        let string = String(data: data, encoding: .utf8)
        #expect(string != nil)
        #expect(string!.contains("#EXTM3U"))
    }

    @Test("Multi-segment playlist contains indexed segment URLs")
    func multiSegmentPlaylist() {
        let segments = [
            SegmentInfo(offset: 0,        duration: 2.0, length: 188),
            SegmentInfo(offset: 188,      duration: 2.0, length: 188),
            SegmentInfo(offset: 376,      duration: 2.0, length: 188),
        ]
        let playlist = HLSManifestGenerator.generateMultiSegmentPlaylist(port: 9000, segments: segments)
        #expect(playlist.contains("http://127.0.0.1:9000/segment_0.ts"))
        #expect(playlist.contains("http://127.0.0.1:9000/segment_1.ts"))
        #expect(playlist.contains("http://127.0.0.1:9000/segment_2.ts"))
        #expect(playlist.contains("#EXT-X-TARGETDURATION:2"))
        #expect(playlist.contains("#EXTINF:2.000,"))
    }
}

// MARK: - FileStreamer Tests

@Suite("FileStreamer")
struct FileStreamerTests {

    private func makeTempFile(content: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("tsplayerkit_test_\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    private func removeTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Initialization succeeds for a valid file")
    func initWithValidFile() throws {
        let content = Data("Hello, TSPlayerKit!".utf8)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        #expect(streamer.fileSize == UInt64(content.count))
        #expect(streamer.fileURL == fileURL)
    }

    @Test("Initialization throws for a non-existent file")
    func initWithNonExistentFile() {
        let badURL = URL(fileURLWithPath: "/nonexistent/path/test.ts")
        #expect(throws: FileStreamerError.self) {
            _ = try FileStreamer(fileURL: badURL)
        }
    }

    @Test("Read full file returns complete content")
    func readFullFile() async throws {
        let content = Data(repeating: 0xAB, count: 1024)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let data = try await streamer.readBytes(offset: 0, length: 1024)
        #expect(data == content)
    }

    @Test("Read partial range returns correct slice")
    func readPartialRange() async throws {
        var content = Data(count: 256)
        for i in 0 ..< 256 { content[i] = UInt8(i) }
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let data = try await streamer.readBytes(offset: 100, length: 50)
        #expect(data.count == 50)
        for i in 0 ..< 50 {
            #expect(data[i] == UInt8(100 + i))
        }
    }

    @Test("Read with length exceeding remaining bytes clamps to EOF")
    func readLengthClampedToEOF() async throws {
        let content = Data("Short".utf8)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let data = try await streamer.readBytes(offset: 0, length: 1000)
        #expect(data.count == 5)
        #expect(data == content)
    }

    @Test("Read with offset at EOF returns empty data")
    func readAtEOFReturnsEmpty() async throws {
        let content = Data("Data".utf8)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let data = try await streamer.readBytes(offset: UInt64(content.count), length: 100)
        #expect(data.isEmpty)
    }

    @Test("Read with offset beyond EOF returns empty data")
    func readBeyondEOFReturnsEmpty() async throws {
        let content = Data("Data".utf8)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let data = try await streamer.readBytes(
            offset: UInt64(content.count) + 1000,
            length: 100
        )
        #expect(data.isEmpty)
    }
}

// MARK: - LocalHTTPServer Tests

@Suite("LocalHTTPServer")
struct LocalHTTPServerTests {

    private func makeTempFile(content: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("tsplayerkit_test_\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    // MARK: Legacy TS mode

    @Test("Server starts and exposes a valid port")
    func serverStartsWithValidPort() throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        defer { server.stop() }

        #expect(server.port > 0)
    }

    @Test("Server serves manifest on /playlist.m3u8")
    func serverServesManifest() async throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        defer { server.stop() }

        let manifest = "#EXTM3U\n#EXT-X-ENDLIST"
        server.setManifest(Data(manifest.utf8))

        let url = URL(string: "http://127.0.0.1:\(server.port)/playlist.m3u8")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)!.contains("#EXTM3U"))
    }

    @Test("Server serves segment on /segment.ts via chunked transfer")
    func serverServesSegment() async throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        defer { server.stop() }
        server.setManifest(Data())

        let url = URL(string: "http://127.0.0.1:\(server.port)/segment.ts")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        #expect(data == content)
    }

    @Test("Server handles Range requests with 206 Partial Content")
    func serverHandlesRangeRequests() async throws {
        var content = Data(count: 256)
        for i in 0 ..< 256 { content[i] = UInt8(i) }
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        defer { server.stop() }
        server.setManifest(Data())

        let url = URL(string: "http://127.0.0.1:\(server.port)/segment.ts")!
        var request = URLRequest(url: url)
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 206)
        #expect(data.count == 10)
        for i in 0 ..< 10 {
            #expect(data[i] == UInt8(10 + i))
        }
    }

    @Test("Server returns 404 for unknown routes")
    func serverReturns404ForUnknownRoutes() async throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        defer { server.stop() }
        server.setManifest(Data())

        let url = URL(string: "http://127.0.0.1:\(server.port)/nonexistent")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 404)
    }

    // MARK: Multi-segment TS mode

    @Test("Multi-segment server serves indexed segments")
    func multiSegmentServerServesSegments() async throws {
        // Create a file with 3 segments of 188 bytes each.
        let seg0 = Data(repeating: 0x47, count: 188)
        let seg1 = Data(repeating: 0x48, count: 188)
        let seg2 = Data(repeating: 0x49, count: 188)
        var content = Data()
        content.append(seg0); content.append(seg1); content.append(seg2)

        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let segments = [
            SegmentInfo(offset: 0,   duration: 2.0, length: 188),
            SegmentInfo(offset: 188, duration: 2.0, length: 188),
            SegmentInfo(offset: 376, duration: 2.0, length: 188),
        ]
        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer, segments: segments)
        defer { server.stop() }
        server.setManifest(Data())

        // Request segment 1
        let url = URL(string: "http://127.0.0.1:\(server.port)/segment_1.ts")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        #expect(data == seg1)
    }

    @Test("Multi-segment server returns 404 for out-of-range index")
    func multiSegmentServerOutOfRange() async throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let segments = [SegmentInfo(offset: 0, duration: 2.0, length: 188)]
        let streamer = try FileStreamer(fileURL: fileURL)
        let server = try LocalHTTPServer(streamer: streamer, segments: segments)
        defer { server.stop() }
        server.setManifest(Data())

        let url = URL(string: "http://127.0.0.1:\(server.port)/segment_99.ts")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 404)
    }

    // MARK: Directory mode (fMP4)

    @Test("Directory mode server serves index.m3u8 and segment files")
    func directoryModeServesFiles() async throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmp4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let m3u8Content = "#EXTM3U\n#EXTINF:2.0,\nsegment_0.m4s\n#EXT-X-ENDLIST"
        try m3u8Content.write(to: dirURL.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

        let segContent = Data(repeating: 0xAB, count: 1024)
        try segContent.write(to: dirURL.appendingPathComponent("segment_0.m4s"))

        let server = try LocalHTTPServer(directoryURL: dirURL)
        defer { server.stop() }

        // Request playlist
        let m3u8URL = URL(string: "http://127.0.0.1:\(server.port)/playlist.m3u8")!
        let (m3u8Data, m3u8Response) = try await URLSession.shared.data(from: m3u8URL)
        #expect((m3u8Response as! HTTPURLResponse).statusCode == 200)
        #expect(String(data: m3u8Data, encoding: .utf8)!.contains("#EXTM3U"))

        // Request segment
        let segURL = URL(string: "http://127.0.0.1:\(server.port)/segment_0.m4s")!
        let (segData, segResponse) = try await URLSession.shared.data(from: segURL)
        #expect((segResponse as! HTTPURLResponse).statusCode == 200)
        #expect(segData == segContent)
    }

    @Test("Directory mode returns 404 for missing files")
    func directoryModeMissingFiles() async throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmp4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let server = try LocalHTTPServer(directoryURL: dirURL)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/playlist.m3u8")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as! HTTPURLResponse).statusCode == 404)
    }
}

// MARK: - TSPlayerItem Tests

@Suite("TSPlayerItem")
struct TSPlayerItemTests {

    @MainActor
    @Test("Legacy TS init succeeds for valid file")
    func legacyInitWithValidFile() throws {
        let content = Data([0x47, 0x00, 0x10, 0x00])
        let directory = FileManager.default.temporaryDirectory
        let tsURL = directory.appendingPathComponent("test_\(UUID().uuidString).ts")
        try content.write(to: tsURL)
        defer { try? FileManager.default.removeItem(at: tsURL) }

        let tsItem = try TSPlayerItem(tsFileURL: tsURL, totalDuration: 10.0)
        let asset = tsItem.playerItem.asset as? AVURLAsset
        #expect(asset != nil)
        #expect(asset?.url.scheme == "http")
        #expect(asset?.url.host == "127.0.0.1")
        #expect(asset?.url.path == "/playlist.m3u8")
    }

    @Test("Legacy init throws for non-existent file")
    func legacyInitWithNonExistentFile() {
        let badURL = URL(fileURLWithPath: "/nonexistent/video.ts")
        #expect(throws: FileStreamerError.self) {
            _ = try TSPlayerItem(tsFileURL: badURL, totalDuration: 10.0)
        }
    }

    @MainActor
    @Test("Multi-segment TS init succeeds with valid segments")
    func multiSegmentInit() throws {
        let content = Data([0x47, 0x00, 0x10, 0x00, 0x48, 0x01, 0x11, 0x01])
        let directory = FileManager.default.temporaryDirectory
        let tsURL = directory.appendingPathComponent("test_\(UUID().uuidString).ts")
        try content.write(to: tsURL)
        defer { try? FileManager.default.removeItem(at: tsURL) }

        let segments = [
            SegmentInfo(offset: 0, duration: 2.0, length: 4),
            SegmentInfo(offset: 4, duration: 2.0, length: 4),
        ]
        let tsItem = try TSPlayerItem(tsFileURL: tsURL, segments: segments)
        #expect(tsItem.playerItem.asset is AVURLAsset)
    }

    @MainActor
    @Test("Multi-segment init throws with empty segments")
    func multiSegmentInitEmptySegments() {
        let content = Data([0x47, 0x00, 0x10, 0x00])
        let directory = FileManager.default.temporaryDirectory
        let tsURL = directory.appendingPathComponent("test_\(UUID().uuidString).ts")
        try? content.write(to: tsURL)
        defer { try? FileManager.default.removeItem(at: tsURL) }

        #expect(throws: TSPlayerItemError.self) {
            _ = try TSPlayerItem(tsFileURL: tsURL, segments: [])
        }
    }

    @MainActor
    @Test("fMP4 directory init succeeds with valid directory")
    func fmp4DirectoryInit() throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmp4_init_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        try "#EXTM3U\n#EXT-X-ENDLIST".write(to: dirURL.appendingPathComponent("index.m3u8"),
                                             atomically: true, encoding: .utf8)

        let tsItem = try TSPlayerItem(fmp4Directory: dirURL)
        let asset = tsItem.playerItem.asset as? AVURLAsset
        #expect(asset != nil)
        #expect(asset?.url.scheme == "http")
        #expect(asset?.url.path == "/playlist.m3u8")
    }
}

// MARK: - FileStreamerError Tests

@Suite("FileStreamerError")
struct FileStreamerErrorTests {

    @Test("Error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [FileStreamerError] = [
            .deinitialized,
            .offsetOutOfRange(offset: 100, fileSize: 50),
            .cannotOpenFile(URL(fileURLWithPath: "/test/path.ts")),
            .systemError(NSError(domain: "test", code: 1)),
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}
