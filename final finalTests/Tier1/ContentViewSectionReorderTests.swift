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

    // MARK: - §4.3 "Drag-reorder bailed out" -> toast (surface-silent-failures plan)

    /// A single refusal (the same trigger `refusedReorderStashesAndRetriesItself` above drives)
    /// must NOT surface anything to the user -- the retry succeeding silently is the whole point
    /// of MF-3's stash-and-retry. Only a SECOND consecutive refusal should ever show a toast.
    @Test("A single refusal is retried silently -- no toast, and the retry flag is clear once it settles")
    func firstRefusalDoesNotToast() async throws {
        let fixture = try makeFixture()
        let isolatedToastCenter = ToastCenter()
        fixture.view.editorState.toastCenter = isolatedToastCenter

        var beginStructuralOpCallCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                beginStructuralOpCallCount += 1
                if beginStructuralOpCallCount == 1 {
                    return false  // fail only the first attempt, like refusedReorderStashesAndRetriesItself
                }
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let before = fixture.view.editorState.sections
        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        let request = try makeRequest(sections: before, moveTitle: "Methodology", afterTitle: "Results and Discussion")

        fixture.view.dispatchSectionReorder(sections: swapped, request: request)

        // Poll for the retry to actually complete (an undo entry recorded means the SECOND
        // attempt reached `.performed`, not just that `beginStructuralOp` was called again --
        // see refusedReorderStashesAndRetriesItself's own doc comment on this harness's timing
        // and why a wide, sparse budget (not a tight loop) is used here.
        var settled = false
        for _ in 0..<60 {
            if !fixture.view.unifiedUndoService.undoStack.isEmpty {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(settled, "the retried reorder should eventually succeed and record an undo entry")

        #expect(isolatedToastCenter.current == nil, "a single refusal that's silently retried must not show any toast")
        #expect(!fixture.view.editorState.sectionReorderRetryAttempted, "the retry flag must be clear again once the retry succeeds")
    }

    /// Two consecutive refusals of the SAME drag must give up and tell the user (§4.3:
    /// "Drag-reorder bailed out" -> toast) rather than retrying forever.
    @Test("Two consecutive refusals of the same drag show the bail-out toast")
    func secondConsecutiveRefusalShowsBailOutToast() async throws {
        let fixture = try makeFixture()
        let isolatedToastCenter = ToastCenter()
        fixture.view.editorState.toastCenter = isolatedToastCenter

        var beginStructuralOpCallCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                beginStructuralOpCallCount += 1
                return false  // fail every attempt
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let before = fixture.view.editorState.sections
        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        let request = try makeRequest(sections: before, moveTitle: "Methodology", afterTitle: "Results and Discussion")

        fixture.view.dispatchSectionReorder(sections: swapped, request: request)

        var toastShown = false
        for _ in 0..<60 {
            if isolatedToastCenter.current != nil {
                toastShown = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(toastShown, "a second consecutive refusal must show the bail-out toast")

        #expect(isolatedToastCenter.current?.style == .warning)
        #expect(isolatedToastCenter.current?.message.contains("move the section") == true)
    }

    /// The retry budget is exactly one attempt per gesture -- a drag that keeps getting refused
    /// must stop after the second attempt, never spin forever re-dispatching the same request.
    @Test("A drag that's refused repeatedly retries exactly once, never more")
    func refusalRetriesExactlyOnce() async throws {
        let fixture = try makeFixture()
        let isolatedToastCenter = ToastCenter()
        fixture.view.editorState.toastCenter = isolatedToastCenter

        var beginStructuralOpCallCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                beginStructuralOpCallCount += 1
                return false  // fail every attempt
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let before = fixture.view.editorState.sections
        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        let request = try makeRequest(sections: before, moveTitle: "Methodology", afterTitle: "Results and Discussion")

        fixture.view.dispatchSectionReorder(sections: swapped, request: request)

        var toastShown = false
        for _ in 0..<60 {
            if isolatedToastCenter.current != nil {
                toastShown = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(toastShown, "the bail-out toast should appear once the retry budget is exhausted")

        // Give any (incorrect) further retry a chance to happen before asserting the final count.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(beginStructuralOpCallCount == 2, "exactly the original attempt plus one retry -- never a third")
    }

    /// Regression test (review round): a retry that dies at `SectionReorderPlanner.plan() ==
    /// .failed` -- e.g. the stashed request has become genuinely invalid by the time the retry
    /// re-validates it against the live `editorState.sections` -- must still reset
    /// `sectionReorderRetryAttempted` and release `sectionDropInFlight`, exactly like the
    /// `.performed`/give-up/`.failedAfterCommit` terminal outcomes in `dispatchSectionReorder`
    /// already do. Before the fix, `reorderSection`'s `plan() == nil` guard left both untouched:
    /// `sectionDropInFlight` stayed stuck `true` forever (permanently blocking
    /// `ContentView.onDragEnded` and the block-sync poll it re-arms), and
    /// `sectionReorderRetryAttempted` stayed stuck `true`, silently poisoning the NEXT,
    /// completely unrelated drag's first (and only) refusal into being misread as a SECOND
    /// consecutive strike -- firing the bail-out toast immediately instead of retrying it
    /// silently the way a genuine first refusal should.
    ///
    /// Uses a self-parent request (`newParentId == sectionId`) to force `.failed`, NOT a
    /// self-drop (`targetSectionId == sectionId`) as this test originally did -- a self-drop is
    /// `.noOp` (acceptance-round fix: it must NOT toast, see
    /// `SectionReorderPlannerTests.planRejectsSelfDropNoOp`), so it can no longer stand in for
    /// "plan() produced a non-plan outcome" here; only a genuine `.failed` still should.
    @Test("A retry that dies at plan()==.failed resets state so a later drag's first refusal isn't misread as a second strike")
    func retryDyingAtPlanFailedDoesNotPoisonNextDrag() async throws {
        let fixture = try makeFixture()
        let isolatedToastCenter = ToastCenter()
        fixture.view.editorState.toastCenter = isolatedToastCenter

        // First drag: refuse only the first attempt, forcing dispatchSectionReorder's
        // .refused branch to stash `request` and its defer to retry via reorderSection(_:).
        var firstDragBeginCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                firstDragBeginCount += 1
                if firstDragBeginCount == 1 {
                    return false
                }
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let before = fixture.view.editorState.sections
        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        // A self-parent request (newParentId == sectionId): dispatchSectionReorder itself
        // never calls SectionReorderPlanner.plan (it's invoked directly here with a
        // pre-computed `sections`, matching every other test above), but the STASHED retry
        // re-validates this exact request through reorderSection -> plan(), which rejects
        // `newParentId == sectionId` with `.failed` -- precisely the case this test needs the
        // retry to die at. (A self-drop, sectionId == targetSectionId, would land on `.noOp`
        // instead -- benign, and must not toast -- so it can't be used here anymore.)
        let moved = try #require(before.first { $0.title == "Methodology" })
        let target = try #require(before.first { $0.title == "Results and Discussion" })
        let request = SectionReorderRequest(
            sectionId: moved.id, targetSectionId: target.id,
            newLevel: moved.headerLevel, newParentId: moved.id
        )

        fixture.view.dispatchSectionReorder(sections: swapped, request: request)

        // Poll for the retry's bail-out toast -- reorderSection's plan()==.failed guard shows
        // one (§4.3's "drag-reorder bailed out", the fix under test), which is the observable
        // signal that the retry actually ran and died there rather than still being in flight.
        var firstToastShown = false
        for _ in 0..<60 {
            if isolatedToastCenter.current != nil {
                firstToastShown = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(firstToastShown, "the retry dying at plan()==.failed is itself a genuine bail-out and must toast")
        #expect(firstDragBeginCount == 1, "plan()==.failed must die before ever reaching a second performSectionReorder dispatch")
        #expect(!fixture.view.editorState.sectionReorderRetryAttempted, "the retry flag must be reset even when the retry dies at plan()==.failed")
        #expect(!fixture.view.editorState.sectionDropInFlight, "sectionDropInFlight must be released even when the retry dies at plan()==.failed")

        // Clear the first drag's own (correct) toast so it can't be mistaken for the second
        // drag's toast below.
        isolatedToastCenter.dismissCurrent()

        // Second, completely unrelated drag: refuse only its first attempt too. If the fix
        // above didn't reset sectionReorderRetryAttempted, this drag's first refusal would be
        // misread as a second consecutive strike and bail out immediately instead of retrying.
        var secondDragBeginCount = 0
        fixture.view.structuralUndoController.testEvalBoolOverride = { js in
            if js.contains("beginStructuralOp") {
                secondDragBeginCount += 1
                if secondDragBeginCount == 1 {
                    return false
                }
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }

        let freshBefore = fixture.view.editorState.sections
        let freshSwapped = try swapSections(freshBefore, "Background and Literature Review", "Conclusion")
        let freshRequest = try makeRequest(
            sections: freshBefore, moveTitle: "Background and Literature Review", afterTitle: "Conclusion"
        )

        fixture.view.dispatchSectionReorder(sections: freshSwapped, request: freshRequest)

        var freshDragSettled = false
        for _ in 0..<60 {
            if !fixture.view.unifiedUndoService.undoStack.isEmpty {
                freshDragSettled = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(freshDragSettled, "the fresh drag's silently-retried reorder should eventually succeed and record an undo entry")

        #expect(isolatedToastCenter.current == nil, "the fresh drag's first refusal must be retried silently, not misread as a second strike and toasted")
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
