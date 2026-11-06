//
//  BlockSyncService+Transition.swift
//  final final
//
//  Phase 5 job A7 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 1): the Swift half of the zoom
//  transition's page calls (web/milkdown/src/api-transition.ts). A zoom used to write a cached copy of the text, re-read the rows and push
//  the whole document over the editor, losing keys typed between the copy and the push (the sync model's windows W1 and W2). Now:
//
//    TransBegin + TransLiveRead  `beginTransition`: ticket N is reserved and the page call submitted in ONE synchronous stretch
//                                (`submitEditorFirstCall`, so reservation order is execution order); the page drains its pending batch,
//                                starts recording and holds every later key back from the polls (`pend' = {}`), in one turn.
//    the batch                   written through the forced poll's write half (`applyFetchedBatch`), as ticket N.
//    TransBarrier / BarrierOpen  `awaitTransitionBarrier`: `DocumentWriter.awaitSettled(through: N)`, everything reserved up to and
//                                including our batch has settled. Read-only; on its bound nothing is changed and the caller abandons.
//    TransPushFrom + TransReplay `swapTransition`: the page replaces its document with the rows' text and puts the recorded typing back on
//                                top in one turn; what the target cannot hold (zoom in: typing outside the range) comes back as `outside`.
//    the outside batch           `writeTransitionBatch`: the model's carried key with a TEMP id, written as an ordinary batch through the
//                                queue right after the state is idle again.
//
//  The refusal path (the page could not carry the typing) is not modelled; the web tests cover it and Swift's catch-up is in
//  EditorViewState+ZoomTransition.swift.
//

import Foundation
import WebKit

/// The reply of `window.FinalFinal.beginTransition()`. `batch` is present only when the call began (it is what the page drained).
struct TransitionBeginReply: Decodable {
    let succeeded: Bool
    let token: Int?
    let reason: String?
    let batch: BlockChanges

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case token, reason, batch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        token = try container.decodeIfPresent(Int.self, forKey: .token)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        batch = try container.decodeIfPresent(BlockChanges.self, forKey: .batch) ?? BlockChanges()
    }
}

/// How `beginTransition` ended.
enum TransitionBegin: Equatable {
    /// The page holds and records, its batch has been written and the barrier is open: the caller reads the rows and swaps.
    case ready(token: Int)
    /// Nothing is held (no page, the page refused, the bridge failed): the caller takes today's path for this one transition.
    case notStarted(reason: String)
    /// The writer did not settle within the bound (a stuck writer, a fault): the hold has been ended and the held typing goes out with
    /// the next poll. The caller abandons the transition and tells the user.
    case barrierTimedOut(token: Int)
}

/// The options `window.FinalFinal.swapTransition(token, options)` takes (api-transition.ts, `SwapTransitionOptions`), encoded as JSON.
struct TransitionSwapPayload: Encodable {
    struct Image: Encodable, Equatable {
        let id: String
        let width: Int?
        let caption: String?
        let alt: String?
    }

    let markdown: String
    let blockIds: [String]
    let expected: [BlockParser.BlockAlignmentMeta]
    let managedBlockIds: [String]
    let imageMeta: [Image]
    let zoomMode: Bool
    let scrollToStart: Bool
    let scrollToBlockId: String?
    /// Phase 5 job A10: typing replayed at the very point where the target inserted text goes after it (api-transition.ts). Nil: omitted.
    var carriedTextFirst: Bool?

    static func images(_ meta: [ContentView.ImageBlockMeta]) -> [Image] {
        meta.map { Image(id: $0.id, width: $0.width, caption: $0.caption, alt: $0.alt) }
    }
}

/// The reply of `window.FinalFinal.swapTransition(...)`.
struct TransitionSwapReply: Decodable {
    let succeeded: Bool
    let reason: String?
    let replayed: Int?
    let dropped: Int?
    let outside: BlockChanges?
    let batch: BlockChanges?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case reason, replayed, dropped, outside, batch
    }
}

/// A caret as a page reports it: a Markdown line and column.
struct TransitionPageCursor: Decodable {
    let line: Int
    let column: Int
}

