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
        let url = HLSManifestGenerator.segmentURL(port: 8080)
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
        #expect(url.path == "/segment.ts")
    }

    @Test("Generated playlist contains required HLS tags")
    func playlistContainsRequiredTags() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, targetDuration: 30.0)

        #expect(playlist.contains("#EXTM3U"))
        #expect(playlist.contains("#EXT-X-VERSION:3"))
        #expect(playlist.contains("#EXT-X-TARGETDURATION:30"))
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(playlist.contains("#EXTINF:30.0,"))
        #expect(playlist.contains("http://127.0.0.1:9000/segment.ts"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
    }

    @Test("Generated playlist uses rounded-up target duration")
    func targetDurationRoundedUp() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, targetDuration: 9.3)
        // ceil(9.3) = 10
        #expect(playlist.contains("#EXT-X-TARGETDURATION:10"))
    }

    @Test("Generated playlist enforces minimum target duration of 1")
    func targetDurationMinimum() {
        let playlist = HLSManifestGenerator.generatePlaylist(port: 9000, targetDuration: 0.0)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:1"))
    }

    @Test("generatePlaylistData returns valid UTF-8 data")
    func playlistDataIsValidUTF8() {
        let data = HLSManifestGenerator.generatePlaylistData(port: 9000, targetDuration: 10.0)
        #expect(!data.isEmpty)
        let string = String(data: data, encoding: .utf8)
        #expect(string != nil)
        #expect(string!.contains("#EXTM3U"))
    }
}

// MARK: - FileStreamer Tests

@Suite("FileStreamer")
struct FileStreamerTests {

    /// Helper to create a temporary file with known content for testing.
    private func makeTempFile(content: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("tsplayerkit_test_\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    /// Helper to clean up a temporary file.
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
        for i in 0 ..< 256 {
            content[i] = UInt8(i)
        }
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)

        // Read bytes 100-149
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

        // Request 1000 bytes from a 5-byte file
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

        // Read starting exactly at the end
        let data = try await streamer.readBytes(offset: UInt64(content.count), length: 100)
        #expect(data.isEmpty)
    }

    @Test("Read with offset beyond EOF returns empty data")
    func readBeyondEOFReturnsEmpty() async throws {
        let content = Data("Data".utf8)
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)

        // Read starting past the end
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

    /// Helper to create a temporary file with known content for testing.
    private func makeTempFile(content: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("tsplayerkit_test_\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

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
        let responseString = String(data: data, encoding: .utf8) ?? ""
        #expect(responseString.contains("#EXTM3U"))
    }

    @Test("Server serves segment on /segment.ts")
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
}

// MARK: - TSPlayerItem Tests

@Suite("TSPlayerItem")
struct TSPlayerItemTests {

    @MainActor
    @Test("Initialization succeeds for a valid .ts file")
    func initWithValidTSFile() throws {
        // Create a minimal file (real .ts files start with 0x47 sync byte,
        // but FileStreamer doesn't validate content — any readable file works)
        let content = Data([0x47, 0x00, 0x10, 0x00]) // Minimal TS-like data
        let directory = FileManager.default.temporaryDirectory
        let tsURL = directory.appendingPathComponent("test_\(UUID().uuidString).ts")
        try content.write(to: tsURL)
        defer { try? FileManager.default.removeItem(at: tsURL) }

        let tsItem = try TSPlayerItem(tsFileURL: tsURL)
        let asset = tsItem.playerItem.asset as? AVURLAsset
        #expect(asset != nil)
        #expect(asset?.url.scheme == "http")
        #expect(asset?.url.host == "127.0.0.1")
        #expect(asset?.url.path == "/playlist.m3u8")
    }

    @Test("Initialization throws for non-existent file")
    func initWithNonExistentFile() {
        let badURL = URL(fileURLWithPath: "/nonexistent/video.ts")

        #expect(throws: FileStreamerError.self) {
            _ = try TSPlayerItem(tsFileURL: badURL)
        }
    }

    @MainActor
    @Test("TSPlayerItem with custom target duration initializes correctly")
    func initWithCustomTargetDuration() throws {
        let content = Data([0x47, 0x00, 0x10, 0x00])
        let directory = FileManager.default.temporaryDirectory
        let tsURL = directory.appendingPathComponent("test_\(UUID().uuidString).ts")
        try content.write(to: tsURL)
        defer { try? FileManager.default.removeItem(at: tsURL) }

        let tsItem = try TSPlayerItem(tsFileURL: tsURL, targetDuration: 60.0)
        #expect(tsItem.playerItem.asset is AVURLAsset)
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
