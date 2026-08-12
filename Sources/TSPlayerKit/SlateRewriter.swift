import Foundation

/// Rewrites a slate MPEG-TS copy so AVPlayer can schedule it mid-live-stream.
///
/// The embedded slate asset has two problems for live insertion:
/// 1. **Non-standard PES headers.** Its timestamps sit at `payload+9` with a
///    flags byte of `0x80` (PTS not declared). AVPlayer therefore reads a
///    timestamp-less segment — after a `#EXT-X-DISCONTINUITY` it has nothing
///    to reset its timebase to, refuses to schedule the segment, and the live
///    edge stops advancing (CoreMedia -12312 / MEDIA_PLAYBACK_STALL).
///    The standard layout is flags `0xA0` (PTS present), header length 5,
///    PTS at `payload+8`.
/// 2. **Near-zero original PTS.** The asset's timestamps start at ~1.4 s —
///    the same encoder delay that content segments carry. Played as-is, a copy
///    inserted mid-stream has timestamps behind the playhead and is refused at
///    the live edge. The copy is therefore SHIFTED by a delta derived from its
///    playlist position: `(sequence + position) × duration` — which lands it
///    on the content timeline (content PTS ≈ uptime + the same ~1.4 s base).
///    Shifting (not re-anchoring) preserves the asset's own base offset, so
///    the run stays continuous with whatever the content encoder's base is.
///
/// Both the first video PES and the first audio PES are rewritten with the
/// same delta, preserving A/V sync.
struct SlateRewriter {

    static let ticksPerSecond: Int64 = 90_000

    /// - Parameters:
    ///   - tsData: The embedded slate TS asset.
    ///   - delta: 90 kHz ticks to add to the copy's timestamps.
    /// - Returns: The rewritten copy, or `nil` if the asset cannot be parsed.
    static func rewrite(_ tsData: Data, adding delta: Int64) -> Data? {
        var out = tsData
        var patchedVideo = false
        var patchedAudio = false
        var i = 0

        while i + 188 <= out.count, !(patchedVideo && patchedAudio) {
            guard out[i] == 0x47 else { i += 188; continue }

            let adaptation = (out[i + 3] >> 4) & 0x03
            var payload = i + 4
            if adaptation == 2 { i += 188; continue }           // no payload
            if adaptation == 3 { payload += 1 + Int(out[i + 4]) } // skip adaptation field

            guard payload + 14 <= i + 188 else { i += 188; continue }
            guard out[payload] == 0, out[payload + 1] == 0, out[payload + 2] == 1 else { i += 188; continue }

            let streamID = out[payload + 3]
            let isVideo = (0xE0...0xEF).contains(streamID)
            let isAudio = (0xC0...0xDF).contains(streamID)
            guard (isVideo && !patchedVideo) || (isAudio && !patchedAudio) else { i += 188; continue }
            // The asset carries its timestamp at payload+9 (non-standard).
            guard let originalPTS = decodePTS(out, at: payload + 9) else { i += 188; continue }

            // Standard layout: flags '10' + PTS-present (0xA0), header length 5,
            // PTS at payload+8 (the asset's original layout kept it at +9).
            out[payload + 6] = 0xA0
            out[payload + 7] = 0x05
            encodePTS(&out, at: payload + 8, pts: originalPTS + delta)

            if isVideo { patchedVideo = true }
            if isAudio { patchedAudio = true }
            i += 188
        }

        return patchedVideo && patchedAudio ? out : nil
    }

    // MARK: - PTS helpers

    /// Decodes the 33-bit PTS/DTS field at `offset` (5 bytes, marker bits
    /// interleaved per ISO/IEC 13818-1).
    private static func decodePTS(_ data: Data, at offset: Int) -> Int64? {
        guard offset + 5 <= data.count else { return nil }
        let b0 = Int64(data[offset]), b1 = Int64(data[offset + 1]), b2 = Int64(data[offset + 2])
        let b3 = Int64(data[offset + 3]), b4 = Int64(data[offset + 4])
        return ((b0 & 0x0E) << 29) | (b1 << 22) | ((b2 & 0xFE) << 14) | (b3 << 7) | (b4 >> 1)
    }

    private static func encodePTS(_ data: inout Data, at offset: Int, pts: Int64) {
        data[offset]     = UInt8(0x21 | ((pts >> 29) & 0x0E))
        data[offset + 1] = UInt8((pts >> 22) & 0xFF)
        data[offset + 2] = UInt8(0x01 | (((pts >> 15) & 0x7F) << 1))
        data[offset + 3] = UInt8((pts >> 7) & 0xFF)
        data[offset + 4] = UInt8(0x01 | ((pts & 0x7F) << 1))
    }
}
