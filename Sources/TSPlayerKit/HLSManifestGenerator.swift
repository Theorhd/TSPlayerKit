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

    static func generatePlaylist(port: UInt16, targetDuration: Double = 10.0) -> String {
        let roundedDuration = max(1, Int(ceil(targetDuration)))
        let formattedDuration = String(format: "%.1f", targetDuration)
        let segment = segmentURL(port: port).absoluteString

        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(roundedDuration)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:\(formattedDuration),
        \(segment)
        #EXT-X-ENDLIST
        """
    }

    static func generatePlaylistData(port: UInt16, targetDuration: Double = 10.0) -> Data {
        Data(generatePlaylist(port: port, targetDuration: targetDuration).utf8)
    }
}
