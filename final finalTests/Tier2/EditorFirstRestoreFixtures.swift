//
//  EditorFirstRestoreFixtures.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-i): what the two suites of the editor-first Version History restore share
//  (EditorFirstRestoreTests.swift: the click and its failures; EditorFirstRestoreUndoTests.swift: the rebuild guard, the quick undo and
//  redo, the sidebar). Helpers on `QuickUndoFixtures`; nothing here is a test.
//
//  Every typing test types into a block that holds NO footnote reference (a footnote renumber heals typing in a footnoted block and
//  would mask a loss, round 2a verdict, fidelity item 4).
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension QuickUndoFixtures {

    /// The C body after the document was changed behind the saved version: the text a restore takes away.
    static var editedBody: String { "The C body EDITED." }

    /// The alert a failed restore raises (plan-v3 C4 wording, with the floor-item-5 sentence about text typed into the restored text).
    static var failedRestoreMessage: String {
        "The restore couldn't be saved, so the document is back as it was before the restore. "
            + "Anything you typed into the restored text was removed with it."
    }

    // MARK: - Rigs and versions

    /// A rig on `fourSections` with a saved version, and the document changed AFTER the version (the C body), so that restoring the
    /// version really changes something. Returns the version.
    func makeRigWithEditedBody() throws -> (EditorFirstRig, Snapshot) {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let version = try saveVersion(rig)
        let cBody = try #require(try rig.blocks().first { $0.textContent == "The C body." })
        try rig.rewriteText(ofBlock: cBody.id, to: Self.editedBody)
        return (rig, version)
    }

    func saveVersion(_ rig: EditorFirstRig) throws -> Snapshot {
        try SnapshotService(database: rig.db, projectId: rig.pid).createManualSnapshot(name: "before-restore")
    }

    func makeRestoreRig(_ doc: String) throws -> EditorFirstRig {
        doc == "article" ? try makeArticleRig() : try makeBookRig()
    }

    /// The document is changed after the version: the first long paragraph gets a marker the restore takes away.
    func editAParagraph(_ rig: EditorFirstRig) throws {
        let paragraph = try firstParagraph(in: try rig.blocks().map(\.id), rig)
        try rig.rewriteText(ofBlock: paragraph.id, to: paragraph.textContent + " EDITED-BEFORE")
    }

    /// The rows of the user's own blocks (not Notes, not Bibliography): what a restore and its undo promise to give back.
    func userRows(_ rig: EditorFirstRig) throws -> [Block] {
        try rig.blocks().filter { !$0.isNotes && !$0.isBibliography }
    }

    func removeRows(_ rig: EditorFirstRig, ofSectionTitled title: String) throws {
        let root = try rig.heading(title)
        let ids = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        try deleteRestoreFixtureRows(rig, ids: ids)
    }

    func setStatus(_ rig: EditorFirstRig, ofBlock id: String, to status: SectionStatus) throws {
        try setRestoreFixtureStatus(rig, ofBlock: id, to: status)
    }

    // MARK: - Typing and pressing

    func typing(_ block: Block, to text: String) -> BlockChanges {
        typing(id: block.id, to: text)
    }

    func typing(id: String, to text: String) -> BlockChanges {
        BlockChanges(updates: [BlockUpdate(id: id, textContent: text, markdownFragment: text, headingLevel: nil)])
    }

    func restorePress(_ rig: EditorFirstRig, _ direction: StructuralUndoController.UndoDirection) async throws {
        let entry = try #require(direction == .undo ? rig.unifiedUndo.undoStack.last : rig.unifiedUndo.redoStack.last)
        #expect(await rig.pressAndSettle(entry, direction), "the \(direction) did not end and settle")
        _ = await rig.waitUntilSettled()
    }

    /// Waits for the job and the put-back to end, then polls until the rig's typing queue is empty (a poll carries one batch per cycle;
    /// the put-back's own push may queue keystrokes made while it was in flight).
    func settleThenCarryRestoreTyping(_ rig: EditorFirstRig) async {
        _ = await rig.waitUntilSettled()
        var cycles = 0
        repeat {
            #expect(await rig.awaitRuns([rig.startReport()]), "a poll did not end")
            cycles += 1
        } while !rig.typingQueue.isEmpty && cycles < 6
        _ = await rig.waitUntilSettled()
    }

    // MARK: - The stand-in rebuild

    /// `QuickUndoFixtures.startStampedRebuild`, plus a `rebuild push skipped` event when the guard skipped the push and, BEFORE `rebuild
    /// landed`, whether `content` is the editor's own text again. Reads the database NOW, stamping first (as the three rebuild handlers
    /// do), and lands when `mayLand` opens.
    func startStampedRebuildNotingSkip(_ rig: EditorFirstRig, mayLand: LifecycleEntryHarness.Gate) {
        let stamp = rig.editorState.stampRebuildRead()
        let read = rig.controller.fetchFullBlocksWithIds(db: rig.db, pid: rig.pid)
        rig.events.note("rebuild read")
        let task = Task { @MainActor in
            await mayLand.wait()
            if let read {
                rig.editorState.content = read.markdown
                _ = await rig.sync.setContentWithBlockIds(
                    markdown: read.markdown, blockIds: read.blockIds, imageMeta: read.imageMeta,
                    cursorBoundary: read.bibBoundaryIndex, cursorBoundaryEnd: read.bibBoundaryEndIndex,
                    expectedBlocks: read.expectedBlocks, managedBlockIds: read.managedBlockIds, preserveUserBlocks: true,
                    stillWanted: { rig.editorState.rebuildPushStillWanted(stamp) })
                if await rig.editorState.skipStaleRebuildTail(stamp, kind: "notes", blockSync: rig.sync) {
                    rig.events.note("rebuild push skipped")
                }
            }
            rig.editorState.contentState = .idle
            rig.events.note("rebuild content-equals-live=\(rig.editorState.content == rig.quickEditorText)")
            rig.events.note("rebuild landed")
        }
        rig.editorState.registerRebuildTask(task)
    }

    /// The document's own text: everything before the `# Notes` heading. A settle's footnote and bibliography resyncs may write the
    /// Notes and Bibliography rows again and push them into the editor (the merge-guarded push takes the database's regions), so those
    /// two regions are not what a restore is compared on; the user's text is.
    static func ownText(of markdown: String) -> String {
        markdown.range(of: "\n# Notes\n").map { String(markdown[..<$0.lowerBound]) } ?? markdown
    }

    /// The managed regions of a document: everything from the `# Notes` heading on (empty when there is none). `ownText`'s complement.
    static func notesRegion(of markdown: String) -> String {
        markdown.range(of: "\n# Notes\n").map { String(markdown[$0.lowerBound...]) } ?? ""
    }
}

/// Sets a block row's status. A plain (non-async) function on purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async
/// overload.
@MainActor
private func setRestoreFixtureStatus(_ rig: EditorFirstRig, ofBlock id: String, to status: SectionStatus) throws {
    try rig.db.dbWriter.write { database in
        guard var block = try Block.fetchOne(database, key: id) else { return }
        block.status = status
        try block.update(database)
    }
}

/// Deletes the rows `ids` from the project (same reason for the plain function).
@MainActor
private func deleteRestoreFixtureRows(_ rig: EditorFirstRig, ids: [String]) throws {
    _ = try rig.db.dbWriter.write { database in
        try Block.filter(keys: ids).deleteAll(database)
    }
}
