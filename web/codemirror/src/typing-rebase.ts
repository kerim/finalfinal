// Typing done while a Cmd-Z waits (Phase 4c, job 2, t-d2061b27) -- the PURE half for Markdown mode: no registry, no latch, no Swift.
//
// A Cmd-Z / Cmd-Shift-Z that waits behind an earlier section command must keep waiting when the user types, then run on the document AS IT
// WAS WHEN THE KEY WAS PRESSED, with the typing done meanwhile put back on top, where it was typed. This file holds the pieces that
// undo-coordinator.ts (the collector, the routing on the document at the press, the held presses) and api-structural-markdown.ts (the
// swap: `markdownStructuralSwap`, `swapWithTypingReplay`) call.
//
//   1. `TypingCollector`   records every change made since a press, tagged with the number of the latest press at or before it.
//   2. `docAtPress`        the document as it was at the press (what the routing compares with the saved copy): the typing inverted, the
//                          automatic changes (a settle's rewrites) commuted in front of it and kept.
//   3. `buildOver`         the map from that document (D0) to the swap target (T): the carry change set of redo-branch.ts, plus -- for a
//                          DRAG -- a translation of the moved chapter, so typing inside it moves back with it.
//   4. `buildReplayDryRun` / `swapWithReplay`   rebase the typing onto T, try it on a throwaway state, and only then swap and replay.
//
// THE REBASE. D0 and T are related by `Over`. The steps s_1..s_n typed since the press are written against D0, D0+s_1, ... A step is placed
// on T+s_1'..s_(i-1)' by mapping each of its edits through `Chain`: back through the inverses of the earlier steps, across Over, forward
// through the earlier REBASED steps (the collab idea, with CodeMirror change sets). A position inside text an earlier step typed is not
// pushed through Over at all: the earlier step left a "run" (where that text starts in the document at that step, and where its copy starts
// in T), and the position is read off the run -- the mirror of the ProseMirror algorithm, so a letter typed after an earlier letter lands
// after it, and a backspace over typed text deletes the copy of that text.
//
// THE EDGE RULE (the judge's ruling, review-round1.md). An INSERTION whose position lies in text that exists in both documents goes where
// Over maps it. If the text it was typed in survives with changed content (a restore: a replaced hunk), the position goes to the END edge
// of the changed run (CodeMirror's own assoc 1; mid-sentence is accepted). If the text it was typed in is gone (a duplicate's copy, an
// inserted section), the letters become their OWN LINE at the gap, padded with blank lines, so they are never glued to a `#` heading line
// (CodeMirror alone would put them at the start of the heading line that follows the removed text). A DELETION inside gone text is a no-op;
// a deletion whose two ends lie in different kinds of text (one in kept text, one in gone text or the moved chapter) cannot be placed.
//
// Nothing here throws to its caller: a failure is returned as a decision (`changed` when the document at the press cannot be built,
// `unplaceable` when a step cannot be placed), and the caller refuses BEFORE the swap with the typing kept.

import { isolateHistory } from '@codemirror/commands';
import {
  Annotation,
  ChangeSet,
  EditorSelection,
  type EditorState,
  type Text,
  Transaction,
  type TransactionSpec,
} from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { derivedCorrection } from './derived-correction';
import type { MovedRange } from './redo-branch';
import { computeRefinedChanges } from './text-diff';

// === Vocabulary ===

/** What the re-check decided about the typing done since a press. The ONE trace-line format uses exactly these words. */
export type TypingDecision = 'rebased' | 'matched' | 'unplaceable' | 'changed' | 'noEntry' | 'midOp';

/**
 * Marks a dispatch of the app's OWN that is the user's typing although it carries no `userEvent`: the smart-quote curling
 * (smart-quotes-plugin.ts, both `view.dispatch` calls), the spell-check replacement (spellcheck-plugin.ts `onReplace`, three places)
 * and, through `dispatchAsTyping`, the user's commands (toolbar formats, slash menu, table commands, inserts). All of them carry the mark
 * today. A dispatch that is NOT marked and has no `input*`/`delete*`/`move*` userEvent counts as a change that is not typing: the
 * collector commutes it out of the way, and a press that meets one it cannot place refuses (`changed`), which is the safe side.
 */
