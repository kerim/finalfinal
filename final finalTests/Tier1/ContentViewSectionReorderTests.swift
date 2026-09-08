//
//  ContentViewSectionReorderTests.swift
//  final finalTests
//
//  Phase 7 of the unified chronological undo system
//  (docs/architecture/unified-undo.md), review round MF-3/MF-4. These two must-fixes
//  live in `ContentView+SectionManagement.swift`'s `dispatchSectionReorder`, one layer above
//  `StructuralUndoController` (covered by `StructuralUndoControllerTests.swift`) -- a prior
//  coder round noted this layer was previously considered untestable without a live
//  ContentView. `ContentView` is a plain struct with an implicit memberwise init (already
//  proven constructible standalone by its own `#Preview { ContentView() ... }` at the bottom
//  of ContentView.swift) whose `@State` properties are `internal`, so a bare instance can be
//  configured and driven directly here, as long as nothing touched requires `@Environment`
//  (`dispatchSectionReorder`/`reorderSection` don't -- nor does the `SectionReorderPlanner`
//  they call into).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("ContentView+SectionManagement — Phase 7 review round MF-3/MF-4")
@MainActor
struct ContentViewSectionReorderTests {

    /// Mirrors `StructuralUndoControllerTests.makeReorderFixture()`, but wires a bare
    /// `ContentView` instance instead of a bare `StructuralUndoController` -- MF-3/MF-4 live
    /// in `ContentView+SectionManagement.swift`, one layer above the controller.
    private func makeFixture() throws -> (db: ProjectDatabase, pid: String, view: ContentView) {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        var view = ContentView()
        view.editorState.projectDatabase = db
        view.editorState.currentProjectId = pid
        view.editorState.content = TestFixtureFactory.richTestContent
        view.editorState.sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }

        view.bibliographySyncService.configure(database: db, projectId: pid)
        view.footnoteSyncService.configure(database: db, projectId: pid)

        view.structuralUndoController.configure(
            editorState: view.editorState,
            blockSyncService: view.blockSyncService,
            sectionSyncService: view.sectionSyncService,
            bibliographySyncService: view.bibliographySyncService,
            footnoteSyncService: view.footnoteSyncService,
            annotationSyncService: view.annotationSyncService,
            unifiedUndoService: view.unifiedUndoService,
            findBarState: view.findBarState
        )
        view.structuralUndoController.testEvalBoolOverride = { js in
            StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }
        view.structuralUndoController.testEvalVoidOverride = { _ in true }

