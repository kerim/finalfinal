//
//  EditorFirstRig+TypingAcrossUndo.swift
//  final finalTests
//
//  Tier 2 (t-d2061b27, Phase 4c job 2, coder S rounds S1 and S2): the scripted editor's switches and answers for typing across a waiting
//  Cmd-Z or Cmd-Shift-Z in Rich Text.
//
//  The switches live in ONE state object (`TypingAcrossUndoStubState`, held by the rig as `typingStubs`: a stored property each in the class
//  would have pushed EditorFirstDeleteTests.swift over the file-length limit) and are forwarded below as properties of the rig, so a test
//  reads `rig.swapReplaysTyping = true`:
//    - `swapReplaysTyping` / `quickUndoReplaysTyping`: the next SUCCESSFUL slow swap / quick undo answers `typingReplayed: true` and an
//      EMPTY batch, as the real page does when it put the typing done during the wait back on top (spent by the call);
//    - `heldTypingBatch`: typing the page is HOLDING back from the polls for a latched press. `hasBlockChanges` / `getBlockChanges` do
//      not see it until `releaseHeldTypingPushes` (the lifecycle's call) moves it into `typingQueue`, or `releaseHeldTypingAndGetBatch`
//      (the old body's call) hands it back as the batch (spent by the release);
//    - `releaseHeldPushesHold`: awaited inside the answer to `releaseHeldTypingPushes` (a page that answers late or never: the caller's
//      bound cancels it); `releaseHeldPushesCalls`, `releaseAndGetBatchCalls`: how often each release call reached the page;
//    - `redoReplyBatch`: the batch the next quick REDO of a Duplicate or a restore answers (the typing done in the redo's wait; spent).
//  With nothing set, the two release calls answer "nothing" (false, an empty batch), so every test that sets no switch sees an editor that
//  held nothing.
//

import Foundation
import Testing
@testable import final_final

/// The switches of the stand-in editor for typing across a waiting press (see the file header).
@MainActor
final class TypingAcrossUndoStubState {
    var swapReplaysTyping = false
    var quickUndoReplaysTyping = false
    var heldTypingBatch: BlockChanges?
    var releaseHeldPushesHold: (() async -> Void)?
    var releaseHeldPushesCalls = 0
    var releaseAndGetBatchCalls = 0
    var redoReplyBatch: BlockChanges?
    var redoReplyTyped: Bool?
}

/// The JSON `releaseHeldTypingAndGetBatch` answers.
private struct ReleasedTypingStubReply: Encodable {
    var released: Bool
    var batch: BlockChanges
}

extension EditorFirstRig {

    var swapReplaysTyping: Bool {
        get { typingStubs.swapReplaysTyping }
        set { typingStubs.swapReplaysTyping = newValue }
    }
    var quickUndoReplaysTyping: Bool {
        get { typingStubs.quickUndoReplaysTyping }
        set { typingStubs.quickUndoReplaysTyping = newValue }
    }
    var heldTypingBatch: BlockChanges? {
        get { typingStubs.heldTypingBatch }
        set { typingStubs.heldTypingBatch = newValue }
    }
    var releaseHeldPushesHold: (() async -> Void)? {
        get { typingStubs.releaseHeldPushesHold }
        set { typingStubs.releaseHeldPushesHold = newValue }
    }
    var releaseHeldPushesCalls: Int { typingStubs.releaseHeldPushesCalls }
    var releaseAndGetBatchCalls: Int { typingStubs.releaseAndGetBatchCalls }
    var redoReplyBatch: BlockChanges? {
        get { typingStubs.redoReplyBatch }
        set { typingStubs.redoReplyBatch = newValue }
    }
    var redoReplyTyped: Bool? {
        get { typingStubs.redoReplyTyped }
        set { typingStubs.redoReplyTyped = newValue }
    }

    /// Round 6: the page puts a boolean `typed` (its gate's own answer: the user typed since the press) in the `ok: true` reply of every
    /// Rich Text quick redo. This adds it to the stand-in's reply when a test set `redoReplyTyped` (spent by the call); a refused
    /// reply and a rig with nothing set are returned unchanged (the field is absent, as on every other reply).
    func addingTypedFlag(to json: String?) -> String? {
        guard let typed = typingStubs.redoReplyTyped else { return json }
        typingStubs.redoReplyTyped = nil
        guard let json, var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              object["ok"] as? Bool == true else { return json }
        object["typed"] = typed
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return json }
        return String(data: data, encoding: .utf8)
    }

    /// `window.FinalFinal.releaseHeldTypingPushes?.() === true`.
    func answerReleaseHeldTypingPushes(_ script: String) async -> Any? {
        events.note("js " + script)
        _ = try? await js.evaluate(script)   // recorded in the scripted evaluator's list too (S3: TA D1 reads the order of polls against it)
        typingStubs.releaseHeldPushesCalls += 1
        if let hold = typingStubs.releaseHeldPushesHold { await hold() }
        guard let held = typingStubs.heldTypingBatch else { return false }
        typingStubs.heldTypingBatch = nil
        typingQueue.append(held)   // the page now reports it to the next poll
        return true
    }

    /// `JSON.stringify(window.FinalFinal.releaseHeldTypingAndGetBatch())`.
    func answerReleaseHeldTypingAndGetBatch(_ script: String) -> String? {
        events.note("js " + script)
        typingStubs.releaseAndGetBatchCalls += 1
        let held = typingStubs.heldTypingBatch
        typingStubs.heldTypingBatch = nil
        return Self.json(ReleasedTypingStubReply(released: held != nil, batch: held ?? BlockChanges()))
    }
}
