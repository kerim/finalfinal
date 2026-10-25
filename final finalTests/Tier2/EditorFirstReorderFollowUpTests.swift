//
//  EditorFirstReorderFollowUpTests.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9, review round 2: G2, G3, G10, G12, G13, C2a): more of the controller's editor-first drag-reorder, driven the way
//  EditorFirstReorderTests.swift drives it (`ReorderRig`, EditorFirstReorderRig.swift). The scripted editor now carries ITS OWN text
//  through the move instead of rebuilding the document from the database rows, so what the user typed and the database has not seen
//  stays on the screen, and a second move works on the document the first one left.
//
//    G12  typing still waiting at the moment of the click is applied by the click and is still on the screen afterwards;
//    G13  an editor that refuses the click (`planMismatch`, `rootNotFound`) hands the press to the old body in the same gate turn;
//    G2   two drops in a row, the second dispatched while the first holds the gate, each planned on the list the earlier one left;
//    G3   the level a first drag gave a card survives, in the sidebar, into the second drag's order overlay;
//    C2a  a card that arrives in the sidebar's list during the click is kept and placed by the overlay rule;
//    G10  a level that changes between the in-gate plan and the old body's start is kept (`levelsBefore` comes from the gate).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// Bravo's heading row is level 2 with the matching text. A plain (non-async) function: inside an `async` test `dbWriter.write` resolves
/// to GRDB's async overload.
@MainActor
private func makeBravoLevelTwo(_ rig: EditorFirstRig, headingId: String) throws {
    _ = try rig.db.dbWriter.write { database in
        try Block.filter(key: headingId).updateAll(
            database, Block.Columns.headingLevel.set(to: 2), Block.Columns.markdownFragment.set(to: "## Bravo"))
    }
}

