//
//  SystemWriteOrderingTests.swift
//  final finalTests
//
//  Phase 2 (t-94369a83), §6: drives system writes through the REAL, full stack --
//  `BlockSyncService` + its internal `DocumentWriter` + a `FootnoteSyncService` wired
//  with a live `SystemWriter` -- proving end-to-end ordering/recovery behavior the
//  writer-only tests in DocumentWriterSystemWriteTests.swift can't reach (those drive
//  `DocumentWriter` directly, with no `FootnoteSyncService`/`BibliographySyncService`
//  in the loop at all).
//
//  T9c is this file's first (and highest-priority) test: it verifies the ONE judgment
//  call the round-3 coder dispatch flagged as its own least-certain -- exactly how
//  `FootnoteSyncService.composeRenameMaps(carried:own:)` chains two rename maps
//  together when a Notes system write fails while a newer Notes update is already
//  pending. See that function's own doc comment (FootnoteSyncService.swift) for the
//  claimed rule ("own wins on shared source labels; a carried entry whose target is
//  itself an own source label chains through to own's final target") -- this test
//  proves that rule against real `reconcileNotesBlocks` behavior, not just against the
//  rule's own prose.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// Thread-safe recorder of every `.renumberFootnotes` notification's `"mapping"`
/// payload. Mirrors `WriterEventRecorder` (DocumentWriterTests.swift)'s NSLock-guarded
/// shape: `NotificationCenter.addObserver(forName:object:queue:using:)`'s `using`
/// closure is `@Sendable`, so a plain captured `var` can't be mutated from inside it
/// under Swift 6 concurrency checking, and `queue: nil` delivers synchronously on the
/// posting thread anyway (no `Task`-hop race to guard against), so a plain NSLock is
/// both correct and simpler than the `Task { @MainActor in ... }` wrapping other files
/// in this target use for cross-thread posts.
private final class RenumberNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mappings: [[String: String]] = []
    func note(_ mapping: [String: String]) {
        lock.withLock { mappings.append(mapping) }
    }
    var all: [[String: String]] { lock.withLock { mappings } }
}

/// MainActor-isolated one-shot gate -- `wait()` parks until `release()` is called (or
/// returns immediately if already released). Inverse of `StartSignal`
/// (BlockSyncPollWatchdogTests.swift): used to hold a production run deterministically
/// "in flight" via a test hook, instead of a wall-clock sleep or a blocked database
/// writer lock (see `resyncNow_doesNotClobberStateWhenStillInFlight`'s own doc comment
/// for why the latter was flaky).
@MainActor
private final class ReleaseSignal {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        guard !released else { return }
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("System writes — full-stack ordering & recovery (Phase 2, Tier 2)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SystemWriteOrderingTests {

    /// Toggles SQLite's `query_only` pragma on the project database's single writer
    /// connection (`DatabasePool` serializes every write call through one dedicated
    /// writer connection, so a pragma set here persists across LATER, separate write
    /// calls on the same `ProjectDatabase` -- it is not per-transaction). With it ON,
    /// any `INSERT`/`UPDATE`/`DELETE` inside a system-write body throws
    /// `SQLITE_READONLY`, which `DocumentWriter.applySystemWrite`'s `catch` turns into
    /// a real `.failed(error)` outcome -- a deterministic, fixture-independent way to
    /// force a genuine write failure without needing a dedicated test seam that
    /// doesn't exist yet in `performFootnoteUpdate`.
    ///
    /// Deliberately `writeWithoutTransaction` (GRDB's TestFixtureFactory-adjacent files
    /// already use this for pragma-shaped statements -- see FixtureGeneratorTests.swift)
    /// rather than `.write { }`: `.write` wraps its closure in a `BEGIN IMMEDIATE`
    /// transaction, which itself needs to acquire the write lock BEFORE the closure
    /// runs -- so turning query_only back OFF via `.write` would need to acquire a
    /// write lock while query_only is STILL on to even START that transaction, a
    /// self-locking trap this round's first attempt hit under concurrent-suite
    /// scheduling. A bare PRAGMA outside any transaction wrapper needs no such lock.
    private func setQueryOnly(_ db: ProjectDatabase, _ enabled: Bool) throws {
        try db.dbWriter.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA query_only = \(enabled ? "ON" : "OFF")")
        }
    }

