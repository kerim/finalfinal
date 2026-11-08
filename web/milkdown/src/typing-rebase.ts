// Typing done while a Cmd-Z waits -- the pure layer (Phase 4c, job 2, t-d2061b27), Rich Text half.
//
// A Cmd-Z (or Cmd-Shift-Z) that waits behind a section command must keep waiting when the user types, and then run on the document
// AS IT WAS WHEN THE KEY WAS PRESSED, with the typing done meanwhile put back on top, where it was typed. This file is the layer that
// knows how: no editor and no Swift in here; the routes (api-structural-swap.ts, api-section-undo.ts) and the coordinator
// (undo-coordinator.ts) call it. Plan: plan-v2.md (M-1 to M-6) and
// plan-v2-amendments.md (1, 2, 5, 7, 9; judge round 3 D2, D3), in .claude/superdev/cmdz-waits-through-typing/.
//
// Pieces, in the order a route uses them:
//   (a) `TypingCollector` records the steps of EVERY document-changing transaction from the moment a press latches or queues. Each step
//       carries a tag (the sequence number of the latest press at or before it, kept through rebasing), its inverse, and whether it is
//       typing: a real user edit, or a transaction appended to one (`appendedTransaction` names a typing root).
//   (b) `docAtPress` inverts ALL steps since the press (typing or not) on the live document. Any failure returns the live document, and
//       `inspectPress` then says `changed` (a safe refusal).
//   (c) `BlockwiseMapping` is the "Over" map from the document at the press (with its block ids) to the target document (with its
//       ids). Top-level blocks are matched by id, in ANY order, so a moved chapter's positions move with it. Inside a matched block
//       positions go through a common-prefix/suffix diff of the block's content; a position inside the changed run goes to the run's
//       edge. A block the target does not hold is gone. `syncNode` is NOT reused: it replaces a differing text node whole and collapses
//       positions.
//   (d) `rebaseTypingSteps` is prosemirror-collab's rebase with Over as one segment of the chain (there is no `rebaseSteps` in
//       @milkdown/prose 7.18.0): C = [inv(sn).map ... inv(s1).map, Over, s1'.map ...]; step i is mapped through C restricted to
//       inv(s_i-1) ... inv(s1), Over, s1' ... s_i-1'; every placed step is mirrored with its inverse, so a position inside text typed
//       earlier is recovered into the rebased text. Enter-made blocks need no id: the split maps into its block's counterpart.
//   (e) The edge rule (the judge's ruling): if the block that held the typing survives with changed content (a restore), the letters go
//       INSIDE that block at the edge of the changed run (mid-sentence accepted). If the block is gone (a duplicate's copy), typing in it
//       becomes its OWN PARAGRAPH at the gap where the block was ("ghost" paragraph, made first, so the typed letters then follow the
//       ordinary route and stay in one paragraph); a deletion there is a no-op. A step the chain cannot place -> `unplaceable`.
//   (f) `buildReplayDryRun` builds the replay as real transactions on the TARGET state and applies them there first
//       (`targetState.applyTransaction`, so appended transactions and filters are included). It fails when a replay is missing from
//       `dry.transactions`, a step did not place, or a plugin changed the replayed document. Nothing live is touched on any path.
//       The replay carries the live selection mapped through the rebase (caret rule), closes the history before every press segment
//       (one history event per press segment) and is tagged `typingReplay`.
//   (g) `formatTypingSincePressLine` is the one trace-line format both editors and the Swift UI tests use.
//
// What the caller must know (round 2): the dry run executes every plugin's `state.apply` on a throwaway state. block-id-plugin's
// `apply` reassigns the module-level id maps and block-sync-plugin's `apply` snapshots and arms its timer unless block-sync is paused,
// so `containPluginSideEffects` (the default `contain`) pauses block-sync, restores the id maps from a copy and re-points the live
// state's plugin state at them. `recentlySplitEmptyIds` may gain a marker for a dead temp id (harmless: the marker names that id only).
// The collector skips `typingReplay` transactions (the replay is adopted with `TypingCollector.adoptRebased`, not recorded twice).

import { closeHistory } from '@milkdown/kit/prose/history';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import {
  type EditorState,
  Plugin,
  PluginKey,
  Selection,
  TextSelection,
  type Transaction,
} from '@milkdown/kit/prose/state';
import {
  AddMarkStep,
  AttrStep,
  Mapping,
  RemoveMarkStep,
  ReplaceAroundStep,
  ReplaceStep,
  type Step,
  type StepMap,
  Transform,
} from '@milkdown/kit/prose/transform';
import { getAllBlockIds, getAllBlockTypes, pointPluginStateAtLiveIds, restoreBlockIdMaps } from './block-id-plugin';
import { setSyncPaused } from './block-sync-plugin';
import { isRealUserEditTransaction } from './undo-coordinator';

// === (g) The trace line ===

export type TypingDecision = 'rebased' | 'matched' | 'unplaceable' | 'changed' | 'noEntry' | 'midOp' | 'noIdMap';

/** The one trace line both editors write at the re-check, whatever the outcome (`matched` = no typing since the press, `rebased` =
 * typing taken out and put back). The Swift UI tests read exactly this text through the structural trace channel. */
export function formatTypingSincePressLine(press: number, steps: number, decision: TypingDecision): string {
  return `typing-since-press press=${press} steps=${steps} decision=${decision}`;
}

// === (a) The collector ===

/** One step of a transaction since a press. `tag` survives rebasing: a mapped step keeps the tag of the step it came from. */
export interface RecordedStep {
  step: Step;
  /** The step that takes `step` back out (`step.invert(docBefore)`), kept so the document at a press can be rebuilt from the live one. */
  inverted: Step;
  /** The sequence number of the latest press at or before this step. */
  tag: number;
  /** True for the user's typing; false for any other change (a derived rewrite, a push), which makes the decision `changed`. */
  typing: boolean;
}

export type PressKind = 'matched' | 'typing' | 'changed';

