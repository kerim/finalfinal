//
//  LifecycleWholeDocumentWrite.swift
//  final final
//
//  t-94369a83 Phase 3a-1a ("FB"), plan v3 §2.3: the queued WHOLE-DOCUMENT save a close,
//  project switch or quit will take through the ordered write queue, as a
//  `SystemWriteKind.lifecycleWholeDocument` system write.
//
//  Phase 3a-1b calls it as step 6 of the lifecycle save sequence (`EditorViewState.runLifecycleFlush`).
//  The out-of-queue `EditorViewState.flushContentToDatabase` is no longer used by close, quit or
//  project switch; it still serves mode switching, zooming and the Markdown re-parse.
//
//  Shape (plan item 17, "parse before reserve"):
//    - `LifecycleWholeDocumentPrepared`: everything the write needs, already PARSED -- a
//      plain `Sendable` value. The reservation function takes this value, so it CANNOT parse.
//    - `LifecycleWholeDocumentWrite.prepare`: the MainActor step. Strips the zoom-notes
//      marker, reads the Notes heading title and runs `BlockParser.parse`, all BEFORE any
//      sequence is reserved, so a slow parse can never sit inside the writer's queue.
//    - `LifecycleWholeDocumentWrite.body`: the pure `@Sendable (Database) throws` write body,
//      calling only the db-level statics extracted from `replaceBlocks*` (C2).
//    - `BlockSyncService.performLifecycleWholeDocumentWrite`: reserve, wait, apply, through
//      `performSystemWrite(kind: .lifecycleWholeDocument, ...)`.
//
//  The epoch (slice-3a-1a.md (D)): the replace statics bump the project's block-write epoch
//  and restamp every row to (E+1, 0) INSIDE the caller's transaction (`stampWholeProjectForRewrite`),
//  so FB adds no stamp or bump of its own. An editor batch reserved before FB commits carries
//  epoch E and is refused whole by rule 1 of `applyBlockChangesFromEditor` if it applies AFTER
//  FB's commit (a lower-numbered batch that applies in turn before FB is not refused). See the
//  exception note on `applySystemWrite` (DocumentWriter.swift), which also says when that
//  refusal loses edits.
//

import Foundation
import GRDB

/// A whole-document write, fully prepared on the MainActor before any sequence is reserved.
struct LifecycleWholeDocumentPrepared: Sendable {
    /// The parsed incoming blocks (Notes title already threaded through the parse).
    let blocks: [Block]
    let projectId: String
    /// The zoom block range, when the editor was zoomed; nil for a whole-document replace.
    let range: (start: Double, end: Double?)?
    /// The zoom ROOT heading id (`replaceBlocksInRange`'s `anchorHeadingId`); nil when not
    /// zoomed. `anchorHeadingId != nil && range == nil` is the "zoom in flight, no block
    /// range yet" shape the primitive REFUSES (judge adjustment B1): building a
    /// whole-document body from it would delete every other section, which is exactly what
    /// `flushContentToDatabase` refuses today (EditorViewState+Zoom.swift:801).
    let anchorHeadingId: String?
    /// The mini-Notes text stripped from zoomed content (`SectionSyncService.stripZoomNotes`).
    /// Non-nil only for a zoomed write (`range != nil`) that carried a non-empty zoom-notes
    /// section, mirroring `flushContentToDatabase`, which only syncs mini-Notes then. Written by
    /// `LifecycleWholeDocumentWrite.body`, in the SAME transaction as the range replace.
    let miniNotes: String?
    /// `miniNotes` parsed into footnote definitions (`label -> text`), done here on the MainActor
    /// before any sequence is reserved (coder obligation 17, "parse before reserve"), so the write
    /// transaction does no parsing. Empty when `miniNotes` is nil or empty, which makes `body` skip
    /// the mini-Notes write exactly as `flushContentToDatabase` skips an empty mini-Notes text (N17).
    let miniNoteDefinitions: [String: String]

    init(
        blocks: [Block],
        projectId: String,
        range: (start: Double, end: Double?)?,
        anchorHeadingId: String?,
        miniNotes: String?
    ) {
        self.blocks = blocks
        self.projectId = projectId
        self.range = range
        self.anchorHeadingId = anchorHeadingId
        self.miniNotes = miniNotes
        self.miniNoteDefinitions = miniNotes.map { FootnoteSyncService.extractFootnoteDefinitions(from: $0) } ?? [:]
    }
}

/// Why `LifecycleWholeDocumentWrite.body` refused to build a write. Defence in depth only:
/// `BlockSyncService.performLifecycleWholeDocumentWrite` already declines this shape before
/// reserving anything, so a body that nonetheless sees it throws, rolling the transaction back
/// (`.failed`) instead of ever running a whole-document replace from it.
enum LifecycleWholeDocumentWriteError: Error, Equatable {
    /// `anchorHeadingId != nil` with no `range` (see `LifecycleWholeDocumentPrepared.anchorHeadingId`).
    case zoomedSectionWithoutRange
}

