//
//  BlockSyncPollWatchdogTests+EpochBarrier.swift
//  final finalTests
//
//  Split out of BlockSyncPollWatchdogTests.swift to keep that file under SwiftLint's
//  `file_length` limit and its struct body under `type_body_length`. Same suite context
//  applies -- see the header comment in BlockSyncPollWatchdogTests.swift for the scripted-JS
//  evaluator design. Being an extension of that same struct, these tests inherit the suite's
//  `.serialized` trait, which matters here: T7 installs the process-global
//  `DebugLog.alwaysSink`, and `.serialized` is what keeps a sibling test's log lines from
//  interleaving into its capture window.
//
//  These two tests cover the persisted (epoch, sequence) block-write stamp guard as seen from
//  the real `BlockSyncService`: T7 the rewrite barrier (a wholesale rewrite between a cycle's
//  fetch and its apply), T8 the retry of a failed `configure`-time epoch bump. The helpers they
//  share with the rest of the suite (`makeStack`, `ScriptedJSEvaluator`, `CountGate`,
//  `AlwaysLogCapture`, `blockChangesJSON`) are declared internal, not private, in
//  BlockSyncPollWatchdogTests.swift for exactly this reason.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@MainActor
extension BlockSyncPollWatchdogTests {

    // swiftlint:disable line_length
    /// T7. The rewrite barrier itself, driven through the REAL service (R4).
    ///
    /// Earlier tests prove the service threads its own `fetchSequence` through to the DB
    /// write, but none of them bump the rewrite epoch between a batch's fetch and its
    /// apply - so an implementation that hardcoded `epoch = 0`, read the wrong column, or
    /// read the epoch AFTER the fetch returned would pass every one of them while the
    /// barrier did nothing. This is the test that fails in that case.
    ///
    /// Shape: one cycle is wedged INSIDE `getBlockChanges` - so its epoch has already
    /// been captured (before the fetch `await`) but its write has not run. Mid-wedge the
    /// test performs a genuine wholesale rewrite through
    /// `BlockSyncService.parseAndStoreBlocks(markdown:)` - the production mode-toggle /
    /// project-load path, whose body is `database.replaceBlocks(...)`, one of the epoch-
    /// bump call sites. The wedge is then released and the pre-rewrite batch must be
    /// rejected WHOLESALE, not filtered row by row.
    ///
    /// Why the INSERT is the discriminating outcome assertion, and why it is anchor-free:
    /// `replaceBlocks` deletes every row and re-inserts freshly parsed blocks, so the
    /// batch's UPDATE targets an id that no longer exists and would no-op even with no
    /// barrier at all. An insert ANCHORED to a pre-rewrite row would be no better evidence:
    /// `processEditorInserts` skips any insert whose anchor row is gone (its own
    /// stale-anchor guard, Database+BlocksInsert.swift), so it would not land with no
    /// barrier either, and its absence would prove nothing about the barrier. The stale
    /// batch therefore carries a document-start insert with NO anchor
    /// (`afterBlockId: nil, atDocumentStart: true`), which depends on no surviving row and
    /// is applied unconditionally by `resolveInsertPlacement`'s doc-start branch: with the
    /// barrier removed it WOULD land. Its absence is attributable to the batch-level epoch
    /// reject alone. The post-rewrite cycle at the end applies the SAME insert shape
    /// (fresh temp id and text) to prove the shape does land when the batch carries the
    /// current epoch - so the absence above is the barrier, not the insert being unlandable.
    /// The unconditional "REJECTED WHOLE BATCH" log line (with `insertsDropped=1`) is the
    /// second, independent witness that the refusal happened inside the write.
    @Test("A wholesale rewrite landing between a cycle's fetch and its apply rejects that cycle's WHOLE batch - its insert never lands, the rewrite's content survives, and the next cycle still writes (R4)")
    // swiftlint:enable line_length
    func wholesaleRewriteMidFlight_rejectsWedgedCyclesWholeBatch_andLaterCycleStillLands() async throws {
        let stack = try makeStack()
        let (db, pid, sync, editorState) = (stack.db, stack.pid, stack.sync, stack.editorState)

        sync.testPollWatchdogSeconds = 30

        let before = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let staleTarget = try #require(before.first { $0.textContent.contains("one two three") },
                                       "expected the Alpha paragraph in the fixture")

