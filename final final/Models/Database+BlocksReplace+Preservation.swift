//
//  Database+BlocksReplace+Preservation.swift
//  final final
//
//  Block replace helpers: heading/image metadata preservation. Extracted from
//  Database+BlocksReplace.swift, which owns the two main entry points (replaceBlocks,
//  replaceBlocksInRange). No-db-parameter helpers only — see
//  Database+BlocksReplace+RowOps.swift for the live-db row mutation helpers.
//

import Foundation
import GRDB

// MARK: - Replace Helpers (Preservation)

/// Mechanical extractions from `replaceBlocks` and `replaceBlocksInRange`
/// (`Database+BlocksReplace.swift`) — no behavior change from the originals. Split-internal
/// helpers of those two entry points, not general-purpose API: every method below is
/// `internal` rather than `private` ONLY because Swift has no cross-file `fileprivate`
/// equivalent that would let the entry-point file call them — the same scope this whole
/// extension used to enforce via a single `private extension ProjectDatabase` before the
/// file_length split. Do not call these from outside this replace-helpers trio of files.
extension ProjectDatabase {

    // MARK: Image metadata

    /// Build a src -> preserved-metadata lookup from existing image blocks (used for the
    /// imageWidth/imageCaption gap-fill during block replacement).
    func buildImageMetadataIndex(from existingBlocks: [Block]) -> [String: ImageMeta] {
        var imageMetaBySrc: [String: ImageMeta] = [:]
        for block in existingBlocks where block.blockType == .image {
            if let src = block.imageSrc, !src.isEmpty {
                imageMetaBySrc[src] = ImageMeta(
                    imageCaption: block.imageCaption,
                    imageWidth: block.imageWidth
                )
            }
        }
        return imageMetaBySrc
    }

    /// Extract a caption from a leading `<!-- caption: ... -->` comment line in a markdown
    /// fragment (legacy pre-`BlockParser.parseImageFragmentMeta` format). Anchored (`^`) so
    /// this can only match a comment immediately preceding the image, not one appearing
    /// anywhere else in the fragment. Returns nil if no such comment is present.
    func extractLegacyImageCaption(from fragment: String) -> String? {
        let frag = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captionRange = frag.range(
            of: #"^<!--\s*caption:\s*(.*?)\s*-->"#, options: .regularExpression
        ) else {
            return nil
        }
        let fullMatch = String(frag[captionRange])
        guard let textRange = fullMatch.range(
            of: #"(?<=caption:\s).*?(?=\s*-->)"#, options: .regularExpression
        ) else {
            return nil
        }
        return String(fullMatch[textRange])
    }

    /// Preserve image metadata by imageSrc match: legacy-caption gap-fill, then
    /// imageWidth/imageCaption gap-fill from the existing-blocks index (first-match-wins).
    /// Returns whether `block` was an image block with a usable src — i.e. whether the
    /// gap-fill logic actually ran — so a caller that only logs for real image blocks
    /// (`replaceBlocks`) knows when to log. `replaceBlocksInRange` has no such log and
    /// simply discards the result.
    @discardableResult
    func applyPreservedImageMetadata(to block: inout Block, index: inout [String: ImageMeta]) -> Bool {
        guard block.blockType == .image, let src = block.imageSrc, !src.isEmpty else { return false }

        // Legacy migration only: recover a caption from a leading
        // <!-- caption: ... --> comment line, same guard as the gap-fill block
        // below (only if the parser hasn't already set imageCaption — new-format
        // fragments set it, even to "", via BlockParser.parseImageFragmentMeta) and
        // anchored (`^`) so this can only match a comment immediately preceding the
        // image, not one appearing anywhere else in the fragment.
        if block.imageCaption == nil, let legacyCaption = extractLegacyImageCaption(from: block.markdownFragment) {
            block.imageCaption = legacyCaption
        }

        // Gap-fill only: don't overwrite parser-extracted values with stale DB cache
        if let meta = index[src] {
            if block.imageWidth == nil, let width = meta.imageWidth {
                block.imageWidth = width
            }
            if block.imageCaption == nil, let caption = meta.imageCaption {
                block.imageCaption = caption
            }
            index.removeValue(forKey: src)  // first-match-wins
        }

        return true
    }

