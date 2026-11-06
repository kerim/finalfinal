// The Rich Text -> Markdown switch, the INCOMING Markdown page's side (Phase 5 job A9, t-94369a83; design:
// docs/architecture/write-queue-plan/phase5/a7-a10-design.md, section 3, and docs/architecture/write-queue-plan/phase5/a9-notes.md).
//
// The switch used to flip the editors first and hand the new Markdown page its text 0.5 to 2 s later, over whatever had been typed:
// keys pressed in that gap reached no editor, or reached the new page and were overwritten (measurements.md: 4 or 5 of 6 markers lost).
// Now the outgoing Rich Text page stays on screen and typeable while this page is filled in the background (still the detached standby
// page, or a fresh one), and the switch flips only when this page has its text. What was typed in the outgoing page meanwhile reaches the
// rows through the ordered queue, and Swift hands the result to this page as a text difference ("the carry"), which this page puts in as
// typing, on top of anything typed here since.
//
// The model's names (docs/architecture/tla/DocSyncCurrent.tla, round 4, TransTwoPage), at the step each call is:
//   TransIncomingReady  `prepareIncomingSwitch`: the page has the rows' text (Swift's `initialize` just before) and starts tracking every
//                       change made here from now on; its typing push to Swift is held until `finishIncomingSwitch` (nothing it sends
//                       could be saved while the switch is still writing the carry).
//   TransSwap           `applySwitchCarry` (once, or twice with the catch-up): the difference `from -> to` (two texts Swift assembled from
//                       the rows, before and after the carried typing was written) is mapped over what was typed HERE since `from` was this
//                       page's text and dispatched as typing, one history step. The carried typing goes BEFORE anything typed here at the
//                       same place (it was typed first).
//   (end)               `finishIncomingSwitch`: tracking stops, the held push is sent (it carries the carried text plus anything typed).
//
// Nothing is refused silently: a carry whose `from` is not the text this page was given (a stray Swift push, an exception) answers
// `{ok: false}` and leaves the page as it is; Swift then pushes the rows the old way (the catch-up of the design's section 0 (c)).

import { isolateHistory } from '@codemirror/commands';
import { ChangeSet, EditorSelection, type Transaction } from '@codemirror/state';
import { getEditorView } from './editor-state';
import { computeMinimalChanges } from './text-diff';
import { holdTypingPushes, releaseTypingPushes } from './typing-push-hold';
import { dispatchAsTyping, typingReplay } from './typing-rebase';

export interface SwitchCarryOptions {
  /** The text this page was last given by Swift (the prepared text, or the `to` of the previous carry). */
  from: string;
  /** The same text with the carried typing in it (assembled from the rows after the carry was written). */
  to: string;
  /** The outgoing editor's caret as a Markdown line and column, used only when nothing has been typed on this page yet. */
  cursor?: { line: number; column: number } | null;
}

export type SwitchCarryResult =
  | { ok: true; spans: number; mappedOverLocalTyping: boolean; raw: string }
  | { ok: false; reason: string };

interface IncomingSwitch {
  /** The last text Swift gave this page (`from` of the next carry must equal it). */
  text: string;
  /** Every change made on this page since `text` was its text, composed (the user's typing on the new page). */
  since: ChangeSet;
}

let incoming: IncomingSwitch | null = null;
let applying = false;

/** Called by main.ts's update listener for every transaction: composes the changes typed here since the last text Swift gave. */
export function noteSwitchTransaction(tr: Transaction): void {
  if (incoming === null || applying || !tr.docChanged) return;
  incoming.since = incoming.since.compose(tr.changes);
}

export function isIncomingSwitchActive(): boolean {
  return incoming !== null;
}

/** TransIncomingReady: the page has the rows' text; from here every change is tracked and the typing push is held. */
export function prepareIncomingSwitch(): { ok: boolean; chars: number } {
  const view = getEditorView();
  if (!view) return { ok: false, chars: 0 };
  incoming = { text: view.state.doc.toString(), since: ChangeSet.empty(view.state.doc.length) };
  holdTypingPushes();
  return { ok: true, chars: view.state.doc.length };
}

