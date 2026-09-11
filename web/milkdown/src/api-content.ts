// Content-related API method implementations for window.FinalFinal

import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { closeHistory, history as pmHistory } from '@milkdown/kit/prose/history';
import type { NodeType, Node as ProsemirrorNode, ResolvedPos } from '@milkdown/kit/prose/model';
import { Slice } from '@milkdown/kit/prose/model';
import { type Plugin, Selection, type Transaction } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import {
  applyPendingConfirmations,
  clearBlockIds,
  confirmBlockIds as confirmBlockIdsPlugin,
  getAllBlockIds,
  getBlockIdAtPos,
  getBlockTypeAtPos,
  resetBlockIdState,
  SYNC_DIAG_DETAIL,
  setBlockIdsForTopLevel,
  setBlockIdZoomMode,
} from './block-id-plugin';
import {
  type BlockChanges,
  type BlockSnapshot,
  destroyBlockSyncState,
  detectPausedEditsAndSnapshot,
  flushPendingBlockChanges as flushPendingBlockChangesPlugin,
  getBlockChanges as getBlockChangesPlugin,
  hasPendingChanges,
  resetAndSnapshot,
  setSyncPaused,
  snapshotBlocks,
  updateSnapshotIds,
} from './block-sync-plugin';
import { resetCAYWState } from './cayw';
import {
  clearContentPushTimer,
  getCurrentContent,
  getEditorInstance,
  getPendingBlockContent,
  setContentHasBeenSet,
  setCurrentContent,
  setIsSettingContent,
  setPendingBlockContent,
  setPendingSlashRedo,
  setPendingSlashUndo,
  setZoomFootnoteState,
} from './editor-state';
import { clearSearch } from './find-replace';
import { consumePendingDropPos, consumePendingPastePos } from './image-plugin';
import { getRecentUserEditSpan } from './recent-edit-span';
import { isSourceModeEnabled } from './source-mode-plugin';
import { syncLog } from './sync-debug';
import type { Block, ExpectedBlockMeta, ImageBlockMeta } from './types';

/**
 * Clear the ProseMirror undo/redo history stacks after a structural, DB-driven document
 * rebuild (project switch today; sidebar section delete/duplicate/undo in a later phase --
 * see the `clearHistory` option on `setContentWithBlockIds` in the sidebar-section-delete-dup
 * worktree this was ported from).
 *
 * The block-level LCS diff `setContentWithBlockIds` otherwise uses deliberately dispatches its
 * replace transaction with `addToHistory: false` -- but that only excludes THIS transaction
 * from being recorded, it does NOT clear history entries already on the stack from BEFORE the
 * push. For a plain resync (bibliography/notes regeneration, zoom) that's exactly right: the
 * whole point of the LCS diff is to leave unrelated undo history intact. But for a structural
 * rebuild like a project switch, prior undo-history entries anchored inside content that just
 * got replaced are no longer safe to leave replayable -- a user pressing Cmd-Z in the editor
 * could resurrect content from the PREVIOUS project, which the next block-sync poll could then
 * silently write back as a brand-new insert into the current one.
 *
 * Implementation -- WHY this needs two chained `reconfigure()` calls, not one: prosemirror-state's
 * `EditorState.reconfigure({ plugins })` preserves each plugin's existing state by matching
 * plugin instances to their declared field NAME (each plugin's own `PluginKey` -- prosemirror-
 * history's history plugin is keyed `"history$"`), NOT by object identity. So simply swapping in
 * a brand-new `history()` plugin instance at the same array position is not enough on its own:
 * `reconfigure()` still finds an existing field already registered under `"history$"` (carried
 * over from whichever plugin instance produced the CURRENT state) and preserves that value
 * instead of running the new plugin's own `init()` -- a naive single-step swap silently leaves
 * the OLD undo/redo stack in place, even though the plugin object itself is new.
 *
 * The fix takes it in two reconfigure() steps, chained: (1) drop the history plugin from the
 * plugin array entirely, so the intermediate state has no field under `"history$"` at all for
 * reconfigure() to preserve; (2) reconfigure AGAIN from THAT intermediate state (not from the
 * original state) with a freshly-constructed `history()` plugin re-inserted -- now there is
 * genuinely nothing to preserve, so this second reconfigure's `init()` actually runs and produces
 * a genuinely empty stack. Every OTHER plugin's state survives both steps untouched, since their
 * object identity never changes across either call (only `history$`'s slot is ever removed/
 * re-added) -- unlike a full `EditorState.create()`, which would reset every plugin's state,
 * including citation/footnote/image decorations that have nothing to do with undo history.
 *
 * Both reconfigures are folded into a SINGLE `view.updateState(...)` call on the final chained
 * result (not one `updateState()` per step): `updateState()` destroys and recreates every
 * plugin's own DOM-facing view (props, event handlers, decorations) on each call, so invoking it
 * twice would tear down and rebuild every plugin's view twice for zero benefit -- only the STATE
 * needs the two-step reconfigure, not the view.
 *
 * The fresh history plugin is reinserted at its ORIGINAL array index (not appended to the end),
 * so plugin ordering -- which can affect `handleDOMEvents`/`handleKeyDown` precedence against
 * other plugins registered nearby -- is unchanged versus before the clear.
 *
 * The existing history plugin is located via `pluginsByKey['history$']`: prosemirror-history
 * registers itself under a module-level singleton `PluginKey("history")` (this is the exact
 * mechanism `PluginKey.get()`/`undoDepth()`/`redoDepth()` use internally), so this app has
 * exactly one plugin under that key regardless of how Milkdown's `history` ctx wrapper
 * constructed it -- no assumption about array position, only about there being one plugin
 * registered under that name.
 *
 * Mount-flash fix (doc-open-blank-regression follow-up): this function itself does NOT
 * begin/end a native cloak, even though `resetForProjectSwitch()` below (its structural-
 * rebuild caller) does. The cloak lives at `resetForProjectSwitch()`'s OWN call site
 * (ContentView+ProjectLifecycle.swift's `handleProjectOpened()`) instead, because this
 * function has a SECOND caller -- `clearStructuralUndoState()` in undo-coordinator.ts --
 * that fires on ordinary undo-stack eviction during normal editing (op #51+, ring-buffer
 * capacity) and must NOT gain a new flicker. See that function's own doc comment for the
 * matching note on its side.
 */
export function clearEditorHistory(view: EditorView): void {
  const pluginsByKey = (view.state as unknown as { config: { pluginsByKey?: Record<string, Plugin> } }).config
    .pluginsByKey;
  const oldHistoryPlugin = pluginsByKey?.history$;
  if (!oldHistoryPlugin) {
    // Legitimate no-op when no history plugin is configured at all (e.g. some test harnesses)
    // -- but also the exact shape a future regression would take if another plugin ever claims
    // the "history$" key ahead of prosemirror-history's own registration (PluginKey dedupes by
    // appending a suffix, e.g. "history$1", leaving nothing under the bare "history$" name this
    // lookup depends on). Log so that silent case surfaces instead of vanishing.
    syncLog('API:clearEditorHistory', 'no-op: no plugin registered under the "history$" key');
    return;
  }
  const originalIndex = view.state.plugins.indexOf(oldHistoryPlugin);
  if (originalIndex === -1) {
    // Should be unreachable given pluginsByKey.history$ resolved above (that plugin instance
    // must be somewhere in view.state.plugins) -- log if it ever isn't, rather than silently
    // no-opping on what would be a genuinely surprising state.
    syncLog('API:clearEditorHistory', 'no-op: history plugin resolved via pluginsByKey but missing from plugins array');
    return;
  }

  // Step 1: drop the history plugin entirely -- the intermediate state has no "history$" field
  // for step 2's reconfigure to preserve.
  const withoutHistory = view.state.plugins.filter((p) => p !== oldHistoryPlugin);
  const stateWithoutHistory = view.state.reconfigure({ plugins: withoutHistory });

  // Step 2: reconfigure AGAIN from the intermediate (history-less) state, chained -- not from
  // the original -- with a brand-new history() plugin re-inserted at its original index.
  const freshHistoryPlugin = pmHistory();
  const pluginsWithFreshHistory = [...withoutHistory];
  pluginsWithFreshHistory.splice(originalIndex, 0, freshHistoryPlugin);
  const finalState = stateWithoutHistory.reconfigure({ plugins: pluginsWithFreshHistory });

  // Single updateState() call on the final chained result -- see doc comment above for why two
  // calls (one per step) would be wasteful and incorrect.
  view.updateState(finalState);
}

/**
 * Force ProseMirror to recompute block-id decorations after `currentBlockIds` has been
 * mutated OUTSIDE the transaction cycle. `data-block-id` is a `Decoration.node` built in
 * block-id-plugin's `decorations(state)` prop (except figure/image nodes, which emit this
 * attribute from a node attribute in image-plugin.ts's `toDOM`, not from this decoration -- a
 * decoration at the same offset wins in the DOM when one exists, but this fix does not correct
 * a stale figure attribute where no decoration covers it; tracked separately, out of scope
 * here), and ProseMirror only re-runs that prop when a transaction reaches the view -- so
 * without this, the Map holds the real DB ids while the DOM keeps rendering whatever the
 * previous dispatch painted, usually stale temp- ids (t-623b1713). DOM consumers that read
 * `el.getAttribute('data-block-id')` then see the stale value.
 *
 * Safe, and specifically safe against re-minting temps: blockIdPlugin's `apply` early-returns
 * its existing value on `!tr.docChanged` (block-id-plugin.ts:957-959), so `assignBlockIds` does
 * NOT re-run; that returned value's `blockIds` is the SAME Map object as the module-level
 * `currentBlockIds` (every reassignment at :952/:973 is immediately re-aliased into the
 * returned state, and all between-transaction writes are in-place `.clear()`/`.set()`), so the
 * untouched plugin value already reflects the corrected ids. blockSyncPlugin's `apply` likewise
 * early-returns on `!tr.docChanged || syncPaused`, so change detection sees nothing.
 *
 * Note: this dispatch is NOT fully inert -- main.ts's `view.dispatch` wrapper restarts a 150ms
 * sectionChanged-notification debounce on ANY transaction not wrapped in `getIsSettingContent()`
 * (that wrapper's own comment: "Check for section change on ANY transaction"), which the
 * `confirmBlockIdsApi` and `syncBlockIds` call sites below are not (the `setContentWithBlockIds`
 * call sites ARE inside a `getIsSettingContent()`-guarded region, so they don't reach it). This
 * is an accepted trade-off (<=150ms delay to that notification, no data loss) -- do not read
 * the plugin-level `docChanged` gates above as proof this dispatch has zero observers.
 *
 * Bare `view.state.tr` with no meta, mirroring setAnnotationDisplayModes and the three other
 * redecoration dispatches in api-annotations.ts (lines 33, 119, 184, 208) -- the established
 * precedent for this exact technique. `addToHistory` is deliberately NOT set: prosemirror-history
 * only consults it inside its `docChanged` branch, so on a stepless transaction the meta is inert,
 * and adding it would imply to a reader that it is load-bearing here.
 */
function redecorateBlockIds(view: EditorView): void {
  try {
    view.dispatch(view.state.tr);
  } catch (e) {
    console.error('[Milkdown] redecorateBlockIds dispatch failed:', e);
  }
}

