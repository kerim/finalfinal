//
//  SectionReconciler+DeleteSweep.swift
//  final final
//
//  Header-matching dispatch and delete-sweep orchestration for SectionReconciler, split out
//  of SectionReconciler.swift to stay under swiftlint's type_body_length limit (same fix
//  applied to Database+BlocksReplace.swift for the same rule). `reconcile()` itself, plus the
//  shared matching/content-comparison helpers these call into (findExactPositionMatch,
//  findTitleMatch, findRelatedProximityMatch, findFallbackProximityMatch, passesMatchGate,
//  buildUpdates, isExemptFromDeleteSweep, duplicateSurvivor,
//  mergeSurvivorUpdates, etc.), stay in SectionReconciler.swift; several of those helpers were
//  bumped from `private` to internal (module-default) access so this file's extension can call
//  them -- Swift's `private` doesn't cross files, only `internal` and above do.
//

import Foundation

extension SectionReconciler {

    // MARK: - Private Header-Matching Loop

    /// Whether the bibliography/Notes flags have verifiably survived this pass, per type --
    /// consumed by the delete sweep below to decide whether a stale flagged row may finally be
    /// swept. Extracted verbatim from `reconcile()`; see `deleteSweepChanges` for how these
    /// two booleans are used.
    struct FlagSurvival {
        let bibliographyGone: Bool
        let notesGone: Bool
    }

    func flagSurvival(
        headers: [ParsedHeader],
        bibliographyExistsInBlocks: Bool,
        notesExistsInBlocks: Bool
    ) -> FlagSurvival {
        // Two-signal AND: the bibliography counts as "gone" only when NEITHER signal claims
        // it survives -- not `bibliographyExistsInBlocks` (the block-level check, covering
        // orphaned entry/terminator blocks a heading-only query would miss) AND no parsed
        // header in THIS pass is itself flagged `isBibliography` (a header can still be
        // flagged even when the caller's own block-level check alone would say "gone" --
        // e.g. a stale/racy read -- so both signals must agree before an immortal-row
        // exemption is lifted). See the delete-sweep loop below for where this is consumed:
        // deletes a currently-exempt flagged row rather than un-flagging it, since an
        // un-flagged row re-entering the title-matching pool would recreate MUST-FIX 1's
        // exact role-swap risk with bibliography-shaped content.
        let bibliographyGone = !bibliographyExistsInBlocks && !headers.contains { $0.isBibliography }

        // Same two-signal AND as bibliographyGone above, mirrored exactly for Notes: gone only
        // when neither signal claims it survives -- not `notesExistsInBlocks` (the block-level
        // check) AND no parsed header in THIS pass is itself flagged `isNotes`. Without this,
        // the first Notes Section row ever created becomes permanent: the delete-sweep loop
        // below unconditionally excluded `!section.isNotes` before this fix, so a Notes row
        // could never be swept even after every footnote was removed from the document.
        let notesGone = !notesExistsInBlocks && !headers.contains { $0.isNotes }

        return FlagSurvival(bibliographyGone: bibliographyGone, notesGone: notesGone)
    }