/** A Markdown line and column as a position of `doc`, clamped (setCursorPosition's rule). */
function positionOf(doc: Transaction['newDoc'], cursor: { line: number; column: number }): number {
  const line = doc.line(Math.max(1, Math.min(cursor.line, doc.lines)));
  return line.from + Math.max(0, Math.min(cursor.column, line.length));
}

/**
 * A carried pure insertion moved left onto the point where typing was done here, when inserting it there gives the same text. The text
 * diff finds an insertion as far right as the common prefix reaches, so a carry that starts with the character after the caret (" box"
 * typed before " harbour") is found one character later ("box " after the space); mapped from there, keys typed here at the caret would
 * go BEFORE the carried keys, which were typed first (hand test 2026-11-06, a9-notes.md, "Cursor fix and switch notice").
 */
function slideToLocalTyping(
  spec: { from: number; to: number; insert: string },
  base: string,
  since: ChangeSet | null
): { from: number; to: number; insert: string } {
  if (since === null || spec.from !== spec.to || spec.insert.length === 0) return spec;
  let slid = spec;
  since.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    if (slid !== spec || fromA !== toA || inserted.length === 0 || fromA >= spec.from) return;
    const between = base.slice(fromA, spec.from);
    const joined = between + spec.insert;
    if (joined.slice(spec.insert.length) === between) {
      slid = { from: fromA, to: fromA, insert: joined.slice(0, spec.insert.length) };
    }
  });
  return slid;
}

/** TransSwap: the carry `from -> to`, mapped over the typing done here since, dispatched as one typing step. See the header. */
export function applySwitchCarry(options: SwitchCarryOptions): SwitchCarryResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  if (incoming === null) return { ok: false, reason: 'notPrepared' };
  if (options.from !== incoming.text) return { ok: false, reason: 'base' };
  try {
    const typedHere = !incoming.since.empty;
    const raw = computeMinimalChanges(options.from, options.to);
    const specs = typedHere ? raw.map((spec) => slideToLocalTyping(spec, options.from, incoming?.since ?? null)) : raw;
    if (specs.length === 0)
      return { ok: true, spans: 0, mappedOverLocalTyping: typedHere, raw: view.state.doc.toString() };
    const carry = ChangeSet.of(specs, options.from.length);
    // The carried typing came first: at a position where both inserted, it goes before what was typed here.
    const mapped = typedHere ? carry.map(incoming.since, true) : carry;
    const newDoc = mapped.apply(view.state.doc);
    let selection: EditorSelection;
    if (!typedHere && options.cursor) {
      const pos = positionOf(newDoc, options.cursor);
      selection = EditorSelection.single(pos);
    } else {
      // The caret moves past carried text inserted exactly where it stands (assoc 1), so the next key lands after it.
      selection = view.state.selection.map(mapped, 1);
    }
    applying = true;
    try {
      dispatchAsTyping(view, {
        changes: mapped,
        selection,
        scrollIntoView: true,
        annotations: [typingReplay.of(true), isolateHistory.of('full')],
      });
    } finally {
      applying = false;
    }
    // Next round's base: `to`, with what was typed here re-expressed after the carry.
    incoming = {
      text: options.to,
      since: typedHere ? incoming.since.map(carry, false) : ChangeSet.empty(options.to.length),
    };
    return { ok: true, spans: specs.length, mappedOverLocalTyping: typedHere, raw: view.state.doc.toString() };
  } catch (error) {
    applying = false;
    return { ok: false, reason: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200) };
  }
}

/** The end of the switch: tracking stops and the held typing push is sent (`'send'`) or dropped. Idempotent. */
export function finishIncomingSwitch(mode: 'send' | 'discard' = 'send'): { ended: boolean } {
  const was = incoming !== null;
  incoming = null;
  applying = false;
  releaseTypingPushes(mode);
  return { ended: was };
}

/** Test-only. */
export function resetIncomingSwitchForTests(): void {
  incoming = null;
  applying = false;
}
