//
//  MarkdownParseCacheTests+Background.swift
//  final finalTests
//
//  t-2fbe4c9b Phase 4c job 3, rounds C2a to C5a: the tests of what the parse memo's BACKGROUND work does with its requests, a second part of
//  `MarkdownParseCacheTests` (the same suite: an extension in its own file, which keeps the main file under SwiftLint's file-length limit).
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows. Every function named
//  here is in MarkdownParseCache.swift, MarkdownScanMemo.swift or the file named.
//
//   17  testIdenticalPrewarmsParseOnce
//       BREAK: in `MarkdownParseCache.scan` replace `let needsParse = !job.storedKeys.contains { $0.matches(key) }` by `let needsParse = true`.
//       FAILS with: "an identical request was parsed again: parseCount 2".
//   18  testLoadPrewarmRequestedAfterResetIsKept
//       BREAK: in `MarkdownParseCache.finish` make `supersededByIdentical` always false.
//       FAILS with: "the book was parsed twice" (the stale job's result is thrown away and the pending request parses it again).
//   19  testUndelayedPrewarmStartsBeforeTheMainActorYields
//       BREAK: in `MarkdownParseCache.prewarm` make the last line `if let startAt = request.startAt { schedule(request, startAt: startAt) }`
//       and start an undelayed request from a `Task { self.start(request) }` (the work starts in a main-actor Task again).
//       FAILS with: "an undelayed request had not started when the call returned".
//   20  testUndelayedPrewarmIsNotStarvedByABusyMainActor
//       BREAK: in `MarkdownParseCache.start` wrap the `Task.detached` in `Task { @MainActor in ... }` (the spawn waits for a free main actor).
//       FAILS with: "the detached job had not started while the main actor was busy".
//   21  testEditorModeChangeRequestsTheLoadPrewarmAfterTheReset
//       BREAK: delete the line `if mode == .source { requestMarkdownLoadPrewarm(...) }` in `EditorViewState.handleEditorModeChange`
//       (MarkdownScanMemo.swift).
//       FAILS with: "the load prewarm asked for after the reset was not stored".
//   22  testBridgedCandidateHitsLikeAContiguousOne
//       BREAK: in `MarkdownScanMemo.sameText` return false for a candidate that is not `isContiguousUTF8`.
//       FAILS with: "a bridged candidate text missed the scan memo".
//   23  testSkippedTextBecomesTheNewestScanEntry
//       BREAK: delete the `scans.touch(stripped:projectId:)` call in `MarkdownParseCache.finish`.
//       FAILS with: "the skipped text was evicted from the scan memo".
//   24  testDelayedRequestReplacingAnUndelayedPendingOneKeepsItsImmediateStart
//       BREAK: in `MarkdownParseCache.prewarm` delete `keepsImmediateStart ? nil :` from the `startAt:` argument.
//       FAILS with: "the post-click request waited for the typing-pause delay".
//

import Foundation
import os
import Testing
@testable import final_final

extension MarkdownParseCacheTests {

    /// Points `DocumentManager.shared` at the rig's project for one synchronous call and puts it back (the load prewarm reads the open
    /// project from it).
    private func withRigAsOpenProject<T>(_ rig: MarkdownWriterRig, _ body: (DocumentManager) -> T) -> T {
        let documentManager = DocumentManager.shared
        let (priorDatabase, priorProjectId) = (documentManager.projectDatabase, documentManager.projectId)
        documentManager.projectDatabase = rig.db
        documentManager.projectId = rig.pid
        defer {
            documentManager.projectDatabase = priorDatabase
            documentManager.projectId = priorProjectId
        }
        return body(documentManager)
    }

    // MARK: - 18

    @Test("18: the load prewarm asked for right after reset() is kept, and parsed once; one asked for only before the reset is wiped")
    func testLoadPrewarmRequestedAfterResetIsKept() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let cache = rig.markdownWriter.parseCache
        rig.editorState.sourceContent = try rig.storedText()
        func requestLoadPrewarm() {
            withRigAsOpenProject(rig) { rig.editorState.requestMarkdownLoadPrewarm(documentManager: $0) }
        }

