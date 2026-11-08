//
//  ReportApplierTests.swift
//  final finalTests
//
//  Phase 5 job B3 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, sections 3.2 to 3.6; b3-notes.md): the editor's reports
//  as the writer's input, driven with a REAL `BlockSyncService`, `DocumentWriter` and database, and a scripted page (`ReportRig`) that
//  answers the page calls the intake makes (`reportOutboxSince`, `ackReports`, `flushReports`, the cover wrapper). Each test pins one
//  of the sync model's rules (README "Phase 5 step T2" and "T2b"); each has a break patch recorded in b3-notes.md.
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

@MainActor
final class ReportRig {
    let db: ProjectDatabase
    let pid: String
    let sync = BlockSyncService()
    let view = WKWebView()
    var session = "s1"
    /// The page's outbox: every report it posted and Swift has not acknowledged (the scripted page never prunes; tests read `acks`).
    var outbox: [Int: BlockChanges] = [:]
    private(set) var acks: [(through: Int, ids: Int)] = []
    private(set) var outboxFetches = 0
    /// `flushReports`: runs first (the page posts while it answers), then the reply names `flushThrough`.
    var onFlush: (() -> Void)?
    var flushThrough = 0
    /// The answer to a covered route call (the script wrapped by `coveredScript`): called with the script, returns the raw reply.
    var onCoveredCall: ((String) -> String?)?

    init(markdown: String = "Alpha.\n\nBravo.\n\nCharlie.") throws {
        db = try TestFixtureFactory.createTemporary(content: markdown)
        pid = try TestFixtureFactory.getProjectId(from: db)
        sync.configure(database: db, projectId: pid, webView: view)
        sync.reportApplier.dropEvery = nil
        sync.reportApplier.gapFetchDisabled = false
        sync.testJSEvaluator = { [weak self] script in self?.answer(script) }
    }

