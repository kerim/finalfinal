//
//  OutlineRefreshStalenessTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Phase 6 (numbered sidebar snapshots). The sidebar shows a snapshot only if its number is higher than the one it already shows
//  (`EditorViewState.acceptOutlineSnapshot`), so an older reading can never land on top of a newer one. This file used to guard the
//  `outlineGeneration` counter and the `RefreshSignal` chain that did the same job by counting; the cases are the same ones, now
//  decided by the numbers. `OutlineSnapshotPublisherTests` covers the reader itself.
//
//  What the sidebar does with a snapshot besides the number check:
//   - a tick is skipped while `contentState != .idle`, an explicit refresh is not;
//   - an explicit snapshot is dropped if anything wrote `sections` locally since the call (hierarchy enforcement's level fix, the
//     old reorder path), a tick is not;
//   - the overlays (`pendingRemovalIds` and the others) are merged in when the snapshot is shown, not when it was read.
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite("Outline Refresh Staleness — Tier 1: Silent Killers")
struct OutlineRefreshStalenessTests {

    private func heading(_ id: String, _ order: Double, level: Int = 1,
                         text: String = "Title") -> Block {
        Block(id: id, projectId: "p", sortOrder: order, blockType: .heading,
              textContent: text,
              markdownFragment: String(repeating: "#", count: level) + " " + text,
              headingLevel: level)
    }

    private func counts(_ pairs: [String: Int]) -> [String: ProjectDatabase.HeadingWordCounts] {
        pairs.mapValues { .init(sectionOnly: $0, aggregate: $0) }
    }

    /// A state wired to a temporary project, with its publisher made by one explicit refresh (so no commit observation runs and
    /// the tests below decide exactly which snapshots arrive).
    private struct Rig {
        let state: EditorViewState
        let db: ProjectDatabase
        let pid: String
    }

