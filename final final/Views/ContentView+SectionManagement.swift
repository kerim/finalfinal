//
//  ContentView+SectionManagement.swift
//  final final
//
//  Section management: scrolling, updating, reordering, and promotion logic.
//

import SwiftUI

extension ContentView {
    func scrollToSection(_ sectionId: String) {
        if editorState.editorMode == .wysiwyg {
            // Milkdown: use block-ID-based scrolling (character offsets are wrong
            // when atom nodes like figures are present — nodeSize=1 vs markdown length)
            editorState.scrollToBlockId = sectionId
        } else {
            // CodeMirror: character offsets map correctly to positions
            guard let db = documentManager.projectDatabase,
                  let pid = documentManager.projectId else { return }

            do {
                let allBlocks = try db.fetchBlocks(projectId: pid)
                let blocks: [Block]
                if let zoomedIds = editorState.zoomedSectionIds {
                    blocks = filterBlocksForZoom(allBlocks, zoomedIds: zoomedIds,
                                                 zoomedBlockRange: editorState.zoomedBlockRange)
                } else {
                    blocks = allBlocks
                }
                // MUST stay in sync with BlockParser.assembleMarkdown filtering
                let nonEmpty = blocks.sorted { $0.sortOrder < $1.sortOrder }
                    .filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
                var offset = 0
                for block in nonEmpty {
                    if block.id == sectionId {
                        break
                    }
                    // In CodeMirror sourceContent, heading blocks are prefixed with
                    // section anchors: <!-- @sid:UUID -->
                    // These add characters not counted in markdownFragment
                    if block.blockType == .heading {
                        // "<!-- @sid:" (10) + id + " -->" (4) = 14 + id.count
                        offset += 14 + block.id.count
                    }
                    offset += block.markdownFragment.count
                    offset += 2  // Account for "\n\n" separator in assembleMarkdown
                }
                editorState.scrollTo(offset: offset)
            } catch {
                DebugLog.log(.outline, "[ContentView] Error computing scroll offset: \(error)")
            }
        }
    }

