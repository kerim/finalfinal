//
//  SectionSyncService+Anchors.swift
//  final final
//

import Foundation

// MARK: - Section Anchor Support

extension SectionSyncService {

    /// Regex pattern for section anchor comments
    /// Anchors are on the same line as headers (no newline in pattern)
    static let anchorPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"<!-- @sid:([0-9a-fA-F-]+) -->"#,
                options: []
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Inject section anchors before each header in markdown
    /// Used when switching from WYSIWYG to source mode
    /// Anchors are placed on the SAME LINE as headers (no newline after anchor)
    /// to prevent blank lines when CodeMirror hides the anchor comment
    /// - Parameters:
    ///   - markdown: The markdown content
    ///   - sections: Current sections with their IDs
    /// - Returns: Markdown with anchors injected before headers
    func injectSectionAnchors(markdown: String, sections: [SectionViewModel]) -> String {
        guard !sections.isEmpty else { return markdown }

        // Build a map of header text to section ID
        // We match by finding headers in the markdown and associating them with sections
        var result = markdown

        // Sort sections by startOffset in reverse order (inject from end to avoid offset drift)
        let sortedSections = sections.sorted { $0.startOffset > $1.startOffset }

        for section in sortedSections {
            // Find the header line at the section's start offset
            let offset = min(section.startOffset, result.count)
            let insertionIndex = result.index(result.startIndex, offsetBy: offset)

            // Inject anchor on SAME LINE as header (no newline)
            let anchor = "<!-- @sid:\(section.id) -->"
            result.insert(contentsOf: anchor, at: insertionIndex)
        }

        return result
    }

    /// Extract section anchors and their IDs from markdown
    /// Used when switching from source mode back to WYSIWYG
    /// Anchors are expected to be on the same line as headers: `<!-- @sid:UUID --># Header`
    /// - Parameter markdown: The markdown content with anchors
    /// - Returns: Tuple of (clean markdown, anchor mappings)
    func extractSectionAnchors(markdown: String) -> (markdown: String, anchors: [SectionAnchorMapping]) {
        var anchors: [SectionAnchorMapping] = []
        let nsRange = NSRange(markdown.startIndex..., in: markdown)

        // Find all anchors and their positions
        let matches = Self.anchorPattern.matches(in: markdown, options: [], range: nsRange)

        var offsetAdjustment = 0

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: markdown) else { continue }

            let anchorId = String(markdown[idRange])
            let originalOffset = match.range.location

            // Calculate the offset in the cleaned markdown (after previous anchors removed)
            let cleanedOffset = originalOffset - offsetAdjustment

            anchors.append(SectionAnchorMapping(
                sectionId: anchorId,
                headerOffset: cleanedOffset
            ))

