import Foundation

/// Parses and cleans HLS playlists — detects ad segments and rewrites URLs.
///
/// Ad detection is a single state machine (`detectMarkedAdSegments`) that produces
/// a set of segment indices to remove. Detection is **bounded**: an ad block opened
/// by `#EXT-X-CUE-OUT` / `#EXT-X-DATERANGE` (SCTE35-OUT, Twitch `stitched-ad`)
/// closes on an explicit end marker *or* when the declared break duration has been
/// consumed — so a missing `SCTE35-IN` can never wipe the rest of the playlist.
///
/// What happens to detected ad segments depends on the playlist type:
/// - **VOD** (`#EXT-X-ENDLIST` present): ad segments are *removed*. The static
///   window makes removal safe, and playback simply skips the break.
/// - **Live** (no ENDLIST) with a slate available (`slatePathPrefix != nil`):
///   ad segments are *replaced* by a local placeholder segment (`/slate/…`).
///   The playlist keeps the same entry count and its media sequence keeps
///   advancing, so AVPlayer never sees a stalled/empty playlist — removing all
///   segments of a full ad-break window used to trigger CoreMediaErrorDomain
///   -12888 ("Playlist File unchanged for longer than 1.5 × target duration").
/// - **Live fMP4** (has `#EXT-X-MAP`) or slate unavailable: fall back to
///   removal — an empty window is valid HLS, and fMP4 cannot mix a TS slate
///   under an active init-map declaration.
///
/// Safety net: if detection would remove (almost) every segment of a VOD playlist,
/// it is considered a false positive and disabled (`fail-open`) — better to show an
/// ad than to break playback.
struct HLSPlaylistCleaner {

    /// Safety cap for an ad break whose duration can't be determined (seconds).
    static let maxAdBlockDuration: Double = 180

    // MARK: - Master playlist

