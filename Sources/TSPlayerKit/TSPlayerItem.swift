import AVFoundation
import Foundation

/// Byte-range metadata for one segment of a concatenated TS file.
public struct SegmentInfo: Codable, Sendable {
    public let offset: UInt64
    public let duration: Double
    public let length: UInt64

    public init(offset: UInt64, duration: Double, length: UInt64) {
        self.offset = offset; self.duration = duration; self.length = length
    }
}

/// Creates an `AVPlayerItem` for local playback via a loopback HTTP server.
/// Supports three modes: legacy single-segment TS, multi-segment TS, and fMP4 directory.
public final class TSPlayerItem {

    public let playerItem: AVPlayerItem
    private let httpServer: LocalHTTPServer

    public init(tsFileURL: URL, segments: [SegmentInfo]) throws {
        guard !segments.isEmpty else { throw TSPlayerItemError.emptySegments }
        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer, segments: segments)
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
    var errorDescription: String? { "Segments array must not be empty." }
}
