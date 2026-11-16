// The zoom transition, Markdown page side (Phase 5 job A8, t-94369a83; design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md,
// sections 0 and 2). A zoom in or out in Markdown used to write the 50 ms-late copy of the text (`flushContentToDatabase`), read the rows
// and push the whole zoomed (or full) text over the page; keys typed between the copy and the push were lost (the sync model's windows W1
// and W2). Now the page hands Swift its live text and starts holding and recording in ONE turn (`beginTransition`), Swift writes that text
// through the ordered queue and waits for it, reads the rows, and the page swaps the new text in with the recorded typing put back on top,
// again in ONE turn (`swapTransition`).
//
// The model's names (docs/architecture/tla/README.md, "Phase 5 step T"; DocSyncCurrent.tla), at the step that is each one:
//   TransBegin + TransLiveRead  `beginTransition`: the live raw text (never a cached copy) is returned, recording starts and the typing push
//                               to Swift is held (typing-push-hold.ts: `pend' = {}`), in one turn, so no key is both in the text and in
//                               the recording.
//   TransBarrier                Swift's side: the text is written through the queue (`MarkdownBlockWriter.writeNow`, or the zoomed range
//                               write while zoomed) and `awaitSettled` waits for it.
//   TransPushFrom + TransReplay `swapTransition`: the new text replaces the page's (the body of `setContent`, as today's zoom push), then the
//                               typing recorded since the begin is put back on top as one history step, and the hold ends, in one turn.
//                               Typing in text the target does not hold (zoom in: outside the zoomed chapter) comes back as `outside`, the
//                               step-1 text with only that typing applied; Swift writes it through the per-block writer after the swap.
//   the refusal path            not modelled (the tests below cover it): the page leaves its text as the user had it, releases the held
//                               push and answers `{refused: true, raw}`; Swift adopts `raw` and runs today's zoom (the one catch-up).
//
// THE CARRY. The zoomed text's body (the zoomed text minus its mini-Notes) is the zoomed chapter exactly as the page held it: Swift wrote the
// page's own text to the rows and assembles the target from them, anchors re-injected. So the body is a substring of the other side: zoom in,
// of the step-1 text; zoom out, of the full target. The page finds it (it must be found exactly once); every recorded change inside it is the
// same change shifted by the difference of the two offsets. Zoom in: a change outside it goes to `outside`; zoom out: a change outside it
// (typing in the mini-Notes) is a refusal; a change across its edge is a refusal. No typing recorded: no search, the swap is today's push.

import { isolateHistory } from '@codemirror/commands';
import { ChangeSet, EditorSelection, Text, type Transaction } from '@codemirror/state';
import { setContent } from './api';
import { getEditorView } from './editor-state';
import { holdTypingPushes, releaseTypingPushes } from './typing-push-hold';
import { dispatchAsTyping, isTypingTransaction, typingReplay } from './typing-rebase';
import { isLatched } from './undo-coordinator';

export interface MarkdownTransitionBeginOk {
  ok: true;
  token: number;
  /** The live raw text (anchors and markers included): what Swift writes through the queue before the barrier. */
  raw: string;
}
export interface MarkdownTransitionBeginRefused {
  ok: false;
  reason: string;
}
export type MarkdownTransitionBeginResult = MarkdownTransitionBeginOk | MarkdownTransitionBeginRefused;

export interface MarkdownSwapOptions {
  /** The target text, anchors included (the zoomed text with its mini-Notes, or the full text with its bibliography marker). */
  text: string;
  /** `in`: the target is a chapter of the step-1 text. `out`: the step-1 text (a zoomed chapter) is part of the target. */
  kind: 'in' | 'out';
  scrollToStart?: boolean;
}

export interface MarkdownSwapOk {
  ok: true;
  /** How many recorded changes were put back on top of the target (0: the swap was today's push). */
  replayed: number;
  /** The page's text after the swap and the replay. */
  raw: string;
  /** Zoom in only: the step-1 text with only the typing done outside the zoomed chapter applied, or null when there was none. */
  outside: string | null;
}
export interface MarkdownSwapRefused {
  ok: false;
  refused: true;
  reason: string;
  /** The page's live text, untouched: Swift adopts it before today's zoom runs (the catch-up). */
  raw: string;
}
export type MarkdownSwapResult = MarkdownSwapOk | MarkdownSwapRefused;

/** One change recorded since the begin. `carriable`: the user's typing, or an undo or redo of it; anything else (a Swift push, a derived
 * correction) is already in the rows and would be doubled by a replay. */
export interface RecordedChange {
  changes: ChangeSet;
  carriable: boolean;
}