    /// Rewrites a master playlist so every playable URL (variant streams and
    /// `#EXT-X-MEDIA` renditions, e.g. alternate audio) points to the local proxy.
    ///
    /// `#EXT-X-I-FRAME-STREAM-INF` entries are dropped: they are trick-play only,
    /// and unlike `#EXT-X-STREAM-INF` their URI is an *attribute* (no URL line
    /// follows) — treating them like regular variants corrupts the playlist.
    ///
    /// - Parameters:
    ///   - m3u8: The raw master playlist from Twitch.
    ///   - proxyBaseURL: The base URL of the local proxy (e.g. "http://127.0.0.1:54321").
    /// - Returns: The rewritten playlist plus the original variant URLs, in document
    ///   order — index `i` is served by the proxy at `/variant/<i>.m3u8`.
    func rewriteMasterPlaylist(_ m3u8: String, proxyBaseURL: String) -> (playlist: String, variantURLs: [String]) {
        let lines = m3u8.components(separatedBy: .newlines)
        var result: [String] = []
        var variantURLs: [String] = []
        var inVariantTag = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                // Trick-play only — dropped (see docstring).
                continue
            }

            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                inVariantTag = true
                result.append(line)
                continue
            }

            // Alternate renditions (audio etc.) embed their URI as an attribute.
            if trimmed.hasPrefix("#EXT-X-MEDIA:"), trimmed.contains("URI=\""),
               let rewritten = rewritingURIAttribute(
                    of: line,
                    to: "\(proxyBaseURL)/variant/\(variantURLs.count).m3u8"
               ) {
                variantURLs.append(extractURI(from: trimmed) ?? "")
                result.append(rewritten)
                continue
            }

            if inVariantTag, !trimmed.hasPrefix("#"), !trimmed.isEmpty {
                // URL line following an #EXT-X-STREAM-INF tag.
                variantURLs.append(trimmed)
                result.append("\(proxyBaseURL)/variant/\(variantURLs.count - 1).m3u8")
                inVariantTag = false
                continue
            }

            inVariantTag = false
            result.append(line)
        }
        return (result.joined(separator: "\n"), variantURLs)
    }

    // MARK: - Variant playlist cleaning

    /// Result of cleaning a variant playlist.
    struct CleanResult {
        /// The cleaned playlist text.
        let playlist: String
        /// Index set of removed segment positions (0-based, within the original playlist).
        let removedIndices: Set<Int>
        /// Index set of segment positions replaced by the slate placeholder
        /// (live playlists only — see `slatePathPrefix`).
        let replacedIndices: Set<Int>
        /// Whether at least one ad segment was removed or replaced.
        let adReplaced: Bool
        /// Number of ad segments detected (removed + replaced).
        let adSegmentCount: Int
    }

    /// Cleans a variant playlist by detecting ad segments, then either removing
    /// them (VOD, or live without slate support) or substituting them with the
    /// local slate placeholder (live TS streams), and rewriting remaining
    /// segment URLs to point to the local proxy.
    /// - Parameters:
    ///   - m3u8: The raw variant playlist text.
    ///   - proxyBaseURL: The local proxy base URL.
    ///   - segmentPathPrefix: Prefix for segment proxy paths (e.g. "/seg").
    ///   - initPathPrefix: Prefix for fMP4 init-segment proxy paths (e.g. "/init").
    ///   - slatePathPrefix: Prefix for slate placeholder paths (e.g. "/slate"),
    ///     or `nil` to disable slate substitution (ad segments are removed instead).
    ///   - slateDuration: Duration of the slate segment in seconds — used for the
    ///     `#EXTINF` of replaced entries.
    /// - Returns: The cleaning result with rewritten playlist.
    func cleanVariantPlaylist(_ m3u8: String, proxyBaseURL: String, segmentPathPrefix: String = "/seg", initPathPrefix: String = "/init", slatePathPrefix: String? = nil, slateDuration: Double = SlateSegment.duration) -> CleanResult {
        let lines = m3u8.components(separatedBy: .newlines)

        // --- Phase 1: detect ad segments ---

        let markedRemoved = detectMarkedAdSegments(lines: lines)
        let urlRemoved = detectURLPatternAds(lines: lines)
        let durationRemoved = detectDurationAnomalies(lines: lines)

        let adIndices = markedRemoved.union(urlRemoved).union(durationRemoved)

        // --- Decide removal vs. slate substitution ---
        //
        // Slate substitution is what makes live ad blocking robust: during a
        // full ad break the sliding window is 100% ads, and deleting every
        // segment produces an empty playlist. AVPlayer aborts such a stream
        // with CoreMediaErrorDomain -12888 after 1.5 × TARGETDURATION. Swapping
        // in placeholder segments keeps the window populated and advancing.
        //
        // It is only safe for MPEG-TS live streams: an fMP4 playlist declares
        // `#EXT-X-MAP` init segments whose scope would cover the TS slate.
        let isVOD = m3u8.contains("#EXT-X-ENDLIST")
        let hasInitMap = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXT-X-MAP:") }
        let useSlate = slatePathPrefix != nil && !isVOD && !hasInitMap

        var removedIndices = Set<Int>()
        var replacedIndices = Set<Int>()

        if useSlate {
            replacedIndices = adIndices
        } else {
            removedIndices = adIndices
            // --- Fail-open guard ---
            // Never strip (almost) an entire VOD: that means the detection misfired.
            // For live (no ENDLIST) an empty window is legitimate — the whole sliding
            // window can genuinely be ads — and AVPlayer just keeps polling.
            let totalSegments = lines.filter {
                let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !t.isEmpty && !t.hasPrefix("#")
            }.count
            if isVOD, totalSegments > 0, removedIndices.count == totalSegments {
                // Every single segment looks like an ad — the detection misfired.
                // Fail-open: better to show ads than serve an empty playlist.
                // (Live playlists—no ENDLIST—keep the removal; empty windows are
                // valid HLS there and AVPlayer simply keeps polling.)
                removedIndices = []
            }
        }

        // --- Phase 2: rewrite ---

        let rewritten = rewriteVariantLines(
            lines: lines,
            removedIndices: removedIndices,
            replacedIndices: replacedIndices,
            proxyBaseURL: proxyBaseURL,
            segmentPathPrefix: segmentPathPrefix,
            initPathPrefix: initPathPrefix,
            slatePathPrefix: slatePathPrefix,
            slateDuration: slateDuration
        )

        return CleanResult(
            playlist: rewritten,
            removedIndices: removedIndices,
            replacedIndices: replacedIndices,
            adReplaced: !removedIndices.isEmpty || !replacedIndices.isEmpty,
            adSegmentCount: removedIndices.count + replacedIndices.count
        )
    }

    // MARK: - Ad tag classification

    private enum AdTag: Equatable {
        /// Opens an ad break; carries the declared break duration if known.
        case adStart(duration: Double?)
        /// Closes an ad break.
        case adEnd
        /// Not an ad boundary.
        case none
    }

    /// Classifies a tag line as an ad-break boundary.
    ///
    /// Covers: `#EXT-X-CUE-OUT`/`CUE-IN`, `#EXT-X-CUE-OUT-CONT` (sliding-window
    /// continuation), and `#EXT-X-DATERANGE` with `SCTE35-OUT`/`SCTE35-IN`,
    /// Twitch `stitched-ad` / `twitch-stitched-ad`, or `CUE="PRE"`/`CUE="POST"`.
    private func classifyAdTag(_ line: String) -> AdTag {
        if line.hasPrefix("#EXT-X-CUE-OUT-CONT") {
            // Continuation marker inside a sliding window: still in the break.
            let duration = numericAttribute("Duration", in: line)
            let elapsed = numericAttribute("ElapsedTime", in: line) ?? 0
            return .adStart(duration: duration.map { max(0, $0 - elapsed) })
        }
        if line.hasPrefix("#EXT-X-CUE-OUT") {
            return .adStart(duration: parseCueOutDuration(line))
        }
        if line.hasPrefix("#EXT-X-CUE-IN") {
            return .adEnd
        }
        if line.hasPrefix("#EXT-X-DATERANGE:") {
            let lower = line.lowercased()
            if lower.contains("scte35-in") || lower.contains("cue=\"post\"") {
                return .adEnd
            }
            if lower.contains("scte35-out") || lower.contains("stitched-ad") || lower.contains("cue=\"pre\"") {
                return .adStart(duration: numericAttribute("DURATION", in: line)
                                    ?? numericAttribute("PLANNED-DURATION", in: line))
            }
        }
        return .none
    }

    /// Duration carried by `#EXT-X-CUE-OUT:30.0` or `#EXT-X-CUE-OUT:DURATION=30.0`.
    private func parseCueOutDuration(_ line: String) -> Double? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colon)...])
        if let d = numericAttribute("DURATION", in: value) { return d }
        let head = value.components(separatedBy: ",").first ?? value
        return Double(head.trimmingCharacters(in: .whitespaces))
    }

    /// Reads a numeric `NAME=value` attribute (case-insensitive) from a tag line.
    private func numericAttribute(_ name: String, in line: String) -> Double? {
        guard let range = line.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let token = line[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
        return Double(token)
    }

    /// Duration of an `#EXTINF:2.000,…` line.
    private func extinfDuration(_ line: String) -> Double {
        guard let colon = line.firstIndex(of: ":") else { return 0 }
        let value = line[line.index(after: colon)...]
        let head = value.components(separatedBy: ",").first ?? ""
        return Double(head.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: - Detection strategies

    /// Detects segments inside an ad break delimited by CUE-OUT/CUE-IN or
    /// DATERANGE (SCTE35 / stitched-ad) markers.
    ///
    /// The break is **bounded by its declared duration**: once the accumulated
    /// `#EXTINF` durations of removed segments reach the break duration, the break
    /// is considered over even without an explicit end marker. Without this, a
    /// Twitch playlist that carries `SCTE35-OUT` but no `SCTE35-IN` in the same
    /// window would cause every following segment to be deleted.
    private func detectMarkedAdSegments(lines: [String]) -> Set<Int> {
        var removed = Set<Int>()
        var segmentIndex = 0
        var inAd = false
        var adBudget: Double = 0
        var pendingDuration: Double = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            switch classifyAdTag(trimmed) {
            case .adStart(let duration):
                inAd = true
                adBudget = duration ?? Self.maxAdBlockDuration
                continue
            case .adEnd:
                inAd = false
                adBudget = 0
                continue
            case .none:
                break
            }

            if trimmed.hasPrefix("#EXTINF:") {
                pendingDuration = extinfDuration(trimmed)
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            // Segment URL line.
            if inAd {
                removed.insert(segmentIndex)
                adBudget -= pendingDuration
                if adBudget <= 0 {
                    inAd = false
                    adBudget = 0
                }
            }
            pendingDuration = 0
            segmentIndex += 1
        }

        return removed
    }

    /// Detects segments whose URLs match known ad CDN patterns.
    private func detectURLPatternAds(lines: [String]) -> Set<Int> {
        var removed = Set<Int>()
        var segmentIndex = 0

        // Kept deliberately specific — loose patterns ("-ad-", "a/video")
        // false-positive on content segment hashes and kill playback.
        let adPatterns = [
            "amazon-ads", "/ads/", ".ads.", "ads.", "doubleclick",
            "googlesyndication", "adserver", "stitched-ad", "/advertisement/",
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()
            for pattern in adPatterns {
                if lower.contains(pattern) {
                    removed.insert(segmentIndex)
                    break
                }
            }
            segmentIndex += 1
        }
        return removed
    }

    /// Detects ad segments by duration anomaly:
    /// - Typical live content segments are ~2s (low-latency HLS)
    /// - Ad segments are typically 6s, 15s, 30s, or 60s
    /// - A run of anomalous-duration segments is flagged as an ad block
    private func detectDurationAnomalies(lines: [String]) -> Set<Int> {
        var removed = Set<Int>()

        // Collect segment durations
        var durations: [Double] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTINF:") {
                durations.append(extinfDuration(trimmed))
            }
        }

        guard durations.count >= 3 else { return removed }

        // Find the mode (dominant content duration)
        let sorted = durations.sorted()
        let mode: Double
        if let first = sorted.first {
            // For live: content is usually the most common short duration
            let closeValues = sorted.filter { abs($0 - first) < 0.5 }
            if closeValues.count >= sorted.count / 2 {
                mode = first
            } else {
                // Fall back to median
                mode = sorted[sorted.count / 2]
            }
        } else {
            return removed
        }

        // Known ad durations (within 0.5s tolerance).
        // 10s is excluded — it's the standard live segment duration on Twitch.
        let adDurations: Set<Double> = [6, 15, 30, 60]

        // Never flag segments whose duration matches the content mode
        let modeTolerance = max(0.5, mode * 0.1)

        func isAdDuration(_ d: Double) -> Bool {
            // Skip: this duration is the normal content duration
            if abs(d - mode) <= modeTolerance { return false }
            // Known ad durations
            for ad in adDurations {
                if d >= ad - 0.5 && d <= ad + 0.5 { return true }
            }
            // Duration significantly longer than content mode
            if mode > 0 && d >= mode * 2.5 { return true }
            return false
        }

        // Find runs of ad-like durations (need ≥ 2 consecutive to count)
        var i = 0
        while i < durations.count {
            if isAdDuration(durations[i]) {
                let runStart = i
                while i < durations.count && isAdDuration(durations[i]) {
                    i += 1
                }
                let runLength = i - runStart
                if runLength >= 2 {
                    for j in runStart..<i {
                        removed.insert(j)
                    }
                }
            } else {
                i += 1
            }
        }

        return removed
    }

    // MARK: - Rewriting

    /// Tags that must not reach the player in their original form:
    /// - ad signaling (CUE-*, ad DATERANGE) and Twitch-private tags
    /// - `#EXT-X-PART:` and `#EXT-X-PART-INF` — even the metadata tag signals
    ///   low-latency HLS capability to AVPlayer, which may trigger blocking
    ///   reloads that our proxy cannot honor (→ CoreMedia -12888). Stripping
    ///   both degrades the stream to standard HLS polling, which works correctly.
    /// - `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT` (LL-HLS helpers)
    ///
    /// `#EXT-X-SERVER-CONTROL` is NOT dropped — it is rewritten in the variant
    /// phase to `CAN-BLOCK-RELOAD=NO` for the same reason.
    private func shouldDropTag(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("#EXT-X-CUE-") { return true }
        if trimmed.hasPrefix("#EXT-X-TWITCH-") { return true }
        if trimmed.hasPrefix("#EXT-X-PREFETCH") { return true }
        if trimmed.hasPrefix("#EXT-X-PART") { return true }   // PART: and PART-INF
        if trimmed.hasPrefix("#EXT-X-PRELOAD-HINT") { return true }
        if trimmed.hasPrefix("#EXT-X-RENDITION-REPORT") { return true }
        if trimmed.hasPrefix("#EXT-X-DATERANGE:") {
            return classifyAdTag(trimmed) != .none
        }
        return false
    }

    /// Rewrites variant playlist lines: removes ad segments (or substitutes
    /// them with slate placeholders), rewrites remaining URLs.
    private func rewriteVariantLines(
        lines: [String],
        removedIndices: Set<Int>,
        replacedIndices: Set<Int>,
        proxyBaseURL: String,
        segmentPathPrefix: String,
        initPathPrefix: String,
        slatePathPrefix: String?,
        slateDuration: Double
    ) -> String {
        var result: [String] = []
        var segmentIndex = 0
        var mapIndex = 0
        var pendingEXTINF: String?
        var previousSegmentWasAd = false
        /// `true` while emitting a run of slate placeholder segments.
        var inSlateRun = false
        /// Last active decryption key (METHOD ≠ NONE), if any. Slate segments
        /// are served in the clear, so a slate run closes the key scope with
        /// `#EXT-X-KEY:METHOD=NONE` and reopens it when content resumes.
        var activeKeyLine: String?

        func appendDiscontinuityIfNeeded() {
            if result.last?.trimmingCharacters(in: .whitespacesAndNewlines) != "#EXT-X-DISCONTINUITY" {
                result.append("#EXT-X-DISCONTINUITY")
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Buffer #EXTINF — it is written only if its segment survives.
            if trimmed.hasPrefix("#EXTINF:") {
                pendingEXTINF = line
                continue
            }

            // Track key scope. A key change mid-slate-run is recorded (and
            // restored on exit) but not emitted — slate is unencrypted.
            if trimmed.hasPrefix("#EXT-X-KEY:") {
                activeKeyLine = trimmed.contains("METHOD=NONE") ? nil : line
                if inSlateRun { continue }
                result.append(line)
                continue
            }

            if shouldDropTag(trimmed) { continue }

            // Non-URL tags — preserve; rewrite #EXT-X-MAP URIs (fMP4 init)
            // and #EXT-X-SERVER-CONTROL (disable blocking reload).
            // #EXT-X-KEY URIs are intentionally left untouched: keys are fetched
            // directly, and proxying them is both useless and a playback risk.
            if trimmed.hasPrefix("#") {
                // Rewrite SERVER-CONTROL to disable blocking playlist reload.
                // AVPlayer sends `?_HLS_msn=N` params when CAN-BLOCK-RELOAD=YES,
                // expecting the server to hold the connection. Our proxy responds
                // immediately → AVPlayer perceives an "unchanged" playlist →
                // CoreMedia error -12888. Plain polling avoids this entirely.
                if trimmed.hasPrefix("#EXT-X-SERVER-CONTROL:") {
                    let rewritten = trimmed
                        .replacingOccurrences(of: "CAN-BLOCK-RELOAD=YES", with: "CAN-BLOCK-RELOAD=NO")
                    result.append(rewritten)
                    continue
                }
                if trimmed.hasPrefix("#EXT-X-MAP:URI=\"") {
                    if let rewritten = rewritingURIAttribute(
                        of: line,
                        to: "\(proxyBaseURL)\(initPathPrefix)/\(mapIndex)/\(Self.segmentFilename(extractURI(from: trimmed) ?? ""))"
                    ) {
                        result.append(rewritten)
                        mapIndex += 1
                    } else {
                        result.append(line)
                    }
                    continue
                }
                result.append(line)
                continue
            }

            // Empty lines
            if trimmed.isEmpty {
                result.append(line)
                continue
            }

            // --- Segment URL ---
            if removedIndices.contains(segmentIndex) {
                pendingEXTINF = nil
                previousSegmentWasAd = true
                segmentIndex += 1
                continue
            }

            if let slatePathPrefix, replacedIndices.contains(segmentIndex) {
                if !inSlateRun {
                    // Entering a slate run: hard boundary before the placeholder…
                    appendDiscontinuityIfNeeded()
                    // …and close any encryption scope (slate is in the clear).
                    if activeKeyLine != nil {
                        result.append("#EXT-X-KEY:METHOD=NONE")
                    }
                    inSlateRun = true
                }
                // The slate has a fixed duration — align EXTINF with reality.
                pendingEXTINF = nil
                result.append("#EXTINF:\(String(format: "%.3f", slateDuration)),")
                result.append("\(proxyBaseURL)\(slatePathPrefix)/\(segmentIndex).ts")
                previousSegmentWasAd = true
                segmentIndex += 1
                continue
            }

            // Content boundary after an ad run (removed or replaced): insert a
            // discontinuity (unless the playlist already has one right there).
            if previousSegmentWasAd {
                appendDiscontinuityIfNeeded()
                if inSlateRun, let key = activeKeyLine {
                    // Reopen the encryption scope closed for the slate run.
                    result.append(key)
                }
                previousSegmentWasAd = false
                inSlateRun = false
            }

            if let extinf = pendingEXTINF {
                result.append(extinf)
                pendingEXTINF = nil
            }

            let proxyURL = "\(proxyBaseURL)\(segmentPathPrefix)/\(segmentIndex)/\(Self.segmentFilename(trimmed))"
            result.append(proxyURL)
            segmentIndex += 1
        }

        // Bump TARGETDURATION to at least 6s. The original value (often 2s for
        // LL-HLS live streams) gives AVPlayer a 1.5× = 3-second window before it
        // declares the playlist "unchanged" (error -12888). After stripping LL-HLS
        // tags we are serving standard HLS, which typically uses 6–10s, and the
        // proxy adds a full round-trip to Twitch on every poll — more breathing
        // room avoids spurious failures on slow or unstable connections.
        let minTarget = 6
        var bumped: [String] = []
        for line in result {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXT-X-TARGETDURATION:") {
                if let colon = trimmed.firstIndex(of: ":"),
                   let value = Int(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                    bumped.append("#EXT-X-TARGETDURATION:\(max(value, minTarget))")
                } else {
                    bumped.append(line)
                }
            } else {
                bumped.append(line)
            }
        }

        return bumped.joined(separator: "\n")
    }

    // MARK: - URI helpers

    /// Last path component of a URL string, without any query string.
    /// Used for proxy paths — must stay consistent with the redirect cache keys
    /// in `AdStrippingProxy` (a `?sig=…` suffix in the filename would 404).
    static func segmentFilename(_ urlString: String) -> String {
        let noQuery = urlString.components(separatedBy: "?").first ?? urlString
        return noQuery.components(separatedBy: "/").last ?? noQuery
    }

    /// Extracts the URI value from a `URI="..."` attribute.
    private func extractURI(from line: String) -> String? {
        guard let start = line.range(of: "URI=\"")?.upperBound,
              let end = line[start...].range(of: "\"")?.lowerBound else { return nil }
        return String(line[start..<end])
    }

    /// Replaces the URI value inside a `URI="..."` attribute with a new one.
    private func rewritingURIAttribute(of line: String, to newURI: String) -> String? {
        guard let uriStart = line.range(of: "URI=\"")?.upperBound,
              let uriEnd = line[uriStart...].range(of: "\"")?.lowerBound else { return nil }
        return line.replacingCharacters(in: uriStart..<uriEnd, with: newURI)
    }
}