        let ghostInsertText = "GHOST insert from a pre-rewrite batch"
        let staleBatchJSON = try blockChangesJSON(
            updates: [
                BlockUpdate(id: staleTarget.id, textContent: "GHOST update from a pre-rewrite batch",
                            markdownFragment: nil, headingLevel: nil)
            ],
            inserts: [
                // Anchor-free document-start insert: applied unconditionally unless the
                // epoch barrier refuses the batch (see the doc comment above).
                BlockInsert(tempId: "temp-ghost-1", blockType: "paragraph",
                            textContent: ghostInsertText,
                            markdownFragment: ghostInsertText,
                            headingLevel: nil, afterBlockId: nil, atDocumentStart: true)
            ]
        )

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", staleBatchJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        try await sync.parseAndStoreBlocks(markdown: "# Gamma\n\nseven eight nine.\n")
        let afterRewrite = try TestFixtureFactory.fetchBlocks(from: db)
        let rewrittenTarget = try #require(afterRewrite.first { $0.textContent.contains("seven eight nine") },
                                           "the rewrite must have replaced the document's blocks")

        js.releaseWedge()
        await cycle1.value
        await applies.waitFor(1)

        #expect(applies.value == 1,
                "cycle 1's apply step must have RUN - a rejection inside the write, not an upstream early return - got \(applies.value) applies")
        #expect(sync.testPollTimeoutForceFlags.isEmpty,
                "no watchdog timeout may be involved in this test - got \(sync.testPollTimeoutForceFlags)")
        #expect(sync.testGenerationAbandonCount == 0,
                "the generation guard must NOT be what stopped this batch - got \(sync.testGenerationAbandonCount)")
        #expect(sync.testOwnBatchAbandonCount == 0,
                "no apply-chain merge path is involved: there is exactly one cycle - got \(sync.testOwnBatchAbandonCount)")

        let rejections = capture.captured.filter { $0.contains("REJECTED WHOLE BATCH") }
        #expect(rejections.count == 1,
                "the barrier must log exactly one unconditional whole-batch rejection - got \(capture.captured)")
        #expect(rejections.first?.contains("batchEpoch=") == true && rejections.first?.contains("currentEpoch=") == true,
                "the rejection line must name both epochs - got \(String(describing: rejections.first))")
        #expect(rejections.first?.contains("insertsDropped=1") == true,
                "the rejection line must show the barrier dropped the batch's one insert - got \(String(describing: rejections.first))")
        DebugLog.alwaysSink = nil

        let afterStale = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(!afterStale.contains { $0.textContent.contains(ghostInsertText) },
                "the pre-rewrite batch's INSERT must not land")
        #expect(!afterStale.contains { $0.textContent.contains("GHOST update") },
                "no part of the pre-rewrite batch may land")
        #expect(afterStale.contains { $0.textContent.contains("seven eight nine") },
                "the rewrite's own content must survive the rejected batch")
        #expect(afterStale.count == afterRewrite.count,
                "the rejected batch must not change the row count at all - got \(afterStale.count), rewrite left \(afterRewrite.count)")

        // Positive control: a batch fetched AFTER the rewrite carries the current epoch, so the
        // very same anchor-free document-start insert shape that was refused above must land now.
        let freshText = "post-rewrite batch lands normally"
        let freshInsertText = "post-rewrite doc-start insert lands normally"
        js.answer("getBlockChanges", try blockChangesJSON(
            updates: [
                BlockUpdate(id: rewrittenTarget.id, textContent: freshText,
                            markdownFragment: nil, headingLevel: nil)
            ],
            inserts: [
                BlockInsert(tempId: "temp-fresh-1", blockType: "paragraph",
                            textContent: freshInsertText,
                            markdownFragment: freshInsertText,
                            headingLevel: nil, afterBlockId: nil, atDocumentStart: true)
            ]
        ))

        await sync.pollBlockChangesForTest(force: false)
        await applies.waitFor(2)

        let afterFresh = try TestFixtureFactory.fetchBlocks(from: db)
        let freshTextForId = Dictionary(uniqueKeysWithValues: afterFresh.map { ($0.id, $0.textContent) })
        #expect(freshTextForId[rewrittenTarget.id] == freshText,
                "the barrier must not reject batches fetched AFTER the rewrite - got \(String(describing: freshTextForId[rewrittenTarget.id]))")
        #expect(afterFresh.contains { $0.textContent.contains(freshInsertText) },
                "the same anchor-free doc-start insert must land at the post-rewrite epoch - so its absence in cycle 1 was the barrier")
        _ = (pid, editorState)
    }

    /// T8. `configure` bumps the persisted block-write epoch. If that bump FAILS, the persisted
    /// epoch is still last session's while this session's fetch sequence restarts low, so a row
    /// last session wrote at a high sequence would silently supersede every edit this session
    /// sends for it. `needsEpochBump` makes the next poll retry the bump BEFORE it fetches, and
    /// defer the whole poll (fetching nothing, so the batch stays queued JS-side) while the retry
    /// keeps failing.
    ///
    /// The failure is a REAL database condition, no production hook: `project.blockWriteEpoch`
    /// is dropped before `configure` runs, so the bump's `SELECT blockWriteEpoch FROM project`
    /// throws; adding the column back clears the condition. The stack is therefore built by hand
    /// (`makeStack` configures immediately, before the condition can be set up).
    ///
    /// Why each phase is attributable to the retry and not to something else:
    ///   - Poll 1: with the column gone, a build WITHOUT the retry would also return before the
    ///     fetch (`currentBlockWriteEpoch` throws), so "no fetch" alone proves nothing. The
    ///     discriminator is the retry's own unconditional log line.
    ///   - Poll 2: the column comes back at the SAME epoch the row's stamp was written in, and
    ///     the row carries a high-sequence stamp from "last session". Without the retry this poll
    ///     would stamp its batch (E, 1) against stored (E, 300) and DROP the edit; only the
    ///     retry's bump moves the epoch to E+1 and restamps the row to (E+1, 0), so the edit
    ///     lands and the epoch reads E+1.
    ///   - Poll 3: the flag was cleared, so nothing bumps again (epoch still E+1).
    @Test("A failed configure-time epoch bump is retried by the next poll, which fetches nothing until the retry succeeds")
    func failedConfigureBump_isRetriedByNextPoll_deferringUntilItSucceeds() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\none two three.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let target = try #require(
            try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent.contains("one two three") },
            "expected the Alpha paragraph in the fixture"
        )

        // "Last session": the row's persisted stamp becomes (E, 300).
        let sessionEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        let lastSession = try db.applyBlockChangesFromEditor(
            BlockChanges(updates: [
                BlockUpdate(id: target.id, textContent: "last session text", markdownFragment: nil, headingLevel: nil)
            ]),
            for: pid, stamp: BlockWriteStamp(epoch: sessionEpoch, sequence: 300)
        )
        #expect(!lastSession.rejectedWholeBatchForStaleEpoch,
                "precondition: the last-session batch carries the current epoch and must not be rejected")
        #expect(lastSession.writtenUpdateIds == [target.id],
                "precondition: the last-session write must land — got \(lastSession.writtenUpdateIds)")

        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        // Make every epoch bump fail, THEN configure - so configure's own bump fails and arms the retry.
        try await db.dbWriter.write { database in
            try database.execute(sql: "ALTER TABLE project DROP COLUMN blockWriteEpoch")
        }
        let webView = WKWebView()                                           // never loaded; retained here
        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: webView)
        let editorState = EditorViewState()                                 // held: `editorState` is weak
        sync.editorState = editorState
        sync.testPollWatchdogSeconds = 30
        #expect(capture.captured.contains { $0.contains("[BlockSync] configure: could not bump blockWriteEpoch") },
                "precondition: configure's bump must have FAILED (the column is gone) — got \(capture.captured)")

        let thisSessionJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "this session text", markdownFragment: nil, headingLevel: nil)
        ])
        let laterJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "later text", markdownFragment: nil, headingLevel: nil)
        ])
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", thisSessionJSON, laterJSON)
        sync.testJSEvaluator = { try await js.evaluate($0) }
        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Poll 1: the retry fails too, so the poll is deferred BEFORE the fetch.
        await sync.pollBlockChangesForTest(force: false)

        #expect(js.callCount("hasBlockChanges") == 1,
                "the deferred poll must still have asked the editor for changes — got \(js.callCount("hasBlockChanges"))")
        #expect(js.callCount("getBlockChanges") == 0,
                "a poll deferred on a failing bump retry must not fetch (the batch would be lost) — got \(js.callCount("getBlockChanges"))")
        #expect(applies.value == 0, "a deferred poll must not apply anything — got \(applies.value) applies")
        #expect(capture.captured.contains { $0.contains("retry of the deferred blockWriteEpoch bump failed") },
                "the deferral must be logged unconditionally, naming the retry — got \(capture.captured)")
        let afterDeferred = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == target.id }
        #expect(afterDeferred?.textContent == "last session text",
                "the deferred poll must not have written anything — got \(String(describing: afterDeferred?.textContent))")

        // Clear the condition, at the SAME epoch (the previous session's persisted one).
        try await db.dbWriter.write { database in
            try database.execute(sql: "ALTER TABLE project ADD COLUMN blockWriteEpoch INTEGER NOT NULL DEFAULT 0")
            try database.execute(sql: "UPDATE project SET blockWriteEpoch = ? WHERE id = ?",
                                 arguments: [sessionEpoch, pid])
        }
        let restoredEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(restoredEpoch == sessionEpoch,
                "precondition: the epoch column must be back at the previous session's epoch — got \(restoredEpoch)")

        // Poll 2: the retry succeeds (epoch E -> E+1, rows restamped), then the poll fetches and applies.
        await sync.pollBlockChangesForTest(force: false)

        let epochAfterRetry = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfterRetry == sessionEpoch + 1,
                "the retry must have bumped the epoch exactly once — got \(epochAfterRetry), expected \(sessionEpoch + 1)")
        #expect(js.callCount("getBlockChanges") == 1,
                "once the retry succeeds the poll must fetch — got \(js.callCount("getBlockChanges"))")
        #expect(applies.value == 1, "the retried poll must apply — got \(applies.value) applies")
        let afterRetry = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == target.id }
        #expect(afterRetry?.textContent == "this session text",
                "the edit must land, not be dropped against last session's (E, 300) stamp — got \(String(describing: afterRetry?.textContent))")

        // Poll 3: the flag is cleared - no second bump, and the poll applies normally.
        await sync.pollBlockChangesForTest(force: false)

        let epochAfterThirdPoll = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfterThirdPoll == epochAfterRetry,
                "a cleared flag must not bump again — got \(epochAfterThirdPoll), expected \(epochAfterRetry)")
        #expect(applies.value == 2, "the following poll must apply normally — got \(applies.value) applies")
        let afterThird = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == target.id }
        #expect(afterThird?.textContent == "later text",
                "the following poll's edit must land — got \(String(describing: afterThird?.textContent))")
        _ = (webView, editorState)
    }
}