export class TypingCollector {
  private active = false;
  private latestPress = 0;
  private readonly idsByPress = new Map<number, ReadonlyMap<number, string>>();
  private recorded: RecordedStep[] = [];
  private readonly typingRoots = new WeakSet<Transaction>();
  private chainRoot: Transaction | null = null;
  private stamp = 0;

  /** The typing transaction whose dispatch is running right now (`runUndoTrackedDispatch` sets it for the outermost dispatch and
   * clears it after): whatever is dispatched from inside it follows it. */
  setChainRoot(root: Transaction | null): void {
    this.chainRoot = root;
  }

  /** True from the first `startPress` until `reset`. */
  get isRecording(): boolean {
    return this.active;
  }

  /** A press latched (`requestStructural`) or queued (`queuePress`): from here on every step is recorded with this press's number.
   * `idsAtPress` is `getAllBlockIds()` read at this moment: top-level offset -> block id, for the document as it is now. */
  startPress(press: number, idsAtPress: ReadonlyMap<number, string>): void {
    this.active = true;
    this.latestPress = press;
    this.idsByPress.set(press, new Map(idsAtPress));
  }

  /** Records the steps of one transaction (call it for EVERY transaction, appended ones included: a plugin's `state.apply` sees
   * them all, `createTypingCollectorPlugin` below). Replay transactions are skipped: the replay is adopted, not recorded. */
  record(tr: Transaction): void {
    if (!this.active || !tr.docChanged) return;
    // A transaction appended to another, or dispatched from inside the dispatch of a typing transaction (Milkdown rewrites a heading's
    // id after each keystroke that way), belongs to the transaction it follows.
    const root = (tr.getMeta('appendedTransaction') as Transaction | undefined) ?? this.chainRoot ?? undefined;
    if (tr.getMeta('typingReplay') || root?.getMeta('typingReplay')) return;
    // Typing: a real user edit (input rules, autocorrect, spellcheck replacement and Enter included), or a transaction appended to one.
    const typing = isRealUserEditTransaction(tr) || (root !== undefined && this.typingRoots.has(root));
    if (typing) this.typingRoots.add(tr);
    for (let index = 0; index < tr.steps.length; index++) {
      const step = tr.steps[index];
      this.recorded.push({ step, inverted: step.invert(tr.docs[index]), tag: this.latestPress, typing });
    }
    this.stamp++;
  }

  /** Every step with a tag of `press` or later, oldest first. */
  stepsSince(press: number): RecordedStep[] {
    return this.recorded.filter((recorded) => recorded.tag >= press);
  }

  idsAtPress(press: number): ReadonlyMap<number, string> | undefined {
    return this.idsByPress.get(press);
  }

  /** Changes whenever the records do (a cache key for `commutePress`). */
  get version(): number {
    return this.stamp;
  }

  /** After a replay: the records of every step since `press` are replaced by the rebased steps (current coordinates, original tags),
   * so a held press that comes later still rebuilds its document from the live one. Earlier records stay. */
  adoptRebased(press: number, rebased: readonly RecordedStep[]): void {
    this.stamp++;
    this.recorded = [
      ...this.recorded.filter((recorded) => recorded.tag < press),
      ...rebased.map(({ step, inverted, tag, typing }) => ({ step, inverted, tag, typing })),
    ];
  }

  /** The block ids of a press whose coordinates moved (a replay renumbered the document): the caller maps them. */
  setIdsAtPress(press: number, ids: ReadonlyMap<number, string>): void {
    this.idsByPress.set(press, new Map(ids));
  }

  /** The press was answered. */
  dropPress(press: number): void {
    this.idsByPress.delete(press);
  }

  /** Every exit: releaseLatchAndQueue, resetUndoCoordinatorState, a barrier clear, the 30 s timeout, `cancelled`, `failed`. */
  reset(): void {
    this.active = false;
    this.latestPress = 0;
    this.idsByPress.clear();
    this.recorded = [];
    this.stamp++;
  }
}

/** A ProseMirror plugin that feeds a collector. A plugin's `state.apply` is called for every transaction in order, appended ones
 * included, which a `view.dispatch` override would not see. */
export function createTypingCollectorPlugin(collector: TypingCollector): Plugin {
  return new Plugin({
    key: new PluginKey('typing-collector'),
    state: {
      init: () => null,
      apply(tr) {
        collector.record(tr);
        return null;
      },
    },
  });
}

// === (b) The document at the press ===

/** The document as it was when `press` was made: the live document with ALL steps since then inverted, typing or not. Any failure
 * (a step that does not invert) returns the live document and `ok: false`. */
export function docAtPress(
  collector: TypingCollector,
  press: number,
  liveDoc: ProsemirrorNode
): { doc: ProsemirrorNode; ok: boolean } {
  try {
    const steps = collector.stepsSince(press);
    const transform = new Transform(liveDoc);
    for (let index = steps.length - 1; index >= 0; index--) {
      if (transform.maybeStep(steps[index].inverted).failed) return { doc: liveDoc, ok: false };
    }
    return { doc: transform.doc, ok: true };
  } catch {
    return { doc: liveDoc, ok: false };
  }
}

export interface PressInspection {
  press: number;
  /** Number of steps recorded since the press (the `steps=` of the trace line). */
  steps: number;
  kind: PressKind;
  /** The document the press acts on: the document at the press with the AUTOMATIC changes applied (the saved copy follows those),
   * and without the user's typing. The live document when `kind` is `matched` or `changed`. */
  docAtPress: ProsemirrorNode;
  /** The user's typing to put back (`kind` `typing` only), rebased to come after the automatic changes: in `docAtPress`
   * coordinates, in order, with their original tags. */
  typing: RecordedStep[];
}

export interface CommuteResult {
  ok: boolean;
  /** The document at the press with the automatic changes applied (the live document when there is no typing or `ok` is false). */
  doc: ProsemirrorNode;
  /** The user's typing, rebased to follow the automatic changes. Empty when there was none. */
  typing: RecordedStep[];
  /** Positions of the document at the press -> positions of `doc` (the automatic changes, in order; empty when there were none). */
  autoMapping: Mapping;
}

