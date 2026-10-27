// Editor-first section REORDER in MARKDOWN mode -- the page half (t-4a8fd8af, Phase 4b, Markdown slice 2, round 2a: the move itself).
//
// A sidebar drag in Markdown mode used to be the old body: the database was reordered first and the editor then received the
// DB-assembled text as a `setContent` push, so anything typed in between was lost. Here the EDITOR changes first, in one synchronous
// JavaScript task and ONE transaction: it moves the section's text (and rewrites the `#` count of the headings whose level the drop
// changed), takes the typing so far with it and carries the caret along. A queued job on the Swift side makes the database agree
// afterwards (`SectionReorderJob`). Rich Text does the same (web/milkdown/src/api-section-reorder.ts); this is the CodeMirror
// counterpart, working on text. The text rules below are copied from that file and from the database's grouping
// (Database+BlocksReorder.swift `groupBlocksBySections`), so the page and the rows end up with the same sections.
//
// ONE window.FinalFinal entry point:  markdownStructuralReorder(request)   (the click; takes a JSON string or a parsed object)
// The undo and redo of the entry are round 2b (api-structural-markdown.ts `markdownStructuralSwap`).
//
// ---------------------------------------------------------------------------------------------------------------------------
// THE JSON CONTRACT (Swift builds `MarkdownReorderRequest`; the page returns `MarkdownReorderResult`)
// ---------------------------------------------------------------------------------------------------------------------------
//
//   interface MarkdownReorderRequest {
//     kind: 'reorder';
//     opId: string;                      // the structural entry's id (also the registry key)
//     rootId: string;                    // the leader the user dragged
//     leaders: MarkdownLeader[];         // EVERY leader of the document (headings and section breaks) in sort order, Notes and
//                                        // Bibliography included, exactly as for the delete (api-structural-markdown.ts): built from
//                                        // the rows AFTER the typing was flushed. `managed` marks the Notes / Bibliography heading rows.
//     order: Array<{ id: string; level?: number }>;
//                                        // the plan: every section leader in FINAL order, Notes and Bibliography last. `level` (1-6) is
//                                        // present on the headings whose level the drop changed.
//     stopLine?: string | null;          // the trimmed first line of the FIRST Notes/Bibliography row of the document (leader or not,
//                                        // e.g. "<!-- ::auto-bibliography:: -->"); null/absent when none. A consistency check only: when
//                                        // given, that line must occur in the live text, else `leadersMismatch`.
//   }
//   interface MarkdownReorderResult {
//     ok: boolean;
//     reason?: 'badRequest' | 'unsupportedKind' | 'noEditor' | 'dispatchThrew'
//            | 'leadersMismatch'         // the leaders do not match the text: nothing changed, Swift flushes and retries ONCE
//            | 'rootNotFound'            // the dragged root is not among the leaders
//            | 'planMismatch'            // the plan is not "one contiguous run starting at the root, moved elsewhere" (a level-only
//                                        // drop is NOT a mismatch: it moves nothing, see below)
//            | 'managedMoved';           // the run holds the Notes or Bibliography heading
//     detail?: string;                   // counts and indexes only, never document text
//     preRaw?: string;                   // the raw document (anchors and markers included) before the call   -- ok only
//     postRaw?: string;                  // ... and after it                                                   -- ok only
//     skippedIds?: string[];             // order ids that had no matched leader and were dropped from the plan   -- ok only
//   }
//
// A refusal changes nothing, records nothing, dispatches nothing and does not touch the undo descriptor. `leadersMismatch` is the same
// failure, with the same detail strings, as the delete's, so Swift reuses its flush-and-retry. Every other refusal sends Swift to the
// old whole-document body.
//
// ---------------------------------------------------------------------------------------------------------------------------
// THE RULES
// ---------------------------------------------------------------------------------------------------------------------------
// GROUPS. A group leader is a matched leader whose id is in the order's id set; its group runs from the start of its line to the start
//   of the next group leader's line. Any other leader line (a heading the plan does not list) is body text of the group leader above it,
//   exactly as `groupBlocksBySections` reads the rows. Order ids with no matched leader are dropped and returned as `skippedIds`.
// MANAGED REGION. It starts at the first request leader flagged `managed`, or at the first line that holds the bibliography opening
//   marker in the live text, whichever comes first (none: the end of the document). No group reaches into it, and nothing moves into or
//   out of it: a run that is to go last lands just before it.
// THE RUN. `oldOrder` = the group leaders in document order, `newOrder` = the plan; `needsMove = oldOrder != newOrder`. The moved run is
//   the longest contiguous run from `rootId` in both orders (the root alone for a plain drag, root plus subsections for an Option drag).
//   `planMismatch` unless the orders are equal once the run is taken out of each; `managedMoved` if the run holds a managed id.
//   The range is from the run's first group start to the next group start (or the region start); the target is the start of the group
//   of the leader that follows the run in the plan (or the region start).
// THE NO-MOVE BRANCH. A drop that changed only levels has `needsMove == false`: the transaction holds only the level rewrites and one
//   entry is recorded, as for any move.
// SEPARATORS. Groups are separated by a blank line, but the LAST group of a document with no Notes/Bibliography ends with whatever the
//   document ends with (one newline, none). (i) A range that was last moves up: its end becomes a blank line, and the group before it
//   becomes the last and takes over the document's original final newlines. (ii) A range moves to the end of such a document: the old
//   last group gets a blank line after it, and the range gives up its blank line for the document's original final newlines. A heading is
//   never glued to the line before it and the document keeps its original final characters.
// LEVELS. Only heading leaders are rewritten (a section break is not a heading), and only when the plan's level differs from the line's.
//   Behind any leading hidden prefix (section anchor, blanks) the `#` run plus ONE ASCII space is replaced by `#`x n + " ": byte for byte
//   `SectionSyncService.updateHeaderLevel` (SectionSyncService.swift), which skips the `#` run and one " " and keeps the rest -- a tab or
//   a U+3000 after the run stays. A row fragment never starts with a hidden prefix (BlockParser trims, and the anchors are stripped when the
//   page's text is stored), so the database rewrites the same characters the page does.
// CARET. The selection is set in the SAME transaction. A head or anchor inside the moved range follows its text to the new place (the
//   offset inside the run, through the level rewrites and the separator changes); any other position is mapped through the changes; a
//   selection the move cuts (one end in the run and one out, the run or the target between its ends) collapses to its head.
//
// THE ENTRY: `registry.set(opId, { checkpoint, preOpDoc, postOpDoc, midOp, markdown: { kind: 'reorder', request, opChanges } })`, recorded
//   BEFORE the dispatch with `midOp: true` (the page's own change must not advance the saved copies); `finally` clears `midOp` and sets
//   `postOpDoc`. A throwing dispatch removes the entry. The checkpoint is the pre-op state with its text history, already isolated.
// THE DESCRIPTOR: on success the page sets `{ undoTopOpId: opId }` itself (Swift's push comes later); a refusal sets nothing.
// THE HISTORY: one ChangeSet, `addToHistory: false` (it maps both history branches through the move: a deletion inside the moved range
//   maps away, an insertion lands at the removal point; see redo-branch.ts for how the undo and redo handle the redo branch) and
//   `isolateHistory('full')`, so typing before and after the command never merges into one undo step. A redo event already waiting
//   when the click comes and lying inside the moved range would land at that removal point (the start of the next chapter's heading
//   line), so the click first drops it from the redo list (`withoutRedoEventsTouching`).

