//
//  EditorFirstRig+SlowUndo.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 3, round 3c): the scripted editor's answer for the editor-first SLOW undo and redo:
//  `structuralSwapEditorFirst("<opId>", "undo"|"redo", {payload})` (web/milkdown/src/api-structural-swap.ts). The stored properties are in
//  the class (EditorFirstDeleteTests.swift): `swapClickBatch`, `swapLiveDiffers`, `swapAnswerNoCheckpoint`, `swapAnswerIdAlignment`,
//  `swapScripts`, `getContentCallsAtSwap`, `onSwapAnswered`. `forceNextJobFailure` is the duplicate's and the restore's switch too.
//
//  What the stand-in editor does at a swap, as the real one does: it consumes the pending batch (`swapClickBatch`, handed back on EVERY
//  path), and then either REFUSES (`docChanged`: the page found the document changed by an automatic update, or a typed step with no
//  place in the target; typing alone no longer refuses, t-d2061b27; `noCheckpoint`: no saved state for
//  the entry; `idAlignment`: the payload does not fit) and changes nothing, or swaps the saved document in. The document it swaps in is
//  the payload's Markdown (the snapshot's document, which is what the entry's checkpoint holds), under the payload's ids; the reply lists
//  those ids as inserted and the live document's ids (the database's rows, which still lack the change because the job has not run) as
//  removed. `rig.editorText`, `rig.quickEditorText` and `editorState.content` become the swapped-in Markdown, as the editor's
//  `contentChanged` makes them (unless `withholdContentUpdate`).
//
//  The rig names no production type of the slow undo (it builds its replies with its own structs), so a break patch that sends the slow
//  undo back to the old body leaves it compiling.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The JSON `structuralSwapEditorFirst` answers: the shape of a WHOLE replace, plus `swappedTo` on success.
private struct SwapStubReply: Encodable {
    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var insertedIds: [String] = []
    var insertedLeaderIds: [String] = []
    var insertedSectionsSnapshot: [String] = []
    var removedIds: [String] = []
    var removedLeaderIds: [String] = []
    var predecessorId: String?
    var swappedTo: String?
    /// t-d2061b27: present (as `true`) only when the page put the typing done during the wait back on top of the swapped-in document.
    var typingReplayed: Bool?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case insertedIds
        case insertedLeaderIds
        case insertedSectionsSnapshot
        case removedIds
        case removedLeaderIds
        case predecessorId
        case swappedTo
        case typingReplayed
    }
}

/// The part of the editor's argument the stand-in needs.
private struct SwapStubPayload: Decodable {
    struct Expected: Decodable {
        let blockType: String
    }

    let markdown: String
    let blockIds: [String]
    let expectedBlocks: [Expected]
}

extension EditorFirstRig {

    /// `structuralSwapEditorFirst("<opId>", "undo"|"redo", {payload})`.
    func answerSwapClick(_ script: String) -> String? {
        swapScripts.append(script)
        events.note("js " + script)
        getContentCallsAtSwap = getContentCalls
        if let hook = onSwapAnswered {
            onSwapAnswered = nil
            hook()
        }
        let batch = swapClickBatch ?? BlockChanges()
        swapClickBatch = nil
        let literals = Self.stringLiterals(in: script)
        guard literals.count >= 2, let payload = Self.swapPayload(in: script) else { return nil }
        let direction = literals[1]

        // The refusals: nothing is swapped, the batch is on the reply.
        if swapLiveDiffers {
            swapLiveDiffers = false
            return Self.json(SwapStubReply(batch: batch, succeeded: false, reason: "docChanged"))
        }
        if swapAnswerNoCheckpoint {
            swapAnswerNoCheckpoint = false
            return Self.json(SwapStubReply(batch: batch, succeeded: false, reason: "noCheckpoint"))
        }
        if swapAnswerIdAlignment {
            swapAnswerIdAlignment = false
            return Self.json(SwapStubReply(batch: batch, succeeded: false, reason: "idAlignment"))
        }

        // The swap: the live document's ids go out, the payload's come in.
        let rows = BlockParser.assemblySorted((try? blocks()) ?? [])
        let leaderTypes: Set<String> = ["heading", "section_break"]
        var reply = SwapStubReply(batch: batch)
        reply.insertedIds = payload.blockIds
        reply.insertedLeaderIds = zip(payload.blockIds, payload.expectedBlocks).filter { leaderTypes.contains($0.1.blockType) }.map(\.0)
        reply.removedIds = rows.map(\.id)
        reply.removedLeaderIds = rows.filter { $0.blockType == .heading || $0.isPseudoSection }.map(\.id)
        reply.swappedTo = direction == "undo" ? "checkpoint" : "redo"
        if swapReplaysTyping {
            // The page put the wait typing back on top; the replay is its only carrier, so the batch is empty (t-d2061b27).
            swapReplaysTyping = false
            reply.batch = BlockChanges()
            reply.typingReplayed = true
        }

        quickEditorText = payload.markdown
        editorText = payload.markdown
        if !withholdContentUpdate { editorState.content = payload.markdown }   // `contentChanged` after the swap
        if emulatesFootnoteContentChange, !withholdContentUpdate {
            // The real editor tells Swift its text through the 50 ms `contentChanged` debounce, i.e. AFTER the click's reply has been
            // processed (and the job reserved): the footnote service's check of the swapped-in text runs then, not inside the reply.
            // `events` gets "content push" when it has run, so a test can wait for it (fix round F1, finding D).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.runContentChangeHandlers()
                self?.events.note("content push")
            }
        }

        // A database fault in the queued job: every insert of a row of the swapped-in document aborts, so the job throws while it writes
        // the rows and its whole transaction rolls back; the database is left EXACTLY as it was (the restore answer's trigger).
        if forceNextJobFailure {
            forceNextJobFailure = false
            let idList = payload.blockIds.map { "'\($0)'" }.joined(separator: ", ")
            _ = try? db.dbWriter.write { database in
                try database.execute(sql: """
                    CREATE TRIGGER failSwapJobInsert BEFORE INSERT ON block WHEN NEW.id IN (\(idList))
                    BEGIN SELECT RAISE(ABORT, 'forced slow undo job failure (test)'); END
                    """)
            }
        }
        return Self.json(reply)
    }

    /// The editor's argument: the JSON object between the first `{` and the last `}` of the script.
    private static func swapPayload(in script: String) -> SwapStubPayload? {
        guard let open = script.firstIndex(of: "{"), let close = script.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(SwapStubPayload.self, from: Data(script[open...close].utf8))
    }
}