    // MARK: Heading pop-queue

    /// Preserve heading ID and metadata by occurrence-indexed title match: pop the front of
    /// this title's queue and apply id + metadata from that SAME popped entry in one branch
    /// (not two separate lookups), so they can never come from two different existing
    /// occurrences of the same title. A unique title has a one-element queue, which behaves
    /// exactly like the old first-match-wins.
    /// - Parameter restoringBibliography: Whether a preserved `isBibliography` flag is OR'd
    ///   back onto `block` by this call. Defaults to `true`, matching every pre-existing call
    ///   site's behavior unchanged (`replaceBlocksInRange`, and `replaceBlocks`'
    ///   `preservingMachineManagedBlocks == true` path). `replaceBlocks`' default
    ///   (`preservingMachineManagedBlocks == false`) path passes
    ///   `!parseFoundBibliographyHeading && hasGenuineBibliographyRun(...)` instead — TWO
    ///   conditions, both required: the fresh parse recognised NO bibliography heading at all
    ///   anywhere in the document, AND this specific heading has a genuine, non-empty,
    ///   terminator-bounded run beneath it with no interior heading anywhere in that run (see
    ///   `hasGenuineBibliographyRun`'s doc comment — this second condition mirrors
    ///   `BibliographyOpeningSelector`'s own tier-2 rule in full, both its empty-run suppression
    ///   AND its interior-heading invalidation, so a document already in the KNOWN-LIMITATION
    ///   damaged state can't have its stale flag resurrected onto a heading with nothing real
    ///   beneath it, or with a real, unrelated heading sitting inside the same run). When
    ///   both hold, this is `true` and behaves exactly as before (needed for
    ///   `carryBibliographyFlagForward`'s detection-mismatch case). When the fresh parse DID
    ///   recognise a (correctly selected, per `BlockParser.parse`'s pre-scan) bibliography
    ///   heading, OR this heading's own run is empty, this is `false` for that heading —
    ///   otherwise an already-wrongly-flagged heading still sitting in the DB (e.g. a
    ///   bare-title user heading a stale parse once mistook for the real one) would have its
    ///   stale flag OR'd back in by this title match, making the false positive permanent
    ///   instead of letting the corrected fresh parse win.
    func applyPreservedHeading(
        to block: inout Block,
        queues: inout [String: [PreservedHeading]],
        restoringBibliography: Bool = true
    ) {
        if block.blockType == .heading,
           var queue = queues[block.textContent], !queue.isEmpty {
            let preserved = queue.removeFirst()
            queues[block.textContent] = queue
            block.id = preserved.id
            block.status = preserved.metadata.status
            block.tags = preserved.metadata.tags
            block.wordGoal = preserved.metadata.wordGoal
            block.goalType = preserved.metadata.goalType
            block.aggregateGoal = preserved.metadata.aggregateGoal
            block.aggregateGoalType = preserved.metadata.aggregateGoalType
            if restoringBibliography, preserved.metadata.isBibliography { block.isBibliography = true }
            if preserved.metadata.isNotes { block.isNotes = true }
        }
    }

