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
        }

        var boundaries: [SectionBoundary] = []
        var lastActualHeaderLevel: Int = 1  // Default to H1 for pseudo-sections at document start

        // Track where bibliography/notes sections start (to end preceding section there)
        var bibliographyStartOffset: Int?
        var notesStartOffset: Int?

        // For import auto-detection: track "Notes" heading found without existingNotesTitle
        // Will be confirmed as notes section if content contains [^N]: patterns
        var pendingNotesOffset: Int?
        var pendingNotesBoundaryIndex: Int?

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
                        isBibliography: false
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
                            isBibliography: true
                        ))
                    } else if header.title == notesHeaderName && existingNotesTitle != nil {
                        inAutoNotes = true
                        notesStartOffset = currentOffset
                        // Don't add to boundaries - notes section is managed separately
                    } else if header.title == "Notes" && existingNotesTitle == nil {
                        // Import auto-detection: tentatively add as regular section,
                        // but record its index so we can remove it if content has [^N]: patterns
                        lastActualHeaderLevel = header.level
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: false
                        ))
                        pendingNotesOffset = currentOffset
                        pendingNotesBoundaryIndex = boundaries.count - 1
                    } else {
                        lastActualHeaderLevel = header.level  // Track for subsequent pseudo-sections
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: false
                        ))
                    }
                }
            }

            currentOffset += lineStr.count + 1 // +1 for newline
        }

        // Import auto-detection: if we found a "Notes" heading without an existing DB entry,
        // check if its content contains [^N]: footnote definitions to avoid false positives
        if let pendingIndex = pendingNotesBoundaryIndex, let pendingOffset = pendingNotesOffset {
            // Extract the content of the pending notes section
            let nextBoundaryOffset = pendingIndex + 1 < boundaries.count
                ? boundaries[pendingIndex + 1].startOffset
                : markdown.count
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(pendingOffset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(nextBoundaryOffset, markdown.count))
            let pendingContent = String(markdown[startIdx..<endIdx])

            // Check for [^N]: definition patterns
            if pendingContent.range(of: #"\[\^\d+\]:"#, options: .regularExpression) != nil {
                // Confirmed as notes section — remove from boundaries and mark as managed
                boundaries.remove(at: pendingIndex)
                notesStartOffset = pendingOffset
                inAutoNotes = true
            }
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
            // This prevents managed section content from being absorbed into the preceding section
            if let notesStart = notesStartOffset {
                if boundary.startOffset < notesStart && endOffset > notesStart {
                    endOffset = notesStart
                }
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
                isBibliography: boundary.isBibliography
            ))
        }

        return headers
    }

    /// Selects the character offset (matching `currentOffset` in the main loop above) of the
    /// ONE line that opens the bibliography section, or `nil` if none does. Mirrors the main
    /// loop's own code-fence and `inAutoNotes` gating (guards below), but — unlike an earlier
    /// version of this comment claimed — that mirroring is no longer complete: the main loop
    /// also skips every heading while it is inside the bibliography region (`inAutoBibliography`)
    /// and closes that region at the terminator, and neither of those is modeled here. So the
    /// candidate/terminator set found by this pre-scan can diverge from what the main loop would
    /// actually reach. Concretely: a `notesHeaderName`-titled heading nested inside what the main
    /// loop treats as the bibliography region (and correctly skips over) still latches this
    /// function's `inAutoNotes` here, which can blind the pre-scan to the real terminator and
    /// return `.none` where the main loop's own view of the document never hit that confusion.
    /// This divergence is a known, deferred gap — not fixed here — so treat this function's
    /// result as an approximation of the main loop's reachable set, not a guarantee of it.
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
    /// 3. **`inAutoNotes` latch** — mirrors the main loop's existing open-and-never-close Notes
    ///    semantics exactly (set once true by a `notesHeaderName` title match, gated on
    ///    `existingNotesTitle != nil`, and never cleared), so Notes-then-Bibliography behavior
    ///    is unchanged. Also gates `isTerminator`/`isCandidate`/`isHeading`.
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
