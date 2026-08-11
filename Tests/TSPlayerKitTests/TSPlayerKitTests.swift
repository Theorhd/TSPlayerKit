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

    @Test("SegmentInfo with file field round-trips through JSON")
    func segmentInfoFileFieldJSONRoundTrip() throws {
        let segments = [
            SegmentInfo(offset: 0,    duration: 2.0, length: 188, file: "video_000.ts"),
            SegmentInfo(offset: 0,    duration: 2.0, length: 200, file: "video_001.ts"),
            SegmentInfo(offset: 200,  duration: 2.0, length: 188, file: "video_001.ts"),
        ]
        let encoder = JSONEncoder()
        let data = try encoder.encode(segments)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([SegmentInfo].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].file == "video_000.ts")
        #expect(decoded[1].file == "video_001.ts")
        #expect(decoded[2].file == "video_001.ts")
        #expect(decoded[0].offset == 0)
        #expect(decoded[1].offset == 0)   // new file, offset resets
        #expect(decoded[2].offset == 200) // same file, offset continues
    }

    @Test("SegmentInfo decodes nil file from old-format JSON")
    func segmentInfoNilFileBackwardCompat() throws {
        let oldJSON = """
        [{"offset":0,"duration":2.0,"length":188}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([SegmentInfo].self, from: oldJSON)
        #expect(decoded.count == 1)
        #expect(decoded[0].file == nil)
        #expect(decoded[0].offset == 0)
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

    // MARK: Multi-file TS mode

    @Test("Multi-file server serves segments from correct streamer")
    func multiFileServerServesFromCorrectFile() async throws {
        // Two files: file0 with 0xAA, file1 with 0xBB.
        let seg0 = Data(repeating: 0xAA, count: 200)
        let seg1 = Data(repeating: 0xBB, count: 200)
        let file0URL = try makeTempFile(content: seg0)
        let file1URL = try makeTempFile(content: seg1)
        defer {
            try? FileManager.default.removeItem(at: file0URL)
            try? FileManager.default.removeItem(at: file1URL)
        }

        let streamer0 = try FileStreamer(fileURL: file0URL)
        let streamer1 = try FileStreamer(fileURL: file1URL)

        let segments = [
            SegmentInfo(offset: 0, duration: 2.0, length: 200, file: file0URL.lastPathComponent),
            SegmentInfo(offset: 0, duration: 2.0, length: 200, file: file1URL.lastPathComponent),
        ]
        let server = try LocalHTTPServer(
            streamers: [file0URL.lastPathComponent: streamer0, file1URL.lastPathComponent: streamer1],
            segments: segments
        )
        defer { server.stop() }
        server.setManifest(Data())

        // Request segment 0 (should get 0xAA from file0).
        let url0 = URL(string: "http://127.0.0.1:\(server.port)/segment_0.ts")!
        let (data0, response0) = try await URLSession.shared.data(from: url0)
        #expect((response0 as! HTTPURLResponse).statusCode == 200)
        #expect(data0 == seg0)

        // Request segment 1 (should get 0xBB from file1).
        let url1 = URL(string: "http://127.0.0.1:\(server.port)/segment_1.ts")!
        let (data1, response1) = try await URLSession.shared.data(from: url1)
        #expect((response1 as! HTTPURLResponse).statusCode == 200)
        #expect(data1 == seg1)
    }

    @Test("Multi-file server returns 404 for out-of-range index")
    func multiFileServerOutOfRange() async throws {
        let content = Data(repeating: 0x47, count: 188)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let segments = [
            SegmentInfo(offset: 0, duration: 2.0, length: 188, file: fileURL.lastPathComponent),
        ]
        let server = try LocalHTTPServer(
            streamers: [fileURL.lastPathComponent: streamer],
            segments: segments
        )
        defer { server.stop() }
        server.setManifest(Data())

        let url = URL(string: "http://127.0.0.1:\(server.port)/segment_99.ts")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as! HTTPURLResponse).statusCode == 404)
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

    // MARK: Multi-file TS tests

    @MainActor
    @Test("Multi-file init succeeds with two files")
    func multiFileInit() throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multifile_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        // Create two TS files in the directory.
        let seg0 = Data(repeating: 0xAA, count: 200)
        let seg1 = Data(repeating: 0xBB, count: 200)
        try seg0.write(to: dirURL.appendingPathComponent("video_000.ts"))
        try seg1.write(to: dirURL.appendingPathComponent("video_001.ts"))

        let segments = [
            SegmentInfo(offset: 0,   duration: 2.0, length: 200, file: "video_000.ts"),
            SegmentInfo(offset: 0,   duration: 2.0, length: 200, file: "video_001.ts"),
        ]
        let tsItem = try TSPlayerItem(tsFilesDirectory: dirURL, segments: segments)
        let asset = tsItem.playerItem.asset as? AVURLAsset
        #expect(asset != nil)
        #expect(asset?.url.scheme == "http")
        #expect(asset?.url.host == "127.0.0.1")
        #expect(asset?.url.path == "/playlist.m3u8")
    }

    @MainActor
    @Test("Multi-file init throws with empty segments")
    func multiFileInitEmptySegments() {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multifile_empty_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        #expect(throws: TSPlayerItemError.self) {
            _ = try TSPlayerItem(tsFilesDirectory: dirURL, segments: [])
        }
    }

    @MainActor
    @Test("Multi-file init throws when segments lack file field")
    func multiFileInitMissingFileField() {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multifile_nofile_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let segments = [
            SegmentInfo(offset: 0, duration: 2.0, length: 200),  // file = nil
        ]
        #expect(throws: TSPlayerItemError.self) {
            _ = try TSPlayerItem(tsFilesDirectory: dirURL, segments: segments)
        }
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

// MARK: - HLSPlaylistCleaner Tests

@Suite("HLSPlaylistCleaner")
struct HLSPlaylistCleanerTests {

    let cleaner = HLSPlaylistCleaner()

    // ── Master playlist ──

    @Test("rewriteMasterPlaylist replaces variant URLs with proxy paths")
    func rewriteMasterVariants() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080
        https://cdn.example.com/chunked/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=1280x720
        https://cdn.example.com/720p/index.m3u8
        """

        let (rewritten, urls) = cleaner.rewriteMasterPlaylist(master, proxyBaseURL: "http://127.0.0.1:9999")

        #expect(rewritten.contains("/variant/0.m3u8"))
        #expect(rewritten.contains("/variant/1.m3u8"))
        #expect(!rewritten.contains("cdn.example.com"))
        #expect(urls.count == 2)
        #expect(urls[0] == "https://cdn.example.com/chunked/index.m3u8")
        #expect(urls[1] == "https://cdn.example.com/720p/index.m3u8")
    }

    @Test("rewriteMasterPlaylist rewrites #EXT-X-MEDIA URIs through proxy")
    func rewriteMasterMediaURI() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="https://cdn.example.com/audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        https://cdn.example.com/video/index.m3u8
        """

        let (rewritten, urls) = cleaner.rewriteMasterPlaylist(master, proxyBaseURL: "http://127.0.0.1:9999")

        // Audio URI rewritten (index 0), video URL rewritten (index 1) — document order.
        #expect(rewritten.contains("/variant/0.m3u8"))  // audio
        #expect(rewritten.contains("/variant/1.m3u8"))  // video
        #expect(urls.count == 2)
    }

    @Test("rewriteMasterPlaylist drops #EXT-X-I-FRAME-STREAM-INF lines")
    func rewriteMasterDropsIFrame() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        https://cdn.example.com/video.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50000,URI="https://cdn.example.com/iframe.m3u8"
        """

        let (rewritten, urls) = cleaner.rewriteMasterPlaylist(master, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(!rewritten.contains("I-FRAME"))
        #expect(urls.count == 1)
    }

    // ── Variant playlist cleaning (no ads) ──

    @Test("cleanVariantPlaylist rewrites segment URLs with proxy prefix")
    func cleanNoAds() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.000,
        0.ts
        #EXTINF:10.000,
        1.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.adSegmentCount == 0)
        #expect(!result.adReplaced)
        #expect(result.playlist.contains("seg/0/0.ts"))
        #expect(result.playlist.contains("seg/1/1.ts"))
        // The raw "0.ts" on its own line must not survive.
        #expect(!result.playlist.contains("\n0.ts\n"))
    }

    // ── CUE-OUT / CUE-IN ──

    @Test("cleanVariantPlaylist removes segments between CUE-OUT and CUE-IN")
    func cleanCueOutIn() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        0.ts
        #EXT-X-CUE-OUT:30.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXT-X-CUE-IN
        #EXTINF:2.000,
        3.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.adSegmentCount == 2)
        #expect(result.adReplaced)
        #expect(result.removedIndices.contains(1))
        #expect(result.removedIndices.contains(2))
        #expect(!result.removedIndices.contains(0))
        #expect(!result.removedIndices.contains(3))
        // Index 3 segment (original) survives but is now at rewritten position after removals;
        // it appears as /seg/3/3.ts (original index preserved).
        #expect(result.playlist.contains("/seg/3/3.ts"))
        #expect(!result.playlist.contains("ad1.ts"))
        #expect(result.playlist.contains("#EXT-X-DISCONTINUITY"))
    }

    // ── SCTE35-OUT with duration (no SCTE35-IN) — bounded removal ──

    @Test("cleanVariantPlaylist bounds ad removal by DATERANGE DURATION (no SCTE35-IN)")
    func cleanSCTE35OutBounded() {
        // Simulates the Twitch live case where SCTE35-OUT appears without
        // a matching SCTE35-IN in the same playlist window.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        0.ts
        #EXT-X-DATERANGE:ID="test",CLASS="scte35",SCTE35-OUT=12345,DURATION=6.0
        #EXTINF:2.000,
        1.ts
        #EXTINF:2.000,
        2.ts
        #EXTINF:2.000,
        3.ts
        #EXTINF:2.000,
        4.ts
        #EXTINF:2.000,
        5.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")

        // DURATION=6 → 3 × 2s segments removed, not everything after the marker.
        #expect(result.adSegmentCount == 3)
        #expect(result.removedIndices.contains(1))
        #expect(result.removedIndices.contains(2))
        #expect(result.removedIndices.contains(3))
        // Segments 0, 4, 5 must survive.
        #expect(!result.removedIndices.contains(0))
        #expect(!result.removedIndices.contains(4))
        #expect(!result.removedIndices.contains(5))
    }

    // ── Twitch stitched-ad ──

    @Test("cleanVariantPlaylist detects Twitch stitched-ad DATERANGE")
    func cleanTwitchStitchedAd() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        content1.ts
        #EXT-X-DATERANGE:ID="stitched-ad-1234567890",CLASS="twitch-stitched-ad",DURATION=4.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXTINF:2.000,
        content2.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.adSegmentCount == 2)
        #expect(result.removedIndices.contains(1))
        #expect(result.removedIndices.contains(2))
        #expect(!result.removedIndices.contains(0))
        #expect(!result.removedIndices.contains(3))
    }

    @Test("cleanVariantPlaylist handles stitched-ad without explicit DURATION (safety cap)")
    func cleanStitchedAdNoDuration() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        0.ts
        #EXT-X-DATERANGE:ID="stitched-ad-X",CLASS="twitch-stitched-ad"
        #EXTINF:2.000,
        1.ts
        #EXTINF:2.000,
        2.ts
        #EXTINF:2.000,
        3.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // Without DURATION the cap (180s) applies; 3 segments × 2s = 6s < 180s
        // — all three are removed.
        #expect(result.adSegmentCount == 3)
    }

    // ── Fail-open ──

    @Test("cleanVariantPlaylist fail-open: VOD with all segments removed disables blocking")
    func cleanFailOpenVOD() {
        // VOD (has ENDLIST) where every segment somehow matches an ad pattern.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-CUE-OUT:999.0
        #EXTINF:2.000,
        0.ts
        #EXTINF:2.000,
        1.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // All 2 segments removed → 100% → fail-open → no removal on a VOD.
        #expect(result.adSegmentCount == 0)
        #expect(!result.adReplaced)
    }

    @Test("cleanVariantPlaylist live stream with full-ad window keeps removal")
    func cleanLiveFullAdWindow() {
        // Live (no ENDLIST): entire window is ads — legit, keep removal.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-CUE-OUT:30.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // Live — keep removal. Empty playlist → AVPlayer polls again.
        #expect(result.adSegmentCount == 2)
    }

    // ── URL-pattern detection ──

    @Test("cleanVariantPlaylist detects ad CDN URL patterns")
    func cleanURLPatternAds() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        content.ts
        #EXTINF:2.000,
        https://cdn.example.com/ads/ad-segment.ts
        #EXTINF:2.000,
        content2.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.adSegmentCount == 1)
        #expect(result.removedIndices.contains(1))
    }

    // ── Duration anomalies ──

    @Test("cleanVariantPlaylist flags run of anomalous-duration segments")
    func cleanDurationAnomalies() {
        // Normal segments: 2s. Ad run: 2 consecutive 6s segments.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:2.000,
        0.ts
        #EXTINF:2.000,
        1.ts
        #EXTINF:6.000,
        2.ts
        #EXTINF:6.000,
        3.ts
        #EXTINF:2.000,
        4.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // The two 6s segments should be flagged as an ad run.
        #expect(result.removedIndices.contains(2))
        #expect(result.removedIndices.contains(3))
        #expect(!result.removedIndices.contains(4))
    }

    @Test("cleanVariantPlaylist does not flag single anomalous-duration segment")
    func cleanSingleAnomalyNotAd() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:2.000,
        0.ts
        #EXTINF:6.000,
        1.ts
        #EXTINF:2.000,
        2.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // A single anomalous segment is not a run — not flagged.
        #expect(!result.removedIndices.contains(1))
    }

    // ── LL-HLS tag stripping ──

    @Test("cleanVariantPlaylist strips low-latency HLS tags but keeps degraded SERVER-CONTROL")
    func cleanStripsLLHLSTags() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0
        #EXT-X-PART-INF:PART-TARGET=1.0
        #EXTINF:2.000,
        0.ts
        #EXT-X-PART:DURATION=1.0,URI="part0.ts"
        #EXTINF:2.000,
        1.ts
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="hint.ts"
        #EXT-X-RENDITION-REPORT:URI="../variant.m3u8",LAST-MSN=1
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // SERVER-CONTROL is preserved, but CAN-BLOCK-RELOAD is forced to NO.
        #expect(result.playlist.contains("CAN-BLOCK-RELOAD=NO"))
        #expect(!result.playlist.contains("CAN-BLOCK-RELOAD=YES"))
        // PART-INF is kept (harmless metadata — not a content part).
        #expect(result.playlist.contains("#EXT-X-PART-INF"))
        // Content-carrying PART entries, PRELOAD-HINT, and RENDITION-REPORT are stripped.
        #expect(!result.playlist.contains("#EXT-X-PART:"))
        #expect(!result.playlist.contains("PRELOAD-HINT"))
        #expect(!result.playlist.contains("RENDITION-REPORT"))
        // Content segments survive.
        #expect(result.playlist.contains("seg/0/0.ts"))
        #expect(result.playlist.contains("seg/1/1.ts"))
        #expect(result.adSegmentCount == 0)
    }

    // ── Twitch tag stripping ──

    @Test("cleanVariantPlaylist strips Twitch-private tags")
    func cleanStripsTwitchTags() {
        let variant = """
        #EXTM3U
        #EXT-X-TWITCH-ELAPSED-SECS:30.0
        #EXT-X-TWITCH-TOTAL-SECS:120.0
        #EXTINF:10.000,
        0.ts
        #EXT-X-PREFETCH:https://cdn.example.com/1.ts
        #EXTINF:10.000,
        1.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(!result.playlist.contains("TWITCH-ELAPSED"))
        #expect(!result.playlist.contains("TWITCH-TOTAL"))
        #expect(!result.playlist.contains("#EXT-X-PREFETCH"))
        #expect(result.adSegmentCount == 0)
    }

    // ── #EXT-X-MAP (fMP4 init) rewriting ──

    @Test("cleanVariantPlaylist rewrites #EXT-X-MAP URIs through proxy")
    func cleanRewritesMapURI() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.000,
        seg0.m4s
        #EXTINF:4.000,
        seg1.m4s
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.playlist.contains("/init/0/init.mp4"))
        #expect(!result.playlist.contains("URI=\"init.mp4\""))
    }

    // ── Discontinuity insertion ──

    @Test("cleanVariantPlaylist inserts DISCONTINUITY after ad block")
    func cleanDiscontinuityAfterAd() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        before.ts
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXT-X-CUE-IN
        #EXTINF:2.000,
        after.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.playlist.contains("#EXT-X-DISCONTINUITY"))
        // The DISCONTINUITY sits between the surviving before and after segments.
        let lines = result.playlist.components(separatedBy: .newlines)
        let discIdx = lines.firstIndex(of: "#EXT-X-DISCONTINUITY")
        #expect(discIdx != nil)
        let beforeIdx = lines.firstIndex(where: { $0.contains("before.ts") })
        let afterIdx = lines.firstIndex(where: { $0.contains("after.ts") })
        #expect(beforeIdx != nil)
        #expect(afterIdx != nil)
        #expect(discIdx! > beforeIdx!)
        #expect(discIdx! < afterIdx!)
    }

    // ── segmentFilename ──

    @Test("segmentFilename strips query string")
    func segmentFilenameStripsQuery() {
        #expect(HLSPlaylistCleaner.segmentFilename("0.ts?sig=abc") == "0.ts")
        #expect(HLSPlaylistCleaner.segmentFilename("https://cdn.example.com/path/0.ts?token=x") == "0.ts")
        #expect(HLSPlaylistCleaner.segmentFilename("https://cdn.example.com/path/0.ts") == "0.ts")
    }

    // ── CUE-OUT without duration (bare marker) ──

    @Test("cleanVariantPlaylist bare CUE-OUT uses safety cap")
    func cleanBareCueOut() {
        // #EXT-X-CUE-OUT with no colon value and no DURATION — safety cap 180s.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        0.ts
        #EXT-X-CUE-OUT
        #EXTINF:2.000,
        1.ts
        #EXTINF:2.000,
        2.ts
        #EXTINF:2.000,
        3.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        #expect(result.adSegmentCount == 3)
    }

    // ── KEY URI left intact ──

    @Test("cleanVariantPlaylist leaves #EXT-X-KEY URIs untouched")
    func cleanKeyURIIntact() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"
        #EXTINF:4.000,
        seg0.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // KEY URI is NOT rewritten — AVPlayer fetches it directly.
        #expect(result.playlist.contains("URI=\"https://cdn.example.com/key.bin\""))
    }
}

