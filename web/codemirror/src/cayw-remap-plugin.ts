/**
 * Remaps every pending CAYW request's start/end range across doc-changing transactions.
 * The Zotero round-trip is a real async HTTP call that can take arbitrary time and is NOT
 * blocked by the app's own UI — if the user keeps editing while a request is pending, the
 * raw offsets captured at open time go stale. This plugin keeps them accurate so the
 * eventual insertion lands in the right place instead of corrupting or duplicating
 * unrelated content.
 *
 * Mirrors caywRemapPlugin in web/milkdown/src/cayw.ts (a ProseMirror Plugin there).
 * CodeMirror 6's equivalent is a ViewPlugin using ChangeDesc.mapPos() — the same
 * remapping idiom already used for spellcheck results in spellcheck-plugin.ts's
 * reconcileResultsAfterEdit/mapResultPositions.
 *
 * Bias: start maps with side -1 (sticks to content before it — doesn't absorb text
 * inserted exactly at start), end maps with side 1 (sticks to content after it — DOES
 * absorb text inserted exactly at end, so text typed inside the pending /cite range
 * extends what gets replaced). Same bias Milkdown's plugin uses.
 */

import { ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { getPendingCAYWRequests } from './editor-state';

export const caywRemapPlugin = ViewPlugin.fromClass(
  class {
    update(update: ViewUpdate) {
      if (!update.docChanged) return;
      const pending = getPendingCAYWRequests();
      if (pending.size === 0) return;
      for (const [id, range] of pending) {
        pending.set(id, {
          start: update.changes.mapPos(range.start, -1),
          end: update.changes.mapPos(range.end, 1),
        });
      }
    }
  }
);