/// Namespace for the FB primitive's two pure steps.
enum LifecycleWholeDocumentWrite {
    /// The MainActor preparation step: everything that parses or reads, done BEFORE any
    /// reservation (plan item 17). Mirrors `flushContentToDatabase`'s parse inputs exactly
    /// (EditorViewState+Zoom.swift:796-933): the `<!-- ::zoom-notes:: -->` marker and
    /// everything after it is stripped first, the Notes heading title is read from the database
    /// (`try?`, so a read error means "no title", as there), and the stripped markdown is parsed
    /// with `existingSectionMetadata: nil` -- heading ids and metadata are preserved by the
    /// replace itself, inside its transaction.
    ///
    /// Returns nil for empty `content`, mirroring `flushContentToDatabase`'s
    /// `guard !contentToFlush.isEmpty`: an empty fetch means "nothing to save", not "the
    /// document is now empty" (a nil here is not a loss and is not counted as one).
    ///
    /// Never refuses a zoomed-without-range shape itself: it faithfully carries
    /// `zoomedSectionId` and `zoomedRange` through, and `performLifecycleWholeDocumentWrite`
    /// refuses (and counts) it. The split keeps this function a pure value builder.
    ///
    /// Trade-off (coder-obligations item 17, parse before reserve): the Notes heading title is read
    /// HERE, on the MainActor and outside the write transaction, not inside `body`. A Notes or
    /// bibliography system write queued ahead of FB can change that title before FB's body runs,
    /// so the parse's Notes classification can be stale by then. `flushContentToDatabase` has the
    /// same property (it reads the title before it parses, outside its replace transaction).
    @MainActor
    static func prepare(
        content: String,
        database: ProjectDatabase,
        projectId: String,
        zoomedRange: (start: Double, end: Double?)?,
        zoomedSectionId: String?
    ) -> LifecycleWholeDocumentPrepared? {
        guard !content.isEmpty else {
            // N18: a nil here is silent to the caller, so say it. An empty fetch means "nothing to
            // save": whatever the editor sent (even a fully emptied document) reaches the database
            // through the forced poll before this point, not through this write.
            DebugLog.log(
                .lifecycle,
                "[LifecycleWholeDocumentWrite] prepare: empty content for project \(projectId) "
                    + "-- no whole-document write prepared"
            )
            return nil
        }

        // Strip zoom notes once, reuse for both the mini-Notes text and the markdown to parse.
        // `stripZoomNotes` returns the content unchanged when no marker is present.
        let stripResult = SectionSyncService.stripZoomNotes(from: content)

        let blocks = BlockParser.parse(
            markdown: stripResult.stripped,
            projectId: projectId,
            existingSectionMetadata: nil,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )

        return LifecycleWholeDocumentPrepared(
            blocks: blocks,
            projectId: projectId,
            range: zoomedRange,
            anchorHeadingId: zoomedSectionId,
            miniNotes: zoomedRange != nil ? stripResult.miniNotes : nil
        )
    }