export const typingDispatch = Annotation.define<boolean>();

/** Tags the replay transactions themselves, so the collector and `maybeNotifyHistoryEdited` can tell them from the user's typing. */
export const typingReplay = Annotation.define<boolean>();

/** True for a transaction that is the user's typing: `input*`, `delete*` or `move*`, or an app dispatch marked `typingDispatch`. Programmatic
 * pushes (`addToHistory: false`), derived corrections and history replays are never typing. */
export function isTypingTransaction(tr: Transaction): boolean {
  if (!tr.docChanged) return false;
  if (tr.annotation(Transaction.addToHistory) === false) return false;
  if (tr.annotation(derivedCorrection)) return false;
  if (tr.isUserEvent('undo') || tr.isUserEvent('redo')) return false;
  return (
    tr.isUserEvent('input') ||
    tr.isUserEvent('delete') ||
    tr.isUserEvent('move') ||
    tr.annotation(typingDispatch) === true
  );
}

/** The ONE trace line both editors and the Swift UI tests use. `steps` is the number of changes recorded since the press (or the list). */
export function formatTypingSincePressLine(
  press: number,
  steps: number | readonly unknown[],
  decision: TypingDecision
): string {
  const count = typeof steps === 'number' ? steps : steps.length;
  return `typing-since-press press=${press} steps=${count} decision=${decision}`;
}

// === 1. The collector ===

/** One change recorded since a press. `changes` is written against the document just before it; `inverse` undoes it. */
export interface TypingStep {
  /** The number of the latest press at or before this change. It survives the rebase: a mapped step keeps its tag. */
  tag: number;
  changes: ChangeSet;
  inverse: ChangeSet;
  /** False for any change that is not the user's typing (an automatic rewrite): the decision is then `changed`. */
  typing: boolean;
}

export class TypingCollector {
  private steps: TypingStep[] = [];
  private tag: number | null = null;

  /** A press was latched or queued: recording starts (if it has not) and every later change carries `seq`. */
  startPress(seq: number): void {
    this.tag = seq;
  }

  get recording(): boolean {
    return this.tag !== null;
  }

  /** Call for every transaction of the view while recording. A transaction that changes nothing, and the replay itself, are ignored. */
  record(tr: Transaction): void {
    if (this.tag === null || !tr.docChanged || tr.annotation(typingReplay) === true) return;
    this.steps.push({
      tag: this.tag,
      changes: tr.changes,
      inverse: tr.changes.invert(tr.startState.doc),
      typing: isTypingTransaction(tr),
    });
  }

  /** Every change made at or after `press`, oldest first. */
  stepsSince(press: number): readonly TypingStep[] {
    return this.steps.filter((step) => step.tag >= press);
  }

  /** After the replay of `press`: its own records are spent; the records of LATER presses are replaced by the rebased steps, which are
   * written against the document now on the screen (so the next held press builds its document-at-press from them). */
  adoptReplay(press: number, rebased: readonly TypingStep[]): void {
    this.steps = rebased.filter((step) => step.tag > press);
  }

  /** Forgets everything and stops recording. Called on every exit of the press (answered, refused, cancelled, failed, timed out). */
  reset(): void {
    this.steps = [];
    this.tag = null;
  }
}

// === 2. The document at the press ===

export interface PressDoc {
  /** The document as it was at the press WITH the automatic changes made since (a settle's Notes / bibliography replace, a derived push, a
   * footnote renumber) applied in their original order and mapped back past the typing; the LIVE document when `decision` is `changed`
   * (so the routing refuses as it does today). */
  doc: Text;
  /** `matched`/`changed` with no typing: every change recorded since the press. `rebased`: the TYPING changes only, written against
   * `doc` (the replay's input); the automatic ones are part of `doc`. */
  steps: readonly TypingStep[];
  /** How many automatic (non-typing) changes were commuted in front of the typing. 0 unless `decision` is `rebased`. */
  automatic: number;
  /** `matched`: nothing changed since. `rebased`: typing changed the document (a candidate: the routing and the dry run still decide).
   * `changed`: automatic changes only, or an automatic change could not be mapped back past the typing (typing inside text a later
   * automatic change replaced), or the inversion failed. */
  decision: 'matched' | 'rebased' | 'changed';
}

