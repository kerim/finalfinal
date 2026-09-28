//
//  BlockSyncPollWatchdogTests+RebuildKeepsBatch.swift
//  final finalTests
//
//  t-7c1d3fd8 (Finding #1, Calm_Bibliography, docs/architecture/tla/README.md): a save
//  in flight when a bibliography/Notes/footnote rebuild starts used to be thrown away by
//  BlockSyncService.checkGenerationGuard's postFetch/postTurnWait discard, and the
//  rebuild would then restore older text from the database over it. `beginDatabaseRebuild()`
//  / `pollBlockChangesNowForDatabaseRebuild()` / `shouldKeepBatchForDatabaseRebuild` close
//  that window for the narrow case where the pending generation transition IS the rebuild
//  itself. Split out of BlockSyncPollWatchdogTests.swift as an extension of the same
//  suite, for the same reasons BlockSyncPollWatchdogTests+EpochBarrier.swift is -- see
//  that file's header and BlockSyncPollWatchdogTests.swift's own header for the shared
//  scripted-JS-evaluator design this suite uses throughout.
//
//  Same-suite context means these tests inherit `.serialized` (see
//  BlockSyncPollWatchdogTests.swift's `@Suite` line) and share `makeStack`,
//  `ScriptedJSEvaluator`, `blockChangesJSON`, `TestStack` with the rest of the suite.
//
//  Test A is the reproduction: with the KEEP exception in place, a routine save parked
//  after its fetch when a bibliography rebuild begins is kept, so the rebuild's own
//  database read sees the edit. Test B proves the fix is narrowly scoped to database
//  rebuilds: an ordinary zoom transition landing in the same window still discards, as
//  before. Test C proves the "exactly one transition" guard in
//  `shouldKeepBatchForDatabaseRebuild`: a hierarchy fix followed by a rebuild is NOT the
//  rebuild alone, so the ce564961/53e6777b hierarchy-race discard still applies. Test D is
//  the pure decision table (plus a stale-but-otherwise-matching-marker case, and Test I
//  below extends it further at the checkpoint level). Tests E and F extend the same proof
//  to the footnote-insertion and Notes-section rebuild paths, which the TLA+ model (whose
//  `bib` block is a single machine-managed block) does not represent -- see
//  DocSyncCurrent.tla's `RebuildWillReadDb` comment. Test F specifically exercises an
//  `isNotes` row whose label is UNCHANGED by the kept batch (as opposed to Test E's
//  shifted-label row, which the safety net correctly refuses), so it is genuine
//  Notes-specific coverage, not a copy of Test A under different fixture text. Test G
//  proves the preFetch checkpoint's `allowDatabaseRebuildKeep: false` is load-bearing: a
//  marker armed for exactly the observed generation still does not stop a lossless
//  preFetch discard. Test H is the review-round regression test for
//  `pollBlockChangesNowForDatabaseRebuild`'s overwrite-safe `defer`: two overlapping
//  rebuilds, where the first rebuild's flush returns only after the second rebuild's
//  `beginDatabaseRebuild()` has already armed its own marker -- the first flush's
//  completion must not wipe it.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@MainActor
extension BlockSyncPollWatchdogTests {

    private static let notesSeed = """
    # Alpha

    Body alpha[^1] text.

    Other paragraph to edit.

    # Notes

    [^1]: First def.
    """

