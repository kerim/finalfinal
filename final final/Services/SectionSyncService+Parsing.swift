//
//  SectionSyncService+Parsing.swift
//  final final
//

import Foundation

// MARK: - Header Parsing

extension SectionSyncService {

    /// Parse markdown content into ParsedHeader structs for reconciliation
    /// - Parameters:
    ///   - markdown: The markdown content to parse
    ///   - existingBibTitle: Title of the existing bibliography section (if any) to detect bibliography by title match
    ///   - existingNotesTitle: Title of the existing notes section (if any) to detect notes by title match
    ///   - fallbackBibTitle: Bibliography header name from settings (captured on MainActor before calling)
    nonisolated static func parseHeaders(
        from markdown: String,
        existingBibTitle: String? = nil,
        existingNotesTitle: String? = nil,
        fallbackBibTitle: String = "Bibliography"
    ) -> [ParsedHeader] {

        var headers: [ParsedHeader] = []
        var currentOffset = 0
        var inCodeBlock = false
        var inAutoBibliography = false  // Track auto-bibliography section (managed by BibliographySyncService)
        var inAutoNotes = false  // Track auto-notes section (managed by FootnoteSyncService)

        // Track section boundaries
        struct SectionBoundary {
            let startOffset: Int
            let level: Int
            let title: String
            let isPseudoSection: Bool
            let isBibliography: Bool
            let isNotes: Bool
        }

        var boundaries: [SectionBoundary] = []
        var lastActualHeaderLevel: Int = 1  // Default to H1 for pseudo-sections at document start

        // Track where bibliography/notes sections start (to end preceding section there).
        // `confirmedNotesOffsets` is a collection (MUST-FIX 4), not a single scalar, since more
        // than one candidate below can independently confirm as a real Notes section (the
        // common case is one; a document could in principle contain two genuine machine-managed
        // Notes headings across a section split-and-remerge history) -- each confirmed offset
        // bounds whichever preceding boundary would otherwise swallow past it, in the loop below.
        var bibliographyStartOffset: Int?
        var confirmedNotesOffsets: [Int] = []

        // A single Notes-titled heading found during the main loop, not yet confirmed as a
        // real machine-managed Notes section -- see the shared post-loop evidence check below.
        // Tracked in a COLLECTION (MUST-FIX 4), not two overwritten scalars: a document can
        // contain multiple headings sharing the same title -- one real, machine-managed
        // "Notes" section, and one unrelated user heading that merely happens to share the
        // name (e.g. an appendix literally titled "Notes"). With two scalars, a later
        // same-titled heading silently overwrote the earlier candidate's offset/index before
        // the evidence check ever ran, so only the LAST heading titled "Notes" was ever
        // evidence-checked; if THAT one had no real footnote content beneath it, neither
        // heading got flagged -- the real, evidenced Notes section earlier in the document
        // silently lost its isNotes flag purely because of what came after it. Each candidate
        // below is evaluated against its own content span independently, so an unconfirmed
        // heading can never blind out a confirmed one.
        struct PendingNotesCandidate {
            let offset: Int
            let boundaryIndex: Int
        }
        var pendingNotesCandidates: [PendingNotesCandidate] = []

        // Bibliography detection: use existing title if provided, otherwise fall back to configured name
        let bibHeaderName = existingBibTitle ?? fallbackBibTitle
        // Notes detection: use existing title if provided, otherwise fall back to "Notes"
        let notesHeaderName = existingNotesTitle ?? "Notes"

        // First pass: find all headers and pseudo-sections
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        // Pre-scan: select the ONE line offset (if any) that opens the bibliography section
        // by title match, delegating to the same shared `BibliographyOpeningSelector` two-tier
        // rule `BlockParser.parse`'s `selectBibliographyOpeningIndex` uses — a legacy marker
        // line wins outright; otherwise the LAST candidate title match strictly before the
        // first terminator, provided a genuine non-empty run separates them; otherwise nothing.
        // Without this, the loop below opened the section at the FIRST title match, which is
        // exactly backwards for a document containing a user heading that merely equals the
        // bibliography header name ABOVE the real, machine-managed heading.
        let selectedBibliographyOffset = selectBibliographyOpeningOffset(
            lines: lines,
            bibHeaderName: bibHeaderName,
            existingBibTitle: existingBibTitle,
            notesHeaderName: notesHeaderName,
            existingNotesTitle: existingNotesTitle
        )

        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            // Legacy marker support: still detect marker if present in old content. This is NOT
            // an independent detection mechanism -- it defers entirely to the shared-selector-
            // backed pre-scan (`selectedBibliographyOffset`) above: a marker line only opens the
            // managed region when it IS the one line the pre-scan itself selected. An orphan
            // marker the pre-scan judged unsupported (see `BibliographyOpeningSelector`'s
            // `markerIsSupported`) falls through here as a no-op line, exactly like any other
            // comment the parser doesn't recognize -- it must never latch `inAutoBibliography`
            // on its own account, or every heading for the rest of the document (including a
            // correctly-placed real bibliography) silently vanishes from the outline.
            if trimmed.hasPrefix(BlockParser.bibliographyStartMarker) {
                if currentOffset == selectedBibliographyOffset {
                    inAutoBibliography = true
                    bibliographyStartOffset = currentOffset
                }
                // MUST run on both branches: an unselected marker line that fails to advance
                // currentOffset desyncs every subsequent line's offset from the real markdown,
                // silently breaking `selectedBibliographyOffset` matching and the reconciler's
                // section boundaries.
                currentOffset += lineStr.count + 1  // +1 for newline
                continue  // Skip - header on same line, don't parse as separate section
            }

            // The managed region is terminator-bounded, matching the pre-scan's own gating
            // exactly: once `BlockParser.bibliographyEndMarker` is seen (by exact equality on
            // the trimmed line, never `.contains`) while the region is open, close it so headings
            // after it (e.g. a real "Appendix") surface again instead of being absorbed forever.
            if inAutoBibliography && !inCodeBlock && !inAutoNotes && trimmed == BlockParser.bibliographyEndMarker {
                inAutoBibliography = false
                currentOffset += lineStr.count + 1  // +1 for newline
                continue
            }

            // Skip headers inside code blocks or auto-managed sections
            if !inCodeBlock && !inAutoBibliography && !inAutoNotes {
                // Check for pseudo-section marker
                if trimmed == "<!-- ::break:: -->" {
                    // Pseudo-sections inherit level from preceding header (not 0!)
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: lastActualHeaderLevel,
                        title: "§ Section Break",
                        isPseudoSection: true,
                        isBibliography: false,
                        isNotes: false
                    ))
                    // Do NOT update lastActualHeaderLevel - pseudo-sections don't affect it
                }
                // Check for header
                else if let header = parseHeaderLine(trimmed) {
                    // Detect bibliography by title match (when no marker is present) — but
                    // ONLY at the pre-scan's selected offset, not at every title match: a
                    // title match that isn't the selected line falls through to the branches
                    // below (notes / import-detection / ordinary heading) exactly like any
                    // other non-matching heading. This allows detection even after the marker
                    // is removed from stored content, while telling a bare-title user heading
                    // apart from the real, machine-managed one — see
                    // `selectBibliographyOpeningOffset`'s doc comment for the full rule.
                    if currentOffset == selectedBibliographyOffset {
                        inAutoBibliography = true
                        bibliographyStartOffset = currentOffset
                        // Emit a boundary (flagged isBibliography) so the reconciler can see
                        // this heading and thread the verdict into a real Section row --
                        // previously dropped entirely here, which is why Section.isBibliography
                        // was never set true by any production writer. Deliberately does NOT
                        // update lastActualHeaderLevel: this heading is machine-managed, not a
                        // real structural heading subsequent pseudo-sections should inherit from.
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: true,
                            isNotes: false
                        ))
                    } else if header.title == notesHeaderName && existingNotesTitle != nil {
                        // MUST-FIX 1: bare title equality alone is NOT evidence a real
                        // machine-managed Notes section opens here -- unlike bibliography,
                        // which only latches via an offset the pre-scan selected using
                        // marker/terminator evidence, this branch used to latch `inAutoNotes`
                        // unconditionally on title match alone, with no closing condition at
                        // all, silently swallowing every boundary from here to end-of-document
                        // on the next parse (real, silent Section-row data loss for any
                        // document with a heading literally titled "Notes"). Fixed by
                        // deferring the decision exactly like the import-auto-detection branch
                        // just below: add as an ordinary (unflagged) boundary for now --
                        // headers after this point are still recognized normally either way --
                        // and record its index so the shared post-loop evidence check (below
                        // the main loop) can retroactively flag it once real footnote content
                        // ([^N]: pattern) is confirmed beneath it. Deliberately does NOT set
                        // `inAutoNotes` here (unlike the old, buggy version of this branch), and
                        // deliberately does NOT update `lastActualHeaderLevel` either --
                        // pre-existing asymmetry versus the branch below, out of scope to change.
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: false,
                            isNotes: false
                        ))
                        pendingNotesCandidates.append(
                            PendingNotesCandidate(offset: currentOffset, boundaryIndex: boundaries.count - 1)
                        )
                    } else if header.title == "Notes" && existingNotesTitle == nil {
                        // Import auto-detection: tentatively add as regular section,
                        // but record its index so we can flag it isNotes if content has [^N]: patterns
                        lastActualHeaderLevel = header.level
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: false,
                            isNotes: false
                        ))
                        pendingNotesCandidates.append(
                            PendingNotesCandidate(offset: currentOffset, boundaryIndex: boundaries.count - 1)
                        )
                    } else {
                        lastActualHeaderLevel = header.level  // Track for subsequent pseudo-sections
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: false,
                            isNotes: false
                        ))
                    }
                }
            }

            currentOffset += lineStr.count + 1 // +1 for newline
        }

        // Evidence check, shared by BOTH the "existingNotesTitle != nil" (MUST-FIX 1) and the
        // "existingNotesTitle == nil" (import auto-detection) tentative-heading branches above.
        // The real invariant (MUST-FIX 4): ACROSS the two branches, exactly one can ever fire
        // for a single parseHeaders call, since existingNotesTitle is a single constant for the
        // whole call -- that part of the old comment was correct. But WITHIN a single branch,
        // the SAME branch can fire once per matching heading, so a document with two headings
        // sharing the notes title produces two entries in `pendingNotesCandidates`, not one --
        // sharing pending state between the branches was never actually the risk; overwriting
        // one candidate's state with another's, within a single branch, was. Each candidate is
        // therefore evaluated independently right here, against its OWN content span, so a
        // later same-titled heading with no real evidence can never suppress an earlier one
        // that has it (see `pendingNotesCandidates`'s doc comment above for the concrete
        // data-loss scenario this avoids). Check whether each candidate's own content contains
        // [^N]: footnote-definition patterns to avoid false positives on a heading that merely
        // shares the notes title/name with no real footnote content beneath it.
        for candidate in pendingNotesCandidates {
            // Extract the content of this candidate's own section
            let nextBoundaryOffset = candidate.boundaryIndex + 1 < boundaries.count
                ? boundaries[candidate.boundaryIndex + 1].startOffset
                : markdown.count
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(candidate.offset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(nextBoundaryOffset, markdown.count))
            let pendingContent = String(markdown[startIdx..<endIdx])

            // Check for [^N]: definition patterns, ANCHORED to line start (MUST-FIX 3) --
            // every other footnote-definition regex in the codebase (MarkdownUtils.swift,
            // FootnoteSyncService+Reconciliation.swift, BlockParser.swift,
            // Database+BlocksInsert.swift, BlockParser+Splitting.swift) anchors with `^` (plus
            // `.anchorsMatchLines` for a multi-line haystack like this one) rather than
            // searching anywhere in the string. Unanchored, a section merely discussing
            // footnote syntax inline -- e.g. prose containing "write it as [^1]: text" -- would
            // false-positively read as real footnote-definition evidence. `String.range(of:
            // options:)`'s `.regularExpression` compare option has no `.anchorsMatchLines`
            // equivalent, so this needs `NSRegularExpression` directly, same as every other
            // anchored example above.
            let contentRange = NSRange(pendingContent.startIndex..., in: pendingContent)
            let hasFootnoteEvidence = (try? NSRegularExpression(
                pattern: #"^\[\^\d+\]:"#, options: [.anchorsMatchLines]
            ))?.firstMatch(in: pendingContent, range: contentRange) != nil

            guard hasFootnoteEvidence else { continue }

            // Confirmed as notes section: flag the boundary IN PLACE (kept, never removed
            // -- Part 2 / this task) so parseHeaders emits it and the reconciler can thread
            // the isNotes verdict into a real Section row, mirroring how the bibliography
            // pre-scan above emits a flagged boundary rather than dropping it. Reconstructs
            // the element (rather than mutating a `var` field) since every other field is
            // unchanged.
            let pending = boundaries[candidate.boundaryIndex]
            boundaries[candidate.boundaryIndex] = SectionBoundary(
                startOffset: pending.startOffset,
                level: pending.level,
                title: pending.title,
                isPseudoSection: pending.isPseudoSection,
                isBibliography: pending.isBibliography,
                isNotes: true
            )
            confirmedNotesOffsets.append(candidate.offset)
            inAutoNotes = true
        }

        guard !boundaries.isEmpty else { return [] }

        // Second pass: calculate content for each section
        let contentLength = markdown.count

        for (index, boundary) in boundaries.enumerated() {
            var endOffset: Int
            if index < boundaries.count - 1 {
                endOffset = boundaries[index + 1].startOffset
            } else {
                endOffset = contentLength
            }

            // If this is the last section before bibliography/notes, end it at the managed section
            // This prevents managed section content from being absorbed into the preceding section.
            // Loops over every confirmed offset (MUST-FIX 4 may confirm more than one candidate)
            // rather than a single scalar; clamping to whichever qualifying offset is smallest is
            // order-independent, since each pass can only shrink `endOffset` further.
            for notesStart in confirmedNotesOffsets where boundary.startOffset < notesStart && endOffset > notesStart {
                endOffset = notesStart
            }
            if let bibStart = bibliographyStartOffset {
                if boundary.startOffset < bibStart && endOffset > bibStart {
                    endOffset = bibStart
                }
            }

            // Extract markdown content for this section
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(boundary.startOffset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
            let sectionMarkdown = String(markdown[startIdx..<endIdx])

            let wordCount = MarkdownUtils.wordCount(for: sectionMarkdown)

            // For pseudo-sections, extract title from first paragraph after break
            let finalTitle: String
            if boundary.isPseudoSection {
                finalTitle = extractPseudoSectionTitle(from: sectionMarkdown)
            } else {
                finalTitle = boundary.title
            }

            headers.append(ParsedHeader(
                position: index,
                title: finalTitle,
                level: boundary.level,
                isPseudoSection: boundary.isPseudoSection,
                startOffset: boundary.startOffset,
                markdownContent: sectionMarkdown,
                wordCount: wordCount,
                isBibliography: boundary.isBibliography,
                isNotes: boundary.isNotes
            ))
        }

        return headers
    }

    /// Selects the character offset (matching `currentOffset` in the main loop above) of the
    /// ONE line that opens the bibliography section, or `nil` if none does. Mirrors SOME of the
    /// main loop's own code-fence and `inAutoNotes` gating (guards below) — including, as of
    /// this fix, a real closing condition for the `inAutoNotes` latch itself (item 3 below,
    /// MUST-FIX 1) — but the two functions are NOT fully unified, and this fix does not attempt
    /// to make them so. They differ in TWO ways that remain deliberately unreconciled:
    ///   (a) the main loop also skips every heading while it is inside the bibliography region
    ///       (`inAutoBibliography`) and closes that region at the terminator; neither mechanic
    ///       is modeled here at all.
    ///   (b) the main loop's OWN `inAutoNotes`-closing condition (its `existingNotesTitle !=
    ///       nil` branch) is evidence-gated — it defers the decision to a multi-line
    ///       footnote-pattern check against the section's actual content, closing only once
    ///       that check runs after the whole document is seen. This pre-scan has no multi-line
    ///       lookahead buffer (it only ever sees one line at a time), so item 3's fix below
    ///       approximates evidence-gating with a level comparison against the next heading
    ///       instead — a genuinely different closing mechanism, not a re-implementation of the
    ///       same one.
    /// Because (a) and (b) are different mechanisms answering the same question, they CAN
    /// disagree on an edge case even after this fix — concretely, a bibliography heading nested
    /// at a level below an unrelated `notesHeaderName`-titled heading (e.g. a level-2 "##
    /// Bibliography" sitting under a level-1 "# Notes" that the main loop's evidence check would
    /// reject for lack of real footnote content, but whose mere presence still closes nothing
    /// here until a same-or-shallower-level heading is reached) can make this pre-scan return an
    /// offset — or `.none` — that the main loop's own reachable set would not. This divergence is
    /// real, known, and DELIBERATELY left deferred, not fixed by this change: treat this
    /// function's result as an approximation of the main loop's reachable set, not a guarantee
    /// of it.
    /// Tokenizes each line into a `BibliographyOpeningSelector.Unit` and delegates the actual
    /// decision to `BibliographyOpeningSelector.select` — see that type's doc comment for the full two-tier
    /// rule and why tier 3 ("last title match anywhere, no evidence required") was deleted
    /// rather than weakened.
    ///
    /// This site's predicates, all required:
    /// 1. **Code fences** — mirrors the main loop's exact ``` toggling; gates `isTerminator`,
    ///    `isCandidate`, and `isHeading`.
    /// 2. **`isMarker`** — a line prefixed `<!-- ::auto-bibliography:: -->`, checked
    ///    unconditionally (not gated by code-fence/notes state) — exactly matching the main
    ///    loop's own unconditional marker check.
    /// 3. **`inAutoNotes` latch** — set true by a `notesHeaderName` title match, gated on
    ///    `existingNotesTitle != nil`, and CLOSED (MUST-FIX 1) at the next heading whose level
    ///    is <= the level of the heading that opened it — a level-scoped mirror of the main
    ///    `parseHeaders` loop's own evidence-gated fix to this same bug (see that function's
    ///    doc comment on its `existingNotesTitle != nil` branch), chosen here instead because
    ///    this function has no multi-line lookahead buffer to run a footnote-pattern evidence
    ///    check against -- it only ever sees one line at a time. Before this fix, the latch was
    ///    open-and-never-close: once a bare-title "Notes" match set it, every remaining line was
    ///    invisible to `isTerminator`/`isCandidate`/`isHeading` below, which could blind this
    ///    pre-scan to a REAL bibliography terminator/candidate sitting after it -- silently
    ///    losing the bibliography flag for a document structured Notes-then-Bibliography. Also
    ///    gates `isTerminator`/`isCandidate`/`isHeading`.
    /// 4. **`isTerminator`** — `BlockParser.bibliographyEndMarker`, matched by EXACT equality
    ///    on the trimmed line (never `.contains`).
    ///
    /// `isCandidate` — exactly the main loop's own bibliography-title condition, NOT
    /// `BlockParser.isBibliographyHeading`'s broader three-title set: a line is a candidate iff
    /// it parses as a header AND `header.title == bibHeaderName`, gated on
    /// `existingBibTitle != nil`. Using the broader set here would return an offset the main
    /// loop's exact-match condition could never equal, silently dropping the bibliography
    /// boundary from the outline entirely. Bibliography is checked BEFORE notes — matching the
    /// main loop's own ordering exactly — so a colliding header name configured for both can't
    /// latch `inAutoNotes` and wrongly exclude the real bibliography candidate.
    ///
    /// `isHeading` — any line `parseHeaderLine` recognizes as a header, at ANY level (1–6), not
    /// just the bibliography title — matching site A's (`BlockParser`) carry-forward-alignment
    /// intent: a heading that isn't the bibliography title still ends a run for run-emptiness
    /// purposes.
    private nonisolated static func selectBibliographyOpeningOffset(
        lines: [Substring],
        bibHeaderName: String,
        existingBibTitle: String?,
        notesHeaderName: String,
        existingNotesTitle: String?
    ) -> Int? {
        var currentOffset = 0
        var inCodeBlock = false
        var inAutoNotes = false
        // The level of the heading that opened `inAutoNotes` -- MUST-FIX 1's closing
        // condition needs it to decide whether a later heading is "at or above" that level.
        var notesHeadingLevel: Int?

        var offsets: [Int] = []
        var units: [BibliographyOpeningSelector.Unit] = []
        offsets.reserveCapacity(lines.count)
        units.reserveCapacity(lines.count)

        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
            }

            // Unconditional, exactly like the main loop's own marker check.
            let isMarker = trimmed.hasPrefix(BlockParser.bibliographyStartMarker)

            // MUST-FIX 1: close the inAutoNotes latch BEFORE gating on it below -- a heading
            // whose level is <= the level of the heading that opened the latch ends the
            // (unevidenced) notes region here. This has to inspect the line for a heading even
            // while `inAutoNotes` is still open, since the gated branch below never runs at all
            // while the latch is on.
            if inAutoNotes, !inCodeBlock,
               let closingHeader = parseHeaderLine(trimmed),
               closingHeader.level <= (notesHeadingLevel ?? Int.max) {
                inAutoNotes = false
                notesHeadingLevel = nil
            }

            var isTerminator = false
            var isCandidate = false
            var isHeading = false

            if !inCodeBlock && !inAutoNotes {
                if trimmed == BlockParser.bibliographyEndMarker {
                    isTerminator = true
                } else if let header = parseHeaderLine(trimmed) {
                    isHeading = true
                    // Bibliography checked BEFORE notes — see this function's doc comment.
                    if header.title == bibHeaderName && existingBibTitle != nil {
                        isCandidate = true
                    } else if header.title == notesHeaderName && existingNotesTitle != nil {
                        inAutoNotes = true
                        notesHeadingLevel = header.level
                    }
                }
            }

            offsets.append(currentOffset)
            units.append(BibliographyOpeningSelector.Unit(
                isMarker: isMarker,
                isTerminator: isTerminator,
                isCandidate: isCandidate,
                isHeading: isHeading,
                isEmpty: trimmed.isEmpty,
                isStandaloneMarker: trimmed == BlockParser.bibliographyStartMarker
            ))

            currentOffset += lineStr.count + 1 // +1 for newline, matching the main loop below
        }

        switch BibliographyOpeningSelector.select(units) {
        case .marker(let index), .candidate(let index):
            return offsets[index]
        case .none:
            return nil
        }
    }

    struct LocalParsedHeader {
        let level: Int
        let title: String
    }

    nonisolated static func parseHeaderLine(_ line: String) -> LocalParsedHeader? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        // Reject ghost image headers from WebKit native drop race condition
        if MarkdownUtils.isGhostImageMarkdown(title) { return nil }

        return LocalParsedHeader(level: level, title: title)
    }

    /// Extract a title for pseudo-sections from the first paragraph after the break marker
    /// Returns "§ " followed by the first few words (up to ~30 chars), or "§ Section Break" if no content
    nonisolated static func extractPseudoSectionTitle(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        // Skip the break marker line and any empty lines to find the first paragraph
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip the break marker itself
            if trimmed == "<!-- ::break:: -->" {
                continue
            }

            // Skip empty lines
            if trimmed.isEmpty {
                continue
            }

            // Skip other markdown constructs that shouldn't be titles
            if trimmed.hasPrefix("#") ||      // Headers
               trimmed.hasPrefix("```") ||    // Code blocks
               trimmed.hasPrefix(">") ||      // Block quotes
               trimmed.hasPrefix("-") ||      // Lists
               trimmed.hasPrefix("*") ||      // Lists
               trimmed.hasPrefix("1.") ||     // Numbered lists
               trimmed.hasPrefix("|") {       // Tables
                continue
            }

            // Found paragraph text - extract first ~30 characters at word boundary
            let excerpt = extractExcerpt(from: trimmed, maxLength: 30)
            if !excerpt.isEmpty {
                return "§ \(excerpt)"
            }
        }

        // Fallback if no paragraph content found
        return "§ Section Break"
    }

    /// Extract an excerpt from text, truncating at word boundary with ellipsis
    nonisolated static func extractExcerpt(from text: String, maxLength: Int) -> String {
        // Strip any markdown formatting (bold, italic, links)
        let plainText = text
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        if plainText.count <= maxLength {
            return plainText
        }

        // Find a word boundary near maxLength
        let prefix = String(plainText.prefix(maxLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }

        // No space found - just truncate
        return prefix + "…"
    }
}