/**
 * Moves every AUTOMATIC change in front of the typing, collab-style: each automatic change is written against the document after the typing
 * recorded before it; it is mapped back through the inverses of those typing changes (last first) and the typing changes are mapped over it,
 * so the typing comes after. The result is `base` (the document at the press plus the automatic changes, in their original order) and the
 * typing, rebased onto it. The whole rebuild is CHECKED: `base` with the rebased typing applied must be the live document, otherwise
 * (typing inside text a later automatic change replaced, an ordering the maps cannot tell apart) the answer is null.
 */
function commuteAutomatic(
  liveDoc: Text,
  steps: readonly TypingStep[],
  typingBefore: boolean
): { base: Text; typing: TypingStep[] } | null {
  try {
    let base = liveDoc;
    for (let i = steps.length - 1; i >= 0; i--) base = steps[i].inverse.apply(base); // the document at the press, every change undone
    const chain: Array<{ tag: number; changes: ChangeSet }> = [];
    for (const step of steps) {
      if (step.typing) {
        chain.push({ tag: step.tag, changes: step.changes });
        continue;
      }
      const docs: Text[] = [base]; // docs[j]: the document before chain[j]
      for (const link of chain) docs.push(link.changes.apply(docs[docs.length - 1]));
      let automatic = step.changes; // written against docs[chain.length]
      for (let j = chain.length - 1; j >= 0; j--) {
        const back = chain[j].changes.invert(docs[j]); // docs[j + 1] -> docs[j]
        automatic = automatic.map(back); // now against docs[j]
        chain[j] = { tag: chain[j].tag, changes: chain[j].changes.map(automatic, typingBefore) }; // the typing, after it
      }
      base = automatic.apply(base);
    }
    let check = base;
    for (const link of chain) check = link.changes.apply(check);
    if (!check.eq(liveDoc)) return null;
    const typing: TypingStep[] = [];
    let doc = base;
    for (const link of chain) {
      typing.push({ tag: link.tag, changes: link.changes, inverse: link.changes.invert(doc), typing: true });
      doc = link.changes.apply(doc);
    }
    return { base, typing };
  } catch {
    return null;
  }
}

/**
 * The document as it was at `press`. Typing alone: every change inverted. Typing mixed with AUTOMATIC changes (the dominant order on a
 * book: the Cmd-Z waits for the earlier command's settle, whose rewrites land after the user's typing): the automatic changes are
 * commuted in front of the typing (`commuteAutomatic`), so the document returned already carries them, as the saved copy does (exactly
 * when the copy advanced over them, or modulo what the app regenerates through the routing's fallback comparison). An automatic change is
 * NEVER counted as typing (that would put its text in the replay and duplicate it). Automatic changes alone, a commute that does not hold
 * (typing inside text a later automatic change replaced) or any failure: the live document with `changed`.
 */
export function docAtPress(liveDoc: Text, collector: TypingCollector, press: number): PressDoc {
  const steps = collector.stepsSince(press);
  if (steps.length === 0) return { doc: liveDoc, steps, automatic: 0, decision: 'matched' };
  const typingSteps = steps.filter((step) => step.typing);
  if (typingSteps.length === 0) return { doc: liveDoc, steps, automatic: 0, decision: 'changed' };
  try {
    if (typingSteps.length === steps.length) {
      let doc = liveDoc;
      for (let i = steps.length - 1; i >= 0; i--) doc = steps[i].inverse.apply(doc);
      return { doc, steps, automatic: 0, decision: 'rebased' };
    }
    const commuted = commuteAutomatic(liveDoc, steps, false) ?? commuteAutomatic(liveDoc, steps, true);
    if (commuted === null)
      return { doc: liveDoc, steps, automatic: steps.length - typingSteps.length, decision: 'changed' };
    return {
      doc: commuted.base,
      steps: commuted.typing,
      automatic: steps.length - typingSteps.length,
      decision: 'rebased',
    };
  } catch {
    return { doc: liveDoc, steps, automatic: 0, decision: 'changed' };
  }
}

