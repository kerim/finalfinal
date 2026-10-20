//
//  SidebarReorderOverlayTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, plan U7): what the Outline sidebar shows between an editor-first drag-reorder and the moment its queued job has
//  renumbered the rows. Every outline result that arrives in that window still carries the OLD row order; `EditorViewState.
//  withoutPendingRemovals` (the one function every outline result goes through) puts it into the order the editor already shows.
//  Pure: plain `Block`s in, plain `Block`s out, no database and no editor.
//
//  The rule (SidebarReorderOverlay.swift): the pending removals filter first and always win; the listed leaders come in `order` order;
//  an unlisted leader (a heading typed a moment ago, one the sidebar did not list when the plan was made) hangs after the nearest listed
//  leader before it in the INCOMING order, or goes first when none comes before it; Notes then Bibliography come last whatever
//  `order` says; every `sortOrder` is renumbered 0, 1, 2...; a listed heading with a planned level takes it, `#` prefix included;
//  the overlay never adds an id the incoming list lacks.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("SidebarReorderOverlay — the outline read before the reorder job commits (Tier 1)")
@MainActor
struct SidebarReorderOverlayTests {

    private func heading(_ id: String, level: Int = 1, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: id, projectId: "p", sortOrder: 0, blockType: .heading, textContent: id,
            markdownFragment: String(repeating: "#", count: level) + " " + id, headingLevel: level,
            isBibliography: bibliography, isNotes: notes)
    }

    /// The database's order BEFORE the reorder job: P is a heading in the preamble the plan did not list, X a heading after A the plan did
    /// not list (typed a moment ago), then B, C, and the managed sections last (Bibliography after Notes, as `fetchOutlineBlocks`
    /// sorts them).
    private var incoming: [Block] {
        [
            heading("P"), heading("A"), heading("X"), heading("B"), heading("C"),
            heading("Notes", notes: true), heading("Bibliography", bibliography: true)
        ]
    }

    // U7: overlay [B, A, C] with B going to level 2. P sits first (nothing listed before it), X travels with A (the nearest listed
    // leader before it), Notes and Bibliography stay last, sort orders run 0...6, and B's card shows level 2 with a `##` prefix.
    // With A removed by a later delete, A stays gone, and X (which hung after A) keeps A's slot in the order: P, B, X, C. The anchors are
    // worked out on the list BEFORE the removal (G1), so deleting a card never re-parents the cards that were hanging after it.
    @Test("outlineReadBeforeCommitFollowsRule")
    func outlineReadBeforeCommitFollowsRule() throws {
        let state = EditorViewState()
        state.pendingReorder = PendingReorder(opId: UUID(), order: ["B", "A", "C"], levels: ["B": 2])

        let shown = state.withoutPendingRemovals(incoming)
        #expect(shown.map(\.id) == ["P", "B", "A", "X", "C", "Notes", "Bibliography"], "got \(shown.map(\.id))")
        #expect(shown.map(\.sortOrder) == (0...6).map(Double.init), "sort orders were not renumbered 0...6: \(shown.map(\.sortOrder))")
        let b = try #require(shown.first { $0.id == "B" })
        #expect(b.headingLevel == 2, "B's card should show the planned level 2, got \(String(describing: b.headingLevel))")
        #expect(b.markdownFragment.hasPrefix("## "), "B's fragment should start with '## ', got '\(b.markdownFragment)'")
        let a = try #require(shown.first { $0.id == "A" })
        #expect(a.headingLevel == 1 && a.markdownFragment == "# A", "A has no planned level and must be left alone")
        // The Bibliography card must still be there right after a drag (binding extras 3 and 5), last, after Notes.
        #expect(shown.last?.isBibliography == true && shown.dropLast().last?.isNotes == true, "Notes then Bibliography must end the outline")

        state.pendingRemovalIds = ["A"]
        let afterDelete = state.withoutPendingRemovals(incoming)
        #expect(!afterDelete.map(\.id).contains("A"), "a section deleted after the drag came back: \(afterDelete.map(\.id))")
        #expect(
            afterDelete.map(\.id) == ["P", "B", "X", "C", "Notes", "Bibliography"],
            "the removal must win, X must keep A's slot after B, and the rest follow the rule, got \(afterDelete.map(\.id))")
        #expect(afterDelete.last?.isBibliography == true, "the Bibliography card was lost")
    }

    // G1, the other half: the removed listed leader had NOTHING hanging after it, so its removal only takes its own card out; every other
    // card stays where the order puts it.
    @Test("removingAListedLeaderWithNothingHangingAfterItJustTakesItOut")
    func removingAListedLeaderWithNothingHangingAfterItJustTakesItOut() {
        let state = EditorViewState()
        state.pendingReorder = PendingReorder(opId: UUID(), order: ["B", "A", "C"], levels: [:])
        let blocks = [
            heading("P"), heading("A"), heading("B"), heading("C"),
            heading("Notes", notes: true), heading("Bibliography", bibliography: true)
        ]
        state.pendingRemovalIds = ["A"]

        let shown = state.withoutPendingRemovals(blocks)
        #expect(shown.map(\.id) == ["P", "B", "C", "Notes", "Bibliography"], "got \(shown.map(\.id))")
        #expect(shown.map(\.sortOrder) == (0...4).map(Double.init), "sort orders were not renumbered 0...4: \(shown.map(\.sortOrder))")
    }

    // C1, the sidebar's half: the bibliography and Notes rebuilds give their rows fresh ids. A plan made with the OLD ids still lists
    // them, and the outline result now carries the NEW ones: the new Notes and Bibliography cards are managed cards (flagged), so they
    // end the outline, Notes first, whatever ids the order names.
    @Test("rebuiltNotesAndBibliographyKeepTheEndOfTheOutline")
    func rebuiltNotesAndBibliographyKeepTheEndOfTheOutline() {
        let state = EditorViewState()
        state.pendingReorder = PendingReorder(
            opId: UUID(), order: ["C", "A", "B", "Notes-old", "Bibliography-old"], levels: [:])
        let rebuilt = [
            heading("A"), heading("B"), heading("C"),
            heading("Notes-new", notes: true), heading("Bibliography-new", bibliography: true)
        ]

        let shown = state.withoutPendingRemovals(rebuilt)
        #expect(shown.map(\.id) == ["C", "A", "B", "Notes-new", "Bibliography-new"], "got \(shown.map(\.id))")
    }

    // `order` is the editor's working order of section leaders: Notes and Bibliography are not part of what the overlay moves, and even
    // an `order` that names them (or names an id the outline lacks) must not move them or add anything.
    @Test("notesAndBibliographyStayLastAndNothingIsAdded")
    func notesAndBibliographyStayLastAndNothingIsAdded() {
        let state = EditorViewState()
        state.pendingReorder = PendingReorder(
            opId: UUID(), order: ["Bibliography", "Notes", "C", "B", "A", "Z-not-in-the-outline"], levels: [:])

        let shown = state.withoutPendingRemovals(incoming)
        #expect(
            shown.map(\.id) == ["P", "C", "B", "A", "X", "Notes", "Bibliography"],
            "managed sections must end the outline, Notes first, and an id the outline lacks is not added: \(shown.map(\.id))")
    }

    // With no reorder pending (the normal case) and nothing else to merge, the outline result is returned untouched.
    @Test("noPendingReorderLeavesTheOutlineAlone")
    func noPendingReorderLeavesTheOutlineAlone() {
        let state = EditorViewState()
        let blocks = incoming
        #expect(state.withoutPendingRemovals(blocks) == blocks)
    }
}
