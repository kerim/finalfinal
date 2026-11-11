//
//  BibliographyLateZoteroConnectTests.swift
//  final finalTests
//
//  Phase 7 (t-94369a83), board t-a54c1950. The first bibliography check after a book opens used to return silently when Zotero was not
//  yet marked connected, and nothing retried it, so a book whose open kept the main thread busy opened with no Bibliography until the
//  first edit (found in Phase 6 by the real-app test testReplaceSectionThenType_book12; Phase 6 only moved the connection earlier).
//  `performBibliographyUpdate` now asks Zotero itself when it finds it not connected, so the order of "the check" and "the open-time
//  connection" no longer matters.
//
//  The question to Zotero is `BibliographySyncService.connectToZotero`, a property these tests replace; the default pings Better
//  BibTeX. The suite is .serialized because the update reads `ZoteroService.shared`, a singleton (same convention as
//  BibliographySyncTests).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@MainActor
private final class ZoteroAskProbe {
    var asked = 0
    /// While true the answer is held back (a slow Better BibTeX).
    var hold = false
}

@Suite("Bibliography: Zotero not yet connected at the check (t-a54c1950)", .serialized)
struct BibliographyLateZoteroConnectTests {

    private static func makeItem(key: String, family: String) throws -> CSLItem {
        let json = """
        {"id":"\(key)","type":"book","title":"Title of \(key)","author":[{"family":"\(family)","given":"Pat"}],"issued":{"date-parts":[[2020]]}}
        """
        return try JSONDecoder().decode(CSLItem.self, from: Data(json.utf8))
    }

    @Test("Zotero not connected at the check, but answering: the check asks, connects and writes the Bibliography")
    @MainActor
    func notConnectedButReachableWritesTheBibliography() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@lateconnectA2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let item = try Self.makeItem(key: "lateconnectA2026", family: "Alpha")

        ZoteroService.shared.isConnected = false
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let probe = ZoteroAskProbe()
        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.connectToZotero = {
            probe.asked += 1
            ZoteroService.shared.isConnected = true   // what the real ping does on success
            return true
        }

        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectA2026"], projectId: projectId)
        await service.flushPendingSync()

        let bibBlocks = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography }
        #expect(probe.asked == 1, "the check asks Zotero exactly once when it finds it not connected")
        #expect(!bibBlocks.isEmpty, "the Bibliography is written although the open-time connection had not finished")
        #expect(bibBlocks.contains { $0.markdownFragment.contains("Alpha") })
        #expect(service.state == .idle)
        #expect(service.updateAttemptCount == 1)
    }

    @Test("Zotero not running: the check ends quietly, writes nothing, and the next change of the citations tries again")
    @MainActor
    func notRunningEndsQuietlyAndTheNextChangeTriesAgain() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@lateconnectB2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let item = try Self.makeItem(key: "lateconnectB2026", family: "Beta")

        ZoteroService.shared.isConnected = false
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let probe = ZoteroAskProbe()
        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.connectToZotero = {
            probe.asked += 1
            return false
        }

        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectB2026"], projectId: projectId)
        await service.flushPendingSync()

        #expect(probe.asked == 1)
        #expect(try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography }.isEmpty,
                "nothing is written while Zotero does not answer")
        #expect(service.state == .idle, "the run leaves the service ready for the next one")

        // Zotero starts later. The same citation set is checked again (the author typed something that left the citations as they
        // were): because the first run committed nothing, the check is scheduled, not skipped as "unchanged".
        service.connectToZotero = {
            probe.asked += 1
            ZoteroService.shared.isConnected = true
            return true
        }
        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectB2026"], projectId: projectId)
        #expect(service.testHasPendingUpdate, "the second check is scheduled")
        await service.flushPendingSync()

        let bibBlocks = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography }
        #expect(bibBlocks.contains { $0.markdownFragment.contains("Beta") }, "the Bibliography appears once Zotero answers")
        #expect(probe.asked == 2)
    }

    @Test("Zotero already connected: the check does not ask again")
    @MainActor
    func connectedZoteroIsNotAskedAgain() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@lateconnectC2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let item = try Self.makeItem(key: "lateconnectC2026", family: "Gamma")

        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let probe = ZoteroAskProbe()
        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.connectToZotero = {
            probe.asked += 1
            return true
        }

        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectC2026"], projectId: projectId)
        await service.flushPendingSync()

        #expect(probe.asked == 0, "a connected Zotero costs no extra request")
        #expect(try TestFixtureFactory.fetchBlocks(from: db).contains { $0.isBibliography && $0.markdownFragment.contains("Gamma") })
    }

    @Test("A newer check that arrives while Zotero is being asked supersedes the older run, which writes nothing")
    @MainActor
    func aNewerCheckDuringTheAskSupersedesTheOlderRun() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@lateconnectD2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let itemD = try Self.makeItem(key: "lateconnectD2026", family: "Delta")
        let itemE = try Self.makeItem(key: "lateconnectE2026", family: "Epsilon")

        ZoteroService.shared.isConnected = false
        ZoteroService.shared.loadItem(itemD)
        ZoteroService.shared.loadItem(itemE)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let probe = ZoteroAskProbe()
        probe.hold = true
        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.connectToZotero = {
            probe.asked += 1
            while probe.hold { try? await Task.sleep(for: .milliseconds(10)) }
            ZoteroService.shared.isConnected = true
            return true
        }

        // Check 1 schedules generation 1; its run is driven here, directly, and stops inside the ask.
        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectD2026"], projectId: projectId)
        let olderRun = Task { @MainActor in
            await service.performBibliographyUpdate(citekeys: ["lateconnectD2026"], projectId: projectId, scheduledGeneration: 1)
        }
        // Bounded: if the run never asks Zotero (the old guard), the wait must end and the assertion below say so, not hang.
        let waitUntil = Date().addingTimeInterval(5)
        while probe.asked == 0, Date() < waitUntil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.asked == 1, "the older run reached the question to Zotero")

        // Check 2 arrives while the older run waits for Zotero: the service is still idle, so it schedules generation 2.
        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectE2026"], projectId: projectId)
        probe.hold = false
        await olderRun.value

        let bibBlocks = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography }
        #expect(bibBlocks.isEmpty, "the older run, superseded while it waited, wrote nothing: \(bibBlocks.map { $0.markdownFragment })")
        #expect(service.state == .idle)

        // The newer check still runs and writes its own citations.
        await service.flushPendingSync()
        let after = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography }
        #expect(after.contains { $0.markdownFragment.contains("Epsilon") })
        #expect(!after.contains { $0.markdownFragment.contains("Delta") })
    }

    @Test("waitForFirstUpdateAttempt returns once a run has made its attempt, and not before")
    @MainActor
    func waitForFirstUpdateAttemptReturnsAfterTheFirstAttempt() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@lateconnectF2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        ZoteroService.shared.isConnected = false
        defer { ZoteroService.shared.isConnected = false }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.connectToZotero = { false }
        #expect(service.updateAttemptCount == 0)

        let waiter = Task { @MainActor in
            await service.waitForFirstUpdateAttempt(timeoutSeconds: 30)
            return service.updateAttemptCount
        }
        try await Task.sleep(for: .milliseconds(150))
        service.checkAndUpdateBibliography(currentCitekeys: ["lateconnectF2026"], projectId: projectId)
        await service.flushPendingSync()

        #expect(await waiter.value == 1, "released by the first attempt, with the count at 1")
    }
}