    /// Matches every parsed header to a database section (or queues an insert for a brand-new
    /// one) through five ordered, tier-major passes, then emits the resulting changes in
    /// **header order**. A header advances from pass to pass only on failure, so it matches at
    /// most once; a match is recorded in `matchedRow` (and `matchedDBIds`) the moment it is
    /// found, never during emission.
    ///
    /// PASS ORDER — load-bearing, chosen so a later header's stronger evidence can never be
    /// pre-empted by an earlier header's weaker evidence:
    ///
    ///     ordinary Pass 1 — exact position + identity gate
    ///     ordinary Pass 2 — title + level anywhere
    ///     flagged block — (a) any already-flagged unmatched row, (b) exact-position + gate,
    ///                      (c) ±3 + gate; atomic per header, internal order preserved,
    ///                      headers in index order
    ///     ordinary Pass 3a — proximity ∩ content-relatedness
    ///     ordinary Pass 3b — pure-proximity fallback
    ///     emission — header index order
    ///
    /// The flagged-header block's step (a) stays unconditionally first and still suppresses (b)/(c);
    /// its placement relative to the ordinary passes is unobservable, because `availableRows`
    /// excludes flagged rows, so no ordinary pass can contend for one. Only the flagged
    /// headers' (b)/(c) move relative to the old header-major loop: they now run after every
    /// ordinary header's Pass 2 title+level match.
    func changesForHeaders(
        _ headers: [ParsedHeader],
        sortedDB: [Section],
        projectId: String,
        matchedDBIds: inout Set<String>
    ) -> [SectionChange] {
        var slots = [SectionChange?](repeating: nil, count: headers.count)
        var matchedRow = [Section?](repeating: nil, count: headers.count)
        var ordinary: [(index: Int, header: ParsedHeader)] = []
        var flagged: [(index: Int, header: ParsedHeader)] = []
        for (index, header) in headers.enumerated() {
            if header.isBibliography || header.isNotes {
                flagged.append((index, header))
            } else {
                ordinary.append((index, header))
            }
        }

        // Pass 1 — ordinary exact position + identity gate.
        //
        // Pass 1/Pass 2 precedence, and the sweep consequence of it. This site is
        // load-bearing for a destructive outcome, not just for which card is relabeled:
        // because a later header's stronger match can now claim a row an EARLIER header
        // would have taken, the earlier header can be left with no candidate at all and
        // reach emission as an insert — and the row the old header-major order matched for
        // it is then unmatched, so `deleteSweepChanges` hard-deletes it. That is a real,
        // accepted behavior change (a row the old order kept by a weaker claim can now
        // lose its `status`/`tags`/`wordGoal` and have its annotations detached), and a
        // reconciler-driven delete is NOT on the unified undo timeline: undoing the text
        // edit brings the heading back, but as a NEW row with default metadata. Pinned by
        // the two spillover-row precedence tests.
        let after1 = ordinary.filter { item in
            if let match = findExactPositionMatch(item.header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)
                matchedRow[item.index] = Optional(match)
                return false
            }
            return true
        }