/**
 * Dispatches a user COMMAND (a toolbar format, a slash-menu insert, a table command) as the user's typing: the same `view.dispatch`, with
 * the `typingDispatch` mark. These commands carry no `userEvent`, and unmarked they would make a Cmd-Z that waits `changed` (a refusal that
 * ordinary use reaches: Cmd-Z, then a click on Bold). Automatic changes are never sent through here.
 */
export function dispatchAsTyping(view: EditorView, spec: TransactionSpec): void {
  const marks =
    spec.annotations === undefined ? [] : Array.isArray(spec.annotations) ? spec.annotations : [spec.annotations];
  view.dispatch({ ...spec, annotations: [...marks, typingDispatch.of(true)] });
}

// === 3. Over: the document at the press -> the swap target ===

/** What the translation of a dragged chapter holds: where the chapter is in D0, where its source text is in T, and the small diff between. */
export interface Translation {
  from: number;
  to: number;
  dst: number;
  dstEnd: number;
  /** The diff movedText -> sourceText, in offsets of the moved text: absorbs the heading levels the drop rewrote. */
  local: ChangeSet;
}

type Kind = 'moved' | 'gone' | 'other';

const refinedBetween = (from: Text, to: Text): ChangeSet =>
  ChangeSet.of(computeRefinedChanges(from.toString(), to.toString()), from.length);

export class Over {
  /** The ranges of D0 that the undo removes with nothing in their place (a duplicate's copy, an inserted section). */
  readonly gone: MovedRange[] = [];

  constructor(
    readonly d0: Text,
    readonly target: Text,
    /** D0 -> T, monotone: the carry change set (redo-branch.ts). */
    readonly changes: ChangeSet,
    readonly translation: Translation | null
  ) {
    changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
      if (toA > fromA && inserted.length === 0) this.gone.push({ from: fromA, to: toA });
    });
  }

  /** What a position of D0 is. An insertion point or a start is in a range from its first position to just before its end; the END of a
   * deletion is in a range from just after its start to its end. */
  classify(pos: number, asEnd: boolean): Kind {
    const inside = (range: MovedRange): boolean =>
      asEnd ? pos > range.from && pos <= range.to : pos >= range.from && pos < range.to;
    if (this.translation && inside(this.translation)) return 'moved';
    if (this.gone.some(inside)) return 'gone';
    return 'other';
  }

  /** The position of D0 in T. `assoc` 1 for an insertion point or a start, -1 for the end of a deletion. */
  mapPos(pos: number, assoc: -1 | 1): number {
    const t = this.translation;
    if (t && (assoc < 0 ? pos > t.from && pos <= t.to : pos >= t.from && pos < t.to)) {
      return t.dst + t.local.mapPos(pos - t.from, assoc);
    }
    return this.changes.mapPos(pos, assoc);
  }
}

/** What `buildOver` needs of a registry entry and of the two documents. */
export interface OverInput {
  /** `undo` (the default): the swap installs the checkpoint. `redo`: the composed redo (`composedRedo`) or the saved-copy swap. */
  direction?: 'undo' | 'redo';
  /** The document at the press. */
  d0: Text;
  /** The document the swap lands on: the checkpoint's document (undo) or the entry's saved post-op document (redo). */
  target: Text;
  /** The entry's checkpoint document (the pre-op document). */
  checkpointDoc: Text;
  /** The change set the command applied (`entry.markdown.opChanges`); absent for an entry the old body recorded. */
  opChanges?: ChangeSet;
  /** The moved text of a REORDER entry, in the document the command produced (`entry.markdown.moved`); absent for every other kind. */
  moved?: MovedRange | null;
}

/**
 * The translation of a dragged chapter: `moved` (drag-end coordinates) is mapped into press coordinates through the churn (the same
 * construction as redo-branch.ts's `back.mapPos`), the source range in T is the deletion of `opChanges` that removes the run (its
 * insertion is blank: the separators), and the two texts are compared by `computeRefinedChanges`. Null when the source cannot be found.
 */
