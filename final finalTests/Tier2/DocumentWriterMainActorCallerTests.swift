//
//  DocumentWriterMainActorCallerTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C1 (slice-3a-1b-everyday.md §5.1 items 4 and 7, obligation N19):
//  `DocumentWriter(assertsMainActorCallers:)`. `reserve`, `reserveSystem`, `enqueueBarrier` and `retire`
//  assert they are called on the MainActor when the flag is set, so a sequence can never be reserved on
//  a writer another task is retiring (the `skipAllReserved` -> `retired = true` gap, N19). BlockSyncService
//  passes `true` for every writer it creates; writer unit tests build writers without the flag and are
//  unaffected.
//
//  The assertion itself stops the process when violated, so it cannot be driven from a test. These tests
//  pin what can be observed: the flag, who sets it (including after a writer replacement), that the four
//  entry points keep working from the MainActor on a flagged writer, and the DEBUG accessors the later
//  rounds' tests read (`BlockSyncService.testWriterHandle`, `DocumentWriter.testOpenBarrierSeq`).
//

import Foundation
import Testing
@testable import final_final

@Suite("DocumentWriter MainActor-caller assertion (N19) — Tier 2 (t-94369a83 3a-1b C1)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DocumentWriterMainActorCallerTests {

    @Test("A writer built the ordinary way does not assert; assertsMainActorCallers: true sets the flag")
    func flagDefaultsOffAndCanBeSet() throws {
        let db = try TestFixtureFactory.createTemporary()
        let pid = try TestFixtureFactory.getProjectId(from: db)
        #expect(DocumentWriter(database: db, projectId: pid).assertsMainActorCallers == false)
        #expect(DocumentWriter(database: db, projectId: pid, firstSequence: 5).assertsMainActorCallers == false)
        #expect(DocumentWriter(database: db, projectId: pid, assertsMainActorCallers: true).assertsMainActorCallers)
    }

    @Test("BlockSyncService passes true for the writer it creates in configure, and for the ones that replace it")
    func blockSyncServiceWritersAssert() async throws {
        let stack = try makeStack()
        #expect(stack.sync.testWriterHandle?.assertsMainActorCallers == true, "configure's writer")
        let first = try #require(stack.sync.testWriterHandle)

        // reconfigure (project switch): a new writer, same flag.
        let otherDb = try TestFixtureFactory.createTemporary()
        let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)
        await stack.sync.reconfigure(database: otherDb, projectId: otherPid)
        let second = try #require(stack.sync.testWriterHandle)
        #expect(second !== first, "reconfigure installs a new writer")
        #expect(second.assertsMainActorCallers == true, "reconfigure's writer")

        // configure with a different database: the replacement branch.
        let thirdDb = try TestFixtureFactory.createTemporary()
        let thirdPid = try TestFixtureFactory.getProjectId(from: thirdDb)
        let webView = stack.webView
        stack.sync.configure(database: thirdDb, projectId: thirdPid, webView: webView)
        let third = try #require(stack.sync.testWriterHandle)
        #expect(third !== second, "configure with a different database installs a new writer")
        #expect(third.assertsMainActorCallers == true, "configure's replacement writer")
    }

    @Test("""
        The four asserting entry points (reserve, reserveSystem, enqueueBarrier, retire) work as before when called from the \
        MainActor on a writer that has the flag set, and the DEBUG accessor reports the open barrier
        """)
    func entryPointsWorkFromTheMainActor_andTheOpenBarrierIsObservable() async throws {
        let db = try TestFixtureFactory.createTemporary()
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let writer = DocumentWriter(database: db, projectId: pid, assertsMainActorCallers: true)

        let editor = writer.reserve()
        #expect(editor.seq == 1)
        let system = writer.reserveSystem()
        #expect(system.seq == 2)
        #expect(writer.testOpenBarrierSeq == nil, "no barrier yet")

        let barrier = try #require(writer.enqueueBarrier())
        #expect(barrier.seq == 3)
        #expect(writer.testOpenBarrierSeq == 3, "the open barrier's sequence is observable")
        #expect(writer.enqueueBarrier() == nil, "one barrier at a time (I-BAR), unchanged by the assertion")

        barrier.release()
        #expect(writer.testOpenBarrierSeq == nil, "released: no open barrier")

        let second = try #require(writer.enqueueBarrier())
        writer.retire(reason: .close)
        #expect(writer.testOpenBarrierSeq == nil, "retire drops an open barrier")
        _ = second
        #expect(writer.enqueueBarrier() == nil, "a retired writer grants no barrier")
    }
}
