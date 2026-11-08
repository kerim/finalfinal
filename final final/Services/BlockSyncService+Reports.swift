//
//  BlockSyncService+Reports.swift
//  final final
//
//  Phase 5 job B3 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, sections 3.3 to 3.6; notes in b3-notes.md): the Swift
//  half of the editor's reports that is not the intake itself (ReportApplier.swift):
//
//    - `BlockSyncService` as the intake's sink: a report's writer turn (`reserveWriterTurn`, synchronous) and its apply
//      (`applyFetchedBatch`, with the duplicate / stale-session check at the turn and the acknowledgement in place of `confirmBlockIds`).
//    - `flushAndAck`: the ONE replacement of every forced poll (rule c). The page posts what it has and answers its highest number in
//      one turn; Swift waits until the intake has decided every report up to it. Nothing is reserved before the reply.
//      `flushForDatabaseRebuild` is its form for the rebuild waits.
//    - The covering wrapper around a route's page call (`coveredScript`, `unwrapCoveredReply`; rule d), used by `submitEditorFirstCall`.
//    - The lifecycle save's live read, which holds the reports and covers them (`fetchContentHoldingReports`; rule e's last part).
//
//  Phase 5 job B4: the 2-second poll is gone. A report lost on the way is taken in from the page's re-post (report-outbox.ts) or by
//  the intake's gap fetch.
//

import Foundation
import WebKit

/// How `flushAndAck` ended.
enum FlushAndAckOutcome: Equatable {
    /// Every report the page had posted when it answered is decided (applied, dropped as a duplicate, or given up by the writer).
    case settled
    /// The page answered, but the writer did not decide everything within the bound (nothing was changed; the reports stay queued).
    case timedOut
    /// No page, or it did not answer within the bound.
    case pageSilent
}

/// The page's answer to a covered route call (`BlockSyncService.coveredScript`): the route's own reply and what it covered.
private struct CoveredRouteReply: Decodable {
    let value: String?
    let cover: ReportCover?

    private enum CodingKeys: String, CodingKey {
        case value = "v"
        case cover
    }
}

private struct ReportCover: Decodable {
    let session: String
    let since: Int
    let through: Int
    let drained: Bool
}

/// The lifecycle save's live read with the reports held (`fetchContentHoldingReports`).
private struct HeldContentReply: Decodable {
    let content: String?
    let hold: ReportHold?
}

private struct ReportHold: Decodable {
    let session: String
    let through: Int
}

extension BlockSyncService: ReportApplierSink {
    // MARK: ReportApplierSink

    var reportPage: WKWebView? { webView }

    var reportAdmissionHeld: Bool { structuralClickPending }

    func reserveReportTurn() -> (WriterTicket, BlockWriteStamp)? {
        guard let database = projectDatabase, let projectId else { return nil }
        return reserveWriterTurn(database: database, projectId: projectId)
    }

    func applyReportBatch(
        ticket: WriterTicket, stamp: BlockWriteStamp, changes: BlockChanges,
        abandonAfterTurn: @escaping @MainActor () -> Bool,
        onApplied: @escaping @MainActor ([String: String]) async -> Void
    ) async {
        guard let database = projectDatabase, let projectId, let webView else {
            ticket.settleIfOpen(.noBatch)
            return
        }
        // The report's editor sequence is open from here until it settles: `SystemWriteScope.heldEditorSeq` names it for that window
        // so a system write started from inside it is refused `.nested` instead of deadlocking behind it (A5). The poll cycle set
        // this around its fetch-to-apply window; Phase 5 B4 moved it here with the poll's removal.
        await SystemWriteScope.$heldEditorSeq.withValue(ticket.seq) {
            await applyFetchedBatch(
                ticket: ticket, changes: changes, stamp: stamp, webView: webView, database: database, projectId: projectId, force: false,
                abandonAfterTurn: abandonAfterTurn, abandonOutcome: .empty, onApplied: onApplied)
        }
    }

    func evaluateReportScript(_ script: String) async -> String? {
        guard let webView else { return nil }
        return (try? await evaluateJS(script, in: webView)) as? String
    }

    // MARK: flushAndAck (design 3.4)

    private struct FlushReply: Decodable {
        let session: String
        let through: Int
        let enabled: Bool?
    }

    /// The page posts what it has and answers its highest report number; returns once the intake has decided every report up to it
    /// (`.settled`), or after `bound` seconds (`.timedOut`, nothing changed), or `.pageSilent` (no page, or no answer in time).
    /// `page` (default: the configured page) is the lifecycle's captured view.
    func flushAndAck(on page: WKWebView? = nil, bound: TimeInterval) async -> FlushAndAckOutcome {
        guard let webView = page ?? self.webView else { return .pageSilent }
        let clock = ContinuousClock()
        let start = clock.now
        let script = "JSON.stringify(window.FinalFinal.flushReports ? window.FinalFinal.flushReports() : null)"
        let outcome = await raceAgainstTimeout(.milliseconds(Int((max(0, bound) * 1000).rounded()))) {
            (try? await self.evaluateJS(script, in: webView)) as? String
        }
        guard case .finished(let answer) = outcome, let json = answer, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(FlushReply.self, from: data) else {
            DebugLog.alwaysPersisted("[PUSH] flushAndAck: the page did not answer")
            return .pageSilent
        }
        guard reply.enabled != false, reply.through > 0 else { return .settled }
        let remaining = max(0, bound - Double((clock.now - start) / .milliseconds(1)) / 1000)
        if await reportApplier.waitDecided(session: reply.session, through: reply.through, timeout: remaining) {
            return .settled
        }
        DebugLog.alwaysPersisted(
            "[PUSH] flushAndAck: not settled within \(bound)s (through=\(reply.through), "
                + "decided=\(reportApplier.decidedThrough(session: reply.session)))")
        return .timedOut
    }

