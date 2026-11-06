//
//  ReportIntake.swift
//  final final
//
//  Phase 5 job B2 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, section 2.2): Swift's side of the editor's SHADOW block
//  reports (web/milkdown/src/report-outbox.ts). In B2 it only RECORDS each report and COMPARES the reports with what the 2-second poll
//  fetches: nothing is reserved, applied or acknowledged from a report, so the poll is still the only input of the writer and a
//  failure here can never lose a change.
//
//  Receipt is synchronous in the script-message delegate callback (correction 5 of the design: no `Task` hop), so a report is recorded
//  in the order WebKit delivered it, before any later page reply is handled.
//
//  The comparison. Every drain of the page's pending maps (the poll, an editor-first route, a transition) posts a `drain` report first,
//  carrying what the shadow held; the poll's reply names its own drain report (`reportThrough`). The reports after the previous
//  compared poll drain, up to and including this one, are folded with the plugin's own merge rules (`detectChanges`): a delete removes a
//  pending update and adds a delete; an update of an id pending as an insert merges into the insert, otherwise it replaces the update;
//  an insert sets the insert. A `rebase` report (the page changed its maps other than by detection) and the `drain` report of ANOTHER
//  drain (an editor-first route took the window so far) restart the fold. Every id on both sides is first resolved through the writer's
//  temp-id map, so when a confirmation lands does not matter. Then one line, persisted:
//    [PUSH-CMP] agree es=a..b reports=n u=.. i=.. d=..
//    [PUSH-CMP] DISAGREE es=a..b reports=n <digest: ids, fields, lengths; never document text>
//    [PUSH-CMP] gap es=a..b missing=[..]            (a report never arrived; no verdict)
//    [PUSH-CMP] gap es=a..b missing=[..] explained: before a restart at es=k  (followed by the verdict line: the fold starts after it)
//

import Foundation
import os
import WebKit

/// One recorded report.
struct RecordedReport: Sendable {
    enum Kind: String, Sendable { case changes, drain, rebase }
    let sequence: Int
    let kind: Kind
    let changes: BlockChanges
    let detectedAt: Double
    let receivedAt: Date
}

/// The fold of a window of reports, in the plugin's own shape (`pendingUpdates` / `pendingInserts` / `pendingDeletes`).
struct ReportFold: Sendable {
    var updates: [String: BlockUpdate] = [:]
    var inserts: [String: BlockInsert] = [:]
    var deletes: Set<String> = []

    mutating func reset() { self = ReportFold() }

    /// The plugin's merge rules, in the order the plugin applies a detection's operations: deletes, updates, then inserts.
    mutating func merge(_ changes: BlockChanges) {
        for id in changes.deletes {
            deletes.insert(id)
            updates.removeValue(forKey: id)
        }
        for update in changes.updates {
            if let existing = inserts[update.id] {
                inserts[update.id] = BlockInsert(
                    tempId: existing.tempId, blockType: update.blockType ?? existing.blockType,
                    textContent: update.textContent ?? existing.textContent,
                    markdownFragment: update.markdownFragment ?? existing.markdownFragment,
                    headingLevel: update.headingLevel, afterBlockId: existing.afterBlockId,
                    atDocumentStart: existing.atDocumentStart)
            } else {
                updates[update.id] = update
            }
        }
        for insert in changes.inserts { inserts[insert.tempId] = insert }
    }

    var asChanges: BlockChanges {
        BlockChanges(updates: Array(updates.values), inserts: Array(inserts.values), deletes: Array(deletes))
    }
}

/// What the comparison found (for the log line and for tests).
enum ReportComparison: Equatable, Sendable {
    case agree(fromEs: Int, throughEs: Int, reports: Int)
    case disagree(fromEs: Int, throughEs: Int, reports: Int, digest: String)
    case gap(fromEs: Int, throughEs: Int, missing: [Int])
}

@MainActor
final class ReportIntake {
    /// One intake for the process: reports name their page session, so pages never mix.
    static let shared = ReportIntake()

