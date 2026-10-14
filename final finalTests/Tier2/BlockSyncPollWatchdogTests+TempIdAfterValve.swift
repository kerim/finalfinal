//
//  BlockSyncPollWatchdogTests+TempIdAfterValve.swift
//  final finalTests
//
//  Split out of BlockSyncPollWatchdogTests.swift to keep that file under SwiftLint's
//  `file_length` limit and its struct body under `type_body_length`. Same suite context
//  applies -- see the header comment in BlockSyncPollWatchdogTests.swift for the scripted-JS
//  evaluator design. Being an extension of that same struct, these tests inherit the suite's
//  `.serialized` trait, which matters here: the shared helpers (`makeStack`,
//  `ScriptedJSEvaluator`, `CountGate`, `blockChangesJSON`) are declared internal, not
//  private, in BlockSyncPollWatchdogTests.swift for exactly this reason.
//
//  bt: a-quick-edit-to-a-block-you-just-created-can-be-silently-dropped-when-two-saves
//

import Foundation
import Testing
import WebKit
@testable import final_final

@MainActor
extension BlockSyncPollWatchdogTests {

    // swiftlint:disable line_length
    /// T9. `resolvingStaleTempIds` used to read `confirmedTempIds` BEFORE
    /// `awaitPredecessorOrAbandon`'s valve — but a predecessor's `applyAndConfirm` merges
    /// its `pendingConfirmations` into `confirmedTempIds` BEFORE its chain node finishes
    /// (the node is released by `doPollBlockChanges`'s `defer`), and `awaitPredecessorOrAbandon`
    /// is exactly what parks a successor until then. So a successor's
    /// edit to a block the predecessor is still in the middle of inserting resolved
    /// against a mapping that did not exist yet, carried the row's temp id straight into
    /// `applyUpdateToTempIdBlock`, found no row for it, and was dropped as a stale temp
    /// update — even though JS had already cleared its queue, so the edit was gone for
    /// good.
    ///
    /// Shape, driven through the REAL service like T3/T4: cycle 1 fetches an INSERT batch
    /// X (a new block, tempId "temp-valve-1") and parks inside `getBlockChanges` — so it
    /// has consumed X but not yet applied it. Cycle 1 returns at the (short, 0.2s) watchdog,
    /// freeing the in-flight slot while its orphan is still parked on the wedge and holding
    /// chain node 1. Cycle 2 then fetches batch Y — an UPDATE to "temp-valve-1", the very
    /// block cycle 1 is still inserting — and parks on the valve waiting for cycle 1's node
    /// to finish; `testApplyChainWaitSeconds` is pinned long (30s) so cycle 2 waits rather
    /// than abandons (T4's scenario, not this one), and cycle 2 itself then returns at its
    /// own 0.2s watchdog while its orphan stays parked on the valve. Releasing the wedge
    /// lets cycle 1's apply run to completion, filling `confirmedTempIds["temp-valve-1"]`
    /// BEFORE its chain node finishes, and only once that node has finished does cycle 2's
    /// orphan resume past the valve and resolve Y's temp id.
    ///
    /// Before the fix, assertions (a), (b) and (c) all failed: Y's temp id was resolved
    /// before X's mapping existed, so the update was dropped and the inserted row kept
    /// "created text".
    @Test("Apply chain: an edit to a just-inserted block, fetched while the insert's cycle is still applying, lands on the permanent row instead of being dropped as a stale temp update")
    // swiftlint:enable line_length
    func applyChain_updateToTempIdFetchedDuringPredecessorApply_resolvesAfterValve() async throws {
        let stack = try makeStack()
        let (db, pid, sync, editorState) = (stack.db, stack.pid, stack.sync, stack.editorState)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let blockAlpha = try #require(blocks.first { $0.textContent.contains("one two three") },
                                      "expected the Alpha paragraph in the fixture")
        let originalCount = blocks.count