/** Rebases the typing steps over one automatic step: `over` is defined on `base`; the typing is defined on `base` followed by the
 * typing before it. Returns the document after `over` and the typing re-expressed to follow it (collab's rebase, mirrors paired), or
 * null when a typing step has no place after `over` (it lay inside text `over` replaced) or anything fails to apply. */
function rebaseTypingOver(
  base: ProsemirrorNode,
  typing: readonly RecordedStep[],
  over: Step
): { base: ProsemirrorNode; typing: RecordedStep[] } | null {
  const automatic = new Transform(base);
  if (automatic.maybeStep(over).failed) return null;
  const count = typing.length;
  const chain = new Mapping();
  for (let index = count - 1; index >= 0; index--) chain.appendMap(typing[index].inverted.getMap());
  chain.appendMap(over.getMap());
  const transform = new Transform(automatic.doc);
  const rebased: RecordedStep[] = [];
  for (let index = 0; index < count; index++) {
    const mapped = typing[index].step.map(chain.slice(count - index));
    if (mapped === null) return null;
    if (isNoOp(mapped)) continue;
    if (transform.maybeStep(mapped).failed) return null;
    rebased.push({
      step: mapped,
      inverted: mapped.invert(transform.docs[transform.docs.length - 1]),
      tag: typing[index].tag,
      typing: true,
    });
    chain.appendMap(mapped.getMap(), count - 1 - index);
  }
  return { base: automatic.doc, typing: rebased };
}

let commuteCache: {
  collector: TypingCollector;
  stamp: number;
  press: number;
  liveDoc: ProsemirrorNode;
  result: CommuteResult;
} | null = null;

/**
 * The document a press acts on, and the typing to put back on top of it. The automatic changes that landed since the press (the
 * settle's Notes and bibliography rebuild, a footnote renumber) are part of the document the saved copy was made of; the user's typing
 * is not. They can land in either order, and the usual one is typing first and the rebuild at the end of the wait. So the steps are
 * COMMUTED: starting from the document at the press, each automatic step is mapped back through the inverses of the typing steps
 * recorded before it and applied first; the typing is rebased (collab-style, mirrors paired) to come after it. The classification stays
 * inclusion-based: a step is typing only if the collector said so, never because it looks like typing (replaying an automatic
 * insertion onto a target that already absorbed it would duplicate text).
 *
 * `ok: false` (the press is `changed`: refused before the swap, the typing kept) when an automatic step cannot be mapped back or does
 * not apply, when a typing step lay inside text a LATER automatic step replaced (typing inside the Notes region that a rebuild
 * overwrote), or when the rebased typing on top of the result does not give back the live document (a wrong base is never trusted).
 */
export function commutePress(collector: TypingCollector, press: number, liveDoc: ProsemirrorNode): CommuteResult {
  const cached = commuteCache;
  if (
    cached &&
    cached.collector === collector &&
    cached.stamp === collector.version &&
    cached.press === press &&
    cached.liveDoc === liveDoc
  ) {
    return cached.result;
  }
  const result = computeCommute(collector, press, liveDoc);
  commuteCache = { collector, stamp: collector.version, press, liveDoc, result };
  return result;
}

function computeCommute(collector: TypingCollector, press: number, liveDoc: ProsemirrorNode): CommuteResult {
  const failed: CommuteResult = { ok: false, doc: liveDoc, typing: [], autoMapping: new Mapping() };
  const steps = collector.stepsSince(press);
  if (!steps.some((recorded) => recorded.typing))
    return { ok: true, doc: liveDoc, typing: [], autoMapping: new Mapping() };
  try {
    const atPress = docAtPress(collector, press, liveDoc);
    if (!atPress.ok) return failed;
    let base = atPress.doc;
    let typing: RecordedStep[] = [];
    const autoMapping = new Mapping();
    for (const recorded of steps) {
      if (recorded.typing) {
        typing.push(recorded); // already in the coordinates of the document after the typing before it
        continue;
      }
      if (typing.length === 0) {
        const applied = new Transform(base);
        if (applied.maybeStep(recorded.step).failed) return failed;
        base = applied.doc;
        autoMapping.appendMap(recorded.step.getMap());
        continue;
      }
      // An automatic step after typing: map it back through the inverses of that typing, apply it first, rebase the typing after it.
      const inverses = new Mapping();
      for (let index = typing.length - 1; index >= 0; index--) inverses.appendMap(typing[index].inverted.getMap());
      const earlier = recorded.step.map(inverses);
      if (earlier === null) return failed;
      const next = rebaseTypingOver(base, typing, earlier);
      if (next === null) return failed;
      base = next.base;
      typing = next.typing;
      autoMapping.appendMap(earlier.getMap());
    }
    // The check that makes a wrong base impossible to trust: the rebased typing on top of the result is the live document.
    const check = new Transform(base);
    for (const recorded of typing) if (check.maybeStep(recorded.step).failed) return failed;
    if (!check.doc.eq(liveDoc)) return failed;
    return { ok: true, doc: base, typing, autoMapping };
  } catch {
    return failed;
  }
}

/** What the re-check needs first: the steps since the press, what they are, and the document the press acts on. */
export function inspectPress(collector: TypingCollector, press: number, liveDoc: ProsemirrorNode): PressInspection {
  const steps = collector.stepsSince(press).length;
  if (steps === 0) return { press, steps: 0, kind: 'matched', docAtPress: liveDoc, typing: [] };
  const commuted = commutePress(collector, press, liveDoc);
  if (!commuted.ok) return { press, steps, kind: 'changed', docAtPress: liveDoc, typing: [] };
  if (commuted.typing.length === 0) return { press, steps, kind: 'matched', docAtPress: liveDoc, typing: [] };
  return { press, steps, kind: 'typing', docAtPress: commuted.doc, typing: commuted.typing };
}

/** The ranges of text the user's typing since `press` INSERTED, in LIVE coordinates (each step's new range, mapped through every later
 * step). A pure deletion (a Backspace) inserts nothing, so it has no range: text it took out of a span the redo is about to remove
 * is not text the redo can take with it. An insertion later deleted again collapses to nothing and is left out too. */
