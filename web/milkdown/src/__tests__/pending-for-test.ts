// pending-for-test.ts -- Phase 5 job B4: the page's poll bridge (`hasBlockChanges`, `getBlockChanges` of window.FinalFinal) was
// removed with Swift's 2-second poll; the editor's reports take the plugin's pending maps instead (report-outbox.ts). The vitest
// harnesses run with reporting off and stand in for Swift by draining the maps themselves; these two helpers do that exactly as
// the removed bridge did, including its hold: while a press is latched (undo-coordinator.ts `isTypingPushHeld`) the typing is held
// back, as a report is not posted then.

import { type BlockChanges, getBlockChanges, hasPendingChanges } from '../block-sync-plugin';
import { isTypingPushHeld } from '../undo-coordinator';

/** What a report would take now: the plugin's pending maps (drained), or nothing while the typing is held back. */
export function takePendingAsReport(): BlockChanges {
  if (isTypingPushHeld()) return { updates: [], inserts: [], deletes: [] };
  return getBlockChanges();
}

/** Whether a report would carry anything now (false while the typing is held back). */
export function hasReportablePending(): boolean {
  return isTypingPushHeld() ? false : hasPendingChanges();
}
