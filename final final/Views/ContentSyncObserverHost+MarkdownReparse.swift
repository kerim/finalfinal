//
//  ContentSyncObserverHost+MarkdownReparse.swift
//  final final
//
//  t-94369a83 Phase 4a, plan v2 section 1(d) step 5: the two things the debounced Markdown re-parse does once every
//  gate has passed (`ContentSyncObserverHost.scheduleFullDocumentReparse`, ViewNotificationModifiers.swift):
//
//    - `runMarkdownReparseFire`: the per-block save. One synchronous step on the main actor through
//      `MarkdownBlockWriter.prepareAndStart` (read the CURRENT text, parse, compare, reserve the turn, start the write).
//    - `legacyWholeDocumentReparse`: today's body, unchanged apart from its `[MdWrite]` timing line. A whole-document
//      `replaceBlocks`, outside the writer, preserving heading metadata. It is the arm of the UI-test flag
//      `FF_UI_TESTING_MD_LEGACY_REPARSE`, and the fallback when the service has no writer for this project.
//
//  Kept in their own file so ViewNotificationModifiers.swift stays under SwiftLint's file-length limit.
//

import SwiftUI

extension ContentSyncObserverHost {

    /// What the debounce does after the gates. Runs inside the fire's Task, in ONE main-actor turn with the gate checks
    /// that precede it (nothing in here suspends).
    ///
    /// - Per-block path (default): the text is `editorState.content` READ NOW (model ruling M1), not `newValue`.
    /// - Legacy path (`FF_UI_TESTING_MD_LEGACY_REPARSE`): `newValue` exactly as before.
    /// - No writer (the per-block path's fallback to the whole-document write): `editorState.content` read now, like the
    ///   per-block path (judge R4).
    ///
    /// `refire` (handed to the writer) schedules a NORMAL debounce fire through `scheduleSourceModeReparse`, so every gate
    /// runs again; the writer calls it after any non-clean outcome (plan 1(d) step 6). Its `newValue` argument is
    /// irrelevant on the per-block path, which reads the content itself.
    @MainActor
    static func runMarkdownReparseFire(
        newValue: String,
        db: ProjectDatabase,
        pid: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        let writer = editorState.markdownWriter
        guard writer.isEnabled else {
            legacyWholeDocumentReparse(newValue: newValue, db: db, pid: pid, editorState: editorState)
            return
        }
        let refire: @MainActor () -> Void = {
            ContentSyncObserverHost<Content>.scheduleSourceModeReparse(
                newValue: editorState.content, editorState: editorState, services: services)
        }
        let disposition = writer.prepareAndStart(
            text: editorState.content, database: db, projectId: pid, service: editorState.blockSyncService, refire: refire)
        if disposition == .noWriter {
            DebugLog.alwaysPersisted(
                "[MdWrite] no writer for this database and project: the Markdown re-parse writes the whole document (today's path)")
            // Judge R4: the CURRENT text, as the per-block path reads it (M1). A surviving schedule's `newValue` can be older
            // than the database (pushes made while `contentState` is not `.idle` do not restart a scheduled re-parse).
            legacyWholeDocumentReparse(newValue: editorState.content, db: db, pid: pid, editorState: editorState)
        }
    }

    /// Today's non-zoomed Markdown re-parse, kept as it was: rebuilds the full block table from `newValue`, preserving
    /// existing heading metadata (status/tags/word goal). A direct whole-document `replaceBlocks`, outside the writer.
    /// It logs the same `[MdWrite]` fields as the per-block path (`mode=legacy`; `parse` covers the row read for the
    /// heading metadata, the Notes-title read and the parse; `apply` is the `replaceBlocks`; `mainThread` is the whole body).
    @MainActor
    static func legacyWholeDocumentReparse(
        newValue: String,
        db: ProjectDatabase,
        pid: String,
        editorState: EditorViewState
    ) {
        let clock = ContinuousClock()
        let start = clock.now
        let existing = try? db.fetchBlocks(projectId: pid)
        var metadata: [String: SectionMetadata] = [:]
        for block in existing ?? [] where block.blockType == .heading {
            metadata[block.textContent] = SectionMetadata(
                status: block.status,
                tags: block.tags?.isEmpty == false ? block.tags : nil,
                wordGoal: block.wordGoal
            )
        }
        // C5: highest-stakes site -- this IS the live, debounced Source Mode re-parse a
        // hand-typed "## Notes" heading goes through, so the DB-resolved title is threaded
        // explicitly rather than left to default.
        let blocks = BlockParser.parse(
            markdown: newValue,
            projectId: pid,
            existingSectionMetadata: metadata.isEmpty ? nil : metadata,
            notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid)
        )
        let parsed = clock.now
        let wrote = (try? db.replaceBlocks(blocks, for: pid)) != nil
        let end = clock.now
        // The rows were just replaced wholesale: the per-block writer's baseline (when it is on, in the no-writer fallback)
        // describes ids that no longer exist. Inert under the legacy flag.
        editorState.markdownWriter.noteDirectWholeWrite(text: newValue)
        editorState.markdownWriter.emit(MarkdownBlockWriter.TimingLine(
            mode: "legacy", parse: parsed - start, mainThread: end - start, apply: end - parsed, counts: "-",
            blocks: blocks.count, chars: newValue.utf8.count, outcome: wrote ? "replaced" : "failed"))
    }
}
