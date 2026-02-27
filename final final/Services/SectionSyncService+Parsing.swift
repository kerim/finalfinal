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
    // swiftlint:disable:next function_parameter_count
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
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            // Legacy marker support: still detect marker if present in old content
            // This ensures backward compatibility during transition
            if trimmed.hasPrefix("<!-- ::auto-bibliography:: -->") {
                inAutoBibliography = true
                bibliographyStartOffset = currentOffset
                currentOffset += lineStr.count + 1  // +1 for newline
                continue  // Skip - header on same line, don't parse as separate section
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
                        isPseudoSection: true
                    ))
                    // Do NOT update lastActualHeaderLevel - pseudo-sections don't affect it
                }
                // Check for header
                else if let header = parseHeaderLine(trimmed) {
                    // Detect bibliography by title match (when no marker is present)
                    // This allows detection even after marker is removed from stored content
                    if header.title == bibHeaderName && existingBibTitle != nil {
                        inAutoBibliography = true
                        bibliographyStartOffset = currentOffset
                        // Don't add to boundaries - bibliography is managed separately
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
                            isPseudoSection: false
                        ))
                        pendingNotesOffset = currentOffset
                        pendingNotesBoundaryIndex = boundaries.count - 1
                    } else {
                        lastActualHeaderLevel = header.level  // Track for subsequent pseudo-sections
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false
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
                wordCount: wordCount
            ))
        }

        return headers
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
