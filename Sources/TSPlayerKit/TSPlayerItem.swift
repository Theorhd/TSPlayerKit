import AVFoundation
import Foundation

/// Byte-range metadata for one segment of a concatenated TS file.
public struct SegmentInfo: Codable, Sendable {
    public let offset: UInt64
    public let duration: Double
    public let length: UInt64
    /// Which TS file contains this segment (e.g. "video_000.ts").
    /// `nil` for the old single-file format (backward compat).
    public let file: String?

    public init(offset: UInt64, duration: Double, length: UInt64, file: String? = nil) {
        self.offset = offset; self.duration = duration; self.length = length; self.file = file
    }
}

/// Creates an `AVPlayerItem` for local playback via a loopback HTTP server.
/// Supports four modes: legacy single-segment TS, multi-segment TS, multi-file TS, and fMP4 directory.
public final class TSPlayerItem {

    public let playerItem: AVPlayerItem
    private let httpServer: LocalHTTPServer

    /// Multi-segment mode: all segments in a single TS file (backward compat).
    public init(tsFileURL: URL, segments: [SegmentInfo]) throws {
        guard !segments.isEmpty else { throw TSPlayerItemError.emptySegments }
        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer, segments: segments)
        server.setManifest(HLSManifestGenerator.generateMultiSegmentPlaylistData(port: server.port, segments: segments))
        httpServer = server
        playerItem = AVPlayerItem(asset: AVURLAsset(url: HLSManifestGenerator.manifestURL(port: server.port)))
    }

    /// Multi-file mode: segments spread across multiple TS files (e.g. `video_000.ts`, `video_001.ts`).
    /// Each segment's `file` field identifies which TS file contains it.
    public init(tsFilesDirectory: URL, segments: [SegmentInfo]) throws {
        guard !segments.isEmpty else { throw TSPlayerItemError.emptySegments }

        // Collect unique TS filenames and open a FileStreamer per file.
        let uniqueFiles = Set(segments.compactMap(\.file))
        guard !uniqueFiles.isEmpty else {
            throw TSPlayerItemError.missingFileField
        }

        var streamers: [String: FileStreamer] = [:]
        for filename in uniqueFiles {
            let fileURL = tsFilesDirectory.appendingPathComponent(filename)
            streamers[filename] = try FileStreamer(fileURL: fileURL)
        }

        let server = try LocalHTTPServer(streamers: streamers, segments: segments)
        server.setManifest(HLSManifestGenerator.generateMultiSegmentPlaylistData(port: server.port, segments: segments))
        httpServer = server
        playerItem = AVPlayerItem(asset: AVURLAsset(url: HLSManifestGenerator.manifestURL(port: server.port)))
    }

    public init(fmp4Directory: URL) throws {
        let server = try LocalHTTPServer(directoryURL: fmp4Directory)
        httpServer = server
        playerItem = AVPlayerItem(asset: AVURLAsset(url: HLSManifestGenerator.manifestURL(port: server.port)))
    }

    public init(tsFileURL: URL, totalDuration: Double) throws {
        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer)
        server.setManifest(HLSManifestGenerator.generatePlaylistData(port: server.port, totalDuration: totalDuration))
        httpServer = server
        playerItem = AVPlayerItem(asset: AVURLAsset(url: HLSManifestGenerator.manifestURL(port: server.port)))
    }
}

enum TSPlayerItemError: Error, LocalizedError {
    case emptySegments
    case missingFileField
    var errorDescription: String? {
        switch self {
        case .emptySegments: "Segments array must not be empty."
        case .missingFileField: "Multi-file segments must have a non-nil `file` field."
        }
    }
}