        // Asked for once and reset after: the job has started, its result is dropped (nothing asked for the same entry).
        requestLoadPrewarm()
        rig.markdownWriter.reset()
        await cache.settled()
        #expect(cache.entries.isEmpty, "premise: a request made only before the reset is wiped by it")

        // The Rich Text -> Markdown switch: the ready callback's request starts a job, the reset follows, the onChange asks again for the
        // same entry. The job's result is kept and the second request dropped: the book is parsed ONCE, not twice.
        let parsedBefore = cache.parseCount
        let startedBefore = cache.startedCount
        requestLoadPrewarm()
        rig.markdownWriter.reset()
        requestLoadPrewarm()
        await cache.settled()
        #expect(cache.entries.count == 1, "the load prewarm requested after reset() was not stored")
        #expect(
            cache.parseCount == parsedBefore + 1 && cache.startedCount == startedBefore + 1,
            "the book was parsed twice: parseCount \(cache.parseCount - parsedBefore), startedCount \(cache.startedCount - startedBefore)")

        // A third identical request (a later ready callback) parses nothing.
        requestLoadPrewarm()
        await cache.settled()
        #expect(cache.parseCount == parsedBefore + 1 && cache.skipCount == 1, "the third identical load request was parsed again")
    }

    // MARK: - 21

    @Test("21: switching to Markdown asks for the load prewarm after the reset (kept, parsed once); switching to Rich Text asks for nothing")
    func testEditorModeChangeRequestsTheLoadPrewarmAfterTheReset() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let cache = rig.markdownWriter.parseCache
        rig.editorState.sourceContent = try rig.storedText()
        rig.editorState.blockReparseTask = Task { try? await Task.sleep(for: .seconds(60)) }

        // The editor's ready callback came first (its request starts a job); then the editorMode onChange runs: reset, then the request again.
        withRigAsOpenProject(rig) { rig.editorState.requestMarkdownLoadPrewarm(documentManager: $0) }
        withRigAsOpenProject(rig) { rig.editorState.handleEditorModeChange(to: .source, documentManager: $0) }
        #expect(rig.editorState.blockReparseTask == nil, "the pending re-parse of the editor that went away was not cancelled")
        await cache.settled()
        #expect(cache.entries.count == 1, "the load prewarm asked for after the reset was not stored")
        #expect(cache.parseCount == 1 && cache.startedCount == 1, "the book was parsed more than once")

        // Switching to Rich Text resets the writer (the memo is emptied) and asks for nothing.
        withRigAsOpenProject(rig) { rig.editorState.handleEditorModeChange(to: .wysiwyg, documentManager: $0) }
        await cache.settled()
        #expect(cache.entries.isEmpty && cache.startedCount == 1, "switching to Rich Text requested a prewarm or left the memo behind")
    }

    // MARK: - 19 and 20: an undelayed request does not wait for the main actor to START

    /// Keeps the calling thread busy for `seconds` (the main thread, in these tests: a synchronous section that keeps the main actor busy).
    /// A plain function, not async.
    private static func keepMainBusy(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test("19: an undelayed prewarm has started its background work when the call returns; a delayed one has not")
    func testUndelayedPrewarmStartsBeforeTheMainActorYields() async throws {
        let project = try makeProject()
        let text = Self.article.markdown
        let undelayed = MarkdownParseCache()
        undelayed.prewarm(raw: text, projectId: project.pid, database: project.db, names: Self.defaultNames)
        // Nothing has suspended between the call and these checks.
        #expect(undelayed.isRunning && undelayed.startedCount == 1, "an undelayed request had not started when the call returned")

        let delayed = MarkdownParseCache()
        delayed.prewarm(raw: text, projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(60))
        #expect(!delayed.isRunning && delayed.startedCount == 0, "a delayed request started at once")
        delayed.reset()

        await undelayed.settled()
        #expect(undelayed.entries.count == 1 && undelayed.parseCount == 1, "premise: the started job stored its entry")
        #expect(delayed.startedCount == 0, "the delayed request ran after its reset")
    }

    @Test("20: an undelayed prewarm made while the main actor is kept busy runs its work meanwhile and is stored once the section ends")
    func testUndelayedPrewarmIsNotStarvedByABusyMainActor() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let started = OSAllocatedUnfairLock(initialState: false)
        cache.testBackgroundStarted = { started.withLock { $0 = true } }
        cache.prewarm(raw: Self.book6.markdown, projectId: project.pid, database: project.db, names: Self.defaultNames)

        // A synchronous section keeps the main actor busy for a fixed half second. If the work could only start once the main actor is
        // free (a `Task` on the main actor spawning it), the job would not have begun when the section ends.
        Self.keepMainBusy(seconds: 0.5)
        #expect(started.withLock { $0 }, "the detached job had not started while the main actor was busy")
        #expect(cache.entries.isEmpty && cache.scans.entries.isEmpty, "premise: nothing could be stored while the main actor was busy")

        // The section is over: the results are stored.
        await cache.settled()
        #expect(cache.entries.count == 1 && cache.parseCount == 1, "the parse was not stored once the main actor was free")
        #expect(cache.scans.entries.count == 1, "the scans were not stored once the main actor was free")
    }

    // MARK: - 24

    @Test("24: a delayed request that replaces an undelayed pending one keeps the immediate start: it runs when the running job ends")
    func testDelayedRequestReplacingAnUndelayedPendingOneKeepsItsImmediateStart() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let first = Self.article.markdown + "\n\nOne."
        let second = Self.article.markdown + "\n\nTwo."
        // While the first job runs: an undelayed request waits behind it, then a DELAYED request for the same text replaces it (the
        // content change a command's adopt causes).
        cache.testBeforeStore = {
            cache.testBeforeStore = nil
            cache.prewarm(raw: second, projectId: project.pid, database: project.db, names: Self.defaultNames)
            cache.prewarm(raw: second, projectId: project.pid, database: project.db, names: Self.defaultNames, after: .seconds(30))
        }
        cache.prewarm(raw: first, projectId: project.pid, database: project.db, names: Self.defaultNames)

        var waited = 0
        while cache.startedCount < 2 && waited < 500 {   // up to 5 s: the second job must start when the first ends, not 30 s later
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(cache.startedCount == 2, "the post-click request waited for the typing-pause delay")
        cache.reset()   // nothing is wanted any more; takes back a waiting delayed request, if the start was wrongly delayed
        await cache.settled()
    }

    // MARK: - 22

    @Test("22: a bridged (Foundation-backed) candidate text hits the scan memo and the parse memo exactly as the contiguous text does")
    func testBridgedCandidateHitsLikeAContiguousOne() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let book = Self.book6.markdown
        cache.prewarm(raw: book, projectId: project.pid, database: project.db, names: Self.defaultNames)
        await cache.settled()

        func bridgedCopy(of text: String) throws -> String {
            let units = Array(text.utf16)
            let nsString = try units.withUnsafeBufferPointer { NSString(characters: try #require($0.baseAddress), length: $0.count) }
            return nsString as String
        }
        let bridged = try bridgedCopy(of: book)
        #expect(!bridged.isContiguousUTF8, "premise: the candidate is a bridged string without contiguous UTF-8")

        let contiguousEntry = try #require(cache.scans.entry(forStripped: book, projectId: project.pid))
        let found = cache.scans.entry(forStripped: bridged, projectId: project.pid)
        let bridgedEntry = try #require(found, "a bridged candidate text missed the scan memo")
        #expect(Key.sameBytes(bridgedEntry.stripped, contiguousEntry.stripped))
        let hitsBefore = cache.scans.hitCount
        #expect(Self.sameStrings(cache.scans.citekeys(for: bridged, projectId: project.pid), contiguousEntry.citekeys))
        #expect(Self.sameStrings(cache.scans.footnoteRefs(for: bridged, projectId: project.pid), contiguousEntry.footnoteRefs))
        #expect(cache.scans.hitCount == hitsBefore + 2, "the consumers' lookups with a bridged candidate were not hits")
        let key = Key(text: bridged, projectId: project.pid, notesTitle: nil, bibliographyHeaderName: "Bibliography", graceNames: [])
        #expect(Key.sameBytes(key.text, book) && Key.sameBytes(bridged, book), "the bridged text differs from the contiguous one")

        // One letter different still misses, bridged or not.
        let changed = try bridgedCopy(of: try Self.changingOneLetterInTheMiddle(of: book))
        #expect(cache.scans.entry(forStripped: changed, projectId: project.pid) == nil, "a changed bridged text was a hit")
        #expect(!Key.sameBytes(changed, book))
    }

    // MARK: - 23

    @Test("23: a text that is requested again (skipped, already stored) becomes the newest scan entry, so a third text evicts the other one")
    func testSkippedTextBecomesTheNewestScanEntry() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        func ask(_ suffix: String) async {
            cache.prewarm(raw: Self.article.markdown + "\n\n" + suffix, projectId: project.pid, database: project.db, names: Self.defaultNames)
            await cache.settled()
        }
        func scanned(_ suffix: String) -> Bool {
            cache.scans.entry(forStripped: Self.article.markdown + "\n\n" + suffix, projectId: project.pid) != nil
        }
        await ask("A")
        await ask("B")                    // scan entries: A, B
        await ask("A")                    // skipped: A is the live text again, so it becomes the newest: B, A
        #expect(cache.skipCount == 1, "premise: the second request for A was skipped")
        await ask("C")                    // evicts the oldest: B
        #expect(scanned("A") && scanned("C"), "the skipped text was evicted from the scan memo")
        #expect(!scanned("B"), "the older text stayed in the scan memo")
    }

    // MARK: - 17

    @Test("17: a request whose full key is already stored (or stored while it waited) parses nothing; a different text or project still parses")
    func testIdenticalPrewarmsParseOnce() async throws {
        let project = try makeProject()
        let cache = MarkdownParseCache()
        let base = Self.article.markdown
        func ask(_ raw: String, in project: (db: ProjectDatabase, pid: String)) async {
            cache.prewarm(raw: raw, projectId: project.pid, database: project.db, names: Self.defaultNames)
            await cache.settled()
        }
        func counts() -> String { "parseCount \(cache.parseCount), skipCount \(cache.skipCount)" }

        // The page's raw text after a command (trigger iii's input) parses once.
        let pageA = Self.pageText(from: base)
        let recordA = MarkdownLeaderMap.recordText(fromRaw: pageA)
        await ask(pageA, in: project)
        #expect(cache.parseCount == 1 && cache.skipCount == 0, "premise: the first request parses: \(counts())")

        // The same request again parses nothing.
        await ask(pageA, in: project)
        #expect(cache.parseCount == 1 && cache.skipCount == 1, "an identical request was parsed again: \(counts())")

        // The same text as the content record holds it (trigger ii's input: anchors and marker already stripped) is the same key.
        await ask(recordA, in: project)
        #expect(cache.parseCount == 1 && cache.skipCount == 2, "the stripped form of a stored text was parsed again: \(counts())")

        // A different text still parses.
        await ask(base + "\n\nAnother paragraph, unlike the first.", in: project)
        #expect(cache.parseCount == 2 && cache.skipCount == 2 && cache.entries.count == 2, "a different text was not parsed: \(counts())")

        // A skipped request makes its stored entry the newest again (it is the live text; it must outlive the others).
        await ask(pageA, in: project)
        #expect(cache.parseCount == 2 && cache.skipCount == 3, "an older stored text was parsed again: \(counts())")
        #expect(cache.entries.last.map { Key.sameBytes($0.key.text, recordA) } == true, "the skipped request's entry was not made the newest")

        // An identical request made WHILE the first one runs is compared when it starts, after the first has stored its entry.
        let third = base + "\n\nA third text, unlike the others."
        cache.testBeforeStore = {
            cache.testBeforeStore = nil
            cache.prewarm(raw: third, projectId: project.pid, database: project.db, names: Self.defaultNames)
        }
        await ask(third, in: project)
        #expect(cache.parseCount == 3 && cache.skipCount == 4, "an identical request made while the first ran was parsed again: \(counts())")

        // The project is part of the key: the same text for another project parses.
        let other = try makeProject()
        await ask(third, in: other)
        #expect(cache.parseCount == 4 && cache.skipCount == 4, "the same text for another project was skipped: \(counts())")
    }
}