/**
 * Correct a stale `blockId` NODE ATTR on top-level figure nodes so it matches
 * block-id-plugin's authoritative position map (`currentBlockIds`, read here via
 * `getBlockIdAtPos`).
 *
 * Why this exists: `FigureNodeView.resolveBlockId()` (image-plugin.ts) now prefers a
 * real (non-temp) map id over the node attr — see that function's doc comment — but the
 * two content-push call sites here (`applyBlocks`, `setContentWithBlockIds`) still write
 * Swift-supplied ids straight onto figure attrs via their own imageMeta/figureBlocks loop,
 * ahead of the map catching up. This corrects the attr to match the map right after that
 * loop, so the DOM (`data-block-id`) and the attr stay consistent with what
 * `resolveBlockId()` will actually resolve to.
 *
 * Walks the doc at TOP LEVEL ONLY (`doc.forEach`), matching how `currentBlockIds` and
 * `assignBlockIds`/`setBlockIdsForTopLevel` are keyed (by top-level offset) — deliberately NOT
 * `doc.descendants()`, which would also visit a figure nested inside a blockquote or list item.
 * Those have no entry in the top-level map at all (`getBlockIdAtPos` returns undefined for
 * them regardless of their real nested identity), so touching them here would be operating on
 * data this map was never designed to describe.
 *
 * Only called from the two content-push sites (`applyBlocks`, `setContentWithBlockIds`),
 * both already inside a `setIsSettingContent`/`setSyncPaused` window, after their own
 * imageMeta/figureBlocks loop, before `pausedPushBaseline` is captured. NOT called from the
 * two poll-driven sites (`confirmBlockIdsApi`, `syncBlockIds`) — dispatching a doc-mutating
 * correction from those outside the settle/pause machinery caused a caption-clobber race, a
 * spurious content push, and DELETE+INSERT churn (round 1). This function never clears an
 * attr — absence of a map entry isn't evidence of staleness, just "not decided yet here".
 *
 * Type-gated FIRST: if the map's type record at this offset disagrees with 'figure', skip
 * entirely — same cross-type-theft class `assignBlockIds` itself guards against. Both call
 * sites here run `clearBlockIds()` immediately before this function, so within a single call
 * the map can't actually hold a stale type at a live offset — this isn't guarding against a
 * live mechanism for this function specifically. It is kept anyway because the underlying
 * hazard the gate exists for is real elsewhere: `resolveBlockId()` (image-plugin.ts) compares
 * this same offset-keyed map against a NodeView's `getPos()`, which can be captured once and
 * held across a doc-changing edit (see its 3-second retry timers) — by the time it is read
 * again, the map has moved on and the offset may now belong to a different block. The type
 * gate is what stops that stale pairing from donating an unrelated block's id.
 *
 * Dispatches nothing when no figure actually needs correcting — the common case — which also
 * means a no-op pass never touches undo history and never gives block-sync's change-detection
 * anything to see. That last point holds even when a real correction DOES dispatch: `blockId`
 * is not part of `toMarkdown` (see the `figureNode` schema in image-plugin.ts), so block-sync's
 * markdown/text-based diff can never observe a pure blockId-attr change as an update or insert.
 */
function syncFigureBlockIdAttrs(view: EditorView): void {
  const { doc } = view.state;
  let tr: Transaction | null = null;
  doc.forEach((node, pos) => {
    if (node.type.name !== 'figure') return;
    if (getBlockTypeAtPos(pos) !== 'figure') return; // map disagrees on type — don't touch
    const mapId = getBlockIdAtPos(pos) ?? '';
    if (mapId === '') return; // no correction — absence isn't staleness
    const attrId = node.attrs.blockId || '';
    if (mapId === attrId) return; // already in sync — nothing to correct
    // A not-yet-confirmed temp id must never be stamped into the attr, even when the
    // attr is currently empty -- matches resolveBlockId's own ranking, which never
    // trusts a temp map id either.
    if (mapId.startsWith('temp-')) return;
    tr = (tr ?? view.state.tr).setNodeMarkup(pos, undefined, { ...node.attrs, blockId: mapId });
  });
  if (!tr) return;
  view.dispatch((tr as Transaction).setMeta('addToHistory', false));
}

/**
 * Double-RAF + micro-scroll force-repaint, THEN signal Swift via the `paintComplete`
 * postMessage channel once that repaint has actually happened. WKWebView's compositor can
 * keep showing the previous frame after a large ProseMirror document replace even though
 * the DOM/JS state is already correct -- confirmed live (doc-open-blank-regression,
 * 2026-08-28) -- so the RAF pair plus a throwaway scroll forces a real compositor refresh
 * before Swift is told painting is done.
 *
 * Extracted so the double-RAF + micro-scroll + `paintComplete`-post sequence exists in
 * exactly one place instead of being hand-copied repeatedly: `setContent()`'s zoom branch
 * below used to inline this directly, `resetForProjectSwitch()` needed the identical
 * sequence for the first-open/project-switch mount flash fix, and `setContentWithBlockIds()`
 * (zoom entry/exit, via BlockSyncService on the Swift side) now uses it too -- that function
 * used to call a signal-less variant of this same repaint dance, which meant nothing ever
 * told Swift's `waitForContentAcknowledgement()` (EditorViewState+Zoom.swift) that the
 * redraw was actually done: every zoom in/out sat out that function's full 1s timeout
 * fallback before continuing (e.g. before `scrollToSection` could fire on zoom-out), even
 * though the visible repaint itself finished within a couple of frames.
 *
 * `extra` is merged into the postMessage body. `setContentWithBlockIds()`'s zoom paths (via
 * BlockSyncService on the Swift side) and CodeMirror's own separate implementation pass
 * nothing (`{}`) -- their body stays exactly `{scrollHeight, timestamp}` with no `reason` or
 * `token` key, and Swift's `resolveCloakToken` (MilkdownCoordinator+MessageHandlers.swift)
 * correctly resolves that to `nil`: these are ordinary paints with no cloak of their own to
 * release. `setContent()`'s own zoom branch is the one caller in THIS file that DOES pass a
 * payload -- `{ reason: 'zoom', token }` (paintcomplete-zoom-reason), echoing back the exact
 * token its own `beginCloak(.zoom)` call minted -- the same explicit-token pattern
 * `resetForProjectSwitch()` uses below for `{ reason: 'projectReset', token }`.
 *
 * Scroll-to-top-on-citation-insert regression (2026-09-04): the micro-scroll nudge below
 * used to be unconditional (`scrollTo(top:1)` -> `scrollTo(top:0)` -> `dom.scrollTop = 0`).
 * `setContentWithBlockIds()` calls this on EVERY push, including the `scrollToStart: false`
 * bibliography resync that lands ~1s after a citation is inserted -- so a citation inserted
 * partway down a long document jumped the view to the top two frames later. Two rules fix
 * this without losing the repaint:
 *
 * 1. CAPTURE BEFORE DISPATCH. The caller must capture the reader's scroll position BEFORE
 *    the document-replacing transaction is dispatched, and pass it in as `options.restoreScroll`.
 *    Capturing early is correct regardless of whether the document ends up shorter or longer
 *    -- nothing else can have intervened between capture and dispatch. (It happens to make no
 *    practical difference in the shortening case specifically: re-reading `window.scrollY`
 *    inside this function's rAF two frames later would see the browser's already-clamped
 *    value, and restoring the earlier-captured `anchor.y` is clamped by the browser to that
 *    SAME value -- the two are equivalent there, not "wrong vs. right" the way they are for
 *    every OTHER source of drift between capture time and paint time.)
 * 2. NUDGE AWAY FROM THE CLAMP, THEN VERIFY IT ACTUALLY MOVED. At the bottom of a document the
 *    browser clamps scrollTo, so a naive "+1 then back" nudge at the end of the document
 *    produces no scroll event and no compositor refresh -- reintroducing the exact
 *    stale/blank-frame bug this function exists to fix. Nudging toward `y - 1` (when `y > 0`)
 *    instead of `y + 1` is the right GUESS for the common case, but it is only a guess: if the
 *    document shrank below `anchor.y` (a bibliography regeneration shortened it) or `anchor.y`
 *    was already 0 in a document with no scrollable range, `y - 1` clamps to the exact same
 *    position the browser is already sitting at, and the guessed direction produces no scroll
 *    event either -- the direction choice ALONE does not guarantee anything. What guarantees a
 *    real scroll event is reading `window.scrollY` back after the first attempt and, if it
 *    didn't move, retrying away from that OBSERVED position (not the possibly-stale anchor)
 *    before the final restore -- see the retry below.
 *
 * `options.restoreScroll` absent means this function always resets to the top -- but that is
 * NOT the same thing as "every zoom/reset caller wants the top". The gate callers actually pull
 * on is `scrollToStart` (on `setContentWithBlockIds`/`setContent`): passing it true makes the
 * CALLER omit `restoreScroll` here (so the top-reset below runs); omitting it makes the caller
 * capture-and-restore instead. Of the 9 Swift call sites of `setContentWithBlockIds`, only ONE
 * passes `scrollToStart: true` -- zoom-in (`EditorViewState+Zoom.swift:190`). Every other caller
 * now gets scroll-preservation instead of a top-reset: the bibliography resync that originally
 * surfaced this bug, the footnote-section-changed and footnote-inserted resyncs
 * (`ContentView+NotificationHandlers.swift:90`, `:254`, `:419`), the two content-rebuild paths
 * (`ContentView+ContentRebuilding.swift:108`, `:572`), structural undo/redo
 * (`StructuralUndoController.swift:470`), project switch
 * (`ContentView+ProjectLifecycle.swift:544`), and zoom-out (`EditorViewState+Zoom.swift:320`).
 * That is broader than the original bibliography-resync report, and deliberately so -- it is not
 * a scope expansion each site needs separately justified. Several of these (footnote insertion
 * and structural undo/redo especially) were quietly suffering the exact same undiagnosed
 * "jump to top" defect before this fix; jumping to the top on an undo, for instance, would
 * itself be a bug. Fixing the shared mechanism here fixed all of them at once, and preservation
 * is the desirable behavior at every one of these call sites, not only the two walked through
 * below.
 *
 * Two of these are worth walking through in detail because their safety isn't obvious from
 * "preservation is generally desirable" alone -- project switch
 * (`ContentView+ProjectLifecycle.swift`'s `handleProjectOpened()`, whose `setContentWithBlockIds`
 * push at line ~544 follows an earlier one) and zoom-out
 * (`ContentView+NotificationHandlers.swift`'s `performUserZoomOut()`, whose awaited
 * `EditorViewState.zoomOut()` pushes via `EditorViewState+Zoom.swift:314`). Project switch is
 * safe because `resetForProjectSwitch()` (this file, below) already did its own unconditional
 * `window.scrollTo(0, 0)` before that later push, so the position it captures and "restores" is
 * already 0. Zoom-out is safe for a DIFFERENT reason, since 2026-09-04: its caller passes
 * `scrollToBlockId` (the section the user zoomed out of) into `setContentWithBlockIds`, which
 * resolves that block's position in the JUST-RESTORED, un-zoomed document -- via the same
 * `blockScrollTargetTop` helper `scrollToBlock` uses -- scrolls there itself, and re-captures
 * `restoreScroll` from that resolved position before calling this function. What this function
 * receives as `restoreScroll` is therefore already the correct landing spot, not the captured
 * position of the (differently-scrolled) zoomed view being replaced -- the old coordinate-space
 * mismatch that caused a visible flash to the document's actual top. `performUserZoomOut()`'s
 * own follow-up `scrollToSection(savedSectionId)` call is kept, but only for the CodeMirror
 * (Source) path this JS fix doesn't reach; in WYSIWYG it recomputes the identical target via the
 * same helper and lands on a position already reached, so it produces no visible movement. This
 * function's actual unconditional-top callers are the ones below that call it with no
 * `options` argument at all: `setContent()`'s own `scrollToStart` branch,
 * `resetForProjectSwitch()`, `signalMountPaintComplete()`, and `setContentWithBlockIds()`'s
 * empty-document branch (see that branch's own comment, below).
 */