    private struct SessionState {
        var reports: [Int: RecordedReport] = [:]
        var highestReceived = 0
        /// The `es` of the last poll drain this session's reports were compared up to.
        var comparedThrough = 0
        var pending: PendingCompare?
    }

    /// A poll fetch whose own drain report had not arrived yet.
    private struct PendingCompare {
        let drained: BlockChanges
        let through: Int
        let idMap: [String: String]
    }

    private var sessions: [String: SessionState] = [:]
    private var sessionOrder: [String] = []
    private static let maxSessions = 4
    /// A page that is never polled (a prepared switch page not yet shown) keeps at most this many reports.
    private static let maxReportsPerSession = 2_000

    /// Ignore reports entirely (`FF_UI_TESTING_LEGACY_POLL=1`).
    var isDisabled = TestMode.isUITestingLegacyPoll

    private(set) var receivedCount = 0
    /// Main-thread time spent in `receive(body:)` since the last verdict line (it goes on that line as `recvMs=`).
    private var receiveNanosSinceVerdict: UInt64 = 0
    private var receivesSinceVerdict = 0
    private static let signposter = OSSignposter(subsystem: "com.kerim.final-final", category: "PushReport")
    private(set) var results: [ReportComparison] = []

    init() {}

    // MARK: Receipt

    /// Records one `blockReport` message body. Synchronous; reserves, applies and answers nothing.
    func receive(body: Any) {
        guard !isDisabled else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let interval = Self.signposter.beginInterval("receive")
        defer {
            Self.signposter.endInterval("receive", interval)
            receiveNanosSinceVerdict += DispatchTime.now().uptimeNanoseconds - started
            receivesSinceVerdict += 1
        }
        guard let dict = body as? [String: Any],
              let sequence = (dict["es"] as? NSNumber)?.intValue, let session = dict["session"] as? String,
              let kindRaw = dict["kind"] as? String, let kind = RecordedReport.Kind(rawValue: kindRaw),
              let json = dict["json"] as? String, let data = json.data(using: .utf8),
              let changes = try? JSONDecoder().decode(BlockChanges.self, from: data) else {
            DebugLog.alwaysPersisted("[PUSH-CMP] unreadable report dropped")
            return
        }
        let detectedAt = (dict["detectedAt"] as? NSNumber)?.doubleValue ?? 0
        let report = RecordedReport(sequence: sequence, kind: kind, changes: changes, detectedAt: detectedAt, receivedAt: Date())
        receive(report, session: session)
    }

    func receive(_ report: RecordedReport, session: String) {
        guard !isDisabled else { return }
        receivedCount += 1
        var state = sessionState(session)
        if report.sequence > state.comparedThrough, state.reports.count < Self.maxReportsPerSession {
            state.reports[report.sequence] = report
        }
        state.highestReceived = max(state.highestReceived, report.sequence)
        sessions[session] = state
        if let pending = state.pending, state.highestReceived >= pending.through {
            sessions[session]?.pending = nil
            compareNow(session: session, drained: pending.drained, through: pending.through, idMap: pending.idMap)
        }
    }

    private func sessionState(_ session: String) -> SessionState {
        if let state = sessions[session] { return state }
        sessionOrder.append(session)
        if sessionOrder.count > Self.maxSessions {
            let dropped = sessionOrder.removeFirst()
            sessions.removeValue(forKey: dropped)
        }
        sessions[session] = SessionState()
        return SessionState()
    }

    // MARK: Comparison

    /// The poll fetched `drained`; its drain posted report `through` on page `session`. Compares now, or when that report arrives.
    func compare(drained: BlockChanges, through: Int, session: String, idMap: [String: String]) {
        guard !isDisabled else { return }
        var state = sessionState(session)
        guard through > state.comparedThrough else { return }
        if state.highestReceived < through {
            state.pending = PendingCompare(drained: drained, through: through, idMap: idMap)
            sessions[session] = state
            return
        }
        sessions[session] = state
        compareNow(session: session, drained: drained, through: through, idMap: idMap)
    }

