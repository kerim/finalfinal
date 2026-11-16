//
//  ReportApplier.swift
//  final final
//
//  Phase 5 job B3 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, sections 3.2 to 3.6; notes in b3-notes.md): the Rich Text
//  editor's numbered block reports (web/milkdown/src/report-outbox.ts) are the writer's input. This is the intake. The sync model's
//  rules (docs/architecture/tla/README.md, "Phase 5 step T2" and "T2b"), each a line of code below:
//
//  (a) In order. A report is admitted only when its number is the next one expected for its page session: its writer turn is reserved
//      at once, synchronously, in the script-message delegate callback (no Task hop), so turns are in editor-number order. A report that
//      arrives after a gap is PARKED (no turn) and the gap is fetched from the page's outbox (`outboxSince`). A number already decided,
//      waiting for its turn, covered or below the next expected is a duplicate and is dropped (at receipt, and again at its turn).
//      A report whose turn the writer gave up on (skipped, refused, discarded) counts as DECIDED.
//  (b) Sessions. Every report carries its page session. A project switch revokes the sessions the page had (`pageWillReset...`, called
//      just before the page is reset); a report of a revoked session is dropped at receipt AND at its writer turn. The "decided" mark
//      (`decidedThrough`, the highest number below which everything is decided) never moves past a report still waiting for its turn:
//      it is contiguous, and a waiting report is not decided until its turn has settled.
//  (c) Nothing forces a poll any more: `flushAndAck` (BlockSyncService+Reports.swift) asks the page to post what it has and to answer
//      its highest number, and waits until that number is decided here; nothing is reserved before the reply.
//  (d) The covering reply: a route's page call (a section command, the zoom / switch begin) reserves ticket N and notes, in the same
//      synchronous stretch, the highest number admitted (`coverMark`); the page's reply covers every report after that number plus
//      its own drain (`registerCover`), and a covered number is dropped wherever it shows up later. The lifecycle save's live read
//      covers in the same way (`registerSaveCover`).
//  (e) Recovery (Phase 5 job B4: the 2-second poll and its net are gone). The page sends every report again, unchanged, while it is
//      not acknowledged 2 s after it was last sent (report-outbox.ts, the re-post); the gap fetch takes a missing number from the
//      outbox as soon as a later one shows the gap. Either way the report comes through `receive`, so a duplicate is dropped and old
//      text is never written after new. Anything actually brought in this way is logged `[PUSH-NET] recovered es=.. via=..`.
//  (g) One call acknowledges the reports and confirms the ids their inserts were given (`ackReports`); the page then drops them.
//
//  Persisted log lines carry numbers, ids' counts and lengths only, never document or page-reply text.
//

import Foundation
import WebKit

/// One report as the page posted it (or as its outbox hands it back).
struct IncomingReport: Sendable {
    let number: Int
    let session: String
    let changes: BlockChanges
    /// When the oldest change it carries was detected, in ms since the epoch (the page's clock).
    let detectedAt: Double
}

/// What applies a report and talks to its page. `BlockSyncService` in the app; a fake in the unit tests.
@MainActor
protocol ReportApplierSink: AnyObject {
    /// The page whose reports this intake takes (the configured Rich Text web view).
    var reportPage: WKWebView? { get }
    /// True while an editor-first section command is between its page call's ticket N and the moment its job holds its place in the
    /// queue (`BlockSyncService.structuralClickPending`, plan D1.5). A report arriving then is held, unadmitted, until it ends.
    var reportAdmissionHeld: Bool { get }
    /// Reserves a writer turn synchronously (`reserveWriterTurn`). Nil: no writer (nothing is admitted; the page re-posts it later).
    func reserveReportTurn() -> (WriterTicket, BlockWriteStamp)?
    /// Applies `changes` as `ticket` (`applyFetchedBatch`). `abandonAfterTurn` is asked once the turn comes; `onApplied` replaces
    /// the separate id confirmation with the report's acknowledgement. Returns when the ticket has settled or was skipped.
    func applyReportBatch(
        ticket: WriterTicket, stamp: BlockWriteStamp, changes: BlockChanges,
        abandonAfterTurn: @escaping @MainActor () -> Bool,
        onApplied: @escaping @MainActor ([String: String]) async -> Void
    ) async
    /// Evaluates a script on `reportPage` and returns its string answer (nil: no page, or it failed).
    func evaluateReportScript(_ script: String) async -> String?
}

@MainActor
final class ReportApplier {
    enum Via: String { case message, repost, gap }

    // MARK: Routing (the delegate callback finds the intake of the page that posted)

    private static let registry = NSHashTable<ReportApplier>.weakObjects()

