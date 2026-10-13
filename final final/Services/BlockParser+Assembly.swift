//
//  BlockParser+Assembly.swift
//  final final
//
//  Reassembles blocks back into markdown, and derives the ProseMirror
//  top-level alignment arrays. Extracted from BlockParser.swift.
//

import Foundation

extension BlockParser {

    // MARK: - Assembly

    /// Assemble blocks back into markdown
    /// Uses tuple comparison for tie-breaking: headings sort before non-headings at same sortOrder
    static func assembleMarkdown(from blocks: [Block]) -> String {
        // MUST filter empty fragments — they produce no ProseMirror node
        let result = assemblySorted(blocks)
            .map { $0.markdownFragment }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")

        DebugLog.log(.sync, "[ASSEMBLE] \(blocks.count) blocks -> result length=\(result.count)")

        return result
    }

    /// Same as `assembleMarkdown`, but inserts `bibliographyEndMarker` immediately after the
    /// LAST block (by the same `assemblySorted` ordering `assembleMarkdown` itself uses) that
    /// is bibliography content — wherever that block falls in the document, not only when it
    /// happens to be the document's final block — so markdown handed to Milkdown or CodeMirror
    /// via `editorState.content` always carries a permanent, position-independent "the
    /// bibliography section ends here" signal, instead of relying on a count that can drift
    /// or corrupt. See `BlockParser.bibliographyEndMarker`'s doc comment for the bug this
    /// closes: `editorState.content` is exactly what `flushContentToDatabase()` — the
    /// reparse that runs immediately before every PDF export — feeds into `parse()`.
    ///
    /// MUST NOT require bibliography content to be the document's last block: the entire
    /// point of this terminator is the case where the user has typed trailing text AFTER the
    /// bibliography (no closing heading in between) — exactly the shape that produced the
    /// orphan-flag bug in the first place. An earlier version of this function guarded on
    /// "the last non-empty block is bibliography content" and returned `base` unmodified
    /// otherwise, which meant the terminator was never emitted for precisely that trailing-
    /// text case — worse, on the next reparse `sectionFlagCarriedForward` would re-flag the
    /// trailing text as bibliography, and the next bibliography regeneration
    /// (`BibliographySyncService.updateBibliographyBlock`, which opens with a `deleteAll` on
    /// every `isBibliography == true` row) would then delete it outright.
    ///
    /// NOT used by `assembleMarkdownForExport`/`assembleStandardMarkdownForExport` -- neither
    /// needs this terminator, but for different reasons now. `assembleStandardMarkdownForExport`
    /// still operates on already bibliography-filtered blocks (`DocumentManager.exportBlocks()`
    /// filters `!$0.isBibliography` before calling it), so it never sees bibliography content to
    /// mark the end of. `assembleMarkdownForExport` now receives the FULL unfiltered block array
    /// instead (`DocumentManager.loadContentForExport()` passes `allBlocksForExport()`'s output
    /// straight through, unfiltered) and does its own bibliography handling internally --
    /// filtering, dedup via `emittedPlaceholder`, and placeholder emission -- so it has no use
    /// for this terminator either.
    static func assembleMarkdownForEditor(from blocks: [Block]) -> String {
        let sortedReal = assemblySorted(blocks).filter { !isEmptyFragment($0.markdownFragment) }
        var fragments = sortedReal.map { $0.markdownFragment }
        if let lastBibIndex = sortedReal.lastIndex(where: { $0.isBibliography }) {
            fragments.insert(bibliographyEndMarker, at: lastBibIndex + 1)
        }
        return fragments.joined(separator: "\n\n")
    }