export function signalPaintComplete(
  dom: HTMLElement,
  extra: Record<string, unknown> = {},
  options: { restoreScroll?: { x: number; y: number; domTop: number } } = {}
): void {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      // CRITICAL: Force compositor refresh with micro-scroll
      // WKWebView's compositor caches the previous content.
      // A scroll triggers compositor refresh, showing the new content.
      const anchor = options.restoreScroll;
      if (anchor) {
        // Nudge AWAY from the end the browser clamps at, then back. Direction matters: at
        // the bottom of the document, scrollTo(y + 1) clamps to y, so a "+1 then back" nudge
        // fires no scroll event and the compositor is never refreshed -- reintroducing the
        // stale/blank frame d9fa212e exists to fix, on exactly the likely case (reader
        // scrolled down, watching the bibliography regenerate). Going to y - 1 is the right
        // guess when y > 0, but it's only a guess -- see the readback-and-retry below for the
        // case where that guess is ALSO clamped -- doc shrank below the anchor, or the
        // anchor was already 0 in a non-scrolling doc.
        const nudgeY = anchor.y > 0 ? anchor.y - 1 : anchor.y + 1;
        const nudgeDomTop = anchor.domTop > 0 ? anchor.domTop - 1 : anchor.domTop + 1;
        // `left: anchor.x` preserves horizontal scroll, where this used to always reset to
        // `left: 0`. Almost certainly harmless -- the window rarely scrolls horizontally --
        // but worth naming as an intentional behavior change.
        const beforeNudgeY = window.scrollY;
        window.scrollTo({ top: nudgeY, left: anchor.x, behavior: 'instant' });
        // Read back window.scrollY (this also forces the pending layout/reflow). If the guessed
        // direction above was clamped right back to where we started, it produced no scroll
        // event at all -- retry away from the OBSERVED position instead of the (possibly now
        // out-of-range) anchor, so a real scroll event fires before the final restore below.
        // This is what makes a real scroll event likely in the common case, not a guarantee of
        // one: when the anchor's y is already 0 in a document with no scrollable range at all,
        // there is nothing to nudge into and no code here can force a scroll event to fire (see
        // the doc comment above).
        if (window.scrollY === beforeNudgeY) {
          const altNudgeY = beforeNudgeY > 0 ? beforeNudgeY - 1 : beforeNudgeY + 1;
          window.scrollTo({ top: Math.max(0, altNudgeY), left: anchor.x, behavior: 'instant' });
        }
        window.scrollTo({ top: anchor.y, left: anchor.x, behavior: 'instant' });
        // dom.scrollTop nudging, kept for symmetry/defensiveness with the window-level nudge
        // above -- but inert under the current CSS: no `overflow` is set on
        // `.ProseMirror`/`#editor` in styles.css, so `view.dom` is never the actual scroll
        // container, and both the read and the writes below are no-ops that each force a
        // synchronous layout for nothing. Left in case that CSS ever changes.
        dom.scrollTop = nudgeDomTop;
        dom.scrollTop = anchor.domTop;
      } else {
        window.scrollTo({ top: 1, left: 0, behavior: 'instant' });
        window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
        dom.scrollTop = 0;
      }

      if (typeof (window as any).webkit?.messageHandlers?.paintComplete?.postMessage === 'function') {
        (window as any).webkit.messageHandlers.paintComplete.postMessage({
          scrollHeight: dom.scrollHeight,
          timestamp: Date.now(),
          ...extra,
        });
      }
    });
  });
}

/**
 * Direct (no RAF, no scroll) `paintComplete` post -- for failure paths where there may be no
 * live `view.dom` to reliably force-repaint at all (must-fix #4, review round 2). Used by
 * `resetForProjectSwitch()`'s own failure paths below, and by `main.ts`'s `initEditor()`
 * catch block for the equivalent mount-failure case -- a failed mount/reset must not leave
 * Swift's cloak waiting out its full ~2.5s fallback when there's nothing to actually repaint.
 */
export function signalPaintCompleteDirect(extra: Record<string, unknown> = {}): void {
  if (typeof (window as any).webkit?.messageHandlers?.paintComplete?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.paintComplete.postMessage({ timestamp: Date.now(), ...extra });
  }
}

/**
 * On-demand mount-paint signal for Swift's claimed-preloaded-WebView path (mount-flash fix,
 * redesign after review round) -- see `pollMountCloakReleaseForClaimedView`'s doc comment
 * (MilkdownCoordinator+MessageHandlers.swift) for why `initEditor()`'s own one-shot post
 * (main.ts) cannot be relied on for a view that was preloaded rather than freshly created:
 * that post may already have fired (or silently no-opped -- no `paintComplete` handler
 * registered yet during preload) well before any Swift-side cloak or handler existed. Swift
 * calls this explicitly, exactly once, only after confirming `isEditorReady()` itself, so
 * `getEditorInstance()` below is expected to be non-null; the guard is defensive only.
 */
export function signalMountPaintComplete(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  signalPaintComplete(view.dom, { reason: 'mount' });
}

/** Re-snapshot in the next animation frame, then unpause sync.
 *  Ensures normalization transactions are absorbed before change detection resumes.
 *  When `detectPausedEdits` is true, edits made while sync was paused are queued
 *  as pending changes instead of being silently discarded, by diffing `baseline`
 *  (a snapshot the caller captured at the moment its own paused push settled —
 *  NOT the ambient last-known state, which may reflect an unrelated prior reset)
 *  against the document as it stands once the pause ends. See
 *  detectPausedEditsAndSnapshot() for the full reasoning and safety constraints. */
function deferredSnapshotAndUnpause(detectPausedEdits = false, baseline?: Map<string, BlockSnapshot>): void {
  requestAnimationFrame(() => {
    const inst = getEditorInstance();
    if (inst) {
      const v = inst.ctx.get(editorViewCtx);
      if (detectPausedEdits && baseline) {
        detectPausedEditsAndSnapshot(v.state.doc, baseline);
      } else {
        resetAndSnapshot(v.state.doc);
      }
    }
    setSyncPaused(false);
  });
}

export function setContent(markdown: string, options?: { scrollToStart?: boolean; cloakToken?: number }): void {
  syncLog('API:setContent', `entry len=${markdown.length} scrollToStart=${options?.scrollToStart ?? false}`);

  // paintcomplete-zoom-reason: merged into whichever exit below actually fires, mirroring
  // resetForProjectSwitch()'s `resetExtra` pattern (below) -- pre-mount stash, empty-content
  // normalization, no-op (content unchanged), or the real scrollToStart repaint all count as
  // "the paint this call was responsible for" from Swift's side, once a token is present.
  // `cloakToken` is only ever set by Swift's own `setContent()` zoom branch
  // (MilkdownCoordinator+Content.swift), which mints it via `beginCloak(.zoom)` exactly when
  // it also passes `scrollToStart: true` -- so a caller with no `cloakToken` (every other
  // caller of this function) sees no behavior change at all: no paint is posted from the
  // early-return paths below, exactly as before this fix.
  const zoomExtra = options?.cloakToken != null ? { reason: 'zoom', token: options.cloakToken } : undefined;

  // NOTE: Do NOT clear zoom mode here. setContent() is called from updateNSView
  // during zoom, and clearing zoom mode causes temp IDs to be generated for mini-Notes
  // nodes before pushBlockIds re-enables it. Zoom mode is independently managed by:
  // - setContentWithBlockIds() for full document loads
  // - resetForProjectSwitch() for project switches
  // - syncBlockIds() with explicit zoomMode parameter
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    // MF3: whichever pre-mount stash was written LAST must win once main.ts's post-mount
    // replay runs -- that replay unconditionally prefers pendingBlockContent when non-null,
    // so a plain setContent() call that arrives AFTER an earlier setContentWithBlockIds()
    // stash must clear it here, or the older, block-ID-bearing content would win instead of
    // this newer plain push (replayPendingPreMountContent below).
    setPendingBlockContent(null);
    setCurrentContent(markdown);
    // A zoom into a not-yet-mounted editor has no `view.dom` to repaint at all -- release
    // Swift's cloak directly (no RAF/scroll dance) rather than leaving it to the 2.5s
    // fallback. See signalPaintCompleteDirect's doc comment.
    if (zoomExtra) signalPaintCompleteDirect(zoomExtra);
    return;
  }

  setContentHasBeenSet(true);
  clearContentPushTimer(); // Cancel stale timers — both empty-content and normal paths replace doc

  // Handle empty content FIRST - ensure doc has valid empty paragraph, not section_break
  // This must run BEFORE the currentContent === markdown check because:
  // - Editor may initialize with section_break due to schema default
  // - currentContent starts as '' so the equality check would skip the fix
  if (!markdown.trim()) {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const doc = view.state.doc;

      // Check if already a valid empty paragraph (optimization: skip if already correct)
      if (doc.childCount === 1 && doc.firstChild?.type.name === 'paragraph' && doc.firstChild?.textContent === '') {
        setCurrentContent(markdown);
        // No transaction was dispatched -- nothing to repaint, same as the "unchanged
        // content" no-op branch below. Direct post (paintcomplete-zoom-reason).
        if (zoomExtra) signalPaintCompleteDirect(zoomExtra);
        return;
      }

      // Replace with empty paragraph
      setSyncPaused(true);
      setIsSettingContent(true);
      try {
        const emptyParagraph = view.state.schema.nodes.paragraph.create();
        const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
        const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, emptyDoc.content);
        view.dispatch(tr.setMeta('addToHistory', false).setSelection(Selection.atStart(tr.doc)));
        setCurrentContent(markdown);
      } finally {
        setIsSettingContent(false);
        deferredSnapshotAndUnpause();
      }
      // A zoom into an empty section DID dispatch a real document-replacing transaction
      // above (must-fix #2, review round 3) -- use the RAF'd signalPaintComplete, the same
      // way resetForProjectSwitch()'s success path does for its own empty-doc replace, so
      // the compositor genuinely settles before Swift is told to reveal. `view.dom` is live
      // here (bound at the top of this action) -- unlike the genuine failure paths
      // elsewhere in this function (pre-mount stash, parser error/null below), which have
      // no live document change to repaint and correctly use signalPaintCompleteDirect
      // instead.
      if (zoomExtra) signalPaintComplete(view.dom, zoomExtra);
    });
    return;
  }

  // For non-empty content, skip if unchanged
  if (getCurrentContent() === markdown) {
    // A no-op zoom (already showing this section's content) never reaches the scrollToStart
    // repaint below -- must still release Swift's cloak (paintcomplete-zoom-reason).
    if (zoomExtra) signalPaintCompleteDirect(zoomExtra);
    return;
  }

  setSyncPaused(true);
  setIsSettingContent(true);
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);

      const parser = ctx.get(parserCtx);
      let doc;
      try {
        doc = parser(markdown);
      } catch (e) {
        console.error('[Milkdown] Parser error:', e instanceof Error ? e.message : e);
        console.error('[Milkdown] Stack:', e instanceof Error ? e.stack : 'N/A');
        // A failed parse has no new document to repaint -- release Swift's cloak directly
        // rather than leaving it to sit out the full 2.5s fallback (must-fix #1,
        // paintcomplete-zoom-reason review round 3).
        if (zoomExtra) signalPaintCompleteDirect(zoomExtra);
        return;
      }
      if (!doc) {
        console.error('[Milkdown] Parser returned null/undefined doc');
        // Same reasoning as the parser-error catch just above -- no document to repaint.
        if (zoomExtra) signalPaintCompleteDirect(zoomExtra);
        return;
      }

      // Preserve figure attributes not encoded in markdown (width, blockId)
      // Markdown ![alt](src) does NOT encode width or blockId — re-parsing loses them.
      // Use positional matching with src verification (consistent with applyBlocks/setContentWithBlockIds pattern)
      const savedFigures: Array<{ src: string; width: number | null; blockId: string }> = [];
      view.state.doc.forEach((node) => {
        if (node.type.name === 'figure') {
          savedFigures.push({
            src: node.attrs.src || '',
            width: node.attrs.width,
            blockId: node.attrs.blockId || '',
          });
        }
      });

      if (savedFigures.length > 0) {
        syncLog(
          'API:setContent',
          `figures before replace: ${savedFigures.map((f) => `src=${f.src.split('/').pop()} w=${f.width}`).join(', ')}`
        );
      }

      const { from } = view.state.selection;
      const docSize = view.state.doc.content.size;
      let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

      // For zoom transitions, set selection to start; otherwise try to preserve position
      if (options?.scrollToStart) {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      } else {
        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
      }
      view.dispatch(tr.setMeta('addToHistory', false));

      // Restore figure attributes by position with src verification
      // (Matches applyBlocks/setContentWithBlockIds pattern — BEFORE resetAndSnapshot)
      if (savedFigures.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        let restoredCount = 0;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < savedFigures.length) {
            const saved = savedFigures[figureIdx];
            // Only restore if src matches (same image at same position)
            if (node.attrs.src === saved.src) {
              const updates: Record<string, any> = { ...node.attrs };
              if (saved.width != null) updates.width = saved.width;
              if (saved.blockId) updates.blockId = saved.blockId;
              if (updates.width !== node.attrs.width || updates.blockId !== node.attrs.blockId) {
                metaTr = metaTr.setNodeMarkup(pos, undefined, updates);
                restoredCount++;
              }
            }
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
        syncLog('API:setContent', `figures after restore: ${restoredCount}/${savedFigures.length}`);
      }

      // Reset scroll position for zoom transitions
      // Swift handles hiding/showing the WKWebView at compositor level
      if (options?.scrollToStart) {
        // Reset scroll immediately
        view.dom.scrollTop = 0;
        window.scrollTo({ top: 0, left: 0, behavior: 'instant' });

        // Force layout calculation
        void view.dom.offsetHeight;
        void document.body.offsetHeight;

        // Wait for actual paint to complete using double RAF, then signal Swift -- see
        // signalPaintComplete's doc comment for the shared double-RAF + micro-scroll +
        // paintComplete-post sequence (also used by resetForProjectSwitch() and
        // initEditor()'s post-mount settle, main.ts). `zoomExtra` (paintcomplete-zoom-reason)
        // echoes Swift's own `.zoom` cloak token back so `resolveCloakToken`
        // (MilkdownCoordinator+MessageHandlers.swift) releases exactly the cloak THIS call
        // began, not whatever `.zoom` cloak happens to be outstanding; absent when Swift
        // passed no `cloakToken`, preserving today's reason-less `{}` body unchanged.
        signalPaintComplete(view.dom, zoomExtra ?? {});
      }
    });
    setCurrentContent(markdown);
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause();
  }
}

