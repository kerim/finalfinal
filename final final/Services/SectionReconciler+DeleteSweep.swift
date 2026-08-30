//
//  SectionReconciler+DeleteSweep.swift
//  final final
//
//  Header-matching dispatch and delete-sweep orchestration for SectionReconciler, split out
//  of SectionReconciler.swift to stay under swiftlint's type_body_length limit (same fix
//  applied to Database+BlocksReplace.swift for the same rule). `reconcile()` itself, plus the
//  shared three-tier matching/content-comparison helpers these call into (findMatch,
//  passesMatchGate, buildUpdates, isExemptFromDeleteSweep, duplicateSurvivor,
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
    /// one), in header order. Three-way dispatch mirrors `reconcile()`'s original inline
    /// `if header.isBibliography { ... continue } / if header.isNotes { ... continue } / else`
    /// structure exactly -- each header produces at most one change.
    func changesForHeaders(
        _ headers: [ParsedHeader],
        sortedDB: [Section],
        projectId: String,
        matchedDBIds: inout Set<String>
    ) -> [SectionChange] {
        var changes: [SectionChange] = []
        for (index, header) in headers.enumerated() {
            let change: SectionChange?
            if header.isBibliography {
                change = changeForBibliographyHeader(
                    header, index: index, projectId: projectId, sortedDB: sortedDB, matchedDBIds: &matchedDBIds
                )
            } else if header.isNotes {
                change = changeForNotesHeader(
                    header, index: index, projectId: projectId, sortedDB: sortedDB, matchedDBIds: &matchedDBIds
                )
            } else {
                change = changeForOrdinaryHeader(
                    header, index: index, projectId: projectId, sortedDB: sortedDB, matchedDBIds: &matchedDBIds
                )
            }
            if let change {
                changes.append(change)
            }
        }
        return changes
    }

    /// Dedicated match/insert/update logic for a header flagged `isBibliography`, extracted
    /// verbatim from `reconcile()`'s former inline branch. Returns `nil` on the steady-state
    /// no-change case (MUST-FIX 2: `buildUpdates` alone returns nil when title/level/content/
    /// position already match, which is exactly the case the self-heal exists to repair when
    /// only the flag itself needs flipping -- seeding with an empty `SectionUpdates()` keeps
    /// that flip from being silently dropped, but a change is only emitted when something
    /// actually differs). `matchedDBIds.insert(match.id)` happens unconditionally whenever a
    /// match is found, even on this no-change path -- dropping it would let a matched-but-
    /// unchanged row be swept as an orphan by the delete sweep below.
    private func changeForBibliographyHeader(
        _ header: ParsedHeader,
        index: Int,
        projectId: String,
        sortedDB: [Section],
        matchedDBIds: inout Set<String>
    ) -> SectionChange? {
        // Dedicated match path for the machine-managed bibliography heading -- see
        // findBibliographyMatch's doc comment for why this must NOT reuse findMatch
        // unmodified (MUST-FIX 1: no pure-proximity fallback).
        if let match = findBibliographyMatch(header, in: sortedDB, excluding: matchedDBIds) {
            matchedDBIds.insert(match.id)

            var updates = buildUpdates(header: header, existing: match, newPosition: index)
            if !match.isBibliography {
                if updates == nil { updates = SectionUpdates() }
                updates?.isBibliography = true
            }
            if let updates {
                return .update(id: match.id, updates: updates)
            }
            return nil
        } else {
            let newSection = Section(
                projectId: projectId,
                sortOrder: index,
                headerLevel: header.level,
                isPseudoSection: header.isPseudoSection,
                isBibliography: true,
                title: header.title,
                markdownContent: header.markdownContent,
                wordCount: header.wordCount,
                startOffset: header.startOffset
            )
            return .insert(newSection)
        }
    }

    /// Dedicated match/insert/update logic for a header flagged `isNotes`, extracted verbatim
    /// from `reconcile()`'s former inline branch. Mirrors `changeForBibliographyHeader` exactly
    /// -- see its doc comment for the steady-state no-change and `matchedDBIds.insert` details,
    /// both of which apply here identically.
    private func changeForNotesHeader(
        _ header: ParsedHeader,
        index: Int,
        projectId: String,
        sortedDB: [Section],
        matchedDBIds: inout Set<String>
    ) -> SectionChange? {
        // Dedicated match path for the machine-managed Notes heading -- mirrors
        // findBibliographyMatch exactly (see findNotesMatch's doc comment for why this
        // must not reuse findMatch unmodified).
        if let match = findNotesMatch(header, in: sortedDB, excluding: matchedDBIds) {
            matchedDBIds.insert(match.id)

            var updates = buildUpdates(header: header, existing: match, newPosition: index)
            if !match.isNotes {
                if updates == nil { updates = SectionUpdates() }
                updates?.isNotes = true
            }
            if let updates {
                return .update(id: match.id, updates: updates)
            }
            return nil
        } else {
            let newSection = Section(
                projectId: projectId,
                sortOrder: index,
                headerLevel: header.level,
                isPseudoSection: header.isPseudoSection,
                isNotes: true,
                title: header.title,
                markdownContent: header.markdownContent,
                wordCount: header.wordCount,
                startOffset: header.startOffset
            )
            return .insert(newSection)
        }
    }

    /// Dedicated match/insert/update logic for an ordinary (non-bibliography, non-Notes)
    /// header, extracted verbatim from `reconcile()`'s former inline `else` branch.
    /// `matchedDBIds.insert(match.id)` happens unconditionally whenever `findMatch` finds a
    /// match, even when `buildUpdates` returns nil (no field actually changed) -- dropping it
    /// on that no-change path would let a matched-but-unchanged row be swept as an orphan by
    /// the delete sweep below.
    private func changeForOrdinaryHeader(
        _ header: ParsedHeader,
        index: Int,
        projectId: String,
        sortedDB: [Section],
        matchedDBIds: inout Set<String>
    ) -> SectionChange? {
        if let match = findMatch(header, in: sortedDB, excluding: matchedDBIds) {
            matchedDBIds.insert(match.id)

            // Check if section needs updating
            let updates = buildUpdates(header: header, existing: match, newPosition: index)
            if updates != nil {
                return .update(id: match.id, updates: updates!)
            }
            return nil
        } else {
            // New section - create with new UUID
            let newSection = Section(
                projectId: projectId,
                sortOrder: index,
                headerLevel: header.level,
                isPseudoSection: header.isPseudoSection,
                title: header.title,
                markdownContent: header.markdownContent,
                wordCount: header.wordCount,
                startOffset: header.startOffset
            )
            return .insert(newSection)
        }
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