    func updateSection(_ section: SectionViewModel) {
        // Barrier (see docs/architecture/unified-undo.md's Barriers section, hazard H8;
        // Decision 2 of the Phase 3 review round): section metadata (status/tags/wordGoal)
        // lives on the block row, not in the document text the unified-undo routing guard
        // compares -- a
        // metadata-only edit leaves that equality check satisfied, so without this a
        // structural undo would silently fire and wipe the edit along with reverting the
        // structural op. Invalidate the whole timeline rather than trying to special-case
        // "does this specific entry's snapshot predate this edit" -- the same fail-safe
        // posture every other H8 barrier in the plan's hazard catalog uses.
        //
        // EXCEPT when this call is an ECHO of a DB-driven section refresh rather than a
        // genuine user edit (review round MF-1, REWRITTEN in the round-4 pass per the judge's
        // finding): `mergeSections` mutates existing `SectionViewModel`s IN PLACE, so
        // `refreshSections()` at the end of every
        // performSectionRestoreReplace/performUndo/performRedo -- landing a restored/undone
        // snapshot's (routinely different) section status -- fires the SAME
        // `.onChange(of: section.status)` → `onSectionUpdated` path a real user edit would.
        // Without a guard, a structural op's own refresh would invalidate the very undo entry
        // it just recorded, degrading structural undo to a silent no-op.
        //
        // The ORIGINAL guard here was a flag (`EditorViewState.isRefreshingSections`, set
        // before the DB-driven merge and cleared a runloop turn later via
        // `DispatchQueue.main.async`) resting on an unverified assumption about exactly when
        // SwiftUI's `.onChange` fires relative to that queued clear -- a reviewer traced that
        // it could fail in EITHER direction (the flag still up when a genuine concurrent user
        // edit's `.onChange` fires, wrongly suppressing it; or already cleared before the
        // refresh's own `.onChange` fires, letting the original self-wipe bug back in), and
        // neither direction is verifiable by a unit test, since none of them construct a real
        // SwiftUI view hierarchy where `.onChange` timing could actually be observed.
        //
        // Replaced with a decidable check instead: compare the incoming section's
        // status/tags/wordGoal/goalType/aggregateGoal/aggregateGoalType against the block row
        // CURRENTLY persisted in the DB. They come out equal, field for field, exactly when
        // this call is an echo of a value the DB already holds (a DB-driven refresh handing
        // back what it just read); a genuine user edit is, by construction, changing at least
        // one of these fields, so the comparison is false and the barrier fires. No flag, no
        // runloop timing assumption, and it's directly unit-testable (unlike the flag it
        // replaces).
        guard let db = documentManager.projectDatabase else { return }
        let metadataUnchanged: Bool = {
            guard let existing = try? db.fetchBlock(id: section.id) else {
                // Can't determine whether this is an echo -- fail safe like every other H8
                // barrier and treat it as a real change.
                return false
            }
            return (existing.status ?? .writing) == section.status
                && (existing.tags ?? []) == section.tags
                && existing.wordGoal == section.wordGoal
                && existing.goalType == section.goalType
                && existing.aggregateGoal == section.aggregateGoal
                && existing.aggregateGoalType == section.aggregateGoalType
        }()
        if !metadataUnchanged {
            unifiedUndoService.invalidateAll(reason: "section metadata edited (status/tags/wordGoal)")
        }

        // Save all section metadata in a single atomic transaction to prevent
        // intermediate ValueObservation fires from resetting fields.
        let statusValue = section.status == .final_ ? "final" : section.status.rawValue
        let tagsString: String? = {
            let data = try? JSONEncoder().encode(section.tags)
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }()
        Task {
            do {
                try db.write { dbConn in
                    try dbConn.execute(
                        sql: """
                            UPDATE block SET
                                status = ?, wordGoal = ?, goalType = ?,
                                aggregateGoal = ?, aggregateGoalType = ?,
                                tags = ?, updatedAt = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            statusValue, section.wordGoal, section.goalType.rawValue,
                            section.aggregateGoal, section.aggregateGoalType.rawValue,
                            tagsString, Date(), section.id
                        ]
                    )
                }
            } catch {
                DebugLog.log(.outline, "[ContentView] Error saving section metadata: \(error.localizedDescription)")
            }
        }
    }

    func reorderSection(_ request: SectionReorderRequest) {
        sectionSyncService.cancelPendingSync()

        // The 3 validation guards (newParentId == sectionId; section not found;
        // targetSectionId == sectionId) live in SectionReorderPlanner.plan, which returns nil
        // for each -- matching every one of those early returns here doing nothing else (in
        // particular, NOT clearing editorState.sectionDropInFlight; see
        // dispatchSectionReorder's doc comment on that ownership transfer). A 4th early
        // return, planSingleSection's own internal re-find-after-promotion guard, lives inside
        // planSingleSection itself rather than in plan(), but returns nil the same way.
        guard let sections = SectionReorderPlanner.plan(
            request: request, in: editorState.sections, syncService: sectionSyncService
        ) else {
            return
        }

        // Dispatch into the audited structural-op sequence (Phase 7, plan §7) instead of
        // the old synchronous finalizeSectionReorder, which unconditionally invalidated the
        // whole unified-undo timeline. StructuralUndoController.performSectionReorder now
        // owns everything downstream: sort-order/offset recompute, hierarchy fixup, and the
        // single DB write, all inside the same audited sequence the other five op kinds use.
        dispatchSectionReorder(sections: sections, request: request)
    }

    /// Dispatch a completed drag-drop reorder into `StructuralUndoController`'s audited
    /// sequence (Phase 7, plan §7). Replaces the old synchronous `finalizeSectionReorder`,
    /// which recomputed sort orders/offsets, ran the in-memory hierarchy fixup, persisted via
    /// `db.reorderAllBlocks`, and unconditionally invalidated the whole unified-undo timeline
    /// -- all of that now lives inside `StructuralUndoController.performSectionReorder`,
    /// sharing the same checkpoint/snapshot machinery as restore/delete/duplicate, so a
    /// reorder is itself undoable rather than wiping whatever came before it (the gap this
    /// phase exists to close -- see plan §7's Phase 7 entry).
    ///
    /// The legacy `Section`-table persist (`persistReorderedBlocks_legacySections`, non-critical,
    /// unrelated to the Block table `db.reorderAllBlocks` writes) still runs as a trailing
    /// fire-and-forget task after the op completes, gated on success so it doesn't re-persist a
    /// refused/failed reorder's stale ordering.
    ///
    /// `request` is the raw drop request `sections` was computed from -- kept alongside the
    /// computed array only for MF-3's stash/retry below, not used for anything else here.
    ///
    /// Ownership of `editorState.sectionDropInFlight` transfers here from whichever drop
    /// delegate's `onDrop` closure called this (MF-2, plan §7) -- every return path below
    /// must eventually clear it (directly, or by handing it to a retried dispatch), or
    /// ContentView's `onDragEnded` stays permanently guarded off and the block-sync poll never
    /// re-arms.
    func dispatchSectionReorder(sections: [SectionViewModel], request: SectionReorderRequest) {
        // MF-4 (review round): a no-op reorder (dropped back where it started) must not mint a
        // snapshot or undo entry. Compared against `editorState.sections` LIVE, at call time --
        // id sequence + headerLevel is what actually determines document order/structure (see
        // `OutlineSidebar.structuralSignature(of:)`'s identical criterion for "did anything
        // structural change"). No machinery touched: nothing is dispatched, no Task spawned.
        if Self.sectionOrderUnchanged(sections, from: editorState.sections) {
            editorState.sectionDropInFlight = false
            editorState.contentState = .idle
            return
        }

        Task {
            defer {
                // MF-3 (review round): if a concurrent drop got refused while THIS reorder (or
                // an even earlier retry) was in flight, its request is stashed below. Retrying
                // it here -- inside this Task's own exit, after ownership of dropInFlight would
                // otherwise be released -- re-arms the flag instead of clearing it, since a
                // retry is still "reorder work in flight" from the same guard's point of view
                // (ContentView.swift's onDragEnded doc comment): there's no new AppKit drag
                // session backing this retry, but a later UNRELATED drag's own Path A could
                // still race it the same way MF-2 closed for the original drop otherwise.
                // `reorderSection` (not SectionReorderPlanner.planSingleSection/planSubtree
                // directly) re-runs
                // the self-drop/same-position guards too, not just the recompute -- the same
                // safety checks a genuine drop gets. The stash itself lives on `editorState`
                // (a class), not a `ContentView` `@State` property -- see
                // `EditorViewState.pendingSectionReorderRequest`'s doc comment for why.
                if let stashed = editorState.pendingSectionReorderRequest {
                    editorState.pendingSectionReorderRequest = nil
                    editorState.sectionDropInFlight = true
                    reorderSection(stashed)
                } else {
                    editorState.sectionDropInFlight = false
                }
            }

            let outcome = await structuralUndoController.performSectionReorder(sections: sections)
            switch outcome {
            case .performed:
                // performStructuralOp's own success path already returns contentState to
                // .idle as its last step -- nothing to do here.
                await persistReorderedBlocks_legacySections()
            case .refused:
                // MF-2 point 4 (review round): performStructuralOp's refusal paths (already
                // `isPerforming`, zoom refusal, precheck refusal) all refuse BEFORE the DB
                // write, without ever touching contentState -- previously this was
                // accidentally papered over by onDragEnded's un-gated .idle write, which
                // MF-2's fix above now correctly suppresses while a drop is still in flight.
                // Without this explicit reset nothing else would ever move contentState off
                // .dragReorder for a refused reorder.
                editorState.contentState = .idle

                // MF-3 (review round): stash the RAW request, not a retry of this now-stale
                // computed `sections` array -- the defer above re-derives a fresh target order
                // from editorState.sections as it stood at retry time, not from whatever was
                // true when this now-refused attempt was dispatched. Only safe because
                // `.refused` means nothing was written -- see the `.failedAfterCommit` case
                // below for why that outcome must NOT retry the same way.
                editorState.pendingSectionReorderRequest = request
            case .failedAfterCommit:
                // N2 (Phase B remediation plan): the DB reorder write already committed, but a
                // later step in the audited sequence failed -- the new order is NOT undoable
                // via the normal Cmd-Z timeline. Deliberately does NOT stash `request` for a
                // retry the way `.refused` does above: the document has ALREADY been
                // reordered, so replaying the same (now stale) target order on top of it would
                // misapply it a second time rather than safely retrying a no-op.
                DebugLog.log(.undo, "[ContentView] performSectionReorder: DB write committed but the op failed to finish recording -- not undoable via Cmd-Z; not retrying (the reorder already happened)")
                editorState.contentState = .idle
            }
        }
    }

    /// MF-4 (review round): pure comparison, no dependency on `self` -- directly unit-testable.
    /// `target`/`current` are considered structurally unchanged when they have the same
    /// sections, in the same order, at the same header levels -- the same id+headerLevel
    /// criterion `OutlineSidebar.structuralSignature(of:)` already uses to decide "did anything
    /// structural change" for that view's own update-skip optimization.
    static func sectionOrderUnchanged(_ target: [SectionViewModel], from current: [SectionViewModel]) -> Bool {
        guard target.count == current.count else { return false }
        return zip(target, current).allSatisfy { $0.id == $1.id && $0.headerLevel == $1.headerLevel }
    }

    /// Persist legacy section table after reorder (fire-and-forget, non-critical)
    func persistReorderedBlocks_legacySections() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            return
        }

        do {
            var sectionChanges: [SectionChange] = []
            for (index, viewModel) in editorState.sections.enumerated() {
                let updates = SectionUpdates(
                    title: viewModel.title,
                    headerLevel: viewModel.headerLevel,
                    sortOrder: index,
                    markdownContent: viewModel.markdownContent,
                    startOffset: viewModel.startOffset,
                    parentId: .some(viewModel.parentId)
                )
                sectionChanges.append(.update(id: viewModel.id, updates: updates))
            }
            try db.applySectionChanges(sectionChanges, for: pid)
        } catch {
            DebugLog.log(.outline, "[ContentView] Error persisting legacy sections: \(error)")
        }
    }

}
