//
//  BlockParser.swift
//  final final
//
//  Parses markdown content into Block structures.
//  Splits by double newlines and detects block types from content.
//
//  Companion files:
//    - BlockParser+Splitting.swift — markdown → raw block strings
//    - BlockParser+Images.swift    — image src/alt/caption/width extraction
//    - BlockParser+Assembly.swift  — blocks → markdown, ProseMirror alignment
//

import Foundation

/// Parser that converts markdown into Block structures
enum BlockParser {

    /// Whether a markdown fragment is effectively empty (no visible content).
    /// Used to filter blocks that produce no ProseMirror node (e.g., section_break with empty fragment).
    static func isEmptyFragment(_ fragment: String) -> Bool {
        fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
        var inNotesSection = false

        for rawBlock in rawBlocks {
            let trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let (blockType, headingLevel) = detectBlockType(trimmed)
            let textContent = extractTextContent(from: trimmed, blockType: blockType)
            // wordCount populated below via Block.recalculateWordCount() so the
            // block-type rules (zero for code/image/HR/section break/bibliography)
            // apply uniformly. Initial value 0 is overwritten before append.

            // Both flags run until the next heading that doesn't re-open them.
            inBibliographySection = sectionFlagCarriedForward(
                current: inBibliographySection,
                opensSection: isBibliographyHeading(trimmed),
                blockType: blockType
            )
            inNotesSection = sectionFlagCarriedForward(
                current: inNotesSection,
                opensSection: trimmed.lowercased() == "# notes",
                blockType: blockType
            )
            let isPseudoSection = trimmed.contains("<!-- ::break:: -->")

            // Look up existing metadata for this heading/section break if available
            let preserved = preservedMetadata(
                in: existingSectionMetadata,
                blockType: blockType,
                textContent: textContent,
                isPseudoSection: isPseudoSection,
                sortOrder: sortOrder
            )

            // Parse image metadata from markdown for image blocks
            let image = imageMetadata(for: trimmed, blockType: blockType)

            var block = Block(
                projectId: projectId,
                sortOrder: sortOrder,
                blockType: blockType,
                textContent: textContent,
                markdownFragment: trimmed,
                headingLevel: headingLevel,
                status: preserved?.status,
                tags: preserved?.tags,
                wordGoal: preserved?.wordGoal,
                imageSrc: image.src,
                imageAlt: image.alt,
                imageCaption: image.caption,
                imageWidth: image.width,
                isBibliography: inBibliographySection,
                isNotes: inNotesSection,
                isPseudoSection: isPseudoSection
            )
            block.recalculateWordCount()

            blocks.append(block)
            sortOrder += 1.0
        }

        return blocks
    }

    // MARK: - Section Flags

    /// A "we are inside section X" flag advanced by one block: an opening heading turns it
    /// on, any *other* heading turns it off, and everything else leaves it as it was.
    private static func sectionFlagCarriedForward(
        current: Bool,
        opensSection: Bool,
        blockType: BlockType
    ) -> Bool {
        if opensSection { return true }
        // Reset if a non-matching heading follows (user typed below the section in CM)
        if current && blockType == .heading { return false }
        return current
    }

    /// Whether `trimmed` is the heading that opens the bibliography section.
    ///
    /// The configured header name (normally read via the @MainActor
    /// ExportSettingsManager.shared.bibliographyHeaderName, e.g. a user-set "Works
    /// Cited") must be recognized alongside the built-in References/Bibliography
    /// literals: in Source Mode the <!-- ::auto-bibliography:: --> marker is already
    /// stripped out of editorState.content before this parse ever sees it (see
    /// ContentView+ContentRebuilding.swift), so a custom header name falling through to
    /// "ordinary heading" here would silently drop isBibliography from every entry
    /// paragraph below it -- the heading itself gets re-flagged by title match in
    /// Database+BlocksReorder.swift's replaceBlocks, but the entries don't, leaving stale
    /// entries stranded as duplicate body text on the very next bibliography write.
    /// BlockParser.parse() is a nonisolated static func called from both @MainActor
    /// production call sites AND non-@MainActor test contexts (e.g.
    /// TestFixtureFactory.createFixture, called from Tier1 tests with no @MainActor
    /// annotation) -- MainActor.assumeIsolated crashed there. ExportSettings.load() is
    /// the plain, non-actor-isolated struct method the manager itself is built on (its
    /// `update()` calls `settings.save()` synchronously, so UserDefaults is always in
    /// sync with the manager's cached value): reading straight from UserDefaults here is
    /// thread-safe and avoids threading an @MainActor read through every call site.
    private static func isBibliographyHeading(_ trimmed: String) -> Bool {
        if trimmed.contains("<!-- ::auto-bibliography:: -->") { return true }
        let titles = ["References", "Bibliography", ExportSettings.load().bibliographyHeaderName]
        return titles.contains { trimmed == "# \($0)" || trimmed == "## \($0)" }
    }

