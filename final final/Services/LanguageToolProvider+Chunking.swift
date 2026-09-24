//
//  LanguageToolProvider+Chunking.swift
//  final final
//
//  Segment consolidation and chunking for oversized documents, for LanguageToolProvider.
//  Split out of LanguageToolProvider.swift (where it already lived in its own in-file
//  extension) to keep that file under SwiftLint's file_length limit. Otherwise a
//  verbatim move -- one intentional deviation: a local variable was renamed from `ch`
//  to `character` in two places to satisfy SwiftLint's identifier_name rule.
//

import AppKit

extension LanguageToolProvider {
    // MARK: - Segment Consolidation

    struct SegmentMapping {
        let index: Int
        let fullTextOffset: Int
        let segment: SpellCheckService.TextSegment
    }

    private static let noSpaceBeforePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}"
    ]

    /// LanguageTool's own per-request character budget is roughly 40-60K depending
    /// on deployment, but consolidation can add joiners and the request is also
    /// form-urlencoded (which inflates non-ASCII/punctuation-heavy text well beyond
    /// its raw character count) — 18,000 UTF-16 units leaves comfortable headroom
    /// under the tightest known limit rather than chasing the server's actual ceiling.
    private static let maxRequestChars = 18_000

    /// Normalizes segments before consolidation: when a segment starts with
    /// punctuation that conventionally takes no preceding space, trims trailing
    /// whitespace from the nearest preceding same-block segment with real content —
    /// dropping any whitespace-only segments consumed along the way (artifacts of
    /// extractSegments flushing on every skipped inline atom: citations, footnotes,
    /// section breaks, annotations, hard breaks). This runs entirely on the
    /// `[TextSegment]` array, before fullText/offsetMap construction, so the
    /// existing single-pass consolidation loop and parseResponse's boundary check
    /// need no changes: segment.text already reflects what will actually be written.
    ///
    /// Note: a trimmed segment's `to` position is intentionally left unchanged
    /// (still reflects the original, untrimmed editor range) — nothing downstream
    /// reads `to` for offset arithmetic (only `from` + a LanguageTool match's own
    /// `length` are used), so this is safe, but keep it in mind if that changes.
    func normalizeSegmentsForElisionSeams(
        _ segments: [SpellCheckService.TextSegment]
    ) -> [SpellCheckService.TextSegment] {
        guard !segments.isEmpty else { return segments }
        var result = segments

        for i in 0..<result.count {
            guard let firstChar = result[i].text.first,
                  Self.noSpaceBeforePunctuation.contains(firstChar) else { continue }
            var precedingIndex = i - 1
            // Require non-nil blockId equality here, matching consolidateSegments'
            // own same-block test (`if let bid = segment.blockId, bid == lastBlockId`)
            // where a nil blockId is always treated as a different block. Without
            // this guard, two segments that both happen to have a nil blockId would
            // be treated as "same block" here but not there — a latent
            // inconsistency, even though in practice blockId is always populated
            // from a real ProseMirror position on the JS side and never nil.
            while precedingIndex >= 0, let precedingBid = result[precedingIndex].blockId, let iBid = result[i].blockId, precedingBid == iBid {
                if result[precedingIndex].text.allSatisfy(\.isWhitespace) {
                    // Whitespace-only segment (e.g. from a skipped annotation/hard
                    // break sandwiched between this seam and the previous real
                    // content) — fully absorbed by the elision, drop it.
                    if !result[precedingIndex].text.isEmpty {
                        result[precedingIndex] = SpellCheckService.TextSegment(
                            text: "", from: result[precedingIndex].from, to: result[precedingIndex].to, blockId: result[precedingIndex].blockId)
                    }
                    precedingIndex -= 1
                    continue
                }
                // Found the nearest real content — trim its trailing whitespace and stop.
                var text = result[precedingIndex].text
                while let last = text.last, last.isWhitespace {
                    text.removeLast()
                }
                result[precedingIndex] = SpellCheckService.TextSegment(
                    text: text, from: result[precedingIndex].from, to: result[precedingIndex].to, blockId: result[precedingIndex].blockId)
                break
            }
        }

        return result.filter { !$0.text.isEmpty }
    }

    func consolidateSegments(
        _ segments: [SpellCheckService.TextSegment]
    ) -> (String, [SegmentMapping]) {
        let segments = normalizeSegmentsForElisionSeams(segments)
        var fullText = ""
        var offsetMap: [SegmentMapping] = []
        var lastBlockId: Int?

        for (i, segment) in segments.enumerated() {
            if !fullText.isEmpty {
                if let bid = segment.blockId, bid == lastBlockId {
                    // Same paragraph. If this segment starts with no-preceding-space
                    // punctuation, normalization above already stripped the
                    // preceding segment's trailing whitespace, so no joiner is
                    // needed (and none should be added, or the artifact would come
                    // right back). Otherwise, only insert a joiner space if neither
                    // side already has whitespace at the seam, to avoid
                    // concatenating two real words into a bogus token.
                    let nextStartsWithNoSpacePunctuation = segment.text.first
                        .map { Self.noSpaceBeforePunctuation.contains($0) } ?? false
                    if !nextStartsWithNoSpacePunctuation {
                        let prevEndsWithWhitespace = fullText.last?.isWhitespace ?? false
                        let nextStartsWithWhitespace = segment.text.first?.isWhitespace ?? false
                        if !prevEndsWithWhitespace && !nextStartsWithWhitespace {
                            fullText += " "
                        }
                    }
                } else {
                    fullText += "\n\n"
                }
            }
            offsetMap.append(SegmentMapping(
                index: i,
                fullTextOffset: fullText.utf16.count,
                segment: segment))
            fullText += segment.text
            lastBlockId = segment.blockId
        }

        return (fullText, offsetMap)
    }

    // MARK: - Chunking for Oversized Documents

    /// Splits `segments` into chunk-sized groups when the consolidated document
    /// exceeds LanguageTool's per-request budget, or returns the single unsplit
    /// chunk otherwise (the common case, and byte-for-byte the old behavior). Each
    /// returned chunk is independently run through `consolidateSegments` — the same
    /// text-joining logic as the normal single-request path — so chunking never
    /// changes what a single request's payload looks like, only how many requests
    /// the whole logical check ends up being split across. Not private: called from
    /// `check(segments:)` in LanguageToolProvider.swift, and Swift's `private` is
    /// file-scoped.
    func buildChunks(from segments: [SpellCheckService.TextSegment]) -> [RequestChunk] {
        let (fullText, offsetMap) = consolidateSegments(segments)
        guard fullText.utf16.count > Self.maxRequestChars else {
            return [RequestChunk(fullText: fullText, offsetMap: offsetMap, segmentCount: segments.count)]
        }

        DebugLog.log(.proofing,
            "[LT] chunking: consolidated text \(fullText.utf16.count) chars exceeds " +
            "\(Self.maxRequestChars) — splitting into multiple requests")

        let normalized = normalizeSegmentsForElisionSeams(segments)
        let splitSafe = splitOversizedSegments(normalized, limit: Self.maxRequestChars)
        let groups = groupIntoChunks(splitSafe)

        return groups.map { group in
            let (groupText, groupOffsetMap) = consolidateSegments(group)
            return RequestChunk(fullText: groupText, offsetMap: groupOffsetMap, segmentCount: group.count)
        }
    }

    /// Packs already-split-safe segments (see `splitOversizedSegments` — every
    /// segment here is individually guaranteed to fit within `maxRequestChars`)
    /// into groups that each fit once consolidated. Segments are first collapsed
    /// into contiguous same-`blockId` runs (a nil `blockId` never joins a run,
    /// matching `consolidateSegments`'s own same-block test); a chunk is closed
    /// between two runs — never inside one — whenever possible, and only falls
    /// back to closing mid-run, at a plain segment boundary, when a single run's
    /// segments alone don't fit in one chunk. Every length check carries a small
    /// (+2 per segment) slack for the "\n\n" or " " joiner `consolidateSegments`
    /// may insert at a seam, so the actual consolidated text for any returned
    /// group is guaranteed to fit even though this function never calls
    /// `consolidateSegments` itself.
    private func groupIntoChunks(
        _ segments: [SpellCheckService.TextSegment]
    ) -> [[SpellCheckService.TextSegment]] {
        guard !segments.isEmpty else { return [] }

        var runs: [[SpellCheckService.TextSegment]] = []
        for segment in segments {
            if let bid = segment.blockId, let lastBid = runs.last?.last?.blockId, bid == lastBid {
                runs[runs.count - 1].append(segment)
            } else {
                runs.append([segment])
            }
        }

        func projectedLength(of run: [SpellCheckService.TextSegment]) -> Int {
            run.reduce(0) { $0 + $1.text.utf16.count + 2 }
        }

        var groups: [[SpellCheckService.TextSegment]] = []
        var current: [SpellCheckService.TextSegment] = []
        var currentLength = 0

        func closeCurrent() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current = []
            currentLength = 0
        }

        for run in runs {
            let runLength = projectedLength(of: run)
            if !current.isEmpty && currentLength + runLength > Self.maxRequestChars {
                closeCurrent()
            }
            if runLength > Self.maxRequestChars {
                // This one block's segments alone don't fit in a chunk — fall back
                // to packing at plain segment boundaries within the run (never
                // mid-segment: splitOversizedSegments already guarantees no single
                // segment alone exceeds the budget).
                for segment in run {
                    let segmentLength = segment.text.utf16.count + 2
                    if !current.isEmpty && currentLength + segmentLength > Self.maxRequestChars {
                        closeCurrent()
                    }
                    current.append(segment)
                    currentLength += segmentLength
                }
            } else {
                current.append(contentsOf: run)
                currentLength += runLength
            }
        }
        closeCurrent()
        return groups
    }

    /// Cuts any segment whose text exceeds `limit` UTF-16 units into sub-segments
    /// that each fit, preserving exact editor-offset accounting: a running
    /// `cursor` (starting at the original segment's `from`) is advanced by each
    /// emitted piece's own UTF-16 length, so `to - from == text.utf16.count` holds
    /// for every piece regardless of how the cut points were chosen. Segments at
    /// or under `limit` pass through unchanged. Production call sites always pass
    /// `maxRequestChars`; tests pass a much smaller value to exercise the
    /// splitting logic at test scale. (No default value here: a default
    /// argument expression is evaluated in a nonisolated context, but
    /// `maxRequestChars` is `@MainActor`-isolated as a static member of this
    /// class — the caller supplies it explicitly instead.)
    func splitOversizedSegments(
        _ segments: [SpellCheckService.TextSegment],
        limit: Int
    ) -> [SpellCheckService.TextSegment] {
        var result: [SpellCheckService.TextSegment] = []
        for segment in segments {
            guard segment.text.utf16.count > limit else {
                result.append(segment)
                continue
            }
            result.append(contentsOf: splitOversizedSegment(segment, limit: limit))
        }
        return result
    }

    private func splitOversizedSegment(
        _ segment: SpellCheckService.TextSegment,
        limit: Int
    ) -> [SpellCheckService.TextSegment] {
        var pieces: [SpellCheckService.TextSegment] = []
        var remaining = Substring(segment.text)
        var cursor = segment.from

        while remaining.utf16.count > limit {
            let cut = cutIndex(in: remaining, utf16Limit: limit)
            let piece = remaining[remaining.startIndex..<cut]
            let pieceCount = piece.utf16.count
            pieces.append(SpellCheckService.TextSegment(
                text: String(piece), from: cursor, to: cursor + pieceCount, blockId: segment.blockId))
            cursor += pieceCount
            remaining = remaining[cut...]
        }

        let pieceCount = remaining.utf16.count
        pieces.append(SpellCheckService.TextSegment(
            text: String(remaining), from: cursor, to: cursor + pieceCount, blockId: segment.blockId))

        return pieces
    }

    /// Picks where to cut `text` at or before `utf16Limit`: prefers the last
    /// sentence boundary (". ", "! ", "? "), else the last whitespace run, else a
    /// grapheme-safe hard cut (logged, since a hard cut with no natural boundary
    /// at all is the silent-degradation case this whole feature exists to catch).
    private func cutIndex(in text: Substring, utf16Limit: Int) -> String.Index {
        if let idx = lastSentenceBoundary(in: text, utf16Limit: utf16Limit) {
            return idx
        }
        if let idx = lastWhitespaceBoundary(in: text, utf16Limit: utf16Limit) {
            return idx
        }
        DebugLog.log(.proofing, "[LT] hard-split oversized segment with no boundary at \(utf16Limit)")
        return Self.hardCutIndex(in: text, utf16Limit: utf16Limit)
    }

    /// Returns the index just after the last ". "/"! "/"? " occurring at or before
    /// `utf16Limit`, or nil if none exists in range.
    private func lastSentenceBoundary(in text: Substring, utf16Limit: Int) -> String.Index? {
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        var count = 0
        var candidate: String.Index?
        var previousWasEnder = false

        for i in text.indices {
            let character = text[i]
            let utf16Length = character.utf16.count
            if count + utf16Length > utf16Limit { break }
            count += utf16Length
            if previousWasEnder && character == " " {
                candidate = text.index(after: i)
            }
            previousWasEnder = sentenceEnders.contains(character)
        }
        return candidate
    }

    /// Returns the index just after the last whitespace character occurring at or
    /// before `utf16Limit`, or nil if none exists in range.
    private func lastWhitespaceBoundary(in text: Substring, utf16Limit: Int) -> String.Index? {
        var count = 0
        var candidate: String.Index?

        for i in text.indices {
            let character = text[i]
            let utf16Length = character.utf16.count
            if count + utf16Length > utf16Limit { break }
            count += utf16Length
            if character.isWhitespace {
                candidate = text.index(after: i)
            }
        }
        return candidate
    }

    /// Grapheme-safe last resort when no sentence or whitespace boundary exists
    /// before the limit: walks whole `Character`s (always full grapheme-cluster
    /// boundaries) so the cut can never land inside a surrogate pair or otherwise
    /// split a multi-code-unit character (e.g. an emoji) in half. Always advances
    /// by at least one character when `text` is non-empty, guaranteeing forward
    /// progress even if a single character alone exceeds `utf16Limit`.
    private static func hardCutIndex(in text: Substring, utf16Limit: Int) -> String.Index {
        var count = 0, cut = text.startIndex
        for i in text.indices {
            let utf16Length = text[i].utf16.count
            if count + utf16Length > utf16Limit { break }
            count += utf16Length; cut = text.index(after: i)
        }
        if cut == text.startIndex, !text.isEmpty { cut = text.index(after: cut) }
        return cut
    }
}