/** The marker that separates a zoomed chapter from its mini-Notes (`EditorViewState.buildZoomInTarget`). */
export const ZOOM_NOTES_SEPARATOR = '\n\n<!-- ::zoom-notes:: -->';

let token: number | null = null;
let tokenCounter = 0;
let baseText = '';
let recorded: RecordedChange[] = [];

/** Called by main.ts's update listener for every transaction. Records only while a transition holds. */
export function noteTransitionTransaction(tr: Transaction): void {
  if (token === null || !tr.docChanged) return;
  const carriable = isTypingTransaction(tr) || tr.isUserEvent('undo') || tr.isUserEvent('redo');
  recorded.push({ changes: tr.changes, carriable });
}

/** Ends the hold (the push is sent or dropped) and forgets the records. A press window that owns the hold keeps it. */
function endHold(mode: 'send' | 'discard'): void {
  token = null;
  recorded = [];
  baseText = '';
  if (!isLatched()) releaseTypingPushes(mode);
}

/** TransBegin + TransLiveRead: the live text, the recording and the hold, in one turn. */
export function beginTransition(): MarkdownTransitionBeginResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  if (isLatched()) return { ok: false, reason: 'latched' };
  // A hold Swift lost track of (its end call never arrived) is replaced: its swap will find its token stale.
  tokenCounter += 1;
  token = tokenCounter;
  baseText = view.state.doc.toString();
  recorded = [];
  holdTypingPushes();
  return { ok: true, token, raw: baseText };
}

/** Ends a hold whose swap never came (`null`: whatever hold is on). `send` posts the held typing push. */
export function endTransition(which: number | null, mode: 'send' | 'discard' = 'send'): { ended: boolean } {
  if (token === null || (which !== null && which !== token)) return { ended: false };
  endHold(mode);
  return { ended: true };
}

export type MarkdownTransitionTakeResult =
  | {
      ok: true;
      /** The text at the begin (what Swift wrote before the barrier). */
      base: string;
      /** The live text now (the base with everything typed since). */
      raw: string;
      /** The caret now, as a Markdown line and column. */
      cursor: { line: number; column: number };
    }
  | { ok: false; reason: string };

/**
 * Phase 5 job A10 (the Markdown -> Rich Text switch; a9-notes.md): the held page's live text, read WITHOUT ending the hold (the outgoing
 * page stays on screen and typeable until the incoming Rich Text page has its text; TransTwoPage). Swift writes `raw` through the queue,
 * carries it to the incoming page, and ends the hold with `endTransition(token, 'discard')` once the outgoing page has left the window and
 * a last take has been carried (the catch-up).
 */
export function takeTransitionText(which: number): MarkdownTransitionTakeResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  if (token === null || which !== token) return { ok: false, reason: 'staleToken' };
  const head = view.state.selection.main.head;
  const line = view.state.doc.lineAt(head);
  return {
    ok: true,
    base: baseText,
    raw: view.state.doc.toString(),
    cursor: { line: line.number, column: head - line.from },
  };
}

export type CarryPlan =
  | {
      ok: true;
      /** The recorded inside changes, shifted onto the target and composed (null: nothing to put back). */
      changes: ChangeSet | null;
      replayed: number;
      /** The target with the replay applied. */
      expected: string;
      outside: string | null;
      /** The caret on the target, when it was inside the zoomed chapter. */
      selection: EditorSelection | null;
    }
  | { ok: false; reason: string };

const unique = (haystack: string, needle: string): number => {
  const at = haystack.indexOf(needle);
  if (at < 0 || haystack.indexOf(needle, at + 1) >= 0) return -1;
  return at;
};

const bodyOf = (text: string): string => {
  const at = text.indexOf(ZOOM_NOTES_SEPARATOR);
  return at < 0 ? text : text.slice(0, at);
};

/**
 * The carry, pure: `base` is the step-1 text, `live` the page's text now, `changes` the changes recorded since (oldest first), `target` the
 * text Swift assembled. See the header, "THE CARRY". Never throws.
 */
