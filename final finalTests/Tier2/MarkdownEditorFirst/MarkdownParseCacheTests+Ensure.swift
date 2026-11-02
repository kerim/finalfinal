//
//  MarkdownParseCacheTests+Ensure.swift
//  final finalTests
//
//  t-2fbe4c9b Phase 4c job 3, round C8: the tests of `MarkdownParseCache.ensure`, the wait the DEBOUNCE FIRE makes for the parse of its own
//  text (ViewState/MarkdownParseCache.swift, "Waiting for a request's job"; called from `scheduleFullDocumentReparse`,
//  Views/ViewNotificationModifiers.swift). A second part of `MarkdownParseCacheTests` (the same suite, an extension in its own file).
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  How the tests hold a background job: `testBackgroundStarted` runs ON THE BACKGROUND THREAD when the job's detached task begins, so a
//  closure that waits on a semaphore keeps the job running (and the request "in its job") until the test lets it go. Every wait on the
//  semaphore is bounded (20 s) so a failing test cannot hang the run.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows. Every function named
//  here is in MarkdownParseCache.swift or the file named.
//
//   25  testEnsureStartsAPendingRequestAndTheFireHits    (THE MUST-FAIL TEST OF THE FIX; real scheduler, real fire Task)
//       BREAK: delete the line `await editorState.markdownWriter.parseCache.ensure(raw: editorState.content, projectId: pid, database: db)` in
//       `ContentSyncObserverHost.scheduleFullDocumentReparse` (Views/ViewNotificationModifiers.swift). The fire (20 ms) then comes before the
//       typing-pause request (300 ms) has started, finds nothing and parses.
//       FAILS with: "the fire parsed on the main thread instead of waiting for its text's parse: ... cache=miss ...".
//   26  testEnsureWaitsForTheRunningRequestOfTheSameText
//       BREAK: in `requestToWaitFor` delete the line `if let running, asksFor(running) { return running.id }`.
//       FAILS with: "ensure did not wait for the running request: none" (and the entry is not stored when it returns).
//   27  testEnsureReturnsAtOnceWhenNothingWasAsked
//       BREAK: in `requestToWaitFor` change `guard let next = pending, asksFor(next) else { return nil }` to `guard let next = pending else`
//       (a pending request for ANOTHER text is waited for and started); or make `ensure` start a parse of its own when it finds no request.
//       FAILS with: "ensure started a parse for a text nobody asked for" / "ensure waited for a request for another text".
//   28  testEnsureThenGenerationMovedDropsTheFire
//       BREAK: in `scheduleFullDocumentReparse` move the `ensure` line below the `guard !Task.isCancelled, editorState.blockReparseGeneration
//       == myGeneration else { return }` that follows the `while let inFlight` loop (the wait is then not re-checked), or delete that guard.
//       FAILS with: "the fire ran its step although the generation had moved while it waited".
//   29  testEnsureTimeoutFallsBackToAMainThreadParse
//       BREAK: in `waitForEnd` delete the `let timer = Task { ... }` block (use `Task {}` as the timer): the wait then lasts until the held job
//       ends (the 20 s gate), so the outcome is not `timeout` (slow failure).
//       FAILS with: "the wait did not end by the timeout: waited".
//   30  testEnsureEndsAtOnceWhenTheFireTaskIsCancelled
//       BREAK: in `waitForEnd` replace the `onCancel:` closure body by nothing. The wait then lasts until the 10 s timer.
//       FAILS with: "a cancelled ensure did not end at once: timeout" (after 10 s).
//   31  testEnsureEndsAtOnceWhenTheCacheIsReset
//       BREAK: delete the line `endEnsureWaiters(forRequest: nil, as: .ended)` in `MarkdownParseCache.reset()`.
//       FAILS with: "a reset did not end the wait: timeout" (after 10 s).
//

import Foundation
import Testing
@testable import final_final

extension MarkdownParseCacheTests {