    // MARK: The covering reply (design 3.3)

    /// Wraps a route's page call: `beginReportCover(session, since)` before it, `endReportCover()` after it, in the same page turn.
    /// The reply becomes `{"v": <the route's own answer>, "cover": {...}}`; `unwrapCoveredReply` takes it apart again.
    nonisolated static func coveredScript(_ script: String, session: String?, since: Int) -> String {
        let sessionLiteral = session.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "null"
        return """
            (() => {
                const ff = window.FinalFinal;
                if (typeof ff.beginReportCover === 'function') { ff.beginReportCover(\(sessionLiteral), \(since)); }
                let v;
                try { v = (\(script)); } finally {
                    var c = typeof ff.endReportCover === 'function' ? ff.endReportCover() : null;
                }
                return JSON.stringify({ v: v === undefined ? null : v, cover: c });
            })()
            """
    }

    /// Takes the route's own answer out of the wrapper and registers what it covered with the intake, before the caller sees the
    /// answer (so before ticket N can settle and before any report after it reaches its turn).
    func unwrapCoveredReply(_ value: String?) -> String? {
        // Only the wrapper's own shape (an object with the "v" key) is unwrapped; any other answer is handed back as it came (a
        // route's own JSON reply is an object too, and would otherwise decode as a wrapper with nothing in it).
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.keys.contains("v"),
              let reply = try? JSONDecoder().decode(CoveredRouteReply.self, from: data) else { return value }
        if let cover = reply.cover, cover.drained {
            reportApplier.registerCover(session: cover.session, since: cover.since, through: cover.through)
        }
        return reply.value
    }

    // MARK: The lifecycle save's live read (design 3.6)

    /// FB's read of the Rich Text page with the reports on: in ONE page turn the page stops posting reports and the document is read;
    /// every report up to the number it answers is covered by the whole-document write. Same bound and same answer as
    /// `fetchContentFromWebView` otherwise.
    func fetchContentHoldingReports(timeout: Duration, webView page: WKWebView) async -> String? {
        let script = """
            (() => {
                const ff = window.FinalFinal;
                const hold = typeof ff.holdReportsForSave === 'function' ? ff.holdReportsForSave() : null;
                return JSON.stringify({ content: ff.getContent(), hold: hold });
            })()
            """
        let outcome = await raceAgainstTimeout(timeout) {
            (try? await self.evaluateJS(script, in: page)) as? String
        }
        guard case .finished(let answer) = outcome, let json = answer, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(HeldContentReply.self, from: data) else {
            DebugLog.log(.lifecycle, "[BlockSyncService] fetchContentHoldingReports: no answer within \(timeout)")
            return nil
        }
        if let hold = reply.hold {
            reportApplier.registerSaveCover(session: hold.session, through: hold.through)
            DebugLog.alwaysPersisted("[PUSH] save read holds the reports through es=\(hold.through)")
        }
        return reply.content?.contiguousUTF8Copy
    }

    /// The bound of a rebuild's `flushAndAck` (its own constant since B4; it was one 8 s poll watchdog period, which a forced poll
    /// had): past it the writer is stuck, which is a fault, and the rebuild goes on against the database as it is.
    nonisolated static let rebuildFlushAndAckBound: TimeInterval = 8

    /// The rebuild waits (bibliography, Notes, footnote insert) and the editor-first commands' closing pushes (the delete's
    /// closing push, the duplicate's settle-time id push): before they read the database, everything the Rich Text page holds
    /// is posted and decided (`flushAndAck`). Returns whether it settled; the rebuild handlers go on regardless, the closing pushes
    /// do not (a flush that did not settle may have left typing out of the database, and reading it then would hand the push an
    /// older document than the editor holds). No Rich Text page (Markdown mode): nothing can be pending in one, so true.
    @discardableResult
    func flushForDatabaseRebuild() async -> Bool {
        guard webView != nil else { return true }
        #if DEBUG
        let bound = testRebuildFlushBound ?? Self.rebuildFlushAndAckBound
        #else
        let bound = Self.rebuildFlushAndAckBound
        #endif
        return await flushAndAck(bound: bound) == .settled
    }

    /// `withResettingContentRecovery` (ViewNotificationModifiers.swift): when a resetting-content window closes, whatever the page
    /// held back meanwhile is sent (`flushAndAck`; nothing waits on it; kept for its log).
    func forceSendForResettingContentRecovery() async {
        _ = await flushAndAck(bound: Self.rebuildFlushAndAckBound)
    }

    /// A lifecycle that did not finish (a cancelled close) lets the page post again.
    func releaseReportHold(on page: WKWebView?) async {
        guard let page = page ?? webView else { return }
        _ = try? await evaluateJS("window.FinalFinal.releaseReportHold && window.FinalFinal.releaseReportHold(); true", in: page)
    }
}
