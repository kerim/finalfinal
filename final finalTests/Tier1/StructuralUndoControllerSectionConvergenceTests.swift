//
//  StructuralUndoControllerSectionConvergenceTests.swift
//  final finalTests
//
//  Tier 1: end-to-end proof that the `section` table actually converges after a real sidebar
//  delete/duplicate op, driven through `StructuralUndoController.performSectionDelete`/
//  `performSectionDuplicate` -- not just `Database+SectionOps.swift` in isolation
//  (`SectionDeleteDuplicateOpsTests.swift` covers that layer, proving the two removed call sites
//  are gone; this file proves the REPLACEMENT mechanism actually works).
//
//  Real production bug found via Phase D's e2e regression suite (2026-08-22), NOT a test
//  problem: `section` is a separate table from `block`, keyed by its OWN independently-generated
//  UUID (`SectionReconciler.reconcile()`'s `Section(...)` construction -- `Section.swift`'s
//  `id: String = UUID().uuidString` default). The OLD `Database+SectionOps.swift` wrongly
//  assumed `block` and `section` shared an ID space: delete's
//  `Section.filter(keys: blockIds).deleteAll(db)` matched zero rows every single time (a silent
//  no-op -- the stale row for the deleted heading survived every sidebar delete, and
//  `Snapshot.swift`'s direct `section.sortOrder` reads, i.e. Version History, were reading a
//  table that didn't reflect the delete), and duplicate's `Section(id: copy.id, ...)` insert
//  created a PERMANENT ORPHAN row under a `block` id no reconciler pass would ever look up again
//  -- confirmed empirically as active, ongoing corruption (4 duplicates -> 4 accumulated orphan
//  rows). The fix: those two call sites no longer touch `section` at all;
//  `StructuralUndoController.performStructuralOp` now forces a `SectionSyncService.syncNow`
//  resync after the content push lands (its own "Step 7c" comment), letting `section` converge
//  through its real, sole maintainer (`SectionReconciler`) -- the same pattern
//  `SnapshotService.restoreEntireProject` (the undo/redo path for every structural op) already
//  used correctly: delete-then-reinsert with fresh, independently-generated ids, never keyed by
//  an unrelated table's id.
//
//  `StructuralUndoControllerTests.swift`'s shared `makeFixture()` deliberately does NOT configure
//  `sectionSyncService` (none of its existing tests needed section-table convergence, and every
//  existing assertion there checks the `block` table -- the actual source of truth for the
//  sidebar UI, which is why this bug shipped invisibly for as long as it did). This file builds
//  its own fixture instead of touching that shared one, so no existing test's behavior changes.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("StructuralUndoController — section-table convergence (2026-08-22 fix)")
@MainActor
struct StructuralUndoSectionConvergenceTests {