    /// Restore `isBibliography` onto the entry rows beneath a heading that
    /// `applyPreservedHeading` just re-flagged from preserved metadata BECAUSE the fresh
    /// parse itself failed to recognise the heading (a detection mismatch) — never for a
    /// heading the parse recognised on its own. `mismatchedHeadingIndices` (built by the
    /// caller's prep loop, by comparing each heading's parser-derived `isBibliography` before
    /// `applyPreservedHeading` runs against its restored value after) is exactly that set: a
    /// healthy, parser-recognised heading's entries are already correctly flagged and need no
    /// help, and must never spend the `budget` below.
    ///
    /// WHY THIS EXISTS: `applyPreservedHeading` restores the flag onto the HEADING only.
    /// When `BlockParser.parse()` didn't recognise that heading (a custom header name since
    /// changed, a demoted heading level), every entry below it comes back unflagged. The next
    /// bibliography regeneration then deletes only the flagged heading and regenerates,
    /// leaving the old entries behind as duplicate body text in the document and in every
    /// export.
    ///
    /// TWO BOUNDS, WHICHEVER COMES FIRST — the terminator bound is ADDITIVE, it does NOT
    /// replace the next-heading rule:
    ///  - a heading stops the run, exactly as `BlockParser.sectionFlagCarriedForward` does;
    ///  - the first block after the arming heading carrying `endsBibliographyRun` stops it
    ///    too, inclusively, and can stop it EARLIER than a heading would.
    /// Reading the terminator as replacing the heading rule would let a run cross an
    /// intervening chapter heading and flag it — never do that.
    ///
    /// The terminator search MUST start strictly after the arming heading, and MUST take the
    /// FIRST match, not the last. A `lastIndex` search over the whole array lets a duplicate
    /// or stale terminator anywhere downstream extend the run over real user prose — flagged
    /// prose is dropped from every export and then deleted outright by the next regeneration.
    /// No terminator after the heading => carry NOTHING: an unbounded run is worse than an
    /// unrestored one.
    ///
    /// `assembleMarkdownForEditor` emits exactly ONE terminator per document — after the last
    /// flagged row anywhere, not one per section — so in a document with more than one
    /// bibliography-titled heading only the LAST such section is genuinely terminator-bounded.
    /// Before the bib-heading-false-positive follow-up fix to `hasGenuineBibliographyRun` (see
    /// that function's doc comment), an earlier mismatched section's forward search would find
    /// that later terminator (past its own section) and this function would fall back to
    /// bounding the carry at the next heading instead — safe, but strictly less precise than the
    /// single-section case. `hasGenuineBibliographyRun` now scans its own full candidate range
    /// for an interior heading too, so it refuses to arm a heading whose apparent run spans a
    /// LATER heading in the first place: `mismatchedHeadingIndices` never includes that earlier
    /// heading, and this function is simply never entered for it. Only the true last section —
    /// the one whose own scanned range contains no interior heading — is ever armed here in
    /// practice. This function's own next-heading/budget bounds remain necessary regardless, as
    /// defense in depth against any future caller that arms `mismatchedHeadingIndices` directly.
    ///
    /// `budget` is the second, independent bound: never flag more non-heading blocks in one
    /// call than the project currently HAS non-heading `isBibliography` rows. A pure count —
    /// no content matching against existing rows, deliberately. This caps the blast radius
    /// even if the predicate above is later changed and gets it wrong.
    ///
    /// KNOWN LIMITATION, by design: on a document ALREADY in the damaged state (heading
    /// flagged, entries not), the assembler places the terminator directly after the heading,
    /// so this arms and disarms in the same step and restores nothing. This prevents
    /// recurrence on a healthy document; it does not heal an already-broken one.
    func carryBibliographyFlagForward(
        _ blocks: inout [Block],
        mismatchedHeadingIndices: Set<Int>,
        budget: Int
    ) {
        guard budget > 0 else { return }
        var remaining = budget
        var index = blocks.startIndex
        while index < blocks.endIndex {
            guard blocks[index].blockType == .heading, blocks[index].isBibliography,
                  mismatchedHeadingIndices.contains(index) else {
                index += 1
                continue
            }
            guard let end = bibliographyRunEnd(in: blocks, after: index) else {
                index += 1
                continue
            }
            var cursor = blocks.index(after: index)
            while cursor <= end {
                if blocks[cursor].blockType == .heading { break }
                if remaining == 0 { break }
                blocks[cursor].isBibliography = true
                remaining -= 1
                cursor = blocks.index(after: cursor)
            }
            index = cursor
        }
    }