    private func makeState(content: String = "# Original Heading\n\nBody.") async throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid
        await state.refreshSectionsAwaiting()
        return Rig(state: state, db: db, pid: pid)
    }

    private func snapshot(
        _ state: EditorViewState, rev: Int, titles: [String], projectId: String? = nil, publisherId: UUID? = nil
    ) -> OutlineSnapshot {
        let blocks = titles.enumerated().map { index, title in heading("snap-\(title)-\(index)", Double(index), text: title) }
        return OutlineSnapshot(
            rev: rev,
            publisherId: publisherId ?? state.outlinePublisher?.id ?? UUID(),
            projectId: projectId ?? state.currentProjectId ?? "",
            blocks: blocks,
            counts: counts(Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, 10) }))
        )
    }

    // MARK: - The number rule

    @Test("A snapshot numbered above the one shown is shown")
    func higherNumberIsShown() async throws {
        let state = try await makeState().state
        #expect(state.sections.map(\.title) == ["Original Heading"])
        let shown = state.shownOutlineRev

        #expect(state.acceptOutlineSnapshot(snapshot(state, rev: shown + 5, titles: ["Newer"]), source: .tick))
        #expect(state.sections.map(\.title) == ["Newer"])
        #expect(state.shownOutlineRev == shown + 5)
    }

    @Test("A snapshot numbered below or equal to the one shown is refused and counted")
    func lowerOrEqualNumberIsRefused() async throws {
        let state = try await makeState().state
        state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["Newer"]), source: .tick)

        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 4, titles: ["Older"]), source: .tick))
        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["Same number"]), source: .tick))
        #expect(state.sections.map(\.title) == ["Newer"])
        #expect(state.staleOutlineDropCount == 2)
        #expect(state.shownOutlineRev == 10)
    }

    @Test("A snapshot from another publisher, or for another project, is ignored without a trace")
    func foreignSnapshotIsIgnored() async throws {
        let state = try await makeState().state
        let titlesBefore = state.sections.map(\.title)

        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 99, titles: ["Foreign"], publisherId: UUID()), source: .tick))
        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 99, titles: ["Other project"], projectId: "other"), source: .tick))
        #expect(state.sections.map(\.title) == titlesBefore)
        #expect(state.staleOutlineDropCount == 0)
    }

    @Test("A stale explicit refresh still calls onSectionsUpdated (the sequences run hierarchy enforcement from it); a stale tick does not")
    func staleExplicitStillCallsTheCallback() async throws {
        let state = try await makeState().state
        state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["Newer"]), source: .tick)
        var calls = 0
        state.onSectionsUpdated = { calls += 1 }

        state.acceptOutlineSnapshot(snapshot(state, rev: 3, titles: ["Older"]), source: .tick)
        #expect(calls == 0)
        state.acceptOutlineSnapshot(snapshot(state, rev: 3, titles: ["Older"]),
                                    source: .explicit(sectionsWritesAtCall: state.localSectionsWriteCount))
        #expect(calls == 1)
        #expect(state.sections.map(\.title) == ["Newer"])
    }

    // MARK: - Tick and explicit differ in two ways

    @Test("A tick is skipped while the editor is not idle; an explicit refresh is not")
    func tickIsSkippedWhileNotIdle() async throws {
        let state = try await makeState().state
        state.contentState = .zoomTransition

        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["Tick"]), source: .tick))
        #expect(state.shownOutlineRev < 10)
        #expect(state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["Explicit"]),
                                            source: .explicit(sectionsWritesAtCall: state.localSectionsWriteCount)))
        #expect(state.sections.map(\.title) == ["Explicit"])
        // A skipped tick is not counted as stale: it was never old, it was early.
        #expect(state.staleOutlineDropCount == 0)
    }

    @Test("An explicit snapshot is dropped after a local write to sections; a tick is not")
    func explicitIsDroppedAfterALocalWrite() async throws {
        let state = try await makeState().state
        let writesAtCall = state.localSectionsWriteCount
        // Hierarchy enforcement's level fix, the old reorder path's mutate closure: sections written ahead of the database.
        state.sections = Array(state.sections.reversed())
        #expect(state.localSectionsWriteCount == writesAtCall + 1)

        #expect(!state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["Read before the change"]),
                                             source: .explicit(sectionsWritesAtCall: writesAtCall)))
        #expect(state.staleOutlineDropCount == 1)
        // The old observation never dropped a tick for a local write, and still does not.
        #expect(state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["Tick"]), source: .tick))
        #expect(state.sections.map(\.title) == ["Tick"])
    }

    @Test("Showing a snapshot is not a local write")
    func showingASnapshotIsNotALocalWrite() async throws {
        let state = try await makeState().state
        let writes = state.localSectionsWriteCount
        state.acceptOutlineSnapshot(snapshot(state, rev: 10, titles: ["A", "B"]), source: .tick)
        state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["A"]), source: .tick)
        #expect(state.localSectionsWriteCount == writes)
    }

    // MARK: - Overlays

    @Test("The removal overlay is merged in when the snapshot is shown, even if it was set after the snapshot was read")
    func removalOverlayIsMergedAtAcceptTime() async throws {
        let state = try await makeState().state
        let reading = snapshot(state, rev: 10, titles: ["Keep", "Remove me"])
        // The overlay is set AFTER the reading was taken (the editor-first Delete Section click) and BEFORE it is shown.
        let removedId = try #require(reading.blocks.last?.id)
        state.pendingRemovalIds = [removedId]

        #expect(state.acceptOutlineSnapshot(reading, source: .tick))
        #expect(state.sections.map(\.title) == ["Keep"], "the deleted section must not come back from a reading taken before the click")

        // Once the overlay is lifted, a later reading shows what the database holds.
        state.pendingRemovalIds = []
        state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["Keep", "Remove me"]), source: .tick)
        #expect(state.sections.map(\.title) == ["Keep", "Remove me"])
    }

    @Test("The restore overlay (a quick undo's section not yet in the database) is merged in at its anchor, whenever the reading was taken")
    func restoreOverlayIsMergedAtAcceptTime() async throws {
        let state = try await makeState().state
        // The reading the database gave: the restored section is not in it yet.
        let reading = snapshot(state, rev: 10, titles: ["A", "C"])
        let anchorId = try #require(reading.blocks.first?.id)
        let entry = UUID()
        state.pendingRestoreSections[entry] = [heading("restored-b", 1, text: "B")]
        state.pendingRestoreAnchors[entry] = .after(anchorId)

        #expect(state.acceptOutlineSnapshot(reading, source: .tick))
        #expect(state.sections.map(\.title) == ["A", "B", "C"], "the restored section sits after its anchor, not where its old sort order says")

        // Once the database has the rows back and the overlay is lifted, the reading alone gives the same list.
        state.pendingRestoreSections[entry] = nil
        state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["A", "C"]), source: .tick)
        #expect(state.sections.map(\.title) == ["A", "C"])
    }

    @Test("The reorder overlay (a drag the database has not renumbered yet) puts a reading into the order the editor shows")
    func reorderOverlayIsMergedAtAcceptTime() async throws {
        let state = try await makeState().state
        // The database still has the old order A, B; the editor already shows B, A.
        let reading = snapshot(state, rev: 10, titles: ["A", "B"])
        let ids = reading.blocks.map(\.id)
        state.pendingReorder = PendingReorder(opId: UUID(), order: [ids[1], ids[0]], levels: [:])

        #expect(state.acceptOutlineSnapshot(reading, source: .tick))
        #expect(state.sections.map(\.title) == ["B", "A"], "an old-order reading must not put the cards back")

        state.pendingReorder = nil
        state.acceptOutlineSnapshot(snapshot(state, rev: 11, titles: ["B", "A"]), source: .tick)
        #expect(state.sections.map(\.title) == ["B", "A"])
    }

    // MARK: - Explicit refresh

    @Test("A refresh with no publisher makes one and fills the sidebar")
    func refreshWithNoPublisherFillsTheSidebar() async throws {
        let state = try await makeState(content: "# Real Heading\n\nBody.").state
        #expect(state.sections.map(\.title) == ["Real Heading"])
        #expect(state.outlinePublisher != nil)
    }

    @Test("A refresh with no database returns at once and changes nothing")
    func refreshWithNoDatabaseReturns() async throws {
        let state = EditorViewState()
        await state.refreshSectionsAwaiting()
        #expect(state.sections.isEmpty)
        #expect(state.staleOutlineDropCount == 0)
    }

    @Test("A refresh sees a write that finished before the call")
    func refreshSeesAnEarlierWrite() async throws {
        let rig = try await makeState()
        let state = rig.state
        let db = rig.db
        let pid = rig.pid
        var newer = heading("newer-1", 0, level: 1, text: "Newer Heading")
        newer.projectId = pid
        try db.replaceBlocks([newer], for: pid)

        await state.refreshSectionsAwaiting()
        #expect(state.sections.map(\.title) == ["Newer Heading"])
    }

    @Test("Two refreshes that overlap both finish, and the sidebar ends on the database")
    func twoRefreshesBothFinish() async throws {
        let rig = try await makeState()
        let state = rig.state
        let db = rig.db
        let pid = rig.pid
        var newer = heading("newer-1", 0, level: 1, text: "Newer Heading")
        newer.projectId = pid
        try db.replaceBlocks([newer], for: pid)

        let first = Task { @MainActor in await state.refreshSectionsAwaiting() }
        let second = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await first.value
        await second.value
        #expect(state.sections.map(\.title) == ["Newer Heading"])
    }

    @Test("A refresh after stopObserving works and does not hang")
    func refreshAfterStopObservingWorks() async throws {
        let state = try await makeState().state
        state.stopObserving()
        #expect(state.outlinePublisher == nil)
        await state.refreshSectionsAwaiting()
        #expect(state.sections.map(\.title) == ["Original Heading"])
    }

    @Test("A refresh whose project changes while it waits shows nothing and does not hang")
    func refreshOnProjectChangeShowsNothing() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original Heading\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        let refresh = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()   // the refresh is now waiting for its reading
        // The project switch lands before the waiting refresh can show anything.
        state.currentProjectId = "some-other-project-id"
        await refresh.value
        #expect(state.sections.isEmpty)
        #expect(state.staleOutlineDropCount == 0)
    }

    @Test("stopObserving while a refresh waits ends the wait")
    func stopObservingWhileRefreshWaits() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original Heading\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        let refresh = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()
        state.stopObserving()
        await refresh.value   // returns, whichever side of the read the stop landed on
    }

    // MARK: - Through the real publisher

    @Test("An opened project fills the sidebar, and a body edit and a status edit made outside the writer reach it")
    func openedProjectFollowsTheDatabase() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Only Section\n\nOne two three four five.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.startObserving(database: db, projectId: pid)
        defer { state.stopObserving() }

        func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition() {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }

        #expect(await waitFor { state.sections.count == 1 }, "the first reading fills the sidebar")
        let wordsBefore = try #require(state.sections.first?.wordCount)

        var paragraph = try #require(try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .paragraph }))
        paragraph.textContent += " and a few more words"
        paragraph.recalculateWordCount()
        try db.write { try paragraph.update($0) }
        #expect(await waitFor { state.sections.first?.wordCount != wordsBefore }, "a typed word reaches the card's count")

        let headingId = try #require(state.sections.first?.id)
        try db.updateBlockStatus(id: headingId, status: .review)
        #expect(await waitFor { state.sections.first?.status == .review }, "a status edit reaches the card")
    }
}
