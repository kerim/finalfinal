//
//  BlockParser+Classification.swift
//  final final
//
//  Block-type detection (heading/code/list/table/image/bibliography/etc.) and plain-text
//  extraction for BlockParser, split out of BlockParser.swift to keep that enum's body under
//  SwiftLint's type_body_length limit and the file under its file_length limit. Mechanical
//  move only -- no behavior change.
//

import Foundation

extension BlockParser {
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
        // Display math block: starts with $$ (either $$...$$ on one line or multi-line).
        // Checked against the block's FIRST LINE only, via the exact same opener
        // predicate `RawBlockSplitter.consumeDisplayMath` (BlockParser+Splitting.swift)
        // used to bound this block in the first place — see `mathDisplayFenceLineRole`.
        // Sharing the predicate means this classifier and the splitter that already
        // produced the block can never disagree about what counts as "math" the way
        // they once did: a naive `trimmed.hasPrefix("$$")` here used to relabel a block
        // the splitter correctly left as an ordinary paragraph (e.g.
        // "$$E = mc^2$$ is the famous equation." — a legitimate embedded closing `$$`
        // followed by trailing prose, never a genuine fence opener) as `.mathDisplay`
        // just because its content happened to start with `$$`.
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        if mathDisplayFenceLineRole(firstLine.trimmingCharacters(in: .whitespaces)).isOpener {
            return .mathDisplay
        }
        // Code block: starts with ```
        if trimmed.hasPrefix("```") { return .codeBlock }
        // Horizontal rule: ---, ***, ___
        if trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil { return .horizontalRule }
        // Section break: <!-- ::break:: -->
        if isSectionBreakMarker(trimmed) { return .sectionBreak }
        // Blockquote: starts with >
        if trimmed.hasPrefix(">") { return .blockquote }
        return nil
    }

    /// Classifies a single already-whitespace-trimmed line's role in a display-math
    /// `$$` fence, matching micromark's own math-flow "meta" bail rule exactly: a
    /// fence only opens when there is NO other `$` anywhere after the leading `$$` —
    /// not merely "doesn't end with $$". Shared by `RawBlockSplitter.consumeDisplayMath`
    /// (BlockParser+Splitting.swift, which uses `isOpener`/`isSingleLineMath` to decide
    /// whether and how a fence opens while splitting) and `fencedOrQuotedType` above
    /// (which uses `isOpener` to classify an already-split block's type) — factored out
    /// as the single source of truth so the two can never disagree, which is exactly
    /// how the two-classifier bug this fixes was possible: `fencedOrQuotedType` used to
    /// run its own, more permissive `hasPrefix("$$")` check independent of this one.
    static func mathDisplayFenceLineRole(_ trimmedLine: String) -> (isOpener: Bool, isSingleLineMath: Bool) {
        let hasOpenPrefix = trimmedLine.hasPrefix("$$")
        let hasCloseSuffix = trimmedLine.hasSuffix("$$")
        let isSingleLineMath = hasOpenPrefix && hasCloseSuffix && trimmedLine.count > 4
        let remainderAfterOpenPrefix = hasOpenPrefix ? String(trimmedLine.dropFirst(2)) : ""
        let opensGluedOnly = hasOpenPrefix && !remainderAfterOpenPrefix.contains("$")
        let isOpener = trimmedLine == "$$" || isSingleLineMath || opensGluedOnly
        return (isOpener, isSingleLineMath)
    }

    /// The exact literal `RawBlockSplitter` (BlockParser+Splitting.swift) and
    /// `isSectionBreakMarker` both compare against. Deliberately EXACT spacing —
    /// no whitespace tolerance — so the splitter's flush guard and this
    /// classifier can never disagree about what counts as "the marker line".
    /// (A separate, more permissive whitespace-tolerant regex exists in
    /// MarkdownUtils.swift for a different purpose — stripping the marker out
    /// of already-composed display text — and must stay separate; see that
    /// call site's comment.)
    static let sectionBreakMarker = "<!-- ::break:: -->"

    /// Explicit, invisible terminator marking the end of the auto-generated bibliography
    /// section. Written into `editorState.content` by `BlockParser+Assembly.swift`'s
    /// `assembleMarkdownForEditor` whenever the last real block is bibliography content, so
    /// every subsequent full reparse (Source Mode's debounced re-parse, and critically the
    /// reparse that runs immediately before every PDF export) has a deterministic,
    /// position-independent signal that the section has ended — see
    /// `sectionFlagCarriedForward`'s doc comment for the bug this closes and the two
    /// rejected approaches that preceded it.
    ///
    /// The `-end` sits BEFORE the closing `::` (`...-end:: -->`, not `...:: -end -->`)
    /// deliberately: `isBibliographyHeading` checks `trimmed.contains("<!-- ::auto-
    /// bibliography:: -->")` and `listTableOrMediaType` checks the same substring, so a
    /// terminator spelled `...:: -end -->` would still contain the opening marker's exact
    /// text and get misclassified as opening (or re-opening) the section it's meant to
    /// close. Spelling the suffix inside the marker's own `::...::` delimiters instead means
    /// neither check's substring can ever match this string. See
    /// `isBibliographyHeading(bibliographyEndMarker) == false` in
    /// BibliographyTerminatorTests.swift for the regression guard.
    static let bibliographyEndMarker = "<!-- ::auto-bibliography-end:: -->"

    /// The literal opening marker itself, as its own named constant — previously only ever
    /// spelled out inline at each call site (`hasBibliographyMarker`'s `.contains` check,
    /// `standaloneMarkerHeadingIndex`'s exact-equality check, and the equivalent checks in
    /// `SectionSyncService+Parsing.swift`/`SectionSyncService+Anchors.swift`). Introduced for
    /// `BibliographyOpeningSelector.Unit.isStandaloneMarker`'s three call sites, which all need
    /// the SAME "is this unit's content the bare marker literal and nothing else" test — see
    /// that field's doc comment. Not a repo-wide literal sweep: existing inline literals
    /// elsewhere are left as-is, out of scope for this fix.
    static let bibliographyStartMarker = "<!-- ::auto-bibliography:: -->"

    /// Pandoc's `--citeproc` generated-bibliography placement marker (the `::: {#refs}\n:::`
    /// fenced-div shorthand for `<div id="refs">...</div>`). Emitted by
    /// `assembleMarkdownForExport(from:bibliographyPlaceholder:)` in place of the document's
    /// bibliography section, at the position that section occupied, so pandoc's citeproc
    /// filter inserts its freshly-generated bibliography there instead of appending it to the
    /// very end of the document — the fix for text typed after the bibliography rendering
    /// BEFORE it in PDF/print output. See that function's doc comment for the full mechanism.
    static let bibliographyPlacementMarker = "::: {#refs}\n:::"

    /// Whether `trimmed` (an already-whitespace-trimmed raw block string) IS a
    /// section-break marker: either the marker alone, or the marker as the
    /// block's FIRST LINE with body content on the line(s) after it.
    ///
    /// Why first-line, not whole-string equality: this predicate is shared by
    /// two different call sites with two different input shapes.
    ///
    /// On the `parse()` path (BlockParser.swift's `parse()`, calling `detectBlockType()`
    /// in this file), `RawBlockSplitter` (BlockParser+Splitting.swift) now ALSO flushes the
    /// marker as its own block the moment it sees the marker line sitting alone
    /// in `currentBlock`, before appending whatever content line comes next —
    /// so `<!-- ::break:: -->\nBody text` (no blank line) splits into TWO raw
    /// blocks there, and this predicate only ever sees the marker by itself on
    /// that path. (It used to reach here as one combined string; the fix for
    /// the "combined block's text gets wiped to empty" bug moved that split
    /// earlier, into the splitter, rather than patching it after the fact here.)
    ///
    /// On the separate editor-sync path (`Database+Blocks.swift`'s
    /// `applyDetectedTypeFromContent`, NOT touched by that fix), `trimmed` is a
    /// single already-existing ProseMirror block's own serialized markdown
    /// fragment being checked for an in-place paragraph → section-break
    /// conversion. That fragment can genuinely be marker-plus-body as ONE
    /// string — it isn't multi-block raw markdown running through
    /// `RawBlockSplitter` at all, so the splitter's new guard never sees it,
    /// and first-line matching (not whole-string equality) is still needed
    /// there to classify it correctly.
    ///
    /// Why not a substring/`.contains` check either: that was this fix's
    /// original bug — a marker appearing mid-sentence inside unrelated prose
    /// (e.g. "...text <!-- ::break:: --> more text...") must NOT match, since
    /// it isn't a section break at all. Anchoring to the first line rejects
    /// that case (the marker isn't at the very start) while still accepting
    /// the marker followed by its own body content on subsequent lines.
    ///
    /// The marker's own line is trimmed of surrounding whitespace before the
    /// comparison, so straggling whitespace around it (e.g.
    /// `"<!-- ::break:: --> \nBody"`, one trailing space before the newline)
    /// still counts as the marker. This isn't a hypothetical: it's only
    /// reachable via Source-Mode hand-editing or pasting text shaped that
    /// way (the app's own slash-command marker insertion never produces it),
    /// but when it IS reached, this must agree with
    /// `SectionReconciler.strippingLeadingBreakMarker`, which trims the same
    /// way — otherwise the two would classify the identical shape
    /// differently and silently disagree on whether it's a section break.
    static func isSectionBreakMarker(_ trimmed: String) -> Bool {
        guard let newline = trimmed.firstIndex(of: "\n") else {
            return trimmed.trimmingCharacters(in: .whitespaces) == sectionBreakMarker
        }
        return trimmed[trimmed.startIndex..<newline]
            .trimmingCharacters(in: .whitespaces) == sectionBreakMarker
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

        // Strip remaining markdown syntax. Headings and code blocks can
        // never actually BE a markdown list, so text in either of those
        // block types that literally starts with "3. " (typed, pasted, or
        // a numbered step inside a code sample) must not have that prefix
        // mistaken for an ordered-list marker and stripped. Blockquotes are
        // different: "> 1. First item" is a completely normal markdown
        // shape — an ordered list nested inside a blockquote — so this
        // regex genuinely can't tell a quoted list from quoted text that
        // merely looks like one. Preserving the literal text is still the
        // safer default for blockquotes: it keeps textContent (search)
        // matching what was actually typed instead of guessing. See
        // MarkdownUtils.stripMarkdownSyntax's `stripListMarkers` doc
        // comment.
        let blockTypeCannotBeAList = blockType == .heading || blockType == .codeBlock || blockType == .blockquote
        text = MarkdownUtils.stripMarkdownSyntax(from: text, stripListMarkers: !blockTypeCannotBeAList)

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
