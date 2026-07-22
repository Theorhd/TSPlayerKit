import Foundation

enum HLSManifestGenerator {
    static let host = "127.0.0.1"
    private static let manifestPath = "playlist.m3u8"

    static func manifestURL(port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(manifestPath)")!
    }

    static func generatePlaylist(port: UInt16, totalDuration: Double) -> String {
        let target = max(1, Int(ceil(totalDuration)))
        let dur = String(format: "%.3f", totalDuration)
        let seg = "http://\(host):\(port)/segment.ts"
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(target)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:\(dur),
        \(seg)
        #EXT-X-ENDLIST
        """
    }

    static func generatePlaylistData(port: UInt16, totalDuration: Double) -> Data {
        Data(generatePlaylist(port: port, totalDuration: totalDuration).utf8)
    }

    static func segmentURL(port: UInt16, index: Int) -> URL {
        URL(string: "http://\(host):\(port)/segment_\(index).ts")!
    }

    static func generateMultiSegmentPlaylist(port: UInt16, segments: [SegmentInfo]) -> String {
        let target = max(1, Int(ceil(segments.map(\.duration).max() ?? 10.0)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
        ]
        for (i, seg) in segments.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.3f", seg.duration)),")
            lines.append(segmentURL(port: port, index: i).absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    static func generateMultiSegmentPlaylistData(port: UInt16, segments: [SegmentInfo]) -> Data {
        Data(generateMultiSegmentPlaylist(port: port, segments: segments).utf8)
    }
}
