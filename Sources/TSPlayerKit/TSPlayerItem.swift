import AVFoundation
import Foundation

/// Wrapper creating an `AVPlayerItem` configured for local `.ts` playback via a local HTTP server.
public final class TSPlayerItem {

    /// The configured `AVPlayerItem` ready for playback.
    public let playerItem: AVPlayerItem

    private let httpServer: LocalHTTPServer

    /// Creates a configured `AVPlayerItem` for a local `.ts` file.
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
