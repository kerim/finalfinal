//
//  StructuralUndoBarrierTests.swift
//  final finalTests
//
//  Phase 4 (docs/plans/patient-rewinding-clockwork.md §4.5/§7): invalidateAll barrier
//  coverage for the four call sites this phase adds.
//
//  Of the four, only ContentView+HierarchyEnforcement.swift's
//  `persistEnforcedSections(editorState:)` is a `static` function reachable without a live
//  SwiftUI view hierarchy -- the other three (drag reorder's `finalizeSectionReorder`, the two
//  inline-annotation branches in `toggleAnnotationCompletion`/`handleAnnotationTextUpdate`, and
//  the three zoom call sites in `sidebarView`) are instance methods/closures on `ContentView`
//  itself, a SwiftUI View struct with @State/@Environment storage that nothing in this test
//  target ever instantiates directly (grep confirms no `ContentView(` construction anywhere
//  under final finalTests/) -- matching the existing precedent that Phase 3's own
//  `updateSection` metadata-edit barrier (ContentView+SectionManagement.swift) has no direct
//  unit test either. Those three are covered by the driver's manual/e2e verification instead
//  (see the coder's final report for the exact repro steps) rather than a novel
//  ContentView-instantiation pattern with no precedent in this suite.
//

import Testing
import Foundation
@testable import final_final

@Suite("Structural undo barriers -- Phase 4")
@MainActor
struct StructuralUndoBarrierTests {

    @Test("persistEnforcedSections invalidates the unified undo timeline (hierarchy-enforcement barrier)")
    func persistEnforcedSectionsInvalidatesTimeline() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let unifiedUndoService = UnifiedUndoService()
        unifiedUndoService.record(StructuralEntry(kind: .sectionDelete, title: "Delete Section", undoSnapshotId: "snap-1"))
        #expect(!unifiedUndoService.undoStack.isEmpty)

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        let sectionsVM = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }
        editorState.sections = sectionsVM

        let controller = StructuralUndoController()
        // persistEnforcedSections only touches unifiedUndoService via this barrier -- a bare,
        // otherwise-unconfigured controller is enough to exercise it.
        controller.configure(
            editorState: editorState, blockSyncService: BlockSyncService(),
            sectionSyncService: SectionSyncService(), bibliographySyncService: BibliographySyncService(),
            footnoteSyncService: FootnoteSyncService(), annotationSyncService: AnnotationSyncService(),
            unifiedUndoService: unifiedUndoService
        )

        // DocumentManager.shared is a process-wide singleton -- save/restore every field this
        // test touches so it doesn't leak state into other tests that also read it.
        let priorController = DocumentManager.shared.structuralUndoController
        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.structuralUndoController = controller
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid
        defer {
            DocumentManager.shared.structuralUndoController = priorController
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
        }

        await ContentView.persistEnforcedSections(editorState: editorState)

        #expect(unifiedUndoService.undoStack.isEmpty, "hierarchy enforcement must invalidate the timeline")
        #expect(unifiedUndoService.redoStack.isEmpty)
    }

    @Test("persistEnforcedSections is a harmless no-op invalidation when the timeline is already empty")
    func persistEnforcedSectionsNoOpWhenTimelineEmpty() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let unifiedUndoService = UnifiedUndoService()
        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }

        let controller = StructuralUndoController()
        controller.configure(
            editorState: editorState, blockSyncService: BlockSyncService(),
            sectionSyncService: SectionSyncService(), bibliographySyncService: BibliographySyncService(),
            footnoteSyncService: FootnoteSyncService(), annotationSyncService: AnnotationSyncService(),
            unifiedUndoService: unifiedUndoService
        )

        let priorController = DocumentManager.shared.structuralUndoController
        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.structuralUndoController = controller
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid
        defer {
            DocumentManager.shared.structuralUndoController = priorController
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
        }

        await ContentView.persistEnforcedSections(editorState: editorState)
        #expect(unifiedUndoService.undoStack.isEmpty)
    }
}
