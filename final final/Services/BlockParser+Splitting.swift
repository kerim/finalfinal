//
//  BlockParser+Splitting.swift
//  final final
//
//  Splits raw markdown into per-block strings. Extracted from BlockParser.swift.
//

import Foundation

extension BlockParser {

    /// Split markdown into raw block strings, respecting code blocks.
    static func splitIntoRawBlocks(_ markdown: String) -> [String] {
        var splitter = RawBlockSplitter()
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            splitter.consume(line: line, at: index, in: lines)
        }
        return splitter.finish()
    }
}

/// Line-at-a-time state machine behind `BlockParser.splitIntoRawBlocks`.
///
/// THE ORDER OF CHECKS IN `consume(line:at:in:)` IS LOAD-BEARING. Display math is
/// tested before the code fence, which is tested before the table, and both the math
/// and table checks are gated on `!inCodeBlock`. Those guards are the fix for a real
/// data-corruption bug: a fenced code block containing a `|`-prefixed or bare `$$`
/// line was split into two DB rows, which knocked block-ID alignment off by one for
/// every block after it (see `MathBlockParserTests.swift`). Preserve the sequence.
private struct RawBlockSplitter {

    /// Regex pattern for footnote definition start: `[^N]:`
    private static let footnoteDefStartPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\[\^(\d+)\]:"#)
        } catch {
            fatalError("Invalid footnote def start regex pattern: \(error)")
        }
    }()

    private var blocks: [String] = []
    private var currentBlock = ""
    private var inCodeBlock = false
    private var inTable = false
    private var inFootnoteDef = false  // Track multi-paragraph footnote definitions
    private var inDisplayMath = false  // Track multi-line $$...$$ display math

    // MARK: - Driver

    mutating func consume(line: String, at index: Int, in lines: [String]) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if consumeDisplayMath(line: line, trimmedLine: trimmedLine) { return }
        if consumeCodeFence(line: line) { return }

        updateTableState(trimmedLine: trimmedLine)
        if inCodeBlock || inTable {
            currentBlock += line + "\n"
            return
        }

        if trimmedLine.isEmpty {
            consumeBlankLine(line: line, at: index, in: lines)
        } else {
            consumeContentLine(line: line, trimmedLine: trimmedLine)
        }
    }

    /// Flushes whatever the last line left open. Don't forget the last block.
    mutating func finish() -> [String] {
        flushCurrentBlockIfNotBlank()
        return blocks
    }

    // MARK: - Per-line stages

    /// Handles the display-math fence: bare `$$` opens/closes, `$$...$$` is a one-line
    /// block, and every line in between is accumulated verbatim.
    /// - Returns: `true` when the line was consumed here and no later stage should see it.
    private mutating func consumeDisplayMath(line: String, trimmedLine: String) -> Bool {
        let isSingleLineMath = trimmedLine.hasPrefix("$$") && trimmedLine.hasSuffix("$$") && trimmedLine.count > 4
        if (trimmedLine == "$$" || isSingleLineMath) && !inCodeBlock {
            if !inDisplayMath {
                // Starting display math: flush current block
                flushCurrentBlockIfNotBlank()
                inDisplayMath = true
                inFootnoteDef = false
                currentBlock += line + "\n"
                // Opened and closed on one line ($$...$$): finish the block immediately
                if isSingleLineMath {
                    blocks.append(currentBlock)
                    currentBlock = ""
                    inDisplayMath = false
                }
                return true
            } else if trimmedLine == "$$" {
                // Closing $$
                currentBlock += line + "\n"
                blocks.append(currentBlock)
                currentBlock = ""
                inDisplayMath = false
                return true
            }
        }

        // Inside display math: accumulate lines. A `$$...$$` line reached while math is
        // already open deliberately falls through the branch above and lands here.
        if inDisplayMath {
            currentBlock += line + "\n"
            return true
        }

        return false
    }

    /// Handles a ``` code fence, which toggles code-block state.
    /// - Returns: `true` when the line was consumed here.
    private mutating func consumeCodeFence(line: String) -> Bool {
        guard line.hasPrefix("```") else { return false }

        if inTable {
            // A table with no blank line before a code-fence opener: close
            // the table first (same "ending a table" logic as below) before
            // entering code-block state. Without this, the fence line gets
            // glued onto the table's own currentBlock (mis-typing it and
            // corrupting its fragment) and inTable stays stuck true while
            // inCodeBlock also becomes true, which then spuriously "ends the
            // table" again on the fence's first content line, splitting the
            // code block apart. Reverse-direction sibling of the !inCodeBlock
            // guards elsewhere, which stop table/math syntax INSIDE a fence from
            // being misdetected as starting a new block.
            blocks.append(currentBlock)
            currentBlock = ""
            inTable = false
        }

        inCodeBlock.toggle()
        inFootnoteDef = false
        currentBlock += line + "\n"
        return true
    }

    /// Opens a table on the first `|` line and closes it on the first non-blank,
    /// non-`|` line. Never consumes the line — the caller decides what to do next.
    private mutating func updateTableState(trimmedLine: String) {
        let isTableLine = trimmedLine.hasPrefix("|")
        if isTableLine && !inTable && !inCodeBlock {
            // Starting a table, flush current block
            if !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(currentBlock)
            }
            currentBlock = ""
            inTable = true
            inFootnoteDef = false
        } else if !isTableLine && inTable && !trimmedLine.isEmpty {
            // Ending a table
            blocks.append(currentBlock)
            currentBlock = ""
            inTable = false
        }
    }

    /// A blank line normally ends the current block — unless it sits inside a footnote
    /// definition, or between a caption comment and the image it belongs to.
    private mutating func consumeBlankLine(line: String, at index: Int, in lines: [String]) {
        if inFootnoteDef {
            // In a footnote def: peek at next line to see if it's a 4-space continuation
            if isFootnoteContinuation(after: index, in: lines) {
                // Keep the empty line as part of the footnote definition block
                currentBlock += line + "\n"
                return
            }
            // End of footnote definition
            inFootnoteDef = false
        }

        if isCaptionAwaitingImage(after: index, in: lines) {
            // Absorb blank line — keep caption and image in same block
            currentBlock += line + "\n"
            return
        }

        flushCurrentBlockIfNotBlank()
    }

    /// A non-blank line either opens a footnote definition, interrupts the current
    /// block with a list marker, or is simply appended to the current block.
    private mutating func consumeContentLine(line: String, trimmedLine: String) {
        // Section-break marker boundary, both directions. Without this, a marker
        // sitting immediately next to prose with NO blank line in between — on
        // either side — gets glued into ONE raw block string alongside that prose.
        // detectBlockType/isSectionBreakMarker still classifies that combined string
        // as `.sectionBreak` (its own first-line check matches), but
        // extractTextContent forces textContent="" for EVERY `.sectionBreak` block
        // regardless of what body text the fragment actually holds — so the prose
        // is still sitting right there in markdownFragment, yet silently vanishes
        // from textContent (word counts, previews, search, the outline sidebar).
        // Splitting the marker into its own block here, at the source, means the
        // prose becomes an ordinary `.paragraph` block with its textContent
        // extracted normally — nothing downstream needs to special-case a
        // section-break fragment that also happens to carry text.
        let accumulatedIsMarkerAlone =
            currentBlock.trimmingCharacters(in: .whitespacesAndNewlines) == BlockParser.sectionBreakMarker
        if accumulatedIsMarkerAlone {
            // Forward case: `<!-- ::break:: -->\nBody text`. The marker line was
            // accumulated alone last time through, and now the body's first line
            // has arrived right behind it. Flush the marker as its own complete
            // block before this new line starts accumulating into a fresh one.
            // Reset inFootnoteDef same as every other flush site in this file —
            // otherwise a footnote def flushed at the marker boundary leaves the
            // flag stuck true, and the next blank line is wrongly absorbed as a
            // footnote-continuation blank, merging two blocks that should stay
            // separate. See BlockParserSectionBreakClassificationTests.swift.
            flushCurrentBlockIfNotBlank()
            inFootnoteDef = false
        } else if line == BlockParser.sectionBreakMarker,
                  !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Reverse case: `Prose\n<!-- ::break:: -->`. Ordinary content was
            // already accumulating and the marker line itself has now arrived with
            // no blank line before it. Flush what came before so the marker still
            // becomes its own `.sectionBreak` block instead of getting appended
            // onto the end of a `.paragraph`-typed block — which would silently
            // drop the section break from the outline sidebar (still no text-wipe
            // there, since the combined block stays typed `.paragraph`, but a real
            // Swift/JS block-count mismatch against ProseMirror's 2-node parse of
            // the same markdown).
            //
            // Deliberately `line`, NOT `trimmedLine`, here — unlike the forward
            // case above. `sectionBreakMarker`'s own doc comment (BlockParser.swift)
            // insists on exact, unindented spacing so the splitter's guards and
            // isSectionBreakMarker can never disagree about what counts as "the
            // marker line"; an indented marker (e.g. inside a list item, `"-
            // Item\n  <!-- ::break:: -->"`) is a comment INSIDE that item, not a
            // section break interrupting it, and must stay glued to the
            // surrounding list so it parses as ONE block — matching ProseMirror,
            // which keeps an HTML comment inside a list item as part of the same
            // bullet_list node. Matching on `trimmedLine` here would wrongly slice
            // that one list block into three (list/marker/list). The forward case
            // doesn't need this restriction: there `currentBlock` already IS just
            // the (possibly indented) marker alone — accepted at any indentation —
            // and flushing it as its own block there is correct and intentional.
            // Same inFootnoteDef reset as the forward case above, for the same reason.
            flushCurrentBlockIfNotBlank()
            inFootnoteDef = false
        }

        let lineRange = NSRange(line.startIndex..., in: line)
        if Self.footnoteDefStartPattern.firstMatch(in: line, range: lineRange) != nil {
            // Flush previous block before starting footnote def
            flushCurrentBlockIfNotBlank()
            inFootnoteDef = true
        } else if let newLineListKind = BlockParser.listMarkerKind(trimmedLine),
                  !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  BlockParser.detectBlockType(currentBlock).0 != newLineListKind {
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
            // Same reset as every other flush site in this file (see the two
            // marker-boundary flushes above) — a list interrupting a still-open
            // footnote definition would otherwise leave inFootnoteDef stuck true
            // past this flush, corrupting the next blank line's handling.
            inFootnoteDef = false
        }
        currentBlock += line + "\n"
    }

    // MARK: - Lookahead helpers

    /// Whether the line after `index` is a 4-space-indented footnote continuation.
    private func isFootnoteContinuation(after index: Int, in lines: [String]) -> Bool {
        let nextIndex = index + 1
        return nextIndex < lines.count && lines[nextIndex].hasPrefix("    ")
    }

    /// Whether `currentBlock` is a complete `<!-- caption: ... -->` comment whose next
    /// non-blank line is an image — in which case the blank line between them must be
    /// absorbed so caption and image stay in one block.
    private func isCaptionAwaitingImage(after index: Int, in lines: [String]) -> Bool {
        let trimmedBlock = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBlock.range(of: "^<!--\\s*caption:", options: .regularExpression) != nil,
              trimmedBlock.hasSuffix("-->") else { return false }

        // Peek ahead for image line
        var nextIdx = index + 1
        while nextIdx < lines.count,
              lines[nextIdx].trimmingCharacters(in: .whitespaces).isEmpty {
            nextIdx += 1
        }
        return nextIdx < lines.count
            && lines[nextIdx].trimmingCharacters(in: .whitespaces).hasPrefix("![")
    }

    // MARK: - Block accumulation

    private mutating func flushCurrentBlockIfNotBlank() {
        guard !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.append(currentBlock)
        currentBlock = ""
    }
}