        let xJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: "temp-valve-1", blockType: "paragraph",
                        textContent: "created text", markdownFragment: "created text",
                        headingLevel: nil, afterBlockId: blockAlpha.id, atDocumentStart: nil)
        ])
        let yJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: "temp-valve-1", textContent: "edited right after creating",
                        markdownFragment: "edited right after creating", headingLevel: nil)
        ])

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // M4/A11 precedent (T3/T4): keep cycle 2 waiting on the valve for cycle 1 rather
        // than abandoning it — the abandon/merge path is T4's scenario, not this one.
        sync.testApplyChainWaitSeconds = 30

        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Cycle 1 fetches X and parks inside the fetch, holding chain node 1.
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        await cycle1.value
        #expect(sync.testInFlightPollIsNil,
                "cycle 1's slot must be free while its orphan is still parked on the fetch")

        // Cycle 2 fetches Y (the edit to the block cycle 1 is still inserting). Its own
        // fetch does not wedge (the scripted evaluator's wedge is one-shot and cycle 1
        // already consumed it), so it proceeds to the valve and parks there waiting for
        // cycle 1's chain node — then returns at its own 0.2s watchdog while that wait
        // continues in the background.
        //
        // force: true — holding cycle 1 inside getBlockChanges makes it a pre-fetch orphan,
        // which pauses unforced polling until it clears, so cycle 2 must be forced to run at
        // all here; the production stall this valve exists for is inside the APPLY, not the
        // fetch.
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: true) }
        await js.waitUntilCallEntry("getBlockChanges", 2)
        await cycle2.value

        // Release cycle 1's fetch: it applies X (inserting the permanent row and filling
        // confirmedTempIds), its chain node finishes, and cycle 2's parked orphan then
        // resumes past the valve and applies Y against the now-current mapping.
        js.releaseWedge()
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let edited = after.filter { $0.textContent == "edited right after creating" }
        #expect(edited.count == 1,
                "exactly one row must carry the edit — got \(after.map { $0.textContent })")
        #expect(edited.first?.id.hasPrefix("temp-") == false,
                "the edited row must be the permanent row, not still keyed by its temp id — got \(String(describing: edited.first?.id))")
        #expect(!after.contains { $0.textContent == "created text" },
                "the pre-edit text must not survive — the edit was applied on top of it, not lost")
        #expect(after.count == originalCount + 1,
                "no duplicate row: the edit must land on the SAME row the insert created — got \(after.count), expected \(originalCount + 1)")
        _ = (pid, editorState)
    }

    // swiftlint:disable line_length
    /// T10. The same reorder fixes a second case `resolvingStaleTempIds` handles: an INSERT
    /// anchored (`afterBlockId`) on a temp id the predecessor has not yet confirmed, not just
    /// an UPDATE to one. Before the fix, that anchor stayed a temp id all the way into
    /// `resolveInsertPlacement` (`Database+BlocksInsert.swift`), which cannot find a row keyed
    /// by a temp id — X's committed row is keyed by its PERMANENT id — so it fell into the
    /// "afterBlockId present but unresolvable" branch and placed the new row using the shared
    /// running sort-order counter, i.e. at the END of the document, not beside its intended
    /// anchor.
    ///
    /// Shape: identical harness to T9 — cycle 1 fetches an INSERT batch X (tempId
    /// "temp-valve-1", anchored on the fixture's "one two three" paragraph) and parks inside
    /// `getBlockChanges`; cycle 2 fetches a SECOND insert, Y (tempId "temp-valve-2"), anchored
    /// on X's still-unconfirmed temp id, and parks on the valve until cycle 1's chain node
    /// finishes and fills `confirmedTempIds["temp-valve-1"]`.
    ///
    /// This only discriminates the fix because the fixture's anchor is NOT the document's last
    /// block: "# Beta" / "four five six." still follow "one two three.", so the unresolved-
    /// anchor fallback's running counter (seeded from `MAX(sortOrder)`) lands Y after those,
    /// not directly after X — reasoned from `resolveInsertPlacement` and the write transaction's
    /// `nextSortOrder` seed, not observed by a pre-fix run (the driver checks that separately).
    /// Had X been anchored on the document's LAST block instead, the fallback's counter would
    /// coincidentally land Y in the same place a correct resolution would, and this shape would
    /// not have caught the bug.
    @Test("Apply chain: a second insert anchored on a just-inserted block's temp id, fetched while the first insert's cycle is still applying, lands directly after it instead of at the document's end")
    // swiftlint:enable line_length
    func applyChain_insertAfterJustInsertedTempId_resolvesAfterValve() async throws {
        let stack = try makeStack()
        let (db, pid, sync, editorState) = (stack.db, stack.pid, stack.sync, stack.editorState)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let blockAlpha = try #require(blocks.first { $0.textContent.contains("one two three") },
                                      "expected the Alpha paragraph in the fixture")
        let originalCount = blocks.count

        let xJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: "temp-valve-1", blockType: "paragraph",
                        textContent: "first inserted", markdownFragment: "first inserted",
                        headingLevel: nil, afterBlockId: blockAlpha.id, atDocumentStart: nil)
        ])
        let yJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: "temp-valve-2", blockType: "paragraph",
                        textContent: "second inserted", markdownFragment: "second inserted",
                        headingLevel: nil, afterBlockId: "temp-valve-1", atDocumentStart: nil)
        ])

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // M4/A11 precedent (T3/T4): keep cycle 2 waiting on the valve for cycle 1 rather
        // than abandoning it — the abandon/merge path is T4's scenario, not this one.
        sync.testApplyChainWaitSeconds = 30

        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Cycle 1 fetches X and parks inside the fetch, holding chain node 1.
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        await cycle1.value
        #expect(sync.testInFlightPollIsNil,
                "cycle 1's slot must be free while its orphan is still parked on the fetch")

        // Cycle 2 fetches Y (a second insert anchored on the block cycle 1 is still
        // inserting). Same reason as T9's cycle 2: force: true — holding cycle 1 inside
        // getBlockChanges makes it a pre-fetch orphan, which pauses unforced polling until
        // it clears, so cycle 2 must be forced to run at all here; the production stall this
        // valve exists for is inside the APPLY, not the fetch.
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: true) }
        await js.waitUntilCallEntry("getBlockChanges", 2)
        await cycle2.value

        // Release cycle 1's fetch: it applies X (inserting the permanent row and filling
        // confirmedTempIds), its chain node finishes, and cycle 2's parked orphan then
        // resumes past the valve and applies Y against the now-current mapping.
        js.releaseWedge()
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        #expect(after.count == originalCount + 2,
                "both inserts must land as new rows — got \(after.count), expected \(originalCount + 2)")
        let firstRow = try #require(after.first { $0.textContent == "first inserted" },
                                     "expected X's row in the document")
        let secondRow = try #require(after.first { $0.textContent == "second inserted" },
                                      "expected Y's row in the document")
        #expect(!firstRow.id.hasPrefix("temp-") && !secondRow.id.hasPrefix("temp-"),
                "both rows must carry permanent ids — got \(firstRow.id) and \(secondRow.id)")
        let firstIndex = try #require(after.firstIndex { $0.id == firstRow.id },
                                       "expected X's row to be found by id in the sorted list")
        let secondIndex = try #require(after.firstIndex { $0.id == secondRow.id },
                                        "expected Y's row to be found by id in the sorted list")
        #expect(secondIndex == firstIndex + 1,
                "Y must sort directly after X, not fall back to the document's end — got index \(secondIndex), expected \(firstIndex + 1)")
        _ = (pid, editorState)
    }
}
