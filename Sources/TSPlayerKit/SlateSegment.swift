import Foundation

/// Provides the placeholder ("slate") MPEG-TS segment served in place of live
/// ad segments.
///
/// During a live ad break the whole Twitch sliding window can turn into ads.
/// Deleting every segment yields an empty playlist — AVPlayer then aborts with
/// CoreMediaErrorDomain -12888 ("Playlist File unchanged for longer than
/// 1.5 × target duration"). Substituting a short black/silent segment keeps
/// the playlist advancing: playback survives the break (showing a black frame
/// with silence) and resumes on real content at the next discontinuity.
///
/// The embedded asset is a 2-second MPEG-TS segment (H.264 640×360 + silent
/// AAC 48 kHz stereo) matching the Twitch live cadence — content and stitched
/// ad segments are both ~2 s, so `#EXTINF` values stay consistent.
enum SlateSegment {

    /// Duration in seconds of the embedded slate segment.
    /// Must match the actual asset duration (verified with ffprobe).
    static let duration: Double = 2.0

    /// The slate segment bytes, or `nil` if the resource failed to load.
    /// Loaded once; immutable thereafter.
    static let data: Data? = {
        guard let url = Bundle.module.url(forResource: "slate", withExtension: "ts"),
              let data = try? Data(contentsOf: url),
              // Sanity check: a valid MPEG-TS packet starts with sync byte 0x47.
              data.count >= 188, data.first == 0x47
        else { return nil }
        return data
    }()

    /// Whether slate substitution is available. When `false`, the cleaner
    /// falls back to removing ad segments (previous behavior).
    static var isAvailable: Bool { data != nil }
}