export function typedRangesInLive(collector: TypingCollector, press: number): Array<[number, number]> {
  const steps = collector.stepsSince(press);
  const ranges: Array<[number, number]> = [];
  steps.forEach((recorded, index) => {
    if (!recorded.typing) return;
    const own: Array<[number, number]> = [];
    recorded.step.getMap().forEach((_oldStart, _oldEnd, newStart, newEnd) => {
      if (newEnd > newStart) own.push([newStart, newEnd]);
    });
    if (own.length === 0) return;
    const later = new Mapping();
    for (let next = index + 1; next < steps.length; next++) later.appendMap(steps[next].step.getMap());
    for (const [start, end] of own) {
      const liveStart = later.map(start, -1);
      const liveEnd = later.map(end, 1);
      if (liveEnd > liveStart) ranges.push([liveStart, liveEnd]);
    }
  });
  return ranges;
}

/** True when any of the (non-empty) ranges lies inside [from, to] in a way that the removal of [from, to] would take typed text with it. */
export function rangesTouchSpan(ranges: ReadonlyArray<[number, number]>, from: number, to: number): boolean {
  return ranges.some(([start, end]) => end > start && end > from && start < to);
}

// === (c) Over: the block-wise map from the document at the press to the target ===

const DEL_BEFORE = 1;
const DEL_AFTER = 2;
const DEL_ACROSS = 4;
const DEL_SIDE = 8;

/** One top-level block: `start` is the position before it, `end` the position after it. */
export interface BlockInfo {
  key: string;
  start: number;
  end: number;
  node: ProsemirrorNode;
}

/** The top-level blocks of `doc` keyed by block id (`ids`: top-level offset -> id, `getAllBlockIds()` shape). A block without an id
 * (a marker atom) is keyed by its type and its ordinal among the id-less blocks of that type. */
export function blocksOf(
  doc: ProsemirrorNode,
  ids: ReadonlyMap<number, string>,
  canonical: (id: string) => string = (id) => id
): BlockInfo[] {
  const blocks: BlockInfo[] = [];
  const seen = new Set<string>();
  const noIdCount = new Map<string, number>();
  doc.forEach((node, offset) => {
    const id = ids.get(offset);
    let key: string;
    if (id !== undefined) {
      key = canonical(id);
    } else {
      const ordinal = noIdCount.get(node.type.name) ?? 0;
      noIdCount.set(node.type.name, ordinal + 1);
      key = `no-id:${node.type.name}:${ordinal}`;
    }
    while (seen.has(key)) key = `${key}#`; // a duplicated id never matches twice
    seen.add(key);
    blocks.push({ key, start: offset, end: offset + node.nodeSize, node });
  });
  return blocks;
}

/**
 * Restore pairing. A restore gives the blocks it brings back fresh ids (only a section root heading keeps its own), so matching by id
 * alone would call every body block of the restored text gone and send typing inside it to an own paragraph at the gap. The judge
 * ruled that typing in a block that SURVIVES with changed content goes inside that block, at the edge of the changed run. So the
 * blocks no id matches are paired by position: between two id-matched anchors (in the same order on both sides), the source blocks
 * with no id match and the target blocks with no id match are paired one to one when there are as many of the one as of the other
 * and every pair has the same node type; a paired target block takes its source block key. A copy a duplicate made has no
 * counterpart in the target (the counts differ) and stays gone; so does a block whose type the restore changed.
 */
function pairUnmatchedBlocks(src: readonly BlockInfo[], dst: readonly BlockInfo[]): BlockInfo[] {
  const dstIndexByKey = new Map(dst.map((block, index) => [block.key, index] as const));
  const srcKeys = new Set(src.map((block) => block.key));
  const paired = dst.map((block) => ({ ...block }));
  let previousSrc = -1;
  let previousDst = -1;
  for (let index = 0; index <= src.length; index++) {
    const matched = index < src.length ? dstIndexByKey.get(src[index].key) : dst.length;
    if (matched === undefined || matched <= previousDst) continue; // not a block of the target, or an anchor the target moved
    const srcRun: number[] = [];
    for (let at = previousSrc + 1; at < index; at++) if (!dstIndexByKey.has(src[at].key)) srcRun.push(at);
    const dstRun: number[] = [];
    for (let at = previousDst + 1; at < matched; at++) if (!srcKeys.has(dst[at].key)) dstRun.push(at);
    if (srcRun.length > 0 && srcRun.length === dstRun.length) {
      const sameTypes = srcRun.every((at, i) => src[at].node.type === dst[dstRun[i]].node.type);
      if (sameTypes) {
        srcRun.forEach((at, i) => {
          paired[dstRun[i]].key = src[at].key;
        });
      }
    }
    previousSrc = index;
    previousDst = matched;
  }
  return paired;
}

interface ContentDiff {
  start: number;
  endA: number;
  endB: number;
}

/** The common-prefix/suffix diff of two blocks' content, as the changed run [start, endA) in `a` and [start, endB) in `b`. Null when
 * the content is equal. */
function contentDiff(a: ProsemirrorNode, b: ProsemirrorNode): ContentDiff | null {
  if (a.content.eq(b.content)) return null;
  const start = a.content.findDiffStart(b.content);
  if (start === null) return null;
  const end = a.content.findDiffEnd(b.content);
  let endA = end ? end.a : a.content.size;
  let endB = end ? end.b : b.content.size;
  if (endA < start || endB < start) {
    // Prefix and suffix overlap (repeated characters): grow both runs to the prefix.
    const shift = start - Math.min(endA, endB);
    endA += shift;
    endB += shift;
  }
  return { start, endA, endB };
}

/** What `Mapping` reads from a segment. */
interface OverResult {
  pos: number;
  delInfo: number;
  recover: null;
}

export class BlockwiseMapping {
  private readonly dstIndexByKey = new Map<string, number>();
  private readonly diffCache = new Map<number, ContentDiff | null>();
  private readonly gapCache = new Map<number, number>();
  private readonly srcKeys: ReadonlySet<string>;

