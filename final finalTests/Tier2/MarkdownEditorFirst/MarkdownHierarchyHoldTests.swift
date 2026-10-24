//
//  MarkdownHierarchyHoldTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 4, O6 / T-U16: the hierarchy-enforcement push in
//  Markdown mode (`ContentView.enforceHierarchyAsync` -> `applyHeadingChangesViaStringReplacement`, which rewrites the content
//  record's text and the editor's source text, a whole-text push) used to run on any idle `onSectionsUpdated`, with no regard for an
//  unapplied Markdown structural command. It writes heading levels into the rows and rewrites the text from the content record, so
//  while the writer's hold is up it must not run; the release runs the handler again.
//
//  Drives the REAL handler (`ContentView.makeSectionsUpdatedHandler`) on a real editor state in Markdown mode.
//
//   BREAK 1: delete the `guard !editorState.markdownWriter.isHeldForStructuralWork else {...}` block in `makeSectionsUpdatedHandler`
//   (ContentView+ProjectLifecycle.swift).    FAILS with: "enforced the hierarchy while a Markdown structural command was unapplied".
//   BREAK 2: delete only its `afterNextRelease` line.    FAILS with: "enforcement did not run again after the release".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown hierarchy enforcement waits for an unapplied structural command — Tier 2 (t-4a8fd8af round 4, T-U16)",
       .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownHierarchyHoldTests {

    /// A level-3 heading straight after a level-1 heading: a hierarchy violation (the clamp makes it level 2).
    private static let violating = "# Alpha\n\nOne.\n\n### Gamma\n\nThree."

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("T-U16: the sections-updated handler skips enforcement while the writer's hold is up, and runs it when the hold is released")
    func hierarchyEnforcementWaitsForTheHold() async throws {
        let rig = try MarkdownWriterRig(content: Self.violating)
        let editorState = rig.editorState
        let syncService = SectionSyncService()   // the handler holds it weakly
        let handler = ContentView.makeSectionsUpdatedHandler(for: editorState, syncService: syncService)
        editorState.onSectionsUpdated = handler   // as ContentView installs it
        editorState.sections = try rig.db.fetchOutlineBlocks(projectId: rig.pid).map { SectionViewModel(from: $0) }
        let levelsBefore = editorState.sections.map(\.headerLevel)
        func enforced() -> Bool { editorState.sections.map(\.headerLevel) != levelsBefore }
        try #require(ContentView.hasHierarchyViolations(in: editorState.sections), "premise: the list violates the hierarchy")
        try #require(editorState.contentState == .idle, "premise: nothing else holds the handler back")

        let hold = rig.markdownWriter.beginStructuralHold()   // a Markdown structural command is unapplied
        defer { hold.release() }
        handler()
        let enforcedWhileHeld = await waitUntil { enforced() || editorState.contentState != .idle }
        #expect(!enforcedWhileHeld, "enforced the hierarchy while a Markdown structural command was unapplied")

        hold.release()
        let enforcedAfterRelease = await waitUntil { enforced() }
        #expect(enforcedAfterRelease, "enforcement did not run again after the release")
    }

    @Test("control: with no hold the same handler enforces at once (the guard changes nothing for Rich Text or an idle Markdown editor)")
    func noHoldNoChange() async throws {
        let rig = try MarkdownWriterRig(content: Self.violating)
        let editorState = rig.editorState
        let syncService = SectionSyncService()
        let handler = ContentView.makeSectionsUpdatedHandler(for: editorState, syncService: syncService)
        editorState.sections = try rig.db.fetchOutlineBlocks(projectId: rig.pid).map { SectionViewModel(from: $0) }
        let levelsBefore = editorState.sections.map(\.headerLevel)
        handler()
        let enforced = await waitUntil { editorState.sections.map(\.headerLevel) != levelsBefore }
        #expect(enforced, "control: the handler must enforce when nothing is held")
    }
}