/// The reply of the switch's page calls that read a held page without ending its hold (Phase 5 jobs A9 and A10): the Rich Text page's
/// `takeTransitionBatch` (`batch`, `cursor`), the Markdown page's `takeTransitionText` (`base`, `raw`, `cursor`), and the prepare of an
/// incoming Rich Text page (`token`).
struct TransitionTakeReply: Decodable {
    let succeeded: Bool
    let batch: BlockChanges?
    let base: String?
    let raw: String?
    let token: Int?
    let cursor: TransitionPageCursor?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case batch, base, raw, token, cursor, reason
    }
}

/// How `swapTransition` ended.
enum TransitionSwap {
    /// The page shows the target with the recorded typing on top (`replayed` steps); `outside` is typing in blocks the target lacks.
    case swapped(replayed: Int, outside: BlockChanges)
    /// The page could not carry the typing and left its document as the user had it; `batch` is the held typing, which the caller writes
    /// before it catches up the old way.
    case refused(reason: String, batch: BlockChanges)
}

extension BlockSyncService {
    /// The barrier's bound: the Markdown page wait's (a stuck writer is a fault, not everyday use).
    nonisolated static let transitionBarrierTimeout: TimeInterval = 15

    /// Steps 1 to 3 of the design's protocol: TransBegin + TransLiveRead, the batch through the queue, TransBarrier. See the file header.
    func beginTransition(barrierTimeout: TimeInterval = BlockSyncService.transitionBarrierTimeout) async -> TransitionBegin {
        guard let database = projectDatabase, let projectId, webView != nil else { return .notStarted(reason: "not configured") }
        // TransBegin + TransLiveRead: ticket N reserved and the call submitted in one synchronous stretch.
        let script = "JSON.stringify(window.FinalFinal.beginTransition())"
        guard let submission = await submitEditorFirstCall(database: database, projectId: projectId, script: script) else {
            return .notStarted(reason: "no writer turn")
        }
        let ticket = submission.ticket
        let json: String?
        switch submission.result {
        case .failure(let error):
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            await endTransition(token: nil) // the page may hold without Swift knowing its token
            return .notStarted(reason: "the page call threw: \(error)")
        case .success(let value):
            json = value
        }
        guard let json, let data = json.data(using: .utf8), let reply = try? JSONDecoder().decode(TransitionBeginReply.self, from: data) else {
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            await endTransition(token: nil)
            return .notStarted(reason: "the page's reply could not be read")
        }
        guard reply.succeeded, let token = reply.token else {
            ticket.settleIfOpen(.empty)
            return .notStarted(reason: reply.reason ?? "refused")
        }
        // The batch the page drained, written as ticket N through the forced poll's write half.
        applyTransitionBatch(reply.batch, ticket: ticket, stamp: submission.stamp, database: database, projectId: projectId)
        DebugLog.alwaysPersisted(
            "[TRANS] begin token=\(token) batch u=\(reply.batch.updates.count) i=\(reply.batch.inserts.count) "
                + "d=\(reply.batch.deletes.count) seq=\(ticket.seq)")
        // TransBarrier: everything reserved up to and including our batch has settled.
        guard await awaitTransitionBarrier(through: ticket.seq, timeout: barrierTimeout) else {
            await endTransition(token: token)
            return .barrierTimedOut(token: token)
        }
        return .ready(token: token)
    }

    /// TransBarrier / TransBarrierOpen: read-only, changes nothing on its bound (`DocumentWriter.awaitSettled`). True when settled.
    func awaitTransitionBarrier(through seq: UInt64, timeout: TimeInterval) async -> Bool {
        guard let writer else { return true }
        let outcome = await writer.awaitSettled(through: seq, timeout: timeout)
        if case .stillOpen(let open) = outcome {
            DebugLog.alwaysPersisted("[TRANS] barrier timed out after \(Int(timeout)) s; still open: \(open)")
            return false
        }
        return true
    }

