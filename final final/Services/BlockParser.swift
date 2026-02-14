//
//  BlockParser.swift
//  final final
//
//  Parses markdown content into Block structures.
//  Splits by double newlines and detects block types from content.
//

import Foundation

/// Parser that converts markdown into Block structures
enum BlockParser {

    /// Parse markdown content into an array of blocks
    /// - Parameters:
    ///   - markdown: The markdown content to parse
    ///   - projectId: The project ID to assign to blocks
    ///   - existingSectionMetadata: Optional metadata from existing sections to preserve
    /// - Returns: Array of Block structures
    static func parse(
        markdown: String,
        projectId: String,
        existingSectionMetadata: [String: SectionMetadata]? = nil
    ) -> [Block] {
        guard !markdown.isEmpty else { return [] }

        var blocks: [Block] = []
        var sortOrder: Double = 1.0

        // Split by double newlines (paragraph boundaries)
        // But keep code blocks and other multi-line structures together
        let rawBlocks = splitIntoRawBlocks(markdown)

        var inBibliographySection = false

        for rawBlock in rawBlocks {
            let trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let (blockType, headingLevel) = detectBlockType(trimmed)
            let textContent = extractTextContent(from: trimmed, blockType: blockType)
            let wordCount = MarkdownUtils.wordCount(for: textContent)

            // Check for special flags
            let isBibliographyHeading = trimmed.contains("<!-- ::auto-bibliography:: -->") ||
                                         trimmed == "# References" ||
                                         trimmed == "## References" ||
                                         trimmed == "# Bibliography" ||
                                         trimmed == "## Bibliography"
            if isBibliographyHeading {
                inBibliographySection = true
            } else if inBibliographySection && blockType == .heading {
                // Reset if a non-bibliography heading follows (user typed below bibliography in CM)
                inBibliographySection = false
            }
            let isBibliography = inBibliographySection
            let isPseudoSection = trimmed.contains("<!-- ::break:: -->")

            // Look up existing metadata for this heading if available
            var status: SectionStatus?
            var tags: [String]?
            var wordGoal: Int?

            if blockType == .heading, let metadata = existingSectionMetadata {
                // Try to match by title
                if let match = metadata[textContent] {
                    status = match.status
                    tags = match.tags
                    wordGoal = match.wordGoal
                }
            }

            // Section breaks inherit status from section metadata
            if isPseudoSection, let metadata = existingSectionMetadata {
                // For pseudo-sections, we might use a special key
                if let match = metadata["__break__\(Int(sortOrder))"] {
                    status = match.status
                    tags = match.tags
                    wordGoal = match.wordGoal
                }
            }

            let block = Block(
                projectId: projectId,
                sortOrder: sortOrder,
                blockType: blockType,
                textContent: textContent,
                markdownFragment: trimmed,
                headingLevel: headingLevel,
                status: status,
                tags: tags,
                wordGoal: wordGoal,
                wordCount: wordCount,
                isBibliography: isBibliography,
                isPseudoSection: isPseudoSection
            )

            blocks.append(block)
            sortOrder += 1.0
        }

        return blocks
    }

    /// Split markdown into raw block strings, respecting code blocks
    private static func splitIntoRawBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var currentBlock = ""
        var inCodeBlock = false
        var inTable = false

        let lines = markdown.components(separatedBy: "\n")

        for line in lines {
            // Check for code fence
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                currentBlock += line + "\n"
                continue
            }