    private func compareNow(session: String, drained: BlockChanges, through: Int, idMap: [String: String]) {
        guard var state = sessions[session] else { return }
        let from = state.comparedThrough + 1
        let result = Self.compare(reports: state.reports, from: from, through: through, drained: drained, idMap: idMap)
        state.comparedThrough = through
        state.reports = state.reports.filter { $0.key > through }
        sessions[session] = state
        record(result.verdict, explainedGap: result.explainedGap)
    }

    private func record(_ verdict: ReportComparison, explainedGap: (missing: [Int], restartEs: Int)?) {
        results.append(verdict)
        if results.count > 200 { results.removeFirst(results.count - 200) }
        if let gap = explainedGap {
            DebugLog.alwaysPersisted(
                "[PUSH-CMP] gap missing=\(gap.missing) explained: before a restart at es=\(gap.restartEs)")
        }
        let recvMs = String(format: "%.2f", Double(receiveNanosSinceVerdict) / 1_000_000)
        DebugLog.alwaysPersisted(Self.line(for: verdict) + " received=\(receivesSinceVerdict) recvMs=\(recvMs)")
        receiveNanosSinceVerdict = 0
        receivesSinceVerdict = 0
    }

    static func line(for verdict: ReportComparison) -> String {
        switch verdict {
        case .agree(let from, let through, let reports):
            return "[PUSH-CMP] agree es=\(from)..\(through) reports=\(reports)"
        case .disagree(let from, let through, let reports, let digest):
            return "[PUSH-CMP] DISAGREE es=\(from)..\(through) reports=\(reports) \(digest)"
        case .gap(let from, let through, let missing):
            return "[PUSH-CMP] gap es=\(from)..\(through) missing=\(missing)"
        }
    }

    /// Pure: folds the reports `from...through` and compares the fold with `drained`, every id resolved through `idMap`.
    static func compare(
        reports: [Int: RecordedReport], from: Int, through: Int, drained: BlockChanges, idMap: [String: String]
    ) -> (verdict: ReportComparison, explainedGap: (missing: [Int], restartEs: Int)?) {
        let window = from <= through ? Array(from...through) : []
        let missing = window.filter { reports[$0] == nil }
        // The fold restarts at a rebase and at another drain's report (not this poll's own, `through`).
        let restarts = window.filter { number in
            guard let report = reports[number] else { return false }
            return report.kind == .rebase || (report.kind == .drain && number != through)
        }
        var foldStart = from
        var explained: (missing: [Int], restartEs: Int)?
        if !missing.isEmpty {
            guard let lastRestart = restarts.last, missing.allSatisfy({ $0 < lastRestart }) else {
                return (.gap(fromEs: from, throughEs: through, missing: missing), nil)
            }
            foldStart = lastRestart
            explained = (missing, lastRestart)
        }
        var fold = ReportFold()
        var count = 0
        for number in foldStart...max(foldStart, through) {
            guard let report = reports[number] else { continue }
            count += 1
            switch report.kind {
            case .rebase:
                fold.reset()
                fold.merge(resolve(report.changes, idMap))
            case .drain where number != through:
                fold.reset()   // another drain took everything up to here (its own shadow included)
            case .drain, .changes:
                fold.merge(resolve(report.changes, idMap))
            }
        }
        let digest = difference(fold.asChanges, resolve(drained, idMap))
        if let digest {
            return (.disagree(fromEs: from, throughEs: through, reports: count, digest: digest), explained)
        }
        return (.agree(fromEs: from, throughEs: through, reports: count), explained)
    }

    /// Every id (update, delete, insert key, insert anchor) resolved through the writer's temp-id map.
    static func resolve(_ changes: BlockChanges, _ idMap: [String: String]) -> BlockChanges {
        guard !idMap.isEmpty else { return changes }
        func id(_ raw: String) -> String { idMap[raw] ?? raw }
        return BlockChanges(
            updates: changes.updates.map {
                BlockUpdate(id: id($0.id), textContent: $0.textContent, markdownFragment: $0.markdownFragment,
                            headingLevel: $0.headingLevel, blockType: $0.blockType)
            },
            inserts: changes.inserts.map {
                BlockInsert(tempId: id($0.tempId), blockType: $0.blockType, textContent: $0.textContent,
                            markdownFragment: $0.markdownFragment, headingLevel: $0.headingLevel,
                            afterBlockId: $0.afterBlockId.map(id), atDocumentStart: $0.atDocumentStart)
            },
            deletes: changes.deletes.map(id))
    }

