//
//  LegacyHeaderParse.swift
//  final finalTests
//
//  TEST-ONLY REFERENCE (t-94369a83, Phase 4a close-time fix). A verbatim copy of `SectionSyncService.parseHeaders` and the three
//  helpers it calls, as they were BEFORE the quadratic index arithmetic was replaced (`git show HEAD:final final/Services/
//  SectionSyncService+Parsing.swift`, 2026-10-11): `String.count` and `markdown.index(markdown.startIndex, offsetBy:)` called once or
//  twice per section boundary, in `confirmNotesCandidates` and `buildParsedHeaders`. Only comments were removed, one `else` was moved
//  up to its closing brace's line (the linter's statement_position rule) and the calls into `SectionSyncService`'s own non-private
//  helpers (`parseHeaderLine`, `extractPseudoSectionTitle`) were qualified; no line of logic was changed. `CloseSyncTimingTests` compares its output with the production function field by field, on the book-length
//  documents and on small edge cases.
//
//  This file is an oracle, not production code: it must keep the OLD arithmetic exactly, so it is never "fixed" to follow the
//  production file.
//

import Foundation
@testable import final_final

enum LegacyHeaderParse {

    struct SectionBoundary {
        let startOffset: Int
        let level: Int
        let title: String
        let isPseudoSection: Bool
        let isBibliography: Bool
        let isNotes: Bool
    }

    struct PendingNotesCandidate {
        let offset: Int
        let boundaryIndex: Int
    }

    static func parseHeaders(
        from markdown: String,
        existingBibTitle: String? = nil,
        existingNotesTitle: String? = nil,
        fallbackBibTitle: String = "Bibliography"
    ) -> [ParsedHeader] {

        var currentOffset = 0
        var inCodeBlock = false
        var inAutoBibliography = false  // Track auto-bibliography section (managed by BibliographySyncService)
        var inAutoNotes = false  // Track auto-notes section (managed by FootnoteSyncService)

        var boundaries: [SectionBoundary] = []
        var lastActualHeaderLevel: Int = 1  // Default to H1 for pseudo-sections at document start

        var bibliographyStartOffset: Int?
        var confirmedNotesOffsets: [Int] = []

        var pendingNotesCandidates: [PendingNotesCandidate] = []

        let bibHeaderName = existingBibTitle ?? fallbackBibTitle
        let notesHeaderName = existingNotesTitle ?? "Notes"

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

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

            inCodeBlock = codeFenceState(after: trimmed, wasInCodeBlock: inCodeBlock)

            if trimmed.hasPrefix(BlockParser.bibliographyStartMarker) {
                if currentOffset == selectedBibliographyOffset {
                    inAutoBibliography = true
                    bibliographyStartOffset = currentOffset
                }
                currentOffset += lineStr.count + 1  // +1 for newline
                continue  // Skip - header on same line, don't parse as separate section
            }

            if inAutoBibliography && !inCodeBlock && !inAutoNotes && trimmed == BlockParser.bibliographyEndMarker {
                inAutoBibliography = false
                currentOffset += lineStr.count + 1  // +1 for newline
                continue
            }

            if !inCodeBlock && !inAutoBibliography && !inAutoNotes {
                if trimmed == "<!-- ::break:: -->" {
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: lastActualHeaderLevel,
                        title: "§ Section Break",
                        isPseudoSection: true,
                        isBibliography: false,
                        isNotes: false
                    ))
                } else if let header = SectionSyncService.parseHeaderLine(trimmed) {
                    if currentOffset == selectedBibliographyOffset {
                        inAutoBibliography = true
                        bibliographyStartOffset = currentOffset
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false,
                            isBibliography: true,
                            isNotes: false
                        ))
                    } else if header.title == notesHeaderName {
                        lastActualHeaderLevel = existingNotesTitle == nil ? header.level : lastActualHeaderLevel
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

        let anyNotesConfirmed = confirmNotesCandidates(
            pendingNotesCandidates,
            boundaries: &boundaries,
            confirmedNotesOffsets: &confirmedNotesOffsets,
            markdown: markdown
        )
        if anyNotesConfirmed {
            inAutoNotes = true
        }

        return buildParsedHeaders(
            markdown: markdown,
            boundaries: boundaries,
            confirmedNotesOffsets: confirmedNotesOffsets,
            bibliographyStartOffset: bibliographyStartOffset
        )
    }

    static func codeFenceState(after trimmed: String, wasInCodeBlock: Bool) -> Bool {
        trimmed.hasPrefix("```") ? !wasInCodeBlock : wasInCodeBlock
    }

    static func confirmNotesCandidates(
        _ pendingNotesCandidates: [PendingNotesCandidate],
        boundaries: inout [SectionBoundary],
        confirmedNotesOffsets: inout [Int],
        markdown: String
    ) -> Bool {
        var anyConfirmed = false

        for candidate in pendingNotesCandidates {
            let nextBoundaryOffset = candidate.boundaryIndex + 1 < boundaries.count
                ? boundaries[candidate.boundaryIndex + 1].startOffset
                : markdown.count
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(candidate.offset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(nextBoundaryOffset, markdown.count))
            let pendingContent = String(markdown[startIdx..<endIdx])

            let candidateUnits = pendingContent.components(separatedBy: "\n").map { line -> NotesOpeningSelector.Unit in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                return NotesOpeningSelector.Unit(
                    isCandidateHeading: false,
                    isAnyHeading: trimmedLine.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil,
                    isEvidence: FootnoteSyncService.parseNotesLabel(from: trimmedLine) != nil
                )
            }
            let hasFootnoteEvidence = NotesOpeningSelector.hasEvidence(in: candidateUnits, after: 1)

            guard hasFootnoteEvidence else { continue }

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
            anyConfirmed = true
        }

        return anyConfirmed
    }

    static func buildParsedHeaders(
        markdown: String,
        boundaries: [SectionBoundary],
        confirmedNotesOffsets: [Int],
        bibliographyStartOffset: Int?
    ) -> [ParsedHeader] {
        guard !boundaries.isEmpty else { return [] }

        var headers: [ParsedHeader] = []
        let contentLength = markdown.count

        for (index, boundary) in boundaries.enumerated() {
            var endOffset: Int
            if index < boundaries.count - 1 {
                endOffset = boundaries[index + 1].startOffset
            } else {
                endOffset = contentLength
            }

            for notesStart in confirmedNotesOffsets where boundary.startOffset < notesStart && endOffset > notesStart {
                endOffset = notesStart
            }
            if let bibStart = bibliographyStartOffset {
                if boundary.startOffset < bibStart && endOffset > bibStart {
                    endOffset = bibStart
                }
            }

            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(boundary.startOffset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
            let sectionMarkdown = String(markdown[startIdx..<endIdx])

            let wordCount = MarkdownUtils.wordCount(for: sectionMarkdown)

            let finalTitle: String
            if boundary.isPseudoSection {
                finalTitle = SectionSyncService.extractPseudoSectionTitle(from: sectionMarkdown)
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

    static func selectBibliographyOpeningOffset(
        lines: [Substring],
        bibHeaderName: String,
        existingBibTitle: String?,
        notesHeaderName: String,
        existingNotesTitle: String?
    ) -> Int? {
        var currentOffset = 0
        var inCodeBlock = false
        var inAutoNotes = false
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

            let isMarker = trimmed.hasPrefix(BlockParser.bibliographyStartMarker)

            if inAutoNotes, !inCodeBlock,
               let closingHeader = SectionSyncService.parseHeaderLine(trimmed),
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
                } else if let header = SectionSyncService.parseHeaderLine(trimmed) {
                    isHeading = true
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
}
