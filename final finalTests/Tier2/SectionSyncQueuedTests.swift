//
//  SectionSyncQueuedTests.swift
//  final finalTests
//
//  Phase 5 job B3-0 (SectionSyncQueued, `docs/architecture/write-queue-plan/phase5/b2-b4-design.md` section 3.7): the section
//  sync's two writes (the `section` table and the content row) are one system write on the writer's queue. A run overtaken by a
//  newer one writes nothing, the content row ends equal to the newest text, and the order is the queue's.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@MainActor
private func waitUntil(timeout seconds: Double, _ condition: @MainActor () throws -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if (try? condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? condition()) == true
}

@Suite("Section sync on the writer's queue (Phase 5 B3-0, Tier 2)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SectionSyncQueuedTests {

    private func contentRow(_ stack: TestStack) throws -> String? {
        try stack.db.fetchContent(for: stack.pid)?.markdown
    }

    private func sectionTitles(_ stack: TestStack) throws -> [String] {
        try stack.db.fetchSections(projectId: stack.pid).map(\.title)
    }

    /// Holds the writer's queue: a system write reserved now and run only when the test says so.
    private func plugQueue(_ stack: TestStack) throws -> ReservedSystemWrite {
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        guard case .held(let plug) = stack.sync.reserveSystemWriteNow(identity: identity) else {
            Issue.record("could not reserve the plug")
            throw CancellationError()
        }
        return plug
    }

    private func releasePlug(_ plug: ReservedSystemWrite, _ stack: TestStack, writing markdown: String? = nil) async {
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let pid = stack.pid
        _ = await stack.sync.runReservedSystemWrite(plug, kind: .structuralReplace, identity: identity) { db, _ in
            if let markdown { try ProjectDatabase.saveContent(db: db, markdown: markdown, projectId: pid) }
            return SystemWriteBody(value: true)
        }
    }

    private func makeService(_ stack: TestStack) -> SectionSyncService {
        let service = SectionSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)
        return service
    }

    @Test("two debounced runs queued behind a held write: the older writes nothing, the newer writes; the content row is the newer text")
    func overtakenDebouncedRunWritesNothing() async throws {
        let stack = try makeStack()
        let service = makeService(stack)
        let plug = try plugQueue(stack)   // systemWriteInFlight 1

        let older = "# Alpha\n\nolder text.\n\n# Beta\n\nfour five six.\n"
        let newer = "# Alpha\n\nnewer text.\n\n# Gamma\n\nseven.\n"
        service.contentChanged(older)
        #expect(await waitUntil(timeout: 5) { stack.editorState.systemWriteInFlight == 2 })   // the older run is queued
        service.contentChanged(newer)
        #expect(await waitUntil(timeout: 5) { stack.editorState.systemWriteInFlight == 3 })   // the newer run is queued

        await releasePlug(plug, stack)
        #expect(await waitUntil(timeout: 5) { service.testSectionSyncOutcomes.count == 2 })
        #expect(service.testSectionSyncOutcomes == ["overtaken at turn", "written"])
        #expect(try contentRow(stack) == newer)
        #expect(try sectionTitles(stack) == ["Alpha", "Gamma"])
    }

    @Test("an explicit sync queued behind a write that changed the content row lands after it (the queue's order)")
    func explicitSyncLandsInQueueOrder() async throws {
        let stack = try makeStack()
        let service = makeService(stack)
        let plug = try plugQueue(stack)

        let text = "# Alpha\n\nqueued text.\n\n# Beta\n\nfour five six.\n"
        let sync = Task { await service.syncNow(text) }
        #expect(await waitUntil(timeout: 5) { stack.editorState.systemWriteInFlight == 2 })
        // Nothing was written while the queue was held: before B3-0 the write went straight to the database here.
        #expect(try contentRow(stack) != text)

        await releasePlug(plug, stack, writing: "# Plug\n\nwritten by the earlier job.\n")
        await sync.value
        #expect(service.testSectionSyncOutcomes == ["written"])
        #expect(try contentRow(stack) == text)
    }

    @Test("two explicit syncs in a row both write, in order, and the content row ends equal to the newest text")
    func twoExplicitSyncsEndOnNewest() async throws {
        let stack = try makeStack()
        let service = makeService(stack)
        let plug = try plugQueue(stack)

        let first = "# Alpha\n\nfirst.\n"
        let second = "# Alpha\n\nsecond.\n\n# Beta\n\nmore.\n"
        let one = Task { await service.syncNow(first) }
        #expect(await waitUntil(timeout: 5) { stack.editorState.systemWriteInFlight == 2 })
        let two = Task { await service.syncNow(second) }
        #expect(await waitUntil(timeout: 5) { stack.editorState.systemWriteInFlight == 3 })

        await releasePlug(plug, stack)
        await one.value
        await two.value
        #expect(service.testSectionSyncOutcomes == ["written", "written"])
        #expect(try contentRow(stack) == second)
        #expect(try sectionTitles(stack) == ["Alpha", "Beta"])
    }

    @Test("a run older than one already written writes nothing (the claim inside the transaction)")
    func olderRunNeverWritesAfterNewer() {
        let order = SectionSyncWriteOrder()
        #expect(order.claim(2))
        #expect(!order.claim(1))
        #expect(!order.claim(2))
        #expect(order.claim(3))
    }

    @Test("with no writer wired the sync writes directly, as before B3-0")
    func unwiredServiceWritesDirectly() async throws {
        let stack = try makeStack()
        let service = SectionSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        let text = "# Alpha\n\ndirect.\n"
        await service.syncNow(text)
        #expect(try contentRow(stack) == text)
        #expect(service.testSectionSyncOutcomes.isEmpty)
    }
}