  constructor(
    readonly src: readonly BlockInfo[],
    readonly dst: readonly BlockInfo[],
    /** Phase 5 job A10 (`RebaseArgs.carriedTextFirst`): a typed insertion at the very point where the target inserted text goes AFTER it. */
    private readonly carriedTextFirst = false
  ) {
    this.srcKeys = new Set(src.map((block) => block.key));
    dst.forEach((block, index) => {
      this.dstIndexByKey.set(block.key, index);
    });
  }

  /** The index of the last source block that starts at or before `pos`, or -1. */
  private locate(pos: number): number {
    let low = 0;
    let high = this.src.length - 1;
    let found = -1;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (this.src[mid].start <= pos) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  private insideIndex(pos: number): number {
    const index = this.locate(pos);
    return index >= 0 && pos > this.src[index].start && pos < this.src[index].end ? index : -1;
  }

  isGone(srcIndex: number): boolean {
    return !this.dstIndexByKey.has(this.src[srcIndex].key);
  }

  /** Where a gone block's place is in the target. Between the nearest surviving blocks before and after it (the anchors, in the same
   * order on both sides) the target may hold blocks no source block corresponds to: the text the operation replaced. Then the place
   * is the EDGE of that run, like a position inside a changed block (its end: right after the target's last such block), so typing
   * in a restored whole document does not go to the top. When the target holds nothing between the anchors (a duplicate's copy:
   * nothing of it is in the target) it is right after the anchor before, which is where the copy stood. */
  gapOf(srcIndex: number): number {
    const cached = this.gapCache.get(srcIndex);
    if (cached !== undefined) return cached;
    let before = -1;
    for (let index = srcIndex - 1; index >= 0 && before < 0; index--) {
      before = this.dstIndexByKey.get(this.src[index].key) ?? -1;
    }
    let after = this.dst.length;
    for (let index = srcIndex + 1; index < this.src.length; index++) {
      const dstIndex = this.dstIndexByKey.get(this.src[index].key);
      if (dstIndex !== undefined && dstIndex > before) {
        after = dstIndex;
        break;
      }
    }
    let gap = before >= 0 ? this.dst[before].end : 0;
    for (let dstIndex = before + 1; dstIndex < after; dstIndex++) {
      if (!this.srcKeys.has(this.dst[dstIndex].key)) gap = this.dst[dstIndex].end;
    }
    this.gapCache.set(srcIndex, gap);
    return gap;
  }

  srcIndexOf(key: string): number {
    return this.src.findIndex((block) => block.key === key);
  }

  /** The key of the gone block that strictly contains `pos` (a position inside it), or null. */
  goneKeyAt(pos: number): string | null {
    const index = this.insideIndex(pos);
    return index >= 0 && this.isGone(index) ? this.src[index].key : null;
  }

  private diffOf(srcIndex: number, dstIndex: number): ContentDiff | null {
    if (this.diffCache.has(srcIndex)) return this.diffCache.get(srcIndex) ?? null;
    const diff = contentDiff(this.src[srcIndex].node, this.dst[dstIndex].node);
    this.diffCache.set(srcIndex, diff);
    return diff;
  }

  /** The source blocks the range [from, to] covers in part or whole (blocks that only touch it do not count). */
  private spanned(from: number, to: number): number[] {
    const indexes: number[] = [];
    for (let index = Math.max(0, this.locate(from)); index < this.src.length; index++) {
      const block = this.src[index];
      if (block.start >= to) break;
      if (block.end > from) indexes.push(index);
    }
    return indexes;
  }

  /** True when no block the range covers is a surviving block that the target moved apart from its neighbour in the range: the
   * matched blocks the range covers must be consecutive, in order, in the target (a join of two blocks places only when both are
   * present and adjacent there). A range inside one block is always intact. */
  rangeIntact(from: number, to: number): boolean {
    if (to < from) [from, to] = [to, from];
    const matched = this.spanned(from, to)
      .map((index) => this.dstIndexByKey.get(this.src[index].key))
      .filter((dstIndex): dstIndex is number => dstIndex !== undefined);
    for (let index = 1; index < matched.length; index++) {
      if (matched[index] !== matched[index - 1] + 1) return false;
    }
    return true;
  }

  /** True when the range covers something and everything it covers is gone from the target. */
  rangeAllGone(from: number, to: number): boolean {
    if (to < from) [from, to] = [to, from];
    if (from === to) return this.goneKeyAt(from) !== null;
    const covered = this.spanned(from, to);
    return covered.length > 0 && covered.every((index) => this.isGone(index));
  }

  /** True when any block the range covers in part or whole is gone from the target (a zoom transition's "the step straddles the
   * edge of the zoomed range": a Backspace joining a block inside the range with one outside it). */
  rangeTouchesGone(from: number, to: number): boolean {
    if (to < from) [from, to] = [to, from];
    return this.spanned(from, to).some((index) => this.isGone(index));
  }

  mapResult(pos: number, assoc: number): OverResult {
    const index = this.locate(pos);
    if (index >= 0 && pos > this.src[index].start && pos < this.src[index].end)
      return this.mapInside(index, pos, assoc);
    // A top-level boundary: the block before and the block after it (either can be absent at the document's edges).
    const before = index >= 0 && pos === this.src[index].start ? index - 1 : index;
    const after = before + 1;
    const beforeGone = before >= 0 && this.isGone(before);
    const afterGone = after < this.src.length && this.isGone(after);
    let delInfo = (beforeGone ? DEL_BEFORE : 0) | (afterGone ? DEL_AFTER : 0);
    let mapped: number;
    if (assoc > 0) {
      if (after >= this.src.length) {
        mapped = this.dst.length > 0 ? this.dst[this.dst.length - 1].end : 0;
      } else if (afterGone) {
        mapped = this.gapOf(after);
        delInfo |= DEL_SIDE;
      } else {
        mapped = this.dst[this.dstIndexByKey.get(this.src[after].key) as number].start;
      }
    } else if (before < 0) {
      mapped = 0;
    } else if (beforeGone) {
      mapped = this.gapOf(before);
      delInfo |= DEL_SIDE;
    } else {
      mapped = this.dst[this.dstIndexByKey.get(this.src[before].key) as number].end;
    }
    return { pos: mapped, delInfo, recover: null };
  }

  private mapInside(srcIndex: number, pos: number, assoc: number): OverResult {
    const dstIndex = this.dstIndexByKey.get(this.src[srcIndex].key);
    if (dstIndex === undefined) {
      return { pos: this.gapOf(srcIndex), delInfo: DEL_ACROSS | DEL_SIDE, recover: null };
    }
    const offset = pos - this.src[srcIndex].start - 1;
    const diff = this.diffOf(srcIndex, dstIndex);
    let mapped = offset;
    const dst = this.dst[dstIndex];
    if (diff && this.carriedAt(this.src[srcIndex].node, dst.node, diff, offset, assoc)) {
      mapped = offset + diff.endB - diff.start;
    } else if (diff && offset > diff.start) {
      if (offset >= diff.endA) mapped = offset - diff.endA + diff.endB;
      else mapped = assoc < 0 ? diff.start : diff.endB; // inside the changed run: its edge
    }
    return { pos: dst.start + 1 + Math.min(mapped, dst.node.content.size), delInfo: 0, recover: null };
  }

  /**
   * `carriedTextFirst`: the target inserted text (a pure insertion) that could equally have been inserted at `offset`, the point a
   * typed step inserts at: that text was typed before the step (the switch to Rich Text's carry: keys typed in the outgoing Markdown
   * page, then keys typed on the new page), so the step goes after it. "Could equally" matters: the diff's common prefix slides the
   * insertion past characters that repeat, so " box" typed before " harbour" is found as "box " one character later, and a typed key at
   * the caret would otherwise go BEFORE the carried text (hand test 2026-11-06, a9-notes.md, "Cursor fix and switch notice").
   */
  private carriedAt(
    src: ProsemirrorNode,
    dst: ProsemirrorNode,
    diff: ContentDiff,
    offset: number,
    assoc: number
  ): boolean {
    if (!this.carriedTextFirst || assoc <= 0 || diff.endA !== diff.start || offset > diff.start) return false;
    if (offset === diff.start) return true;
    const inserted = diff.endB - diff.start;
    return dst.content.cut(offset + inserted).eq(src.content.cut(offset));
  }

  map(pos: number, assoc = 1): number {
    return this.mapResult(pos, assoc).pos;
  }
}

// === (d) The rebase ===

/** prosemirror-collab's chain, as a `Mapping`: [inv(sn) ... inv(s1), Over, s1' ...]. Over is the one segment that is not a StepMap:
 * `Mapping` only needs `mapResult` of a segment (and `recover` of one that is mirrored), so the cast is all it takes. */
class RebaseMapping {
  private readonly chain = new Mapping();
  private readonly count: number;