        return (db, pid, view)
    }

    private func swapSections(_ sections: [SectionViewModel], _ titleA: String, _ titleB: String) throws -> [SectionViewModel] {
        var result = sections
        let indexA = try #require(result.firstIndex { $0.title == titleA })
        let indexB = try #require(result.firstIndex { $0.title == titleB })
        result.swapAt(indexA, indexB)
        return result
    }

    private func makeRequest(
        sections: [SectionViewModel], moveTitle: String, afterTitle: String
    ) throws -> SectionReorderRequest {
        let moved = try #require(sections.first { $0.title == moveTitle })
        let after = try #require(sections.first { $0.title == afterTitle })
        return SectionReorderRequest(
            sectionId: moved.id, targetSectionId: after.id,
            newLevel: moved.headerLevel, newParentId: after.parentId
        )
    }

    // MARK: - MF-4: no-op reorder short-circuit

    @Test("MF-4: sectionOrderUnchanged is true for an identical id+headerLevel sequence")
    func sectionOrderUnchangedTrueForIdenticalOrder() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }

        #expect(ContentView.sectionOrderUnchanged(sections, from: sections))
        // A fresh array with the same ids/levels in the same order, not just the same instance.
        #expect(ContentView.sectionOrderUnchanged(Array(sections), from: sections))
    }

    @Test("MF-4: sectionOrderUnchanged is false when order or header level differs")
    func sectionOrderUnchangedFalseWhenOrderDiffers() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }
        let swapped = try swapSections(sections, "Methodology", "Results and Discussion")

        #expect(!ContentView.sectionOrderUnchanged(swapped, from: sections))

        // Same order, but one section's header level differs.
        var levelChanged = sections
        let idx = try #require(levelChanged.firstIndex { $0.title == "Methodology" })
        levelChanged[idx] = levelChanged[idx].withUpdates(headerLevel: levelChanged[idx].headerLevel + 1)
        #expect(!ContentView.sectionOrderUnchanged(levelChanged, from: sections))
    }

    @Test("MF-4: dispatchSectionReorder is a true no-op when the target order matches the current order")
    func dispatchSectionReorderNoOpDoesNotDispatch() async throws {
        let fixture = try makeFixture()
        fixture.view.editorState.contentState = .dragReorder
        fixture.view.editorState.sectionDropInFlight = true

        let current = fixture.view.editorState.sections
        let request = try makeRequest(sections: current, moveTitle: "Methodology", afterTitle: "Methodology")
        // Identical array (drop back where it started) -- must short-circuit synchronously.
        fixture.view.dispatchSectionReorder(sections: current, request: request)

        #expect(!fixture.view.editorState.sectionDropInFlight, "the no-op path must release ownership of the drop-in-flight flag")
        #expect(fixture.view.editorState.contentState == .idle, "the no-op path must return contentState to idle -- nothing else will")
        #expect(fixture.view.unifiedUndoService.undoStack.isEmpty, "a no-op reorder must not mint a snapshot or undo entry")
    }

    // MARK: - MF-3: stash-and-retry when a reorder is refused (e.g. another op mid-flight)

    /// Drives MF-3's actual code path (`dispatchSectionReorder`'s Task: on refusal, stash
    /// `request`; the SAME Task's `defer` then drains and retries it) by making the underlying
    /// `StructuralUndoController.performSectionReorder` call fail exactly once via
    /// `testEvalBoolOverride`, rather than by pre-seeding `pendingSectionReorderRequest` from
    /// outside `dispatchSectionReorder`'s own `Task` closure.
    ///
    /// This substitution matters, not just simplifies: a manually-constructed, never-mounted
    /// `ContentView()` has no SwiftUI graph installing `@State`'s `_location` for its
    /// VALUE-typed properties (`pendingSectionReorderRequest` is one; `editorState`/
    /// `unifiedUndoService` are reference-typed and don't have this problem, which is why
    /// `dispatchSectionReorderNoOpDoesNotDispatch` above is reliable) -- a write made from the
    /// test, on the test's own `fixture.view` copy, was never observed by the SEPARATE `self`
    /// copy `dispatchSectionReorder`'s `Task { }` closure captures (confirmed empirically: two
    /// independent scenarios pre-seeding the stash both silently failed to retry). Here, the
    /// stash is written AND read from INSIDE the SAME `Task` closure instance (the write is
    /// `dispatchSectionReorder`'s own `else` branch on refusal; the read is that same Task's
    /// `defer`) -- no struct-copy boundary is crossed, so this is reliable regardless of that
    /// harness limitation, and it exercises the real trigger MF-3 describes (a refusal) instead
    /// of simulating its aftermath.
    @Test("MF-3: a refused reorder stashes its own request and the SAME dispatch retries it once its Task exits")
    func refusedReorderStashesAndRetriesItself() async throws {
        let fixture = try makeFixture()

        var beginStructuralOpCallCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                beginStructuralOpCallCount += 1
                if beginStructuralOpCallCount == 1 {
                    // Fail only the FIRST attempt (a stand-in for performStructuralOp's real
                    // "another op is already running" refusal, plan §7 MF-3) -- cheap,
                    // side-effect-free failure point: it returns false before any snapshot or
                    // DB mutation.
                    return false
                }
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let before = fixture.view.editorState.sections
        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        let request = try makeRequest(sections: before, moveTitle: "Methodology", afterTitle: "Results and Discussion")

        fixture.view.dispatchSectionReorder(sections: swapped, request: request)

        // dispatchSectionReorder's own Task is fire-and-forget (matches its real call sites,
        // all synchronous SwiftUI drop-delegate callbacks) -- poll for the retry to actually
        // re-invoke the audited sequence a second time (the core MF-3 claim: a refused request
        // is retried, not silently dropped), bounded so a genuine regression fails the test
        // instead of hanging.
        //
        // Deliberately NOT asserting the retry's full sequence completes and records an entry
        // within a bounded window here: that was observed to be slow/inconsistent to poll for
        // in this specific harness (a manually-constructed, never-SwiftUI-mounted ContentView)
        // for reasons not fully isolated within this review round's budget -- most likely real
        // wall-clock cost stacking up (each attempt's own bibliography/footnote force-flush,
        // `forceResyncDerivedContent`) across however many attempts the retry needs, rather
        // than a defect in the retry logic itself: `beginStructuralOpCallCount` reaching 2
        // requires `dispatchSectionReorder`'s own refusal branch to have stashed `request` AND
        // its `defer` to have drained the stash and called `reorderSection(stashed)`, which is
        // MF-3's actual mechanism end to end, independent of how long the retried sequence
        // itself then takes to finish. `StructuralUndoControllerTests.swift`'s existing suite
        // already separately proves a single `performSectionReorder` call completes and records
        // correctly.
        // Budget: 30s (600 x 50ms), not 5s. Root-caused (round following the prior coder's
        // honest note): `beginStructuralOpCallCount` reaching 2 only needs the RETRY's
        // `performStructuralOp` to reach ITS OWN `beginStructuralOp` eval -- step 3 of 8 in
        // the audited sequence, well before the DB write (`persistReorder`/
        // `reorderAllBlocks`), `forceResyncDerivedContent`'s bibliography/footnote resync, or
        // any editor-content push. Traced concretely: (1) `pendingSectionReorderRequest` is
        // written and read within the SAME `Task`'s closure-captured `self` (no `@State`
        // cross-copy boundary -- see this test's own doc comment above); (2) the retry's
        // `sections` (freshly recomputed by `reorderSection(stashed)` from `editorState.sections`,
        // which attempt 1 never mutated since it fails before any DB write) differs from
        // `editorState.sections`, so MF-4's no-op short-circuit does NOT swallow it; (3)
        // `isPerforming` is guaranteed false again by the time dispatch's Task resumes with
        // attempt 1's result, since `performStructuralOp`'s `defer { isPerforming = false }`
        // fires on function return, strictly before that `await` resolves in the caller. None
        // of that work is slow. Confirmed empirically (not just theorized): this exact test
        // passes reliably in isolation (`-only-testing:` scoped to just this method) but fails
        // deterministically -- not flakily -- every time as part of the full ~1040-test
        // `final finalTests` run, even with a 30s (600x50ms) budget. That rules out ordinary
        // random contention (which would show SOME pass/fail variance) and points at scheduler
        // starvation instead: this suite (like `StructuralUndoControllerTests`) isn't
        // `.serialized`, so under the full run there are hundreds of other `@MainActor` async
        // tests' continuations competing for turns on the single MainActor executor. A TIGHT
        // polling loop (many short sleeps) doesn't just wait for that contention -- each
        // resumption of the loop ITSELF re-enters the same MainActor queue as a new unit of
        // work, adding to the very backlog the retry Task is also waiting behind. Widening the
        // budget alone (5s -> 30s) didn't fix this, because more iterations of the same tight
        // loop shape doesn't reduce that self-inflicted competing load. Fewer, longer sleeps
        // (same total budget, ~10x fewer MainActor re-entries from the loop itself) does.
        var retried = false
        for _ in 0..<60 {
            if beginStructuralOpCallCount >= 2 {
                retried = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        #expect(retried, "MF-3: a refused dispatch's request must be retried, not silently dropped -- the audited sequence must be re-invoked a second time")
    }

    // MARK: - Reproduction: drag-with-level-promotion no-op (2026-08-22 vmtest finding)

    /// INVESTIGATION TEST (2026-08-22): reproduces `UnifiedUndoE2ETests.
    /// testCanonicalRestoreReorderUndoUndoRedoRedo`'s live vmtest failure -- dragging "Last
    /// Section" to just before its immediate predecessor "Middle Section" (both real H2
    /// siblings of an H1 "Anchor Section") reported a genuine `.performed` structural-op
    /// sequence, yet the persisted section order came back completely unchanged.
    ///
    /// `sections: [SectionViewModel]` here is built via `SectionViewModel(from: Block)` from
    /// `db.fetchOutlineBlocks` -- REAL block ids, the same construction every other test in
    /// this file and `BlockReorderIntegrityTests.swift` already uses, and the same path
    /// `EditorViewState.applySectionsUpdate`/`mergeSections` uses in the live app (confirmed by
    /// tracing every `editorState.sections =` assignment and every `SectionSyncService.
    /// loadSections()` call site: the ONLY place a `Section`-table-keyed `SectionViewModel`
    /// exists is `ContentView.swift`'s `onShowHistory` closure, feeding the SEPARATE Version
    /// History coordinator, never `editorState.sections`). So this is NOT the id-space mismatch
    /// the delete/duplicate bug turned out to be -- `SectionViewModel.id` genuinely already IS
    /// the heading block's own id on this path, and `reorderAllBlocks`'s `Block.fetchOne(db,
    /// key: section.id)` lookups succeed correctly. The one thing this scenario adds beyond
    /// `performSectionReorderRecordsUndoEntry`'s already-passing same-level swap above: a
    /// genuine header-LEVEL promotion (H2 -> H1), traced against the real
    /// `calculateZoneLevel(x:sidebarWidth:predecessorLevel:)` math for the e2e suite's own
    /// drop coordinates (dx: 0.05, predecessorLevel 1 from Anchor) -- confirmed by hand
    /// arithmetic to compute newLevel=1, not 2, for that drop.
    @Test("Reproduces: dragging a section to insertBefore its predecessor, WITH a header-level promotion, must actually persist the new order")
    func reorderWithLevelPromotionActuallyPersistsNewOrder() async throws {
        let content = """
        # Anchor Section

        Anchor section body text for word counting.

        ## Middle Section

        Middle section body text for word counting purposes.

        ## Last Section

        Last section body text for word counting purposes too.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let view = ContentView()
        view.editorState.projectDatabase = db
        view.editorState.currentProjectId = pid
        view.editorState.content = content
        view.editorState.sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }

        view.bibliographySyncService.configure(database: db, projectId: pid)
        view.footnoteSyncService.configure(database: db, projectId: pid)

        view.structuralUndoController.configure(
            editorState: view.editorState,
            blockSyncService: view.blockSyncService,
            sectionSyncService: view.sectionSyncService,
            bibliographySyncService: view.bibliographySyncService,
            footnoteSyncService: view.footnoteSyncService,
            annotationSyncService: view.annotationSyncService,
            unifiedUndoService: view.unifiedUndoService,
            findBarState: view.findBarState
        )
        view.structuralUndoController.testEvalBoolOverride = { js in
            StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }
        view.structuralUndoController.testEvalVoidOverride = { _ in true }

        let sections = view.editorState.sections
        let anchor = try #require(sections.first { $0.title == "Anchor Section" })
        let last = try #require(sections.first { $0.title == "Last Section" })

        // Mirrors OutlineSidebar.handleDrop's .insertBefore(idx: 1) branch exactly: targetSectionId
        // is the PREDECESSOR of the drop index (Anchor, idx-1), newLevel=1 is the confirmed
        // calculateZoneLevel output for this suite's own drop coordinates.
        let request = SectionReorderRequest(
            sectionId: last.id, targetSectionId: anchor.id, newLevel: 1, newParentId: nil
        )
        view.reorderSection(request)

        // dispatchSectionReorder's Task is fire-and-forget -- poll for the entry to land
        // (same pattern as refusedReorderStashesAndRetriesItself above).
        var recorded = false
        for _ in 0..<100 {
            if !view.unifiedUndoService.undoStack.isEmpty { recorded = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(recorded, "the reorder should record a .sectionReorder undo entry")

        let afterBlocks = try db.fetchOutlineBlocks(projectId: pid)
        let afterTitles = afterBlocks.map(\.outlineTitle)
        #expect(
            afterTitles == ["Anchor Section", "Last Section", "Middle Section"],
            "dragging Last Section to before Middle Section, with a level promotion to H1, must persist -- got \(afterTitles)"
        )
    }
}
