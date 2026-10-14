//
//  EditorViewState+Quit.swift
//  final final
//

import Foundation

extension EditorViewState {
    /// Quit-time flush. Stops and drains the 2s block-sync poll BEFORE flushAllSync(),
    /// mirroring performProjectClose(), so a poll cycle can't re-insert a paragraph the
    /// flush just wrote during the up-to-3s backup wait (TLA+ Finding #8,
    /// Calm_InsertThenQuit).
    ///
    /// Best-effort, with the same residual as close: stopPollingAndDrain() cannot
    /// force a cycle wedged inside evaluateJavaScript to finish, and a cycle that had
    /// already fetched when polling stopped still applies its batch when the reply
    /// arrives (see BlockSyncService.stopPollingAndDrain and the watchdog notes around
    /// raceWithTimeout). Such a wedged or post-fetch-orphan cycle can still land after
    /// this flush. The TLA+ model's QuitDrain, like CloseDrain, waits for
    /// poll.st = "none" and so abstracts that window away. This drain wait is itself
    /// this method's dominant cost when a cycle is wedged: `stopPollingAndDrain()` can
    /// add up to one full poll watchdog period (`BlockSyncService.defaultPollWatchdogSeconds`,
    /// 8s by default) to quit's worst-case time, on top of the WebView fetch timeout
    /// and the bibliography/footnote flush bound below.
    ///
    /// `suppressRebuildsForQuit` is armed FIRST, before the drain even starts: below,
    /// `flushAllSync()` -> `flushPendingBibliographyAndFootnoteSync()` can force an
    /// already-scheduled bibliography or Notes update to run now, and that update's own
    /// database write posts `.bibliographySectionChanged` / `.notesSectionChanged`.
    /// `stopPollingAndDrain()` only knows about the periodic poll Timer and whatever
    /// unforced cycle is already in flight -- it has no way to stop either handler's own
    /// forced poll (`pollBlockChangesNowForDatabaseRebuild()`), which bypasses the drain
    /// entirely and could re-apply a still-unconfirmed insert on top of the row this
    /// same flush just wrote. Suppressing the rebuild instead means no such poll ever
    /// starts. See `EditorViewState.suppressRebuildsForQuit`'s doc comment for the full
    /// mechanism.
    func flushForQuit() async {
        suppressRebuildsForQuit = true
        let drainStart = Date()
        await blockSyncService?.stopPollingAndDrain()
        DebugLog.log(.lifecycle, "[EditorViewState] flushForQuit: drain took \(Date().timeIntervalSince(drainStart))s")
        if let freshContent = await blockSyncService?.fetchContentFromWebView(),
           !freshContent.isEmpty {
            content = freshContent
        }
        await flushAllSync()
    }
}