  constructor(inverses: readonly Step[], over: BlockwiseMapping) {
    this.count = inverses.length;
    for (let index = inverses.length - 1; index >= 0; index--) this.chain.appendMap(inverses[index].getMap());
    this.chain.appendMap(over as unknown as StepMap);
  }

  /** The map step `index` (0-based) goes through: inv(s_index) ... inv(s1), Over, s1' ... s_index'. */
  window(index: number): Mapping {
    return this.chain.slice(this.count - index);
  }

  /** Only the inverses: step `index`'s coordinates back to the document at the press. */
  inversesOnly(index: number): Mapping {
    return this.chain.slice(this.count - index, this.count);
  }

  /** s_index' was applied: append its map, mirrored with inv(s_index). */
  appendPlaced(map: StepMap, index: number): void {
    this.chain.appendMap(map, this.count - 1 - index);
  }

  full(): Mapping {
    return this.chain.slice(0);
  }
}

/** A step that is placed in the target: the rebased step with its inverse, its tag and whether it was typing. */
export interface RebasedStep extends RecordedStep {
  /** True for the paragraph made for typing in a block the target no longer holds. */
  ghost?: boolean;
}

export interface RebaseArgs {
  /** All steps since the press, oldest first (`TypingCollector.stepsSince`). */
  steps: readonly RecordedStep[];
  /** The document at the press and its block ids (`getAllBlockIds()` read when the press latched). */
  docAtPress: ProsemirrorNode;
  idsAtPress: ReadonlyMap<number, string>;
  /** The target document and the ids of its top-level blocks (payload.blockIds placed by offset, or `entry.idMap` with its confirm log). */
  targetDoc: ProsemirrorNode;
  targetIds: ReadonlyMap<number, string>;
  /** Maps an id to its permanent form (a temp id Swift confirmed between the press and now), applied to both sides. */
  canonical?: (id: string) => string;
  /** Default true (the Phase 4c rule, (e)): typing in a block the target no longer holds becomes its own paragraph at the gap. False
   * (a zoom transition, Phase 5 job A7): such typing is NOT carried into the target (it goes to the rows as an ordinary batch, the
   * design's `outside`), so a step inside a gone block is dropped, and a step that spans the edge of the range (a join of a block
   * inside the range with one outside it) refuses the whole replay. */
  ghostsForGoneBlocks?: boolean;
  /** Default true (the restore pairing, `pairUnmatchedBlocks`). False (a zoom transition): the target's ids are a subset of the
   * source's, so no block is paired by position; a target block without an id (a mini-Notes block) matches nothing. */
  pairUnmatched?: boolean;
  /** Default false. True (the switch to Rich Text, Phase 5 job A10): where the target inserted text at the very point a typed step
   * inserts, the typed step goes after it. The target's text there is typing done in the outgoing Markdown page before the flip; the
   * replayed step is typing done on the new page after it. */
  carriedTextFirst?: boolean;
}

export interface RebaseOutcome {
  ok: boolean;
  reason?: string;
  /** The target document with the typed steps put back on top. */
  doc: ProsemirrorNode;
  /** The ghost paragraphs first, then every placed step, in order. */
  steps: RebasedStep[];
  /** Live-document positions -> positions in `doc` (the live selection is mapped through it). */
  mapping: Mapping;
  /** Steps that became a no-op (deleted text that is not in the target) and were not replayed. */
  dropped: number;
}

function spanOf(step: Step): { from: number; to: number } | null {
  if (
    step instanceof ReplaceStep ||
    step instanceof ReplaceAroundStep ||
    step instanceof AddMarkStep ||
    step instanceof RemoveMarkStep
  ) {
    return { from: step.from, to: step.to };
  }
  // A node attribute change (a heading id the editor rewrites as the title is typed): the node it names, so a block the target does
  // not hold drops it instead of refusing the whole replay.
  if (step instanceof AttrStep) return { from: step.pos, to: step.pos + 1 };
  return null;
}

function isNoOp(step: Step): boolean {
  return step instanceof ReplaceStep && step.from === step.to && step.slice.size === 0;
}

/** Rebases the typing steps of one press onto the target document (see the header, (c) to (e)). Pure: it only reads its arguments. */
export function rebaseTypingSteps(args: RebaseArgs): RebaseOutcome {
  const { steps, targetDoc } = args;
  const canonical = args.canonical ?? ((id: string) => id);
  const failed = (reason: string): RebaseOutcome => ({
    ok: false,
    reason,
    doc: targetDoc,
    steps: [],
    mapping: new Mapping(),
    dropped: 0,
  });
  const count = steps.length;
  const ghosts = args.ghostsForGoneBlocks !== false;
  const srcBlocks = blocksOf(args.docAtPress, args.idsAtPress, canonical);
  const dstPlain = blocksOf(targetDoc, args.targetIds, canonical);
  const dstBlocks = args.pairUnmatched === false ? dstPlain : pairUnmatchedBlocks(srcBlocks, dstPlain);
  const plain = new BlockwiseMapping(srcBlocks, dstBlocks, args.carriedTextFirst === true);

  // Typing inside a block the target no longer holds becomes its own paragraph at the gap. The paragraphs are made first, so the
  // letters then follow the ordinary route (matched block, changed content) and stay together in one paragraph. Not under
  // `ghostsForGoneBlocks: false` (a zoom transition): that typing is dropped here and reaches the rows as an ordinary batch.
  const inversesOnly = new Mapping();
  for (let index = count - 1; index >= 0; index--) inversesOnly.appendMap(steps[index].inverted.getMap());
  const ghostTagByKey = new Map<string, number>();
  for (let index = 0; ghosts && index < count; index++) {
    const step = steps[index].step;
    if (!(step instanceof ReplaceStep) || step.slice.size === 0) continue;
    const key = plain.goneKeyAt(inversesOnly.slice(count - index).map(step.from, 1));
    if (key !== null && !ghostTagByKey.has(key)) ghostTagByKey.set(key, steps[index].tag);
  }
  const transform = new Transform(targetDoc);
  let over = plain;
  const ghostRecords: RebasedStep[] = [];
  if (ghostTagByKey.size > 0) {
    const paragraph = targetDoc.type.schema.nodes.paragraph?.createAndFill();
    if (!paragraph) return failed('the schema has no paragraph for typing in a removed block');
    const ghosts = [...ghostTagByKey.keys()]
      .map((key) => ({ key, srcIndex: plain.srcIndexOf(key), gap: plain.gapOf(plain.srcIndexOf(key)) }))
      .sort((a, b) => b.gap - a.gap || b.srcIndex - a.srcIndex);
    for (const ghost of ghosts) {
      try {
        transform.insert(ghost.gap, paragraph);
      } catch (error) {
        return failed(`no paragraph fits at the gap of a removed block: ${String(error).slice(0, 120)}`);
      }
    }
    const ghostTag = steps[0].tag;
    transform.steps.forEach((step, index) => {
      ghostRecords.push({
        step,
        inverted: step.invert(transform.docs[index]),
        tag: ghostTag,
        typing: true,
        ghost: true,
      });
    });
    const shifted = dstBlocks.map((block) => ({
      ...block,
      start: transform.mapping.map(block.start, 1),
      end: transform.mapping.map(block.end, -1),
    }));
    ghosts.forEach((ghost, index) => {
      const start = transform.mapping.slice(index + 1).map(ghost.gap, 1);
      shifted.push({ key: ghost.key, start, end: start + paragraph.nodeSize, node: paragraph });
    });
    shifted.sort((a, b) => a.start - b.start);
    over = new BlockwiseMapping(srcBlocks, shifted, args.carriedTextFirst === true);
  }

  const chain = new RebaseMapping(
    steps.map((recorded) => recorded.inverted),
    over
  );
  const placed: RebasedStep[] = [];
  let dropped = 0;
  for (let index = 0; index < count; index++) {
    const recorded = steps[index];
    const span = spanOf(recorded.step);
    const back = chain.inversesOnly(index);
    // A change of the block itself (a heading id rewritten, a list wrapped) made to a block the target no longer holds is not carried
    // to the paragraph made for the typing: that paragraph stands for the typed letters, not for the block. Without ghosts (a zoom
    // transition) it is dropped for every gone block: the block is outside the zoomed range and its change reaches the rows as a batch.
    if (span && (recorded.step instanceof ReplaceAroundStep || recorded.step instanceof AttrStep)) {
      const goneKey = plain.goneKeyAt(back.map(span.from, 1) + 1);
      if (goneKey !== null && (!ghosts || ghostTagByKey.has(goneKey))) {
        dropped++;
        continue;
      }
    }
    const mapped = recorded.step.map(chain.window(index));
    if (mapped === null) {
      // Deleted across: typed text that was deleted with its block is gone with it (a deletion there is a no-op). Anything else the
      // chain cannot place is a refusal.
      if (span && over.rangeAllGone(back.map(span.from, 1), back.map(span.to, -1))) {
        dropped++;
        continue;
      }
      return failed(`step ${index + 1} of ${count} has no place in the target`);
    }
    if (
      span &&
      span.from !== span.to &&
      !ghosts &&
      over.rangeTouchesGone(back.map(span.from, 1), back.map(span.to, -1))
    ) {
      return failed(`step ${index + 1} of ${count} spans the edge of the zoomed range`);
    }
    if (span && span.from !== span.to && !over.rangeIntact(back.map(span.from, 1), back.map(span.to, -1))) {
      return failed(`step ${index + 1} of ${count} spans blocks the target has moved apart`);
    }
    if (isNoOp(mapped)) {
      dropped++;
      continue;
    }
    const result = transform.maybeStep(mapped);
    if (result.failed) return failed(`step ${index + 1} of ${count} does not apply in the target: ${result.failed}`);
    placed.push({
      step: mapped,
      inverted: mapped.invert(transform.docs[transform.docs.length - 1]),
      tag: recorded.tag,
      typing: recorded.typing,
    });
    chain.appendPlaced(mapped.getMap(), index);
  }
  return { ok: true, doc: transform.doc, steps: [...ghostRecords, ...placed], mapping: chain.full(), dropped };
}

// === (f) The replay and its dry run ===

export interface ReplayArgs extends Omit<RebaseArgs, 'targetDoc'> {
  /** The live selection (`view.state.selection`), in live-document coordinates; the replay sets it mapped through the rebase. */
  liveSelection: Selection;
  /** Whether block-sync was paused before the dry run and stays paused after it (the quick routes pause it before the swap). */
  syncPausedAfter: boolean;
  /** The live state, whose block-id plugin state is pointed at the restored id maps after the dry run. */
  liveState?: EditorState;
  /** Runs one `applyTransaction` with the plugins' module-level state contained. Default: `containPluginSideEffects`. */
  contain?: <T>(run: () => T) => T;
}

export interface ReplayDryRun {
  ok: boolean;
  /** `matched` when there was nothing to replay. */
  decision: 'rebased' | 'matched' | 'unplaceable';
  reason?: string;
  /** The first (usually the only) replay transaction, built on the target state. Dispatch it right after the swap. */
  replayTr: Transaction | null;
  /** One per press segment, in order; each starts with `closeHistory`. Dispatch them in order. */
  replayTrs: Transaction[];
  /** The target state after the replay. After the real dispatch the page asserts `view.state.doc.eq(dryState.doc)`. */
  dryState: EditorState | null;
  /** The placed steps, for `TypingCollector.adoptRebased`. */
  rebased: RebasedStep[];
}

/** The dry run executes every plugin's `state.apply` on a throwaway state. Block-id's `apply` reassigns the module-level id maps, and
 * block-sync's `apply` snapshots the document and arms a timer unless block-sync is paused. So: pause block-sync, copy the id maps,
 * run, put the maps back (in place) and re-point the live state's block-id plugin state at them. */
export function containPluginSideEffects<T>(
  run: () => T,
  options: { syncPausedAfter: boolean; liveState?: EditorState }
): T {
  const ids = getAllBlockIds();
  const types = getAllBlockTypes();
  setSyncPaused(true);
  try {
    return run();
  } finally {
    restoreBlockIdMaps(ids, types);
    if (options.liveState) pointPluginStateAtLiveIds(options.liveState);
    setSyncPaused(options.syncPausedAfter);
  }
}

function groupByTag(steps: readonly RebasedStep[]): RebasedStep[][] {
  const groups: RebasedStep[][] = [];
  for (const step of steps) {
    const last = groups[groups.length - 1];
    if (last && last[0].tag === step.tag) last.push(step);
    else groups.push([step]);
  }
  return groups;
}

/** The live selection mapped through the rebase (caret rule), kept inside the document. */
function mapSelection(selection: Selection, mapping: Mapping, doc: ProsemirrorNode): Selection {
  try {
    const clamp = (pos: number) => Math.max(0, Math.min(doc.content.size, pos));
    return TextSelection.between(
      doc.resolve(clamp(mapping.map(selection.anchor, -1))),
      doc.resolve(clamp(mapping.map(selection.head, -1)))
    );
  } catch {
    return Selection.atEnd(doc);
  }
}

/**
 * Builds the replay against the TARGET state and applies it there first (amendment 1): `dry = targetState.applyTransaction(tr)` for each
 * press segment, so appended transactions and filters are included. Fails (`unplaceable`, nothing built, nothing live touched) when a
 * step does not place, a replay is missing from `dry.transactions`, or a plugin changed the replayed document. The caller dispatches
 * `replayTrs` right after the swap, in the same guarded block, and asserts the live document equals `dryState.doc`; on any failure
 * there it puts the live state back and refuses.
 */
export function buildReplayDryRun(targetState: EditorState, args: ReplayArgs): ReplayDryRun {
  const refused = (reason: string): ReplayDryRun => ({
    ok: false,
    decision: 'unplaceable',
    reason,
    replayTr: null,
    replayTrs: [],
    dryState: null,
    rebased: [],
  });
  if (args.steps.length === 0) {
    return { ok: true, decision: 'matched', replayTr: null, replayTrs: [], dryState: targetState, rebased: [] };
  }
  try {
    const outcome = rebaseTypingSteps({ ...args, targetDoc: targetState.doc });
    if (!outcome.ok) return refused(outcome.reason ?? 'the rebase failed');
    const contain =
      args.contain ??
      (<T>(run: () => T): T =>
        containPluginSideEffects(run, { syncPausedAfter: args.syncPausedAfter, liveState: args.liveState }));
    const groups = groupByTag(outcome.steps);
    const replayTrs: Transaction[] = [];
    let state = targetState;
    groups.forEach((group, groupIndex) => {
      const tr = state.tr;
      closeHistory(tr); // one history event per press segment: this segment never joins the group before it
      tr.setMeta('typingReplay', true);
      for (const placed of group) tr.step(placed.step);
      if (groupIndex === groups.length - 1) tr.setSelection(mapSelection(args.liveSelection, outcome.mapping, tr.doc));
      const dry = contain(() => state.applyTransaction(tr));
      if (!dry.transactions.includes(tr)) throw new Error('a plugin filtered the replay out');
      replayTrs.push(tr);
      state = dry.state;
    });
    if (!state.doc.eq(outcome.doc)) throw new Error('the plugins changed the replayed document');
    return {
      ok: true,
      decision: 'rebased',
      replayTr: replayTrs[0],
      replayTrs,
      dryState: state,
      rebased: outcome.steps,
    };
  } catch (error) {
    return refused(`exception: ${error instanceof Error ? error.message : String(error)}`.slice(0, 200));
  }
}