    /// The `blockReport` message handler's body, from `page`. Synchronous (design correction 5). A page no intake owns is ignored: its
    /// reports stay in its outbox and come in once the page is configured (the page's re-post, or the next report's gap).
    static func route(body: Any, from page: WKWebView?) {
        guard let page, let applier = registry.allObjects.first(where: { $0.sink?.reportPage === page }) else { return }
        applier.receive(body: body)
    }

    /// A project switch is about to reset `page`: every session it has had is revoked now, before the reset reaches it, so a report of
    /// the old project still on its way is refused at receipt and at its turn, and the new session (made by the reset) is never revoked.
    static func pageWillResetForProjectSwitch(_ page: WKWebView?) {
        guard let page else { return }
        for applier in registry.allObjects where applier.sink?.reportPage === page {
            applier.revokeKnownSessions(reason: "project switch")
        }
    }

    // MARK: State

    weak var sink: ReportApplierSink?
    /// `FF_UI_TESTING_PUSH_DROP=<n>`: every n-th report arriving on the message handler for the first time is discarded as if lost
    /// (its re-posts are not counted and never dropped).
    var dropEvery: Int? = TestMode.uiTestingPushDrop
    /// `FF_UI_TESTING_PUSH_GAP_FETCH_OFF=1`: no gap fetch (the page's re-post is then the only recovery).
    var gapFetchDisabled = TestMode.isUITestingPushGapFetchOff

    private struct Ledger {
        var nextExpected = 1
        var parked: [Int: IncomingReport] = [:]
        var waiting: Set<Int> = []
        var decided: Set<Int> = []
        var decidedThrough = 0
        /// The numbers a route's reply (or the save's read) covered: `since+1 ... through` of each cover.
        var covers: [ClosedRange<Int>] = []
        var covered: Int { covers.map(\.upperBound).max() ?? 0 }
        func isCovered(_ number: Int) -> Bool { covers.contains { $0.contains(number) } }
    }

    private var ledgers: [String: Ledger] = [:]
    private var revoked: Set<String> = []
    /// The session the last admitted (or covered) report belonged to: the page's current one, as far as Swift knows.
    private(set) var activeSession: String?
    private var gapFetchInFlight = false
    private var messagesSeen = 0

    private var ackInFlight = false
    private var pendingAck: (session: String, mapping: [String: String])?
    private var lastAckedThrough: [String: Int] = [:]

    // Counters (tests, and the `[PUSH] stats` line).
    private(set) var admittedCount = 0
    private(set) var appliedCount = 0
    private(set) var duplicateCount = 0
    private(set) var staleSessionCount = 0
    private(set) var recoveredCount = 0
    private(set) var droppedForTestCount = 0
    /// Typing-to-database delays (ms) of the reports applied, newest last, at most 4,000.
    private(set) var applyDelaysMs: [Double] = []
    #if DEBUG
    /// Test-only: the order in which numbers were admitted (`session:es`).
    private(set) var testAdmitted: [String] = []
    #endif

    init(sink: ReportApplierSink?) {
        self.sink = sink
        Self.registry.add(self)
    }

    // MARK: Receipt

    /// One `blockReport` message body. Synchronous.
    func receive(body: Any) {
        guard let dict = body as? [String: Any],
              let number = (dict["es"] as? NSNumber)?.intValue, let session = dict["session"] as? String,
              let json = dict["json"] as? String, let data = json.data(using: .utf8),
              let changes = try? JSONDecoder().decode(BlockChanges.self, from: data) else {
            DebugLog.alwaysPersisted("[PUSH] unreadable report dropped")
            return
        }
        // Phase 5 job B4: the page sends a report again, unchanged, while it is not acknowledged 2 s after it was last sent.
        let isRepost = (dict["repost"] as? NSNumber)?.boolValue ?? false
        if !isRepost {
            messagesSeen += 1
            if let every = dropEvery, messagesSeen % every == 0 {
                droppedForTestCount += 1
                DebugLog.alwaysPersisted("[PUSH-DROP] dropped es=\(number) (test switch, every \(every))")
                return
            }
        }
        let detectedAt = (dict["detectedAt"] as? NSNumber)?.doubleValue ?? 0
        receive(IncomingReport(number: number, session: session, changes: changes, detectedAt: detectedAt), via: isRepost ? .repost : .message)
    }

