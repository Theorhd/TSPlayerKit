import AVFoundation
import Foundation

/// Metadata for a single segment within a concatenated TS file.
///
/// Used to generate a multi-segment HLS manifest where each segment maps to a
/// byte range of the concatenated file. This avoids the 8 MB response cap issue
/// that truncates single-segment manifests to ~6 seconds of playback.
public struct SegmentInfo: Codable, Sendable {
    /// Byte offset of this segment within the concatenated TS file.
    public let offset: UInt64
    /// Duration of this segment in seconds (from the original `#EXTINF` tag).
    public let duration: Double
    /// Length of this segment in bytes.
    public let length: UInt64

    public init(offset: UInt64, duration: Double, length: UInt64) {
        self.offset = offset
        self.duration = duration
        self.length = length
    }
}

/// Wrapper creating an `AVPlayerItem` configured for local `.ts` playback via a local HTTP server.
public final class TSPlayerItem {

    /// The configured `AVPlayerItem` ready for playback.
    public let playerItem: AVPlayerItem

    private let httpServer: LocalHTTPServer

    /// Creates a configured `AVPlayerItem` for a local `.ts` file using a
    /// **multi-segment** HLS manifest.
    ///
    /// Each segment maps to a byte range within the concatenated TS file.
    /// The local HTTP server serves each segment by its exact byte range,
    /// without any response-size cap — individual HLS segments are small
    /// enough (typically 2–10 s) that reading them into memory is safe.
    ///
    /// - Parameters:
    ///   - tsFileURL: Path to the concatenated `.ts` file on disk.
    ///   - segments: Segment metadata (offset, duration, length) for each
    ///     original chunk, in playback order. Must be non-empty.
    public init(tsFileURL: URL, segments: [SegmentInfo]) throws {
        guard !segments.isEmpty else {
            throw TSPlayerItemError.emptySegments
        }

        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer, segments: segments)

        let manifestData = HLSManifestGenerator.generateMultiSegmentPlaylistData(
            port: server.port,
            segments: segments
        )
        server.setManifest(manifestData)

        self.httpServer = server

        let manifestURL = HLSManifestGenerator.manifestURL(port: server.port)
        let asset = AVURLAsset(url: manifestURL)
        self.playerItem = AVPlayerItem(asset: asset)
    }

    /// Creates a configured `AVPlayerItem` for a local `.ts` file using a
    /// **single-segment** HLS manifest (legacy fallback).
    ///
    /// - Parameters:
    ///   - tsFileURL: Path to the local `.ts` file on disk.
    ///   - totalDuration: The **real total duration** of the content in seconds.
    ///     This is written into the HLS manifest's `#EXTINF` tag so AVPlayer
    ///     knows how long the content is. Passing an incorrect value (e.g. the
    ///     old default of 10.0) causes playback to stop after that many seconds.
    ///     Obtain this from the sum of all `#EXTINF` values in the original
    ///     HLS playlist, or from a sidecar `.duration` file written at download time.
    public init(tsFileURL: URL, totalDuration: Double) throws {
        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer)

        let manifestData = HLSManifestGenerator.generatePlaylistData(
            port: server.port,
            totalDuration: totalDuration
        )
        server.setManifest(manifestData)

        self.httpServer = server

        let manifestURL = HLSManifestGenerator.manifestURL(port: server.port)
        let asset = AVURLAsset(url: manifestURL)
        self.playerItem = AVPlayerItem(asset: asset)
    }
}

enum TSPlayerItemError: Error, LocalizedError {
    case emptySegments

    var errorDescription: String? {
        switch self {
        case .emptySegments:
            return "Segments array must not be empty when using the multi-segment initializer."
        }
    }
}
