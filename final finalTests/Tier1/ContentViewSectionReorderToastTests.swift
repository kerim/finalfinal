//
//  ContentViewSectionReorderToastTests.swift
//  final finalTests
//
//  Split out of ContentViewSectionReorderTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full Phase 7 /
//  review round MF-3/MF-4 background. This file covers §4.3's "drag-reorder bailed out" toast
//  (single refusal stays silent, a second consecutive refusal surfaces the toast, a retry never
//  fires more than once, and a later drag's first refusal isn't misread as a second strike) plus
//  the level-promotion reproduction case, using the shared `makeFixture()` / `swapSections()` /
//  `makeRequest()` helpers defined in ContentViewSectionReorderTests.swift.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ContentViewSectionReorderTests {

    // MARK: - §4.3 "Drag-reorder bailed out" -> toast (surface-silent-failures plan)

    /// A single refusal (the same trigger `refusedReorderStashesAndRetriesItself`, defined in
    /// ContentViewSectionReorderTests.swift, drives) must NOT surface anything to the user --
    /// the retry succeeding silently is the whole point
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

        #expect(
            isolatedToastCenter.current == nil,
            "the fresh drag's first refusal must be retried silently, not misread as a second strike and toasted"
        )
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
    /// `performSectionReorderRecordsUndoEntry`'s already-passing same-level swap (StructuralUndoControllerTests.swift): a
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
        // (same pattern as refusedReorderStashesAndRetriesItself, ContentViewSectionReorderTests.swift).
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