    /// Section metadata to carry over from an existing section, matched by heading title
    /// or — for section breaks, which have no title — by sort position.
    private static func preservedMetadata(
        in existing: [String: SectionMetadata]?,
        blockType: BlockType,
        textContent: String,
        isPseudoSection: Bool,
        sortOrder: Double
    ) -> SectionMetadata? {
        guard let existing else { return nil }

        var match: SectionMetadata?
        // Try to match by title
        if blockType == .heading {
            match = existing[textContent] ?? match
        }
        // Section breaks inherit status from section metadata under a special key
        if isPseudoSection {
            match = existing["__break__\(Int(sortOrder))"] ?? match
        }
        return match
    }

    // MARK: - Block Type Detection

    /// Detect the block type from content
    static func detectBlockType(_ content: String) -> (BlockType, Int?) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heading: starts with # (1-6) — the only type carrying a level
        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
            let hashes = trimmed[match].filter { $0 == "#" }
            return (.heading, hashes.count)
        }

        return (fencedOrQuotedType(trimmed) ?? listTableOrMediaType(trimmed), nil)
    }

    /// Fence-, rule- and quote-style types, or nil if `trimmed` is none of them.
    /// ORDER IS LOAD-BEARING: `$$` and ``` must be tested before the `---` horizontal-rule
    /// pattern, and the section-break comment before the `>` blockquote prefix.
    private static func fencedOrQuotedType(_ trimmed: String) -> BlockType? {
        // Display math block: starts with $$ (either $$...$$ on one line or multi-line)
        if trimmed.hasPrefix("$$") { return .mathDisplay }
        // Code block: starts with ```
        if trimmed.hasPrefix("```") { return .codeBlock }
        // Horizontal rule: ---, ***, ___
        if trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil { return .horizontalRule }
        // Section break: <!-- ::break:: -->
        if trimmed.contains("<!-- ::break:: -->") { return .sectionBreak }
        // Blockquote: starts with >
        if trimmed.hasPrefix(">") { return .blockquote }
        return nil
    }

    /// List, table, image and bibliography types, falling back to `.paragraph`.
    /// Only reached when `fencedOrQuotedType` found no match.
    private static func listTableOrMediaType(_ trimmed: String) -> BlockType {
        // Bullet list: starts with - * +
        if trimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) != nil { return .bulletList }
        // Ordered list: starts with 1. 2. etc
        if trimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) != nil { return .orderedList }
        // Table: starts with |
        if trimmed.hasPrefix("|") { return .table }
        // Caption + Image: <!-- caption: text -->\n...\n![alt](url)
        if trimmed.hasPrefix("<!--"), trimmed.contains("caption:"),
           trimmed.range(of: "!\\[", options: .regularExpression) != nil { return .image }
        // Image: ![alt](url)
        if trimmed.range(of: "^!\\[", options: .regularExpression) != nil { return .image }
        // Bibliography marker
        if trimmed.contains("<!-- ::auto-bibliography:: -->") { return .bibliography }
        // Default: paragraph
        return .paragraph
    }

    /// Whether `trimmedLine` looks like the start of a bullet ("-"/"*"/"+ ") or
    /// ordered ("1. ") list item, and which kind. Returns nil for anything else.
    /// Single-line check — used to detect a list "interrupting" non-list
    /// content with no blank line in between (see the call site in
    /// `RawBlockSplitter.consumeContentLine` for why this matters).
    static func listMarkerKind(_ trimmedLine: String) -> BlockType? {
        if trimmedLine.range(of: "^[-*+]\\s+", options: .regularExpression) != nil {
            return .bulletList
        }
        if trimmedLine.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
            return .orderedList
        }
        return nil
    }

    // MARK: - Text Extraction

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
            text = strippingBlockquoteMarkers(text)

        case .bulletList, .orderedList:
            text = strippingListMarkers(text)

        case .codeBlock:
            text = codeInsideFences(text)

        case .sectionBreak, .horizontalRule:
            text = ""

        default:
            break
        }

        text = strippingFootnoteDefinitionPrefixes(text)

        // Strip remaining markdown syntax
        text = MarkdownUtils.stripMarkdownSyntax(from: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes every leading `>` marker (and the space after it) from each line.
    private static func strippingBlockquoteMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var l = line
                while l.hasPrefix(">") {
                    l.removeFirst()
                    l = l.trimmingCharacters(in: .init(charactersIn: " "))
                }
                return l
            }
            .joined(separator: "\n")
    }

    /// Removes the leading bullet or ordinal marker from each line.
    private static func strippingListMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var l = line.trimmingCharacters(in: .whitespaces)
                if let range = l.range(of: "^[-*+]\\s+|^\\d+\\.\\s+", options: .regularExpression) {
                    l.removeSubrange(range)
                }
                return l
            }
            .joined(separator: "\n")
    }

    /// Keeps only the lines between ``` fences, dropping the fence markers themselves.
    private static func codeInsideFences(_ text: String) -> String {
        var inFence = false
        var codeLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                codeLines.append(line)
            }
        }
        return codeLines.joined(separator: "\n")
    }

    /// Strips footnote definition prefixes: `[^N]:` at line start.
    private static func strippingFootnoteDefinitionPrefixes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\[\^\d+\]:\s*"#, options: .anchorsMatchLines
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
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