export function getContent(): string {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return getCurrentContent();

  const sourceEnabled = isSourceModeEnabled();
  const rawMarkdown = getMarkdown()(editorInstance.ctx);
  let markdown = rawMarkdown;

  // Unescape heading syntax that ProseMirror's serializer escapes in paragraphs.
  const beforeHeadingUnescape = markdown;
  markdown = markdown.replace(/^\\(#{1,6}\s)/gm, '$1');
  if (markdown !== beforeHeadingUnescape) {
    syncLog('API:getContent', 'heading unescape applied');
  }

  // Unescape footnote definition brackets escaped by ProseMirror's serializer.
  const beforeFootnoteUnescape = markdown;
  markdown = markdown.replace(/^\\(\[\^\d+\]:)/gm, '$1');
  if (markdown !== beforeFootnoteUnescape) {
    syncLog('API:getContent', 'footnote unescape applied');
  }

  // Unescape backticks that ProseMirror's serializer escapes in text nodes.
  // Safe: ProseMirror does not escape inside code_block nodes, only inline text.
  // Global regex (not line-anchored) is correct because escaped backticks only appear in inline text.
  if (!sourceEnabled) {
    const beforeBacktickUnescape = markdown;
    markdown = markdown.replace(/\\`/g, '`');
    if (markdown !== beforeBacktickUnescape) {
      syncLog('API:getContent', 'backtick unescape applied');
    }
  }

  // Fix double ## prefixes in source mode: "## ## Heading" → "## Heading"
  if (sourceEnabled) {
    const beforeDoubleFix = markdown;
    markdown = markdown.replace(/^(#{1,6}) \1 /gm, '$1 ');
    if (markdown !== beforeDoubleFix) {
      syncLog('API:getContent', 'double-## prefix fix applied');
    }
  }

  const trimmed = markdown.trim();

  // Empty/minimal document may serialize to just a section break marker - treat as empty
  if (trimmed === '' || trimmed === '<!-- ::break:: -->') {
    return '';
  }

  setCurrentContent(markdown);
  return markdown;
}

export function resetEditorState(): void {
  resetForProjectSwitch();
}

/**
 * @param cloakToken Optional cloak token minted by Swift's `beginCloak(.projectReset)`
 *   (MilkdownCoordinator+MessageHandlers.swift), echoed back verbatim in this call's
 *   `paintComplete` post so Swift can resolve the release to the EXACT cloak this call is
 *   settling -- not just "the .projectReset reason" (which would be ambiguous if a second
 *   project switch/open starts before the first one's mount flash has finished cloaking,
 *   e.g. rapid A→B→A switching). Absent for `resetEditorState()`'s project-CLOSE caller
 *   below, which has no Swift-side cloak to release.
 */
export function resetForProjectSwitch(cloakToken?: number): void {
  clearContentPushTimer(); // Defense in depth — prevent stale timer from old project
  const editorInstance = getEditorInstance();

  // Reset block-related state
  resetBlockIdState();
  destroyBlockSyncState();
  setCurrentContent('');
  // MF2: a pre-mount pendingBlockContent stash left over from the PREVIOUS project must not
  // survive into this one -- otherwise the editor mounting later (or a delayed replay) would
  // resurrect the previous project's content instead of the one now being switched to.
  setPendingBlockContent(null);
  setContentHasBeenSet(false);
  setIsSettingContent(false);
  setPendingSlashUndo(false);
  setPendingSlashRedo(false);
  setZoomFootnoteState(false, 0);
  // Clear search state
  clearSearch();

  // Clear CAYW and citation state
  resetCAYWState();

  // Merged into whichever paintComplete post actually fires below -- success (RAF'd, via
  // signalPaintComplete) or either failure path (direct, via signalPaintCompleteDirect).
  const resetExtra = cloakToken != null ? { reason: 'projectReset', token: cloakToken } : { reason: 'projectReset' };

  // Clear document via normal transaction (preserves ProseMirror's internal layout caches,
  // unlike updateState() which destroys them and causes rendering issues on project switch)
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);

      // Clear the undo/redo history stacks FIRST, before the doc-clearing transaction below.
      // clearEditorHistory() ends in view.updateState(finalState) -- since the plugin array
      // changes, this unconditionally destroys and recreates every plugin's DOM-facing view,
      // but prosemirror-view's updateState() internally still branches on
      // `prevState.doc.eq(state.doc)` for whether to also run the expensive updateDoc path
      // (the one the comment just above this block warns "destroys [layout caches] and causes
      // rendering issues on project switch"). Calling this here, while the document is still
      // the OUTGOING project's unchanged doc, keeps that check true, so the plugin-view churn
      // happens against an unchanged document and updateDoc never runs. The actual content
      // replacement then goes through the plain transaction path below, exactly as the
      // neighboring comment demands -- calling this AFTER that transaction would instead hand
      // updateState() a just-changed doc and hit the destructive branch it's there to avoid.
      clearEditorHistory(view);

      const emptyParagraph = view.state.schema.nodes.paragraph.create();
      const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
      // NOTE: `tr` must be reused (not re-derived via a second `view.state.tr` access) when
      // building the post-replace selection below -- `.tr` is a getter that mints a fresh
      // Transaction from `view.state` every time it's read, so a second `view.state.tr.doc`
      // here would point at the PRE-replace document while `tr` itself has already moved past
      // it, and ProseMirror's setSelection() rejects a selection anchored to the wrong doc
      // (pre-existing bug, fixed in passing: this always threw and was silently swallowed by
      // the catch below, so this whole block -- including the history clear added alongside
      // it -- never actually ran on any real project switch).
      const tr = view.state.tr.replace(0, view.state.doc.content.size, new Slice(emptyDoc.content, 0, 0));
      tr.setSelection(Selection.atStart(tr.doc));
      tr.setMeta('addToHistory', false);
      view.dispatch(tr);
      view.dom.scrollTop = 0;

      // Mount-flash fix (doc-open-blank-regression follow-up): force a real WKWebView
      // repaint and tell Swift once it's happened, so `beginCloak(.projectReset)`'s
      // native cloak (webView.alphaValue = 0, armed before this call) can release --
      // see signalPaintComplete's doc comment. Reason key always present so Swift's
      // reason-fallback resolution works even if `cloakToken` wasn't threaded through
      // (e.g. `resetEditorState()`'s project-CLOSE caller below).
      signalPaintComplete(view.dom, resetExtra);
    } catch (e) {
      // State reset failed -- log it (this exact silent swallow is why the pre-existing
      // selection bug above went unnoticed for as long as it did; don't repeat that).
      syncLog('API:resetForProjectSwitch', `state reset failed: ${e instanceof Error ? e.message : e}`);
      // Must-fix #4 (review round 2): post directly (no RAF/scroll -- there's no reliable
      // live `view.dom` to force-repaint here; the throw may have happened before `view` was
      // even bound), mirroring main.ts's initEditor() catch block. Without this, a failed
      // reset left the cloak waiting out its full ~2.5s fallback for no reason -- there was
      // never going to be a real repaint to wait for on this path.
      signalPaintCompleteDirect(resetExtra);
    }
  } else {
    // Must-fix #4 (review round 2): no editor instance at all (reset arriving before mount,
    // or after teardown) -- same direct-post treatment as the catch block above: there is no
    // `view.dom` on this path either, ever, so there's nothing to wait for a real repaint on.
    signalPaintCompleteDirect(resetExtra);
  }

  // Reset scroll position to top (prevents previous project's scroll persisting)
  window.scrollTo(0, 0);
  document.documentElement.scrollTop = 0;
  document.body.scrollTop = 0;
}

export function applyBlocks(blocks: Block[]): void {
  clearContentPushTimer(); // Cancel stale timers before document replacement
  syncLog('API:applyBlocks', `entry blocks=${blocks.length} syncPaused=true`);
  // [SYNC-DIAG Round 2] First-few (id, blockType, textLen) so we can correlate
  // Swift's block-array shape with the DOM that ends up in the editor.
  if (SYNC_DIAG_DETAIL) {
    const firstFew = blocks
      .slice(0, 5)
      .map((b) => `(${b.id.slice(0, 8)},${b.blockType},txtLen=${b.textContent?.length ?? 0})`);
    syncLog('API:applyBlocks', `firstFew=[${firstFew.join(',')}]`);
  }
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const parser = editorInstance.ctx.get(parserCtx);

    // Sort blocks by sortOrder, then filter empty fragments (stay in sync with Swift BlockParser)
    const sortedBlocks = [...blocks].sort((a, b) => a.sortOrder - b.sortOrder);
    const nonEmptyBlocks = sortedBlocks.filter((b) => b.markdownFragment.trim().length > 0);

    // Assemble markdown from non-empty blocks
    const markdown = nonEmptyBlocks.map((b) => b.markdownFragment).join('\n\n');

    // Parse and replace document content
    setSyncPaused(true);
    setIsSettingContent(true);
    try {
      const doc = parser(markdown);
      if (!doc) return;

      const { from } = view.state.selection;
      const docSize = view.state.doc.content.size;
      let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

      // Try to preserve cursor position
      const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
      try {
        tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
      } catch {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      }

      view.dispatch(tr.setMeta('addToHistory', false));
      setCurrentContent(markdown);

      // Clear stale temp IDs from assignBlockIds, set real IDs, rebuild snapshot.
      // NOTE: blockIds should already be collapsed for list merging on the Swift side
      // (consecutive same-type list blocks map to a single PM list node).
      clearBlockIds();
      const blockIds = nonEmptyBlocks.map((b) => b.id);
      // NOTE: as of this writing, no Swift call site invokes window.FinalFinal.applyBlocks
      // (verified via repo-wide grep) — likely superseded by setContentWithBlockIds. Hardened
      // here anyway for uniformity/future-proofing; zero live-path risk either way.
      const expected: ExpectedBlockMeta[] = nonEmptyBlocks.map((b) => ({
        blockType: b.blockType,
        nonEmpty: b.textContent.trim().length > 0,
      }));
      setBlockIdsForTopLevel(blockIds, view.state.doc, expected);

      // Inject image metadata (caption, width) from block data into figure nodes
      // MUST use nonEmptyBlocks to keep positional figure matching aligned
      const figureBlocks = nonEmptyBlocks.filter((b) => b.blockType === 'image');
      if (figureBlocks.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < figureBlocks.length) {
            const block = figureBlocks[figureIdx];
            metaTr = metaTr.setNodeMarkup(pos, undefined, {
              ...node.attrs,
              caption: block.imageCaption || '',
              width: block.imageWidth ?? node.attrs.width ?? null,
              blockId: block.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
      }

      // Correct any figure whose attr still disagrees with the map after the loop above —
      // e.g. a figure the loop above skipped entirely (figureIdx ran out before this offset).
      // See syncFigureBlockIdAttrs's doc comment.
      syncFigureBlockIdAttrs(view);
    } finally {
      setIsSettingContent(false);
      // Delay snapshot + unpause to RAF so normalization transactions are absorbed
      deferredSnapshotAndUnpause();
    }
  } catch (e) {
    console.error('[Milkdown] applyBlocks failed:', e);
  }
}

// ---------------------------------------------------------------------------
// Block-level LCS diff for setContentWithBlockIds
//
// setContentWithBlockIds() used to replace the ENTIRE document in a single
// tr.replace(0, docSize, ...) step every time a background resync
// (bibliography/notes/footnote regeneration, zoom in/out, project restore,
// generic block rebuild, etc.) pushed new content. Per prosemirror-history's
// position-mapping rules, one step spanning the whole document collapses
// every earlier undo-history position to the boundary of that single step —
// even for content that didn't actually change. That silently broke undo for
// anything the user did shortly before a resync fired (e.g. deleting a
// citation, then having the bibliography resync land ~1s later, before they
// pressed Cmd+Z).
//
// The fix: diff the two documents' TOP-LEVEL blocks (paragraphs, headings,
// etc. — depth-1 children of the doc root) using a standard LCS algorithm
// with Node.eq() as the equality test, then replace only the specific block
// ranges that actually differ, each via its own tr.replace() call within one
// transaction. Blocks the LCS matches as unchanged keep their original
// identity/position (shifted only by the size deltas of earlier-replaced
// ranges, via tr.mapping) — so undo-history positions pointing into them
// survive intact.
// ---------------------------------------------------------------------------

/** A single contiguous run of top-level blocks that differs between the old
 * and new document, expressed as block INDICES (not document positions) into
 * each document's top-level child array. `oldFrom`/`newFrom` are inclusive,
 * `oldTo`/`newTo` are exclusive — the same convention as Array.slice. */
export interface BlockChangeRange {
  oldFrom: number;
  oldTo: number;
  newFrom: number;
  newTo: number;
}

/** Document positions of every top-level block boundary, indexed by block
 * index: starts[i] is the position immediately before block i, and
 * starts[doc.childCount] is the position immediately after the last block
 * (== doc.content.size). Translates the block-index ranges
 * diffTopLevelBlocks() produces into document/Fragment-cut positions. */
export function topLevelBlockStarts(doc: ProsemirrorNode): number[] {
  const starts: number[] = [0];
  let pos = 0;
  doc.forEach((node) => {
    pos += node.nodeSize;
    starts.push(pos);
  });
  return starts;
}

/** Cap on DP table cells (rows * cols of the trimmed middle) above which we
 * give up on finding the minimal diff and fall back to treating the entire
 * trimmed middle as one changed range — still bounded to the region that
 * actually differs (never the whole document), just not minimal within it.
 * Sized to keep worst-case memory/time in the tens-of-MB / low-hundreds-of-ms
 * range even for unusually large documents. */
const DIFF_DP_CELL_CAP = 4_000_000;

/**
 * Diff the top-level blocks of `oldDoc` and `newDoc` and return the list of
 * disjoint block-index ranges that differ, in document order.
 *
 * Uses the standard longest-common-subsequence algorithm (Node.eq() as the
 * match predicate) over the top-level block arrays, after trimming any
 * common prefix/suffix. This is what lets two separate edits on either side
 * of an untouched block (e.g. a citation's own paragraph, unchanged by a
 * resync that touches a paragraph before it AND one after it) come back as
 * TWO disjoint ranges rather than one range spanning — and replacing —
 * everything in between; that is the whole point of this fix (see the
 * bibliography-resync regression test in __tests__/block-diff.test.ts).
 *
 * Returns an empty array when the two documents' top-level blocks are
 * entirely `.eq()`-identical (nothing to replace).
 *
 * --- Accepted residual risk: content-identical duplicate blocks ---
 * When several top-level blocks are fully `.eq()`-identical to each other
 * (e.g. multiple paragraphs that each contain only the same citation
 * `[@samekey]`, or repeated blank spacer paragraphs) AND a resync also
 * changes how many such duplicates exist nearby, the LCS has no way to know
 * — from content alone — which specific occurrence a stale undo-history
 * position was pointing at; every duplicate is an equally valid match. The
 * backtrack below resolves ties deterministically but arbitrarily with
 * respect to "which occurrence" — it may sweep a duplicate a human would
 * consider "the same one" into a replaced range instead of matching it. This
 * is inherent to any purely content-based diff (there's no identity to
 * disambiguate identical content) and isn't fixable by improving this
 * algorithm specifically. The worst case is still strictly better than the
 * pre-fix behavior: at most the ambiguous duplicate-block region's undo
 * history is affected, never the whole document's. A test pins the current
 * arbitrary-but-deterministic behavior so a future change can't silently
 * regress it into sweeping in MORE blocks than necessary.
 */
export function diffTopLevelBlocks(oldDoc: ProsemirrorNode, newDoc: ProsemirrorNode): BlockChangeRange[] {
  const oldBlocks: ProsemirrorNode[] = [];
  oldDoc.forEach((node) => {
    oldBlocks.push(node);
  });
  const newBlocks: ProsemirrorNode[] = [];
  newDoc.forEach((node) => {
    newBlocks.push(node);
  });

  // Trim common prefix.
  let prefixLen = 0;
  const maxCommon = Math.min(oldBlocks.length, newBlocks.length);
  while (prefixLen < maxCommon && oldBlocks[prefixLen].eq(newBlocks[prefixLen])) {
    prefixLen++;
  }

  // Trim common suffix, bounded so it never overlaps the already-trimmed prefix.
  let suffixLen = 0;
  const maxSuffix = maxCommon - prefixLen;
  while (
    suffixLen < maxSuffix &&
    oldBlocks[oldBlocks.length - 1 - suffixLen].eq(newBlocks[newBlocks.length - 1 - suffixLen])
  ) {
    suffixLen++;
  }

  const oldMid = oldBlocks.slice(prefixLen, oldBlocks.length - suffixLen);
  const newMid = newBlocks.slice(prefixLen, newBlocks.length - suffixLen);

  if (oldMid.length === 0 && newMid.length === 0) {
    return [];
  }

  const m = oldMid.length;
  const n = newMid.length;

  // Fallback for pathologically large middles: one range spanning the whole
  // trimmed middle (== today's whole-document behavior, but bounded to the
  // region that actually differs rather than the entire document).
  if (m * n > DIFF_DP_CELL_CAP) {
    return [
      {
        oldFrom: prefixLen,
        oldTo: oldBlocks.length - suffixLen,
        newFrom: prefixLen,
        newTo: newBlocks.length - suffixLen,
      },
    ];
  }

  // dp[i][j] = length of the LCS of oldMid[i:] and newMid[j:].
  const dp: Int32Array[] = new Array(m + 1);
  for (let i = 0; i <= m; i++) dp[i] = new Int32Array(n + 1);
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = oldMid[i].eq(newMid[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  // Backtrack to find the matched (unchanged) block index pairs, in order.
  const matches: Array<{ oldIdx: number; newIdx: number }> = [];
  {
    let i = 0;
    let j = 0;
    while (i < m && j < n) {
      if (oldMid[i].eq(newMid[j]) && dp[i][j] === dp[i + 1][j + 1] + 1) {
        matches.push({ oldIdx: i, newIdx: j });
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
  }

  // Convert the gaps between matches (plus before-the-first/after-the-last)
  // into disjoint change ranges, offsetting back into full-document block
  // indices (undoing the prefix trim).
  const ranges: BlockChangeRange[] = [];
  let prevOld = 0;
  let prevNew = 0;
  for (const match of matches) {
    if (match.oldIdx > prevOld || match.newIdx > prevNew) {
      ranges.push({
        oldFrom: prefixLen + prevOld,
        oldTo: prefixLen + match.oldIdx,
        newFrom: prefixLen + prevNew,
        newTo: prefixLen + match.newIdx,
      });
    }
    prevOld = match.oldIdx + 1;
    prevNew = match.newIdx + 1;
  }
  if (prevOld < m || prevNew < n) {
    ranges.push({
      oldFrom: prefixLen + prevOld,
      oldTo: prefixLen + m,
      newFrom: prefixLen + prevNew,
      newTo: prefixLen + n,
    });
  }

  return ranges;
}

/**
 * Apply the block-level diff between `oldDoc` and `newDoc` to `tr` (which
 * must currently be positioned at `oldDoc`), replacing only the block ranges
 * that actually differ instead of the whole document. Each range is applied
 * via its own tr.replace() call in document order; positions are mapped
 * through `tr.mapping` before each call so earlier replacements in the same
 * loop (which may have changed content length) don't throw off later ones.
 */
export function buildBlockLevelReplace(tr: Transaction, oldDoc: ProsemirrorNode, newDoc: ProsemirrorNode): Transaction {
  const ranges = diffTopLevelBlocks(oldDoc, newDoc);
  if (ranges.length === 0) return tr;

  const oldStarts = topLevelBlockStarts(oldDoc);
  const newStarts = topLevelBlockStarts(newDoc);

  for (const range of ranges) {
    const from = tr.mapping.map(oldStarts[range.oldFrom]);
    const to = tr.mapping.map(oldStarts[range.oldTo]);
    const slice = new Slice(newDoc.content.cut(newStarts[range.newFrom], newStarts[range.newTo]), 0, 0);
    tr = tr.replace(from, to, slice);
  }

  return tr;
}

export function setContentWithBlockIds(
  markdown: string,
  blockIds: string[],
  options?: {
    scrollToStart?: boolean;
    imageMeta?: ImageBlockMeta[];
    cursorBoundary?: number;
    // Node index one PAST the last bibliography block — see the clamp logic below for how
    // this bounds the END of the section, as opposed to cursorBoundary's START.
    cursorBoundaryEnd?: number;
    detectPausedEdits?: boolean;
    expected?: ExpectedBlockMeta[];
    // Whether the pushed content is a zoomed subset of the document. See the
    // matching doc comment on window.FinalFinal.setContentWithBlockIds in
    // types.ts for the race this closes. Defaults to false (full-document load).
    zoomMode?: boolean;
    // Zoom-out: land on this block, in the restored document's own coordinate space. Resolved
    // AFTER block ids and image metadata have settled for the newly-pushed document -- see the
    // insertion point inside the paused callback below. Ignored when `scrollToStart` is true.
    scrollToBlockId?: string;
  }
): void {
  clearContentPushTimer(); // Cancel stale timers before document replacement
  syncLog(
    'API:setContentWithBlockIds',
    `entry len=${markdown.length} blocks=${blockIds.length} scrollToStart=${options?.scrollToStart ?? false} zoomMode=${options?.zoomMode ?? false}`
  );
  // [SYNC-DIAG Round 2] First-few IDs so we can tie Swift's id-array to the parsed DOM
  if (SYNC_DIAG_DETAIL) {
    const firstFew = blockIds.slice(0, 5).map((id) => id.slice(0, 8));
    syncLog('API:setContentWithBlockIds', `firstFewIds=[${firstFew.join(',')}]`);
  }
  // Set zoom mode SYNCHRONOUSLY from the caller-supplied option (defaults to
  // false, matching the old unconditional-clear behavior for every call site
  // that doesn't pass it). Previously this always cleared to false and relied
  // on a LATER, separately-awaited syncBlockIds()/pushBlockIds() Swift
  // round-trip to flip it back on for zoom entry — leaving a window where a
  // position-0 insert into the zoomed section was misclassified
  // atDocumentStart: true. See block-sync-document-start.test.ts.
  setBlockIdZoomMode(options?.zoomMode ?? false);
  setContentHasBeenSet(true);
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    // Editor instance doesn't exist yet (main.ts's initEditor() is still awaiting
    // Editor.make().create()). Stash the FULL argument set so main.ts's post-mount replay
    // can call setContentWithBlockIds again with the caller's real block UUIDs, image
    // metadata, and cursor boundaries intact -- replaying through setContent() instead would
    // re-parse and mint fresh block IDs (blockIdPlugin), destroying the real ones.
    setPendingBlockContent({ markdown, blockIds, options });
    setCurrentContent(markdown); // keep -- other readers still expect this
    return;
  }

  // Empty content: clear block IDs and snapshot
  if (!markdown.trim()) {
    setIsSettingContent(true);
    setSyncPaused(true);
    let emptyPushBaseline: Map<string, BlockSnapshot> | undefined;
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const emptyParagraph = view.state.schema.nodes.paragraph.create();
        const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
        const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, emptyDoc.content);
        view.dispatch(tr.setMeta('addToHistory', false).setSelection(Selection.atStart(tr.doc)));
        clearBlockIds();
        redecorateBlockIds(view);
        // Also tells Swift's waitForContentAcknowledgement() (zoom in/out) the redraw is
        // actually done -- see signalPaintComplete's doc comment. Called with no `options`:
        // an emptied document always resets scroll to the top regardless of
        // `options?.scrollToStart`, deliberately -- there is no meaningful position left to
        // preserve once the document has nothing in it.
        signalPaintComplete(view.dom);
        if (options?.detectPausedEdits) {
          emptyPushBaseline = snapshotBlocks(view.state.doc);
        }
      });
      setCurrentContent(markdown);
    } finally {
      setIsSettingContent(false);
      deferredSnapshotAndUnpause(options?.detectPausedEdits ?? false, emptyPushBaseline);
    }
    return;
  }

  // Match applyBlocks pattern: sync paused through ENTIRE operation
  setIsSettingContent(true);
  setSyncPaused(true);
  let parseSucceeded = false;
  // Captured at the very end of the paused callback below, once the pushed
  // content and its real block IDs (and any image-metadata adjustment) have
  // fully settled — the correct "before" baseline for detectPausedEdits, as
  // opposed to the ambient last-known state (see deferredSnapshotAndUnpause).
  let pausedPushBaseline: Map<string, BlockSnapshot> | undefined;
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const parser = ctx.get(parserCtx);

      let doc;
      try {
        doc = parser(markdown);
      } catch (e) {
        console.error('[Milkdown] setContentWithBlockIds parser error:', e);
        resetAndSnapshot(view.state.doc);
        return;
      }
      if (!doc) {
        resetAndSnapshot(view.state.doc);
        return;
      }

      const { from } = view.state.selection;
      // Capture the reader's scroll position BEFORE the document is replaced. It cannot be
      // re-read inside signalPaintComplete's rAF callback two frames later: a bibliography
      // regeneration often makes the document SHORTER, and by then the browser has already
      // clamped window.scrollY to the new, smaller layout -- "restore the current scroll" at
      // that point would faithfully restore the wrong, already-clamped value.
      const scrollAnchor = options?.scrollToStart
        ? undefined
        : { x: window.scrollX, y: window.scrollY, domTop: view.dom.scrollTop };
      let tr = buildBlockLevelReplace(view.state.tr, view.state.doc, doc);

      if (options?.scrollToStart) {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      } else {
        let safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));

        // Clamp cursor before the bibliography section to prevent typing into bib paragraphs.
        // cursorBoundary is the node index of the first bibliography block; cursorBoundaryEnd
        // is the node index one past the LAST bibliography block (absent when the section runs
        // to the end of the document). The clamp only fires when the cursor actually falls
        // INSIDE that [bibPos, bibEndPos) range, not merely at-or-past bibPos: a regenerated
        // bibliography can now be reinserted back at a mid-document anchor instead of always
        // landing at the document's end, so a cursor sitting in real trailing user content
        // AFTER the section must be left alone, not yanked back to just before it.
        const boundary = options?.cursorBoundary ?? -1;
        const boundaryEnd = options?.cursorBoundaryEnd;
        let bibPos = doc.content.size;
        let bibEndPos = doc.content.size;
        if (boundary >= 0) {
          let nodeIdx = 0;
          doc.forEach((_node, pos) => {
            if (nodeIdx === boundary) {
              bibPos = pos;
            }
            if (boundaryEnd !== undefined && nodeIdx === boundaryEnd) {
              bibEndPos = pos;
            }
            nodeIdx++;
          });
          if (safeFrom >= bibPos && safeFrom < bibEndPos) {
            safeFrom = Math.max(0, bibPos - 1);
          }
        }

        syncLog(
          'API:setContentWithBlockIds',
          `cursor: from=${from} safeFrom=${safeFrom} boundary=${boundary} boundaryEnd=${boundaryEnd} bibPos=${bibPos} bibEndPos=${bibEndPos} docSize=${doc.content.size}`
        );

        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
      }
      view.dispatch(tr.setMeta('addToHistory', false));
      parseSucceeded = true;

      // Clear stale IDs, assign real ones, snapshot — all within syncPaused
      clearBlockIds();
      if (blockIds.length > 0) {
        setBlockIdsForTopLevel(blockIds, view.state.doc, options?.expected);
      }
      redecorateBlockIds(view);

      // Inject image metadata (width, caption, blockId) into figure nodes
      // Same pattern as applyBlocks — matches figure nodes positionally with metadata
      const imageMeta = options?.imageMeta;
      if (imageMeta && imageMeta.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < imageMeta.length) {
            const meta = imageMeta[figureIdx];
            metaTr = metaTr.setNodeMarkup(pos, undefined, {
              ...node.attrs,
              caption: meta.caption || '',
              width: meta.width ?? node.attrs.width ?? null,
              blockId: meta.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
      }

      // Correct any figure whose attr still disagrees with the map after the loop above.
      // See syncFigureBlockIdAttrs's doc comment. MUST run before pausedPushBaseline is
      // captured below — dispatching this correction AFTER that snapshot would register as a
      // paused user edit and confuse block-sync's detectPausedEdits comparison.
      syncFigureBlockIdAttrs(view);

      // Capture the "just pushed" baseline LAST, after every transaction in this
      // paused callback has settled, so it reflects the fully-assembled restored
      // content (real IDs, image metadata) — not an intermediate state.
      if (options?.detectPausedEdits) {
        pausedPushBaseline = snapshotBlocks(view.state.doc);
      }

      // Resolve the zoom-out target LAST: block IDs are only valid after
      // setBlockIdsForTopLevel/redecorateBlockIds, and figure heights above the target only
      // settle after the image-metadata pass above.
      let paintAnchor = scrollAnchor;
      const targetTop =
        !options?.scrollToStart && options?.scrollToBlockId
          ? blockScrollTargetTop(view, options.scrollToBlockId)
          : null;
      if (!options?.scrollToStart && options?.scrollToBlockId && targetTop === null) {
        // blockScrollTargetTop() couldn't resolve the zoom-out target (stale/unknown blockId,
        // or coordsAtPos() threw) -- this silently falls through to the pre-fix captured-anchor
        // behaviour below, i.e. exactly the scroll-flash bug this whole mechanism exists to
        // close. Log it so a recurrence in practice is diagnosable instead of invisible.
        syncLog(
          'API:setContentWithBlockIds',
          `zoom-out scroll target unresolved for blockId=${options.scrollToBlockId.slice(0, 8)}, falling back to captured anchor`
        );
      }
      // `!== null`, NOT a truthiness check: 0 is a legitimate target (a section at the very
      // top of the document). `if (targetTop)` would fall through to the pre-fix
      // captured-anchor behaviour on exactly that case.
      if (targetTop !== null) {
        window.scrollTo({ top: targetTop, left: window.scrollX, behavior: 'instant' });
        paintAnchor = { x: window.scrollX, y: window.scrollY, domTop: view.dom.scrollTop };
      }

      // Also tells Swift's waitForContentAcknowledgement() (zoom in/out) the redraw is
      // actually done -- see signalPaintComplete's doc comment.
      signalPaintComplete(view.dom, {}, { restoreScroll: paintAnchor });
    });
    if (parseSucceeded) {
      setCurrentContent(markdown);
    }
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause(options?.detectPausedEdits ?? false, pausedPushBaseline);
  }
}

