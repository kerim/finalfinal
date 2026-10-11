//
//  MarkdownBibliographyFlushTests+Fallback.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, code-review fix round (judge R1 and R2): what the bibliography flush does when its own per-block
//  write does NOT land. The rebuild that follows the flush reads the ROWS and pushes them over the screen, so the rows must
//  carry the user's typing: whenever the write failed, was skipped, was refused or never got a turn, and every guard still
//  holds, `writeNow` answers `.fallBackToDirectWrite` (the direct write this hook always made before Phase 4a). When a guard
//  no longer holds (a lifecycle armed, the mode changed...) it writes nothing and RE-ARMS the debounce, so the typing is still
//  saved by the normal fire.
//
//    - the writer belongs to another project: no turn can be reserved -> fallback, and the real hook then writes the text
//    - the apply FAILS (an injected database error) -> fallback
//    - the waiting turn is SKIPPED (a drain or switch retired the writer): guards hold -> fallback; a lifecycle armed -> nothing
//      written, re-armed (`.abandoned`)
//    - a guard that fails after the wait for the write in flight re-arms the debounce (R2), and the typed paragraph lands
//
//  Same serialized suite as `MarkdownBibliographyFlushTests`; none of these needs the Zotero singleton.
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension MarkdownBibliographyFlushTests {

    private static let fallbackBase = "# Alpha\n\nOne.\n\nTwo.\n\n# Beta\n\nFour."
    private static let fallbackTyped = fallbackBase.replacingOccurrences(of: "Two.", with: "Two, typed.")

    /// A switch a test flips to break or restore `guardsHold` while `writeNow` waits.
    @MainActor
    final class GuardSwitch {
        var holds = true
    }

    // MARK: - R1: the write did not land

    @Test("""
        (R1) the writer belongs to another project, so no turn can be reserved: `writeNow` answers `.fallBackToDirectWrite` and the \
        real hook then writes the typed paragraph the old way, so the rows the rebuild reads carry it
        """)
    func anotherProjectsWriterFallsBackToTheDirectWrite() async throws {
        let rig = try MarkdownWriterRig(content: Self.fallbackBase)
        let other = try TestFixtureFactory.createTemporary(content: "# Other")
        let otherProjectId = try TestFixtureFactory.getProjectId(from: other)
        rig.sync.writer = DocumentWriter(database: other, projectId: otherProjectId, firstSequence: 1, assertsMainActorCallers: true)
        rig.editorState.content = Self.fallbackTyped

        #expect(await rig.writeNow() == .fallBackToDirectWrite)
        #expect(try rig.storedText() == Self.fallbackBase, "premise: `writeNow` itself wrote nothing")

        let hook = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
        await hook(rig.pid, nil)
        #expect(try rig.storedText().contains("Two, typed."), "the direct write carried the typed text into the rows")
    }

    @Test("""
        (R1) the apply FAILS (an injected database error): `writeNow` answers `.fallBackToDirectWrite` because the guards still hold; \
        the direct write that follows puts the typed text in the rows and ends the failure streak
        """)
    func aFailedWriteFallsBackToTheDirectWrite() async throws {
        let rig = try MarkdownWriterRig(content: Self.fallbackBase)
        rig.editorState.content = Self.fallbackTyped
        try rig.db.write { database in
            try database.execute(sql: "CREATE TRIGGER md_injected_failure BEFORE UPDATE ON block BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }

        let outcome = await rig.writeNow()

        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=failed") == true, "premise: the apply failed")
        #expect(outcome == .fallBackToDirectWrite)
        #expect(try rig.storedText() == Self.fallbackBase, "nothing landed")
        #expect(rig.markdownWriter.consecutiveFailures == 1)

        try rig.db.write { database in try database.execute(sql: "DROP TRIGGER md_injected_failure") }
        rig.editorState.flushContentToDatabase()   // what the hook does on `.fallBackToDirectWrite`
        #expect(try rig.storedText().contains("Two, typed."))
        #expect(rig.markdownWriter.consecutiveFailures == 0, "the direct write ends the failure streak")
    }

    @Test("""
        (R1) the waiting turn is SKIPPED (the writer was retired): with the guards holding `writeNow` answers \
        `.fallBackToDirectWrite`; with a lifecycle armed it writes nothing, answers `.abandoned` and re-arms the debounce
        """, arguments: [false, true])
    func aSkippedWriteWritesDirectlyOnlyWhenTheGuardsHold(lifecycleArmed: Bool) async throws {
        let rig = try MarkdownWriterRig(content: Self.fallbackBase)
        let parked = rig.parkedSignal()
        let held = rig.hold()
        rig.editorState.content = Self.fallbackTyped
        let flush = Task { @MainActor in await rig.writeNow() }
        await parked.wait()   // the write is reserved behind the held sequence and waits its turn

        var token: LifecycleToken?
        if lifecycleArmed {
            guard case .armed(let armed) = rig.editorState.armLifecycle(.close, wasGettingStarted: false) else {
                Issue.record("could not arm a close token")
                return
            }
            token = armed
        }
        rig.writer.retire(reason: lifecycleArmed ? .close : .projectSwitch)   // a drain or a switch skips the waiting turn
        let outcome = await flush.value
        _ = held

        let expected: MarkdownBlockWriter.WriteNowOutcome = lifecycleArmed ? .abandoned : .fallBackToDirectWrite
        #expect(outcome == expected)
        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=skipped") == true, "premise: the write was skipped")
        #expect(try rig.storedText() == Self.fallbackBase, "`writeNow` itself never writes whole documents")
        if lifecycleArmed {
            #expect(rig.refireCount >= 1, "the debounce was re-armed")
        }
        if let token { rig.editorState.clearLifecycle(token.id) }
    }

    // MARK: - R2: a guard that fails after the wait re-arms the debounce

    @Test("""
        (R2) a guard that fails after `writeNow` waited for the write in flight re-arms the debounce: nothing is written by \
        `writeNow`, a re-parse is scheduled, and it saves the typed paragraph
        """)
    func aGuardFailingAfterTheWaitReArmsTheDebounce() async throws {
        let rig = try MarkdownWriterRig(content: Self.fallbackBase, debounce: .milliseconds(5))
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.fallbackTyped) == .started)   // write 1 waits behind the held sequence
        await parked.wait()
        let newest = Self.fallbackTyped.replacingOccurrences(of: "Four.", with: "Four, newest.")
        rig.editorState.content = newest

        let guards = GuardSwitch()
        guards.holds = false
        let editorState = rig.editorState
        let flush = Task { @MainActor in
            await rig.markdownWriter.writeNow(
                overrideContent: nil, editorState: editorState, guardsHold: { guards.holds },
                refire: { _ = rig.schedule(editorState.content) })
        }
        await Task.yield()
        await Task.yield()
        await rig.release(held)
        let outcome = await flush.value

        #expect(outcome == .abandoned)
        #expect(try rig.storedText().contains("Two, typed."), "write 1 landed")
        #expect(try !rig.storedText().contains("Four, newest."), "`writeNow` wrote nothing more")
        let rearmed = try #require(editorState.blockReparseTask, "the debounce was re-armed")
        guards.holds = true
        await rearmed.value
        await rig.settle()
        #expect(try rig.storedText() == newest, "the re-armed fire saved the newest paragraph")
    }
}
