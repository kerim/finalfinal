//
//  MarkdownWriterStructuralHoldTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 3: the Markdown writer's HOLD
//  (MarkdownBlockWriter+StructuralHold.swift). Real writer, real database, a REAL `SectionDeleteJob` as the queued job. The
//  click itself (JS, reply turn, starter) is a later round; here a test plays its writer-side steps in the production order:
//
//      hold = beginStructuralHold()                       // step 2
//      prepareStructuralClick(text: textUpToTheClick)     // step 5a: the typing batch, reserved first
//      noteQueuedStructuralJob()                          // step 5b
//      startDeleteJob(...)                                // step 5d: the job, reserved behind the batch
//      ... the job applies ...
//      reserveStructuralFlush(text: liveText); hold.release()   // step 8, one synchronous turn
//
//  A held SYSTEM sequence (`rig.hold()`, reserved BEFORE everything else) keeps every reservation unapplied, so the order in
//  which things are reserved is exact and nothing depends on timing.
//
//  What the tests pin, and each one's break patch (a 1-5 line change in production code that must make it fail):
//
//   T-1   a queued job leaves the baseline on the rows.
//         BREAK: delete `version += 1` in `noteQueuedStructuralJob()` (MarkdownBlockWriter.swift).
//         FAILS with: "text baseline names deleted id" (and "baseline is not rows").
//
//   T-U3  a re-parse armed during the hold fires only after the release.
//         BREAK: in `prepare` (MarkdownBlockWriter.swift) delete the `if context.trigger == .debounceFire, isHeldForStructuralWork`
//         block. FAILS with: "a re-parse fire reserved a diff while the delete was unapplied", then "the delete job failed: a
//         re-parse had already deleted its rows" and "the held fire was not re-armed".
//
//   T-U4  the bibliography flush's `writeNow` waits while a job is unapplied.
//         BREAK: in `awaitQuietWriter` (MarkdownBlockWriter+StructuralHold.swift) delete the
//         `if !bypassingStructuralHold { await awaitStructuralHoldReleased() }` line.
//         FAILS with: "writeNow did not wait for the hold" and "the delete job failed: the flush had already deleted its rows".
//
//   D3    `writeNow` is not `inFlight` while it waits on the hold, so step 8's loop-await cannot deadlock on it.
//         BREAK: in `awaitQuietWriter` replace the same await line with
//             let parked = Task { await self.awaitStructuralHoldReleased() }; inFlight = parked; await parked.value; inFlight = nil
//         FAILS with: "writeNow published itself as inFlight while it waited on the hold" and "step 8 deadlocked".
//
//   Bypass  the two structural triggers (and the click's own `writeNow(bypassingStructuralHold: true)`) ignore the hold, and the
//         two triggers never do a whole-document write (an open fence reserves nothing and changes no baseline or epoch).
//         BREAK 1: in `prepare` drop `context.trigger == .debounceFire,` from the hold test (every trigger is held).
//         FAILS with: "the click's typing batch was held" / "typing lost".
//         BREAK 2: in `checkOpenFence` move `.structuralClick, .structuralFlush` from the `.debounceFire` case to the `.writeNow` case.
//         FAILS with: "an open fence must be skipped, not turned into a whole-document fallback".
//
//   Token   one release per token; nested holds release waiters and the refire only at zero; `requestRefire` is a no-op while held.
//         BREAK: in `lowerStructuralHold` delete `guard structuralHoldState.count == 0 else { return }`.
//         FAILS with: "the first of two holds' release ran the refire".
//
//  A note on `droppedDeletes` (the plan's T-U3/T-U4 wording): the database applies a delete of an already-missing row as a no-op and
//  does not report it as dropped (Database+Blocks.swift `processEditorDeletes`, Database+BlockWriteStamp.swift), so a stale delete
//  never shows as `droppedDeletes=N`. What a stale write really does to a Delete is run BEFORE the job and remove the rows the job
//  needs, so the job rolls back (`rootNotDeletable`) and the user would see "Couldn't Delete Section". That is what these tests
//  assert; the "applied-with-drops" timing-line check is kept as well.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown writer structural hold — Tier 2 (t-4a8fd8af, slice 1 round 3)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownWriterStructuralHoldTests {

    private static let base = "# Alpha\n\nOne.\n\n# Beta\n\nFour.\n\n# Gamma\n\nSeven."
    /// What the editor shows after the click removed Beta (the rows still hold it until the job applies).
    private static let afterDelete = "# Alpha\n\nOne.\n\n# Gamma\n\nSeven."

    private static func replacing(_ text: String, _ old: String, _ new: String) -> String {
        text.replacingOccurrences(of: old, with: new)
    }

    private func noRefire() -> @MainActor () -> Void { {} }

    // MARK: - T-1

    @Test("""
        T-1: a typing batch reserved for the click, then a queued Delete job: once both have applied the baseline is the rows, \
        no baseline entry names a deleted id, the post-apply flush (step 8, which then releases the hold) compares against the rows, \
        and the next save leaves the rows equal to the editor
        """)
    func queuedStructuralJobLeavesTheBaselineOnRows() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let beta = try #require(try rig.heading("Beta"))
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: beta.id, projectId: rig.pid))
        let held = rig.hold()
        let hold = writer.beginStructuralHold()
        defer { hold.release() }

        // The user typed inside Beta, then clicked Delete Section on Beta: the click's batch carries that typing.
        let textUpToTheClick = Self.replacing(Self.base, "Four.", "Four, typed.")
        rig.editorState.content = textUpToTheClick
        let batch = writer.prepareStructuralClick(
            text: textUpToTheClick, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
        try #require(batch == .started, "the click's typing batch is reserved")
        writer.noteQueuedStructuralJob()
        let jobTask = try await rig.startDeleteJob(heading: "Beta")

        await rig.release(held)   // the batch applies, then the job
        let result = await jobTask.value
        await rig.settle()
        guard case .applied(let output) = result.outcome else {
            Issue.record("the delete job did not apply: \(result.outcome)")
            return
        }
        let deleted = Set(output.deletedBlockIds)
        try #require(Set(subtree).isSubset(of: deleted), "premise: the job deleted Beta's rows")

        #expect(writer.baseline.isRows, "the baseline is not rows after the batch and the job applied")
        if case .text(let installed) = writer.baseline {
            #expect(!installed.entries.contains { $0.id.map(deleted.contains) ?? false }, "text baseline names deleted id")
        }

        // Step 8, as in production: after the job applied, the post-apply flush of the live text (typing in Gamma made while the
        // job ran) is reserved and the hold is released in the same synchronous turn. The hold stays up until then, so nothing
        // else can save before this. The first save after the job compares against the rows the job left.
        let liveDuringTheJob = Self.replacing(Self.afterDelete, "Seven.", "Seven, typed once.")
        rig.editorState.content = liveDuringTheJob
        let flush = writer.reserveStructuralFlush(
            text: liveDuringTheJob, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
        hold.release()
        #expect(flush != nil, "the post-apply flush found the typing made during the job")
        await flush?.value
        #expect(!writer.isHeldForStructuralWork, "premise: step 8 released the hold")
        #expect(writer.lastTimingLine?.contains("mode=rows") == true, "the first save after the job did not compare against the stored rows")
        #expect(try rig.storedText() == liveDuringTheJob, "the flush saved the typing made during the job")

        // The next save, with more typing in Gamma, now that the hold is down.
        let next = Self.replacing(liveDuringTheJob, "Seven, typed once.", "Seven, typed twice.")
        let disposition = await rig.fireAndSettle(next)
        #expect(disposition == .started, "the next save was held after the hold was released")
        #expect(writer.lastTimingLine?.contains("applied-with-drops") == false)
        #expect(writer.consecutiveFailures == 0)
        #expect(try rig.storedText() == next, "the rows equal the editor text")
        #expect(try rig.rows().count == rig.parse(next).count, "one row per parsed block")
    }

    // MARK: - T-U3

    @Test("""
        T-U3: a re-parse armed during the hold reserves nothing and stays armed: the job still finds its rows and applies, the \
        fire runs again only after the release, and then it writes nothing stale
        """)
    func reparseArmedDuringTheHoldFiresOnlyAfterTheRelease() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let held = rig.hold()
        let hold = writer.beginStructuralHold()   // the click's hold, raised before anything below
        defer { hold.release() }

        // The user typed in Alpha and clicked Delete Section on Beta. The editor has changed; the rows have not.
        let textUpToTheClick = Self.replacing(Self.base, "One.", "One, typed.")
        let live = Self.replacing(Self.afterDelete, "One.", "One, typed.")
        rig.editorState.content = live

        // The debounced re-parse comes due before the job is even reserved (the gap after the click's JS).
        let fire = rig.fire(live)
        #expect(fire == .heldForStructuralWork, "a re-parse fire reserved a diff while the delete was unapplied")
        await rig.settle()
        #expect(writer.inFlight == nil, "a held fire left a write in flight")
        #expect(try rig.rows().contains { $0.textContent == "Beta" }, "the held fire already wrote the delete itself")

        // The click's own steps: the typing batch, then the job, behind the held fire's would-be place.
        let batch = writer.prepareStructuralClick(
            text: textUpToTheClick, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
        #expect(batch == .started)
        writer.noteQueuedStructuralJob()
        let jobTask = try await rig.startDeleteJob(heading: "Beta")
        await rig.release(held)
        let result = await jobTask.value
        await rig.settle()
        if case .applied(let output) = result.outcome {
            #expect(!output.deletedBlockIds.isEmpty)
        } else {
            Issue.record("the delete job failed: a re-parse had already deleted its rows (\(result.outcome))")
        }
        #expect(rig.refireCount == 0, "the held fire was re-armed while the hold was still up")

        // The release re-arms the held fire; the re-armed fire sees rows equal to the editor and writes nothing.
        hold.release()
        #expect(rig.refireCount == 1, "the held fire was not re-armed")
        let rearmed = await rig.fireAndSettle(live)
        #expect(rearmed == .nothingToWrite, "the re-armed fire still found something to write")
        #expect(writer.lastTimingLine?.contains("applied-with-drops") == false)
        #expect(writer.consecutiveFailures == 0)
        #expect(try rig.storedText() == live, "the rows equal the editor text")
    }

    // MARK: - T-U4

    @Test("""
        T-U4: the bibliography flush's writeNow during an unapplied job waits for the release, the job applies first, and the flush \
        then finds the rows equal to the editor: no stale delete, no whole-document fallback
        """)
    func bibliographyFlushDuringAnUnappliedJobWaits() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let held = rig.hold()
        let hold = writer.beginStructuralHold()
        defer { hold.release() }
        rig.editorState.content = Self.afterDelete

        // The bibliography update's flush hook runs `writeNow` in the gap before the job is reserved.
        let returned = HoldTestFlag()
        let flush = Task { @MainActor () -> MarkdownBlockWriter.WriteNowOutcome in
            let outcome = await rig.writeNow()
            returned.value = true
            return outcome
        }
        for _ in 0..<200 where writer.structuralHoldWaiterCount == 0 && writer.inFlight == nil { await Task.yield() }
        #expect(writer.structuralHoldWaiterCount == 1, "writeNow did not wait for the hold")

        let jobTask = try await rig.startDeleteJob(heading: "Beta")
        await rig.release(held)
        let result = await jobTask.value
        if case .applied(let output) = result.outcome {
            #expect(!output.deletedBlockIds.isEmpty)
        } else {
            Issue.record("the delete job failed: the flush had already deleted its rows (\(result.outcome))")
        }
        #expect(!returned.value, "writeNow returned before the hold was released")

        hold.release()
        let outcome = await runWithin(2) { await flush.value }
        #expect(outcome == .proceeded, "the flush did not proceed (a whole-document fallback would show as fallBackToDirectWrite)")
        #expect(writer.lastTimingLine?.contains("applied-with-drops") != true)
        #expect(writer.consecutiveFailures == 0)
        #expect(try rig.storedText() == Self.afterDelete, "the rows equal the editor text")
    }

    // MARK: - D3

    @Test("""
        D3: writeNow does not publish itself as inFlight while it waits on the hold, so step 8 (loop-await inFlight, reserve the \
        flush, release, await the flush) completes within 2 s and the writeNow then returns .proceeded
        """)
    func writeNowIsNotInFlightWhileItWaitsOnTheHold() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let hold = writer.beginStructuralHold()
        defer { hold.release() }   // frees a deadlocked run, too
        let typed = Self.replacing(Self.base, "Seven.", "Seven, typed.")
        rig.editorState.content = typed

        let flush = Task { @MainActor in await rig.writeNow() }
        for _ in 0..<200 where writer.structuralHoldWaiterCount == 0 && writer.inFlight == nil { await Task.yield() }
        #expect(writer.structuralHoldWaiterCount == 1, "writeNow did not wait for the hold")
        #expect(writer.inFlight == nil, "writeNow published itself as inFlight while it waited on the hold")

        // Step 8 in the plan's order, in the job-future continuation.
        let step8 = await runWithin(2) { @MainActor () -> Bool in
            while let pending = writer.inFlight { await pending.value }
            let flushTask = writer.reserveStructuralFlush(
                text: typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {})
            hold.release()
            await flushTask?.value
            return true
        }
        #expect(step8 == true, "step 8 deadlocked on the writeNow that waits on the hold")

        let outcome = await runWithin(2) { await flush.value }
        #expect(outcome == .proceeded, "the waiting writeNow did not return .proceeded after the release")
        #expect(try rig.storedText() == typed, "the flush saved the live text")
    }

    // MARK: - The bypass triggers

    @Test("""
        the click's typing batch, the post-apply flush and the click's own writeNow ignore the hold (a debounce fire does not), \
        and each saves the typing it was given
        """)
    func structuralTriggersIgnoreTheHold() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let hold = writer.beginStructuralHold()
        defer { hold.release() }

        #expect(rig.fire(Self.base) == .heldForStructuralWork, "control: a debounce fire is held")

        let typed1 = Self.replacing(Self.base, "One.", "One, typed once.")
        rig.editorState.content = typed1
        let click = writer.prepareStructuralClick(
            text: typed1, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
        #expect(click == .started, "the click's typing batch was held")
        await rig.settle()
        #expect(try rig.storedText() == typed1, "typing lost: the click's batch did not reach the rows")

        writer.noteQueuedStructuralJob()
        let typed2 = Self.replacing(typed1, "Seven.", "Seven, typed twice.")
        rig.editorState.content = typed2
        let flush = writer.reserveStructuralFlush(
            text: typed2, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
        #expect(flush != nil, "the post-apply flush was held")
        #expect(writer.lastStructuralFlushDisposition == .started)
        await flush?.value
        #expect(try rig.storedText() == typed2, "typing lost: the flush did not reach the rows")

        let typed3 = Self.replacing(typed2, "Four.", "Four, typed thrice.")
        rig.editorState.content = typed3
        let outcome = await rig.writeNow(bypassingStructuralHold: true)
        #expect(outcome == .proceeded, "the click's own mismatch flush waited on its own hold")
        #expect(try rig.storedText() == typed3, "typing lost: the bypassing writeNow did not reach the rows")
    }

    @Test("""
        the two structural triggers never write the whole document: an open code fence reserves nothing and changes no baseline, \
        version, row or write epoch, with the hold up or down
        """)
    func structuralTriggersNeverWriteTheWholeDocument() async throws {
        for held in [true, false] {
            let rig = try MarkdownWriterRig(content: Self.base)
            let writer = rig.markdownWriter
            let hold = held ? writer.beginStructuralHold() : nil
            defer { hold?.release() }
            let open = Self.base + "\n\n```swift\nlet unfinished = 1"
            rig.editorState.content = open
            let epochBefore = try rig.db.currentBlockWriteEpoch(projectId: rig.pid)
            let versionBefore = writer.version
            let baselineBefore = writer.baseline

            let click = writer.prepareStructuralClick(
                text: open, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
            #expect(click == .skippedOpenFence, "an open fence must be skipped, not turned into a whole-document fallback (held: \(held))")
            let flush = writer.reserveStructuralFlush(
                text: open, database: rig.db, projectId: rig.pid, service: rig.sync, refire: noRefire())
            #expect(flush == nil, "an open fence reserved a flush (held: \(held))")
            #expect(writer.lastStructuralFlushDisposition == .skippedOpenFence)

            #expect(writer.inFlight == nil, "something was reserved (held: \(held))")
            #expect(try rig.storedText() == Self.base, "the rows changed (held: \(held))")
            #expect(try rig.db.currentBlockWriteEpoch(projectId: rig.pid) == epochBefore, "a whole-document write moved the epoch (held: \(held))")
            #expect(writer.version == versionBefore, "a direct write or a set-point ran (held: \(held))")
            #expect(writer.baseline == baselineBefore, "the baseline moved (held: \(held))")
        }
    }

    // MARK: - The token

    @Test("""
        a token releases once; two holds release the waiters and the kept refire only when the last is released; requestRefire does \
        nothing while a hold is up, and the kept refire runs once
        """)
    func tokenReleasesOnceAndNestedHoldsReleaseAtZero() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let writer = rig.markdownWriter
        let first = writer.beginStructuralHold()
        let second = writer.beginStructuralHold()
        #expect(writer.structuralHoldCount == 2)
        #expect(writer.isHeldForStructuralWork)

        #expect(rig.fire(Self.base) == .heldForStructuralWork)
        let resumed = HoldTestFlag()
        let waiter = Task { @MainActor in
            await writer.awaitStructuralHoldReleased()
            resumed.value = true
        }
        for _ in 0..<200 where writer.structuralHoldWaiterCount == 0 { await Task.yield() }
        #expect(writer.structuralHoldWaiterCount == 1, "premise: the waiter parked")

        writer.requestRefire()
        #expect(rig.refireCount == 0, "requestRefire ran the kept refire while a hold was up")

        first.release()
        first.release()
        #expect(writer.structuralHoldCount == 1, "the same token lowered the count twice")
        #expect(rig.refireCount == 0, "the first of two holds' release ran the refire")
        await Task.yield()
        #expect(!resumed.value, "the first of two holds' release resumed a waiter")

        second.release()
        await waiter.value
        #expect(resumed.value, "the waiter was not resumed by the last release")
        #expect(writer.structuralHoldCount == 0)
        #expect(!writer.isHeldForStructuralWork)
        #expect(rig.refireCount == 1, "the last release did not run the kept refire")

        writer.requestRefire()
        #expect(rig.refireCount == 1, "the kept refire ran twice")
    }
}