    /// TransPushFrom + TransReplay: the page call that swaps the target in with the recorded typing on top, in one turn. On success the
    /// coordinator learns the pushed text (`.blockSyncDidPushContent`, as `setContentWithBlockIds` posts it), so `updateNSView` does not
    /// re-push it without ids. A bridge failure is treated as a refusal with nothing handed back (the page state is unknown; the catch-up
    /// pushes the rows the old way).
    func swapTransition(token: Int, payload: TransitionSwapPayload) async -> TransitionSwap {
        guard let webView else { return .refused(reason: "noWebView", batch: BlockChanges()) }
        guard let payloadData = try? JSONEncoder().encode(payload), let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            await endTransition(token: token)
            return .refused(reason: "the payload could not be encoded", batch: BlockChanges())
        }
        // JSON is a JavaScript expression: the payload goes in as an object literal, with no template-literal escaping to get wrong.
        let script = "JSON.stringify(window.FinalFinal.swapTransition(\(token), \(payloadJSON)))"
        let value: String?
        do {
            value = try await evaluateJS(script, in: webView) as? String
        } catch {
            await endTransition(token: token)
            return .refused(reason: "the page call threw: \(error)", batch: BlockChanges())
        }
        guard let value, let data = value.data(using: .utf8), let reply = try? JSONDecoder().decode(TransitionSwapReply.self, from: data) else {
            await endTransition(token: token)
            return .refused(reason: "the page's reply could not be read", batch: BlockChanges())
        }
        guard reply.succeeded else {
            return .refused(reason: reply.reason ?? "refused", batch: reply.batch ?? BlockChanges())
        }
        NotificationCenter.default.post(name: .blockSyncDidPushContent, object: nil, userInfo: ["markdown": payload.markdown])
        return .swapped(replayed: reply.replayed ?? 0, outside: reply.outside ?? BlockChanges())
    }

    /// Phase 5 job A9 (the switch to Markdown; a9-notes.md): drains the typing the outgoing Rich Text page holds since the begin (or the last
    /// take) WITHOUT ending the hold, from `page` (the outgoing page, held strongly by the caller: after the flip it is no longer in the
    /// window but still runs). Nil when the page could not answer or the token is stale; `cursor` is the caret's Markdown line and column
    /// when the batch is not empty.
    func takeTransitionBatch(token: Int, from page: WKWebView) async -> (batch: BlockChanges, cursor: CursorPosition?)? {
        let script = "JSON.stringify(window.FinalFinal.takeTransitionBatch(\(token)))"
        guard let json = (try? await evaluateJS(script, in: page)) as? String, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(TransitionTakeReply.self, from: data) else { return nil }
        guard reply.succeeded, let batch = reply.batch else {
            DebugLog.alwaysPersisted("[TRANS] take refused: \(reply.reason ?? "?")")
            return nil
        }
        return (batch, reply.cursor.map { CursorPosition(line: $0.line, column: $0.column) })
    }

    /// Ends a hold whose swap never came (`token` nil: any hold, for a begin whose reply could not be read). The typing held meanwhile is
    /// still in the page's own pending queue and goes out with the next poll.
    func endTransition(token: Int?, on page: WKWebView? = nil) async {
        guard let webView = page ?? webView else { return }
        let script = "JSON.stringify(window.FinalFinal.endTransition(\(token.map(String.init) ?? "null")))"
        _ = try? await evaluateJS(script, in: webView)
    }

    /// Writes `changes` (the zoom-in's outside batch, or a refused swap's held typing) as an ordinary batch through the queue: ticket
    /// reserved here, synchronously, with no `await` before it, so the caller decides exactly where in the main actor's order it lands.
    /// Returns the ticket's sequence (for `awaitTransitionBarrier`), or nil when there was nothing to write or no turn could be had.
    @discardableResult
    func writeTransitionBatch(_ changes: BlockChanges) -> UInt64? {
        guard !changes.isEmpty, let database = projectDatabase, let projectId,
              let (ticket, stamp) = reserveWriterTurn(database: database, projectId: projectId) else { return nil }
        applyTransitionBatch(changes, ticket: ticket, stamp: stamp, database: database, projectId: projectId)
        return ticket.seq
    }

    /// Hands an already-taken batch to `applyFetchedBatch` (the forced poll's write half) on its own task; an empty one settles at once.
    private func applyTransitionBatch(
        _ changes: BlockChanges, ticket: WriterTicket, stamp: BlockWriteStamp, database: ProjectDatabase, projectId: String
    ) {
        guard !changes.isEmpty, let webView else {
            ticket.settleIfOpen(.empty)
            return
        }
        ticket.noteFetched()
        Task { @MainActor [weak self] in
            defer { ticket.settleIfOpen(.noBatch) }
            await self?.applyFetchedBatch(
                ticket: ticket, changes: changes, stamp: stamp, webView: webView, database: database, projectId: projectId, force: false)
        }
    }
}