        // Pass 2 — ordinary title + level anywhere.
        let after2 = after1.filter { item in
            if let match = findTitleMatch(item.header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)
                matchedRow[item.index] = Optional(match)
                return false
            }
            return true
        }

        // Flagged block — atomic per flagged header, in index order. Step (a) inside
        // findBibliographyMatch/findNotesMatch is unconditionally first and suppresses
        // (b)/(c) exactly as before.
        for item in flagged {
            let match = item.header.isBibliography
                ? findBibliographyMatch(item.header, in: sortedDB, excluding: matchedDBIds)
                : findNotesMatch(item.header, in: sortedDB, excluding: matchedDBIds)
            if let match {
                matchedDBIds.insert(match.id)
                matchedRow[item.index] = Optional(match)
            }
        }

        // Pass 3a — ordinary proximity ∩ content-relatedness.
        let after3a = after2.filter { item in
            if let match = findRelatedProximityMatch(item.header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)
                matchedRow[item.index] = Optional(match)
                return false
            }
            return true
        }

        // Pass 3b — ordinary pure-proximity fallback, for whatever 3a left unmatched.
        _ = after3a.filter { item in
            if let match = findFallbackProximityMatch(item.header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)
                matchedRow[item.index] = Optional(match)
                return false
            }
            return true
        }

        // Emission — header order. A non-nil `matchedRow[index]` routes through `updateChange`,
        // whose nil return (matched but nothing actually changed) leaves the slot nil so
        // NOTHING is emitted for it; it must never fall through to `insertChange`, which would
        // queue a duplicate insert for every already-correct row.
        for (index, header) in headers.enumerated() {
            if let match = matchedRow[index] {
                slots[index] = updateChange(header: header, match: match, index: index)
            } else {
                slots[index] = insertChange(header: header, index: index, projectId: projectId)
            }
        }
        return slots.compactMap { $0 }
    }

    /// Builds the `.update` change for a header whose row one of the five match sites claimed,
    /// or `nil` when nothing about that row actually differs. A `nil` return means "matched,
    /// but already correct" — the caller emits nothing for it, which is what keeps a
    /// steady-state reconcile a no-op.
    ///
    /// `matchedDBIds.insert(match.id)` is the caller's job at each match site, never here: a
    /// matched-but-unchanged row must still count as matched, or the delete sweep below would
    /// treat it as an orphan. The bibliography/Notes flag flip mirrors the old dedicated
    /// branches — `buildUpdates` alone returns nil when title/level/content/position already
    /// match, which is exactly the case the self-heal exists to repair when only the flag
    /// itself needs flipping, so seeding with an empty `SectionUpdates()` keeps that flip from
    /// being silently dropped.
    private func updateChange(
        header: ParsedHeader,
        match: Section,
        index: Int
    ) -> SectionChange? {
        var updates = buildUpdates(header: header, existing: match, newPosition: index)
        if header.isBibliography && !match.isBibliography {
            if updates == nil { updates = SectionUpdates() }
            updates?.isBibliography = true
        }
        if header.isNotes && !match.isNotes {
            if updates == nil { updates = SectionUpdates() }
            updates?.isNotes = true
        }
        guard let updates else { return nil }
        return .update(id: match.id, updates: updates)
    }

    /// Builds the `.insert` change for a header no pass could match — a brand-new section at
    /// the header's own index, carrying whichever flagged role the header itself has.
    private func insertChange(
        header: ParsedHeader,
        index: Int,
        projectId: String
    ) -> SectionChange {
        let newSection = Section(
            projectId: projectId,
            sortOrder: index,
            headerLevel: header.level,
            isPseudoSection: header.isPseudoSection,
            isBibliography: header.isBibliography,
            isNotes: header.isNotes,
            title: header.title,
            markdownContent: header.markdownContent,
            wordCount: header.wordCount,
            startOffset: header.startOffset
        )
        return .insert(newSection)
    }

    // MARK: - Private Delete-Sweep Logic

    /// Bibliography/Notes survival + matched-row evidence `deleteSweepChanges` needs, grouped
    /// into one parameter instead of four separate ones (`bibliographyGone`, `notesGone`,
    /// `matchedBibliographyRows`, `matchedNotesRows`). Fixes a `function_parameter_count`
    /// violation: `deleteSweepChanges` originally took 8 parameters, 2 of which
    /// (`bibliographyRowMatched`/`notesRowMatched`) were dropped as redundant --
    /// `bibliographyRowMatched == !matchedBibliographyRows.isEmpty` always, so
    /// `deleteSweepChanges` now derives them itself instead of trusting a caller to keep an
    /// inconsistent pair from ever being passed in. That alone only got the count to 6; this
    /// struct groups the remaining bibliography/Notes-specific values down to 1, for a final
    /// count of 3 (`sortedDB`, `matchedDBIds`, `flaggedRows`).
    struct DeleteSweepFlagState {
        let bibliographyGone: Bool
        let notesGone: Bool
        let matchedBibliographyRows: [Section]
        let matchedNotesRows: [Section]
    }

    /// Unmatched DB sections were deleted from markdown, EXCEPT bibliography/notes
    /// sections which are managed separately by their sync services (see
    /// isExemptFromDeleteSweep) -- UNLESS a stale flagged row must be swept because
    /// either (a) the flag is verifiably gone via BOTH signals (bibliographyGone/
    /// notesGone), an ordinary `.delete` exactly like any other unmatched row since
    /// there's no winning sibling this pass to migrate onto, or (b) it's a genuine
    /// DUPLICATE that lost this pass's match to a sibling row (duplicateSurvivor below
    /// finds that sibling), swept via `.deleteDuplicate` instead -- which migrates the
    /// loser's real status/tags/wordGoal onto the survivor and reassigns its
    /// annotations rather than silently discarding them along with the row (see
    /// `SectionChange.deleteDuplicate`'s doc comment). Extracted verbatim from
    /// `reconcile()`'s former inline loop.
    ///
    /// `bibliographyRowMatched`/`notesRowMatched` are derived here, once, from
    /// `flaggedRows.matchedBibliographyRows`/`matchedNotesRows` rather than being accepted as
    /// separate parameters -- see `DeleteSweepFlagState`'s doc comment for why.
    func deleteSweepChanges(
        sortedDB: [Section],
        matchedDBIds: Set<String>,
        flaggedRows: DeleteSweepFlagState
    ) -> [SectionChange] {
        let bibliographyRowMatched = !flaggedRows.matchedBibliographyRows.isEmpty
        let notesRowMatched = !flaggedRows.matchedNotesRows.isEmpty

        var changes: [SectionChange] = []
        // Unmatched-row delete path. The tier-major pass order changes WHICH rows reach this
        // branch: a row the old header-major order kept alive via a weaker (often
        // pure-proximity) claim can now be claimed by a different header instead, leaving it
        // unmatched here and hard-deleted — with no migration, since the `.deleteDuplicate`
        // sibling branch below requires a flagged survivor. What that costs is exactly what
        // this branch destroys: `status`, `tags`, `wordGoal`, and the row's id (its
        // annotations survive as rows but their `sectionId` is nulled by the FK). Unlike a
        // text edit, this is NOT recoverable from the unified undo timeline: undoing the
        // edit that removed the heading re-inserts a row at defaults with a new id, and the
        // detached annotations are not reattached. Deliberate (a row with no matching heading
        // is what the sweep is for), decided in orphan-delete-decision.md, and pinned by the
        // spillover-row precedence tests.
        for section in sortedDB where !matchedDBIds.contains(section.id) {
            if isExemptFromDeleteSweep(
                section,
                bibliographyGone: flaggedRows.bibliographyGone,
                notesGone: flaggedRows.notesGone,
                bibliographyRowMatched: bibliographyRowMatched,
                notesRowMatched: notesRowMatched
            ) { continue }

            if let survivor = duplicateSurvivor(
                for: section,
                matchedBibliographyRows: flaggedRows.matchedBibliographyRows,
                matchedNotesRows: flaggedRows.matchedNotesRows
            ) {
                changes.append(.deleteDuplicate(
                    loserId: section.id,
                    survivorId: survivor.id,
                    survivorUpdates: mergeSurvivorUpdates(loser: section, survivor: survivor)
                ))
                // Distinguishes a duplicate-sweep delete from an ordinary one below, so a
                // future "my section's tags/status/word-goal vanished" report is
                // diagnosable from the persistent DiagnosticLogFile sink alone -- title
                // itself stays excluded for the same reason as the ordinary case.
                DebugLog.log(.sync, "[SectionReconciler] Deleted duplicate id=\(section.id.prefix(8)) " +
                    "order=\(section.sortOrder) survivor=\(survivor.id.prefix(8)) status=\(section.status)")
            } else {
                changes.append(.delete(id: section.id))
                // Deliberately excludes title: it's a literal excerpt of the user's
                // manuscript, and this line reaches the persistent DiagnosticLogFile
                // sink (Release builds included) whenever the user's Diagnostics
                // toggle is on. id+sortOrder+pseudo+status is enough to correlate
                // against a read-only DB inspection (see CLAUDE.md) if a mis-steal
                // needs investigating; it can't distinguish that from an ordinary
                // user-initiated deletion on its own, but this is a correlation key,
                // not a verdict.
                DebugLog.log(.sync, "[SectionReconciler] Deleted id=\(section.id.prefix(8)) " +
                    "order=\(section.sortOrder) pseudo=\(section.isPseudoSection) status=\(section.status)")
            }
        }
        return changes
    }
}
