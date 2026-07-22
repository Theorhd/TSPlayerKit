import Foundation

enum HLSManifestGenerator {
    static let host = "127.0.0.1"
    private static let manifestPath = "playlist.m3u8"
    private static let segmentPath = "segment.ts"

    static func manifestURL(port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(manifestPath)")!
    }

    // MARK: - Single-segment (legacy fallback)

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

    // MARK: - Multi-segment

    /// Builds the URL for a specific segment by its index.
    /// The server routes `/segment_N.ts` → byte range of the concatenated TS file.
    static func segmentURL(port: UInt16, index: Int) -> URL {
        URL(string: "http://\(host):\(port)/segment_\(index).ts")!
    }

    /// Generates a multi-segment HLS playlist where each entry maps to a byte
    /// range of a single concatenated `.ts` file.
    ///
    /// Each segment is small (typically 2–10 s, < 10 MB), so the server can
    /// serve the full byte range in one response without any size cap — fixing
    /// the ~6-second playback truncation that occurred with single-segment
    /// manifests capped at 8 MB.
    ///
    /// - Parameters:
    ///   - port: The local HTTP server port.
    ///   - segments: Segment metadata in playback order. Must be non-empty.
    /// - Returns: A complete HLS playlist string (multivariant playlist format).
    static func generateMultiSegmentPlaylist(port: UInt16, segments: [SegmentInfo]) -> String {
        let maxDuration = segments.map(\.duration).max() ?? 10.0
        let targetDuration = max(1, Int(ceil(maxDuration)))

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
        ]

        for (index, segment) in segments.enumerated() {
            let formattedDuration = String(format: "%.3f", segment.duration)
            let segURL = segmentURL(port: port, index: index).absoluteString
            lines.append("#EXTINF:\(formattedDuration),")
            lines.append(segURL)
        }

        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    static func generateMultiSegmentPlaylistData(port: UInt16, segments: [SegmentInfo]) -> Data {
        Data(generateMultiSegmentPlaylist(port: port, segments: segments).utf8)
    }
}
