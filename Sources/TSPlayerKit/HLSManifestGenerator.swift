import Foundation

enum HLSManifestGenerator {
    static let host = "127.0.0.1"
    private static let manifestPath = "playlist.m3u8"
    private static let segmentPath = "segment.ts"

    static func manifestURL(port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(manifestPath)")!
    }

    static func segmentURL(port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(segmentPath)")!
    }

    /// Generates a single-segment HLS playlist for a local .ts file.
    ///
    /// - Parameters:
    ///   - port: The local HTTP server port.
    ///   - totalDuration: The **real total duration** of the .ts content in seconds.
    ///     This value is written into `#EXTINF` and `#EXT-X-TARGETDURATION`.
    ///     Passing the wrong value (e.g. 10.0) causes AVPlayer to stop playback
    ///     after that many seconds, regardless of how much data remains in the file.
    static func generatePlaylist(port: UInt16, totalDuration: Double) -> String {
        // #EXT-X-TARGETDURATION must be an integer >= ceil(max segment duration).
        let targetDuration = max(1, Int(ceil(totalDuration)))
        // #EXTINF accepts a floating-point value — use 3 decimal places for precision.
        let formattedDuration = String(format: "%.3f", totalDuration)
        let segment = segmentURL(port: port).absoluteString

        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:\(formattedDuration),
        \(segment)
        #EXT-X-ENDLIST
        """
    }

    static func generatePlaylistData(port: UInt16, totalDuration: Double) -> Data {
        Data(generatePlaylist(port: port, totalDuration: totalDuration).utf8)
    }
}