    /// Waits (polling the main actor, at most 5 s) until `condition` holds.
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        var waited = 0
        while !condition() && waited < 1_000 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
    }

    /// Keeps every background job of `cache` running from the moment it starts until the returned semaphore is signalled.
    private func holdBackgroundJobs(of cache: MarkdownParseCache) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        cache.testBackgroundStarted = { _ = gate.wait(timeout: .now() + 20) }
        return gate
    }

    // MARK: - 25

    @Test("25: a debounce fire whose typing-pause parse has not started yet starts it and waits for it, and its step hits the memo")
    func testEnsureStartsAPendingRequestAndTheFireHits() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)   // the debounce is 20 ms; the typing-pause request waits 300 ms
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let cache = rig.markdownWriter.parseCache

        let fire = try #require(underStableSettings { rig.schedule(typed) }, "premise: the real scheduler armed the fire")
        #expect(
            cache.startedCount == 0 && !cache.isRunning && cache.entries.isEmpty,
            "premise: the typing-pause request is still waiting out its 300 ms when the fire's Task is created")
        await fire.value   // the fire's Task: ensure, the wait for the write in flight, the gates, the synchronous step
        await rig.settle()
        await cache.settled()

        let line = rig.markdownWriter.lastTimingLine ?? "nil"
        #expect(line.contains("cache=hit"), "the fire parsed on the main thread instead of waiting for its text's parse: \(line)")
        #expect(line.contains("parse=0.0ms"), "a hit parses nothing: \(line)")
        #expect(line.contains("outcome=applied"), "premise: the fire wrote the typing: \(line)")
        #expect(cache.startedCount == 1, "the request was not started once (by ensure), startedCount \(cache.startedCount)")
        #expect(cache.ensureWaiterCount == 0, "a waiter was left behind")
        #expect(try rig.storedText() != loaded, "the typing was not saved")
    }

    // MARK: - 26

    @Test("26: ensure waits for the job already running for the same text and returns when its entry is stored; it starts no second job")
    func testEnsureWaitsForTheRunningRequestOfTheSameText() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let text = Self.book6.markdown
        cache.prewarm(raw: text, projectId: project.pid, database: project.db, names: Self.defaultNames)
        #expect(cache.isRunning && cache.entries.isEmpty, "premise: the job is running and has stored nothing")

        let outcome = await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: .seconds(20))
        #expect(outcome == .waited, "ensure did not wait for the running request: \(outcome)")
        let key = Key(
            text: text, projectId: project.pid, notesTitle: try project.db.fetchNotesHeadingTitle(projectId: project.pid),
            bibliographyHeaderName: Self.defaultNames.headerName, graceNames: Self.defaultNames.graceNames)
        #expect(cache.lookup(key) != nil, "the entry was not stored when ensure returned")
        #expect(cache.startedCount == 1 && cache.ensureWaiterCount == 0, "a second job was started or a waiter was left behind")
    }

    // MARK: - 27

    @Test("27: ensure returns at once and starts nothing when the memo holds the key or nobody asked for the text or the project")
    func testEnsureReturnsAtOnceWhenNothingWasAsked() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let text = Self.article.markdown
        let bound = Duration.seconds(5)   // a wait that wrongly begins would end as `timeout`, 5 s later

        let nothing = await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: bound)
        #expect(nothing == .none, "nothing was asked, ensure returned \(nothing)")
        #expect(cache.startedCount == 0 && !cache.isRunning && cache.entries.isEmpty, "ensure started a parse for a text nobody asked for")

        // A request for ANOTHER text, and one for the same text in ANOTHER project, are not this fire's request.
        cache.prewarm(raw: text + "\n\nAnother text.", projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(60))
        let otherText = await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: bound)
        #expect(otherText == .none, "ensure waited for a request for another text: \(otherText)")
        cache.prewarm(raw: text, projectId: "another-project", database: project.db, names: Self.defaultNames, after: .seconds(60))
        let otherProject = await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: bound)
        #expect(otherProject == .none, "ensure waited for a request of another project: \(otherProject)")
        #expect(cache.startedCount == 0 && !cache.isRunning, "ensure started a parse for a text nobody asked for")
        cache.reset()

        // The memo already holds the key (made with the settings' own names, as ensure reads them): at once, nothing started.
        cache.prewarm(raw: text, projectId: project.pid, database: project.db)
        await cache.settled()
        let startedBefore = cache.startedCount
        let stored = await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: bound)
        #expect(stored == .hit, "the memo held the key, ensure returned \(stored)")
        #expect(cache.startedCount == startedBefore && cache.ensureWaiterCount == 0)
    }

    // MARK: - 28

    @Test("28: when the generation moves on while the fire waits in ensure, the fire is dropped after the wait and writes nothing")
    func testEnsureThenGenerationMovedDropsTheFire() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let cache = rig.markdownWriter.parseCache
        let gate = holdBackgroundJobs(of: cache)

        let fire = try #require(underStableSettings { rig.schedule(typed) }, "premise: the real scheduler armed the fire")
        try await waitUntil { cache.ensureWaiterCount == 1 }
        #expect(cache.ensureWaiterCount == 1 && cache.isRunning, "premise: the fire is inside ensure, waiting for its text's held job")

        // A keystroke moves the generation (the scheduler also cancels the Task; here only the generation moves, the check this test is for).
        rig.editorState.blockReparseGeneration += 1
        gate.signal()
        await fire.value
        await rig.settle()
        await cache.settled()

        #expect(rig.markdownWriter.lastTimingLine == nil, "the fire ran its step although the generation had moved while it waited")
        #expect(try rig.storedText() == loaded, "the dropped fire wrote the typing")
        #expect(cache.hitCount == 0 && cache.missCount == 0, "the dropped fire looked the memo up")
        #expect(cache.ensureWaiterCount == 0)
    }

    // MARK: - 29

    @Test("29: when the job outlasts the bound, ensure gives up (timeout) and the fire's step parses on the main thread with the same changes")
    func testEnsureTimeoutFallsBackToAMainThreadParse() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        let timedOutWriter = rig.markdownWriter
        let hittingWriter = MarkdownBlockWriter()
        timedOutWriter.noteLoaded(text: loaded, pid: rig.pid)
        hittingWriter.noteLoaded(text: loaded, pid: rig.pid)
        var timedOutChanges: BlockChanges?
        var hitChanges: BlockChanges?
        let timedOutIds = TempIds()
        let hitIds = TempIds()
        timedOutWriter.testMakeTempId = { timedOutIds.make() }
        hittingWriter.testMakeTempId = { hitIds.make() }
        timedOutWriter.testChangesObserver = { timedOutChanges = $0 }
        hittingWriter.testChangesObserver = { hitChanges = $0 }

        let names = underStableSettings { BlockParser.bibliographyNames(from: ExportSettings.load()) }
        hittingWriter.parseCache.prewarm(raw: typed, projectId: rig.pid, database: rig.db, names: names)
        await hittingWriter.parseCache.settled()

        // The first writer's job for the typed text is held past the bound.
        let cache = timedOutWriter.parseCache
        let gate = holdBackgroundJobs(of: cache)
        cache.prewarm(raw: typed, projectId: rig.pid, database: rig.db, names: names)
        let outcome = await cache.ensure(raw: typed, projectId: rig.pid, database: rig.db, timeout: .milliseconds(150))
        #expect(outcome == .timeout, "the wait did not end by the timeout: \(outcome)")
        #expect(cache.ensureWaiterCount == 0, "a waiter was left behind after the timeout")

        // The fire's synchronous step now, as the fire does after ensure: it misses and parses; the changes equal a hit's.
        let held = rig.hold()
        let dispositions = underStableSettings {
            (
                timedOutWriter.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {}),
                hittingWriter.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {})
            )
        }
        #expect(dispositions.0 == .started && dispositions.1 == .started, "premise: both writers reserved a turn")
        await rig.release(held)
        for writer in [timedOutWriter, hittingWriter] {
            while let pending = writer.inFlight { await pending.value }
        }
        gate.signal()
        await cache.settled()

        let missLine = timedOutWriter.lastTimingLine ?? "nil"
        #expect(missLine.contains("cache=miss"), "the step after a timeout did not parse on the main thread: \(missLine)")
        let hitLine = hittingWriter.lastTimingLine ?? "nil"
        #expect(hitLine.contains("cache=hit"), "premise: the other writer hit: \(hitLine)")
        let missing = try #require(timedOutChanges, "the timed-out writer reserved no changes")
        let hitting = try #require(hitChanges, "the other writer reserved no changes")
        #expect(!missing.updates.isEmpty && !missing.inserts.isEmpty, "premise: the edit is an update and an insert")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(missing) == encoder.encode(hitting), "the main-thread parse after a timeout gave different changes than a hit")
    }

    // MARK: - 30 and 31: nothing is left waiting

    @Test("30: a cancelled caller's wait ends at once (a newer keystroke cancels the fire's Task) and leaves no waiter behind")
    func testEnsureEndsAtOnceWhenTheFireTaskIsCancelled() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let gate = holdBackgroundJobs(of: cache)
        let text = Self.article.markdown
        cache.prewarm(raw: text, projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(60))
        let waiting = Task { await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: .seconds(10)) }
        try await waitUntil { cache.ensureWaiterCount == 1 }
        #expect(cache.ensureWaiterCount == 1 && cache.isRunning, "premise: the caller waits for the held job it started")

        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        let outcome = await waiting.value
        #expect(outcome == .ended, "a cancelled ensure did not end at once: \(outcome)")
        #expect(cancelledAt.duration(to: .now) < .seconds(3), "the cancelled wait lasted until the timer")
        #expect(cache.ensureWaiterCount == 0, "a waiter was left behind after the cancellation")
        gate.signal()
        await cache.settled()
    }

    @Test("31: reset() ends the wait of a caller waiting for a job that no longer matters, and leaves no waiter behind")
    func testEnsureEndsAtOnceWhenTheCacheIsReset() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let gate = holdBackgroundJobs(of: cache)
        let text = Self.article.markdown
        cache.prewarm(raw: text, projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(60))
        let waiting = Task { await cache.ensure(raw: text, projectId: project.pid, database: project.db, timeout: .seconds(10)) }
        try await waitUntil { cache.ensureWaiterCount == 1 }
        #expect(cache.ensureWaiterCount == 1, "premise: the caller waits")

        let resetAt = ContinuousClock.now
        cache.reset()
        let outcome = await waiting.value
        #expect(outcome == .ended, "a reset did not end the wait: \(outcome)")
        #expect(resetAt.duration(to: .now) < .seconds(3), "the wait lasted until the timer")
        #expect(cache.ensureWaiterCount == 0, "a waiter was left behind after the reset")
        gate.signal()
        await cache.settled()
        #expect(cache.entries.isEmpty, "the result of the job that no longer mattered was stored")
    }
}