/**
 * Replay a content push that arrived before the editor instance existed, once the editor has
 * just mounted (main.ts's `initEditor()`, called AFTER the dispatch-tracking hooks are
 * installed, so the replay's own transactions go through the same content-push/section-change
 * tracking as everything else -- see main.ts's doc comment).
 *
 * Both pre-mount no-instance branches above (`setContent`, `setContentWithBlockIds`) stash
 * their argument(s) rather than applying them. This replays whichever stash was written LAST
 * (MF3): `pendingBlockContent`, when non-null, always reflects the most recent pre-mount
 * write -- `setContent`'s own no-instance branch clears it whenever IT runs later, so a
 * non-null value here can only mean "the most recent pre-mount write was a
 * setContentWithBlockIds() call," never a stale leftover from an earlier one.
 *
 * Replays through the SAME entry point the push originally came in on: `setContentWithBlockIds`
 * carries the caller's real block UUIDs, image metadata, and cursor boundaries, which would be
 * lost by round-tripping through `setContent`'s markdown-only re-parse (blockIdPlugin would
 * mint fresh temporary IDs instead) -- the "destroying all real UUIDs (causing mass deletes)"
 * hazard ContentView+ContentRebuilding.swift warns about.
 *
 * Exported (not inlined in main.ts) so the regression test in
 * __tests__/pre-mount-content-push.test.ts exercises this exact production code path instead
 * of a hand-copied duplicate (M20).
 */