    /// Assemble blocks into Pandoc-compatible markdown for export.
    /// Uses `markdownForExport()` which includes fig-alt and width attributes for image blocks.
    /// - Parameter bibliographyPlaceholder: when true, replaces the bibliography section — which
    ///   is otherwise dropped entirely, since each export format regenerates its own bibliography —
    ///   with the user's own bibliography heading (if the section has one) followed by
    ///   `bibliographyPlacementMarker`, at the position the section occupies. `false` (the
    ///   default) drops the section with nothing left behind, byte-identical to today's behavior —
    ///   unchanged for DOCX/ODT.
    static func assembleMarkdownForExport(from blocks: [Block], bibliographyPlaceholder: Bool = false) -> String {
        let sorted = assemblySorted(blocks)

        // Computed once, over the SORTED array (not the raw `blocks` parameter -- see
        // `classifyNotesRuns`'s doc comment for why): which machine-managed "# Notes" heading
        // ids Pandoc's footnote lifting left stranded with nothing but footnote definitions
        // (and their continuations) underneath, plus which non-heading blocks in every run are
        // continuation paragraphs of a multi-paragraph footnote definition. Skipped/indented in
        // the loop below, after the isBibliography branch.
        let notesClassification = classifyNotesRuns(in: sorted)

        // Scan the WHOLE bibliography run for a `.heading`-typed block -- do not just take the
        // first isBibliography block encountered. A persisted `<!-- ::auto-bibliography:: -->`
        // marker block is ITSELF flagged isBibliography = true and can sort ahead of the real
        // `# Bibliography` heading; it is typed `.bibliography`, never `.heading` (detectBlockType
        // tests `^#{1,6}\s` before classifying as `.bibliography`, and the glued source-mode shape
        // `<!-- ::auto-bibliography:: --># Bibliography` fails that test too). Using the naive
        // first-isBibliography-block selector would silently take the marker-only branch and drop
        // the user's heading from the PDF whenever a marker block exists -- exactly the headingless
        // bibliography this fix exists to prevent.
        //
        // Safe against multiple `.heading && isBibliography` blocks (e.g. a citation entry whose
        // formatted text happens to start with `#`, since BibliographySyncService's
        // updateBibliographyBlock computes `isHeading = fragment.hasPrefix("#")` per-fragment for
        // EVERY rawBlock, not just the first) because of two invariants that hold together:
        // (1) BibliographySyncService.generateBibliographyMarkdown always builds the header
        // fragment ("# {headerName}\n\n") FIRST, before any entries are appended, so no entry
        // fragment can precede it in the string that gets split into blocks; (2)
        // updateBibliographyBlock is atomic per generation -- it deletes ALL existing
        // isBibliography blocks for the project first, then inserts freshly split fragments in
        // order with sortOrder = start + Double(index) * step (where `start` is the position the
        // bibliography is being reinserted at and `step > 0` is the spacing between fragments),
        // so the header fragment (index 0) always gets the LOWEST sortOrder of the batch, and no
        // block from a prior generation survives to sort ahead of it. Together these guarantee
        // the header is always the lowest-sortOrder qualifying block at generation time -- "first
        // in document order" reliably selects the real header, never a false-positive
        // heading-shaped entry.
        //
        // Known, out-of-scope gap: Database+BlocksReplace+Preservation.swift's applyPreservedHeading can
        // reattach isBibliography = true to a heading block via title-based occurrence-index
        // matching during block reconciliation -- a path entirely separate from
        // updateBibliographyBlock's atomic delete-all/insert-all guarantee above relies on.
        // Whether reconciliation/undo could ever produce two simultaneously-live
        // isBibliography && .heading blocks outside a single generation is unproven; no existing
        // test covers this. Pre-existing behavior, unchanged by this fix.
        let headingBlock = sorted.first { $0.isBibliography && $0.blockType == .heading }

        var fragments: [String] = []
        var emittedPlaceholder = false

        for block in sorted {
            // MUST run before the isBibliography branch, for ALL blocks -- a bibliography-
            // flagged block with a blank/whitespace-only fragment must never reach
            // `emittedPlaceholder = true` at its own (possibly early) sort position, or the
            // real `# Bibliography` heading reached later gets silently dropped since a
            // placeholder was "already emitted."
            let fragment = block.markdownForExport()
            guard !isEmptyFragment(fragment) else { continue }

            if block.isBibliography {
                guard bibliographyPlaceholder, !emittedPlaceholder else { continue }
                emittedPlaceholder = true
                if let headingBlock {
                    // markdownForExport() (== markdownFragment, e.g. "# Bibliography"), NOT
                    // textContent (which would give just the bare word "Bibliography", rendering
                    // as an ordinary paragraph, not a heading -- wrong). stripBibliographyMarker
                    // here is defensive belt-and-braces, not load-bearing: a fragment carrying the
                    // marker inline isn't typed `.heading` to begin with (see above), so
                    // headingBlock's fragment is already clean by construction --
                    // BibliographySyncService's generateBibliographyMarkdown explicitly builds it
                    // WITHOUT the marker, and Source Mode content gets stripSectionAnchors/
                    // stripBibliographyMarker applied before editorState.content is ever reparsed.
                    fragments.append(SectionSyncService.stripBibliographyMarker(from: headingBlock.markdownForExport()))
                }
                // No heading anywhere in the bibliography section -> fall back to the marker alone.
                fragments.append(bibliographyPlacementMarker)
                continue
            }

            // MUST run AFTER the isBibliography branch, not before it: a block can carry BOTH
            // isBibliography and isNotes on a legacy document whose bibliography header was once
            // literally named "Notes" (current validation in ExportSettings.swift, ~line 671,
            // rejects that name going forward, but a grace-list path keeps old such documents
            // working). The isBibliography branch above already `continue`s on every one of its
            // paths, so placing this check after it means a dual-flagged heading is always
            // handled as bibliography content and never reaches this check at all -- deliberate.
            if notesClassification.qualifyingHeadingIDs.contains(block.id) {
                continue
            }

            // A multi-paragraph footnote's continuation paragraph: indent every line 4
            // spaces so it parses as PART OF the preceding "[^N]: ..." definition (Pandoc
            // footnote-continuation syntax) instead of spilling out as an ordinary
            // top-level paragraph — see `indentedContinuation`'s doc comment.
            if notesClassification.continuationIDs.contains(block.id) {
                fragments.append(indentedContinuation(fragment))
                continue
            }

            fragments.append(fragment)
        }

        return fragments.joined(separator: "\n\n")
    }

