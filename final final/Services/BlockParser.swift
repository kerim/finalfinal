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

            // Notes section: mark ALL blocks under # Notes with isNotes=true
            let isNotesHeading = trimmed.lowercased() == "# notes"
            if isNotesHeading {
                inNotesSection = true
            } else if inNotesSection && blockType == .heading {
                inNotesSection = false
            }
            let isNotes = inNotesSection
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

            // Parse image metadata from markdown for image blocks
            var imageSrc: String?
            var imageAlt: String?
            var imageCaption: String?
            var imageWidth: Int?
            if blockType == .image {
                let meta = Self.parseImageFragmentMeta(from: trimmed)
                imageSrc = meta.src
                imageAlt = meta.alt
                imageCaption = meta.caption
                // Parse {width=N%} from Pandoc attributes
                imageWidth = Self.parseImageWidthPercent(from: trimmed)
                if imageWidth != nil {
                    DebugLog.log(.image, "[BlockParser] Parsed width=\(imageWidth ?? -1) from fragment: \(trimmed.prefix(60))")
                }
            }

            var block = Block(
                projectId: projectId,
                sortOrder: sortOrder,
                blockType: blockType,
                textContent: textContent,
                markdownFragment: trimmed,
                headingLevel: headingLevel,
                status: status,
                tags: tags,
                wordGoal: wordGoal,
                imageSrc: imageSrc,
                imageAlt: imageAlt,
                imageCaption: imageCaption,
                imageWidth: imageWidth,
                isBibliography: isBibliography,
                isNotes: isNotes,
                isPseudoSection: isPseudoSection
            )
            block.recalculateWordCount()

            blocks.append(block)
            sortOrder += 1.0
        }

        return blocks
    }

    /// Split markdown into raw block strings, respecting code blocks
    /// Regex pattern for footnote definition start: [^N]:
    private static let footnoteDefStartPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\[\^(\d+)\]:"#)
        } catch {
            fatalError("Invalid footnote def start regex pattern: \(error)")
        }
    }()

    /// Whether `trimmedLine` looks like the start of a bullet ("-"/"*"/"+ ") or
    /// ordered ("1. ") list item, and which kind. Returns nil for anything else.
    /// Single-line check — used to detect a list "interrupting" non-list
    /// content with no blank line in between (see the call site in
    /// `splitIntoRawBlocks` for why this matters).
    private static func listMarkerKind(_ trimmedLine: String) -> BlockType? {
        if trimmedLine.range(of: "^[-*+]\\s+", options: .regularExpression) != nil {
            return .bulletList
        }
        if trimmedLine.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
            return .orderedList
        }
        return nil
    }

    private static func splitIntoRawBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var currentBlock = ""
        var inCodeBlock = false
        var inTable = false
        var inFootnoteDef = false  // Track multi-paragraph footnote definitions
        var inDisplayMath = false  // Track multi-line $$...$$ display math

        let lines = markdown.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Check for display math fence: bare "$$" opens/closes; "$$...$$" is a one-line block
            let isSingleLineMath = trimmedLine.hasPrefix("$$") && trimmedLine.hasSuffix("$$") && trimmedLine.count > 4
            if (trimmedLine == "$$" || isSingleLineMath) && !inCodeBlock {
                if !inDisplayMath {
                    // Starting display math: flush current block
                    if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(currentBlock)
                        currentBlock = ""
                    }
                    inDisplayMath = true
                    inFootnoteDef = false
                    currentBlock += line + "\n"
                    // Opened and closed on one line ($$...$$): finish the block immediately
                    if isSingleLineMath {
                        blocks.append(currentBlock)
                        currentBlock = ""
                        inDisplayMath = false
                    }
                    continue
                } else if trimmedLine == "$$" {
                    // Closing $$
                    currentBlock += line + "\n"
                    blocks.append(currentBlock)
                    currentBlock = ""
                    inDisplayMath = false
                    continue
                }
            }

            // Inside display math: accumulate lines
            if inDisplayMath {
                currentBlock += line + "\n"
                continue
            }

            // Check for code fence
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                inFootnoteDef = false
                currentBlock += line + "\n"
                continue
            }

            // Check for table (starts with |)
            let isTableLine = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            if isTableLine && !inTable && !inCodeBlock {
                // Starting a table, flush current block
                if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(currentBlock)
                }
                currentBlock = ""
                inTable = true
                inFootnoteDef = false
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

            // Empty line handling — check for footnote definition continuations
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inFootnoteDef {
                    // In a footnote def: peek at next line to see if it's a 4-space continuation
                    let nextIndex = index + 1
                    if nextIndex < lines.count && lines[nextIndex].hasPrefix("    ") {
                        // Keep the empty line as part of the footnote definition block
                        currentBlock += line + "\n"
                        continue
                    } else {
                        // End of footnote definition
                        inFootnoteDef = false
                    }
                }

                // Check if current block is a caption comment — keep with following image
                let trimmedBlock = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedBlock.range(of: "^<!--\\s*caption:", options: .regularExpression) != nil
                   && trimmedBlock.hasSuffix("-->") {
                    // Peek ahead for image line
                    var nextIdx = index + 1
                    while nextIdx < lines.count
                          && lines[nextIdx].trimmingCharacters(in: .whitespaces).isEmpty {
                        nextIdx += 1
                    }
                    if nextIdx < lines.count
                       && lines[nextIdx].trimmingCharacters(in: .whitespaces).hasPrefix("![") {
                        // Absorb blank line — keep caption and image in same block
                        currentBlock += line + "\n"
                        continue
                    }
                }

                if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = ""
                }
            } else {
                // Check if this line starts a footnote definition
                let lineRange = NSRange(line.startIndex..., in: line)
                if footnoteDefStartPattern.firstMatch(in: line, range: lineRange) != nil {
                    // Flush previous block before starting footnote def
                    if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(currentBlock)
                        currentBlock = ""
                    }
                    inFootnoteDef = true
                } else if let newLineListKind = listMarkerKind(trimmedLine),
                          !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          detectBlockType(currentBlock).0 != newLineListKind {
                    // A list-item-looking line arriving with NO preceding blank
                    // line, while currentBlock is non-list content (or a
                    // DIFFERENT list type). This splitter's default assumption
                    // — "a blank line is the only block boundary" — doesn't hold
                    // here: per CommonMark itself, a list CAN interrupt a
                    // paragraph (or any other block) with no blank line needed.
                    //
                    // Confirmed real-world corruption this guards against: a
                    // pasted image splitting one bullet_list into two siblings
                    // around a new figure (a deliberate, tested placement — see
                    // insert-pos.test.ts) produces, from a still-unconfirmed
                    // upstream cause, markdown where the figure's line and the
                    // second list's first line are adjacent with NO blank line
                    // between them. Without this guard, the figure line and the
                    // entire second list get glued into ONE row, typed `.image`
                    // (since that's the first line) — the second list's own rows
                    // (and, for the caller reading this row's markdownFragment
                    // going forward, its distinct identity) are silently lost.
                    // See BlockListSplitPasteExportTests.swift for the
                    // regression test built from the exact real persisted DB
                    // state this was found in.
                    //
                    // detectBlockType(currentBlock) — not just its last line —
                    // correctly classifies a normal multi-item list (all list
                    // marker lines) OR a list whose last line is an indented,
                    // nested atom continuation (block-sync-plugin.ts's
                    // indentContinuationLines, e.g. "- Item 2\n  ![](...)") as
                    // .bulletList/.orderedList from its FIRST line — so a
                    // genuine continuation of the SAME list never gets split.
                    //
                    // DIAGNOSTIC: this guard firing at all means the upstream
                    // text was missing a blank line where CommonMark/Milkdown's
                    // own serializer normally puts one. The exact upstream
                    // trigger is still unconfirmed (see the investigation notes
                    // above) — this log lets a real retest confirm whether this
                    // is the mechanism still in play, and captures enough of
                    // both sides of the boundary to identify the trigger if it
                    // recurs. `.data` is enabled by default in this build.
                    DebugLog.log(.data, "[BlockParser] list-interruption guard fired: " +
                        "currentBlock tail=\"\(currentBlock.suffix(80))\" newLine=\"\(line.prefix(80))\"")
                    blocks.append(currentBlock)
                    currentBlock = ""
                }
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

        // Display math block: starts with $$ (either $$...$$ on one line or multi-line)
        if trimmed.hasPrefix("$$") {
            return (.mathDisplay, nil)
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

        // Caption + Image: <!-- caption: text -->\n...\n![alt](url)
        if trimmed.hasPrefix("<!--") && trimmed.contains("caption:") {
            if trimmed.range(of: "!\\[", options: .regularExpression) != nil {
                return (.image, nil)
            }
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

        // Strip footnote definition prefixes: [^N]: at line start
        if let regex = try? NSRegularExpression(pattern: #"^\[\^\d+\]:\s*"#, options: .anchorsMatchLines) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
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
        // MUST filter empty fragments — they produce no ProseMirror node
        let result = sorted
            .map { $0.markdownFragment }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")

        DebugLog.log(.sync, "[ASSEMBLE] \(blocks.count) blocks -> result length=\(result.count)")

        return result
    }

    /// Assemble blocks into Pandoc-compatible markdown for export.
    /// Uses `markdownForExport()` which includes fig-alt and width attributes for image blocks.
    static func assembleMarkdownForExport(from blocks: [Block]) -> String {
        let sorted = blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        let result = sorted
            .map { $0.markdownForExport() }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")

        return result
    }

    /// Assemble blocks into standard markdown for export (no Pandoc attributes).
    /// Uses `markdownForStandardExport()` which outputs plain markdown with captions as italic text.
    /// Returns the node index (in ProseMirror alignment order) of the first bibliography block,
    /// or nil if no bibliography blocks exist.
    /// MUST stay in sync with idsForProseMirrorAlignment list-merging logic.
    static func firstBibliographyNodeIndex(_ blocks: [Block]) -> Int? {
        var nodeIndex = 0
        var prevListType: BlockType? = nil

        for block in blocks {
            if isEmptyFragment(block.markdownFragment) { continue }

            let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)

            if isListBlock && block.blockType == prevListType {
                // Merged into previous list node — same index
                if block.isBibliography { return nodeIndex - 1 }
                continue
            }

            if block.isBibliography { return nodeIndex }
            nodeIndex += 1
            prevListType = isListBlock ? block.blockType : nil
        }
        return nil
    }

    /// Per-id ground-truth metadata handed to the JS side's optional `setBlockIdsForTopLevel`
    /// alignment check (see block-id-plugin.ts `ExpectedBlockMeta`). Kept as a separate
    /// Codable type (rather than reusing `Block`) so the JSON payload sent to JS is minimal
    /// and doesn't leak unrelated Block fields.
    struct BlockAlignmentMeta: Codable, Sendable {
        /// blockType: Swift BlockType.rawValue. nonEmpty: blankness ⟺ text.trim() == "" —
        /// SAME symmetric definition as the TS side (block-id-plugin.ts). Keep both in lockstep.
        let blockType: String
        let nonEmpty: Bool
    }

    /// Single source of truth for "which blocks get a top-level PM id, and what they're
    /// expected to be" — idsForProseMirrorAlignment delegates here TOTALLY (see below), so the
    /// id array and the metadata array cannot drift apart in count/order by construction.
    static func alignmentPairs(_ blocks: [Block]) -> [(id: String, meta: BlockAlignmentMeta)] {
        var result: [(id: String, meta: BlockAlignmentMeta)] = []
        var prevListType: BlockType? = nil
        for block in blocks {
            if isEmptyFragment(block.markdownFragment) { continue }
            // The standalone auto-bibliography MARKER block (distinct from ordinary blocks
            // flagged isBibliography=true, which keep blockType .heading/.paragraph) parses to
            // the `auto_bibliography` PM atom, excluded from BLOCK_TYPES/isBlockType() on the JS
            // side, so it never consumes an index tick in setBlockIdsForTopLevel's walk.
            // Including its id here would shift every subsequent id one position early — so it
            // must contribute NEITHER an id NOR metadata, matching the JS-side exclusion exactly.
            if block.blockType == .bibliography { continue }
            let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)
            if isListBlock && block.blockType == prevListType { continue }
            let nonEmpty = !block.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            result.append((block.id, BlockAlignmentMeta(blockType: block.blockType.rawValue, nonEmpty: nonEmpty)))
            prevListType = isListBlock ? block.blockType : nil
        }
        return result
    }

    /// Collapse consecutive same-type list block IDs for ProseMirror alignment.
    /// ProseMirror merges consecutive list items (separated by \n\n in assembleMarkdown)
    /// into a single list node. This produces an ID array matching PM's top-level node count.
    /// Delegates entirely to `alignmentPairs` — see that function for the filtering/merging rules.
    /// - Parameter blocks: Must be sorted by `sortOrder` ascending.
    static func idsForProseMirrorAlignment(_ blocks: [Block]) -> [String] {
        alignmentPairs(blocks).map { $0.id }
    }

    static func assembleStandardMarkdownForExport(from blocks: [Block]) -> String {
        let sorted = blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        let result = sorted
            .map { $0.markdownForStandardExport() }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")

        return result
    }
    /// Extract integer percentage from a `{width=N%}` Pandoc attribute in a markdown fragment.
    /// Returns nil if no width attribute is present.
    static func parseImageWidthPercent(from fragment: String) -> Int? {
        guard let attrMatch = fragment.range(
            of: #"\{[^}]*width=(\d+)%[^}]*\}"#, options: .regularExpression
        ) else { return nil }
        let attrStr = String(fragment[attrMatch])
        guard let numRange = attrStr.range(
            of: #"(?<=width=)\d+(?=%)"#, options: .regularExpression
        ) else { return nil }
        return Int(attrStr[numRange])
    }

    // MARK: - Image Caption/Alt Parsing

    /// Extracted alt/caption/src for an image markdown fragment's `![...](...)` syntax.
    struct ImageFragmentMeta {
        let src: String?
        let alt: String?
        let caption: String?
    }

    /// Parses `![bracket-text](src){...attrs...}`, separating caption from accessibility alt
    /// text using the SAME self-marking rule as the editor's `image-plugin.ts`: the presence
    /// of an `alt="..."` attribute (even empty) signals the CURRENT format, where bracket text
    /// is the caption and the attribute is the alt. Its absence signals a pre-fix document,
    /// where bracket text is (as before) the alt — any caption for that case lives in the
    /// legacy `<!-- caption: ... -->` comment, recovered separately by
    /// `Database+BlocksReorder.swift`'s gap-fill (not here).
    static func parseImageFragmentMeta(from fragment: String) -> ImageFragmentMeta {
        // Bracket text uses an escape-aware character class (`(?:[^\]\\]|\\.)*`, not a bare
        // `[^\]]*`) so a caption containing an escaped bracket (`\]`) doesn't prematurely end
        // the match — a caption is user-typed free text, unlike the old format's auto-filled
        // filename, so it's meaningfully more likely to contain "]" in practice.
        guard let imageMatch = fragment.range(
            of: #"!\[(?:[^\]\\]|\\.)*\]\([^)]+\)"#, options: .regularExpression
        ) else { return ImageFragmentMeta(src: nil, alt: nil, caption: nil) }

        let matchStr = String(fragment[imageMatch])
        guard let bracketRange = matchStr.range(of: #"(?<=!\[)(?:[^\]\\]|\\.)*(?=\])"#, options: .regularExpression),
              let srcRange = matchStr.range(of: #"(?<=\()[^)]+(?=\))"#, options: .regularExpression) else {
            return ImageFragmentMeta(src: nil, alt: nil, caption: nil)
        }

        let bracketText = String(matchStr[bracketRange])
        let src = String(matchStr[srcRange])

        if let rawAltValue = extractAltAttributeValue(from: fragment) {
            // Current format: bracket text is the caption; the attribute carries the real
            // accessibility alt text. One more unescape pass recovers image-plugin.ts's own
            // manual escaping layer — extractAltAttributeValue has already normalized away the
            // OTHER (automatic, library-added) layer while locating the value's boundaries.
            return ImageFragmentMeta(
                src: src,
                alt: unescapeBackslashOnce(rawAltValue),
                caption: unescapeCaptionBracketText(bracketText)
            )
        } else {
            // Pre-fix format: bracket text is the alt (unchanged from historical behavior).
            return ImageFragmentMeta(src: src, alt: bracketText, caption: nil)
        }
    }

    /// Extracts the value of an `alt="..."` attribute from the fragment's trailing `{...}`
    /// block, or nil if no `alt=` key exists at all — the self-marking "old format" signal
    /// (distinct from returning "" for an explicit but empty `alt=""`).
    ///
    /// The on-disk attribute block has TWO layers of backslash-escaping baked in:
    /// `image-plugin.ts`'s own `escapeAltAttr` (one manual layer, e.g. `"` → `\"`) PLUS a second
    /// layer that mdast-util-to-markdown's serializer adds automatically on top when writing a
    /// value that would otherwise misparse on the next read (confirmed empirically: a value
    /// with no backslash of its own still comes out with 2 backslashes per quote in the
    /// persisted markdownFragment). On the JS/remark-parse side, remark's own automatic
    /// CommonMark unescaping consumes exactly that second layer — scoped to this exact text
    /// run, since remark tokenizes it as its own text node — before `image-plugin.ts`'s own
    /// extraction regex ever looks for the `alt="..."` boundary. This regex-based Swift parser
    /// reads the raw, unprocessed bytes directly, so it must replicate that same normalization
    /// itself, scoped to the isolated attribute block ONLY (not the whole fragment, which would
    /// also wrongly strip the caption's own single-layer bracket escaping — see
    /// unescapeCaptionBracketText), before it can unambiguously locate the closing quote: a raw
    /// `\\"` is genuinely ambiguous between "escaped backslash then a bare terminating quote"
    /// and "one double-escaped quote" without this normalization first.
    private static func extractAltAttributeValue(from fragment: String) -> String? {
        guard let attrBlockRange = fragment.range(
            of: #"\{[^{]*\}\s*$"#, options: [.regularExpression, .backwards]
        ) else { return nil }
        let normalizedBlock = unescapeBackslashOnce(String(fragment[attrBlockRange]))

        guard let regex = try? NSRegularExpression(pattern: #"alt="((?:[^"\\]|\\.)*)""#) else { return nil }
        let range = NSRange(normalizedBlock.startIndex..., in: normalizedBlock)
        guard let match = regex.firstMatch(in: normalizedBlock, range: range),
              let valueRange = Range(match.range(at: 1), in: normalizedBlock) else { return nil }
        return String(normalizedBlock[valueRange])
    }

    /// Reverses one layer of backslash-escaping (`\X` → `X` for any `X`).
    private static func unescapeBackslashOnce(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\\(.)"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    /// Reverses the single layer of backslash-escaping that mdast-util-to-markdown's own image
    /// serializer applies to bracket/description text (e.g. `]` → `\]`) — standard CommonMark
    /// escaping, not something `image-plugin.ts` adds manually, so (unlike the alt attribute)
    /// only one unescape pass is needed here.
    private static func unescapeCaptionBracketText(_ text: String) -> String {
        unescapeBackslashOnce(text)
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