export function replayPendingPreMountContent(): void {
  const pending = getPendingBlockContent();
  if (pending) {
    setPendingBlockContent(null); // fire-once, before the call
    setContentWithBlockIds(pending.markdown, pending.blockIds, pending.options);
    return;
  }
  // Legacy/non-block callers (e.g. a plain setContent() that arrived pre-mount): the
  // no-instance branch above always went through setCurrentContent() too, so replay it here
  // -- clearing currentContent FIRST, since setContent()'s own `getCurrentContent() ===
  // markdown` early-return guard would otherwise always match this exact value and silently
  // swallow the replay (the bug this whole mechanism replaces).
  const currentContent = getCurrentContent();
  if (currentContent?.trim()) {
    setCurrentContent('');
    setContent(currentContent);
  }
}

/**
 * Resolve the scroll-target `top` for a block id, in the given view's OWN coordinate space --
 * the shared computation behind both `scrollToBlock` (below) and the zoom-out in-push scroll
 * resolution in `setContentWithBlockIds`. Single copy, load-bearing: the two call sites must
 * compute the exact identical value (the -100 offset included) or the zoom-out fix's kept
 * `scrollToSection` follow-up (WYSIWYG) stops being a harmless no-op and starts fighting the
 * in-push scroll instead of merely re-confirming it.
 *
 * Returns null if the id isn't in `getAllBlockIds()` (stale/unknown id) or `coordsAtPos` throws
 * (e.g. a position outside the current document) -- callers treat null as "can't resolve,
 * fall back."
 */