    /// Pre-compiled regex matching a machine-generated footnote-definition line's START:
    /// `[^N]:` where N is one or more digits. Deliberately mirrors
    /// `FootnoteSyncService+Reconciliation.swift`'s `footnoteDefPattern`
    /// (`^\[\^(\d+)\]:\s*(.*)`) in restricting the label to digits only -- `FootnoteSyncService`
    /// never generates a non-numeric label like `[^method-note]:`, so a non-numeric label is
    /// actually evidence a block was hand-typed by the user, not evidence to loosen the pattern
    /// for. A looser regex here would wrongly treat user-written content as machine-managed and
    /// delete the user's own heading -- exactly the failure class this whole fix exists to avoid.
    ///
    /// Deliberately NOT `.anchorsMatchLines`, unlike the mirrored pattern: this is matched
    /// against a single already-trimmed fragment, and `^` must anchor to the START of that
    /// fragment only -- a paragraph whose *second* line happens to start with this shape must
    /// not count as a footnote definition.
    private static let footnoteDefStartPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\[\^\d+\]:"#, options: [])
        } catch {
            fatalError("Invalid footnote def start regex pattern: \(error)")
        }
    }()

    /// Whether `fragment`, once trimmed, starts with a machine-generated numeric footnote
    /// definition marker (`[^N]:`). See `footnoteDefStartPattern`'s doc comment for why the
    /// anchoring is numeric-only and start-of-fragment-only.
    private static func isFootnoteDefinitionFragment(_ fragment: String) -> Bool {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return footnoteDefStartPattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// Prefixes EVERY line of `fragment` with 4 spaces -- the Pandoc-markdown indent a footnote
    /// definition's continuation paragraph(s) require to parse as part of that footnote rather
    /// than as an ordinary top-level paragraph. Splits on `"\n"` (not a regex) so this behaves
    /// identically whether `fragment` is a single line or carries embedded newlines (e.g. a
    /// continuation paragraph typed with a manual line break) -- every line gets the indent, not
    /// just the first. Deliberately does NOT indent an already-blank line: `"    " + ""` would
    /// leave trailing whitespace on what must stay an empty separator line between paragraphs.
    static func indentedContinuation(_ fragment: String) -> String {
        fragment
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : "    " + $0 }
            .joined(separator: "\n")
    }

    /// Per-Notes-run classification, computed once over the whole document for export.
    struct NotesRunClassification {
        /// Every `isNotes && .heading` block whose entire run of following isNotes content is
        /// homogeneous machine-managed footnote content (definitions and/or their
        /// continuations, zero pre-definition user prose) -- safe to drop from export because
        /// nothing but Pandoc's own lifted `[^N]: ...` blocks sits under it.
        var qualifyingHeadingIDs: Set<String> = []
        /// Every non-heading block, in ANY run (qualifying or not), that is a continuation
        /// paragraph of a multi-paragraph footnote definition -- see the shared ownership
        /// definition in this function's doc comment. Must be 4-space indented on export via
        /// `indentedContinuation`, never dropped.
        var continuationIDs: Set<String> = []
    }

    /// Classifies every "# Notes" run in `sorted` for export: which headings qualify to be
    /// DROPPED, and which non-heading blocks (in every run, regardless of whether that run's own
    /// heading qualifies) are CONTINUATION paragraphs that must be indented rather than emitted
    /// as plain top-level text.
    ///
    /// MUST take the already-`assemblySorted` array, not the raw `blocks` parameter passed to
    /// `assembleMarkdownForExport`: `assemblySorted` breaks ties at equal `sortOrder` by placing
    /// headings before non-headings, and on a document where the Notes heading and its first
    /// definition happen to share a `sortOrder` (a real shape this codebase's block-reconciliation
    /// can produce), raw input order could place the heading after its own definitions, silently
    /// producing an empty scanned run that fails toward (wrongly) keeping a heading that should
    /// have been dropped -- or worse, misreading the run boundary entirely.
    ///
    /// Run boundary: walks forward from the heading collecting the run of immediately-following
    /// blocks that are `isNotes && blockType != .heading`, stopping at the first block that is
    /// either not `isNotes` or is any heading. This deliberately mirrors `BlockParser.swift`'s own
    /// `sectionFlagCarriedForward` -- the actual producer of the `isNotes` flag, which re-opens it
    /// at every `# notes` heading and carries it until the next heading OF ANY KIND -- and NOT
    /// `FootnoteSyncService+Reconciliation.swift`'s `stripNotesSection`, which closes only on an
    /// H1. Those two boundary rules diverge on a document with a non-H1 heading inside the Notes
    /// run; picking the wrong one here would either scan past the flag's real extent or stop short
    /// of it. Do not "harmonize" this with `stripNotesSection` -- they answer different questions
    /// (what the flag actually covers, vs. what markdown text to strip) and only one is correct
    /// here.
    ///
    /// Shared ownership definition (matches `FootnoteSyncService+Reconciliation.swift`'s
    /// reconciliation logic -- keep both in sync if this rule ever changes): walking a run in
    /// order, a non-heading block that is itself a `[^N]:` definition (per
    /// `isFootnoteDefinitionFragment`) opens/re-opens an owner; any LATER non-heading,
    /// non-definition block in the SAME run is a continuation of the most recently opened owner;
    /// a non-heading, non-definition block BEFORE any definition in the run is the user's own
    /// hand-typed prose -- it owns nothing, is never indented, and disqualifies the heading.
    ///
    /// A heading qualifies (added to `qualifyingHeadingIDs`) only if its run has AT LEAST ONE
    /// non-empty block, AND every non-empty block in the run is EITHER a definition OR a
    /// continuation -- i.e. zero pre-definition user prose anywhere in the run. Empty fragments
    /// count toward neither "at least one" nor "every." An empty run (heading with nothing
    /// non-empty under it) does NOT qualify -- fails toward keeping the heading.
    ///
    /// Continuation collection is INDEPENDENT of heading qualification: a continuation is
    /// collected (and indented on export) even in a run whose heading does NOT qualify for
    /// dropping, because the indent is a Pandoc-syntax requirement for the continuation to parse
    /// as part of its footnote at all -- unrelated to what export ultimately does with the
    /// heading above it. Multiple independent "# notes" headings (possible since
    /// `sectionFlagCarriedForward` can re-open the flag more than once per document) are each
    /// judged strictly on their own run's evidence.
    private static func classifyNotesRuns(in sorted: [Block]) -> NotesRunClassification {
        var result = NotesRunClassification()
        var index = 0
        while index < sorted.count {
            let block = sorted[index]
            guard block.isNotes, block.blockType == .heading else {
                index += 1
                continue
            }

            var runEnd = index + 1
            var hasNonEmptyBlock = false
            var allNonEmptyQualify = true
            var sawDefinition = false
            while runEnd < sorted.count {
                let candidate = sorted[runEnd]
                guard candidate.isNotes, candidate.blockType != .heading else { break }
                let candidateFragment = candidate.markdownForExport()
                if !isEmptyFragment(candidateFragment) {
                    hasNonEmptyBlock = true
                    if isFootnoteDefinitionFragment(candidateFragment) {
                        sawDefinition = true
                    } else if sawDefinition {
                        // Continuation of the most recently seen definition -- doesn't
                        // disqualify the run, but must still be indented on export.
                        result.continuationIDs.insert(candidate.id)
                    } else {
                        // Pre-definition content: the user's own hand-typed Notes prose.
                        // Owns nothing, disqualifies the heading, never indented.
                        allNonEmptyQualify = false
                    }
                }
                runEnd += 1
            }

            if hasNonEmptyBlock && allNonEmptyQualify {
                result.qualifyingHeadingIDs.insert(block.id)
            }

            // Resume scanning right after this run -- the block at `runEnd` (if any) was never
            // part of it (that's exactly why the inner loop stopped there), so it gets its own
            // independent evaluation on the next outer-loop iteration.
            index = runEnd
        }
        return result
    }

    /// Assemble blocks into standard markdown for export (no Pandoc attributes).
    /// Uses `markdownForStandardExport()` which outputs plain markdown with captions as italic text.
    ///
    /// Unlike `assembleMarkdownForExport`, this path deliberately KEEPS every "# Notes"
    /// heading -- correct for a plain .md export, which has no Pandoc pass to lift footnote
    /// definitions elsewhere, so the heading is genuine document structure the user should see.
    /// It still runs continuation paragraphs through `indentedContinuation` (via the same
    /// `classifyNotesRuns` scan `assembleMarkdownForExport` uses) so a multi-paragraph footnote
    /// round-trips as valid Pandoc-flavored markdown here too, instead of its second paragraph
    /// spilling out as an unindented, un-owned top-level paragraph.
    static func assembleStandardMarkdownForExport(from blocks: [Block]) -> String {
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        let sorted = assemblySorted(blocks)
        let notesClassification = classifyNotesRuns(in: sorted)
        return sorted
            .map { block -> String in
                let fragment = block.markdownForStandardExport()
                guard notesClassification.continuationIDs.contains(block.id) else { return fragment }
                return indentedContinuation(fragment)
            }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")
    }

    /// Assemble blocks into plain markdown for the "Markdown Only" export -- text only, no
    /// images, no sidecar image folder needed to render correctly. Two steps:
    ///
    /// 1. Drop `.image`-typed blocks entirely, BEFORE assembly. A `.image` block's fragment
    ///    (`Block.markdownForStandardExport()`) glues the image reference and its caption
    ///    together as ONE fragment (`![alt](src)\n\n*caption*`), so stripping only the image
    ///    syntax out of the assembled text would leave an orphaned italic caption floating
    ///    with nothing above it to caption. Dropping the whole block removes both cleanly.
    /// 2. Strip any image markup that survived anyway -- an inline image embedded inside
    ///    prose/list/table/blockquote text that never got its own `.image`-typed block -- via
    ///    `MarkdownUtils.strippingImages` (fenced-code/inline-code-safe), applied to EACH
    ///    fragment individually, INSIDE this function's own `map`, before `isEmptyFragment`
    ///    filters the result -- deliberately not by calling `assembleStandardMarkdownForExport`
    ///    and post-processing its already-joined-and-filtered output.
    ///
    /// This ordering matters for two reasons, both regressions an earlier "assemble first,
    /// strip the whole document, then collapse blank-line craters" version of this function
    /// had:
    /// - Per-fragment stripping never touches the `\n\n` join between fragments, so it can
    ///   never reach INSIDE a fenced code block's fragment and delete blank lines the user
    ///   typed there on purpose -- unlike a `\n{3,}` regex pass over the whole assembled
    ///   string, which cannot tell "blank lines between fragments" from "blank lines inside a
    ///   code fence" and silently ate the latter too.
    /// - Stripping BEFORE `isEmptyFragment` runs (rather than after, when the filter has
    ///   already made its one pass over the pre-strip fragments) means a fragment that strips
    ///   down to whitespace-only -- not just exactly `""` -- is still caught, since
    ///   `isEmptyFragment` trims before comparing. A post-hoc `\n{3,}` collapse only catches
    ///   an exactly-empty fragment collapsing two `\n\n` joins into `\n\n\n\n`; it does nothing
    ///   for a fragment that stripped down to a single leftover space, which used to survive
    ///   as a visible, stray blank-looking line.
    static func assembleMarkdownOnlyForExport(from blocks: [Block]) -> String {
        let withoutImages = blocks.filter { $0.blockType != .image }
        return assemblySorted(withoutImages)
            .map { MarkdownUtils.strippingImages(from: $0.markdownForStandardExport()) }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")
    }

    /// Shared assembly ordering: by `sortOrder`, with headings ahead of non-headings
    /// at the same `sortOrder`. Every `assemble…` entry point MUST use this, or
    /// an export can disagree with the editor about block order.
    private static func assemblySorted(_ blocks: [Block]) -> [Block] {
        blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
    }

    // MARK: - ProseMirror Alignment

    /// Returns the node index (in ProseMirror alignment order) of the first bibliography
    /// block, or nil if no bibliography blocks exist.
    /// MUST stay in sync with idsForProseMirrorAlignment list-merging logic.
    static func firstBibliographyNodeIndex(_ blocks: [Block]) -> Int? {
        var nodeIndex = 0
        var prevListType: BlockType?

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

    /// Returns the node index (in ProseMirror alignment order) one PAST the last bibliography
    /// block, or nil if no bibliography blocks exist. Companion to `firstBibliographyNodeIndex`,
    /// used to bound the END of the bibliography section rather than just its start: now that a
    /// regenerated bibliography can be reinserted back at a mid-document anchor instead of
    /// always landing at the document's end (`BibliographySyncService.updateBibliographyBlock`),
    /// a cursor sitting in real trailing user content AFTER the section is a position the
    /// section's START index alone cannot distinguish from a position INSIDE the section.
    /// MUST stay in sync with idsForProseMirrorAlignment list-merging logic.
    static func lastBibliographyNodeIndex(_ blocks: [Block]) -> Int? {
        var nodeIndex = 0
        var prevListType: BlockType?
        var lastBibIndex: Int?

        for block in blocks {
            if isEmptyFragment(block.markdownFragment) { continue }

            let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)

            if isListBlock && block.blockType == prevListType {
                // Merged into previous list node — same index
                if block.isBibliography { lastBibIndex = nodeIndex - 1 }
                continue
            }

            if block.isBibliography { lastBibIndex = nodeIndex }
            nodeIndex += 1
            prevListType = isListBlock ? block.blockType : nil
        }
        return lastBibIndex.map { $0 + 1 }
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
        var prevListType: BlockType?
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
}