    private func parkRoutineCycleAfterFetch(_ stack: TestStack, updates: [BlockUpdate]) async throws
        -> (js: ScriptedJSEvaluator, routine: Task<Void, Never>) {
        stack.sync.testPollWatchdogSeconds = 30
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, false)
        js.answer("getBlockChanges", try blockChangesJSON(updates: updates))
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }
        let sync = stack.sync
        let routine = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        return (js, routine)
    }

    private func text(_ stack: TestStack, _ id: String) throws -> String? {
        try TestFixtureFactory.fetchBlocks(from: stack.db).first { $0.id == id }?.textContent
    }

    @Test("A bibliography rebuild starting while a routine save is parked after its fetch keeps that save, so the rebuild's DB read sees the edit")
    func bibRebuildDuringParkedFetch_keepsBatch() async throws {
        let stack = try makeStack()
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: stack.db)
            .first { $0.textContent.contains("one two three") }, "expected the Alpha paragraph")
        let edited = "one two three [@smith2020]."
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: target.id, textContent: edited, markdownFragment: nil, headingLevel: nil)
        ])
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        let sync = stack.sync
        let flush = Task { @MainActor in await sync.pollBlockChangesNowForDatabaseRebuild() }
        js.releaseWedge()
        await routine.value
        await flush.value
        #expect(try text(stack, target.id) == edited, "the rebuild's fetchBlocksWithIds() read must see the edit")
        #expect(stack.sync.testGenerationAbandonCount == 0)
        #expect(stack.sync.testRebuildKeptBatchCount == 1)
        #expect(stack.sync.testDatabaseRebuildGeneration == nil, "marker must clear once the forced flush returns")
        stack.editorState.contentState = .idle
    }

    @Test("A zoom transition landing while a routine save is parked after its fetch still discards that save")
    func zoomDuringParkedFetch_stillDiscards() async throws {
        let stack = try makeStack()
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: stack.db)
            .first { $0.textContent.contains("one two three") })
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: target.id, textContent: "one two three [@smith2020].", markdownFragment: nil, headingLevel: nil)
        ])
        stack.editorState.contentState = .zoomTransition   // no beginDatabaseRebuild
        js.releaseWedge()
        await routine.value
        #expect(try text(stack, target.id) == "one two three.")
        #expect(stack.sync.testGenerationAbandonCount == 1)
        #expect(stack.sync.testRebuildKeptBatchCount == 0)
        stack.editorState.contentState = .idle
    }

    @Test("A heading-level fix followed by a rebuild while a save is parked still discards it (ce564961/53e6777b race)")
    func hierarchyThenRebuildDuringParkedFetch_stillDiscards() async throws {
        let stack = try makeStack()
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: stack.db)
            .first { $0.textContent.contains("one two three") })
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: target.id, textContent: "one two three [@smith2020].", markdownFragment: nil, headingLevel: nil)
        ])
        stack.editorState.contentState = .hierarchyEnforcement
        stack.editorState.contentState = .idle
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        let sync = stack.sync
        let flush = Task { @MainActor in await sync.pollBlockChangesNowForDatabaseRebuild() }
        js.releaseWedge()
        await routine.value
        await flush.value
        #expect(try text(stack, target.id) == "one two three.")
        #expect(stack.sync.testGenerationAbandonCount == 1)
        #expect(stack.sync.testRebuildKeptBatchCount == 0)
        stack.editorState.contentState = .idle
    }

    @Test("shouldKeepBatchForDatabaseRebuild keeps only when the pending rebuild is the one and only transition")
    func keepDecisionTable() {
        typealias Sync = BlockSyncService
        #expect(Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: 5, generationAtPollStart: 4, rebuildGeneration: 5))
        #expect(!Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: 5, generationAtPollStart: 3, rebuildGeneration: 5))
        #expect(!Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: 5, generationAtPollStart: 4, rebuildGeneration: nil))
        #expect(!Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: nil, generationAtPollStart: 4, rebuildGeneration: 5))
        #expect(!Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: 6, generationAtPollStart: 5, rebuildGeneration: 5))
        // A stale marker that otherwise matches `currentGeneration` exactly: this is what
        // `pollBlockChangesNowForDatabaseRebuild`'s overwrite-safe `defer` (see
        // BlockSyncService+DatabaseRebuild.swift) exists to prevent ever reaching this
        // function with a marker from a DIFFERENT, already-finished rebuild -- but the pure
        // decision itself must also refuse it on the merits: `rebuildGeneration` (4) does not
        // equal `generationAtPollStart + 1` (5), so this is not "the pending rebuild is the
        // one and only transition since this poll's snapshot".
        #expect(!Sync.shouldKeepBatchForDatabaseRebuild(currentGeneration: 5, generationAtPollStart: 4, rebuildGeneration: 4))
    }

    // swiftlint:disable:next line_length
    @Test("A footnote insertion that shifts existing labels, landing while a routine save is parked after its fetch, keeps the body edit and does not revert the shifted Notes labels")
    func footnoteInsertionDuringParkedFetch_keepsBodyEdit_doesNotRevertShiftedLabels() async throws {
        let stack = try makeStack(content: Self.notesSeed)
        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let body = try #require(blocks.first { $0.textContent.contains("Other paragraph to edit") })
        let def1 = try #require(blocks.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })
        let bodyEdited = "Other paragraph to edit, now edited."
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: body.id, textContent: bodyEdited, markdownFragment: nil, headingLevel: nil),
            BlockUpdate(id: def1.id, textContent: "First def.", markdownFragment: "[^1]: First def.", headingLevel: nil)
        ])
        let footnotes = FootnoteSyncService()
        footnotes.configure(database: stack.db, projectId: stack.pid)

        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        let inserted = footnotes.handleImmediateInsertion(label: "1", projectId: stack.pid)
        #expect(inserted != nil)
        let sync = stack.sync
        let flush = Task { @MainActor in await sync.pollBlockChangesNowForDatabaseRebuild() }
        js.releaseWedge()
        await routine.value
        await flush.value

        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.first { $0.id == body.id }?.textContent == bodyEdited, "the body edit must survive")
        #expect(after.first { $0.id == def1.id }?.markdownFragment.hasPrefix("[^2]:") == true,
                "the shifted definition must stay [^2] - the stale [^1] update must be refused, not revert it")
        let defs = after.filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(defs.count == 2, "exactly the new [^1] and the shifted [^2] - got \(defs.map(\.markdownFragment))")
        #expect(defs.filter { $0.markdownFragment.hasPrefix("[^1]:") }.count == 1)
        #expect(stack.sync.testRebuildKeptBatchCount == 1)
        #expect(stack.sync.testGenerationAbandonCount == 0)
        stack.editorState.contentState = .idle
    }

    // Genuinely Notes-specific (not a copy of Test A with different fixture text): the
    // parked batch edits an EXISTING footnote DEFINITION row's text with its label
    // unchanged, alongside an ordinary body edit. That exercises
    // `Database+Blocks.applyUpdateToExistingBlock`'s Notes safety net on the KEPT path --
    // a label-unchanged edit must pass that safety net and land, proving the keep
    // exception is not somehow defeated for `isNotes` rows the way a label-changing
    // (shifted) update is refused in Test E/F above.
    @Test("A Notes-section rebuild keeps a parked save that edits an existing footnote definition's text")
    func notesRebuildDuringParkedFetch_keepsNotesDefinitionEdit() async throws {
        let stack = try makeStack(content: Self.notesSeed)
        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let body = try #require(blocks.first { $0.textContent.contains("Other paragraph to edit") })
        let def1 = try #require(blocks.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })
        let bodyEdited = "Other paragraph to edit[^1], with a new reference."
        let defEdited = "First def., now expanded with more detail."
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: body.id, textContent: bodyEdited, markdownFragment: nil, headingLevel: nil),
            BlockUpdate(id: def1.id, textContent: defEdited, markdownFragment: "[^1]: \(defEdited)", headingLevel: nil)
        ])
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        let sync = stack.sync
        let flush = Task { @MainActor in await sync.pollBlockChangesNowForDatabaseRebuild() }
        js.releaseWedge()
        await routine.value
        await flush.value
        #expect(try text(stack, body.id) == bodyEdited, "the body edit must survive the Notes-section rebuild")
        #expect(try text(stack, def1.id) == defEdited,
                "the label-unchanged footnote-definition edit must survive too - Notes rows are not immune to the keep exception")
        #expect(stack.sync.testRebuildKeptBatchCount == 1)
        #expect(stack.sync.testGenerationAbandonCount == 0)
        #expect(stack.sync.testDatabaseRebuildGeneration == nil)
        stack.editorState.contentState = .idle
    }

    // Proves the preFetch checkpoint's `allowDatabaseRebuildKeep: false` genuinely
    // disables the keep exception there, not merely that it happens not to fire: a
    // rebuild marker is armed for EXACTLY the generation this cycle observes (which
    // WOULD satisfy `shouldKeepBatchForDatabaseRebuild` were the exception open), yet
    // the cycle must still abandon before ever reaching `getBlockChanges()` -- the
    // lossless discard the doc comment on that call site promises.
    @Test("preFetch still discards losslessly even when a rebuild marker is armed for exactly this generation")
    func preFetchDiscardsRegardlessOfArmedRebuildMarker() async throws {
        let stack = try makeStack()
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let reachedHook = CountGate()
        var resumeHook: CheckedContinuation<Void, Never>?
        stack.sync.testAfterGenerationCaptureHook = {
            reachedHook.note()
            await withCheckedContinuation { resumeHook = $0 }
        }

        let cycle = Task { @MainActor in await stack.sync.pollBlockChangesForTest(force: false) }
        await reachedHook.waitFor(1)

        // A rewrite lands exactly in the pre-fetch window: bump the generation AND arm
        // the rebuild marker for that same new generation, as a real rebuild handler
        // would (contentState change, then beginDatabaseRebuild()).
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()

        resumeHook?.resume()
        await cycle.value

        #expect(stack.sync.testGenerationAbandonCount == 1, "preFetch must still abandon despite the armed marker")
        #expect(stack.sync.testRebuildKeptBatchCount == 0, "the keep exception must never fire at preFetch")
        #expect(js.callCount("getBlockChanges") == 0, "a lossless preFetch discard never reaches the fetch at all")
        stack.editorState.contentState = .idle
    }

    // Regression test for the review-round fix to `pollBlockChangesNowForDatabaseRebuild`'s
    // `defer`: two rebuilds overlapping (the 5s `contentStateWatchdog` frees `contentState`
    // back to `.idle` while a slow forced flush is still running, letting a second rebuild
    // begin and arm its OWN marker before the first flush's `defer` fires). Built from the
    // real reentrancy machinery (the routine cycle parks first, holding `inFlightPoll`, and
    // rebuild #1's forced flush genuinely DRAINS on it rather than being artificially
    // wedged) -- but the one thing that machinery alone does NOT pin down is exactly when
    // flush1's `Task` body first runs relative to this test's own subsequent statements:
    // Swift gives no guarantee that a freshly spawned `Task`'s body waits for its spawner's
    // next `await` before starting (an earlier version of this test assumed that and was
    // WRONG -- flush1 could, and did, run far enough to capture its `myMarker` snapshot
    // AFTER rebuild #2 already armed its own marker, defeating the whole point: flush1 would
    // then be comparing rebuild #2's marker against itself and "correctly" clearing it,
    // which is not what this test claims to prove). `testAfterMarkerCaptureHook` pins that
    // moment explicitly instead of assuming it.
    @Test("A second rebuild's marker survives the first rebuild's flush completing afterward, and its parked save is kept")
    func overlappingRebuilds_secondMarkerSurvivesFirstFlushCompleting_andItsParkedBatchIsKept() async throws {
        let stack = try makeStack()
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: stack.db)
            .first { $0.textContent.contains("one two three") })
        let edited = "one two three [@smith2020]."

        // Rebuild #1 begins.
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        #expect(stack.sync.testDatabaseRebuildGeneration == 1)

        // The watchdog frees contentState back to idle while rebuild #1's flush is still
        // to come -- gen stays at 1 (going TO idle never bumps).
        stack.editorState.contentState = .idle

        // A routine save parks in exactly rebuild #1's post-bump window (generationAtPoll=1).
        let (js, routine) = try await parkRoutineCycleAfterFetch(stack, updates: [
            BlockUpdate(id: target.id, textContent: edited, markdownFragment: nil, headingLevel: nil)
        ])

        // Rebuild #1's forced flush starts. Park it the instant it captures its OWN
        // `myMarker` -- i.e. BEFORE it can reach `pollBlockChangesNow()`'s drain loop (which
        // is where it will actually block on the routine cycle above) -- so this test
        // controls, rather than assumes, that the capture happens while the marker is still
        // rebuild #1's value (1), strictly before rebuild #2 arms its own.
        let markerCaptured = CountGate()
        stack.sync.testAfterMarkerCaptureHook = { markerCaptured.note() }
        let sync = stack.sync
        let flush1 = Task { @MainActor in await sync.pollBlockChangesNowForDatabaseRebuild() }
        await markerCaptured.waitFor(1)

        // Rebuild #2 begins now that flush1's `myMarker` capture is confirmed to have
        // already happened -- overwrites the marker before flush1's defer can possibly run
        // (flush1 has not yet reached, let alone passed, the drain on the parked routine
        // cycle).
        stack.editorState.contentState = .bibliographyUpdate
        stack.sync.beginDatabaseRebuild()
        #expect(stack.sync.testDatabaseRebuildGeneration == 2)

        // Release the routine cycle: it keeps its batch (current=2, generationAtPoll=1,
        // rebuildGeneration=2 -- exactly one transition), then finishes, freeing
        // inFlightPoll. flush1's drain then resolves, its own inner cycle finds nothing
        // left, and it returns -- its defer running strictly after rebuild #2 armed its
        // marker, and comparing against `myMarker == 1`, not 2.
        js.releaseWedge()
        await routine.value
        await flush1.value

        #expect(try text(stack, target.id) == edited, "the routine save parked in rebuild #2's window must be kept")
        #expect(stack.sync.testRebuildKeptBatchCount == 1)
        #expect(stack.sync.testGenerationAbandonCount == 0)
        #expect(stack.sync.testDatabaseRebuildGeneration == 2,
                "rebuild #1's flush completing afterward must not wipe rebuild #2's marker")
        stack.editorState.contentState = .idle
    }
}