    /// The pure write body: a `@Sendable (Database) throws` closure that captures only the
    /// already-parsed `Sendable` value and runs ONLY the db-level statics extracted from
    /// `replaceBlocks*` (`ProjectDatabase.replaceBlocks(db:...)` for a whole-document write,
    /// `replaceBlocksInRange(db:...)` for a zoomed one) on the `Database` the writer's
    /// transaction hands it. No `self`, no `read`/`write`, no MainActor state.
    ///
    /// Value: for a zoomed write, the rows `replaceBlocksInRange` actually inserted (final ids,
    /// document order); for a whole-document write, `[]` (`replaceBlocks` returns nothing, and
    /// the parsed blocks' ids are NOT the stored ids once heading ids are preserved by title).
    /// No lifecycle caller reads it.
    ///
    /// `deletedAnchors` stays empty on purpose: the replace bumps the epoch inside this same
    /// transaction, so an editor batch reserved before FB that applies AFTER FB's commit is refused
    /// WHOLE for its stale epoch (rule 1 of `applyBlockChangesFromEditor`) and never needs a
    /// tombstone to re-anchor; a lower-numbered batch that applied in turn before FB has had its
    /// rows replaced by FB's content.
    ///
    /// DELIBERATELY NOT DONE: `flushContentToDatabase`'s zoomed MainActor post-processing (zoom-root
    /// re-resolution from the inserted rows, `zoomedBlockRange` recompute, the
    /// `clearZoomRestoringEditor` teardown). That is correct only for a close, switch or quit that
    /// COMPLETES, where no editor state is left to keep consistent. For a close, switch or quit
    /// that is CANCELLED after FB committed, the editor keeps running. The replace keeps heading ids
    /// (matched by title; a zoomed write also pins the zoom root, and leaves machine-managed
    /// Notes/bibliography rows and everything outside the range alone) but deletes and re-inserts
    /// every other block in the replaced region with a fresh id, so the editor's ids for those
    /// blocks are dead after FB's commit, and the empty `deletedAnchors` means no tombstone exists
    /// to re-anchor an insert that points at one. A caller that keeps the editor running must
    /// re-push the block ids before polling resumes (plan P1 abort path; 3a-1b obligation N14).
    ///
    /// Mini-Notes (judge adjustment B9, plan §2.3(a), 3a-1b): for a ZOOMED write whose zoom-notes
    /// text carried definitions, they are written back to the Notes rows FIRST, in this same
    /// transaction, and then the range is replaced. The mini-Notes write is NON-FATAL (N33): it runs
    /// in a savepoint inside `do/catch`, so a failure is logged (`alwaysPersisted`: it is the user's
    /// footnote-definition edit that did not land), its own half-done work is rolled back, and the
    /// range replace still persists. Empty `miniNoteDefinitions` skip the write (N17), as
    /// `flushContentToDatabase` skips an empty mini-Notes text. A whole-document write never writes
    /// mini-Notes (`prepare` only carries them for a zoomed write).
    static func body(
        _ prepared: LifecycleWholeDocumentPrepared
    ) -> @Sendable (Database) throws -> SystemWriteBody<[Block]> {
        { db in
            if let range = prepared.range {
                if !prepared.miniNoteDefinitions.isEmpty {
                    do {
                        try db.inSavepoint {
                            try SectionSyncService.syncMiniNotesBack(
                                definitions: prepared.miniNoteDefinitions, db: db, pid: prepared.projectId)
                            return .commit
                        }
                    } catch {
                        DebugLog.alwaysPersisted(
                            "[LifecycleWholeDocumentWrite] mini-Notes write failed (non-fatal; the range replace "
                                + "still runs, but the zoom panel's footnote-definition edit did not reach the "
                                + "Notes rows): \(error)"
                        )
                    }
                }
                let inserted = try ProjectDatabase.replaceBlocksInRange(
                    db: db,
                    prepared.blocks,
                    for: prepared.projectId,
                    startSortOrder: range.start,
                    endSortOrder: range.end,
                    anchorHeadingId: prepared.anchorHeadingId
                )
                return SystemWriteBody(value: inserted)
            }
            guard prepared.anchorHeadingId == nil else {
                throw LifecycleWholeDocumentWriteError.zoomedSectionWithoutRange
            }
            try ProjectDatabase.replaceBlocks(db: db, prepared.blocks, for: prepared.projectId)
            return SystemWriteBody(value: [])
        }
    }
}

extension BlockSyncService {
    /// Reserves a `.lifecycleWholeDocument` system sequence, waits for its turn and applies
    /// `LifecycleWholeDocumentWrite.body(prepared)` in one writer transaction. `stillWanted` is
    /// always true: a lifecycle save is never withdrawn once asked for.
    ///
    /// Refuses WITHOUT reserving anything when `prepared` is the zoomed-without-range shape
    /// (judge adjustment B1): it logs `alwaysPersisted`, counts `lifecycleWholeDocumentLost` and
    /// emits `.lifecycleWholeDocumentLost` through the same hook as every other loss
    /// (`reportLifecycleWholeDocumentLost`), and returns `.refused(.notWanted)` with
    /// `prepareRan == false`. Every other refusal or failure is counted by
    /// `performSystemWrite`'s own hook, except `.refused(.noWriter)`, which is the caller's
    /// direct-write fallback and not a loss (B6).
    ///
    /// Called by the lifecycle save sequence (`EditorViewState.runLifecycleFlush`, step 6).
    ///
    /// `onReserved` (Phase 3a-1b, C3b) is forwarded to `performSystemWrite`: it fires once FB has reserved its
    /// place in the queue. A refusal that reserves nothing never calls it.
    func performLifecycleWholeDocumentWrite(
        identity: SystemWriteIdentity,
        prepared: LifecycleWholeDocumentPrepared,
        onReserved: (() -> Void)? = nil
    ) async -> SystemWriteResult<[Block]> {
        if let zoomRootId = prepared.anchorHeadingId, prepared.range == nil {
            reportLifecycleWholeDocumentLost(
                reason: "refused: zoomed section \(zoomRootId) has no block range yet "
                    + "-- a whole-document write from it would delete every other section")
            return SystemWriteResult(outcome: .refused(.notWanted), prepareRan: false)
        }
        return await performSystemWrite(
            identity: identity,
            kind: .lifecycleWholeDocument,
            stillWanted: { true },
            onReserved: onReserved,
            body: LifecycleWholeDocumentWrite.body(prepared)
        )
    }
}