@Suite("Editor-first drag-reorder: follow-ups of the review (t-0b70d1e9, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstReorderFollowUpTests: QuickUndoFixtures {

    private static let alphaBravoCharlie = ["Alpha", "Bravo", "Charlie", "Notes"]
    private static let bravoAlphaCharlie = ["Bravo", "Alpha", "Charlie", "Notes"]

    private func makeRig() async throws -> ReorderRig {
        try await ReorderRig.make(markdown: EditorFirstReorderTests.document)
    }

    /// The jobs pin the snapshots they write: unpin everything this rig's project holds when the test ends.
    private func unpinSnapshots(_ rig: EditorFirstRig) {
        for snapshot in (try? SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots()) ?? [] {
            SnapshotService.unpinUndoPointSnapshot(snapshot.id)
        }
    }

    private func row(_ rig: EditorFirstRig, _ text: String) throws -> Block {
        try #require(try rig.blocks().first { $0.textContent == text }, "no block with the text '\(text)'")
    }

    // MARK: - G12

    // G12 (EVERYDAY): the user typed a few words into Bravo, and the editor has not handed them to Swift yet when the drop comes. The
    // click consumes them (the reply's `batch`) and Swift applies them: they reach the database row, and the editor still shows them
    // after the move because the move carries the editor's own text. (A scripted editor that rebuilt its document from the database
    // would lose them from the screen; the red proof that Swift applies the batch is the shared batch handling of the click.)
    @Test("typingStillWaitingAtTheClickIsKept")
    func typingStillWaitingAtTheClickIsKept() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let typedInto = try row(r.rig, "Bravo body one.")
        r.rig.editorText = try r.rig.assembledMarkdown()   // the editor holds the document
        r.clickBatch = try r.typeWithoutHandingItOver(into: typedInto, appending: " WAITING")
        #expect(try row(r.rig, "Bravo body one.").id == typedInto.id, "precondition: the database has not seen the typing")

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        await r.settleThenCarryTyping()

        let applied = try row(r.rig, "Bravo body one. WAITING")
        #expect(applied.id == typedInto.id, "the typing that was waiting at the click went to another row")
        let screen = try #require(r.rig.editorText, "the editor holds no document")
        #expect(screen.contains("Bravo body one. WAITING"), "the move took the waiting typing off the screen: \(screen)")
        #expect(r.editorHeadingTitles == Self.bravoAlphaCharlie, "the sections are not in the new order on the screen")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "the rows are not in the new order")
        let table = try r.rig.assembledMarkdown()
        #expect(
            ReorderRig.contentLines(screen) == ReorderRig.contentLines(table),
            "after quiet, the screen and the table differ:\n\(screen)\n---\n\(table)")
    }

    // MARK: - G13

    // G13 (EVERYDAY): the editor refuses the click (its working order does not fit the plan, or it holds no node for the dragged section
    // yet): nothing moved there, and the SAME press goes on in the same gate turn with the old whole-document body. One entry is
    // recorded and it carries its own snapshot id (the old kind); no editor-first job exists, no overlay is left, and the sidebar and
    // the table are in the new order.
    @Test("anEditorRefusalFallsBackToTheOldBodyInTheSameGateTurn", arguments: ["planMismatch", "rootNotFound"])
    func anEditorRefusalFallsBackToTheOldBodyInTheSameGateTurn(_ reason: String) async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        r.refuseNextClickWith = reason

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        _ = await r.rig.waitUntilSettled()

        #expect(outcome == .performed, "the refused drop ended \(outcome) instead of falling back")
        #expect(r.refusedClicks == [reason], "the editor was not asked exactly once: \(r.refusedClicks)")
        #expect(r.clicks.isEmpty, "the editor moved something although it refused")
        let stack = r.rig.unifiedUndo.undoStack
        #expect(stack.count == 1, "expected exactly one structural entry, got \(stack.count)")
        let entry = try #require(stack.last)
        #expect(entry.kind == .sectionReorder && !entry.isEditorFirst && entry.undoSnapshotId != nil, "the entry is not the old kind: \(entry)")
        #expect(r.rig.editorState.pendingReorder == nil, "an order overlay is left although no editor-first job exists")
        #expect(r.rig.controller.efSlots.slot(entry.id) == nil, "an editor-first slot exists for the fallback")
        #expect(r.rig.editorState.efJobRegistry.outstandingCount == 0 && r.rig.editorState.pendingEditorFirstJobs == 0, "a job was queued")
        #expect(!r.rig.scripts(containing: "beginStructuralOp").isEmpty, "the old body did not run")
        let line = "[EF-STRUCT] reorder fell back to the old path: \(reason)"
        #expect(r.rig.persistedLog.contains { $0.contains(line) }, "no fallback line in this rig's log: \(r.rig.persistedLog)")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie, "the sidebar is not in the new order: \(r.sidebarTitles)")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "the table is not in the new order: \(r.databaseTitles)")
    }

    // MARK: - G2

    private struct Reading: Equatable {
        let sidebar: [String]
        let editor: [String]
        let database: [String]
    }

    private final class Capture {
        var secondDrop: Task<StructuralUndoController.StructuralOpOutcome, Never>?
        var seenClicks = 0
        var readings: [Reading] = []
    }

    // G2 + C4 (EVERYDAY): two drops in a row with the writer held, so no job has run when the second comes. The second is dispatched while
    // the first holds the structural gate (it waits behind it) and was planned against the list from BEFORE the first; there it looks
    // like "already in place" (Alpha is already at the top), which is the shape the drop-time short-circuit used to swallow. Under the gate
    // it is planned again on the list the first drop left, and carried out: after the first, the sidebar, the editor and the (lagging)
    // table read as below; after the second the order is the original again; the jobs then make the table agree.
    @Test("twoDropsInARowEachFollowTheListTheEarlierOneLeft")
    func twoDropsInARowEachFollowTheListTheEarlierOneLeft() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()   // no job runs: the table keeps the original order throughout
        defer { r.rig.release(hold) }
        let stale = r.rig.editorState.sections
        let first = try r.request(moving: "Bravo", after: nil)
        let second = try r.request(moving: "Alpha", after: nil)
        let capture = Capture()
        r.rig.controller.testOrderingSpy = { [unowned r] step in
            r.rig.spyLog.note(step)
            if step == "efClickStart", capture.secondDrop == nil {
                // The first drop has the gate; the second is dispatched now and waits for it.
                capture.secondDrop = Task { @MainActor in await r.drop(second, preGatePlanAgainst: stale) }
            }
            if step == "efRecorded", r.clicks.count > capture.seenClicks {
                capture.seenClicks = r.clicks.count
                capture.readings.append(Reading(sidebar: r.sidebarTitles, editor: r.editorHeadingTitles, database: r.databaseTitles))
            }
        }

        let firstOutcome = await r.drop(first, preGatePlanAgainst: stale)
        let secondOutcome = try #require(await capture.secondDrop?.value, "the second drop was never dispatched")

        #expect(firstOutcome == .performed && secondOutcome == .performed, "the drops ended \(firstOutcome) and \(secondOutcome)")
        #expect(r.clicks.count == 2, "the editor was asked \(r.clicks.count) times: the second drop was swallowed")
        let readings = capture.readings
        #expect(readings.count == 2, "expected a reading after each drop, got \(readings.count)")
        guard readings.count == 2 else { return }
        let held = Self.alphaBravoCharlie
        #expect(
            readings[0] == Reading(sidebar: Self.bravoAlphaCharlie, editor: Self.bravoAlphaCharlie, database: held),
            "after the first drop: \(readings[0])")
        #expect(
            readings[1] == Reading(sidebar: Self.alphaBravoCharlie, editor: Self.alphaBravoCharlie, database: held),
            "after the second drop: \(readings[1])")

        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "an outline read before either job commits: \(r.sidebarTitles)")
        #expect(r.rig.unifiedUndo.undoStack.count == 2, "expected two entries, got \(r.rig.unifiedUndo.undoStack.count)")

        r.rig.release(hold)
        #expect(await r.rig.waitUntilSettled(), "the two jobs did not settle")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.rig.editorState.pendingReorder == nil, "the overlay was not lifted when the last job settled")
        #expect(try r.databaseHeadingTitles() == Self.alphaBravoCharlie, "got \(r.databaseTitles)")
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "got \(r.sidebarTitles)")
        #expect(r.editorHeadingTitles == Self.alphaBravoCharlie, "got \(r.editorHeadingTitles)")
    }

    // MARK: - G3

    // G3 (EVERYDAY): a first drag gives Charlie the level 2 (a sub-section of Alpha); a second drag, before the first job has written
    // that level, moves Bravo to the top. The overlay holds ONE slot and the second replaces the first: its order carries the first one's
    // pending level (the second's own levels win), or an outline read in between would show Charlie as a chapter again. The jobs then
    // write the level once (the second job's own levels are only its own), and the table ends with Charlie at level 2.
    @Test("levelsOfAnEarlierDropSurviveIntoTheNextOverlay")
    func levelsOfAnEarlierDropSurviveIntoTheNextOverlay() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()
        defer { r.rig.release(hold) }

        let firstOutcome = try await r.reorder("Charlie", after: "Alpha", level: 2, asChildOf: "Alpha")
        #expect(firstOutcome == .performed, "the first drop ended \(firstOutcome)")
        #expect(r.sidebarTitles == ["Alpha", "Charlie", "Bravo", "Notes"], "got \(r.sidebarTitles)")
        #expect(r.rig.editorState.sections.first { $0.title == "Charlie" }?.headerLevel == 2, "the first drop did not give Charlie level 2")
        #expect(r.rig.editorText?.contains("\n## Charlie\n") == true, "the editor does not show Charlie as a sub-section")

        let secondOutcome = try await r.reorder("Bravo", after: nil)
        #expect(secondOutcome == .performed, "the second drop ended \(secondOutcome)")
        await r.rig.editorState.refreshSectionsAwaiting()   // neither job has written anything: the table still says level 1
        let charlieCard = try #require(r.rig.editorState.sections.first { $0.title == "Charlie" })
        #expect(r.sidebarTitles == ["Bravo", "Alpha", "Charlie", "Notes"], "got \(r.sidebarTitles)")
        #expect(charlieCard.headerLevel == 2, "the first drop's level was lost from the sidebar by the second: \(charlieCard.headerLevel)")
        #expect(charlieCard.markdownContent.hasPrefix("## "), "Charlie's card text is '\(charlieCard.markdownContent)'")

        r.rig.release(hold)
        #expect(await r.rig.waitUntilSettled(), "the two jobs did not settle")
        await r.rig.editorState.refreshSectionsAwaiting()
        let charlieRow = try r.rig.heading("Charlie")
        #expect(charlieRow.headingLevel == 2 && charlieRow.markdownFragment == "## Charlie", "got \(String(describing: charlieRow.headingLevel))")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "got \(r.databaseTitles)")
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie && r.rig.editorState.sections.first { $0.title == "Charlie" }?.headerLevel == 2)
        #expect(r.rig.editorState.pendingReorder == nil)
    }

    // MARK: - C2a

    // C2a (EVERYDAY): while the editor's JavaScript runs, the outline observation adds a card to the sidebar's list (a heading typed a
    // moment ago, Delta, right after Alpha). The plan was made before and does not have it. After the click the card is still there,
    // placed by the overlay rule: right after the nearest listed section before it in the list as it is (Alpha), which moved.
    @Test("aCardArrivingDuringTheClickIsKeptAndPlacedByTheOverlayRule")
    func aCardArrivingDuringTheClickIsKeptAndPlacedByTheOverlayRule() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()   // the job cannot run, so nothing refreshes the list behind the assertions
        defer { r.rig.release(hold) }
        let delta = SectionViewModel(from: Block(
            id: "typed-delta", projectId: r.rig.pid, sortOrder: 0, blockType: .heading, textContent: "Delta",
            markdownFragment: "# Delta", headingLevel: 1))
        r.onClick = { [unowned r] in
            guard let index = r.rig.editorState.sections.firstIndex(where: { $0.title == "Alpha" }) else { return }
            r.rig.editorState.sections.insert(delta, at: index + 1)
        }

        let outcome = try await r.reorder("Alpha", after: "Bravo")

        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(
            r.sidebarTitles == ["Bravo", "Alpha", "Delta", "Charlie", "Notes"],
            "the card that arrived during the click was dropped or misplaced: \(r.sidebarTitles)")
    }

    // MARK: - G10

    // G10 (EVERYDAY): the old whole-document body (Markdown mode here). Bravo was made a sub-section a moment ago, in the text and in the
    // table; the sidebar still says level 1 when the in-gate plan is made (`levelsBefore` is taken there, from the gate). Before the
    // sequence starts it waits for the running rebuilds, and meanwhile the outline observation catches the card up to level 2. The
    // sequence writes only the levels the PLAN changed relative to `levelsBefore` from the gate: none, so Bravo keeps level 2. Taken at
    // the sequence's start instead, `levelsBefore` would already say 2 and the plan's 1 would be written over it.
    // The seam that lands the refresh between the plan and the sequence: a rebuild task registered with the editor state
    // (`registerRebuildTask`), which the old body waits for after its plan.
    //
    // t-4a8fd8af slice 2 (Markdown drag, round 3a): a Markdown drag now goes editor-first when `MarkdownEditorFirstSwitch` is on (the
    // default). This test is about the OLD body (what it writes when a level changed between the plan and the sequence), which the
    // switch still gives, so it turns the switch off for its body.
    @Test("aLevelChangedBetweenThePlanAndTheOldBodyIsKept")
    func aLevelChangedBetweenThePlanAndTheOldBodyIsKept() async throws {
        let previousSwitch = MarkdownEditorFirstSwitch.enabled
        MarkdownEditorFirstSwitch.enabled = false
        defer { MarkdownEditorFirstSwitch.enabled = previousSwitch }
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let bravo = try r.rig.heading("Bravo")
        try makeBravoLevelTwo(r.rig, headingId: bravo.id)
        r.rig.editorState.content = try r.rig.assembledMarkdown()   // the text the Markdown flush writes agrees with the table
        r.rig.editorState.editorMode = .source
        #expect(r.rig.editorState.sections.first { $0.id == bravo.id }?.headerLevel == 1, "precondition: the sidebar still says level 1")
        let landing = Task { @MainActor [unowned r] in
            // The old body holds the gate and is waiting for the rebuilds: the refresh lands now, after the plan. (Bounded: a drop that
            // never takes the gate must not leave this task, and the test that awaits it, spinning for ever.)
            var spins = 0
            while !r.rig.controller.isPerforming, spins < 20_000 {
                await Task.yield()
                spins += 1
            }
            r.rig.editorState.sections.first { $0.id == bravo.id }?.headerLevel = 2
        }
        r.rig.editorState.registerRebuildTask(landing)

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        await landing.value
        _ = await r.rig.waitUntilSettled()

        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.clicks.isEmpty, "the editor-first road was taken in Markdown mode")
        let row = try r.rig.heading("Bravo")
        #expect(row.headingLevel == 2, "Bravo's level in the table was reset to \(String(describing: row.headingLevel))")
        #expect(row.markdownFragment == "## Bravo", "Bravo's text in the table is '\(row.markdownFragment)'")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "got \(r.databaseTitles)")
    }
}