    /// The intake proper (rule a). Synchronous: an admitted report holds its writer turn when this returns.
    func receive(_ report: IncomingReport, via: Via) {
        let session = report.session
        if revoked.contains(session) {
            staleSessionCount += 1
            DebugLog.alwaysPersisted("[PUSH] dropped stale session es=\(report.number) via=\(via.rawValue)")
            return
        }
        var ledger = ledgers[session] ?? Ledger()
        if isSettledOrTaken(ledger, report.number) {
            duplicateCount += 1
            ledgers[session] = ledger
            // A re-post of a number already decided: its acknowledgement may be what was lost. Acknowledge again.
            if via == .repost, report.number <= ledger.decidedThrough { reacknowledge(session: session) }
            return
        }
        if via != .message {
            recoveredCount += 1
            DebugLog.alwaysPersisted("[PUSH-NET] recovered es=\(report.number) via=\(via.rawValue)")
        }
        if report.number > ledger.nextExpected {
            ledger.parked[report.number] = report
            ledgers[session] = ledger
            requestGapFetch(session: session, after: ledger.nextExpected - 1)
            return
        }
        if admissionHeld {
            // An editor-first click is between its ticket N and its job's place (plan D1.5): a turn reserved now would land between
            // the two, ahead of the job (a section's rows deleted before its delete job runs, typing into a section before its
            // reinsert). Held, in order, until the job holds its place (`admissionResumed`).
            ledger.parked[report.number] = report
            ledgers[session] = ledger
            DebugLog.alwaysPersisted("[PUSH] es=\(report.number) held: a section command's job is not in the queue yet")
            return
        }
        ledgers[session] = ledger
        admit(report)
        admitParked(session: session)
    }

    private func isSettledOrTaken(_ ledger: Ledger, _ number: Int) -> Bool {
        number < ledger.nextExpected || number <= ledger.decidedThrough || ledger.isCovered(number)
            || ledger.decided.contains(number) || ledger.waiting.contains(number) || ledger.parked[number] != nil
    }

    /// `reportAdmissionHeld`, read from the sink (false without one).
    private var admissionHeld: Bool { sink?.reportAdmissionHeld ?? false }

    /// The click's job holds its place in the queue: the reports held meanwhile are admitted now, in order, behind it.
    func admissionResumed() {
        for session in ledgers.keys where !revoked.contains(session) {
            admitParked(session: session)
        }
    }

    private func admitParked(session: String) {
        while !admissionHeld, var ledger = ledgers[session], let next = ledger.parked.removeValue(forKey: ledger.nextExpected) {
            ledgers[session] = ledger
            admit(next)
        }
        // Parked numbers a cover made obsolete.
        if var ledger = ledgers[session] {
            ledger.parked = ledger.parked.filter { $0.key >= ledger.nextExpected }
            ledgers[session] = ledger
        }
    }

    private func admit(_ report: IncomingReport) {
        let session = report.session
        guard var ledger = ledgers[session], report.number == ledger.nextExpected else { return }
        guard let sink, let (ticket, stamp) = sink.reserveReportTurn() else {
            // No writer (or the epoch could not be read): nothing is admitted; the report stays in the page's outbox and comes in
            // again with its re-post.
            DebugLog.alwaysPersisted("[PUSH] es=\(report.number) not admitted: no writer turn")
            return
        }
        ledger.nextExpected = report.number + 1
        ledger.waiting.insert(report.number)
        ledgers[session] = ledger
        activeSession = session
        admittedCount += 1
        #if DEBUG
        testAdmitted.append("\(session):\(report.number)")
        #endif
        let number = report.number
        let detectedAt = report.detectedAt
        let changes = report.changes
        if !changes.isEmpty { ticket.noteFetched() }
        Task { @MainActor [weak self] in
            await sink.applyReportBatch(
                ticket: ticket, stamp: stamp, changes: changes,
                abandonAfterTurn: { [weak self] in self?.shouldDropAtTurn(session: session, number: number) ?? true },
                onApplied: { [weak self] mapping in await self?.reportApplied(session: session, number: number, detectedAt: detectedAt, mapping) })
            ticket.settleIfOpen(.noBatch)
            self?.turnSettled(session: session, number: number)
        }
    }

    /// Rule (a) and (b) at the writer's turn: a revoked session's report, or one a route's reply covered, writes nothing.
    private func shouldDropAtTurn(session: String, number: Int) -> Bool {
        if revoked.contains(session) {
            staleSessionCount += 1
            DebugLog.alwaysPersisted("[PUSH] es=\(number) dropped at its turn: stale session")
            return true
        }
        if let ledger = ledgers[session], ledger.isCovered(number) {
            duplicateCount += 1
            return true
        }
        return false
    }

