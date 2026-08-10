import Foundation

/// Parses and cleans HLS playlists — detects ad segments and rewrites URLs.
struct HLSPlaylistCleaner {

    // MARK: - Master playlist

    /// Rewrites a master playlist so variant stream URLs point to the local proxy.
    /// - Parameters:
    ///   - m3u8: The raw master playlist from Twitch.
    ///   - proxyBaseURL: The base URL of the local proxy (e.g. "http://127.0.0.1:54321").
    /// - Returns: The rewritten playlist.
    func rewriteMasterPlaylist(_ m3u8: String, proxyBaseURL: String) -> String {
        let lines = m3u8.components(separatedBy: .newlines)
        var result: [String] = []
        var variantIndex = 0
        var inVariantTag = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { result.append(line); continue }
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") || trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                inVariantTag = true
                result.append(line)
                continue
            }
            if inVariantTag && !trimmed.hasPrefix("#") {
                // This is a variant URL — replace with proxy URL
                result.append("\(proxyBaseURL)/variant/\(variantIndex).m3u8")
                variantIndex += 1
                inVariantTag = false
                continue
            }
            inVariantTag = false
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Variant playlist cleaning

    /// Result of cleaning a variant playlist.
    struct CleanResult {
        /// The cleaned playlist text.
        let playlist: String
        /// Index set of removed segment positions (0-based, within the original playlist).
        let removedIndices: Set<Int>
        /// Replacement URLs for removed segments (original URL → replacement URL).
        /// When empty, the segment was removed entirely.
        let adReplaced: Bool
        /// Number of ad segments detected and removed.
        let adSegmentCount: Int
    }

    /// Cleans a variant playlist by detecting and removing ad segments,
    /// then rewriting remaining segment URLs to point to the local proxy.
    /// - Parameters:
    ///   - m3u8: The raw variant playlist text.
    ///   - proxyBaseURL: The local proxy base URL.
    ///   - segmentPathPrefix: Prefix for segment proxy paths (e.g. "/seg").
    /// - Returns: The cleaning result with rewritten playlist.
    func cleanVariantPlaylist(_ m3u8: String, proxyBaseURL: String, segmentPathPrefix: String = "/seg", initPathPrefix: String = "/init") -> CleanResult {
        let lines = m3u8.components(separatedBy: .newlines)
        var removedIndices = Set<Int>()
        var adSegmentCount = 0

        // --- Phase 1: Detect ad segments ---

        let cueRemoved = detectCueAds(lines: lines)
        let urlRemoved = detectURLPatternAds(lines: lines)
        let durationRemoved = detectDurationAnomalies(lines: lines)

        removedIndices = cueRemoved.union(urlRemoved).union(durationRemoved)
        adSegmentCount = removedIndices.count

        // --- Phase 2: Rewrite ---

        let rewritten = rewriteVariantLines(
            lines: lines,
            removedIndices: removedIndices,
            proxyBaseURL: proxyBaseURL,
            segmentPathPrefix: segmentPathPrefix,
            initPathPrefix: initPathPrefix
        )

        return CleanResult(
            playlist: rewritten,
            removedIndices: removedIndices,
            adReplaced: adSegmentCount > 0,
            adSegmentCount: adSegmentCount
        )
    }

    // MARK: - Detection strategies

    /// Detects segments between `#EXT-X-CUE-OUT` and `#EXT-X-CUE-IN` markers.
    private func detectCueAds(lines: [String]) -> Set<Int> {
        var removed = Set<Int>()
        var inAd = false
        var segmentIndex = 0
        var adStartIndex = -1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("#EXT-X-CUE-OUT") {
                inAd = true
                adStartIndex = segmentIndex
                continue
            }

            if trimmed.hasPrefix("#EXT-X-CUE-IN") {
                if inAd, adStartIndex >= 0 {
                    for i in adStartIndex..<segmentIndex {
                        removed.insert(i)
                    }
                }
                inAd = false
                adStartIndex = -1
                continue
            }

            // Also detect SCTE35 via DATERANGE
            if trimmed.hasPrefix("#EXT-X-DATERANGE:") {
                let lower = trimmed.lowercased()
                if lower.contains("scte35-out") || lower.contains("cue=\"pre\"") || lower.contains("cue=\"post\"") {
                    inAd = true
                    adStartIndex = segmentIndex
                }
                if lower.contains("scte35-in") {
                    if inAd, adStartIndex >= 0 {
                        for i in adStartIndex..<segmentIndex {
                            removed.insert(i)
                        }
                    }
                    inAd = false
                    adStartIndex = -1
                }
                continue
            }

            // Count segments: non-# lines after #EXTINF
            if trimmed.hasPrefix("#EXTINF:") {
                continue
            }
            if !trimmed.hasPrefix("#") && !trimmed.isEmpty {
                segmentIndex += 1
            }
        }

