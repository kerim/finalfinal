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
    ///
    /// Also recognizes a GLUED fence — `$$` sharing a line with LaTeX content instead of
    /// sitting alone — as "prefix xor suffix": a line starting with `$$` but NOT also
    /// ending with `$$` opens a fence (e.g. `$$\begin{aligned}`), and once open, a line
    /// ending with `$$` but NOT also starting with `$$` closes it (e.g. `\end{aligned}$$`).
    /// A line that's both (prefix AND suffix) keeps the existing single-line/fall-through
    /// behavior unchanged. This mirrors the JS math tokenizer's own swallow-to-EOF
    /// behavior on an unterminated glued opener (see math-plugin.ts /
    /// math-paste-normalize.ts) — matching it here means a glued-open line with no
    /// matching close accumulates to EOF instead of staying a paragraph, same as JS.
    /// - Returns: `true` when the line was consumed here and no later stage should see it.
    private mutating func consumeDisplayMath(line: String, trimmedLine: String) -> Bool {
        let hasOpenPrefix = trimmedLine.hasPrefix("$$")
        let hasCloseSuffix = trimmedLine.hasSuffix("$$")
        // Matches micromark's own math-flow "meta" state exactly: it bails the instant it
        // sees ANY further `$` character while scanning the rest of the opening line, so a
        // line only opens a real display-math fence when there is NO other `$` anywhere
        // after the leading `$$` — not merely "doesn't end with $$". Without this, a line
        // like `$$E = mc^2$$ is the famous equation.` (a legitimate embedded closing `$$`
        // followed by trailing prose) or `$$a + $b$ c` (two separate `$`-delimited runs) is
        // misclassified as a glued opener and swallows everything after it to EOF —
        // corrupting input micromark itself would have safely parsed as an ordinary
        // paragraph. See math-paste-normalize.ts for the mirrored JS predicate.
        //
        // Shared with `BlockParser.fencedOrQuotedType`'s block-type classification via
        // `mathDisplayFenceLineRole` (BlockParser.swift) — a single source of truth so
        // this splitter and that classifier can never disagree about what opened.
        let fenceRole = BlockParser.mathDisplayFenceLineRole(trimmedLine)

        if fenceRole.isOpener && !inCodeBlock {
            if !inDisplayMath {
                // Starting display math: flush current block
                flushCurrentBlockIfNotBlank()
                inDisplayMath = true
                inFootnoteDef = false
                currentBlock += line + "\n"
                // Opened and closed on one line ($$...$$): finish the block immediately
                if fenceRole.isSingleLineMath {
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

        // Inside display math: accumulate lines, then check for a glued close
        // (suffix without prefix) — a line that's both prefix and suffix deliberately
        // falls through here unchanged (stays open), matching existing behavior.
        if inDisplayMath {
            currentBlock += line + "\n"
            if hasCloseSuffix && !hasOpenPrefix {
                blocks.append(currentBlock)
                currentBlock = ""
                inDisplayMath = false
            }
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
        if consumeBibliographyEndMarkerGlue(line: line) {
            return
        }

        // Section-break / bibliography-end marker boundary, both directions, both
        // markers. Without this, a marker sitting immediately next to prose with NO
        // blank line in between — on either side — gets glued into ONE raw block
        // string alongside that prose. detectBlockType/isSectionBreakMarker still
        // classifies a glued section-break combination as `.sectionBreak` (its own
        // first-line check matches), but extractTextContent forces textContent=""
        // for EVERY `.sectionBreak` block regardless of what body text the fragment
        // actually holds — so the prose is still sitting right there in
        // markdownFragment, yet silently vanishes from textContent (word counts,
        // previews, search, the outline sidebar). The bibliography-end marker has a
        // parallel failure mode: `parse()` matches it via exact equality
        // (`trimmed == bibliographyEndMarker`), so a glued combination wouldn't match
        // at all and the terminator would silently fail to close the section — the
        // exact bug this whole mechanism exists to fix. Splitting either marker into
        // its own block here, at the source, means nothing downstream needs to
        // special-case a marker fragment that also happens to carry text.
        let accumulatedTrimmed = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let accumulatedIsMarkerAlone =
            accumulatedTrimmed == BlockParser.sectionBreakMarker
            || accumulatedTrimmed == BlockParser.bibliographyEndMarker
        if accumulatedIsMarkerAlone {
            // Forward case: `<!-- ::break:: -->\nBody text` (or the bibliography-end
            // marker in place of the break marker). The marker line was accumulated
            // alone last time through, and now the body's first line has arrived
            // right behind it. Flush the marker as its own complete block before this
            // new line starts accumulating into a fresh one. Reset inFootnoteDef same
            // as every other flush site in this file — otherwise a footnote def
            // flushed at the marker boundary leaves the flag stuck true, and the next
            // blank line is wrongly absorbed as a footnote-continuation blank,
            // merging two blocks that should stay separate. See
            // BlockParserSectionBreakClassificationTests.swift.
            flushCurrentBlockIfNotBlank()
            inFootnoteDef = false
        } else if line == BlockParser.sectionBreakMarker || line == BlockParser.bibliographyEndMarker,
                  !currentBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Reverse case: `Prose\n<!-- ::break:: -->` (or the bibliography-end
            // marker). Ordinary content was already accumulating and the marker line
            // itself has now arrived with no blank line before it. Flush what came
            // before so the marker still becomes its own block instead of getting
            // appended onto the end of a `.paragraph`-typed block — which would
            // silently drop the section break from the outline sidebar (still no
            // text-wipe there, since the combined block stays typed `.paragraph`, but
            // a real Swift/JS block-count mismatch against ProseMirror's 2-node parse
            // of the same markdown), or — for the bibliography-end marker — glue the
            // terminator onto the end of the preceding paragraph so `parse()`'s exact
            // `trimmed == bibliographyEndMarker` check never matches it at all.
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
            //
            // SCOPE OF THAT "stay glued when indented" rule: it is
            // `sectionBreakMarker`'s contract only. The two markers this branch
            // matches do NOT share one invariant:
            //
            //   • `sectionBreakMarker` — whole-line and unindented ONLY. Anywhere
            //     else (indented, or sharing a line with other text) it is just an
            //     HTML comment belonging to its surrounding block, and must stay
            //     glued there. Losing one costs a sidebar outline entry and a
            //     block-count mismatch; nothing is deleted.
            //   • `bibliographyEndMarker` — always split out into its own block, at
            //     any indentation, even when it only appears as a SUBSTRING of a
            //     line. That is `consumeBibliographyEndMarkerGlue` (called earlier,
            //     line ~222), which fires before this guard is ever reached for the
            //     same-line-glue shapes. It deliberately overrides the reasoning
            //     above, because the terminator is invisible in CodeMirror: the user
            //     cannot see or place it, so a marker that fails to be recognised
            //     leaves the bibliography section open and the text around it is
            //     silently lost. Data loss outranks matching ProseMirror's node
            //     count, so the trade-off flips.
            //
            // Do NOT "unify" the two by making the terminator obey the
            // stay-glued-when-indented rule; that reintroduces the orphan/data-loss
            // path `consumeBibliographyEndMarkerGlue`'s doc comment describes.
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

    /// Same-line glue on the bibliography-end terminator: a raw line that CONTAINS the
    /// terminator as a substring but isn't EQUAL to it. In CodeMirror the terminator's
    /// line is fully hidden via `Decoration.replace` (a "blank" line to the eye), and
    /// `atomicRanges` only protects its INTERIOR — so both the start and end of that
    /// blank line are legal cursor positions. Clicking either boundary and typing glues
    /// new text directly onto the SAME line as the terminator:
    /// `Foo<!-- ::auto-bibliography-end:: -->` (glued before) or the mirror
    /// `<!-- ::auto-bibliography-end:: -->Foo` (glued after). Neither shape matches the
    /// adjacent-LINE guards above (which only fire when the marker occupies a whole line
    /// by itself) or `parse()`'s exact-equality match, so without this the section never
    /// closes and the glued text is silently lost — reproducing, through this fix's own
    /// UI affordance, the exact orphan bug this whole mechanism exists to prevent.
    ///
    /// The terminator is always emitted FIRST as its own block, regardless of which side
    /// the glued text landed on: the marker is completely invisible in CodeMirror, so a
    /// user can never deliberately choose "before" vs "after" it — both shapes are the
    /// same accidental gesture (clicking what looks like a blank trailing line and
    /// typing). Closing the section before the glued text is evaluated means that text
    /// always survives as ordinary, unflagged content for EITHER shape, instead of the
    /// "glued before" shape silently inheriting `isBibliography = true` from the still-open
    /// section and reproducing the export-drops-it/undeletable data-loss path this
    /// terminator exists to close off in the first place.
    ///
    /// Any content already accumulating in `currentBlock` from EARLIER lines (the
    /// adjacent-line case above, e.g. a paragraph glued to the terminator's line with no
    /// blank line before it) is flushed as its own block first, untouched by the
    /// same-line splitting below — it stays flagged by its own position, exactly as the
    /// adjacent-line guards already handle it.
    /// - Returns: `true` when the line was consumed here and no later stage should see it.
    private mutating func consumeBibliographyEndMarkerGlue(line: String) -> Bool {
        guard line != BlockParser.bibliographyEndMarker,
              let markerRange = line.range(of: BlockParser.bibliographyEndMarker) else {
            return false
        }

        let prefix = String(line[line.startIndex..<markerRange.lowerBound])
        let suffix = String(line[markerRange.upperBound...])

        flushCurrentBlockIfNotBlank()
        inFootnoteDef = false

        blocks.append(BlockParser.bibliographyEndMarker + "\n")

        if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(prefix + "\n")
        }
        if !suffix.isEmpty {
            // Left open (not flushed) so a following line with no blank line before it
            // still merges into the same paragraph as the glued suffix text, matching
            // this splitter's normal accumulation behavior everywhere else.
            currentBlock = suffix + "\n"
        }
        return true
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