    // T9c -- REWRITTEN (review round, t-94369a83 Phase 2, finding #3): the original
    // version of this test used deliberately unusual starting labels (10/20/30) so the
    // editor-space keys 1/2/3 that end up in `composed` never collided with a real
    // database row. That let it verify the CHAINING arithmetic in isolation, but it
    // could not (and did not) catch the real bug found in review: `composeRenameMaps`
    // mixing database-space and editor-space labels, which only produces observable
    // corruption when a rename's target label collides with a database row that is
    // still sitting at that label. This version uses realistic 1/2/3 labels
    // specifically so that collision happens, and asserts the FINAL DATABASE STATE
    // rather than `composeRenameMaps`'s own intermediate dictionary value (whose exact
    // shape is an implementation detail, not the contract this test exists to hold).
    @Test("""
        a failed Notes write with a newer update pending, followed by that newer update deleting the row still sitting at its \
        original label, ends with exactly the surviving definition under its correct final label and original body -- no \
        duplicates, nothing resurrected (review findings #2/#3)
        """)
    func notesWrite_realisticLabelCollision_endsWithCorrectSurvivorNoDuplicates() async throws {
        let seed = """
        Body[^1] and[^2] and[^3].

        # Notes

        [^1]: Alpha body text.

        [^2]: Beta body text.

        [^3]: Gamma body text.
        """
        let stack = try makeStack(content: seed)

        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        let recorder = RenumberNotificationRecorder()
        let token = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { note in
            recorder.note(note.userInfo?["mapping"] as? [String: String] ?? [:])
        }
        defer { NotificationCenter.default.removeObserver(token) }

        func defRows() throws -> [Block] {
            try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isNotes && $0.blockType == .paragraph }
        }
        func defByLabel() throws -> [String: (id: String, body: String)] {
            var result: [String: (id: String, body: String)] = [:]
            for block in try defRows() {
                guard let parsed = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment) else { continue }
                result[parsed.label] = (block.id, parsed.text)
            }
            return result
        }

        let originalDefs = try defByLabel()
        #expect(Set(originalDefs.keys) == Set(["1", "2", "3"]), "fixture must start with exactly the 3 seeded labels")
        let originalThreeId = try #require(originalDefs["3"]?.id, "db row [^3] (Gamma) must exist before anything runs")

        // --- Edit 1: the user deletes the reference to [^2]. Editor refs are now
        // ["1","3"] -> own={"3":"2"}. carriedRenameMap starts empty, so composed ==
        // own here (this round doesn't exercise the bug on its own -- it's what sets
        // up the carry). The write is forced to FAIL, with a NEWER Notes update
        // already pending (edit 2, scheduled below, before edit 1's own outcome is
        // known) -- this is Recovery R's own "carry forward" precondition.
        try setQueryOnly(stack.db, true)
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "3"], projectId: stack.pid, fullContent: seed)
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: stack.pid, fullContent: seed)
        await service.performFootnoteUpdate(
            refs: ["1", "3"], projectId: stack.pid, fullContent: seed, scheduledGeneration: 0)

        #expect(recorder.all.count == 1, "edit 1's own forward post -- no inverse, since a newer update is pending")
        #expect(service.testCarriedRenameMap == ["3": "2"], "round 1: composed == own since carried started empty")
        #expect(try defByLabel().keys.sorted() == ["1", "2", "3"], "edit 1's failed write must leave the DB untouched")

        // --- Edit 2 (the "newer update"): the user deletes the reference to the
        // FIRST footnote the editor currently displays -- editor refs are now just
        // ["2"] (displayed; semantically db-original row [^3], since edit 1's own
        // `prepare` already told the editor to show it as "2"). own={"2":"1"}.
        // `composeRenameMaps` must chain db-original "3" -> editor "2" -> "1", i.e.
        // {"3":"1"} -- NOT also add a bogus {"2":"1"} entry (the old bug), which would
        // rename db-original row [^2] (Beta, already orphaned by edit 1) to "1" too,
        // colliding with both the correctly-renamed [^3] row AND the untouched,
        // now-also-stale [^1] (Alpha) row. This write is allowed to succeed.
        try setQueryOnly(stack.db, false)
        await service.performFootnoteUpdate(
            refs: ["2"], projectId: stack.pid, fullContent: seed, scheduledGeneration: 0)

        #expect(recorder.all.count == 2, "edit 2's own forward post -- still never an inverse")
        #expect(service.testCarriedRenameMap.isEmpty, "a successful apply must clear the carry")

        let finalRows = try defRows()
        #expect(finalRows.count == 1, Comment(rawValue:
                "exactly one surviving definition -- got \(finalRows.map(\.markdownFragment)) (a collision leaves " +
                "extra rows sharing label \"1\")"))
        let finalDefs = try defByLabel()
        #expect(finalDefs.keys.sorted() == ["1"])
        #expect(finalDefs["1"]?.body == "Gamma body text.",
                "the survivor must be db-original [^3]'s body -- never [^1]'s (Alpha) or [^2]'s (Beta)")
        #expect(finalDefs["1"]?.id == originalThreeId, Comment(rawValue:
                "the survivor must be db-original [^3], renamed in place -- never a duplicate, and never a " +
                "resurrected [^1] or [^2]"))
    }

    // W34
    @Test("""
        SystemWriteScope.heldEditorSeq refuses .nested while its editor sequence is genuinely open (A5), and does not falsely \
        refuse once that same sequence has settled
        """)
    func heldEditorSeqNestingGuard_refusesWhileOpen_notFalselyAfterSettle() async throws {
        let stack = try makeStack()

        let js = ScriptedJSEvaluator()
        js.answer("flushPendingBlockChanges", true)
        js.answer("hasBlockChanges", true)
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: stack.db)
            .first { $0.textContent.contains("one two three") })
        let json = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "edited while held open", markdownFragment: nil, headingLevel: nil)
        ])
        js.answer("getBlockChanges", json)
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }
        // Same escape hatch W32 already established: the `heldEditorSeq` nesting
        // check backs a DEBUG `assertionFailure` (a real, unguarded call from
        // production code should never hit it) that would otherwise crash this test
        // process the moment it intentionally triggers `.nested` here.
        stack.sync.testSuppressNestedAssert = true

        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        var whileOpenOutcome: SystemWriteOutcome<Int>?
        var whileOpenPrepareRan: Bool?
        var afterSettleOutcome: SystemWriteOutcome<Int>?

        // Both hooks run on the SAME Task as `doPollBlockChanges` (an unstructured
        // `Task { }` inherits the task-local values active at its creation point, and
        // neither hook spawns a further child task), so `SystemWriteScope.heldEditorSeq`
        // -- set via `withValue` around the whole fetch-through-apply window -- is
        // genuinely visible from inside them, exactly as it would be from code called
        // deep within that window in production. `testAfterFetchHook` fires while the
        // ticket is still open (fetched, not yet turn-waited/applied);
        // `testAfterApplyHook` fires right after `applyAndConfirm` -- by then the
        // writer has already removed the ticket's phase entry on a successful apply,
        // so `writer.isOpen(heldSeq)` is false even though the SAME task-local value
        // is still in scope -- this is the "still open, not was set" distinction W34
        // exists to prove.
        stack.sync.testAfterFetchHook = {
            let result = await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                body: { _ in SystemWriteBody(value: 1) }
            )
            whileOpenOutcome = result.outcome
            whileOpenPrepareRan = result.prepareRan
        }
        stack.sync.testAfterApplyHook = {
            let result = await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                body: { _ in SystemWriteBody(value: 1) }
            )
            afterSettleOutcome = result.outcome
        }

        await stack.sync.pollBlockChangesForTest(force: true)

        guard case .refused(.nested) = whileOpenOutcome else {
            Issue.record("expected .refused(.nested) while the held editor sequence was still open, got \(String(describing: whileOpenOutcome))")
            return
        }
        #expect(whileOpenPrepareRan == false, "a .nested refusal must never have run prepare")

        if case .refused(.nested) = afterSettleOutcome {
            Issue.record("must NOT refuse .nested once the held editor sequence has already settled -- got \(String(describing: afterSettleOutcome))")
        }
        // The apply itself must have actually landed -- proves the nested-check calls
        // above did not somehow interfere with the real cycle's own write.
        let updated = try TestFixtureFactory.fetchBlocks(from: stack.db).first { $0.id == target.id }
        #expect(updated?.textContent == "edited while held open")
    }

    // W36
    @Test("""
        performSystemWrite's prepareRan is false for every pre-prepare refusal, with prepare genuinely never invoked (proven via \
        a counter, not just the flag), and true for every post-prepare outcome when prepare was supplied
        """)
    func prepareRanReflectsWhetherPrepareActuallyRan() async throws {
        let stack = try makeStack()
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)

        // A plain reference type, not the `Comment`-shaped concern from earlier rounds
        // -- just a mutable counter `prepare` can capture and increment, proving it
        // was truly never called (not merely that `prepareRan` says so) for the four
        // pre-prepare refusals below.
        final class Counter { var value = 0 }

        // 1. .nested (step 1, before reserve).
        do {
            let counter = Counter()
            let result = await SystemWriteScope.$active.withValue(true) {
                await stack.sync.performSystemWrite(
                    identity: identity, kind: .headingLevels, stillWanted: { true },
                    prepare: { counter.value += 1 },
                    body: { _ in SystemWriteBody(value: 1) }
                )
            }
            guard case .refused(.nested) = result.outcome else {
                Issue.record("expected .refused(.nested), got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == false)
            #expect(counter.value == 0, "prepare must not have been invoked for .nested")
        }

        // 2. pre-reserve .notWanted (step 2, before reserve).
        do {
            let counter = Counter()
            let result = await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { false },
                prepare: { counter.value += 1 },
                body: { _ in SystemWriteBody(value: 1) }
            )
            guard case .refused(.notWanted) = result.outcome else {
                Issue.record("expected .refused(.notWanted), got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == false)
            #expect(counter.value == 0, "prepare must not have been invoked for pre-reserve .notWanted")
        }

        // 3. .noWriter (step 3, before reserve) -- a BlockSyncService that was never configured.
        do {
            let unconfigured = BlockSyncService()
            let counter = Counter()
            let result = await unconfigured.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                prepare: { counter.value += 1 },
                body: { _ in SystemWriteBody(value: 1) }
            )
            guard case .refused(.noWriter) = result.outcome else {
                Issue.record("expected .refused(.noWriter), got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == false)
            #expect(counter.value == 0, "prepare must not have been invoked for .noWriter")
        }

        // 4. reserve-time .identityMismatch (step 3, before reserve) -- an identity
        // naming a completely different project/database than the writer's own.
        do {
            let otherDb = try TestFixtureFactory.createTemporary()
            let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)
            let mismatched = SystemWriteIdentity(projectId: otherPid, database: otherDb)
            let counter = Counter()
            let result = await stack.sync.performSystemWrite(
                identity: mismatched, kind: .headingLevels, stillWanted: { true },
                prepare: { counter.value += 1 },
                body: { _ in SystemWriteBody(value: 1) }
            )
            guard case .refused(.identityMismatch) = result.outcome else {
                Issue.record("expected .refused(.identityMismatch), got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == false)
            #expect(counter.value == 0, "prepare must not have been invoked for reserve-time .identityMismatch")
        }

        // 5. .failed, with prepare supplied -- prepareRan must be true (prepare runs
        // at step 5, well before the body -- which throws -- ever runs at step 8).
        do {
            struct Boom: Error {}
            let counter = Counter()
            let result = await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                prepare: { counter.value += 1 },
                body: { (_: Database) -> SystemWriteBody<Int> in throw Boom() }
            )
            guard case .failed = result.outcome else {
                Issue.record("expected .failed, got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == true)
            #expect(counter.value == 1)
        }

        // 6. .applied, with prepare supplied -- prepareRan must be true.
        do {
            let counter = Counter()
            let result = await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                prepare: { counter.value += 1 },
                body: { _ in SystemWriteBody(value: 1) }
            )
            guard case .applied = result.outcome else {
                Issue.record("expected .applied, got \(result.outcome)")
                return
            }
            #expect(result.prepareRan == true)
            #expect(counter.value == 1)
        }
        // NOT covered this round (recorded honestly): `.skipped`/`.outOfTurn` with
        // prepareRan == true both need the write to be genuinely blocked behind
        // another sequence AFTER prepare runs, then skipped/raced out from under it --
        // doable (e.g. hold an editor sequence open via `testAfterFetchHook`, park a
        // second `performSystemWrite` call behind it, then call `configure(...)` again
        // to trigger `skipAllReserved`), but not attempted this round given the time
        // ceiling; the four pre-prepare-refusal cases and the two post-prepare
        // outcomes above are the ones this test proves.
    }

    // T15
    @Test("""
        a stale debounced footnote update, captured before a fresh immediate insertion bumped syncGeneration, is rejected \
        outright and cannot overwrite the immediate insertion's own definition
        """)
    func staleDebouncedUpdateCannotOverwriteFreshImmediateInsertion() async throws {
        let seed = "Body[^1] here.\n\n# Notes\n\n[^1]: Original body."
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: pid)

        // Stands in for a real debounced update scheduled at generation 0 (captured
        // refs=["1"], matching what `checkAndUpdateFootnotes` would have snapshotted
        // before the immediate insertion below ever happened).
        let staleGeneration = 0

        // An immediate insertion happens before that debounced update ever fires --
        // bumps `syncGeneration` (0 -> 1) and inserts a real [^2] definition.
        let insertionGeneration = service.beginImmediateInsertion()
        let insertedId = await service.commitImmediateInsertion(label: "2", projectId: pid, generation: insertionGeneration)
        #expect(insertedId != nil, "the immediate insertion itself must have landed")

        let afterInsertion = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(afterInsertion.count == 2, "expected [^1] and the freshly-inserted [^2]")

        // The STALE debounced update (generation 0, now behind the live syncGeneration
        // of 1) finally runs -- `performFootnoteUpdate`'s own `scheduledGeneration ==
        // syncGeneration` guard must reject it outright, touching nothing.
        await service.performFootnoteUpdate(
            refs: ["1"], projectId: pid, fullContent: seed, scheduledGeneration: staleGeneration)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(after.count == 2,
                "the stale update must not have deleted [^2] or otherwise mutated the notes section")
        let labels = Set(after.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(labels == Set(["1", "2"]), "both definitions must survive exactly as the immediate insertion left them")
    }

    // T9 (the rest of the Notes recovery table, alongside T9c above)
    @Test("""
        a failed Notes write with NO newer update pending posts the INVERSE of its composed mapping to the editor and clears the \
        carry -- the opposite branch from T9c's carry-forward
        """)
    func notesWrite_failedWithNoNewerUpdatePending_postsInverse_clearsCarry() async throws {
        let seed = """
        Body[^3] and[^1] and[^2].

        # Notes

        [^1]: Alpha body.

        [^2]: Beta body.

        [^3]: Gamma body.
        """
        let stack = try makeStack(content: seed)
        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        let recorder = RenumberNotificationRecorder()
        let token = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { note in
            recorder.note(note.userInfo?["mapping"] as? [String: String] ?? [:])
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try setQueryOnly(stack.db, true)
        // Deliberately NOT calling `checkAndUpdateFootnotes` first -- no `pendingUpdate`,
        // so Recovery R's "no newer update pending" gate holds and it must post the
        // inverse (T9c's sibling test set `pendingUpdate` first to take the OTHER branch).
        await service.performFootnoteUpdate(
            refs: ["3", "1", "2"], projectId: stack.pid, fullContent: seed, scheduledGeneration: 0)
        try setQueryOnly(stack.db, false)

        #expect(recorder.all.count == 2, "the forward post from prepare, PLUS Recovery R's inverse post")
        guard recorder.all.count == 2 else { return }
        let forward = recorder.all[0]
        let inverse = recorder.all[1]
        #expect(!forward.isEmpty)
        let expectedInverse = Dictionary(uniqueKeysWithValues: forward.map { ($1, $0) })
        #expect(inverse == expectedInverse, "the second post must be the EXACT inverse of the first (key/value swapped)")
        #expect(service.testCarriedRenameMap.isEmpty,
                "nothing to carry forward once the inverse has been posted -- next run starts clean")

        // Confirm the DB itself was never touched by the failed write (same invariant
        // T9c checks): still the 3 original rows under their original labels.
        let stillOriginal = try TestFixtureFactory.fetchBlocks(from: stack.db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let labels = Set(stillOriginal.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(labels == Set(["1", "2", "3"]), "the failed write must not have touched the database")
    }

    // Review finding #1(b): a later immediate insertion must never supersede an
    // earlier one's write.
    @Test("""
        two immediate footnote insertions fired back-to-back both land -- the second no longer silently cancels the first's \
        database-side label shift
        """)
    func rapidDoubleImmediateInsertion_bothLand() async throws {
        let seed = "Body[^1] here.\n\n# Notes\n\n[^1]: Original body."
        let stack = try makeStack(content: seed)
        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        // Mirrors the shape at the two real call sites (ContentView+NotificationHandlers
        // .swift / ContentView+ContentRebuilding.swift): `beginImmediateInsertion` runs
        // synchronously, back-to-back, for BOTH insertions before either's
        // `commitImmediateInsertion` Task is even scheduled -- so by the time insertion
        // A's Task starts running, `syncGeneration` has ALREADY been bumped again by
        // insertion B's own `beginImmediateInsertion` call. This is exactly the
        // precondition finding #1(b) describes: with the old `stillWanted` (generation
        // equality), A would be refused `.notWanted` before ever reserving a turn.
        let genA = service.beginImmediateInsertion()
        let genB = service.beginImmediateInsertion()

        async let resultA = service.commitImmediateInsertion(label: "2", projectId: stack.pid, generation: genA)
        async let resultB = service.commitImmediateInsertion(label: "3", projectId: stack.pid, generation: genB)
        let (idA, idB) = await (resultA, resultB)

        #expect(idA != nil, "insertion A's write must have landed -- not silently cancelled by insertion B's later generation bump")
        #expect(idB != nil, "insertion B's write must have landed")

        let defs = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isNotes && $0.blockType == .paragraph }
        let labels = Set(defs.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(defs.count == 3, Comment(rawValue:
                "expected exactly 3 definition rows ([^1] original, plus both insertions' shifts) -- got " +
                "\(defs.map(\.markdownFragment))"))
        #expect(labels == Set(["1", "2", "3"]), "both insertions' label shifts must be reflected -- got \(labels)")
    }

    // Review finding #1(a): `state` must not report `.idle` while a genuinely
    // in-flight run (either kind) is still running, just because a DIFFERENT run that
    // started later already finished and hit its own `defer`.
    @Test("""
        state never falsely reports idle while a Notes update and an immediate insertion are genuinely both in flight, checked \
        at whichever of the two finishes first
        """)
    func stateStaysBusyUntilBothOverlappingRunsComplete() async throws {
        let seed = "Body[^1] and[^2].\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second."
        let stack = try makeStack(content: seed)
        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        // A plain (non-isolated) reference type, same pattern as W36's `Counter` above --
        // both mutating closures below run on the SAME MainActor context this test
        // function itself runs on, so ordinary property mutation is safe.
        final class RaceObserver {
            var aFinished = false
            var bFinished = false
            var violation = false
            func markAFinished(currentState: FootnoteSyncState) {
                aFinished = true
                if !bFinished, currentState != .syncing { violation = true }
            }
            func markBFinished(currentState: FootnoteSyncState) {
                bFinished = true
                if !aFinished, currentState != .syncing { violation = true }
            }
        }
        let observer = RaceObserver()

        // Two `Task { @MainActor in ... }` blocks (not `async let` + nested local
        // functions -- the latter trips Swift 6's "concurrently-executed local
        // function must be @Sendable" diagnostic for no real benefit here, since both
        // bodies are already MainActor-isolated and only ever touch MainActor state).
        let taskA = Task { @MainActor in
            // A reorder (not a pure append) so its own `own` map is non-empty and
            // `prepare` runs, setting `renumberGeneration` -- the field the finding's
            // own text says a false-idle signal can corrupt via a data race.
            await service.performFootnoteUpdate(
                refs: ["2", "1"], projectId: stack.pid, fullContent: seed, scheduledGeneration: 0)
            observer.markAFinished(currentState: service.state)
        }
        let taskB = Task { @MainActor in
            // No `beginImmediateInsertion()` call here on purpose -- calling it would
            // bump `syncGeneration` and invalidate A's own `scheduledGeneration: 0`
            // entry guard before A even starts. `generation` is otherwise inert now
            // (finding #1b), so passing a literal value exercises exactly what this
            // test needs without disturbing A.
            _ = await service.commitImmediateInsertion(label: "3", projectId: stack.pid, generation: 0)
            observer.markBFinished(currentState: service.state)
        }
        _ = await (taskA.value, taskB.value)

        #expect(!observer.violation, Comment(rawValue:
                "state reported .idle while the other run was still genuinely in flight -- the exact false-idle " +
                "signal finding #1a describes"))
        #expect(observer.aFinished && observer.bFinished)
        #expect(service.state == .idle, "state must settle back to .idle once both runs have actually finished")
    }

    // Review finding #4: a failed bibliography write's retry never actually fired.
    @Test("a failed bibliography write schedules a retry that ACTUALLY runs, not just a counter climbing while zero retries ever fire")
    func bibliographyRetry_actuallyRuns() async throws {
        let itemJSON = """
        {"id":"retrytestkey2026","type":"book","title":"Retry Test Title","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let stack = try makeStack(content: "Citing [@retrytestkey2026] here.")
        let service = BibliographySyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        try setQueryOnly(stack.db, true)
        await service.performBibliographyUpdate(
            citekeys: ["retrytestkey2026"], projectId: stack.pid, scheduledGeneration: 0)

        let afterFailure = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(afterFailure.isEmpty, "the failed write must not have created a bibliography block")

        // Review round 3 (F4): the retry no longer goes through the debounced
        // `checkAndUpdateBibliography` path at all -- it now calls
        // `performBibliographyUpdate` DIRECTLY (see that fix's own doc comment on
        // `scheduleBibliographyRetryOrGiveUp`), specifically so it can force a re-run
        // regardless of whether the citekey set changed. One consequence: there is no
        // longer an observable "scheduled but not yet fired" `pendingUpdate` state to
        // poll for -- `pendingUpdate` is explicitly cleared (never set) on this path,
        // and the retry's own `Task`, once created, runs at its very next opportunity
        // with NO debounce delay at all. Polling `testHasPendingUpdate` here (this
        // test's original assertion) checks a mechanism of the OLD, since-removed
        // retry implementation, not the actual, meaningful outcome -- and doing so
        // used to also starve the test of any chance to flip `query_only` off before
        // all `maxBibliographyRetries` attempts fired back-to-back and gave up while
        // still failing. Fixed by flipping `query_only` off SYNCHRONOUSLY, with no
        // suspension point in between -- guaranteed (MainActor, no `await` yet) to
        // happen before the already-scheduled retry `Task` gets its turn -- then
        // polling for the real outcome the retry is meant to produce.
        try setQueryOnly(stack.db, false)

        var succeeded = false
        for _ in 0..<200 {
            let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
            if blocks.contains(where: { $0.markdownFragment.contains("Doe") }) {
                succeeded = true
                break
            }
            await Task.yield()
        }
        #expect(succeeded, Comment(rawValue:
                "the retry must have ACTUALLY run and written the bibliography -- the old bug's symptom was " +
                "that the retry never fired at all"))
    }

    // Review round 3, F4: the retry used to re-enter through
    // `checkAndUpdateBibliography`, whose own `currentSet != lastKnownCitekeys` guard
    // exists to decide whether a NEW check is warranted at all -- not whether a FAILED
    // write should be retried. A failed write never commits `lastKnownCitekeys`, so
    // that guard silently blocked the retry whenever the failed citekey set was
    // UNCHANGED from what was already committed: a manual `regenerateBibliography`
    // re-trigger (e.g. after Zotero metadata changed with no OTHER citation edit) or a
    // `resyncNow`-triggered retry restoring the same citekey set.
    @Test("F4: a failed write is retried even when the citekey set is UNCHANGED (e.g. Zotero metadata changed with no citation edit)")
    func bibliographyRetry_runsEvenWhenCitekeySetUnchanged() async throws {
        let originalJSON = """
        {"id":"f4retrykey2026","type":"book","title":"F4 Original Title","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let updatedJSON = """
        {"id":"f4retrykey2026","type":"book","title":"F4 Updated Title","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let originalItem = try JSONDecoder().decode(CSLItem.self, from: Data(originalJSON.utf8))
        let updatedItem = try JSONDecoder().decode(CSLItem.self, from: Data(updatedJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(originalItem)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let stack = try makeStack(content: "Citing [@f4retrykey2026] here.")
        let service = BibliographySyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        // Establish `lastKnownCitekeys == {"f4retrykey2026"}` via a successful first
        // write -- the exact precondition that made the pre-fix guard block the retry.
        await service.performBibliographyUpdate(
            citekeys: ["f4retrykey2026"], projectId: stack.pid, scheduledGeneration: 0)
        let afterFirst = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(afterFirst.contains { $0.markdownFragment.contains("F4 Original Title") })

        // Metadata changes for the SAME citekey (no citekey SET change at all), then
        // the write fails.
        ZoteroService.shared.loadItem(updatedItem)
        try setQueryOnly(stack.db, true)
        await service.performBibliographyUpdate(
            citekeys: ["f4retrykey2026"], projectId: stack.pid, scheduledGeneration: 0)

        let afterFailure = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(afterFailure.contains { $0.markdownFragment.contains("F4 Original Title") },
            "the failed write must not have changed the committed bibliography yet")

        try setQueryOnly(stack.db, false)

        // Poll for the retry to have actually run and picked up the changed metadata --
        // under the pre-fix bug this citekey set is UNCHANGED, so routing the retry
        // through `checkAndUpdateBibliography` would silently no-op forever.
        var updated = false
        for _ in 0..<200 {
            let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
            if blocks.contains(where: { $0.markdownFragment.contains("F4 Updated Title") }) {
                updated = true
                break
            }
            await Task.yield()
        }
        #expect(updated, Comment(rawValue:
                "the retry must have actually run even though the citekey set never changed -- only the " +
                "rendered content did"))
    }

    // Review round 3, F5: the retry's deferred `Task` wasn't cancelled by `reset()`
    // (called on project switch). A switch landing inside its deferral window let a
    // stale retry fire against the NEW project's just-reset state, see a citekey
    // mismatch there, and overwrite the new project's own legitimate pending update
    // with the OLD project's stale data.
    @Test("F5: reset() (project switch) cancels a still-pending bibliography retry so it can never fire against the new project's state")
    func bibliographyRetryTask_cancelledByReset_doesNotClobberNewProject() async throws {
        let itemAJSON = """
        {"id":"f5retrykeya2026","type":"book","title":"F5 Old Project Title",\
        "author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let itemBJSON = """
        {"id":"f5retrykeyb2026","type":"book","title":"F5 New Project Title",\
        "author":[{"family":"Smith","given":"Sam"}],"issued":{"date-parts":[[2021]]}}
        """
        let itemA = try JSONDecoder().decode(CSLItem.self, from: Data(itemAJSON.utf8))
        let itemB = try JSONDecoder().decode(CSLItem.self, from: Data(itemBJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(itemA)
        ZoteroService.shared.loadItem(itemB)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let stackA = try makeStack(content: "Citing [@f5retrykeya2026] here.")
        let stackB = try makeStack(content: "Citing [@f5retrykeyb2026] here.")

        let service = BibliographySyncService()
        service.configure(database: stackA.db, projectId: stackA.pid)
        service.systemWriter = SystemWriter(blockSync: stackA.sync)

        try setQueryOnly(stackA.db, true)
        await service.performBibliographyUpdate(
            citekeys: ["f5retrykeya2026"], projectId: stackA.pid, scheduledGeneration: 0)
        try setQueryOnly(stackA.db, false)

        // Project switch, deliberately landing inside the retry's own deferral window:
        // `reset()` runs synchronously, immediately after the retry was scheduled
        // (inside `performBibliographyUpdate`, still on MainActor) and before that
        // retry `Task` has had any chance at all to run its own body -- `syncGeneration`
        // is still untouched here (the retry's own `syncGeneration += 1` sits behind
        // the very guard `reset()`'s cancel is meant to trip).
        service.reset()
        service.configure(database: stackB.db, projectId: stackB.pid)
        service.systemWriter = SystemWriter(blockSync: stackB.sync)

        // The new project's own, unrelated pending update -- this must land untouched.
        await service.performBibliographyUpdate(
            citekeys: ["f5retrykeyb2026"], projectId: stackB.pid, scheduledGeneration: 0)

        // Give the (cancelled) retry `Task` every opportunity to run its course.
        for _ in 0..<50 { await Task.yield() }

        let projectBBib = try TestFixtureFactory.fetchBlocks(from: stackB.db).filter { $0.isBibliography }
        #expect(projectBBib.contains { $0.markdownFragment.contains("F5 New Project Title") },
            "the new project's own pending update must have landed")
        #expect(!projectBBib.contains { $0.markdownFragment.contains("F5 Old Project Title") }, Comment(rawValue:
                "the cancelled retry from the OLD project must never have written anything into the new " +
                "project's database"))

        let projectABib = try TestFixtureFactory.fetchBlocks(from: stackA.db).filter { $0.isBibliography }
        #expect(projectABib.isEmpty, Comment(rawValue:
                "the old project's own failed write must never have been retried after its project switched away"))
    }

    // Review finding #5: resyncNow used to unconditionally clear debounceTask/
    // pendingUpdate/syncGeneration after its 2s wait even when state was STILL
    // `.syncing`, discarding a pending debounced update and superseding the
    // still-in-flight run's own write.
    @Test("""
        resyncNow does not drop a pending debounced update, and does not clobber an in-flight write, when it cannot reach .idle \
        within its own 2s wait
        """)
    func resyncNow_doesNotClobberStateWhenStillInFlight() async throws {
        let itemJSON = """
        {"id":"resyncbibkey2026","type":"book","title":"Resync Test A","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let item2JSON = """
        {"id":"resyncbibkeyB2026","type":"book","title":"Resync Test B","author":[{"family":"Smith","given":"Sam"}],"issued":{"date-parts":[[2021]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        let item2 = try JSONDecoder().decode(CSLItem.self, from: Data(item2JSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        ZoteroService.shared.loadItem(item2)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let stack = try makeStack(content: "Citing [@resyncbibkey2026] here.")
        let service = BibliographySyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        // A genuinely pending debounced update, scheduled while idle -- must survive.
        service.checkAndUpdateBibliography(currentCitekeys: ["resyncbibkey2026"], projectId: stack.pid)
        #expect(service.testHasPendingUpdate)

        // Hold the in-flight run deterministically suspended via the production-side
        // test hook, mirroring `BlockSyncService.testPollCycleHook`'s own precedent --
        // NOT a real wall-clock sleep or a blocked database writer lock. An earlier
        // version of this test held the writer lock busy via `Thread.sleep` inside a
        // `Task`, which starved Swift concurrency's cooperative thread pool badly
        // enough that the EARLIER debounce Task above (a real 1s timer) sometimes
        // still got a chance to fire and clear `pendingUpdate` before
        // `regenerateBibliography`'s own cancellation took effect -- a genuine flake,
        // not a fix bug. The hook removes that race entirely.
        let releaseSignal = ReleaseSignal()
        service.testInFlightHook = { await releaseSignal.wait() }

        // The in-flight run: `regenerateBibliography` cancels the debounce but --
        // unlike `checkAndUpdateBibliography` -- never touches `pendingUpdate`,
        // exactly the real path that leaves a genuinely pending update sitting
        // alongside an in-flight run.
        let inFlightTask = Task { @MainActor in
            await service.regenerateBibliography(projectId: stack.pid, citekeys: ["resyncbibkeyB2026"])
        }
        for _ in 0..<200 {
            if service.state == .syncing { break }
            await Task.yield()
        }
        #expect(service.state == .syncing, "the in-flight run must have started before resyncNow is called")
        #expect(service.testHasPendingUpdate, Comment(rawValue:
                "the earlier pending update must still be sitting here, untouched by regenerateBibliography"))

        // resyncNow's own 2s wait times out with state still `.syncing` (the in-flight
        // run stays held until we release it below) -- it must not drop the pending
        // update or bump the generation out from under the in-flight run.
        await service.resyncNow(citekeys: ["resyncbibkeyC2026"], projectId: stack.pid)

        #expect(service.testHasPendingUpdate,
                "resyncNow must not have cleared the pending debounced update just because it could not itself run")

        releaseSignal.release()
        await inFlightTask.value

        let afterInFlight = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(afterInFlight.contains { $0.markdownFragment.contains("Smith") },
                "the in-flight run's own write must still have landed -- resyncNow must not have superseded it")

        // Traced (per the coordinator's ask, not guessed): the pending update captured
        // in step 1 (generation 1) is, by the time we get here, LEGITIMATELY stale --
        // `regenerateBibliography` bumped `syncGeneration` to 2 of its own accord (its
        // own doc comment: "supersede any debounced rebuild scheduled before now"),
        // which is correct, INTENDED behavior completely independent of `resyncNow`.
        // `flushPendingSync` below still calls `performBibliographyUpdate` with the
        // pending update's ORIGINAL captured generation (1); `performBibliographyUpdate`'s
        // own entry guard (`scheduledGeneration == syncGeneration`) then correctly
        // refuses it as superseded -- the EXACT SAME staleness rejection
        // `BibliographySyncTests.staleGenerationRejectedCurrentGenerationWrites`
        // already covers for the ordinary (non-resyncNow) debounce path. This is not a
        // resyncNow bug: `resyncNow`'s own contract (verified above, and by
        // `testHasPendingUpdate` staying true through its early return) is that it must
        // not ITSELF clear `pendingUpdate` or bump `syncGeneration` when it can't run --
        // it says nothing about guaranteeing an already-superseded update still applies
        // later, and it must not: reapplying it here WOULD be the real bug (clobbering
        // the in-flight run's newer, correct "Smith" content with stale "Doe" content).
        await service.flushPendingSync()
        let afterFlush = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(afterFlush.contains { $0.markdownFragment.contains("Smith") }, Comment(rawValue:
                "the in-flight run's newer content must survive the flush attempt -- the stale pending update " +
                "must not have overwritten it"))
        #expect(!afterFlush.contains { $0.markdownFragment.contains("Doe") }, Comment(rawValue:
                "the pending update captured BEFORE regenerateBibliography's own (unrelated, correct) generation " +
                "bump is now legitimately superseded -- it must be rejected as stale, not silently reapplied " +
                "over newer content"))
    }

    // Review finding #8: resyncNow bypassed the "don't overwrite a manually-edited
    // bibliography" guard that checkAndUpdateBibliography has.
    @Test("resyncNow respects the manually-edited-bibliography guard, same as checkAndUpdateBibliography")
    func resyncNow_respectsManualEditGuard() async throws {
        let itemJSON = """
        {"id":"resyncguardkey2026","type":"book","title":"Guard Test","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let stack = try makeStack(content: "Citing [@resyncguardkey2026] here.")
        let service = BibliographySyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)
        service.markAsManuallyEdited()

        await service.resyncNow(citekeys: ["resyncguardkey2026"], projectId: stack.pid)

        let bibBlocks = try TestFixtureFactory.fetchBlocks(from: stack.db).filter { $0.isBibliography }
        #expect(bibBlocks.isEmpty, "resyncNow must not overwrite a manually-edited bibliography")
    }

    // "Also required" item, review round 3: `BibliographySyncService.resyncNow` got
    // `resyncNow_doesNotClobberStateWhenStillInFlight` above, proving it doesn't drop a
    // pending debounced update or clobber an in-flight write when it can't itself reach
    // `.idle` within its own 2s wait. `FootnoteSyncService.resyncNow`'s fix (mirrors the
    // same `if state == .syncing { wait up to 2s }` / `guard state == .idle else { ...
    // return }` shape) was identically shaped but had no equivalent test at all --
    // `FootnoteSyncService.testInFlightHook` (mirroring
    // `BibliographySyncService.testInFlightHook`) added specifically to let this test
    // hold a run deterministically in flight.
    @Test("""
        FootnoteSyncService.resyncNow does not drop a pending debounced update, and does not clobber an in-flight write, when it \
        cannot reach .idle within its own 2s wait
        """)
    func footnoteResyncNow_doesNotClobberStateWhenStillInFlight() async throws {
        let seed = """
        Body[^1].

        # Notes

        [^1]: First real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // A genuinely pending debounced update, scheduled while idle -- must survive.
        // Adds ref "2" (distinct from the in-flight run below, which REMOVES all refs)
        // so the two effects are unambiguous to tell apart afterward.
        let pendingContent = "Body[^1] and[^2].\n\n# Notes\n\n[^1]: First real text."
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: pendingContent)
        #expect(service.testHasPendingUpdate)

        // Hold the in-flight run deterministically suspended via the production-side
        // test hook -- same precedent as `resyncNow_doesNotClobberStateWhenStillInFlight`
        // above. The in-flight run removes ALL footnotes (refs: []) -- a distinct,
        // easily-checkable effect ("Notes section is gone entirely") from the pending
        // update's own effect ("def 2 was added").
        let releaseSignal = ReleaseSignal()
        service.testInFlightHook = { await releaseSignal.wait() }

        let inFlightTask = Task { @MainActor in
            await service.performFootnoteUpdate(
                refs: [], projectId: projectId, fullContent: "Body with no refs at all.", scheduledGeneration: 0)
        }
        for _ in 0..<200 {
            if service.state == .syncing { break }
            await Task.yield()
        }
        #expect(service.state == .syncing, "the in-flight run must have started before resyncNow is called")
        #expect(service.testHasPendingUpdate, Comment(rawValue:
                "the earlier pending update must still be sitting here, untouched by the in-flight run"))

        // resyncNow's own 2s wait times out with state still `.syncing` (the in-flight
        // run stays held until we release it below) -- it must not drop the pending
        // update or bump the generation out from under the in-flight run.
        await service.resyncNow(footnoteRefs: ["1", "3"], projectId: projectId, fullContent: "Body[^1] and[^3].")

        #expect(service.testHasPendingUpdate,
                "resyncNow must not have cleared the pending debounced update just because it could not itself run")

        releaseSignal.release()
        await inFlightTask.value

        let afterInFlight = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(afterInFlight.isEmpty, Comment(rawValue:
                "the in-flight run's own removal must still have landed -- resyncNow must not have superseded it, " +
                "and must not have run its own (different) refs instead"))
    }

    // Review finding #10: `lastKnownCitekeys` was never committed on the
    // unchanged-rendered-content early return, so an unresolvable citekey caused every
    // later check to see a "changed" set and reschedule a full run (including a Zotero
    // fetch and a Source-Mode wholesale flush) forever.
    @Test("""
        an unresolvable citekey set still commits lastKnownCitekeys on the unchanged-content path, so a later check doesn't see \
        a false 'changed' set forever
        """)
    func unresolvableCitekeys_commitOnUnchangedContentPath() async throws {
        ZoteroService.shared.isConnected = true
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }
        // Deliberately never load items for these keys -- both are permanently
        // unresolvable, so `generateBibliographyMarkdown` renders "" for either set.
        let stack = try makeStack(content: "Citing [@unresolvableA2026] here.")
        let service = BibliographySyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        await service.performBibliographyUpdate(
            citekeys: ["unresolvableA2026"], projectId: stack.pid, scheduledGeneration: 0)

        // A DIFFERENT unresolvable citekey set. Content renders identically ("" either
        // way), so this must take the unchanged-content early return -- and still
        // commit `lastKnownCitekeys` to the NEW set.
        await service.performBibliographyUpdate(
            citekeys: ["unresolvableB2026"], projectId: stack.pid, scheduledGeneration: 0)

        // Proven indirectly: checking again with the SAME (just-seen) set must schedule
        // NOTHING, because `currentSet == lastKnownCitekeys` now holds. Under the old
        // bug, `lastKnownCitekeys` would still be stuck at the FIRST set, so this would
        // look "changed" and schedule a pending update every single time.
        service.checkAndUpdateBibliography(currentCitekeys: ["unresolvableB2026"], projectId: stack.pid)
        #expect(!service.testHasPendingUpdate, Comment(rawValue:
                "lastKnownCitekeys must have been committed on the unchanged-content path -- otherwise " +
                "checkAndUpdateBibliography sees a 'changed' set every time and reschedules forever"))
    }
}