    private func reportApplied(session: String, number: Int, detectedAt: Double, _ mapping: [String: String]) async {
        appliedCount += 1
        if detectedAt > 0 {
            let delay = Date().timeIntervalSince1970 * 1000 - detectedAt
            applyDelaysMs.append(delay)
            if applyDelaysMs.count > 4_000 { applyDelaysMs.removeFirst(applyDelaysMs.count - 4_000) }
            DebugLog.alwaysPersisted("[PUSH] es=\(number) applied after \(Int(delay.rounded())) ms ids=\(mapping.count)")
        }
        markDecided(session: session, number: number)
        await acknowledge(session: session, mapping: mapping)
    }

    private func turnSettled(session: String, number: Int) {
        if var ledger = ledgers[session] {
            ledger.waiting.remove(number)
            ledgers[session] = ledger
        }
        markDecided(session: session, number: number)
        Task { @MainActor [weak self] in await self?.acknowledge(session: session, mapping: [:]) }
    }

    private func markDecided(session: String, number: Int) {
        guard var ledger = ledgers[session] else { return }
        if number > ledger.decidedThrough { ledger.decided.insert(number) }
        advance(&ledger)
        ledgers[session] = ledger
    }

    /// `decidedThrough` moves over contiguous decided numbers only, never past one still waiting for its turn (rule b).
    private func advance(_ ledger: inout Ledger) {
        while ledger.decided.contains(ledger.decidedThrough + 1), !ledger.waiting.contains(ledger.decidedThrough + 1) {
            ledger.decided.remove(ledger.decidedThrough + 1)
            ledger.decidedThrough += 1
        }
    }

    // MARK: Sessions (rule b)

    func revokeKnownSessions(reason: String) {
        let sessions = Set(ledgers.keys).union(activeSession.map { [$0] } ?? [])
        guard !sessions.isEmpty else { return }
        revoked.formUnion(sessions)
        for session in sessions { ledgers.removeValue(forKey: session) }
        activeSession = nil
        DebugLog.alwaysPersisted("[PUSH] revoked \(sessions.count) page session(s): \(reason)")
    }

    func isRevoked(_ session: String) -> Bool { revoked.contains(session) }

    // MARK: The covering reply (rule d)

    /// Taken in the same synchronous stretch as a route's reservation of N: the session last admitted and the highest number admitted
    /// in it (everything after it is still on its way, or parked, and the reply covers it).
    func coverMark() -> (session: String?, since: Int) {
        guard let session = activeSession, let ledger = ledgers[session] else { return (activeSession, 0) }
        return (session, ledger.nextExpected - 1)
    }

    /// The route's reply: every report of `session` in `since+1 ... through` is in N's batch. Those not yet admitted are decided now
    /// (they are dropped wherever they show up); those already admitted after N are dropped at their turn.
    func registerCover(session: String, since: Int, through: Int) {
        guard !revoked.contains(session), through > since else { return }
        var ledger = ledgers[session] ?? Ledger()
        ledger.covers.append((since + 1)...through)
        ledger.covers.removeAll { $0.upperBound <= ledger.decidedThrough && !$0.contains { ledger.waiting.contains($0) } }
        if since + 1 <= through {
            for number in (since + 1)...through where !ledger.waiting.contains(number) && number > ledger.decidedThrough {
                ledger.decided.insert(number)
            }
        }
        ledger.nextExpected = max(ledger.nextExpected, through + 1)
        ledger.parked = ledger.parked.filter { $0.key > through }
        advance(&ledger)
        ledgers[session] = ledger
        activeSession = session
        admitParked(session: session)
        Task { @MainActor [weak self] in await self?.acknowledge(session: session, mapping: [:]) }
    }

    /// The lifecycle save's live read (design 3.6 and the model's FB cover): the whole document it read holds every report of
    /// `session` up to `through`. Those not yet admitted are covered (they would get turns after FB); those already admitted keep
    /// their earlier turns (they land before FB, which then writes the same text again).
    func registerSaveCover(session: String, through: Int) {
        guard !revoked.contains(session) else { return }
        let since = (ledgers[session]?.nextExpected ?? 1) - 1
        registerCover(session: session, since: since, through: through)
    }

    // MARK: Waiting (flushAndAck's step 2 and 3)

    /// The highest number of `session` below which everything is decided (0 for a session never seen).
    func decidedThrough(session: String) -> Int { ledgers[session]?.decidedThrough ?? 0 }