import { isolateHistory } from '@codemirror/commands';
import { ChangeSet, EditorSelection, Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import {
  ATX_HEADING,
  type DocumentScan,
  installState,
  isRecord,
  type LeaderCandidate,
  leaderMismatchDetail,
  leadingHiddenOf,
  type MarkdownLeader,
  type MarkdownStructuralFailure,
  parseLeaders,
  scanDocument,
  stripLeadingHidden,
  trace,
} from './api-structural-markdown';
import { getEditorExtensions, getEditorView } from './editor-state';
import { type MovedRange, removedSpans, withoutRedoEventsTouching } from './redo-branch';
import { withAppOrigin } from './typewriter-plugin';
import { deleteRegistryEntry, getRegistry, setRegistryEntry, setUndoDescriptor } from './undo-coordinator';

// === The contract (see the header) ===

export interface MarkdownReorderOrderEntry {
  id: string;
  level?: number;
}

export interface MarkdownReorderRequest {
  kind: 'reorder';
  opId: string;
  rootId: string;
  leaders: MarkdownLeader[];
  order: MarkdownReorderOrderEntry[];
  stopLine?: string | null;
}

export type MarkdownReorderFailure = MarkdownStructuralFailure | 'planMismatch' | 'managedMoved' | 'rootNotFound';

export interface MarkdownReorderResult {
  ok: boolean;
  reason?: MarkdownReorderFailure;
  detail?: string;
  preRaw?: string;
  postRaw?: string;
  skippedIds?: string[];
}

// === Request parsing ===

function parseReorderRequest(input: unknown): { request: MarkdownReorderRequest } | { failure: MarkdownReorderResult } {
  let raw: unknown = input;
  if (typeof input === 'string') {
    try {
      raw = JSON.parse(input);
    } catch {
      return { failure: { ok: false, reason: 'badRequest', detail: 'unparsable json' } };
    }
  }
  if (!isRecord(raw)) return { failure: { ok: false, reason: 'badRequest', detail: 'not an object' } };
  if (raw.kind !== 'reorder') {
    return { failure: { ok: false, reason: 'unsupportedKind', detail: `kind=${String(raw.kind)}` } };
  }
  if (typeof raw.opId !== 'string' || raw.opId === '') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'opId' } };
  }
  if (typeof raw.rootId !== 'string' || raw.rootId === '') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'rootId' } };
  }
  if (!Array.isArray(raw.leaders)) return { failure: { ok: false, reason: 'badRequest', detail: 'leaders' } };
  const parsedLeaders = parseLeaders(raw.leaders);
  if ('badIndex' in parsedLeaders) {
    return { failure: { ok: false, reason: 'badRequest', detail: `leader ${parsedLeaders.badIndex}` } };
  }
  if (!Array.isArray(raw.order)) return { failure: { ok: false, reason: 'badRequest', detail: 'order' } };
  const order: MarkdownReorderOrderEntry[] = [];
  for (const [index, item] of raw.order.entries()) {
    const level = isRecord(item) ? item.level : undefined;
    const valid =
      isRecord(item) &&
      typeof item.id === 'string' &&
      (level === undefined ||
        level === null ||
        (typeof level === 'number' && Number.isInteger(level) && level >= 1 && level <= 6));
    if (!valid) return { failure: { ok: false, reason: 'badRequest', detail: `order ${index}` } };
    const entry = item as { id: string };
    order.push(typeof level === 'number' ? { id: entry.id, level } : { id: entry.id });
  }
  const stopLine = raw.stopLine;
  if (stopLine !== undefined && stopLine !== null && typeof stopLine !== 'string') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'stopLine' } };
  }
  return {
    request: {
      kind: 'reorder',
      opId: raw.opId,
      rootId: raw.rootId,
      leaders: parsedLeaders.leaders,
      order,
      stopLine: stopLine as string | null | undefined,
    },
  };
}