    // A named struct rather than a raw tuple, purely to stay under SwiftLint's large_tuple cap --
    // no behavioral difference, `fixture.db`/`.pid`/`.controller`/`.editorState` access is identical.
    //
    // `unifiedUndoService` and `sectionSyncService` MUST be stored here, not just handed to
    // `controller.configure(...)` and left to fall out of `makeFixture()`'s local scope:
    // `StructuralUndoController` holds both as `weak var`. Without a surviving strong reference,
    // ARC deallocates them before the test body's `performSectionDelete`/`performSectionDuplicate`
    // call runs -- `performStructuralOp`'s `guard let unifiedUndoService` then fails immediately
    // and every op reports `.refused` before ever reaching the mutation this file exists to test
    // (found via this file's own first real test run: both tests failed with `.refused`, not the
    // expected `.performed`, tracing back to exactly this). `StructuralUndoControllerTests.swift`'s
    // `makeFixture()` already returns `unifiedUndoService` for the identical reason; it doesn't
    // need `sectionSyncService` to survive because none of its tests assert through it the way
    // these two do.
    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let controller: StructuralUndoController
        let editorState: EditorViewState
        let unifiedUndoService: UnifiedUndoService
        let sectionSyncService: SectionSyncService
    }

    private func makeFixture() async throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = TestFixtureFactory.testContent

        let blockSyncService = BlockSyncService()
        let sectionSyncService = SectionSyncService()
        sectionSyncService.configure(database: db, projectId: pid)
        sectionSyncService.editorState = editorState
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
        // Same JS-bridge stub as StructuralUndoControllerTests.swift's makeFixture() (internal,
        // so accessible cross-file within this same test target) -- models what a real
        // evalBool/evalVoid round trip reports, not a blanket `true`.
        controller.testEvalBoolOverride = { js in StructuralUndoControllerTests.realisticEvalBoolDefault(js) }
        controller.testEvalVoidOverride = { _ in true }

        // Establish the REAL baseline `section` table state the same way production does: run
        // the actual reconciler once against the seeded content, so "Second Section" gets its
        // own independently-generated UUID (never a `block` id) -- the exact shape the removed
        // code got wrong, and the shape every real section row has in production.
        await sectionSyncService.syncNow(TestFixtureFactory.testContent)

        return Fixture(
            db: db, pid: pid, controller: controller, editorState: editorState,
            unifiedUndoService: unifiedUndoService, sectionSyncService: sectionSyncService
        )
    }

    /// Wires `DocumentManager.shared`'s process-wide singleton to this fixture's own
    /// controller/db/project id, saving and returning the prior values so the caller's `defer`
    /// can restore them. Needed for Step 7c's project-switch guard (`StructuralUndoController.
    /// swift`, review round 2026-08-22 -- mirrors `enforceHierarchyInSequence`'s own identical
    /// guard, and the identical save/restore pattern `StructuralUndoControllerTests.swift`/
    /// `StructuralUndoBarrierTests.swift` already use for the same reason): without this,
    /// `DocumentManager.shared.projectId` is whatever a DIFFERENT test last left it as (a
    /// process-wide global, not reset per test), never equal to THIS fixture's
    /// `editorState.currentProjectId` -- so the guard would refuse every time, silently
    /// skipping the resync this whole test exists to verify.
    private func wireDocumentManager(to fixture: Fixture) -> (controller: StructuralUndoController?, db: ProjectDatabase?, pid: String?) {
        let prior = (
            controller: DocumentManager.shared.structuralUndoController,
            db: DocumentManager.shared.projectDatabase,
            pid: DocumentManager.shared.projectId
        )
        DocumentManager.shared.structuralUndoController = fixture.controller
        DocumentManager.shared.projectDatabase = fixture.db
        DocumentManager.shared.projectId = fixture.pid
        return prior
    }

    @Test("performSectionDelete converges the section table: the deleted heading's real section row disappears, not just the block row")
    func performSectionDeleteConvergesSectionTable() async throws {
        let fixture = try await makeFixture()
        let prior = wireDocumentManager(to: fixture)
        defer {
            DocumentManager.shared.structuralUndoController = prior.controller
            DocumentManager.shared.projectDatabase = prior.db
            DocumentManager.shared.projectId = prior.pid
        }

        let sectionsBefore = try fixture.db.fetchSections(projectId: fixture.pid)
        let secondSectionRow = try #require(
            sectionsBefore.first { $0.title == "Second Section" },
            "the reconciler should have created a real section row for \"Second Section\" during setup"
        )

        let blocksBefore = try fixture.db.fetchBlocks(projectId: fixture.pid)
        let secondSectionBlock = try #require(blocksBefore.first { $0.textContent == "Second Section" })

        let ok = await fixture.controller.performSectionDelete(rootId: secondSectionBlock.id)
        #expect(ok == .performed)

        let sectionsAfter = try fixture.db.fetchSections(projectId: fixture.pid)
        #expect(
            !sectionsAfter.contains { $0.id == secondSectionRow.id },
            "the section table must converge -- the deleted heading's REAL section row must be gone, not silently survive"
        )
        #expect(!sectionsAfter.contains { $0.title == "Second Section" })
    }

    @Test("performSectionDuplicate converges the section table: the copy gets its own independently-keyed row, not an orphan under the block id")
    func performSectionDuplicateConvergesSectionTable() async throws {
        let fixture = try await makeFixture()
        let prior = wireDocumentManager(to: fixture)
        defer {
            DocumentManager.shared.structuralUndoController = prior.controller
            DocumentManager.shared.projectDatabase = prior.db
            DocumentManager.shared.projectId = prior.pid
        }

        let sectionsBefore = try fixture.db.fetchSections(projectId: fixture.pid)
        let beforeCount = sectionsBefore.count

        let blocksBefore = try fixture.db.fetchBlocks(projectId: fixture.pid)
        let secondSectionBlock = try #require(blocksBefore.first { $0.textContent == "Second Section" })

        let ok = await fixture.controller.performSectionDuplicate(rootId: secondSectionBlock.id)
        #expect(ok == .performed)

        let blocksAfter = try fixture.db.fetchBlocks(projectId: fixture.pid)
        let copiedBlock = try #require(blocksAfter.first { $0.textContent == "Second Section copy" })

        let sectionsAfter = try fixture.db.fetchSections(projectId: fixture.pid)
        #expect(
            sectionsAfter.count == beforeCount + 1,
            "the section table must gain exactly one new row for the copy -- not zero, and not an extra orphan alongside a real one"
        )
        let copiedSectionRow = try #require(
            sectionsAfter.first { $0.title == "Second Section copy" },
            "the copy must get a real, reconciler-derived section row -- not silently missing"
        )
        #expect(
            copiedSectionRow.id != copiedBlock.id,
            "the copy's section row must have its OWN independently-generated id, never the block's id -- that mismatch was the orphan-row bug"
        )
    }
}