            // Check for table (starts with |)
            let isTableLine = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            if isTableLine && !inTable {
                // Starting a table, flush current block
                if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(currentBlock)
                }
                currentBlock = ""
                inTable = true
            } else if !isTableLine && inTable && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Ending a table
                blocks.append(currentBlock)
                currentBlock = ""
                inTable = false
            }

            if inCodeBlock || inTable {
                currentBlock += line + "\n"
                continue
            }

            // Empty line marks paragraph boundary
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = ""
                }
            } else {
                currentBlock += line + "\n"
            }
        }

        // Don't forget the last block
        if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(currentBlock)
        }

        return blocks
    }

    /// Detect the block type from content
    private static func detectBlockType(_ content: String) -> (BlockType, Int?) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heading: starts with # (1-6)
        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
            let hashes = trimmed[match].filter { $0 == "#" }
            let level = hashes.count
            return (.heading, level)
        }

        // Code block: starts with ```
        if trimmed.hasPrefix("```") {
            return (.codeBlock, nil)
        }

        // Horizontal rule: ---, ***, ___
        if trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil {
            return (.horizontalRule, nil)
        }

        // Section break: <!-- ::break:: -->
        if trimmed.contains("<!-- ::break:: -->") {
            return (.sectionBreak, nil)
        }

        // Blockquote: starts with >
        if trimmed.hasPrefix(">") {
            return (.blockquote, nil)
        }

        // Bullet list: starts with - * +
        if trimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) != nil {
            return (.bulletList, nil)
        }

        // Ordered list: starts with 1. 2. etc
        if trimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) != nil {
            return (.orderedList, nil)
        }

        // Table: starts with |
        if trimmed.hasPrefix("|") {
            return (.table, nil)
        }

        // Image: ![alt](url)
        if trimmed.range(of: "^!\\[", options: .regularExpression) != nil {
            return (.image, nil)
        }

        // Bibliography marker
        if trimmed.contains("<!-- ::auto-bibliography:: -->") {
            return (.bibliography, nil)
        }

        // Default: paragraph
        return (.paragraph, nil)
    }

    /// Extract plain text content from markdown block
    static func extractTextContent(from content: String, blockType: BlockType) -> String {
        var text = content

        switch blockType {
        case .heading:
            // Remove # markers
            if let range = text.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                text.removeSubrange(range)
            }

        case .blockquote:
            // Remove > markers
            text = text.components(separatedBy: "\n")
                .map { line in
                    var l = line
                    while l.hasPrefix(">") {
                        l.removeFirst()
                        l = l.trimmingCharacters(in: .init(charactersIn: " "))
                    }
                    return l
                }
                .joined(separator: "\n")

        case .bulletList, .orderedList:
            // Remove list markers
            text = text.components(separatedBy: "\n")
                .map { line in
                    var l = line.trimmingCharacters(in: .whitespaces)
                    if let range = l.range(of: "^[-*+]\\s+|^\\d+\\.\\s+", options: .regularExpression) {
                        l.removeSubrange(range)
                    }
                    return l
                }
                .joined(separator: "\n")

        case .codeBlock:
            // Remove code fence markers, keep code content
            let lines = text.components(separatedBy: "\n")
            var inFence = false
            var codeLines: [String] = []
            for line in lines {
                if line.hasPrefix("```") {
                    inFence.toggle()
                    continue
                }
                if inFence {
                    codeLines.append(line)
                }
            }
            text = codeLines.joined(separator: "\n")

        case .sectionBreak, .horizontalRule:
            text = ""

        default:
            break
        }

        // Strip remaining markdown syntax
        text = MarkdownUtils.stripMarkdownSyntax(from: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Assemble blocks back into markdown
    /// Uses tuple comparison for tie-breaking: headings sort before non-headings at same sortOrder
    static func assembleMarkdown(from blocks: [Block]) -> String {
        let sorted = blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        return sorted
            .map { $0.markdownFragment }
            .joined(separator: "\n\n")
    }
}

// MARK: - Section Metadata for Migration

/// Metadata from existing sections to preserve during migration
struct SectionMetadata {
    let status: SectionStatus?
    let tags: [String]?
    let wordGoal: Int?

    init(status: SectionStatus? = nil, tags: [String]? = nil, wordGoal: Int? = nil) {
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
    }

    init(from section: Section) {
        self.status = section.status
        self.tags = section.tags.isEmpty ? nil : section.tags
        self.wordGoal = section.wordGoal
    }
}
