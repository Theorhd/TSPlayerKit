import AVFoundation
import Foundation
import Network
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

    @Test("Concurrent reads over one streamer return correct slices")
    func concurrentReadsReturnCorrectSlices() async throws {
        // Distinct byte values per position so any slice mix-up is caught.
        var content = Data(count: 1_000_000)
        for i in 0 ..< content.count { content[i] = UInt8(i % 251) }
        let fileURL = try makeTempFile(content: content)
        defer { removeTempFile(at: fileURL) }

        let streamer = try FileStreamer(fileURL: fileURL)
        let sliceSize = 100_000
        await withTaskGroup(of: (Int, Data?).self) { group in
            for i in 0 ..< 10 {
                group.addTask {
                    let data = try? await streamer.readBytes(
                        offset: UInt64(i * sliceSize), length: UInt64(sliceSize)
                    )
                    return (i, data)
                }
            }
            for await (i, data) in group {
                guard let data else { Issue.record("read \(i) failed"); continue }
                let expected = content.subdata(in: i * sliceSize ..< (i + 1) * sliceSize)
                #expect(data == expected, "slice \(i) mismatched")
            }
        }
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

    // MARK: Range hardening

    private func rangeRequest(port: UInt16, path: String, range: String) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    @Test("Inverted range (bytes=100-50) returns 416, no crash")
    func invertedRangeReturns416() async throws {
        var content = Data(count: 256)
        for i in 0 ..< 256 { content[i] = UInt8(i) }
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let server = try LocalHTTPServer(streamer: try FileStreamer(fileURL: fileURL))
        defer { server.stop() }
        server.setManifest(Data())

        let (_, response) = try await rangeRequest(port: server.port, path: "/segment.ts", range: "bytes=100-50")
        #expect(response.statusCode == 416)
        #expect(response.allHeaderFields["Content-Range"] as? String == "bytes */256")

        // The server is still alive after the malformed request.
        let (data, ok) = try await rangeRequest(port: server.port, path: "/segment.ts", range: "bytes=0-9")
        #expect(ok.statusCode == 206)
        #expect(data.count == 10)
    }

    @Test("Range starting past EOF returns 416, no underflow")
    func rangePastEndReturns416() async throws {
        let content = Data(repeating: 0x47, count: 256)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let server = try LocalHTTPServer(streamer: try FileStreamer(fileURL: fileURL))
        defer { server.stop() }
        server.setManifest(Data())

        let (_, response) = try await rangeRequest(port: server.port, path: "/segment.ts", range: "bytes=99999999-")
        #expect(response.statusCode == 416)

        let (_, closed) = try await rangeRequest(port: server.port, path: "/segment.ts", range: "bytes=300-400")
        #expect(closed.statusCode == 416)
    }

    @Test("Suffix range (bytes=-N) returns the LAST N bytes")
    func suffixRangeReturnsLastBytes() async throws {
        var content = Data(count: 256)
        for i in 0 ..< 256 { content[i] = UInt8(i) }
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let server = try LocalHTTPServer(streamer: try FileStreamer(fileURL: fileURL))
        defer { server.stop() }
        server.setManifest(Data())

        let (data, response) = try await rangeRequest(port: server.port, path: "/segment.ts", range: "bytes=-50")
        #expect(response.statusCode == 206)
        #expect(response.allHeaderFields["Content-Range"] as? String == "bytes 206-255/256")
        #expect(data.count == 50)
        for i in 0 ..< 50 {
            #expect(data[i] == UInt8(206 + i))
        }
    }

    @Test("Malformed range specs return 416 (multipart, garbage, double dash)")
    func malformedRangesReturn416() async throws {
        let content = Data(repeating: 0x47, count: 256)
        let fileURL = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let server = try LocalHTTPServer(streamer: try FileStreamer(fileURL: fileURL))
        defer { server.stop() }
        server.setManifest(Data())

        for spec in ["bytes=0-10,20-30", "bytes=abc-def", "bytes=1-2-3", "bytes=-"] {
            let (_, response) = try await rangeRequest(port: server.port, path: "/segment.ts", range: spec)
            #expect(response.statusCode == 416, "spec \(spec) should be 416")
        }
    }

    @Test("Range handling is identical in multi-segment mode")
    func multiSegmentRangeHardening() async throws {
        var seg = Data(count: 200)
        for i in 0 ..< 200 { seg[i] = UInt8(i % 256) }
        let fileURL = try makeTempFile(content: seg)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let segments = [SegmentInfo(offset: 0, duration: 2.0, length: 200)]
        let server = try LocalHTTPServer(streamer: try FileStreamer(fileURL: fileURL), segments: segments)
        defer { server.stop() }
        server.setManifest(Data())

        // Inverted → 416
        let (_, inverted) = try await rangeRequest(port: server.port, path: "/segment_0.ts", range: "bytes=100-50")
        #expect(inverted.statusCode == 416)

        // Suffix → last 40 bytes of the segment
        let (suffixData, suffix) = try await rangeRequest(port: server.port, path: "/segment_0.ts", range: "bytes=-40")
        #expect(suffix.statusCode == 206)
        #expect(suffix.allHeaderFields["Content-Range"] as? String == "bytes 160-199/200")
        #expect(suffixData == seg.subdata(in: 160 ..< 200))

        // Open range past segment end → 416
        let (_, past) = try await rangeRequest(port: server.port, path: "/segment_0.ts", range: "bytes=500-")
        #expect(past.statusCode == 416)
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

    @Test("Directory mode rejects path traversal outside the served root")
    func directoryModeRejectsPathTraversal() async throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmp4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        // A file OUTSIDE the served directory, reachable via `../`.
        let secretURL = dirURL.deletingLastPathComponent()
            .appendingPathComponent("secret_\(UUID().uuidString).txt")
        try "topsecret".write(to: secretURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secretURL) }

        let server = try LocalHTTPServer(directoryURL: dirURL)
        defer { server.stop() }

        // Percent-encoded so the client's URL layer does not normalize `..` away.
        let url = URL(string: "http://127.0.0.1:\(server.port)/%2e%2e%2f\(secretURL.lastPathComponent)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 403)
        #expect(String(data: data, encoding: .utf8) != "topsecret")
    }

    @Test("Directory mode serves fMP4 segments as video/mp4")
    func directoryModeContentTypes() async throws {
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmp4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        try Data(repeating: 0xAB, count: 64).write(to: dirURL.appendingPathComponent("seg_0.m4s"))
        try Data(repeating: 0x47, count: 188).write(to: dirURL.appendingPathComponent("seg_1.ts"))

        let server = try LocalHTTPServer(directoryURL: dirURL)
        defer { server.stop() }

        let m4sURL = URL(string: "http://127.0.0.1:\(server.port)/seg_0.m4s")!
        let (_, m4sResponse) = try await URLSession.shared.data(from: m4sURL)
        #expect((m4sResponse as! HTTPURLResponse).allHeaderFields["Content-Type"] as? String == "video/mp4")

        let tsURL = URL(string: "http://127.0.0.1:\(server.port)/seg_1.ts")!
        let (_, tsResponse) = try await URLSession.shared.data(from: tsURL)
        #expect((tsResponse as! HTTPURLResponse).allHeaderFields["Content-Type"] as? String == "video/mp2t")
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
        #expect(result.playlist.contains("seg/0.ts"))
        #expect(result.playlist.contains("seg/1.ts"))
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
        // Segment URLs are filename-keyed (stable across reloads).
        #expect(result.playlist.contains("/seg/3.ts"))
        #expect(!result.playlist.contains("ad1.ts"))
        // No discontinuity: the surviving content has continuous PTS, and a
        // discontinuity at the live edge stalls AVPlayer.
        #expect(!result.playlist.contains("#EXT-X-DISCONTINUITY"))
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
        // Live full-ad window: keep the last segment so the playlist is never
        // empty — an empty playlist triggers -12888 on the next poll.
        #expect(result.adSegmentCount == 1)
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
        // PART-INF is dropped too — it signals LL-HLS capability to AVPlayer,
        // which may trigger blocking reloads even without CAN-BLOCK-RELOAD=YES.
        #expect(!result.playlist.contains("PART-INF"))
        // Content-carrying PART entries, PRELOAD-HINT, and RENDITION-REPORT are stripped.
        #expect(!result.playlist.contains("#EXT-X-PART:"))
        #expect(!result.playlist.contains("PRELOAD-HINT"))
        #expect(!result.playlist.contains("RENDITION-REPORT"))
        // Content segments survive.
        #expect(result.playlist.contains("seg/0.ts"))
        #expect(result.playlist.contains("seg/1.ts"))
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

    @Test("cleanVariantPlaylist strips PROGRAM-DATE-TIME (regression: -16831)")
    func cleanStripsProgramDateTime() {
        // Live playlist with slate substitution. The PDT of the newest
        // (live-edge) segments survives on slate placeholders; if it reaches
        // AVPlayer, the start time lands inside the live-edge threshold →
        // CoreMedia -16831 "START-TIME is too close to live" → stall.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-PROGRAM-DATE-TIME:2026-08-11T19:00:00.000Z
        #EXTINF:2.000,
        content0.ts
        #EXT-X-PROGRAM-DATE-TIME:2026-08-11T19:00:02.000Z
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.ts
        #EXT-X-PROGRAM-DATE-TIME:2026-08-11T19:00:04.000Z
        #EXTINF:2.000,
        ad2.ts
        #EXT-X-CUE-IN
        #EXT-X-PROGRAM-DATE-TIME:2026-08-11T19:00:06.000Z
        #EXTINF:2.000,
        content1.ts
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )
        #expect(!result.playlist.contains("PROGRAM-DATE-TIME"))
        // Content and slate entries survive (no MEDIA-SEQUENCE in this fixture
        // → global index = position: 1, 2).
        #expect(result.playlist.contains("seg/content0.ts"))
        #expect(result.playlist.contains("/slate/1.ts"))
        #expect(result.playlist.contains("/slate/2.ts"))
        #expect(result.playlist.contains("seg/content1.ts"))
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

    // ── Discontinuity behavior ──

    @Test("cleanVariantPlaylist does not insert DISCONTINUITY around an ad block")
    func cleanNoDiscontinuityAfterAd() {
        // Removed (or slate-replaced) ads leave the surviving content on both
        // sides with continuous PTS — the player skips the gap natively. An
        // explicit discontinuity at the live edge makes AVPlayer stall, so the
        // cleaner must NOT insert one.
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
        #expect(!result.playlist.contains("#EXT-X-DISCONTINUITY"))
        let lines = result.playlist.components(separatedBy: .newlines)
        let beforeIdx = lines.firstIndex(where: { $0.contains("before.ts") })
        let afterIdx = lines.firstIndex(where: { $0.contains("after.ts") })
        #expect(beforeIdx != nil)
        #expect(afterIdx != nil)
        // Both content segments survive; the ads in between are gone.
        #expect(beforeIdx! < afterIdx!)
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

    @Test("redirectMappings stay consistent with rewritten proxy paths")
    func redirectMappingsMatchProxyPaths() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:2.000,
        seg0.ts?token=abc
        #EXTINF:2.000,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let baseURL = URL(string: "https://cdn.example.com/live/stream/index.m3u8")!

        let result = cleaner.cleanVariantPlaylist(
            variant,
            proxyBaseURL: "http://127.0.0.1:9999",
            segmentPathPrefix: "/seg/0",
            initPathPrefix: "/init/0",
            variantBaseURL: baseURL
        )

        let mappings = Dictionary(result.redirectMappings.map { ($0.path, $0.url) },
                                  uniquingKeysWith: { first, _ in first })
        // Every rewritten path appears in the playlist, and every URL is
        // resolved against the variant's post-redirect base URL.
        for (path, url) in result.redirectMappings {
            #expect(result.playlist.contains(path), "playlist lacks rewritten path \(path)")
            #expect(url.absoluteString.hasPrefix("https://cdn.example.com/live/stream/"))
        }
        // Query strings are stripped from the proxy path (they would 404) but
        // preserved in the forwarded CDN URL.
        #expect(mappings["/seg/0/seg0.ts"]?.absoluteString == "https://cdn.example.com/live/stream/seg0.ts?token=abc")
        #expect(mappings["/seg/0/seg1.ts"]?.absoluteString == "https://cdn.example.com/live/stream/seg1.ts")
        #expect(mappings["/init/0/0/init.mp4"]?.absoluteString == "https://cdn.example.com/live/stream/init.mp4")
    }
}

// MARK: - Slate substitution Tests

@Suite("SlateSubstitution")
struct SlateSubstitutionTests {

    let cleaner = HLSPlaylistCleaner()

    @Test("Live ad segments are replaced with slate URLs, not removed")
    func liveAdsReplacedWithSlate() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:2.000,
        seg100.ts
        #EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad",DURATION=4.0
        #EXTINF:2.000,
        ad101.ts
        #EXTINF:2.000,
        ad102.ts
        #EXTINF:2.000,
        seg103.ts
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )

        #expect(result.adSegmentCount == 2)
        #expect(result.replacedIndices == [1, 2])
        #expect(result.removedIndices.isEmpty)
        #expect(result.adReplaced)

        // Ad URLs are gone; slate placeholders took their slot. Slate URLs are
        // the GLOBAL indices (MEDIA-SEQUENCE 100 + position): 101, 102.
        #expect(!result.playlist.contains("ad101.ts"))
        #expect(!result.playlist.contains("ad102.ts"))
        #expect(result.playlist.contains("/slate/101.ts"))
        #expect(result.playlist.contains("/slate/102.ts"))

        // Media sequence is preserved so AVPlayer sees the playlist advancing.
        #expect(result.playlist.contains("#EXT-X-MEDIA-SEQUENCE:100"))

        // The slate run carries NO discontinuities: the proxy shifts each
        // copy's PTS onto the content timeline, and a discontinuity at the
        // live edge stalls AVPlayer (empirically verified).
        let lines = result.playlist.components(separatedBy: .newlines)
        let contentIdx = lines.firstIndex(where: { $0.contains("seg100.ts") })
        let slate1Idx = lines.firstIndex(where: { $0.contains("/slate/101.ts") })
        let slate2Idx = lines.firstIndex(where: { $0.contains("/slate/102.ts") })
        let resumeIdx = lines.firstIndex(where: { $0.contains("seg103.ts") })
        #expect(contentIdx != nil && slate1Idx != nil && slate2Idx != nil && resumeIdx != nil)
        let discontinuities = lines.indices.filter { lines[$0] == "#EXT-X-DISCONTINUITY" }
        #expect(discontinuities.isEmpty)
    }

    @Test("Full-ad live window becomes all-slate, never empty (regression: -12888)")
    func fullAdWindowBecomesSlate() {
        // The -12888 case: during a live ad break the whole sliding window is
        // ads. Removal produced an empty playlist and AVPlayer aborted after
        // 1.5 × TARGETDURATION. Slate substitution must keep it populated.
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:200
        #EXT-X-CUE-OUT:30.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXTINF:2.000,
        ad3.ts
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )

        #expect(result.replacedIndices == [0, 1, 2])
        #expect(result.removedIndices.isEmpty)
        // Every original slot is still a playable segment (global indices
        // 200 + position).
        #expect(result.playlist.contains("/slate/200.ts"))
        #expect(result.playlist.contains("/slate/201.ts"))
        #expect(result.playlist.contains("/slate/202.ts"))
        let segmentLines = result.playlist.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        #expect(segmentLines.count == 3)
    }

    @Test("Slate EXTINF matches the slate duration, not the ad duration")
    func slateExtinfAligned() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-CUE-OUT:30.0
        #EXTINF:6.000,
        ad1.ts
        #EXTINF:2.000,
        content.ts
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate", slateDuration: 2.0
        )

        let lines = result.playlist.components(separatedBy: .newlines)
        guard let slateIdx = lines.firstIndex(where: { $0.contains("/slate/0.ts") }) else {
            Issue.record("Expected a slate URL in the rewritten playlist")
            return
        }
        #expect(lines[slateIdx - 1] == "#EXTINF:2.000,")
    }

    @Test("VOD ignores slate — ad segments are still removed")
    func vodStillRemoves() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        content.ts
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXT-X-CUE-IN
        #EXTINF:2.000,
        content2.ts
        #EXT-X-ENDLIST
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )

        #expect(result.removedIndices == [1, 2])
        #expect(result.replacedIndices.isEmpty)
        #expect(!result.playlist.contains("/slate/"))
    }

    @Test("fMP4 live playlist (EXT-X-MAP) falls back to removal — TS slate cannot mix with init map")
    func fmp4FallsBackToRemoval() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:2.000,
        seg0.m4s
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.m4s
        #EXTINF:2.000,
        ad2.m4s
        #EXT-X-CUE-IN
        #EXTINF:2.000,
        seg3.m4s
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )

        // fMP4 live: fail-open — keep ad segments (can't substitute TS slate
        // under an active init-map). The user sees the ad but the stream survives.
        #expect(result.removedIndices.isEmpty)
        #expect(result.replacedIndices.isEmpty)
    }

    @Test("Encrypted stream: slate run closes and reopens the key scope")
    func slateClosesAndReopensKeyScope() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"
        #EXTINF:2.000,
        seg0.ts
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        #EXT-X-CUE-IN
        #EXTINF:2.000,
        seg3.ts
        """

        let result = cleaner.cleanVariantPlaylist(
            variant, proxyBaseURL: "http://127.0.0.1:9999", slatePathPrefix: "/slate"
        )

        let lines = result.playlist.components(separatedBy: .newlines)
        let keyNoneIdx = lines.firstIndex(of: "#EXT-X-KEY:METHOD=NONE")
        let slateIdx = lines.firstIndex(where: { $0.contains("/slate/1.ts") })
        #expect(keyNoneIdx != nil)
        #expect(slateIdx != nil)
        #expect(keyNoneIdx! < slateIdx!)

        // The original key is re-emitted before content resumes.
        let keyReemitIdx = lines.lastIndex(where: { $0.contains("URI=\"https://cdn.example.com/key.bin\"") })
        let resumeIdx = lines.firstIndex(where: { $0.contains("seg3.ts") })
        #expect(keyReemitIdx != nil)
        #expect(resumeIdx != nil)
        #expect(keyReemitIdx! > slateIdx!)
        #expect(keyReemitIdx! < resumeIdx!)
    }

    @Test("Without slatePathPrefix, live removal behavior is unchanged")
    func noSlatePrefixKeepsRemoval() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-CUE-OUT:4.0
        #EXTINF:2.000,
        ad1.ts
        #EXTINF:2.000,
        ad2.ts
        """

        let result = cleaner.cleanVariantPlaylist(variant, proxyBaseURL: "http://127.0.0.1:9999")
        // Without slate, ads are removed — but the last segment is kept to
        // prevent an empty playlist that triggers -12888 on polls.
        #expect(result.removedIndices == [0])
        #expect(result.replacedIndices.isEmpty)
        #expect(!result.playlist.contains("/slate/"))
    }
}