function blockScrollTargetTop(view: EditorView, blockId: string): number | null {
  const blockIds = getAllBlockIds();

  let targetPos: number | null = null;
  for (const [pos, id] of blockIds) {
    if (id === blockId) {
      targetPos = pos;
      break;
    }
  }

  if (targetPos === null) {
    return null;
  }

  try {
    // Scroll to position ~100px from top for visual consistency with scrollToOffset
    const coords = view.coordsAtPos(targetPos + 1);
    if (!coords) return null;
    return Math.max(0, coords.top + window.scrollY - 100);
  } catch (e) {
    console.error('[Milkdown] blockScrollTargetTop failed:', e);
    return null;
  }
}

export function scrollToBlock(blockId: string): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const targetTop = blockScrollTargetTop(view, blockId);
    if (targetTop === null) {
      // Matches the pre-refactor behavior: even when the target can't be resolved, still
      // focus the editor before returning.
      view.focus();
      return;
    }
    // No `left` key -- matches the pre-refactor behavior this was extracted from exactly:
    // horizontal scroll position is left untouched (sidebar-click/find-bar/outline navigation
    // never intended to move it).
    window.scrollTo({ top: targetTop, behavior: 'smooth' });
    view.focus();
  } catch (e) {
    console.error('[Milkdown] scrollToBlock failed:', e);
  }
}

export function getBlockAtCursor(): { blockId: string; offset: number } | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    const $head = view.state.doc.resolve(head);

    // Find the nearest block containing the cursor
    for (let depth = $head.depth; depth > 0; depth--) {
      const pos = $head.before(depth);
      const blockId = getBlockIdAtPos(pos);
      if (blockId) {
        // Calculate offset within the block
        const offset = head - pos - 1; // -1 for node start boundary
        return { blockId, offset: Math.max(0, offset) };
      }
    }

    return null;
  } catch (e) {
    console.error('[Milkdown] getBlockAtCursor failed:', e);
    return null;
  }
}

export function hasBlockChanges(): boolean {
  return hasPendingChanges();
}

export function flushPendingBlockChanges(): void {
  flushPendingBlockChangesPlugin();
}

export function getBlockChangesApi(): BlockChanges {
  return getBlockChangesPlugin();
}

export function confirmBlockIdsApi(mapping: Record<string, string>): void {
  confirmBlockIdsPlugin(mapping);
  const applied = applyPendingConfirmations();
  updateSnapshotIds(applied);
  // The Map is updated synchronously, but `data-block-id` in the DOM is a decoration that
  // only recomputes on dispatch -- without this, every confirmed block keeps rendering its
  // old temp- id until some unrelated later transaction happens to repaint it (t-623b1713).
  if (applied.size > 0) {
    const editorInstance = getEditorInstance();
    if (editorInstance) {
      try {
        redecorateBlockIds(editorInstance.ctx.get(editorViewCtx));
      } catch (e) {
        console.error('[Milkdown] confirmBlockIdsApi redecorate failed:', e);
      }
    }
  }
}

export function syncBlockIds(orderedIds: string[], zoomMode: boolean, expected?: ExpectedBlockMeta[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  // [SYNC-DIAG Round 2] syncBlockIds is a third Swift→JS seed point (zoom + pushBlockIds).
  // Log before setBlockIdsForTopLevel runs so the plugin-side log reflects the input.
  if (SYNC_DIAG_DETAIL) {
    const firstFew = orderedIds.slice(0, 5).map((id) => id.slice(0, 8));
    syncLog(
      'API:syncBlockIds',
      `entry orderedIds.length=${orderedIds.length} zoomMode=${zoomMode} firstFew=[${firstFew.join(',')}]`
    );
  }
  setBlockIdZoomMode(zoomMode); // Set zoom mode based on caller context
  setBlockIdsForTopLevel(orderedIds, view.state.doc, expected);
  resetAndSnapshot(view.state.doc);
  redecorateBlockIds(view);
}

// ---------------------------------------------------------------------------
// Cursor-aware insert-position algorithm (pasted-image placement fix)
//
// Pinned down and exhaustively verified against the real installed schema by
// the committed test suite in `__tests__/insert-pos.test.ts` (16+ tests) —
// see that file and `docs/`/plan history for the full container-by-container
// rationale. This is the production implementation the tests exercise
// directly (no parallel/duplicated copy).
// ---------------------------------------------------------------------------

const TABLE_FAMILY = new Set(['table', 'table_row', 'table_header_row', 'table_cell', 'table_header']);

function isTableFamily(node: ProsemirrorNode): boolean {
  return TABLE_FAMILY.has(node.type.name);
}

/** Ordered depths (deepest/least-escalated first) for which the caret's
 * position is at the start/end of every ancestor from that depth up to the
 * caret's own immediate parent — i.e. valid candidate anchor points for
 * "before(d)" / "after(d)" that still represent "at the caret", not a jump
 * backward/forward past sibling content.
 *
 * Always seeded with `$pos.depth` itself as the base candidate, so the
 * returned array is never empty (see `chainWalk`'s guard below, which relies
 * on this). */
function candidateDepths($pos: ResolvedPos, atStart: boolean): number[] {
  const out = [$pos.depth];
  for (let d = $pos.depth - 1; d >= 1; d--) {
    const idx = $pos.index(d);
    const matches = atStart ? idx === 0 : idx === $pos.node(d).childCount - 1;
    if (!matches) break;
    out.push(d);
  }
  return out;
}

/** Does this node's content model accept `nodeType` somewhere after its
 * actual current children (walking its content-match state machine), even
 * if not as the very first child? Handles position-dependent expressions
 * like list_item's "paragraph block*" (false before the mandatory first
 * paragraph, true after it) as well as unconditional ones like blockquote's
 * "block+" (true immediately) and bullet_list's "listItem+" (always false). */
function canEventuallyContainBlockType(node: ProsemirrorNode, nodeType: NodeType): boolean {
  let match = node.type.contentMatch;
  if (match.matchType(nodeType)) return true;
  for (let i = 0; i < node.childCount; i++) {
    const next = match.matchType(node.child(i).type);
    if (!next) return false;
    match = next;
    if (match.matchType(nodeType)) return true;
  }
  return false;
}

/** Full boundary-chain walk: always escalate exactly as far as the
 * structural "am I at the edge of this whole run of interchangeable
 * siblings" condition demands — never further, never less. Correct on its
 * own for: START in any container, and END in a "symmetric" container (one
 * whose content model treats all children uniformly, e.g. blockquote's
 * "block+" — no distinguished reserved slot to signal "nest here instead"). */
function chainWalk($pos: ResolvedPos, wantStart: boolean): number {
  const candidates = candidateDepths($pos, wantStart);
  const shallowest = candidates[candidates.length - 1];
  if (shallowest === undefined) {
    // candidateDepths always seeds its result with $pos.depth (itself
    // guaranteed >= 1 by the depth < 1 early-return in
    // computeCursorAwareInsertPos), so this branch should be unreachable.
    // Guard explicitly rather than falling through: $pos.before(undefined)/
    // $pos.after(undefined) silently default to $pos.depth in ProseMirror,
    // which would mask a real bug here instead of surfacing it.
    throw new Error('chainWalk: candidateDepths returned an empty array (unreachable)');
  }
  return wantStart ? $pos.before(shallowest) : $pos.after(shallowest);
}

/** Compute where to insert a block-level node (e.g. a pasted/dropped image
 * figure) so that it lands exactly at the caret, splitting the minimum
 * necessary structure and never tearing apart something that should stay
 * whole (e.g. a table, or a list's mandatory-first paragraph). */
export function computeCursorAwareInsertPos(doc: ProsemirrorNode, rawPos: number, nodeType: NodeType): number {
  const $pos = doc.resolve(rawPos);

  // Depth 0: already an unambiguous, valid top-level insertion point.
  if ($pos.depth < 1) return rawPos;

  const atStart = $pos.parentOffset === 0;
  const atEnd = $pos.parentOffset === $pos.parent.content.size;

  if (atStart || atEnd) {
    // Never attempt to escalate/split through table structure — table_cell's
    // content ("paragraph", exactly one) forces escalation all the way past
    // table/table_row, and ProseMirror's schema has no structural guarantee
    // that a split table would keep matching row/column counts. Use the
    // existing, proven-safe "after the outermost block" fallback instead.
    for (let d = 1; d <= $pos.depth; d++) {
      if (isTableFamily($pos.node(d))) return $pos.after(1);
    }

    // Is the caret's own immediate container "asymmetric" — does it reject
    // the figure type as a FIRST child (index 0)? list_item's
    // "paragraph block*" does (paragraph is mandatory-first); blockquote's
    // "block+" does not (no ordering constraint — any index is equally
    // valid). This distinguishes containers with a genuine "supplementary
    // content lives here, after the required lead-in" slot (list_item) from
    // uniform runs of interchangeable siblings (blockquote), where nesting —
    // even though schema-valid — has no such meaning and must not be
    // preferred over full escalation (verified: preferring it regresses the
    // blockquote-start/end flagship cases, since block+ trivially accepts a
    // figure at any index).
    const immediateParent = $pos.node($pos.depth - 1);
    const asymmetric = !immediateParent.canReplaceWith(0, 0, nodeType);

    const tryNestAtEnd = (): number | null => {
      const idx = $pos.indexAfter($pos.depth - 1);
      if (immediateParent.canReplaceWith(idx, idx, nodeType)) return $pos.after($pos.depth);
      return null;
    };

    if (atStart && atEnd) {
      // Genuinely empty textblock (e.g. an empty bullet). Prefer appending
      // in place (no escalation) when the container's own reserved-slot
      // asymmetry makes that the natural, intended placement; otherwise
      // (symmetric container, e.g. an empty quoted line) fall through to the
      // ordinary chain walk.
      if (asymmetric) {
        const nested = tryNestAtEnd();
        if (nested !== null) return nested;
      }
      return chainWalk($pos, false);
    }

    if (atEnd && asymmetric) {
      const nested = tryNestAtEnd();
      if (nested !== null) return nested;
    }

    return chainWalk($pos, atStart);
  }

  // Genuinely mid-text (interior, not at any ancestor's boundary).
  if ($pos.depth === 1) return $pos.pos;
  for (let d = $pos.depth - 1; d >= 1; d--) {
    if (isTableFamily($pos.node(d))) return $pos.after(1);
    if (canEventuallyContainBlockType($pos.node(d), nodeType)) return $pos.pos;
  }
  return $pos.after(1);
}

/**
 * Insert an image figure node at the end of the document.
 * Called from Swift after image import completes.
 */
export function insertImage(opts: {
  src: string;
  alt: string;
  caption: string;
  width: number | null;
  blockId: string;
  /** Where this insert originated. `'picker'` = native file picker (no
   * cursor-based paste/drop position to consult — see position-selection
   * logic below). Any other value (or omitted) is treated as a
   * clipboard/drop origin. */
  origin?: string;
}): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const figureType = view.state.schema.nodes.figure;
    if (!figureType) {
      console.error('[Milkdown] figure node type not found in schema');
      return;
    }

    // Remove ghost inline images from ProseMirror state (not just DOM).
    // WebKit's native performDragOperation can insert <img> elements before
    // JS events fire; ProseMirror incorporates them as inline image nodes.
    // Legitimate images use the projectmedia:// scheme, never blob:/data:.
    const imageType = view.state.schema.nodes.image;
    let tr = view.state.tr;
    if (imageType) {
      const removals: { from: number; to: number }[] = [];
      view.state.doc.descendants((node, pos) => {
        if (node.type === imageType) {
          const src = (node.attrs.src as string) || '';
          if (src.startsWith('blob:') || src.startsWith('data:')) {
            removals.push({ from: pos, to: pos + node.nodeSize });
          }
        }
      });
      if (removals.length > 0) {
        syncLog('API:insertImage', `removing ${removals.length} ghost image(s)`);
        // Delete in reverse order to preserve earlier positions
        for (let i = removals.length - 1; i >= 0; i--) {
          tr = tr.delete(removals[i].from, removals[i].to);
        }
      }
    }
    // DOM cleanup as belt-and-suspenders
    for (const el of document.querySelectorAll('img[src^="blob:"], img[src^="data:"]')) {
      el.remove();
    }

    const node = figureType.create({
      src: opts.src,
      alt: opts.alt,
      caption: opts.caption,
      width: opts.width,
      blockId: opts.blockId,
    });

    // Position selection order: cursor-aware paste position first, then
    // cursor-aware drop position, then the existing after-cursor-block
    // fallback (still used by the image-picker flow). Both paste and drop
    // positions are routed through computeCursorAwareInsertPos() so a raw
    // position at any depth/boundary escalates or nests correctly instead of
    // going straight to tr.insert(). Compute against tr.doc (which may have
    // had ghost images removed).
    //
    // Both pending position fields are drained unconditionally (even for a
    // picker-originated call) so a picker insert never leaves stale state
    // behind for a later, unrelated paste/drop to pick up — see the mutual
    // one-shot-consume contract in image-plugin.ts.
    const pastePos = consumePendingPastePos();
    const dropPos = consumePendingDropPos();
    // Both pastePos and dropPos were captured in pre-deletion document
    // coordinates. If a ghost inline image (blob:/data:) existed before either
    // position, the tr.delete(...) calls above shifted everything after it, so
    // each must be mapped through the accumulated transform steps before being
    // resolved against tr.doc — otherwise it can point at the wrong logical spot.
    const mappedPastePos = pastePos !== null ? tr.mapping.map(pastePos) : null;
    const mappedDropPos = dropPos !== null ? tr.mapping.map(dropPos) : null;
    const docSize = tr.doc.content.size;
    syncLog(
      'API:insertImage',
      `pastePos=${pastePos} mappedPastePos=${mappedPastePos} dropPos=${dropPos} mappedDropPos=${mappedDropPos} docSize=${docSize} origin=${opts.origin ?? ''}`
    );

    const isPicker = opts.origin === 'picker';
    const rawPos =
      !isPicker && mappedPastePos !== null && mappedPastePos >= 0 && mappedPastePos <= docSize
        ? mappedPastePos
        : !isPicker && mappedDropPos !== null && mappedDropPos >= 0 && mappedDropPos <= docSize
          ? mappedDropPos
          : null;

    let insertPos: number;
    if (rawPos !== null) {
      insertPos = computeCursorAwareInsertPos(tr.doc, rawPos, figureType);
      syncLog('API:insertImage', `cursor-aware insertPos=${insertPos} (from rawPos=${rawPos})`);
    } else {
      // Fallback: after current selection's top-level block. Reached whenever
      // there's no usable cursor-aware position — the picker path (expected),
      // OR (unexpected, and a loss of precision) a clipboard paste/drop whose
      // pendingPastePos/pendingDropPos was never set or already expired (see
      // PENDING_POS_TIMEOUT_MS in image-plugin.ts). Logged explicitly so a
      // live-app retest's console makes it obvious which case this was.
      if (!isPicker) {
        syncLog(
          'API:insertImage',
          `FALLBACK: no usable paste/drop position (pastePos=${pastePos} mappedPastePos=${mappedPastePos} dropPos=${dropPos} mappedDropPos=${mappedDropPos}) — using after-current-block placement, cursor-aware positioning was lost`
        );
      }
      try {
        const { from } = view.state.selection;
        const $from = tr.doc.resolve(Math.min(from, docSize));
        insertPos = $from.after(1);
      } catch {
        insertPos = tr.doc.content.size;
      }
    }
    // Detect whether this insert is about to split ONE ordered_list into two
    // halves (e.g. pasting/dropping an image mid-list), as opposed to landing
    // in a gap that does NOT split a single list — between two independent
    // pre-existing lists, inside/after some other container, at the very top
    // level, etc. Resolved against tr.doc BEFORE the insert happens, so
    // $split.parent is the list as it stands whole, not yet split: a gap
    // between two separate adjacent ordered_list nodes resolves its .parent
    // to the containing doc/blockquote (not ordered_list), so that case is
    // correctly excluded here without any special-casing.
    //
    // Only in the genuine mid-list-split case do we continue the tail half's
    // numbering — a deliberately-started new list (manual list creation /
    // input rules) is untouched: those always resolve to a fresh position
    // whose $split.parent is never the SAME ordered_list with items on both
    // sides, so `continuation` stays null and `order` keeps its normal
    // default of 1.
    // Depth-agnostic by construction: `$split.parent` is whatever node
    // directly contains position `insertPos` at ITS OWN depth, resolved
    // dynamically — so this works identically whether the split list is a
    // top-level ordered_list or one nested many levels deep inside other
    // lists/blockquotes. There is no hardcoded depth to keep in sync with
    // nesting.
    //
    // Do NOT extend this to walk up past a `paragraph` parent to catch the
    // mid-text-paste case (pasting inside an item's text, not at an item
    // boundary). That case is intentionally excluded: `list_item`'s content
    // model is `"paragraph block*"`, which unconditionally absorbs a pasted
    // figure as an extra block child of the SAME item, without ever
    // splitting the list. There is nothing to continue numbering for —
    // walking up to find an ordered_list ancestor there would misidentify a
    // non-split as a split.
    const $split = tr.doc.resolve(insertPos);
    const splitDepth = $split.depth;
    let continuation: number | null = null;
    if (
      splitDepth > 0 &&
      $split.parent.type === view.state.schema.nodes.ordered_list &&
      $split.index(splitDepth) > 0 &&
      $split.indexAfter(splitDepth) < $split.parent.childCount
    ) {
      const list = $split.parent;
      const before = $split.index(splitDepth);
      continuation = (list.attrs.order ?? 1) + before;
    }

    tr = tr.insert(insertPos, node);

    if (continuation !== null) {
      // `insertPos` sat INSIDE the (still whole) list's own content, between
      // two list items — not at a top-level boundary. To actually place a
      // block-level figure there, ProseMirror's replace negotiation closes
      // the list right after the earlier items (one "list close" token,
      // ending the first half-list immediately before the figure) and opens
      // a fresh list right after the figure (the second half-list starts
      // there directly, with no further gap) — verified against the real
      // editor pipeline (see repro-list-paste.test.ts). So the tail list
      // begins one position past the figure, not directly at
      // insertPos + node.nodeSize.
      const tailPos = insertPos + 1 + node.nodeSize;
      const tailList = tr.doc.nodeAt(tailPos);
      if (tailList && tailList.type === view.state.schema.nodes.ordered_list) {
        tr = tr.setNodeMarkup(tailPos, undefined, { ...tailList.attrs, order: continuation });
      }
    }

    view.dispatch(tr);
  } catch (e) {
    console.error('[Milkdown] insertImage failed:', e);
  }
}