function movedTranslation(
  d0: Text,
  churn: ChangeSet | null,
  opChanges: ChangeSet,
  checkpointDoc: Text,
  moved: MovedRange
): Translation | null {
  const back = churn ? churn.invert(d0) : null; // produced -> D0
  const from = back ? back.mapPos(moved.from, 1) : moved.from;
  const to = back ? back.mapPos(moved.to, -1) : moved.to;
  if (to <= from) return null;
  const source = removedRun(opChanges);
  if (!source) return null;
  const movedText = d0.sliceString(from, to);
  const sourceText = checkpointDoc.sliceString(source.from, source.to);
  const local = ChangeSet.of(computeRefinedChanges(movedText, sourceText), movedText.length);
  return { from, to, dst: source.from, dstEnd: source.to, local };
}

/** The run a reorder's `opChanges` removes (checkpoint coordinates): the biggest deletion whose insertion is blank (the separators). */
function removedRun(opChanges: ChangeSet): MovedRange | null {
  const found: MovedRange[] = [];
  opChanges.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    if (toA <= fromA || inserted.toString().trim() !== '') return;
    if (found.length === 0 || toA - fromA > found[0].to - found[0].from) found[0] = { from: fromA, to: toA };
  });
  return found[0] ?? null;
}

/** The REDO of a drag: the chapter is in its source place in D0 (= the checkpoint document); `moved` (in the produced document) is mapped
 * through the settle into T. Typing inside the chapter's source text goes with it to its destination. */
function redoTranslation(
  d0: Text,
  target: Text,
  opChanges: ChangeSet,
  settle: ChangeSet,
  moved: MovedRange
): Translation | null {
  const source = removedRun(opChanges);
  if (!source) return null;
  const dst = settle.mapPos(moved.from, 1);
  const dstEnd = settle.mapPos(moved.to, -1);
  if (dstEnd <= dst) return null;
  const local = ChangeSet.of(
    computeRefinedChanges(d0.sliceString(source.from, source.to), target.sliceString(dst, dstEnd)),
    source.to - source.from
  );
  return { from: source.from, to: source.to, dst, dstEnd, local };
}

/**
 * The map from D0 to T for an UNDO: `churn.compose(opChanges.invert(checkpoint))` (the carry of redo-branch.ts, with D0 in the place of the
 * live document), checked to turn D0 into T; the diff between the two documents otherwise (an entry the old body recorded has no
 * `opChanges`). A REORDER adds the translation of the dragged chapter; if that cannot be built the answer is null (the caller refuses, typing
 * kept). Null on any failure.
 *
 * A REDO (`direction: 'redo'`, `target` = the entry's saved post-op document): when D0 is the checkpoint document, `opChanges` composed with
 * the settle (exactly `composedRedo`'s change set) and, for a drag, the translation of the chapter from its source place to the new one;
 * otherwise the diff D0 -> target (`swapRedoFromSavedCopy`), with no translation.
 */
export function buildOver(input: OverInput): Over | null {
  try {
    const { d0, target, checkpointDoc, opChanges, moved } = input;
    let changes: ChangeSet | null = null;
    let translation: Translation | null = null;
    if (opChanges && input.direction === 'redo') {
      if (d0.eq(checkpointDoc)) {
        const produced = opChanges.apply(checkpointDoc);
        const settle = refinedBetween(produced, target);
        changes = settle.empty ? opChanges : opChanges.compose(settle);
        if (moved && moved.to > moved.from) {
          translation = redoTranslation(d0, target, opChanges, settle, moved);
          if (translation === null) return null;
        }
      }
    } else if (opChanges) {
      const produced = opChanges.apply(checkpointDoc);
      const churn = d0.eq(produced) ? null : refinedBetween(d0, produced);
      const inverse = opChanges.invert(checkpointDoc);
      changes = churn ? churn.compose(inverse) : inverse;
      if (moved && moved.to > moved.from) {
        if (!target.eq(checkpointDoc)) return null;
        translation = movedTranslation(d0, churn, opChanges, checkpointDoc, moved);
        if (translation === null) return null;
      }
    }
    if (changes === null || !changes.apply(d0).eq(target)) changes = refinedBetween(d0, target);
    return new Over(d0, target, changes, translation);
  } catch {
    return null;
  }
}

// === 4. The rebase ===

class Unplaceable extends Error {}

/** Text a step typed that was placed in T: where it starts in the document at that step, how long it is, where its copy starts in T. */
interface Run {
  from: number;
  len: number;
  toT: number;
}