            // Track how much we've removed for offset adjustment
            // match.range.length gives us the length of the full match
            offsetAdjustment += match.range.length
        }

        // Remove all anchors from the markdown
        let cleanedMarkdown = Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: nsRange,
            withTemplate: ""
        )

        return (cleanedMarkdown, anchors)
    }

    /// Strip all section anchors from markdown
    /// Used for clean export and display
    func stripSectionAnchors(from markdown: String) -> String {
        Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: NSRange(markdown.startIndex..., in: markdown),
            withTemplate: ""
        )
    }

    // MARK: - Bibliography Marker Support

    /// Inject bibliography marker before the bibliography section header
    /// Used when building sourceContent for CodeMirror (follows section anchor pattern)
    ///
    /// Unlike sites A (`BlockParser`) and B (`SectionSyncService.parseHeaders`), this site had no
    /// content tokenizer at all before this redesign — the entire function used to be one
    /// `regex.firstMatch(...)` against the whole string, followed by an unconditional insert at
    /// whatever it found (or an unconditional early return if it found nothing). There was no
    /// marker `.contains` check, no terminator scan, and no "last match anywhere" fallback; see
    /// `git show 097e4ba1:"final final/Services/SectionSyncService+Anchors.swift"` for that exact
    /// prior shape. It now enumerates `markdown` BY LINE (same granularity as site B, via
    /// `enumerateSubstrings(.byLines)`) into a `[BibliographyOpeningSelector.Unit]` sequence and
    /// delegates the actual decision to `BibliographyOpeningSelector.select` — see that type's
    /// doc comment for the full two-tier rule and why tier 3 was deleted rather than weakened.
    ///
    /// This site's predicates:
    /// - `isMarker`: `line.contains("<!-- ::auto-bibliography:: -->")` (mirrors the old
    ///   document-wide `.contains` check — now per-line, but the FIRST line satisfying it is
    ///   still unit index 0's marker match, matching the old unconditional-first-match
    ///   behavior).
    /// - `isTerminator`: the trimmed line exactly equals `BlockParser.bibliographyEndMarker`
    ///   (mirrors the old exact-equality scan; a glued/doubled marker line can CONTAIN the
    ///   terminator literal without ever being the terminator itself, so a substring search
    ///   would bind the wrong bound).
    /// - `isCandidate`: the existing anchored regex (`#{1,2} <escaped effectiveBibliographyHeaderName>`,
    ///   with optional `@sid` anchor prefix) matches that line. Regex match `NSRange`s are
    ///   mapped onto the line sequence below by locating which line each match's start falls
    ///   within.
    /// - `isHeading`: any line matching a `#{1,6}\s` heading pattern, with the SAME optional
    ///   `@sid` anchor prefix `isCandidate` tolerates — broader than `isCandidate` otherwise (a
    ///   heading that ISN'T the bibliography title still counts as a heading for run-emptiness
    ///   purposes, matching must-fix 1's intent). The anchor-prefix tolerance matters because
    ///   every production caller pipes `injectSectionAnchors(...)` output straight into this
    ///   function, so a non-candidate heading in the run is anchor-prefixed too
    ///   (`<!-- @sid:UUID --># Chapter`) and would otherwise fail the bare pattern (the line
    ///   starts with `<!--`), getting miscounted as content instead of excluded as a heading.
    ///   Unlike sites A/B, this site has no code-fence or Notes-latch gating at all (row 9 of
    ///   the per-site behavior table), so `isHeading`/`isCandidate`/`isTerminator` are computed
    ///   unconditionally per line.
    /// - `isEmpty`: blank/whitespace-only lines.
    ///
    /// `.marker` -> return `markdown` unchanged (the markdown already unambiguously identifies
    /// its own bibliography heading; injecting a SECOND marker onto some other line, e.g. a
    /// bare-title heading that merely shares the bibliography's title, would leave two markers
    /// in the document — `BlockParser.parse`'s own tier 1 then takes the FIRST marker it finds
    /// in raw-block order, which need not be the one this function would otherwise have
    /// chosen). `.none` -> ALSO return `markdown` unchanged — this is a deliberate behavior
    /// change from before, not a preserved one: the old code (see the doc comment above) had no
    /// tier concept and no terminator concept at all — it simply took `regex.firstMatch`'s
    /// result, i.e. the FIRST title-matching heading anywhere in the document, and wrote onto it
    /// unconditionally whenever one existed. That could write a real marker onto an EARLIER
    /// decoy heading that merely shares the bibliography title (with the genuine, terminator-
    /// bounded section sitting further down), or onto a heading with no real content beneath it
    /// at all — exactly the shapes `BlockParser` now deliberately refuses to flag. Both paths are
    /// closed here: nothing is written unless `select` finds real evidence. `.candidate(i)` ->
    /// insert the marker at that line's start range — matching the old code's own insertion
    /// mechanics (insert at the matched heading's start), just now gated on `select`'s evidence
    /// instead of firing unconditionally on the first regex match.
    /// - Parameters:
    ///   - markdown: The markdown content (with section anchors already injected)
    ///   - sections: Current sections to identify bibliography
    /// - Returns: Markdown with bibliography marker injected before the bibliography header
    func injectBibliographyMarker(markdown: String, sections: [SectionViewModel]) -> String {
        // Bail if there is no bibliography section at all.
        guard sections.contains(where: { $0.isBibliography }) else {
            return markdown
        }

        // Find the bibliography header in the markdown
        // The header might be prefixed with a section anchor: <!-- @sid:UUID --># Bibliography
        //
        // Judge-round fix: match against every ACCEPTABLE name (the two built-ins, the
        // current effective name, and the whole grace list of previously-used names --
        // `ExportSettings.acceptableBibliographyHeaderNames`, the same list every other
        // recognition site in this feature accepts), not just the single current effective
        // name. Without this, a document whose heading still reads an older, grace-listed
        // name (a real, expected shape right after a rename -- see
        // `ExportSettings.previousBibliographyHeaderNames`'s doc comment) would stop getting
        // its Source Mode marker injected here even though `isBibliography` flags survive via
        // the grace-list bare-title match at every other site -- a degradation, not data
        // loss, but the same class of omission the whole grace-list mechanism exists to
        // prevent.
        let acceptableNames = ExportSettingsManager.shared.settings.acceptableBibliographyHeaderNames

        // Try to find the header with or without anchor prefix
        // Pattern: line-start + optional anchor + "#" or "##" + " (Name1|Name2|...)" + line-end.
        // Anchored on both ends (via `^`/`$` with `.anchorsMatchLines`) so this can never
        // match mid-line inside a legitimate `## <name>` H2 heading (unanchored, "# Name"
        // matches the substring starting at the second "#" of "## Name", corrupting the
        // content with the marker inserted between the two "#" characters), and can never
        // match an EARLIER ordinary heading that's merely a textual prefix of the
        // bibliography name (e.g. "# Bibliography Notes" before the real "# Bibliography"
        // heading later in the document -- unanchored, "# Bibliography" matches as a
        // prefix of that first line and `firstMatch` stops there). `#{1,2}` mirrors
        // `BlockParser.isBibliographyHeading`, which accepts both the `#` and `##` forms.
        let anchorPrefixPattern = #"(<!-- @sid:[0-9a-fA-F-]+ -->)?"#
        let escapedAlternation = acceptableNames
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let headerPattern = "^" + anchorPrefixPattern + #"#{1,2} (?:\#(escapedAlternation))$"#
        // `isHeading` below needs this SAME anchor-prefix tolerance: every production caller of
        // this function pipes `injectSectionAnchors(...)` output straight in, so a non-candidate
        // heading sitting between the selected candidate and the terminator is anchor-prefixed
        // (`<!-- @sid:UUID --># Chapter`) exactly like the candidate heading itself. Without this,
        // such a line's bare `#{1,6}\s` check fails (the line starts with `<!--`), so it gets
        // scored as CONTENT rather than excluded as a heading -- letting this site select and
        // permanently WRITE a marker onto a heading `BlockParser` deliberately refuses to flag.
        let headingLinePattern = "^" + anchorPrefixPattern + #"#{1,6}\s"#

        guard let regex = try? NSRegularExpression(pattern: headerPattern, options: [.anchorsMatchLines]) else {
            return markdown
        }

        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: nsRange)

        // Tokenize the markdown by line -- see this function's doc comment.
        var lineRanges: [Range<String.Index>] = []
        markdown.enumerateSubstrings(in: markdown.startIndex..<markdown.endIndex, options: .byLines) { _, lineRange, _, _ in
            lineRanges.append(lineRange)
        }

        // Map each regex match's start position onto the line it falls within, so isCandidate
        // can be a per-line boolean like every other predicate.
        var candidateLineIndices: Set<Int> = []
        for match in matches {
            guard let matchStart = Range(match.range, in: markdown)?.lowerBound else { continue }
            if let lineIndex = lineRanges.firstIndex(where: { $0.contains(matchStart) || $0.upperBound == matchStart }) {
                candidateLineIndices.insert(lineIndex)
            }
        }

        let units: [BibliographyOpeningSelector.Unit] = lineRanges.enumerated().map { index, range in
            let line = String(markdown[range])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return BibliographyOpeningSelector.Unit(
                isMarker: line.contains("<!-- ::auto-bibliography:: -->"),
                isTerminator: trimmed == BlockParser.bibliographyEndMarker,
                isCandidate: candidateLineIndices.contains(index),
                isHeading: trimmed.range(of: headingLinePattern, options: .regularExpression) != nil,
                isEmpty: trimmed.isEmpty,
                isStandaloneMarker: trimmed == BlockParser.bibliographyStartMarker
            )
        }

        // Site C bails on ANY marker, supported or not — independent of the selector's tier-1
        // support rule. This is a genuine, deliberate BEHAVIOR CHANGE from before this redesign,
        // not a preserved one: the old function (see the doc comment above) had no marker check
        // at all and would happily write a second marker onto whatever `regex.firstMatch` found,
        // even into a document that already carried one elsewhere. That guard is new here because
        // falling through to tier 2 in a document that already has a marker would insert a SECOND
        // marker; `BlockParser.parse` then takes the FIRST marker it finds in raw-block order,
        // which need not be this one — so a second write here could silently pick the wrong
        // opening for every other reader of the document.
        guard !units.contains(where: { $0.isMarker }) else { return markdown }

        switch BibliographyOpeningSelector.select(units) {
        case .marker, .none:
            return markdown
        case .candidate(let index):
            var result = markdown
            let marker = "<!-- ::auto-bibliography:: -->"
            result.insert(contentsOf: marker, at: lineRanges[index].lowerBound)
            return result
        }
    }

    /// Strip bibliography marker from markdown
    /// Used when cleaning content for Milkdown or export
    /// nonisolated: pure string operation, safe to call from any context (e.g. BlockParser)
    nonisolated static func stripBibliographyMarker(from markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: "")
    }

    /// Strip the bibliography-end terminator (`BlockParser.bibliographyEndMarker`) from
    /// markdown. Used only by display-only sinks (e.g. `SectionCardView.swift`'s sidebar
    /// preview text) — NOT by anything that builds `editorState.content`, where the
    /// terminator must survive so the pre-export reparse still sees it. See
    /// `BlockParser.bibliographyEndMarker`'s doc comment.
    /// nonisolated: pure string operation, safe to call from any context (e.g. BlockParser).
    nonisolated static func stripBibliographyEndMarker(from markdown: String) -> String {
        markdown.replacingOccurrences(of: BlockParser.bibliographyEndMarker, with: "")
    }
}
