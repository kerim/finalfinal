//
//  MarkdownParseCacheTests+Switch.swift
//  final finalTests
//
//  t-2fbe4c9b Phase 4c job 3, round C9: the TEST-ONLY SWITCH `FF_UI_TESTING_NO_PARSE_MEMO=1` (`TestMode.isUITestingNoParseMemo`), which turns
//  the parse memo and the handler scan memo OFF so that the same build can run with and without the job-3 background work. A second part of
//  `MarkdownParseCacheTests` (the same suite, an extension in its own file). NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  The environment variable can only be set for a launched app, so the unit test injects the SAME effect the way the neighbouring knob
//  `FF_UI_TESTING_MD_LEGACY_REPARSE` is injected (`MarkdownBlockWriter(isLegacyReparse:)`): the writer's init takes
//  `parseMemoDisabled`, whose default is `TestMode.isUITestingNoParseMemo` (the variable, read once). The test below asserts that the
//  variable itself is inert in a unit-test run (`isUITesting` is false there), and that the injected switch has the full effect.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows. Every function named
//  here is in MarkdownParseCache.swift or TestMode.swift. The guards in `lookup`, `store`, `prewarm` and `ensure` cover each other for
//  the memo's CONTENT (a disabled memo is never filled), so the breaks below are the ones this test can tell apart:
//
//   32  testNoParseMemoSwitchTurnsTheMemoOff
//       BREAK A: delete the `guard !isDisabled else { return }` at the top of `MarkdownParseCache.prewarm`.
//       FAILS with: "a prewarm started background work with the memo switched off".
//       BREAK B: delete the `guard !isDisabled else { return }` in `MarkdownParseCache.store(_:blocks:endsOpen:)`.
//       FAILS with: "the memo kept an entry although it is switched off" (and the second prepare says cache=hit).
//       BREAK C: in `MarkdownBlockWriter.init` pass `parseMemoDisabled` nowhere (build the cache with `MarkdownParseCache()`).
//       FAILS with: "premise: the writer passed the switch to its memo".
//       NOT told apart by this test: the `!isDisabled` in `lookup` and the `if isDisabled { return .none }` in `ensure`. With the other
//       guards in place nothing is ever stored or asked for, so those two only save the main thread a key build and a lookup; they are
//       the same one-`Bool` check and are read in the code. The `isUITesting &&` in `TestMode.isUITestingNoParseMemo` is checked by the
//       first `#expect` only when the variable is set in the test process.
//

import Foundation
import Testing
@testable import final_final

extension MarkdownParseCacheTests {

    // MARK: - 32

    @Test("32: with the NO_PARSE_MEMO switch on, a prepare parses and says cache=miss, prewarms store and start nothing, and ensure returns at once")
    func testNoParseMemoSwitchTurnsTheMemoOff() async throws {
        let rig = try MarkdownWriterRig(content: Self.article.markdown)
        let loaded = try rig.storedText()
        let typed = try Self.typedEdit(of: loaded, rows: try rig.rows())
        #expect(!TestMode.isUITestingNoParseMemo, "the variable switched the memo off outside a UI test")
        #expect(!rig.markdownWriter.parseCache.isDisabled, "premise: a writer made without the switch has the memo on")

        let writer = MarkdownBlockWriter(parseMemoDisabled: true)
        writer.noteLoaded(text: loaded, pid: rig.pid)
        let cache = writer.parseCache
        #expect(cache.isDisabled, "premise: the writer passed the switch to its memo")

        // Every way of asking for a background parse does nothing: no job, no entry, no scans, no pending request.
        writer.prewarmParse(raw: typed, projectId: rig.pid, database: rig.db)
        writer.prewarmParseAfterTypingPause(raw: typed, projectId: rig.pid, database: rig.db)
        cache.prewarm(raw: typed, projectId: rig.pid, database: rig.db, names: Self.defaultNames)
        cache.prewarm(raw: typed, projectId: rig.pid, database: rig.db, names: Self.defaultNames, after: .milliseconds(10))
        #expect(cache.startedCount == 0 && !cache.isRunning, "a prewarm started background work with the memo switched off")
        await cache.settled()   // nothing is waiting: returns at once
        #expect(cache.entries.isEmpty && cache.scans.entries.isEmpty, "a prewarm stored something with the memo switched off")
        #expect(cache.scans.stripped(forRaw: typed) == nil, "the scan memo answered with the memo switched off")

        // ensure returns at once, even though a request for exactly this text was asked for above (it would wait if the switch were not on).
        let outcome = await cache.ensure(raw: typed, projectId: rig.pid, database: rig.db, timeout: .seconds(5))
        #expect(outcome == .none, "ensure did not return at once with the memo switched off: \(outcome)")
        #expect(cache.ensureWaiterCount == 0)

        // A prepare parses on the main thread and says so; the same text again misses again (nothing was stored).
        _ = underStableSettings { writer.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {}) }
        while let pending = writer.inFlight { await pending.value }
        let firstLine = writer.lastTimingLine ?? "nil"
        #expect(firstLine.contains("cache=miss"), "the first prepare did not parse on the main thread: \(firstLine)")
        #expect(!firstLine.contains("parse=0.0ms"), "a miss parses: \(firstLine)")
        #expect(cache.entries.isEmpty, "the memo kept an entry although it is switched off")

        _ = underStableSettings { writer.prepareAndStart(text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {}) }
        while let pending = writer.inFlight { await pending.value }
        let secondLine = writer.lastTimingLine ?? "nil"
        #expect(secondLine.contains("cache=miss"), "the second prepare of the same text hit although the memo is switched off: \(secondLine)")
        #expect(cache.hitCount == 0 && cache.missCount >= 2, "hits \(cache.hitCount), misses \(cache.missCount)")
    }
}
