//
//  OutlineParser.swift
//  final final
//

import Foundation

struct OutlineParser {

    // MARK: - Public API

    /// Parses markdown content into an array of OutlineNodes
    static func parse(markdown: String, projectId: String) -> [OutlineNode] {
        let headers = extractHeaders(from: markdown)
        guard !headers.isEmpty else { return [] }

        var headersWithEnds = calculateEndOffsets(headers, contentLength: markdown.count)
        assignParents(&headersWithEnds)

        return headersWithEnds.enumerated().map { index, header in
            OutlineNode(
                id: header.id,
                projectId: projectId,
                headerLevel: header.level,
                title: header.title,
                startOffset: header.startOffset,
                endOffset: header.endOffset,
                parentId: header.parentId,
                sortOrder: index,
                isPseudoSection: header.isPseudoSection
            )
        }
    }

    /// Extracts preview text from a section (first non-header lines)
    static func extractPreview(from markdown: String, startOffset: Int, endOffset: Int, maxLines: Int = 4) -> String {
        guard startOffset < endOffset, startOffset < markdown.count else { return "" }

        let start = markdown.index(markdown.startIndex, offsetBy: startOffset)
        let end = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
        let section = String(markdown[start..<end])

        var lines: [String] = []
        var foundContent = false

        for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip header line at start
            if !foundContent && trimmed.hasPrefix("#") {
                continue
            }

            // Skip empty lines before content
            if !foundContent && trimmed.isEmpty {
                continue
            }

            foundContent = true

            // Skip empty lines between content (but not within)
            if trimmed.isEmpty && lines.count < maxLines {
                continue
            }

            if lines.count < maxLines {
                lines.append(String(line))
            } else {
                break
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts words in text
    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: - Private Types

    private struct ParsedHeader {
        let level: Int
        let title: String
        let startOffset: Int
        var endOffset: Int
        let isPseudoSection: Bool
        var parentId: String?
        let id: String

        init(level: Int, title: String, startOffset: Int, isPseudoSection: Bool) {
            self.level = level
            self.title = title
            self.startOffset = startOffset
            self.endOffset = startOffset // Will be calculated later
            self.isPseudoSection = isPseudoSection
            self.parentId = nil
            self.id = UUID().uuidString
        }
    }

    // MARK: - Private Methods

    private static func extractHeaders(from markdown: String) -> [ParsedHeader] {
        var headers: [ParsedHeader] = []
        var currentOffset = 0
        var inCodeBlock = false
        var inAutoBibliography = false  // Track auto-generated bibliography section

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks to avoid parsing # in code
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            // Track auto-bibliography section (managed by BibliographySyncService)
            if trimmed == "<!-- ::auto-bibliography:: -->" {
                inAutoBibliography = true
            }
            if trimmed == "<!-- ::end-auto-bibliography:: -->" {
                inAutoBibliography = false
            }

            // Parse header if not in code block AND not in auto-bibliography
            if !inCodeBlock && !inAutoBibliography,
               let header = parseHeaderLine(trimmed, at: currentOffset) {
                headers.append(header)
            }

            // Advance offset (+1 for newline, use character count for String indexing compatibility)
            currentOffset += lineStr.count + 1
        }

        return headers
    }

    private static func parseHeaderLine(_ line: String, at offset: Int) -> ParsedHeader? {
        // Match # through ###### followed by space and text
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        // Must have at least one # and be followed by space
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        // Extract title (everything after "# ")
        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        return ParsedHeader(
            level: level,
            title: title,
            startOffset: offset,
            isPseudoSection: isPseudoSection(title: title)
        )
    }

    private static func calculateEndOffsets(_ headers: [ParsedHeader], contentLength: Int) -> [ParsedHeader] {
        var result = headers

        for i in 0..<result.count {
            if i == result.count - 1 {
                // Last header ends at content end
                result[i].endOffset = contentLength
            } else {
                // Each header ends where the next one starts
                result[i].endOffset = result[i + 1].startOffset
            }
        }

        return result
    }

    private static func assignParents(_ headers: inout [ParsedHeader]) {
        // Stack of (level, id) pairs - start with virtual root
        var parentStack: [(level: Int, id: String?)] = [(0, nil)]

        for i in 0..<headers.count {
            let currentLevel = headers[i].level

            // Pop stack until we find a parent with lower level
            while parentStack.count > 1 && parentStack.last!.level >= currentLevel {
                parentStack.removeLast()
            }

            // Assign parent
            headers[i].parentId = parentStack.last?.id

            // Push current header onto stack
            parentStack.append((currentLevel, headers[i].id))
        }
    }

    private static func isPseudoSection(title: String) -> Bool {
        let lower = title.lowercased()
        let patterns = [
            "-part ",
            "- part ",
            "-continued",
            "- continued",
            "-part\t",
            "- part\t"
        ]
        return patterns.contains { lower.contains($0) }
    }
}