    /// True once every report of `session` up to `through` is decided (applied, dropped or given up), or the session was revoked.
    /// After `fetchAfter` seconds with numbers not yet received, the outbox is fetched once (a report lost on the way).
    func waitDecided(session: String, through: Int, timeout: TimeInterval, fetchAfter: TimeInterval = 1.0) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        var fetched = false
        while true {
            if revoked.contains(session) || decidedThrough(session: session) >= through { return true }
            let elapsed = clock.now - start
            if elapsed >= .seconds(timeout) { return false }
            if !fetched, elapsed >= .seconds(fetchAfter), (ledgers[session]?.nextExpected ?? 1) <= through {
                fetched = true
                DebugLog.alwaysPersisted("[PUSH] flush fetched outbox (through=\(through))")
                requestGapFetch(session: session, after: (ledgers[session]?.nextExpected ?? 1) - 1)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

}

extension ReportApplier {
    // MARK: Gap fetch (rule e)

    func requestGapFetch(session: String, after: Int) {
        guard !gapFetchDisabled, !gapFetchInFlight else { return }
        gapFetchInFlight = true
        Task { @MainActor [weak self] in
            await self?.fetchOutbox(session: session, since: after, via: .gap)
            self?.gapFetchInFlight = false
        }
    }

    func fetchOutbox(session: String?, since: Int, via: Via) async {
        guard let sink else { return }
        let sessionLiteral = session.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "null"
        let script = "JSON.stringify(window.FinalFinal.reportOutboxSince ? window.FinalFinal.reportOutboxSince("
            + "\(sessionLiteral), \(since)) : null)"
        guard let json = await sink.evaluateReportScript(script), let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(OutboxReply.self, from: data) else { return }
        for entry in reply.entries {
            guard let entryData = entry.json.data(using: .utf8),
                  let changes = try? JSONDecoder().decode(BlockChanges.self, from: entryData) else { continue }
            receive(IncomingReport(number: entry.number, session: reply.session, changes: changes, detectedAt: entry.detectedAt ?? 0), via: via)
        }
    }

    // MARK: Acknowledgement (rule g)

    /// Tells the page every report of `session` up to the decided mark is done, confirming `mapping` in the same call. At most one in
    /// flight; a later one carries the newest mark and every id waiting. One with ids is awaited (as the old `confirmBlockIds` was).
    func acknowledge(session: String, mapping: [String: String]) async {
        if ackInFlight {
            let merged = (pendingAck?.session == session ? pendingAck?.mapping ?? [:] : [:]).merging(mapping) { $1 }
            pendingAck = (session, merged)
            return
        }
        ackInFlight = true
        var next: (session: String, mapping: [String: String])? = (session, mapping)
        while let current = next {
            let through = decidedThrough(session: current.session)
            if through > (lastAckedThrough[current.session] ?? 0) || !current.mapping.isEmpty {
                lastAckedThrough[current.session] = through
                await sendAck(session: current.session, through: through, mapping: current.mapping)
            }
            next = pendingAck
            pendingAck = nil
        }
        ackInFlight = false
    }

    /// Sends the acknowledgement of `session` again even though its mark has not moved (a re-post showed the page still holds it).
    private func reacknowledge(session: String) {
        lastAckedThrough[session] = 0
        Task { @MainActor [weak self] in await self?.acknowledge(session: session, mapping: [:]) }
    }

    private func sendAck(session: String, through: Int, mapping: [String: String]) async {
        guard let sink, !revoked.contains(session),
              let data = try? JSONEncoder().encode(AckPayload(session: session, through: through, idMapping: mapping)),
              let payload = String(data: data, encoding: .utf8) else { return }
        _ = await sink.evaluateReportScript("JSON.stringify(window.FinalFinal.ackReports ? window.FinalFinal.ackReports(\(payload)) : 0)")
    }

    // MARK: Test support

    #if DEBUG
    func testLedger(_ session: String) -> ReportLedgerView {
        let ledger = ledgers[session] ?? Ledger()
        return ReportLedgerView(
            nextExpected: ledger.nextExpected, decidedThrough: ledger.decidedThrough, waiting: ledger.waiting,
            parked: ledger.parked.keys.sorted(), covered: ledger.covered)
    }
    #endif
}

/// The page's answer to `reportOutboxSince` (report-outbox.ts `outboxSince`).
private struct OutboxReply: Decodable {
    let session: String
    let lastEs: Int?
    let entries: [OutboxEntry]
}

private struct OutboxEntry: Decodable {
    let number: Int
    let json: String
    let detectedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case number = "es"
        case json, detectedAt
    }
}

/// The acknowledgement `ackReports` takes (api-content.ts `ackReportsApi`).
private struct AckPayload: Encodable {
    let session: String
    let through: Int
    let idMapping: [String: String]
}

#if DEBUG
/// Test-only: one page session's ledger as the tests read it.
struct ReportLedgerView {
    let nextExpected: Int
    let decidedThrough: Int
    let waiting: Set<Int>
    let parked: [Int]
    let covered: Int
}
#endif