    /// Returns the index of the first block after `headingIndex` carrying `endsBibliographyRun`
    /// — the transient marker `BlockParser.parse()` sets on the block immediately preceding a
    /// `BlockParser.bibliographyEndMarker` line — or `nil` if no such block exists (no
    /// terminator anywhere after this heading). Shared by `carryBibliographyFlagForward`
    /// (which carries the flag FORWARD onto entries beneath a restored heading) and
    /// `replaceBlocks`' restore gate, via `hasGenuineBibliographyRun` below (which decides
    /// WHETHER to restore the heading's flag at all), so the two questions — "where does this
    /// run end" and "should I restore this heading" — can never disagree about where the run
    /// ends.
    func bibliographyRunEnd(in blocks: [Block], after headingIndex: Int) -> Int? {
        guard headingIndex < blocks.index(before: blocks.endIndex) else { return nil }
        return blocks[blocks.index(after: headingIndex)...].firstIndex(where: { $0.endsBibliographyRun })
    }

    /// Whether the heading at `headingIndex` has a genuine, non-empty, terminator-bounded run
    /// beneath it in `blocks`: a terminator exists after it (`bibliographyRunEnd` is non-nil)
    /// AND no block anywhere in `(headingIndex, end]` — not just the block immediately after
    /// the heading — is itself a heading. Mirrors `carryBibliographyFlagForward`'s own loop
    /// exactly — that loop starts flagging at `index + 1` and `break`s the moment it hits a
    /// heading, wherever in the range that heading falls — so "genuine" here means precisely
    /// "carry-forward would flag at least one block", and mirrors `BibliographyOpeningSelector`'s
    /// own tier-2 interior-heading rule (the SAME rule — ANY heading strictly between the
    /// candidate and where the run ends invalidates it — applied to the `[Block]` shape here,
    /// rather than to raw text there) so the restore gate and a fresh parse's own selection can
    /// never disagree about whether a shape counts as evidence: a heading two blocks down the
    /// run is just as disqualifying as a heading immediately after it. Deliberately NOT folded
    /// into `BibliographyOpeningSelector` itself: different question (where does a run end,
    /// given `[Block]` with no text form) over an incompatible data shape (no terminator-carrying
    /// line/block exists here — only a transient flag on the preceding content block).
    func hasGenuineBibliographyRun(in blocks: [Block], after headingIndex: Int) -> Bool {
        guard let end = bibliographyRunEnd(in: blocks, after: headingIndex) else { return false }
        let cursor = blocks.index(after: headingIndex)
        guard cursor <= end else { return false }
        // Scan the WHOLE run (cursor...end), not just the immediately-next block: a heading
        // ANYWHERE in that range — not only as the very first block — ends the candidate's
        // section, exactly as BibliographyOpeningSelector's tier 2 now requires (see that file's
        // doc comment). Checking only blocks[cursor] let a heading later in the same range (e.g.
        // an unrelated real "# Notes" heading two blocks down) go undetected, which could
        // resurrect a stale isBibliography flag onto a heading whose run this selector-level rule
        // would refuse to select on a fresh parse.
        return !blocks[cursor...end].contains { $0.blockType == .heading }
    }