/**
 * Surgically update heading levels in the editor without replacing the document.
 * Called from Swift hierarchy enforcement to avoid the DB-to-editor round-trip
 * that causes content discrepancy and data loss.
 */
export function updateHeadingLevels(changes: Array<{ blockId: string; newLevel: number }>): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance || changes.length === 0) return;

  syncLog('API:updateHeadingLevels', `${changes.length} changes`);
  setSyncPaused(true);
  setIsSettingContent(true);
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const blockIds = getAllBlockIds(); // Map<pos, id>

      // Invert: id → pos
      const idToPos = new Map<string, number>();
      for (const [pos, id] of blockIds) {
        idToPos.set(id, pos);
      }

      // P3 WYSIWYG (undo-mode-switch-focus second timing gap): split changes into
      // overlapping-the-user's-recent-edit vs not. Positions are resolved ONCE here
      // against the pre-dispatch doc -- setNodeMarkup is attr-only and never shifts
      // positions, so these `pos` values stay valid across BOTH transactions below, even
      // though the second is built against the state left by the first's dispatch.
      const recentSpan = getRecentUserEditSpan();
      const overlapping: Array<{ pos: number; newLevel: number }> = [];
      const silent: Array<{ pos: number; newLevel: number }> = [];
      let appliedCount = 0;

      for (const change of changes) {
        const pos = idToPos.get(change.blockId);
        if (pos === undefined) {
          syncLog('API:updateHeadingLevels', `WARN: blockId ${change.blockId.slice(0, 8)} not found`);
          continue;
        }
        const node = view.state.doc.nodeAt(pos);
        if (!node || node.type.name !== 'heading') continue;
        const overlaps = recentSpan !== null && pos < recentSpan.to && pos + node.nodeSize > recentSpan.from;
        (overlaps ? overlapping : silent).push({ pos, newLevel: change.newLevel });
      }

      // Non-overlapping changes: keep today's silent dispatch verbatim -- hierarchy
      // enforcement is a programmatic, sync-origin push, must not land as a
      // user-undoable step.
      if (silent.length > 0) {
        let tr = view.state.tr;
        for (const { pos, newLevel } of silent) {
          const node = tr.doc.nodeAt(pos);
          if (!node || node.type.name !== 'heading') continue;
          tr = tr.setNodeMarkup(pos, undefined, { ...node.attrs, level: newLevel });
          appliedCount++;
        }
        if (tr.steps.length > 0) {
          view.dispatch(tr.setMeta('addToHistory', false));
        }
      }

      // Overlapping changes: undoable, isolated on BOTH history boundaries.
      if (overlapping.length > 0) {
        let tr = view.state.tr;
        for (const { pos, newLevel } of overlapping) {
          const node = tr.doc.nodeAt(pos);
          if (!node || node.type.name !== 'heading') continue;
          tr = tr.setNodeMarkup(pos, undefined, { ...node.attrs, level: newLevel });
          appliedCount++;
        }
        if (tr.steps.length > 0) {
          // Leading boundary: closeHistory resets prevTime to 0 BEFORE this transaction
          // applies, so it can never join the user's still-open typing group. Tagged
          // derivedCorrection (not addToHistory:false -- deliberately left undoable) so
          // undo-coordinator.ts's three provenance predicates route it correctly.
          view.dispatch(closeHistory(tr).setMeta('derivedCorrection', true));
          // Trailing boundary -- not optional. Without this second dispatch, the state
          // left by the one above stores prevTime = tr.time from the correction ITSELF,
          // so the user's very next transaction within newGroupDelay (500ms, unconfigured
          // here) at an adjacent position would join the correction's own undo group --
          // "user resumes typing right where the correction just happened" is the common
          // case, not an edge case. A second, EMPTY closeHistory dispatch resets
          // prevTime back to 0 for whatever comes next (applyTransaction performs the
          // reset and returns early at zero steps).
          view.dispatch(closeHistory(view.state.tr));
        }
      }

      // Update currentContent to match post-surgery state
      // (prevents stale currentContent from causing issues with setContent unchanged check)
      setCurrentContent(getMarkdown()(ctx));

      syncLog('API:updateHeadingLevels', `applied ${appliedCount}/${changes.length} changes`);
    });
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause();
  }
}
