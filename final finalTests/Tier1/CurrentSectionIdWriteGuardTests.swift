//
//  CurrentSectionIdWriteGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  bt t-fecee361 (narrow ContentView.body's @Observable reads to cut per-keystroke full-tree
//  redraws): `EditorViewState.currentSectionId` used to be written unconditionally, at both
//  `ContentView+ContentRebuilding.swift` call sites, from `resolveSectionId(blockId:title:)`'s
//  result -- on essentially every content push from either editor. `@Observable` fires on any
//  write, same value included, and `ContentView.body` reads `currentSectionId` (through
//  `OutlineSidebarPane`'s construction), so that unconditional write redrew the whole view tree
//  per keystroke. `setCurrentSectionId(blockId:title:)` (EditorViewState+EditorControls.swift) is
//  the guarded replacement: it only actually writes `currentSectionId` when the resolved value is
//  a genuine change, treating a transient nil resolution (mid-reparse) as "unknown, keep the
//  previous id" unless that previous id is no longer a real section.
//
//  These tests observe the guard directly via `withObservationTracking`, matching
//  `OutlineSidebarRenderKeyTests.swift`'s stated limit on what a unit test can and can't prove:
//  they show the GUARD correctly distinguishes a real write from a same-value/transient-nil
//  no-op, not that SwiftUI's diffing behavior itself skips a re-render as a result.
//

import Testing
import Foundation
import os
@testable import final_final

@MainActor
@Suite("currentSectionId write guard — Tier 1: Silent Killers")
struct CurrentSectionIdWriteGuardTests {

    // MARK: - Helpers

    private func makeSection(id: String, title: String) -> SectionViewModel {
        SectionViewModel(from: Section(
            id: id,
            projectId: "test-project",
            sortOrder: 0,
            headerLevel: 1,
            title: title
        ))
    }

    /// Registers `withObservationTracking` on `editorState.currentSectionId`, runs `mutate`, and
    /// reports whether the observation fired -- i.e. whether `currentSectionId` was actually
    /// WRITTEN. `@Observable` fires on any write, same value included, so "fired" here means
    /// "a write happened", which is exactly the thing `setCurrentSectionId` is meant to avoid
    /// except when the value is genuinely changing.
    private func observesFire(_ editorState: EditorViewState, mutate: () -> Void) -> Bool {
        // `onChange` below is `@Sendable () -> Void`: a captured `var` would compile today only
        // because delivery happens synchronously in this test. Under Swift 6 that's a "mutation
        // of captured var in concurrently-executing code" error, and even short of that it's
        // migration debt -- if delivery ever stopped being synchronous, an unsynchronized var
        // could be read before it's set, turning a real regression into a silent false PASS.
        // `OSAllocatedUnfairLock` is this codebase's existing idiom for a Sendable-safe mutable
        // flag (see `DiagnosticLogFile.enabledCache`), and matches
        // `ObservableListDiffTests.swift`'s use of the same pattern for the same reason.
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = editorState.currentSectionId
        } onChange: {
            fired.withLock { $0 = true }
        }
        mutate()
        return fired.withLock { $0 }
    }

    // MARK: - Case 1: same-value repeat

    @Test("same-value re-resolve does not fire observation")
    func sameValueReResolveDoesNotFire() {
        let editorState = EditorViewState()
        editorState.sections = [makeSection(id: "a", title: "Alpha")]
        editorState.currentSectionId = "a"

        let fired = observesFire(editorState) {
            editorState.setCurrentSectionId(blockId: "a", title: "Alpha")
        }
        #expect(!fired, "resolving to the id already stored must not write currentSectionId")
        #expect(editorState.currentSectionId == "a")
    }

    // MARK: - Case 2: genuinely different section

    @Test("resolving to a genuinely different section fires observation")
    func genuinelyDifferentSectionFires() {
        let editorState = EditorViewState()
        editorState.sections = [makeSection(id: "a", title: "Alpha"), makeSection(id: "b", title: "Beta")]
        editorState.currentSectionId = "a"

        let fired = observesFire(editorState) {
            editorState.setCurrentSectionId(blockId: "b", title: "Beta")
        }
        #expect(fired, "resolving to a different section must write currentSectionId")
        #expect(editorState.currentSectionId == "b")
    }

    // MARK: - Case 3: transient nil-resolve, previous section still present

    @Test("nil-resolve while the previous section is still present does not fire and leaves currentSectionId unchanged")
    func nilResolveWithPreviousSectionStillPresentDoesNotFire() {
        let editorState = EditorViewState()
        editorState.sections = [makeSection(id: "a", title: "Alpha")]
        editorState.currentSectionId = "a"

        let fired = observesFire(editorState) {
            // Neither blockId nor title matches any section -- the transient mid-reparse nil
            // resolveSectionId(blockId:title:) returns routinely, per its own doc comment.
            editorState.setCurrentSectionId(blockId: nil, title: "Unresolvable Title")
        }
        #expect(!fired, "an unresolvable caret must not overwrite a still-valid previous section id")
        #expect(editorState.currentSectionId == "a")
    }

    // MARK: - Case 4: nil-resolve after the previous section is gone

    @Test("nil-resolve after the previous section is removed fires and currentSectionId becomes nil")
    func nilResolveAfterPreviousSectionRemovedFires() {
        let editorState = EditorViewState()
        editorState.sections = [makeSection(id: "a", title: "Alpha")]
        editorState.currentSectionId = "a"
        // The user deleted the section the caret was in.
        editorState.sections = []

        let fired = observesFire(editorState) {
            editorState.setCurrentSectionId(blockId: nil, title: "Unresolvable Title")
        }
        #expect(fired, "an unresolvable caret must clear currentSectionId once the previous section is gone")
        #expect(editorState.currentSectionId == nil)
    }
}