// MARK: - AdStrippingProxy slate route Tests

@Suite("AdStrippingProxy")
struct AdStrippingProxyTests {

    @Test("Embedded slate segment is available and TS-aligned")
    func slateAssetIsValid() {
        #expect(SlateSegment.isAvailable)
        let data = SlateSegment.data
        #expect(data != nil)
        #expect(data!.count > 0)
        #expect(data!.count % 188 == 0)        // whole MPEG-TS packets
        #expect(data!.first == 0x47)           // sync byte
    }

    @Test("SlateRewriter: standard PES layout with PTS at position×duration")
    func slateRewriterLayout() throws {
        let raw = try #require(SlateSegment.data)
        // delta = 3 × 2 s × 90 kHz — a copy at playlist position 3.
        let rewritten = try #require(SlateRewriter.rewrite(raw, adding: 540_000))

        // Same packet count; the rewrite only touches PES header bytes.
        #expect(rewritten.count == raw.count)

        // Find the first video PES and its PTS. The REWRITTEN copy carries it
        // at the standard payload+8; the RAW asset keeps it at payload+9
        // (non-standard layout — exactly what the rewriter fixes).
        func firstVideoPTS(_ data: Data, ptsOffset: Int) -> (flagsOffset: Int, pts: Int64)? {
            var i = 0
            while i + 188 <= data.count {
                if data[i] == 0x47 {
                    let adaptation = (data[i + 3] >> 4) & 0x03
                    var payload = i + 4
                    if adaptation == 2 { i += 188; continue }
                    if adaptation == 3 { payload += 1 + Int(data[i + 4]) }
                    if payload + 14 <= i + 188,
                       data[payload] == 0, data[payload + 1] == 0, data[payload + 2] == 1,
                       (0xE0...0xEF).contains(data[payload + 3]) {
                        let off = payload + ptsOffset
                        let b0 = Int64(data[off]), b1 = Int64(data[off + 1])
                        let b2 = Int64(data[off + 2]), b3 = Int64(data[off + 3])
                        let b4 = Int64(data[off + 4])
                        let pts = ((b0 & 0x0E) << 29) | (b1 << 22) | ((b2 & 0xFE) << 14) | (b3 << 7) | (b4 >> 1)
                        return (payload + 6, pts)
                    }
                }
                i += 188
            }
            return nil
        }

        let origVideo = try #require(firstVideoPTS(raw, ptsOffset: 9))
        let newVideo = try #require(firstVideoPTS(rewritten, ptsOffset: 8))
        #expect(rewritten[newVideo.flagsOffset] == 0xA0, "flags must declare PTS present")
        #expect(rewritten[newVideo.flagsOffset + 1] == 0x05, "PES header length must be 5")
        // Shifted by the delta, preserving the asset's own base offset.
        #expect(newVideo.pts == origVideo.pts + 540_000,
                "PTS must be shifted by exactly the delta (got \(newVideo.pts), expected \(origVideo.pts + 540_000))")
    }

    @Test("/slate/ route serves the placeholder segment over HTTP")
    func slateRouteServesSegment() async throws {
        let fetcher = RemotePlaylistFetcher(userAgent: "TSPlayerKitTests")
        let proxy = try AdStrippingProxy(
            remoteURL: URL(string: "https://example.com/unused.m3u8")!,
            fetcher: fetcher
        )
        defer { proxy.stop() }

        let slateURL = URL(string: "http://127.0.0.1:\(proxy.localURL.port!)/slate/5.ts")!
        let (data, response) = try await URLSession.shared.data(from: slateURL)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
        // The served copy is the REWRITTEN slate (standard PES layout, PTS at
        // position×2s), not the raw asset — AVPlayer needs the rewritten form.
        #expect(data != SlateSegment.data)
        #expect(data.count == SlateSegment.data?.count)
        #expect(data.first == 0x47)
        if let raw = SlateSegment.data {
            // Both start on the same transport packets — only PES headers differ.
            let deltaCount = zip(data, raw).filter { $0 != $1 }.count
            #expect(deltaCount < 64, "Expected only PES header bytes to differ, got \(deltaCount)")
        }
    }

    @Test("End-to-end: live ad break flows through the proxy as slate segments")
    func endToEndLiveAdBreak() async throws {
        // Simulate the Twitch CDN with a local static server: one live variant
        // playlist whose window contains a stitched-ad break.
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adproxy_e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let originVariant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:2.000,
        seg100.ts
        #EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad",DURATION=4.0
        #EXTINF:2.000,
        ad101.ts
        #EXTINF:2.000,
        ad102.ts
        #EXTINF:2.000,
        seg103.ts
        """
        try originVariant.write(to: dirURL.appendingPathComponent("index.m3u8"),
                                atomically: true, encoding: .utf8)
        let contentBytes = Data(repeating: 0x47, count: 376)
        try contentBytes.write(to: dirURL.appendingPathComponent("seg100.ts"))
        try contentBytes.write(to: dirURL.appendingPathComponent("seg103.ts"))

        let origin = try LocalHTTPServer(directoryURL: dirURL)
        defer { origin.stop() }

        let fetcher = RemotePlaylistFetcher(userAgent: "TSPlayerKitTests")
        let proxy = try AdStrippingProxy(
            remoteURL: URL(string: "http://127.0.0.1:\(origin.port)/playlist.m3u8")!,
            fetcher: fetcher
        )
        defer { proxy.stop() }
        let base = "http://127.0.0.1:\(proxy.localURL.port!)"

        // Master: single-variant input → synthesized master pointing at /variant/0.
        let (masterData, masterResp) = try await URLSession.shared.data(from: URL(string: "\(base)/master.m3u8")!)
        #expect((masterResp as! HTTPURLResponse).statusCode == 200)
        let master = String(data: masterData, encoding: .utf8)!
        #expect(master.contains("#EXT-X-STREAM-INF"))
        #expect(master.contains("/variant/0.m3u8"))

        // Variant: ads replaced by slate, content proxied, sequence preserved.
        // Segment URLs keep the original index: /seg/{variant}/{index}/{file}.
        let (variantData, variantResp) = try await URLSession.shared.data(from: URL(string: "\(base)/variant/0.m3u8")!)
        #expect((variantResp as! HTTPURLResponse).statusCode == 200)
        let variant = String(data: variantData, encoding: .utf8)!
        #expect(variant.contains("#EXT-X-MEDIA-SEQUENCE:100"))
        #expect(!variant.contains("ad101.ts"))
        #expect(!variant.contains("ad102.ts"))
        #expect(variant.contains("/slate/101.ts"))
        #expect(variant.contains("/slate/102.ts"))
        #expect(variant.contains("/seg/0/seg100.ts"))
        #expect(variant.contains("/seg/0/seg103.ts"))

        // The slate placeholder is served locally — as the REWRITTEN copy
        // (standard PES layout, PTS shifted by 101 × 2 s = 202 s).
        let (slateData, slateResp) = try await URLSession.shared.data(from: URL(string: "\(base)/slate/101.ts")!)
        #expect((slateResp as! HTTPURLResponse).statusCode == 200)
        #expect(slateData != SlateSegment.data)
        #expect(slateData.count == SlateSegment.data?.count)

        // …and content segments stream through from the origin untouched.
        let (segData, segResp) = try await URLSession.shared.data(from: URL(string: "\(base)/seg/0/seg100.ts")!)
        #expect((segResp as! HTTPURLResponse).statusCode == 200)
        #expect(segData == contentBytes)
    }
}

// MARK: - Programmable static origin

/// Minimal HTTP origin for fetcher/proxy tests: fixed responses per path,
/// request counting, and optional first-request connection drops.
final class StaticOriginServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.staticorigin")
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    /// (status, contentType, body) per path. Unlisted paths → 404.
    private let responses: [String: (Int, String, Data)]
    /// Paths whose FIRST request is answered by dropping the connection
    /// without a response — simulates a transport-level failure.
    private let dropFirstFor: Set<String>
    private var requestCounts: [String: Int] = [:]
    private var requestHeads: [String: String] = [:]

    init(responses: [String: (Int, String, Data)], dropFirstFor: Set<String> = []) throws {
        self.responses = responses
        self.dropFirstFor = dropFirstFor
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = listener.port?.rawValue ?? 0
                self.readySemaphore.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        readySemaphore.wait()
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func stop() { listener.cancel() }

    func requestCount(for path: String) -> Int {
        lock.withLock { requestCounts[path] ?? 0 }
    }

    /// Raw request head (request line + headers) of the LAST request for a path.
    func lastRequestHead(for path: String) -> String? {
        lock.withLock { requestHeads[path] }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, accumulated: Data())
    }

    private func receiveHead(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data else { connection.cancel(); return }
            var buffer = accumulated
            buffer.append(data)
            if buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.route(head: buffer, on: connection)
            } else if isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHead(connection, accumulated: buffer)
            }
        }
    }

    private func route(head: Data, on connection: NWConnection) {
        let raw = String(data: head, encoding: .utf8) ?? ""
        let requestLine = raw.components(separatedBy: "\r\n").first ?? ""
        let target = requestLine.components(separatedBy: " ").dropFirst().first ?? ""
        let path = target.components(separatedBy: "?").first ?? target

        lock.withLock {
            requestCounts[path, default: 0] += 1
            requestHeads[path] = raw
        }

        if requestCount(for: path) == 1, dropFirstFor.contains(path) {
            // Transport-level failure: close without answering.
            connection.cancel()
            return
        }

        let (status, contentType, body) = responses[path] ?? (404, "text/plain", Data())
        let headText = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(headText.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - RemotePlaylistFetcher Tests

@Suite("RemotePlaylistFetcher")
struct RemotePlaylistFetcherTests {

    private func makeFetcher(extraHeaders: [String: String] = [:]) -> RemotePlaylistFetcher {
        RemotePlaylistFetcher(userAgent: "FetcherTests", extraHeaders: extraHeaders, timeout: 2)
    }

    @Test("HTTP 200 with HTML body is rejected as invalidPlaylist")
    func htmlPageIsRejected() async throws {
        let origin = try StaticOriginServer(responses: [
            "/playlist.m3u8": (200, "text/html", Data("<html><body>gateway error</body></html>".utf8)),
        ])
        defer { origin.stop() }
        let fetcher = makeFetcher()

        do {
            _ = try await fetcher.fetchPlaylist(url: origin.baseURL.appendingPathComponent("playlist.m3u8"))
            Issue.record("expected invalidPlaylist, got a result")
        } catch RemotePlaylistFetcher.FetchError.invalidPlaylist {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("HTTP 403 fails immediately without retry")
    func httpErrorFailsImmediately() async throws {
        let origin = try StaticOriginServer(responses: [
            "/playlist.m3u8": (403, "text/plain", Data("denied".utf8)),
        ])
        defer { origin.stop() }
        let fetcher = makeFetcher()

        do {
            _ = try await fetcher.fetchPlaylist(url: origin.baseURL.appendingPathComponent("playlist.m3u8"))
            Issue.record("expected httpError, got a result")
        } catch let error as RemotePlaylistFetcher.FetchError {
            guard case .httpError(let code) = error else {
                Issue.record("expected httpError, got \(error)")
                return
            }
            #expect(code == 403)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(origin.requestCount(for: "/playlist.m3u8") == 1)
    }

    @Test("Transport-level failure gets exactly one retry")
    func transportFailureGetsSingleRetry() async throws {
        // The first request is dropped without a response; the retry succeeds.
        let valid = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.000,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let origin = try StaticOriginServer(
            responses: ["/playlist.m3u8": (200, "application/vnd.apple.mpegurl", Data(valid.utf8))],
            dropFirstFor: ["/playlist.m3u8"]
        )
        defer { origin.stop() }
        let fetcher = makeFetcher()

        let (text, _) = try await fetcher.fetchPlaylist(url: origin.baseURL.appendingPathComponent("playlist.m3u8"))
        #expect(text.hasPrefix("#EXTM3U"))
        #expect(origin.requestCount(for: "/playlist.m3u8") == 2)
    }

    @Test("User-Agent and extra headers reach the origin")
    func extraHeadersAreSent() async throws {
        let origin = try StaticOriginServer(responses: [
            "/playlist.m3u8": (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n".utf8)),
        ])
        defer { origin.stop() }
        let fetcher = makeFetcher(extraHeaders: ["X-Client-Id": "abc123"])

        _ = try? await fetcher.fetchPlaylist(url: origin.baseURL.appendingPathComponent("playlist.m3u8"))
        let head = origin.lastRequestHead(for: "/playlist.m3u8") ?? ""
        #expect(head.contains("User-Agent: FetcherTests"))
        #expect(head.contains("X-Client-Id: abc123"))
    }
}

// MARK: - AdStrippingProxy failure paths Tests

@Suite("AdStrippingProxyFailures")
struct AdStrippingProxyFailureTests {

    @Test("Segment CDN error (403) is answered with a clean 502")
    func segmentErrorBecomes502() async throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=10000000
        /variant/0.m3u8
        """
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:2.000,
        seg0.ts
        #EXT-X-ENDLIST
        """
        // The origin 403s the segment with an HTML body — the proxy must
        // answer 502 and never stream that body to AVPlayer as video/mp2t.
        let origin = try StaticOriginServer(responses: [
            "/playlist.m3u8": (200, "application/vnd.apple.mpegurl", Data(master.utf8)),
            "/variant/0.m3u8": (200, "application/vnd.apple.mpegurl", Data(variant.utf8)),
            "/seg0.ts": (403, "text/html", Data("<html>denied</html>".utf8)),
        ])
        defer { origin.stop() }

        let fetcher = RemotePlaylistFetcher(userAgent: "ProxyFailureTests", timeout: 2)
        let proxy = try AdStrippingProxy(remoteURL: origin.baseURL.appendingPathComponent("playlist.m3u8"), fetcher: fetcher)
        defer { proxy.stop() }

        // Walk the local playlist chain first — the segment mapping is only
        // registered once the variant has been fetched through the proxy.
        let base = "http://127.0.0.1:\(proxy.localURL.port!)"
        let (_, masterResp) = try await URLSession.shared.data(from: URL(string: "\(base)/master.m3u8")!)
        #expect((masterResp as! HTTPURLResponse).statusCode == 200)
        let (_, variantResp) = try await URLSession.shared.data(from: URL(string: "\(base)/variant/0.m3u8")!)
        #expect((variantResp as! HTTPURLResponse).statusCode == 200)

        let (data, segResp) = try await URLSession.shared.data(from: URL(string: "\(base)/seg/0/seg0.ts")!)
        #expect((segResp as! HTTPURLResponse).statusCode == 502)
        #expect(!String(data: data, encoding: .utf8)!.contains("denied"))
    }

    @Test("Invalid origin playlist becomes a clean 502")
    func invalidPlaylistBecomes502() async throws {
        let origin = try StaticOriginServer(responses: [
            "/playlist.m3u8": (200, "text/html", Data("<html>gateway error page</html>".utf8)),
        ])
        defer { origin.stop() }

        let fetcher = RemotePlaylistFetcher(userAgent: "ProxyFailureTests", timeout: 2)
        let proxy = try AdStrippingProxy(remoteURL: origin.baseURL.appendingPathComponent("playlist.m3u8"), fetcher: fetcher)
        defer { proxy.stop() }

        let (data, resp) = try await URLSession.shared.data(from: proxy.localURL)
        #expect((resp as! HTTPURLResponse).statusCode == 502)
        #expect(!String(data: data, encoding: .utf8)!.contains("gateway error page"))
    }
}