interface Stage {
  /** The document after the step -> the document before it. */
  inv: ChangeSet;
  /** T before the step -> T after it (the rebased step). */
  fwd: ChangeSet;
  runs: Run[];
}

class Chain {
  readonly stages: Stage[] = [];

  constructor(readonly over: Over) {}

  /** The run of `stage` the position touches (both edges count), the later one for assoc 1 when two runs touch. */
  private runAt(stage: Stage, pos: number, assoc: -1 | 1): Run | null {
    let hit: Run | null = null;
    for (const run of stage.runs) {
      if (pos < run.from || pos > run.from + run.len) continue;
      if (hit === null || assoc > 0) hit = run;
    }
    return hit;
  }

  /** A position of the document after the last step -> T after the last rebased step. */
  mapPos(pos: number, assoc: -1 | 1, upTo: number = this.stages.length): number {
    if (upTo === 0) return this.over.mapPos(pos, assoc);
    const stage = this.stages[upTo - 1];
    const run = this.runAt(stage, pos, assoc);
    if (run) return run.toT + (pos - run.from);
    return stage.fwd.mapPos(this.mapPos(stage.inv.mapPos(pos, assoc), assoc, upTo - 1), assoc);
  }

  /** The position in D0, or null when it lies inside text an earlier step typed. */
  baseOf(pos: number, assoc: -1 | 1): number | null {
    let p = pos;
    for (let k = this.stages.length; k >= 1; k--) {
      const stage = this.stages[k - 1];
      if (this.runAt(stage, p, assoc)) return null;
      p = stage.inv.mapPos(p, assoc);
    }
    return p;
  }
}

interface Edit {
  from: number;
  to: number;
  /** Where the inserted text starts in the document after the step. */
  newFrom: number;
  insert: string;
}

/** One edit placed on T. `lead` and `coreLen` locate the typed text inside `insert` (the own-line rule trims newlines and adds padding). */
interface Placement {
  from: number;
  to: number;
  insert: string;
  lead: number;
  coreLen: number;
  padLeft: number;
}

function editsOf(changes: ChangeSet): Edit[] {
  const edits: Edit[] = [];
  changes.iterChanges((from, to, newFrom, _toB, inserted) => {
    edits.push({ from, to, newFrom, insert: inserted.toString() });
  });
  return edits;
}

const plain = (from: number, to: number, insert: string): Placement => ({
  from,
  to,
  insert,
  lead: 0,
  coreLen: insert.length,
  padLeft: 0,
});

/** The edge rule for letters typed in text that is gone: their own line at the gap `at`, a blank line before and after. Null for nothing but
 * blank characters (nothing the user would miss). */
function ownLine(text: string, at: number, tDoc: Text): Placement | null {
  const core = text.replace(/^\n+/, '').replace(/\n+$/, '');
  if (core.trim() === '') return null;
  const lead = text.length - text.replace(/^\n+/, '').length;
  const before = tDoc.sliceString(Math.max(0, at - 2), at);
  const after = tDoc.sliceString(at, Math.min(tDoc.length, at + 2));
  let prefix = '\n\n';
  if (at === 0 || before === '\n\n') prefix = '';
  else if (before.endsWith('\n')) prefix = '\n';
  let suffix = '\n\n';
  if (at === tDoc.length || after === '\n\n') suffix = '';
  else if (after.startsWith('\n')) suffix = '\n';
  return { from: at, to: at, insert: `${prefix}${core}${suffix}`, lead, coreLen: core.length, padLeft: prefix.length };
}

