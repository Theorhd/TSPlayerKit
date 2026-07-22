import AVFoundation
import Foundation

/// Wrapper creating an `AVPlayerItem` configured for local `.ts` playback via a local HTTP server.
public final class TSPlayerItem {

    /// The configured `AVPlayerItem` ready for playback.
    public let playerItem: AVPlayerItem

    private let httpServer: LocalHTTPServer

    /// Creates a configured `AVPlayerItem` for a local `.ts` file.
    public init(tsFileURL: URL, targetDuration: Double = 10.0) throws {
        let streamer = try FileStreamer(fileURL: tsFileURL)
        let server = try LocalHTTPServer(streamer: streamer)

        let manifestData = HLSManifestGenerator.generatePlaylistData(
            port: server.port,
            targetDuration: targetDuration
        )
        server.setManifest(manifestData)

        self.httpServer = server

        let manifestURL = HLSManifestGenerator.manifestURL(port: server.port)
        let asset = AVURLAsset(url: manifestURL)
        self.playerItem = AVPlayerItem(asset: asset)
    }
}