    /// A comparable signature per entry: kind and id as the key, every field as the value (text only through its length and a hash).
    private static func entries(_ changes: BlockChanges) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        func textSig(_ text: String?) -> String {
            guard let text else { return "nil" }
            return "len\(text.utf16.count)#\(String(stableHash(text) % 1_679_616, radix: 36))"
        }
        for update in changes.updates {
            out["u:" + update.id] = [
                "text": textSig(update.textContent), "md": textSig(update.markdownFragment),
                "level": update.headingLevel.map(String.init) ?? "nil", "type": update.blockType ?? "nil"
            ]
        }
        for insert in changes.inserts {
            out["i:" + insert.tempId] = [
                "text": textSig(insert.textContent), "md": textSig(insert.markdownFragment),
                "level": insert.headingLevel.map(String.init) ?? "nil", "type": insert.blockType,
                "after": insert.afterBlockId.map { String($0.prefix(13)) } ?? "nil",
                "start": insert.atDocumentStart.map { $0 ? "1" : "0" } ?? "nil"
            ]
        }
        for id in changes.deletes { out["d:" + id] = [:] }
        return out
    }

    /// A deterministic hash (FNV-1a over UTF-8), so a digest names the same text the same way in every launch.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// nil when equal; otherwise a digest of at most 10 differences: ids (13 characters), field names and lengths, never text.
    static func difference(_ reported: BlockChanges, _ polled: BlockChanges) -> String? {
        let left = entries(reported)
        let right = entries(polled)
        guard left != right else { return nil }
        var parts: [String] = []
        for key in Set(left.keys).union(right.keys).sorted() {
            let short = String(key.prefix(15))
            switch (left[key], right[key]) {
            case (nil, .some(let fields)):
                parts.append("poll-only \(short)\(fields["text"].map { " \($0)" } ?? "")")
            case (.some(let fields), nil):
                parts.append("report-only \(short)\(fields["text"].map { " \($0)" } ?? "")")
            case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                let fields = Set(lhs.keys).union(rhs.keys).sorted().filter { lhs[$0] != rhs[$0] }
                parts.append("differ \(short) " + fields.map { "\($0)=\(lhs[$0] ?? "-")/\(rhs[$0] ?? "-")" }.joined(separator: ","))
            default:
                continue
            }
        }
        let shown = parts.prefix(10).joined(separator: "; ")
        return "reported(u=\(reported.updates.count) i=\(reported.inserts.count) d=\(reported.deletes.count)) "
            + "polled(u=\(polled.updates.count) i=\(polled.inserts.count) d=\(polled.deletes.count)): \(shown)"
            + (parts.count > 10 ? "; +\(parts.count - 10) more" : "")
    }

    // MARK: The page's configuration

    /// The document-start script that tells the Rich Text page whether to report and its interval R (`window.__FF_REPORTS__`).
    static func configUserScript() -> WKUserScript {
        let enabled = !TestMode.isUITestingLegacyPoll
        let interval = TestMode.uiTestingReportIntervalMs.map { ", intervalMs: \($0)" } ?? ""
        return WKUserScript(
            source: "window.__FF_REPORTS__ = { enabled: \(enabled)\(interval) };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// The poll's fetch script: with reporting on, the same drain plus the drain report's number (falls back to the plain fetch on a
    /// page without it); with `FF_UI_TESTING_LEGACY_POLL=1`, exactly the old script.
    static var pollFetchScript: String {
        if TestMode.isUITestingLegacyPoll { return "JSON.stringify(window.FinalFinal.getBlockChanges())" }
        return "JSON.stringify((window.FinalFinal.getBlockChangesReported || window.FinalFinal.getBlockChanges)())"
    }

    /// The two extra fields of the reported fetch's reply.
    struct PollWindow: Decodable {
        let reportThrough: Int?
        let reportSession: String?
    }
}