function placeEdit(edit: Edit, chain: Chain, over: Over, tDoc: Text): Placement | null {
  const { from, to, insert } = edit;
  const baseFrom = chain.baseOf(from, 1);
  const kindFrom: Kind | null = baseFrom === null ? null : over.classify(baseFrom, false);
  if (to === from) {
    if (insert === '') return null;
    const at = chain.mapPos(from, 1);
    return kindFrom === 'gone' ? ownLine(insert, at, tDoc) : plain(at, at, insert);
  }
  const baseTo = chain.baseOf(to, -1);
  const kindTo: Kind | null = baseTo === null ? null : over.classify(baseTo, true);
  if (kindFrom === 'gone' && kindTo === 'gone') {
    // The text it deleted is gone with the undo; what it typed over that text is still put back, on its own line.
    return insert === '' ? null : ownLine(insert, chain.mapPos(from, 1), tDoc);
  }
  if (kindFrom !== null && kindTo !== null && kindFrom !== kindTo) {
    throw new Unplaceable(`a deletion starts in ${kindFrom} text and ends in ${kindTo} text`);
  }
  const t = over.translation;
  if (t && baseFrom !== null && baseTo !== null && kindFrom === 'other' && baseFrom <= t.from && baseTo >= t.to) {
    throw new Unplaceable('a deletion spans the dragged chapter');
  }
  const start = chain.mapPos(from, 1);
  const end = Math.max(start, chain.mapPos(to, -1));
  if (start === end && insert === '') return null;
  return plain(start, end, insert);
}

interface Rebased {
  /** The steps written against T (tags kept), for the collector's `adoptReplay` and the replay. */
  steps: TypingStep[];
  /** T with every rebased step applied. */
  tDoc: Text;
  chain: Chain;
}

function rebaseSteps(over: Over, steps: readonly TypingStep[]): Rebased {
  const chain = new Chain(over);
  let docPrev = over.d0;
  let tPrev = over.target;
  const out: TypingStep[] = [];
  for (const step of steps) {
    const placed: Array<{ placement: Placement; newFrom: number; origLen: number }> = [];
    for (const edit of editsOf(step.changes)) {
      const placement = placeEdit(edit, chain, over, tPrev);
      if (placement) placed.push({ placement, newFrom: edit.newFrom, origLen: edit.insert.length });
    }
    placed.sort((a, b) => a.placement.from - b.placement.from || a.placement.to - b.placement.to);
    for (let i = 1; i < placed.length; i++) {
      if (placed[i].placement.from < placed[i - 1].placement.to)
        throw new Unplaceable('two typed changes overlap once placed');
    }
    const fwd = ChangeSet.of(
      placed.map(({ placement }) => ({ from: placement.from, to: placement.to, insert: placement.insert })),
      tPrev.length
    );
    const runs: Run[] = [];
    let delta = 0;
    for (const { placement, newFrom, origLen } of placed) {
      if (origLen > 0 && placement.coreLen > 0) {
        runs.push({
          from: newFrom + placement.lead,
          len: placement.coreLen,
          toT: placement.from + delta + placement.padLeft,
        });
      }
      delta += placement.insert.length - (placement.to - placement.from);
    }
    chain.stages.push({ inv: step.inverse, fwd, runs });
    out.push({ tag: step.tag, changes: fwd, inverse: fwd.invert(tPrev), typing: true });
    docPrev = step.changes.apply(docPrev);
    tPrev = fwd.apply(tPrev);
  }
  return { steps: out, tDoc: tPrev, chain };
}

// === 5. The dry run and the guarded swap ===

export interface ReplayInput {
  /** The state the swap installs (its document is T; the dry run goes through its transaction filters and history). */
  targetState: EditorState;
  over: Over;
  /** Every change since the press, oldest first (`docAtPress(...).steps`); all of them typing. */
  steps: readonly TypingStep[];
  /** The live selection, in the live document: the caret after the replay is this, mapped through the rebase. */
  liveSelection: EditorSelection;
}

export type ReplayPlan =
  | {
      ok: true;
      decision: 'rebased' | 'matched';
      /** One transaction spec per press segment, in order; dispatch them one after the other. The last one sets the selection. */
      replaySpecs: TransactionSpec[];
      /** The target state with every spec applied: the document the real dispatch must produce. */
      dryState: EditorState;
      /** The steps written against the document the replay leaves on the screen: pass to `TypingCollector.adoptReplay`. */
      rebasedSteps: TypingStep[];
      selection: EditorSelection;
    }
  | { ok: false; decision: 'unplaceable'; reason: string };