    private func answer(_ script: String) -> Any? {
        if script.contains("beginReportCover") { return onCoveredCall?(script) }
        if script.contains("reportOutboxSince") {
            outboxFetches += 1
            let since = Self.lastInt(in: script, after: "reportOutboxSince(") ?? 0
            let entries = outbox.keys.sorted().filter { $0 > since }.map { number -> [String: Any] in
                let json = String(data: (try? JSONEncoder().encode(outbox[number])) ?? Data(), encoding: .utf8) ?? "{}"
                return ["es": number, "json": json, "detectedAt": 0]
            }
            let reply: [String: Any] = ["session": session, "lastEs": outbox.keys.max() ?? 0, "entries": entries]
            return String(data: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), encoding: .utf8)
        }
        if script.contains("ackReports") {
            if let range = script.range(of: "ackReports("),
               let data = script[range.upperBound...].split(separator: ")").first.map({ Data($0.utf8) }),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                acks.append(((obj["through"] as? Int) ?? 0, (obj["idMapping"] as? [String: String])?.count ?? 0))
            }
            return "1"
        }
        if script.contains("flushReports") {
            onFlush?()
            return "{\"session\":\"\(session)\",\"through\":\(flushThrough),\"held\":false,\"enabled\":true}"
        }
        return nil
    }

    private static func lastInt(in script: String, after marker: String) -> Int? {
        guard let range = script.range(of: marker) else { return nil }
        let tail = script[range.upperBound...].prefix { $0 != ")" }
        return tail.split(separator: ",").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Reports

    func update(_ id: String, _ text: String) -> BlockChanges {
        BlockChanges(updates: [BlockUpdate(id: id, textContent: text, markdownFragment: text, headingLevel: nil, blockType: "paragraph")])
    }

    /// The page posts report `es` (kept in its outbox) and, unless `lost`, Swift's handler takes it in.
    func post(_ number: Int, _ changes: BlockChanges, lost: Bool = false, session: String? = nil) {
        outbox[number] = changes
        guard !lost else { return }
        sync.reportApplier.receive(IncomingReport(number: number, session: session ?? self.session, changes: changes, detectedAt: 0), via: .message)
    }

    /// The `blockReport` message body the page sends for outbox entry `es` (`repost`: a re-send of an unacknowledged report).
    func messageBody(_ number: Int, repost: Bool) -> [String: Any] {
        let json = String(data: (try? JSONEncoder().encode(outbox[number] ?? BlockChanges())) ?? Data(), encoding: .utf8) ?? "{}"
        return ["es": NSNumber(value: number), "session": session, "kind": "changes", "json": json, "detectedAt": NSNumber(value: 0),
                "repost": NSNumber(value: repost)]
    }

    // MARK: Reading

    func paragraphs() throws -> [Block] {
        try db.fetchBlocks(projectId: pid).filter { $0.blockType == .paragraph }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func ids() throws -> [String] { try paragraphs().map(\.id) }

    func text(_ id: String) throws -> String? { try paragraphs().first { $0.id == id }?.markdownFragment }

    /// Holds the writer: a turn reserved ahead of everything the test does next, open until `release`.
    func holdWriter() throws -> WriterTicket {
        try #require(sync.writer).reserve()
    }

    func release(_ ticket: WriterTicket) { ticket.settleIfOpen(.empty) }

    func decided() -> Int { sync.reportApplier.decidedThrough(session: session) }

    func waitUntil(_ seconds: Double = 5, _ condition: () throws -> Bool) async rethrows -> Bool {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < end {
            if try condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }
}

@Suite("ReportApplier: the editor's reports as the writer's input (Phase 5 B3)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReportApplierTests {

    @Test("reports are applied in editor-number order; the newest text is what stays")
    func inOrderApply() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        rig.post(2, rig.update(a, "A12."))
        rig.post(3, rig.update(a, "A123."))
        #expect(try await rig.waitUntil { rig.decided() == 3 })
        #expect(try rig.text(a) == "A123.")
        #expect(rig.sync.reportApplier.testAdmitted == ["s1:1", "s1:2", "s1:3"])
    }

    @Test("a report after a gap is held (no turn) until the gap is fetched from the outbox; then all apply in order")
    func gapHoldsAndFetches() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writerHold = try rig.holdWriter()
        rig.post(1, rig.update(a, "A1."))
        rig.post(2, rig.update(a, "A12."), lost: true)
        rig.post(3, rig.update(a, "A123."))
        #expect(rig.sync.reportApplier.testLedger("s1").parked == [3] || rig.sync.reportApplier.testAdmitted.count == 3)
        rig.release(writerHold)
        #expect(try await rig.waitUntil { rig.decided() == 3 })
        #expect(rig.outboxFetches >= 1)
        #expect(rig.sync.reportApplier.testAdmitted == ["s1:1", "s1:2", "s1:3"])
        #expect(try rig.text(a) == "A123.")
        #expect(rig.sync.reportApplier.recoveredCount == 1)
    }

    @Test("a duplicate (already admitted, or already decided) is dropped at receipt")
    func duplicateDropped() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        rig.post(1, rig.update(a, "A1."))
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        rig.post(2, rig.update(a, "A12."))
        rig.post(1, rig.update(a, "OLD."))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        #expect(rig.sync.reportApplier.admittedCount == 2)
        #expect(try rig.text(a) == "A12.")
    }

    @Test("a report of a revoked page session is dropped at receipt")
    func staleSessionAtReceipt() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        rig.sync.reportApplier.revokeKnownSessions(reason: "test")
        rig.post(2, rig.update(a, "STALE."))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try rig.text(a) == "A1.")
        #expect(rig.sync.reportApplier.staleSessionCount == 1)
    }

    @Test("a report admitted before its session is revoked writes nothing at its turn (the check is made again there)")
    func staleSessionAtTurn() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writerHold = try rig.holdWriter()
        rig.post(1, rig.update(a, "STALE."))
        #expect(rig.sync.reportApplier.testLedger("s1").waiting == [1])
        rig.sync.reportApplier.revokeKnownSessions(reason: "test")
        rig.release(writerHold)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try rig.text(a) == "Alpha.")
    }

    @Test("a report the writer gave up on counts as decided: its re-post cannot write it later (P5B_Net_Close)")
    func givenUpCountsDecided() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writerHold = try rig.holdWriter()
        rig.post(1, rig.update(a, "OLD."))
        try #require(rig.sync.writer).skipAllReserved(reason: .lifecycleDrain)
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        _ = writerHold
        // Newer text reaches the rows another way (FB), then the page re-posts report 1: it is decided, never applied over it.
        rig.post(2, rig.update(a, "NEW."))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        rig.sync.reportApplier.receive(body: rig.messageBody(1, repost: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try rig.text(a) == "NEW.")
        #expect(rig.sync.reportApplier.admittedCount == 2)
    }

    @Test("the decided mark never moves past a report still waiting for its turn")
    func decidedMarkWaitsForWaitingReport() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writerHold = try rig.holdWriter()
        rig.post(1, rig.update(a, "A1."))
        rig.sync.reportApplier.registerCover(session: "s1", since: 1, through: 3)
        #expect(rig.decided() == 0)
        rig.release(writerHold)
        #expect(try await rig.waitUntil { rig.decided() == 3 })
        #expect(try rig.text(a) == "A1.")
    }

    @Test("the gap fetch takes the whole outbox and deduplicates: a re-sent report never writes old text over new")
    func outboxFetchDedups() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        rig.post(2, rig.update(a, "A12."))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        // The page has not pruned (no ack applied in the scripted page): a fetch of the whole outbox sees 1 and 2 again, and a
        // later report 3 that was lost.
        rig.post(3, rig.update(a, "A123."), lost: true)
        await rig.sync.reportApplier.fetchOutbox(session: "s1", since: 0, via: .gap)
        #expect(try await rig.waitUntil { rig.decided() == 3 })
        #expect(try rig.text(a) == "A123.")
        #expect(rig.sync.reportApplier.admittedCount == 3)
        #expect(rig.sync.reportApplier.recoveredCount == 1)
    }

    @Test("B4: a lost report is taken in from the page's re-post (gap fetch off); the report parked behind it then applies, in order")
    func repostRecoversALostReport() async throws {
        let rig = try ReportRig()
        rig.sync.reportApplier.gapFetchDisabled = true
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."), lost: true)
        rig.post(2, rig.update(a, "A12."))
        #expect(rig.sync.reportApplier.testLedger("s1").parked == [2])
        #expect(rig.outboxFetches == 0)
        // Two seconds later the page sends report 1 again, unchanged, flagged as a re-post, on the message handler.
        rig.sync.reportApplier.receive(body: rig.messageBody(1, repost: true))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        #expect(rig.sync.reportApplier.testAdmitted == ["s1:1", "s1:2"])
        #expect(try rig.text(a) == "A12.")
        #expect(rig.sync.reportApplier.recoveredCount == 1)
    }

    @Test("B4: a freshly configured service takes in its page's first report, though nothing else has touched its intake yet")
    func configuredServiceRoutesTheFirstReport() async throws {
        // run-1794105228-99842: the intake was created lazily, and only the 2-second poll's first tick created it; with no poll,
        // `ReportApplier.route` found no intake for the page and every report was ignored.
        let db = try TestFixtureFactory.createTemporary(content: "Alpha.\n\nBravo.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let view = WKWebView()
        let sync = BlockSyncService()
        sync.testJSEvaluator = { _ in nil }
        sync.configure(database: db, projectId: pid, webView: view)
        let alpha = try #require(try db.fetchBlocks(projectId: pid).first { $0.markdownFragment == "Alpha." })
        let json = try blockChangesJSON(updates: [
            BlockUpdate(id: alpha.id, textContent: "Routed.", markdownFragment: "Routed.", headingLevel: nil, blockType: "paragraph")
        ])
        ReportApplier.route(body: ["es": NSNumber(value: 1), "session": "s1", "kind": "changes", "json": json,
                                   "detectedAt": NSNumber(value: 0)], from: view)
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while try db.fetchBlocks(projectId: pid).first(where: { $0.id == alpha.id })?.markdownFragment != "Routed.", clock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try db.fetchBlocks(projectId: pid).first { $0.id == alpha.id }?.markdownFragment == "Routed.")
        _ = view
    }

    @Test("B4: a re-post of a number already decided writes nothing and is acknowledged again (its acknowledgement may have been lost)")
    func repostOfADecidedReportIsAcknowledgedAgain() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        rig.post(2, rig.update(a, "A12."))
        #expect(try await rig.waitUntil { rig.decided() == 2 && rig.acks.contains { $0.through == 2 } })
        let acksBefore = rig.acks.count
        rig.outbox[1] = rig.update(a, "OLD.")
        rig.sync.reportApplier.receive(body: rig.messageBody(1, repost: true))
        #expect(try await rig.waitUntil { rig.acks.count > acksBefore })
        #expect(rig.acks.last?.through == 2)
        #expect(try rig.text(a) == "A12.")
        #expect(rig.sync.reportApplier.admittedCount == 2)
    }

    @Test("B4: the test drop switch counts first posts only: a re-post is never dropped")
    func dropSwitchNeverDropsARepost() async throws {
        let rig = try ReportRig()
        rig.sync.reportApplier.gapFetchDisabled = true
        rig.sync.reportApplier.dropEvery = 1   // every first post is lost
        let a = try #require(try rig.ids().first)
        rig.outbox[1] = rig.update(a, "A1.")
        rig.sync.reportApplier.receive(body: rig.messageBody(1, repost: false))
        #expect(rig.sync.reportApplier.droppedForTestCount == 1)
        rig.sync.reportApplier.receive(body: rig.messageBody(1, repost: true))
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        #expect(try rig.text(a) == "A1.")
    }

    @Test("a second report naming a temp id minted by the first resolves through the writer's map (GuardLateTemp)")
    func tempIdAcrossReports() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let insert = BlockInsert(tempId: "temp-x1", blockType: "paragraph", textContent: "", markdownFragment: "", headingLevel: nil,
                                 afterBlockId: a)
        rig.post(1, BlockChanges(inserts: [insert]))
        rig.post(2, rig.update("temp-x1", "Typed in the new paragraph."))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        let texts = try rig.paragraphs().map(\.markdownFragment)
        #expect(texts.contains("Typed in the new paragraph."))
        #expect(rig.acks.contains { $0.ids == 1 })
    }

    @Test("the covering reply: a report in flight at an editor-first click is in N's batch and is dropped at its later turn")
    func coveringReplyDropsCoveredNumbers() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.post(1, rig.update(a, "A1."))
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        // The click: ticket N reserved, then the page call. Report 2 (older text) was posted just before the click's script ran; it
        // reaches Swift while the call is in flight. The page's reply folds 2 with its own drain (3, newer text) and covers 1...3.
        rig.onCoveredCall = { [weak rig] script in
            guard let rig else { return nil }
            #expect(script.contains("beginReportCover(\"s1\", 1)"))
            rig.post(2, rig.update(a, "A12-old."))
            rig.outbox[3] = rig.update(a, "A123-click.")
            guard let batchData = try? JSONEncoder().encode(rig.update(a, "A123-click.")),
                  let batch = String(data: batchData, encoding: .utf8),
                  let innerData = try? JSONSerialization.data(withJSONObject: ["batch": batch]),
                  let inner = String(data: innerData, encoding: .utf8) else { return nil }
            let outer: [String: Any] = ["v": inner, "cover": ["session": "s1", "since": 1, "through": 3, "drained": true]]
            return (try? JSONSerialization.data(withJSONObject: outer)).flatMap { String(data: $0, encoding: .utf8) }
        }
        let submission = try #require(await rig.sync.submitEditorFirstCall(database: rig.db, projectId: rig.pid, script: "JSON.stringify(1)"))
        guard case .success(let value) = submission.result, let value, let data = value.data(using: .utf8),
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let batchData = reply["batch"]?.data(using: .utf8) else {
            Issue.record("the route's own reply did not come back unwrapped")
            return
        }
        let batch = try JSONDecoder().decode(BlockChanges.self, from: batchData)
        submission.ticket.noteFetched()
        await rig.sync.applyFetchedBatch(ticket: submission.ticket, changes: batch, stamp: submission.stamp, webView: rig.view,
                                         database: rig.db, projectId: rig.pid, force: false)
        #expect(try await rig.waitUntil { rig.sync.reportApplier.testLedger("s1").waiting.isEmpty })
        // Report 2 had its own turn after N: with the cover it wrote nothing, so N's text stands.
        #expect(try rig.text(a) == "A123-click.")
        #expect(rig.decided() >= 3)
        // The late report 3 shows up too (its re-post): dropped.
        rig.post(3, rig.update(a, "A123-click."))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try rig.text(a) == "A123-click.")
    }

    @Test("a report arriving during an editor-first click is admitted only once the click's job holds its place (plan D1.5)")
    func reportDuringClickWaitsForTheJob() async throws {
        // The regression of 2026-11-07 (b3-notes.md): a report reserved its turn between a Delete Section click's ticket N and the
        // delete job's place, so its deletes of the section's rows ran first and the job failed (`rootNotDeletable`).
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writer = try #require(rig.sync.writer)
        rig.sync.structuralClickPending = true   // the click: routine input steps aside
        let clickTicket = writer.reserve()       // ticket N, the route's page call
        rig.post(1, rig.update(a, "From the report."))
        #expect(rig.sync.reportApplier.testLedger("s1").parked == [1])
        clickTicket.settleIfOpen(.empty)
        let job = writer.reserve()               // the job takes its place
        rig.sync.structuralClickPending = false  // ... and the pause ends
        #expect(await job.waitForTurn() == .go)
        let seenByTheJob = try rig.text(a)
        job.settleIfOpen(.empty)
        #expect(seenByTheJob == "Alpha.")
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        #expect(try rig.text(a) == "From the report.")
    }

    @Test("flushAndAck returns only after the writer has decided every report up to the page's answer")
    func flushAndAckWaitsForTheWriter() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        let writerHold = try rig.holdWriter()   // a queued system write, say the bibliography's
        rig.flushThrough = 1
        rig.onFlush = { [weak rig] in rig?.post(1, rig?.update(a, "Flushed.") ?? BlockChanges()) }
        var outcome: FlushAndAckOutcome?
        let task = Task { @MainActor in outcome = await rig.sync.flushAndAck(bound: 5) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(outcome == nil)
        #expect(try rig.text(a) == "Alpha.")
        rig.release(writerHold)
        await task.value
        #expect(outcome == .settled)
        #expect(try rig.text(a) == "Flushed.")
    }

    @Test("flushAndAck fetches the outbox when the page's report never arrived, and still settles")
    func flushAndAckFetchesALostReport() async throws {
        let rig = try ReportRig()
        let a = try #require(try rig.ids().first)
        rig.flushThrough = 1
        rig.onFlush = { [weak rig] in rig?.post(1, rig?.update(a, "Lost then fetched.") ?? BlockChanges(), lost: true) }
        let outcome = await rig.sync.flushAndAck(bound: 4)
        #expect(outcome == .settled)
        #expect(try rig.text(a) == "Lost then fetched.")
    }

    @Test("lifecycle step F is flushAndAck, the save's read holds and covers: a report posted before the read but arriving after FB is dropped")
    func lifecycleFlushAndSaveCover() async throws {
        let rig = try LifecycleFlushHarness()
        let para = try #require(try rig.blocks().first { $0.blockType == .paragraph }).id
        func update(_ text: String) -> BlockChanges {
            BlockChanges(updates: [BlockUpdate(id: para, textContent: text, markdownFragment: text, headingLevel: nil, blockType: "paragraph")])
        }
        var scripts: [String] = []
        let base = rig.sync.testJSEvaluator
        let sync = rig.sync
        let fbText = "# Alpha\n\none two three four five.\n\n# Beta\n\nfour five six.\n"
        rig.sync.testJSEvaluator = { script in
            scripts.append(script)
            if script.contains("flushReports") {
                let report = IncomingReport(number: 1, session: "s1", changes: update("one two three four."), detectedAt: 0)
                sync.reportApplier.receive(report, via: .message)
                return "{\"session\":\"s1\",\"through\":1,\"enabled\":true}"
            }
            if script.contains("holdReportsForSave") {
                let reply: [String: Any] = ["content": fbText, "hold": ["session": "s1", "through": 2]]
                return String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8)
            }
            if script.contains("ackReports") { return "1" }
            return try await base?(script)
        }
        _ = await rig.run(.close)
        // Report 2 (posted before the read, so its text is in FB) reaches Swift only now.
        rig.sync.reportApplier.receive(IncomingReport(number: 2, session: "s1", changes: update("one two three four"), detectedAt: 0), via: .message)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!scripts.contains { $0.contains("getBlockChanges") })
        let flushAt = try #require(scripts.firstIndex { $0.contains("flushReports") })
        let readAt = try #require(scripts.firstIndex { $0.contains("holdReportsForSave") })
        #expect(flushAt < readAt)
        #expect(try rig.paragraphTexts().contains("one two three four five."))
        #expect(rig.sync.reportApplier.admittedCount == 1)
    }

    @Test("the rebuild flush and the resetting-content recovery are flushAndAck: no pull (no getBlockChanges) is ever made")
    func rebuildFlushMakesNoPull() async throws {
        let rig = try ReportRig()
        var scripts: [String] = []
        let base = rig.sync.testJSEvaluator
        rig.sync.testJSEvaluator = { script in
            scripts.append(script)
            return try await base?(script)
        }
        #expect(await rig.sync.flushForDatabaseRebuild())
        await rig.sync.forceSendForResettingContentRecovery()
        #expect(scripts.filter { $0.contains("flushReports") }.count == 2)
        #expect(!scripts.contains { $0.contains("getBlockChanges") || $0.contains("hasBlockChanges") })
    }
}
