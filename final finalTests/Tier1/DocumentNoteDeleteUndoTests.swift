//
//  DocumentNoteDeleteUndoTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  t-c683aa25 -- Document Note delete: tier 1, quiet, undoable (UX contract §3/D3).
//  Proves the bespoke B3/B4 sequence (StructuralUndoController.performDocumentNoteDelete /
//  performDocumentNoteUndo / performDocumentNoteRedo) end to end, via the same
//  testEvalBoolOverride/testEvalVoidOverride JS-round-trip stubs used throughout this suite
//  -- see StructuralUndoControllerTests.swift's header for that harness's own rationale.
//  Deliberately NOT reusing that file's `makeFixture()` (which sets up a section + a manual
//  snapshot for the six snapshot-based ops) -- this kind touches neither, by design (see
//  docs/architecture/unified-undo.md's "Tracked entries for DB-only mutations" subsection).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Document Note delete/undo/redo -- Tier 1: Silent Killers")
@MainActor
struct DocumentNoteDeleteUndoTests {

    private func getContentId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM content LIMIT 1")!
        }
    }

    private func makeFixture() throws -> (
        db: ProjectDatabase, pid: String, contentId: String,
        controller: StructuralUndoController, editorState: EditorViewState,
        unifiedUndoService: UnifiedUndoService
    ) {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let contentId = try getContentId(db)

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = TestFixtureFactory.testContent

        let blockSyncService = BlockSyncService()
        let sectionSyncService = SectionSyncService()
        let bibliographySyncService = BibliographySyncService()
        bibliographySyncService.configure(database: db, projectId: pid)
        let footnoteSyncService = FootnoteSyncService()
        footnoteSyncService.configure(database: db, projectId: pid)
        let annotationSyncService = AnnotationSyncService()
        let unifiedUndoService = UnifiedUndoService()

        let controller = StructuralUndoController()
        controller.configure(
            editorState: editorState,
            blockSyncService: blockSyncService,
            sectionSyncService: sectionSyncService,
            bibliographySyncService: bibliographySyncService,
            footnoteSyncService: footnoteSyncService,
            annotationSyncService: annotationSyncService,
            unifiedUndoService: unifiedUndoService,
            findBarState: FindBarState()
        )
        // Every JS round trip this bespoke sequence makes (beginStructuralOp,
        // finalizeStructuralOpPostOpDoc, setUndoDescriptor, receiveUndoOutcome/
        // receiveRedoOutcome) genuinely returns/is a real boolean or void call in production --
        // unlike StructuralUndoControllerTests.swift's realisticEvalBoolDefault, nothing in
        // this sequence ever calls a void-returning JS function (like setContent) through
        // evalBool, so a blanket `true` models the bridge correctly here.
        controller.testEvalBoolOverride = { _ in true }
        controller.testEvalVoidOverride = { _ in true }

        return (db, pid, contentId, controller, editorState, unifiedUndoService)
    }

    @Test("Delete records a real .documentNoteDelete entry (payload = deleted row, undoSnapshotId = nil) and the DB row is gone")
    func deleteRecordsEntryAndRemovesRow() async throws {
        let fixture = try makeFixture()
        let note = try fixture.db.insertDocumentAnnotation(
            contentId: fixture.contentId, type: .comment, text: "Check with editor"
        )

        let outcome = await fixture.controller.performDocumentNoteDelete(id: note.id)
        #expect(outcome == .performed)
        #expect(try fixture.db.fetchAnnotation(id: note.id) == nil, "the row must actually be deleted")

        let entry = try #require(fixture.unifiedUndoService.undoStack.last)
        #expect(entry.kind == .documentNoteDelete)
        #expect(entry.title == "Delete Document Note")
        #expect(entry.undoSnapshotId == nil, "no snapshot machinery for this kind")
        #expect(fixture.unifiedUndoService.redoStack.isEmpty)

        guard case .documentNote(let payloadRow) = entry.payload else {
            Issue.record("expected a .documentNote payload, got \(String(describing: entry.payload))")
            return
        }
        #expect(payloadRow.id == note.id)
        #expect(payloadRow.text == note.text)
        #expect(payloadRow.type == note.type)

        // Disjointness from the snapshot inverse (B7): this op must never call
        // createUndoPointSnapshot -- no snapshot row exists after it.
        let snapshotService = SnapshotService(database: fixture.db, projectId: fixture.pid)
        #expect(
            try snapshotService.fetchAllSnapshots().isEmpty,
            "performDocumentNoteDelete must never mint a snapshot"
        )
    }

    @Test("Undo re-inserts the row identical (id/type/text/isCompleted/createdAt) and moves the entry to the redo stack")
    func undoReinsertsRowIdentical() async throws {
        let fixture = try makeFixture()
        let note = try fixture.db.insertDocumentAnnotation(
            contentId: fixture.contentId, type: .task, text: "Needs peer review"
        )

        let deleteOutcome = await fixture.controller.performDocumentNoteDelete(id: note.id)
        #expect(deleteOutcome == .performed)
        let entry = try #require(fixture.unifiedUndoService.undoStack.last)

        await fixture.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)

        let restored = try #require(try fixture.db.fetchAnnotation(id: note.id))
        #expect(restored.id == note.id)
        #expect(restored.type == note.type)
        #expect(restored.text == note.text)
        #expect(restored.isCompleted == note.isCompleted)
        #expect(
            abs(restored.createdAt.timeIntervalSince(note.createdAt)) < 0.001,
            "createdAt must round-trip verbatim, not be reset to 'now'"
        )

        #expect(fixture.unifiedUndoService.undoStack.isEmpty)
        #expect(fixture.unifiedUndoService.redoStack.last?.id == entry.id)
    }

    @Test("Redo deletes the row again and moves the entry back to the undo stack")
    func redoDeletesAgain() async throws {
        let fixture = try makeFixture()
        let note = try fixture.db.insertDocumentAnnotation(
            contentId: fixture.contentId, type: .reference, text: "See appendix"
        )

        let deleteOutcome = await fixture.controller.performDocumentNoteDelete(id: note.id)
        #expect(deleteOutcome == .performed)
        let entry = try #require(fixture.unifiedUndoService.undoStack.last)

        await fixture.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)
        #expect(try fixture.db.fetchAnnotation(id: note.id) != nil)
        let redoEntry = try #require(fixture.unifiedUndoService.redoStack.last)

        await fixture.controller.handleStructuralRequest(opId: redoEntry.id.uuidString, direction: .redo)

        #expect(try fixture.db.fetchAnnotation(id: note.id) == nil, "redo must delete the row again")
        #expect(fixture.unifiedUndoService.redoStack.isEmpty)
        #expect(fixture.unifiedUndoService.undoStack.last?.id == entry.id)
    }

    @Test("An entry with undoSnapshotId == nil survives invalidateAll (unpinSnapshots guards the optional instead of crashing)")
    func nilSnapshotIdEntrySurvivesInvalidateAll() async throws {
        let fixture = try makeFixture()
        let note = try fixture.db.insertDocumentAnnotation(
            contentId: fixture.contentId, type: .comment, text: "Note"
        )

        let outcome = await fixture.controller.performDocumentNoteDelete(id: note.id)
        #expect(outcome == .performed)
        let entry = try #require(fixture.unifiedUndoService.undoStack.last)
        #expect(entry.undoSnapshotId == nil)

        // invalidateAll's unpinSnapshots(of:) must guard the now-optional undoSnapshotId
        // rather than force-unwrap/crash on this kind's nil value.
        fixture.unifiedUndoService.invalidateAll(reason: "test barrier")
        #expect(fixture.unifiedUndoService.undoStack.isEmpty)
        #expect(fixture.unifiedUndoService.redoStack.isEmpty)
    }

    @Test("performDocumentNoteDelete refuses when the annotation id does not exist")
    func refusesForMissingAnnotation() async throws {
        let fixture = try makeFixture()

        let outcome = await fixture.controller.performDocumentNoteDelete(id: "not-a-real-id")

        #expect(outcome == .refused)
        #expect(fixture.unifiedUndoService.undoStack.isEmpty)
    }
}