/** The caret after the replay: the live selection mapped through the rebase (a caret at the end of typed text ends right after its copy). */
function mappedSelection(rebased: Rebased, live: EditorSelection): EditorSelection {
  const max = rebased.tDoc.length;
  const clamp = (pos: number): number => Math.max(0, Math.min(max, pos));
  return EditorSelection.create(
    live.ranges.map((range) =>
      EditorSelection.range(clamp(rebased.chain.mapPos(range.anchor, 1)), clamp(rebased.chain.mapPos(range.head, 1)))
    ),
    live.mainIndex
  );
}

/**
 * Builds the replay against T and applies it to a throwaway copy of the target state. `ok` only if every change was placed and the document
 * the specs produce on the target state (through its filters) is the one the rebase computed. The specs are what the page will dispatch;
 * afterwards it asserts `view.state.doc.eq(dryState.doc)`. Never throws.
 */
export function buildReplayDryRun(input: ReplayInput): ReplayPlan {
  try {
    const { targetState, over, steps, liveSelection } = input;
    if (!targetState.doc.eq(over.target))
      return { ok: false, decision: 'unplaceable', reason: 'the target state is not the target document' };
    if (steps.length === 0) {
      return {
        ok: true,
        decision: 'matched',
        replaySpecs: [],
        dryState: targetState,
        rebasedSteps: [],
        selection: targetState.selection,
      };
    }
    const rebased = rebaseSteps(over, steps);
    const selection = mappedSelection(rebased, liveSelection);

    // One history event per press segment: consecutive steps with the same tag are one transaction, isolated from what is before it.
    const groups: Array<{ tag: number; changes: ChangeSet }> = [];
    for (const step of rebased.steps) {
      const last = groups[groups.length - 1];
      if (last && last.tag === step.tag) last.changes = last.changes.compose(step.changes);
      else groups.push({ tag: step.tag, changes: step.changes });
    }
    const replaySpecs: TransactionSpec[] = groups.map((group, index) => ({
      changes: group.changes,
      selection: index === groups.length - 1 ? selection : undefined,
      annotations: [typingReplay.of(true), isolateHistory.of('before')],
    }));

    let dryState = targetState;
    for (const spec of replaySpecs) dryState = dryState.update(spec).state;
    if (!dryState.doc.eq(rebased.tDoc))
      return { ok: false, decision: 'unplaceable', reason: 'a filter changed the replay' };
    return { ok: true, decision: 'rebased', replaySpecs, dryState, rebasedSteps: rebased.steps, selection };
  } catch (error) {
    return { ok: false, decision: 'unplaceable', reason: error instanceof Error ? error.message : String(error) };
  }
}

export interface SwapReplayResult {
  ok: boolean;
  decision: TypingDecision;
  steps: number;
  reason?: string;
  /** For `TypingCollector.adoptReplay` when `ok`. */
  rebasedSteps?: TypingStep[];
}

/**
 * The swap and the replay as one guarded block. The dry run comes first: if it fails nothing has been touched (the document is the live
 * document, the typing is kept) and the answer is `unplaceable`. Otherwise `install` puts the target state on the view, the specs are
 * dispatched, and the page asserts the document is the dry run's; on any throw or mismatch the state from before the swap is installed again
 * and the answer is `unplaceable`. No half-applied state either way. `afterInstall` runs between the install and the replay.
 */
export function swapWithReplay(
  view: EditorView,
  input: ReplayInput,
  install: (state: EditorState) => void,
  afterInstall?: () => void
): SwapReplayResult {
  const plan = buildReplayDryRun(input);
  const steps = input.steps.length;
  if (!plan.ok) return { ok: false, decision: 'unplaceable', steps, reason: plan.reason };
  const stateBefore = view.state;
  try {
    install(input.targetState);
    afterInstall?.(); // the swapped-in text, read before the replay (the writer baseline Swift adopts)
    for (const spec of plan.replaySpecs) view.dispatch(spec);
    if (!view.state.doc.eq(plan.dryState.doc)) throw new Error('the replay did not produce the dry-run document');
  } catch (error) {
    try {
      install(stateBefore);
    } catch {
      // Nothing more can be done; the caller's own guard reports the failed swap.
    }
    return {
      ok: false,
      decision: 'unplaceable',
      steps,
      reason: error instanceof Error ? error.message : String(error),
    };
  }
  return { ok: true, decision: plan.decision, steps, rebasedSteps: plan.rebasedSteps };
}