// === The plan ===

type PlanOutcome =
  | {
      ok: true;
      changes: ChangeSet;
      selection: EditorSelection;
      skippedIds: string[];
      detail: string;
      /** The moved text in the new document (null: nothing moved). */
      moved: MovedRange | null;
    }
  | { ok: false; failure: MarkdownReorderResult };

function refuse(reason: MarkdownReorderFailure, detail?: string): PlanOutcome {
  return { ok: false, failure: { ok: false, reason, ...(detail === undefined ? {} : { detail }) } };
}

function sameSequence(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

/** How many newline characters end the text just before `pos`. */
function newlinesBefore(doc: Text, pos: number): number {
  let count = 0;
  while (count < pos && doc.sliceString(pos - count - 1, pos - count) === '\n') count++;
  return count;
}

interface Replacement {
  from: number;
  to: number;
  insert: string;
}

/**
 * The `#` rewrite of a heading leader, or null when the line is not a heading or already has the level. Behind the leading hidden prefix
 * (section anchor, blanks) it replaces the `#` run plus ONE ASCII space by `#`x level + " " -- what SectionSyncService.updateHeaderLevel
 * writes (it skips the run, skips one " ", keeps the rest as the title).
 */
function levelRewrite(doc: Text, candidate: LeaderCandidate, level: number): Replacement | null {
  const line = doc.lineAt(candidate.from);
  if (!ATX_HEADING.test(stripLeadingHidden(line.text))) return null; // a section break is not a heading
  const prefix = leadingHiddenOf(line.text);
  const rest = line.text.slice(prefix.length);
  let hashes = 0;
  while (rest[hashes] === '#') hashes++;
  if (hashes === level) return null;
  const spaceLength = rest[hashes] === ' ' ? 1 : 0;
  const from = line.from + prefix.length;
  return { from, to: from + hashes + spaceLength, insert: `${'#'.repeat(level)} ` };
}

/**
 * Matches the leaders, finds the run, builds the one change set and the selection after it. Pure: reads `doc` and `selection`, changes
 * nothing.
 */
function planReorder(doc: Text, selection: EditorSelection, request: MarkdownReorderRequest): PlanOutcome {
  const { leaders } = request;
  if (!leaders.some((leader) => leader.id === request.rootId)) return refuse('rootNotFound');

  const scan: DocumentScan = scanDocument(doc, request.stopLine);
  const mismatchDetail = leaderMismatchDetail(scan, leaders);
  if (mismatchDetail !== null) return refuse('leadersMismatch', mismatchDetail);
  if (request.stopLine && scan.stopHits.length === 0) return refuse('leadersMismatch', 'stopLineMissing');

  // The working order: what the page can actually place. An order id with no matched leader is skipped, not fatal.
  const leaderIndexById = new Map<string, number>();
  leaders.forEach((leader, index) => {
    if (!leaderIndexById.has(leader.id)) leaderIndexById.set(leader.id, index);
  });
  const skippedIds = request.order.filter((entry) => !leaderIndexById.has(entry.id)).map((entry) => entry.id);
  const working = request.order.filter((entry) => leaderIndexById.has(entry.id));
  const newOrder = working.map((entry) => entry.id);
  const isGroupLeader = new Set(newOrder);

  // The group leaders in document order; every other leader line is body of the group leader above it.
  const groupLeaderIndexes: number[] = [];
  leaders.forEach((leader, index) => {
    if (isGroupLeader.has(leader.id)) groupLeaderIndexes.push(index);
  });
  const oldOrder = groupLeaderIndexes.map((index) => leaders[index].id);
  const managed = new Set(leaders.filter((leader) => leader.managed !== undefined).map((leader) => leader.id));

  // Where the Notes / Bibliography region starts: the first managed leader of the REQUEST, or the first line that holds the bibliography
  // opening marker in the live text, whichever comes first. A group never reaches into it.
  const end = doc.length;
  let regionStart: number | undefined;
  const firstManaged = leaders.findIndex((leader) => leader.managed !== undefined);
  if (firstManaged >= 0) regionStart = scan.candidates[firstManaged].from;
  const markerLine = scan.bibliographyStarts[0];
  if (markerLine !== undefined && (regionStart === undefined || markerLine < regionStart)) regionStart = markerLine;
  const tailAt = regionStart ?? end;

  const startOfGroup = (k: number): number => scan.candidates[groupLeaderIndexes[k]].from;
  const endOfGroup = (k: number): number => {
    const next = k + 1 < groupLeaderIndexes.length ? startOfGroup(k + 1) : end;
    return startOfGroup(k) < tailAt ? Math.min(next, tailAt) : next;
  };

  // The moved run: the longest run from the root that is contiguous in BOTH orders.
  const oldAt = oldOrder.indexOf(request.rootId);
  const newAt = newOrder.indexOf(request.rootId);
  if (oldAt < 0 || newAt < 0) return refuse('planMismatch', 'rootNotInOrder');
  const needsMove = !sameSequence(oldOrder, newOrder);
  let runLength = 0;
  if (needsMove) {
    runLength = 1;
    while (
      oldAt + runLength < oldOrder.length &&
      newAt + runLength < newOrder.length &&
      oldOrder[oldAt + runLength] === newOrder[newAt + runLength]
    ) {
      runLength++;
    }
    const oldRest = [...oldOrder.slice(0, oldAt), ...oldOrder.slice(oldAt + runLength)];
    const newRest = [...newOrder.slice(0, newAt), ...newOrder.slice(newAt + runLength)];
    if (!sameSequence(oldRest, newRest)) return refuse('planMismatch', `runLength=${runLength}`);
    if (oldOrder.slice(oldAt, oldAt + runLength).some((id) => managed.has(id))) return refuse('managedMoved');
  }

  // Where the run goes: the start of the follower's group; with no follower, or a follower inside the managed region, the region start.
  let from = 0;
  let to = 0;
  let target = 0;
  if (needsMove) {
    from = startOfGroup(oldAt);
    to = endOfGroup(oldAt + runLength - 1);
    const followerId = newOrder[newAt + runLength];
    target = Math.min(followerId === undefined ? end : startOfGroup(oldOrder.indexOf(followerId)), tailAt);
    if (target >= from && target <= to) return refuse('planMismatch', 'targetInsideRun');
  }

  // The level rewrites, split into those inside the moved text (they are made in the copy that is inserted) and the others.
  const rewrites: Replacement[] = [];
  for (const entry of working) {
    if (entry.level === undefined) continue;
    const index = leaderIndexById.get(entry.id);
    if (index === undefined) continue;
    const rewrite = levelRewrite(doc, scan.candidates[index], entry.level);
    if (rewrite !== null) rewrites.push(rewrite);
  }
  const insideRun = (rewrite: Replacement): boolean => needsMove && rewrite.from >= from && rewrite.from < to;
  const outside = rewrites.filter((rewrite) => !insideRun(rewrite));
  const relative = ChangeSet.of(
    rewrites
      .filter(insideRun)
      .map((rewrite) => ({ from: rewrite.from - from, to: rewrite.to - from, insert: rewrite.insert })),
    to - from
  );

  // The edits, all in coordinates of the original document.
  const specs: Replacement[] = outside.map((rewrite) => ({ ...rewrite }));
  let mode: 'verbatim' | 'last' | 'toEnd' = 'verbatim';
  let insertion = '';
  let padLength = 0;
  let bodyLength = 0; // length of the run's text before its trailing newlines (original text), used by the caret mapping
  let newTrail = 0; // the newlines the inserted text ends with when they changed
  if (needsMove) {
    const runText = relative.apply(Text.of(doc.sliceString(from, to).split('\n'))).toString();
    const runTrail = Math.min(newlinesBefore(doc, to), to - from); // the newlines the run's text ends with
    const finalNewlines = newlinesBefore(doc, end);
    if (regionStart === undefined) {
      if (to === end) mode = 'last';
      else if (target === end) mode = 'toEnd';
    }
    bodyLength = to - from - runTrail;
    const body = runText.slice(0, runText.length - runTrail);
    if (mode === 'last') {
      // (i) The last group moves up: it now ends with a blank line, and the group before it becomes the last and takes over the
      // document's final newlines.
      newTrail = 2;
      insertion = `${body}\n\n`;
      const before = newlinesBefore(doc, from);
      specs.push({ from: target, to: target, insert: insertion });
      specs.push({
        from: from - Math.max(0, before - finalNewlines),
        to: end,
        insert: '\n'.repeat(Math.max(0, finalNewlines - before)),
      });
    } else if (mode === 'toEnd') {
      // (ii) A group moves to the end: the old last group gets a blank line after it, and the moved group gives up its blank line for the
      // document's final newlines.
      padLength = Math.max(0, 2 - finalNewlines);
      newTrail = finalNewlines;
      insertion = `${'\n'.repeat(padLength)}${body}${'\n'.repeat(finalNewlines)}`;
      specs.push({ from, to, insert: '' });
      specs.push({ from: end, to: end, insert: insertion });
    } else {
      insertion = runText;
      specs.push({ from, to, insert: '' });
      specs.push({ from: target, to: target, insert: insertion });
    }
  }
  // Ascending, an insertion before a replacement that starts at the same place.
  const isReplacement = (spec: Replacement): number => (spec.to > spec.from ? 1 : 0);
  specs.sort((x, y) => x.from - y.from || isReplacement(x) - isReplacement(y) || x.to - y.to);
  const changes = ChangeSet.of(
    specs.map((spec) => ({ from: spec.from, to: spec.to, insert: spec.insert })),
    end
  );

  // The selection, in coordinates of the new document.
  const newLength = changes.newLength;
  const clamp = (pos: number): number => Math.max(0, Math.min(newLength, pos));
  const insertStart = needsMove ? changes.mapPos(target, -1) : 0;
  const insideMoved = (pos: number): boolean => needsMove && pos >= from && (pos < to || (to === end && pos === end));
  const mapInside = (pos: number): number => {
    let offset = pos - from;
    let trailing = 0;
    if (mode !== 'verbatim' && offset > bodyLength) {
      trailing = Math.min(offset - bodyLength, newTrail);
      offset = bodyLength;
    }
    return insertStart + padLength + relative.mapPos(offset, 1) + trailing;
  };
  const mapOutside = (pos: number): number => changes.mapPos(pos, pos === target && target < end ? 1 : -1);
  const mapAny = (pos: number): number => (insideMoved(pos) ? mapInside(pos) : mapOutside(pos));
  const ranges = selection.ranges.map((range) => {
    if (!needsMove)
      return EditorSelection.range(clamp(changes.mapPos(range.anchor, -1)), clamp(changes.mapPos(range.head, -1)));
    const anchorIn = insideMoved(range.anchor);
    const headIn = insideMoved(range.head);
    if (anchorIn && headIn) return EditorSelection.range(clamp(mapInside(range.anchor)), clamp(mapInside(range.head)));
    const low = Math.min(range.anchor, range.head);
    const high = Math.max(range.anchor, range.head);
    const cut = anchorIn !== headIn || (low < from && high >= to) || (low < target && target < high);
    if (cut) return EditorSelection.cursor(clamp(mapAny(range.head)));
    return EditorSelection.range(clamp(mapOutside(range.anchor)), clamp(mapOutside(range.head)));
  });

  return {
    ok: true,
    changes,
    selection: EditorSelection.create(ranges, selection.mainIndex),
    // The moved text itself: the blank lines the pad adds in front of it (rule ii) belong to the group before it.
    moved: needsMove ? { from: insertStart + padLength, to: insertStart + insertion.length } : null,
    skippedIds,
    detail: `moved=${needsMove ? to - from : 0} run=${runLength} leaders=${newOrder.length} levels=${rewrites.length} skipped=${skippedIds.length}`,
  };
}

// === The click ===

/** Plans the command, records the entry, dispatches once. Nothing is recorded or dispatched on a refusal. */
function runReorder(view: EditorView, request: MarkdownReorderRequest): MarkdownReorderResult {
  const registry = getRegistry();
  const doc = view.state.doc;

  // 1. Plan first. A refusal (or any failure) returns here: nothing is recorded and nothing is dispatched.
  let plan: PlanOutcome;
  try {
    plan = planReorder(doc, view.state.selection, request);
  } catch (error) {
    trace(`markdown-reorder plan threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'badRequest', detail: 'planThrew' };
  }
  if (!plan.ok) return plan.failure;

  // 1b. A redo event that is already waiting (typing taken back with Cmd-Z before the drag) and lies inside the text this move removes
  // would be mapped to the removal point by the dispatch below -- the start of the next chapter's heading line -- and a later
  // Cmd-Shift-Z would type it there. Such events leave the redo list first (the first one and every later one, as in the undo's carry).
  const trimmed = withoutRedoEventsTouching(view.state, removedSpans(plan.changes), getEditorExtensions());
  if (trimmed) {
    try {
      installState(view, trimmed.state, { label: 'drag-trim', keepScroll: true });
      trace(`markdown-reorder redo list trimmed dropped=${trimmed.dropped}`);
    } catch (error) {
      trace(`markdown-reorder redo trim threw: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  // 2. Record the entry BEFORE the dispatch, mid-op, so the page's own change does not advance the saved copies. The checkpoint is the
  // pre-op state with its text history, isolated so typing after a swap-back does not merge into the typing before the command.
  const preRaw = doc.toString();
  const existing = registry.get(request.opId);
  const checkpoint = view.state.update({ annotations: isolateHistory.of('full') }).state;
  setRegistryEntry(request.opId, {
    checkpoint,
    preOpDoc: view.state.doc,
    postOpDoc: doc, // placeholder until the dispatch has landed
    midOp: true,
    markdown: { kind: 'reorder', request, opChanges: plan.changes, moved: plan.moved, postSelection: plan.selection },
  });

  // 3. One dispatch: the move, the separators, the level rewrites and the selection in ONE transaction. addToHistory:false maps both
  // history branches through the move (a deletion inside the moved range maps away, an insertion lands at the removal point; see
  // redo-branch.ts for how the undo and redo handle the redo branch); isolateHistory('full') closes the typing group on both sides.
  let dispatched = false;
  try {
    withAppOrigin(() =>
      view.dispatch({
        changes: plan.changes,
        selection: plan.selection,
        annotations: [Transaction.addToHistory.of(false), isolateHistory.of('full')],
      })
    );
    dispatched = true;
  } catch (error) {
    if (existing) setRegistryEntry(request.opId, { ...existing, midOp: false });
    else deleteRegistryEntry(request.opId);
    trace(`markdown-reorder dispatch threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'dispatchThrew' };
  } finally {
    const entry = registry.get(request.opId);
    if (entry) {
      registry.set(request.opId, {
        ...entry,
        postOpDoc: dispatched ? view.state.doc : entry.postOpDoc,
        midOp: false,
      });
    }
  }

  trace(`markdown-reorder ${plan.detail}`);
  return { ok: true, preRaw, postRaw: view.state.doc.toString(), skippedIds: plan.skippedIds };
}

/** window.FinalFinal.markdownStructuralReorder: the click. See the header for the contract. Never throws. */
export function markdownStructuralReorder(json: string | object): MarkdownReorderResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const parsed = parseReorderRequest(json);
  if ('failure' in parsed) return parsed.failure;
  const result = runReorder(view, parsed.request);
  // Swift pushes this same value only after the writer's last write and the job's reservation; the page sets it now, so a Cmd-Z in that
  // gap finds this reorder on top. A refusal sets nothing.
  if (result.ok) setUndoDescriptor({ undoTopOpId: parsed.request.opId });
  return result;
}