        return removed
    }

    /// Detects segments whose URLs match known ad CDN patterns.
    private func detectURLPatternAds(lines: [String]) -> Set<Int> {
        var removed = Set<Int>()
        var segmentIndex = 0

        let adPatterns = [
            "amazon-ads", "a/video", "/ad/", "-ad-", "twitch-ad",
            "ads.", ".ads.", "doubleclick", "googlesyndication",
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTINF:") { continue }
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
                let durStr = trimmed
                    .replacingOccurrences(of: "#EXTINF:", with: "")
                    .replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                durations.append(Double(durStr) ?? 0)
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

    /// Rewrites variant playlist lines: removes ad segments, rewrites remaining URLs.
    private func rewriteVariantLines(
        lines: [String],
        removedIndices: Set<Int>,
        proxyBaseURL: String,
        segmentPathPrefix: String,
        initPathPrefix: String
    ) -> String {
        var result: [String] = []
        var segmentIndex = 0
        var mapIndex = 0
        var inAdBlock = false
        var pendingEXTINF: String?
        var wasAdRemoved = false
        var nextDiscontinuityNeeded = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Handle #EXTINF — buffer it, decide when we see the URL
            if trimmed.hasPrefix("#EXTINF:") {
                pendingEXTINF = line
                continue
            }

            // Ad marker tags
            if trimmed.hasPrefix("#EXT-X-CUE-OUT") || trimmed.hasPrefix("#EXT-X-CUE-IN") {
                if trimmed.hasPrefix("#EXT-X-CUE-OUT") { inAdBlock = true }
                if trimmed.hasPrefix("#EXT-X-CUE-IN") && inAdBlock {
                    inAdBlock = false
                    nextDiscontinuityNeeded = true
                }
                // Always strip CUE tags themselves
                continue
            }

            // DATERANGE with SCTE35 ad markers
            if trimmed.hasPrefix("#EXT-X-DATERANGE:") {
                let lower = trimmed.lowercased()
                if lower.contains("scte35-out") || lower.contains("cue=\"pre\"") {
                    inAdBlock = true
                    continue
                }
                if lower.contains("scte35-in") {
                    if inAdBlock {
                        inAdBlock = false
                        nextDiscontinuityNeeded = true
                    }
                    continue
                }
                // Non-ad DATERANGE — preserve
                result.append(line)
                continue
            }

            // Non-URL tags — preserve, but rewrite MAP/KEY URIs
            if trimmed.hasPrefix("#") {
                // Strip Twitch-specific tags
                if trimmed.hasPrefix("#EXT-X-TWITCH-") || trimmed.hasPrefix("#EXT-X-PREFETCH") {
                    continue
                }
                // Skip tags that were already handled
                if trimmed.hasPrefix("#EXT-X-CUE-") || trimmed.hasPrefix("#EXT-X-DATERANGE:") {
                    continue
                }
                // Rewrite #EXT-X-MAP URI to proxy
                if trimmed.hasPrefix("#EXT-X-MAP:URI=\"") {
                    if let rewritten = rewriteMapOrKey(line: line, proxyBaseURL: proxyBaseURL, pathPrefix: initPathPrefix, index: mapIndex) {
                        result.append(rewritten)
                        mapIndex += 1
                    } else {
                        result.append(line)
                    }
                    continue
                }
                // Rewrite #EXT-X-KEY URI to proxy
                if trimmed.hasPrefix("#EXT-X-KEY:") && trimmed.contains("URI=\"") {
                    if let rewritten = rewriteMapOrKey(line: line, proxyBaseURL: proxyBaseURL, pathPrefix: "/key", index: mapIndex) {
                        result.append(rewritten)
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

            // --- This is a segment URL ---
            let isAd = removedIndices.contains(segmentIndex) || inAdBlock

            if isAd {
                // Discard the segment and its #EXTINF
                pendingEXTINF = nil
                wasAdRemoved = true
                segmentIndex += 1
                continue
            }

            // Content segment
            if wasAdRemoved && nextDiscontinuityNeeded {
                result.append("#EXT-X-DISCONTINUITY")
                nextDiscontinuityNeeded = false
            }
            wasAdRemoved = false

            if let extinf = pendingEXTINF {
                result.append(extinf)
                pendingEXTINF = nil
            }

            // Rewrite segment URL to proxy
            let rewrittenURL = "\(proxyBaseURL)\(segmentPathPrefix)/\(segmentIndex)/\(trimmed.components(separatedBy: "/").last ?? trimmed)"
            result.append(rewrittenURL)
            segmentIndex += 1
        }

        // Don't leave a dangling EXTINF
        if let extinf = pendingEXTINF {
            result.append(extinf)
        }

        // Update TARGETDURATION if we removed segments (recompute from remaining)
        var finalResult: [String] = []
        for line in result {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXT-X-TARGETDURATION:") {
                // Keep original — AVPlayer handles longer durations fine
                finalResult.append(line)
                continue
            }
            finalResult.append(line)
        }

        return finalResult.joined(separator: "\n")
    }

    /// Rewrites the URI inside `#EXT-X-MAP:URI="..."` or `#EXT-X-KEY:URI="..."` to point to the proxy.
    private func rewriteMapOrKey(line: String, proxyBaseURL: String, pathPrefix: String, index: Int) -> String? {
        guard let uriStart = line.range(of: "URI=\"")?.upperBound,
              let uriEnd = line[uriStart...].range(of: "\"")?.lowerBound else { return nil }
        let uriString = String(line[uriStart..<uriEnd])
        let filename = uriString.components(separatedBy: "/").last ?? uriString
        let proxyURI = "\(proxyBaseURL)\(pathPrefix)/\(index)/\(filename)"
        return line.replacingCharacters(in: uriStart..<uriEnd, with: proxyURI)
    }
}
