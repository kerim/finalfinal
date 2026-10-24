//
//  MarkdownOwedPull.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 4, O29 and O31: the OWED PULL.
//
//  THE HOLE. The page posts `contentChanged` for what the user types, and Swift's `handleContentPush` drops it while a rebuild or a
//  transition runs (`isResettingContent` up, the content state not idle) or inside the 150 ms grace after a Swift push. The dropped
//  text stays on screen but never reaches the content record, so nothing re-arms the re-parse and the rows stay behind the editor
//  until the next key. A re-parse fire that comes due while the content state is not idle is discarded the same way
//  (`scheduleFullDocumentReparse`), and nothing re-arms it either (model run 3, O31).
//
//  THE FIX. Both set ONE flag on the writer (`notePullOwed`). The next time the content state is idle (the hook in
//  `ContentView.handleContentStateChange`; for a drop inside the 150 ms grace, a short timer, because no transition follows) the pull
//  runs: it reads the page's LIVE text, adopts it into the content record (O25: `adoptMarkdownPageText`) and arms the re-parse, so the
//  typing is saved with no further key.
//
//  WHAT NEVER PULLS. A lifecycle (close, switch, quit), a project change, leaving Markdown mode and zoom are not drops of typing:
//  they save the live text themselves, and a pull after teardown would act on a dead editor. The gate says `abandon` for those and
//  the flag is cleared; the discard site (`discardedFireOwesPull`) never sets it for them.
//
//  The decision logic lives here, away from the SwiftUI view, so a unit test drives it with a stand-in page.
//

import Foundation

@MainActor
enum MarkdownOwedPull {

    /// What the caller's state says about pulling right now.
    enum Gate: Equatable {
        /// Pull now.
        case proceed
        /// The content state is busy: keep the flag, the next idle runs the pull.
        case retryAtIdle
        /// A lifecycle, a project change, a mode change or a zoom: clear the flag, never pull.
        case abandon
    }

    enum Outcome: Equatable {
        case notOwed
        case deferred
        case abandoned
        /// The editor did not answer; the pull stays owed for the next idle.
        case editorSilent
        case pulled
    }

    /// Runs the pull if one is owed. `readLive` reads the page's raw text (`getContentRaw`), `adopt` takes it into the content record,
    /// `arm` schedules the re-parse. The flag is cleared BEFORE the read, so a drop that happens during the read owes a new pull.
    static func runIfOwed(
        writer: MarkdownBlockWriter,
        gate: () -> Gate,
        readLive: () async -> String?,
        adopt: (String) -> Void,
        arm: () -> Void
    ) async -> Outcome {
        guard writer.isPullOwed else { return .notOwed }
        switch gate() {
        case .abandon:
            _ = writer.takePullOwed()
            return .abandoned
        case .retryAtIdle:
            return .deferred
        case .proceed:
            break
        }
        let reason = writer.pullOwedReason ?? "unknown"
        _ = writer.takePullOwed()
        guard let live = await readLive() else {
            DebugLog.alwaysPersisted("[MdWrite] the pull of the live editor text (\(reason)) got no answer from the editor; still owed")
            writer.notePullOwed("the editor did not answer (\(reason))")
            return .editorSilent
        }
        // The read suspended: a lifecycle, a project change or a mode change may have arrived. A busy content state may not stop the
        // adopt: the page's text is the page's text, and adopting it is always right (O25).
        guard gate() != .abandon else { return .abandoned }
        adopt(live)
        arm()
        DebugLog.log(.lifecycle, "[MdWrite] pulled the live editor text (\(reason)) and re-armed the re-parse")
        return .pulled
    }

    /// O31: whether a re-parse fire that was discarded at `scheduleFullDocumentReparse`'s content-state gate owes the pull. ONLY a fire
    /// discarded because the content state was not idle does; leaving Markdown mode and zoom are the gate's other terms and owe nothing.
    /// (The lifecycle, project, cancellation and generation discards are other guards that never reach this one.)
    static func discardedFireOwesPull(contentIsIdle: Bool, isSourceMode: Bool, isZoomed: Bool) -> Bool {
        !contentIsIdle && isSourceMode && !isZoomed
    }
}
