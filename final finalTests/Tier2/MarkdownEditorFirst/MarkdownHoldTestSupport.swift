//
//  MarkdownHoldTestSupport.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 3: shared helpers for the tests of the Markdown
//  writer's structural hold (`MarkdownWriterStructuralHoldTests`).
//
//    - `startDeleteJob(heading:)`   a REAL `SectionDeleteJob` through the writer's queue (the background half of a Delete Section),
//                                   returned once it holds its place in the queue.
//    - `writeNow(bypassingStructuralHold:)`   the bibliography flush hook's `writeNow` with the production guard set.
//    - `runWithin(_:_:)`            runs work in its own Task and gives up after a deadline WITHOUT cancelling or joining it, so a
//                                   deadlocked run is reported instead of hanging the suite.
//
//  Nothing here sleeps except `runWithin`'s 10 ms poll for a deadline.
//

import Foundation
import Testing
@testable import final_final

/// A flag a test sets from a `@Sendable` closure or a Task.
final class HoldTestFlag: @unchecked Sendable {
    var value = false
}

@MainActor
private final class CompletionBox<T> {
    var value: T?
    var finished = false
}

/// Runs `work` in its own Task and waits at most `seconds` for it. Returns its value, or nil when the deadline passed first. The
/// Task is left running on purpose (a deadlocked one can only be freed by the test releasing whatever it waits on).
@MainActor
func runWithin<T>(_ seconds: Double, _ work: @escaping @MainActor () async -> T) async -> T? {
    let box = CompletionBox<T>()
    Task { @MainActor in
        box.value = await work()
        box.finished = true
    }
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !box.finished, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return box.finished ? box.value : nil
}

@MainActor
extension MarkdownWriterRig {

    typealias DeleteJobResult = SystemWriteResult<SectionDeleteJob.Output>

    /// Starts a real section-delete job for the section whose heading reads `title` and returns its Task as soon as the job holds
    /// its place in the writer's queue (`onReserved`, the same signal the click path waits for). Whatever was reserved before
    /// it is ordered ahead of it; a held system sequence (`hold()`) keeps it from running.
    func startDeleteJob(heading title: String) async throws -> Task<DeleteJobResult, Never> {
        let root = try #require(try heading(title))
        return await startDeleteJob(rootBlockId: root.id)
    }

    /// The same with an explicit root id (a root that is no deletable section makes the job fail, which is how a test makes one fail).
    func startDeleteJob(rootBlockId: String) async -> Task<DeleteJobResult, Never> {
        let job = SectionDeleteJob(
            opId: UUID(), rootBlockId: rootBlockId, projectId: pid,
            fallbackBibliographyTitle: "Bibliography", slots: SectionDeleteSlotStore())
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let sync = sync
        var started: Task<DeleteJobResult, Never>?
        await withCheckedContinuation { (reserved: CheckedContinuation<Void, Never>) in
            started = Task { @MainActor in
                await job.perform(on: sync, identity: identity, registry: EFJobRegistry(), onReserved: { reserved.resume() })
            }
        }
        guard let started else { preconditionFailure("the job's Task was created inside the continuation") }
        return started
    }

    /// `writeNow` with the production guard set. `bypassingStructuralHold: true` is the click's own mismatch flush (plan B1).
    func writeNow(bypassingStructuralHold: Bool) async -> MarkdownBlockWriter.WriteNowOutcome {
        let pid = pid
        let editorState = editorState
        return await markdownWriter.writeNow(
            overrideContent: nil,
            editorState: editorState,
            bypassingStructuralHold: bypassingStructuralHold,
            guardsHold: { ContentView.bibliographyFlushGuardsHold(editorState, scheduledForProjectId: pid) },
            refire: {})
    }
}