export function planCarry(
  base: string,
  live: Text,
  changes: readonly RecordedChange[],
  target: string,
  kind: 'in' | 'out',
  liveSelection: EditorSelection | null
): CarryPlan {
  try {
    if (changes.length === 0)
      return { ok: true, changes: null, replayed: 0, expected: target, outside: null, selection: null };
    if (changes.some((change) => !change.carriable)) return { ok: false, reason: 'changed' };
    let check = Text.of(base.split('\n'));
    for (const change of changes) check = change.changes.apply(check);
    if (!check.eq(live)) return { ok: false, reason: 'records' };

    let bFrom: number;
    let bodyLength: number;
    let tFrom: number;
    if (kind === 'in') {
      const body = bodyOf(target);
      bFrom = body.length > 0 ? unique(base, body) : -1;
      bodyLength = body.length;
      tFrom = 0;
    } else {
      const body = bodyOf(base);
      tFrom = body.length > 0 ? unique(target, body) : -1;
      bodyLength = body.length;
      bFrom = 0;
    }
    if (bFrom < 0 || tFrom < 0) return { ok: false, reason: 'slice' };

    let from = bFrom;
    let to = bFrom + bodyLength;
    let tDoc = Text.of(target.split('\n'));
    let composed: ChangeSet | null = null;
    let replayed = 0;
    let outsideTouched = false;
    for (const change of changes) {
      const specs: Array<{ from: number; to: number; insert: string }> = [];
      let refusal: string | null = null;
      change.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
        if (fromA >= from && toA <= to) {
          specs.push({ from: fromA - from + tFrom, to: toA - from + tFrom, insert: inserted.toString() });
        } else if (toA <= from || fromA >= to) {
          if (kind === 'out') refusal = 'outside';
          else outsideTouched = true;
        } else {
          refusal = 'straddle';
        }
      });
      if (refusal !== null) return { ok: false, reason: refusal };
      if (specs.length > 0) {
        const shifted = ChangeSet.of(specs, tDoc.length);
        tDoc = shifted.apply(tDoc);
        composed = composed === null ? shifted : composed.compose(shifted);
        replayed += 1;
      }
      from = change.changes.mapPos(from, -1);
      to = change.changes.mapPos(to, 1);
    }

    const expected = target.slice(0, tFrom) + live.sliceString(from, to) + target.slice(tFrom + bodyLength);
    if (tDoc.toString() !== expected) return { ok: false, reason: 'inconsistent' };
    const outside =
      kind === 'in' && outsideTouched
        ? live.sliceString(0, from) + base.slice(bFrom, bFrom + bodyLength) + live.sliceString(to)
        : null;
    let selection: EditorSelection | null = null;
    if (liveSelection) {
      const main = liveSelection.main;
      const inside = (pos: number): boolean => pos >= from && pos <= to;
      if (inside(main.anchor) && inside(main.head)) {
        selection = EditorSelection.single(main.anchor - from + tFrom, main.head - from + tFrom);
      }
    }
    return { ok: true, changes: composed, replayed, expected, outside, selection };
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) };
  }
}

/** TransPushFrom + TransReplay: the target replaces the page's text and the recorded typing goes back on top, in one turn. */
export function swapTransition(which: number, options: MarkdownSwapOptions): MarkdownSwapResult {
  const view = getEditorView();
  if (!view) return { ok: false, refused: true, reason: 'noEditor', raw: '' };
  const live = view.state.doc;
  if (token === null || which !== token)
    return { ok: false, refused: true, reason: 'staleToken', raw: live.toString() };
  const plan = planCarry(baseText, live, recorded, options.text, options.kind, view.state.selection);
  const refuse = (reason: string): MarkdownSwapRefused => {
    endHold('send'); // the held typing reaches Swift once
    return { ok: false, refused: true, reason, raw: view.state.doc.toString() };
  };
  if (!plan.ok) return refuse(plan.reason);

  // The dry run, before anything live changes: the target state through the editor's transaction filters, then the replay.
  const replaySpec =
    plan.changes === null
      ? null
      : {
          changes: plan.changes,
          ...(plan.selection ? { selection: plan.selection } : {}),
          annotations: [typingReplay.of(true), isolateHistory.of('before')],
        };
  if (replaySpec) {
    const swapped = view.state.update({ changes: { from: 0, to: live.length, insert: options.text } }).state;
    if (swapped.doc.toString() !== options.text) return refuse('a filter changed the target');
    if (swapped.update(replaySpec).state.doc.toString() !== plan.expected) return refuse('a filter changed the replay');
  }

  // Recording stops before the swap's own transactions.
  token = null;
  recorded = [];
  baseText = '';
  setContent(options.text, { scrollToStart: options.scrollToStart === true, origin: 'intentional' });
  if (replaySpec) dispatchAsTyping(view, replaySpec);
  // The replay's own 50 ms push carries the text; the push owed for the typing is dropped (noteTypingReplayed's rule).
  if (!isLatched()) releaseTypingPushes('discard');
  return { ok: true, replayed: plan.replayed, raw: view.state.doc.toString(), outside: plan.outside };
}

/** Test-only: forgets every transition (web tests). */
export function resetMarkdownTransitionForTests(): void {
  token = null;
  recorded = [];
  baseText = '';
}