    /// Build the pop-queue of existing headings by title (consumed occurrence-by-occurrence
    /// as `newBlocks` is walked in `replaceBlocksInRange`) plus the set of existing heading
    /// ids that must never be deleted or popped.
    ///
    /// Count how many NEW headings share each title — this is how many old occurrences of
    /// that title the pop queue below will actually reach (the 1st new heading titled T
    /// claims the 1st old occurrence titled T, the 2nd new claims the 2nd old, ...). Used to
    /// decide, per OLD occurrence, whether its own slot will ever be popped.
    ///
    /// Group existing headings by title, in existing-range order (preserves zoomedSectionId
    /// across re-parses), then split each title's occurrences into `protectedIds` (never
    /// deleted, never eligible to be popped) vs. `queues` (the pop queue consumed by
    /// `applyPreservedHeading`). A duplicate title gets a queue of length > 1; consuming the
    /// new parse in order pops the front of the matching title's queue, so the nth heading
    /// titled T in the new parse inherits id+metadata from the nth QUEUED heading titled T in
    /// the old rows — occurrence-index matching, not absolute position (position would churn
    /// every downstream id when a paragraph is inserted above a heading).
    ///
    /// Real invariant this provides: a machine-managed (isNotes/isBibliography) old heading
    /// is protected specifically when ITS OWN occurrence slot — its position among old
    /// headings sharing its title — falls at or beyond the new-heading count for that title,
    /// i.e. no new heading will ever reach it to pop it. A title wholly absent from newBlocks
    /// has zero consumable slots, so every occurrence of it is protected — the common case,
    /// unchanged from before. The fix only changes behavior on a COUNT MISMATCH: e.g. a plain
    /// user heading that collides in title with the machine "Notes" heading used to strip
    /// protection from every "Notes"-titled occurrence (title-only check), including the
    /// machine one, even when the machine heading's own queue slot was never going to be
    /// reached by the single colliding new heading — silently deleting the machine section
    /// with nothing to bring it back. Because protected occurrences are excluded from the
    /// queue entirely, they are never candidates to be popped in the first place; a
    /// still-protected heading's queue slot can never be popped, but that was never the
    /// actual bug — the bug was protection LAPSING (a title leaving the protected set)
    /// despite the specific machine occurrence's slot remaining unreachable. See
    /// `ZoomDataIntegrityTests`'s title-collision-with-protected-heading tests for the exact
    /// scenario this guards.
    /// - Parameter protectingNotes: Whether an isNotes heading occurrence beyond the
    ///   consumable count is ALSO protected, alongside isBibliography (always protected
    ///   regardless of this flag). Defaults to `true`. Both of `replaceBlocksInRange`'s call
    ///   site and `replaceBlocks`' bibliography+Notes preservation path pass `true` -- Notes
    ///   gets the same protection bibliography does, for the same reason (see `replaceBlocks`'
    ///   doc comment): its incoming `blocks` is guaranteed Notes-free at those call sites, so
    ///   there is nothing there for a preserved row to collide with.
    func buildHeadingQueues(
        existing: [Block],
        newBlocks: [Block],
        protectingNotes: Bool = true
    ) -> (queues: [String: [PreservedHeading]], protectedIds: Set<String>) {
        var newHeadingCountByTitle: [String: Int] = [:]
        for block in newBlocks where block.blockType == .heading {
            newHeadingCountByTitle[block.textContent, default: 0] += 1
        }

        var existingHeadingsByTitle: [String: [Block]] = [:]
        for block in existing where block.blockType == .heading {
            existingHeadingsByTitle[block.textContent, default: []].append(block)
        }
        var protectedHeadingIds: Set<String> = []
        var headingsByTitle: [String: [PreservedHeading]] = [:]
        for (title, occurrences) in existingHeadingsByTitle {
            let consumable = newHeadingCountByTitle[title, default: 0]
            for (index, block) in occurrences.enumerated() {
                if ((protectingNotes && block.isNotes) || block.isBibliography) && index >= consumable {
                    protectedHeadingIds.insert(block.id)
                    continue
                }
                headingsByTitle[title, default: []].append(PreservedHeading(from: block))
            }
        }
        return (headingsByTitle, protectedHeadingIds)
    }

    /// Build a footnote-label -> existing-row lookup from existing isNotes blocks, used to
    /// merge a same-label incoming Notes row into its existing DB row instead of inserting a
    /// duplicate (see `handleMachineManagedBlock`).
    func buildNotesRowIndex(from existing: [Block]) -> [String: Block] {
        var notesRowByLabel: [String: Block] = [:]
        for block in existing where block.isNotes {
            if let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
                notesRowByLabel[label] = block
            }
        }
        return notesRowByLabel
    }

}
