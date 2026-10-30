// Editor-first VERSION HISTORY RESTORES in MARKDOWN mode -- the page half (t-4a8fd8af, Phase 4b, Markdown slice 4, round B).
//
// The three Version History restores (Restore Entire Project, Replace Current Section, Insert as New Section) used to be the old body in
// Markdown mode: the database was written first and the editor then received the DB-assembled text as a `setContent` push, so anything
// typed in between was lost, the pushed text carried no hidden section markers (the Outline card click landed far away) and the Cmd-Z took
// the slow "Undoing..." route. Here the EDITOR changes first, in one synchronous JavaScript task and ONE transaction: it swaps the restored
// text in. A queued job on the Swift side makes the database agree afterwards (`StructuralReplaceJob`, the one Rich Text uses). Rich Text
// does the same (web/milkdown/src/api-structural-replace.ts); this is the CodeMirror counterpart, working on text.
//
// ONE window.FinalFinal entry point:  markdownStructuralRestore(request)   (the click; takes a JSON string or a parsed object)
// The undo and redo of the entry are `markdownStructuralSwap(opId, 'undo' | 'redo')` (api-structural-markdown.ts), unchanged in shape:
// the undo swaps the pre-op state back in, the redo is the COMPOSED redo (`composedRedo`: the recorded change, then the small difference
// to the settled post-op document), so the same ids (the markers inside `text`) come back.
//
// THE TEXT. Swift builds `text` BEFORE it calls the page: the restored blocks assembled the way the rows assemble (blocks joined by a blank
// line, no trailing newline for a section; the document's own ending for a whole restore) with `<!-- @sid:ID -->` glued in front of every
// leader row (the ids the queued job will give the rows). The page inserts it verbatim, so page text and rows name the same ids from the
// first moment; the page never makes up an id.
//
// ---------------------------------------------------------------------------------------------------------------------------
// THE JSON CONTRACT (Swift builds `MarkdownLeaderMap.RestoreRequest`; the page returns `MarkdownRestoreResult`)
// ---------------------------------------------------------------------------------------------------------------------------
// The request carries the delete's leader fields (api-structural-markdown.ts `MarkdownStructuralRequest`, checked against the live text the
// way the delete checks them) with `kind: 'restore'`, a `mode` and the `text`:
//
//   kind:        'restore'
//   opId:        string          // the structural entry's id (also the registry key)
//   mode:        'whole' | 'section' | 'insertAfter'
//   rootId:      string | null   // section: the target heading (required). insertAfter: the anchor leader; null = none (insert before the
//                                // first managed leader, i.e. after the last section). whole: null (ignored if present).
//   leaders:     MarkdownLeader[]// EVERY leader of the document, in sort order, Notes and Bibliography included (as for the delete).
//                                // Present in every mode; not checked for `whole`.
//   stopLine:    string | null   // the trimmed first line of the first Notes/Bibliography row after the root (after the start of the
//                                // document when rootId is null), leader or not; null when there is none (always null for `whole`)
//   endLeaderId: null            // always null; accepted for parity with the delete's request and never read
//   text:        string          // what goes in (see THE TEXT). A string, possibly empty. Never trimmed or normalised by the page.
//
// The reply is `MarkdownStructuralResult` (`ok`, `reason`, `detail`, `preRaw`, `postRaw`, as for the delete) plus, when ok:
//
//   replaced:          { from: number; to: number }   // the hull of the change in the POST-op document: from the start of the first
//                                                    // changed hunk to the end of the last one (for an insertion: the inserted text,
//                                                    // the blank-line separator included). `{from: at, to: at}` when nothing changed.
//   insertedLeaderIds: string[]                       // the `<!-- @sid:ID -->` markers found at the start of a line of `text`, in order.
//                                                    // Only a cross-check against the plan's new leaders on the Swift side.
//
// FAILURES (nothing is changed, recorded or dispatched; the undo descriptor is not touched):
//   badRequest      the JSON is malformed, `mode` is none of the three, `text` is not a string, `leaders` / `stopLine` / `rootId` are
//                   malformed, `rootId` is missing for a section, or the root / anchor is the Notes or Bibliography heading
//                   (`detail: 'rootIsManaged'`)
//   unsupportedKind `kind` is not 'restore'
//   noEditor        no editor is mounted
//   leadersMismatch the leaders do not match the live text (Swift flushes the typing and retries once), or the range cannot be found
//                   (`rootMissing`, `stopLineMissing`, `emptyRange`). Not for `whole`: nothing to locate.
//   dispatchThrew   CodeMirror refused the transaction (the registry entry is removed again)
//
// THE RANGE (the FLAT range, SnapshotService.flatRange / milkdown findFlatSectionRange: sub-sections are NOT part of it):
//   section      from the start of the root leader's line to the first later leader of ANY level (Notes and Bibliography included) or the
//                line `stopLine` names, whichever comes first; the end of the document otherwise.
//   insertAfter  a pure insertion at the end of the anchor's flat range (the same end rule). Without an anchor: at the first managed
//                (Notes/Bibliography) leader or the `stopLine` line, whichever comes first, else the end of the document.
//   whole        [0, doc.length).
// THE SEPARATORS (blocks are separated by one blank line; a heading is never glued to the line before it):
//   section, a leader or stop line follows   `text + "\n\n"` replaces the range (the blank line before the next leader is part of it).
//   section, the range ends the document     `text` replaces the range WITHOUT its trailing newlines: the document keeps its ending.
//   insertAfter, a leader or stop line follows   `text + "\n\n"` is inserted at the start of that line (a blank line precedes the leader).
//   insertAfter, the end of the document     `"\n\n" + text` is inserted in front of the document's trailing newlines (nothing, when the
//                text before them is empty): the document keeps its ending.
//   whole        `text` replaces everything, exactly.
// THE CHANGE SET. ONE ChangeSet. Replace and whole: `computeRefinedChanges(oldSlice, replacement)` (text-diff.ts), shifted to the start of
//   the range: only the characters that really differ change, so a caret in an unchanged paragraph, the scroll position and the history
//   events there stay where they are, and the cost is bounded (line-level Myers, one span past a few thousand differences). Not one big
//   replace. Insertion: one pure insertion.
// THE CARET. No scrollIntoView on the dispatch: the page stays where the user reads, in all three modes.
//   Replace / whole: the selection is mapped through the change set; a caret inside a changed hunk goes to the start of that hunk (assoc
//   -1); a selection that overlaps a hunk collapses to its head. Any other selection keeps both ends and its direction.
//   Insertion: the Duplicate's mapping (api-structural-markdown-duplicate.ts THE CARET): a caret at the insertion point stays with the text
//   that follows (the Notes heading); at the end of the document every position from the insertion point onward stays at the end of the
//   text before it, so the next typing lands there.
//
// THE ENTRY: `registry.set(opId, { checkpoint, preOpDoc, postOpDoc, midOp, markdown: { kind: 'restore', request, opChanges, moved,
//   postSelection } })`, recorded BEFORE the dispatch with `midOp: true` (the page's own change must not advance the saved copies);
//   `finally` clears `midOp` and sets `postOpDoc`. A throwing dispatch removes the entry (or puts a previous entry of the same opId back).
//   The checkpoint is the pre-op state with its text history, already isolated.
//   `moved` is the hull of the change in the post-op document (`replaced`, or null when nothing changed); the undo's redo carry drops the
//   redo events that touch it (redo-branch.ts) and the set-aside / put-back brings them back after the redo. For an insertion at the end
//   of the document it starts behind the `\n\n` in front of the text, so typing appended to the end of the text before it stays in the carry.
// THE REDO LIST (step 1b, as in the delete): before anything is recorded, the redo events that lie inside a span this removes are taken
//   out of the redo list (`withoutRedoEventsTouching`, installed with the label 'restore-trim'), because the dispatch maps such an event to
//   the removal point and a later Cmd-Shift-Z would type it there, glued to whatever follows. An insertion removes nothing: no-op.
//   It runs before `preRaw` and the checkpoint are taken, so the entry's pre-op state is the trimmed one.
// THE DESCRIPTOR: on success the page sets `{ undoTopOpId: opId }` itself (Swift's push comes later); a refusal sets nothing.
// THE HISTORY: `addToHistory: false` and `isolateHistory('full')`, so typing before and after the command never merges into one undo
//   step. The click also forgets the recent-edit span (recent-edit-span.ts): typing that ended inside the changed text must not make the
//   app's own rewrite of the restored text (the settle's footnote renumber, anchors) an undo step.
// NO QUICK RE-RUN. Unlike the delete, the restore has none: its redo is the composed redo, through the shared midOp block of
//   `markdownStructuralSwap`, which reads the redo depth BEFORE the redo and puts the set-aside redo steps back after it.

import { isolateHistory } from '@codemirror/commands';
import { ChangeSet, EditorSelection, type Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import {
  installState,
  leaderMismatchDetail,
  type MarkdownRestoreRequest,
  type MarkdownStructuralFailure,
  type MarkdownStructuralResult,
  parseRequest,
  scanDocument,
  trace,
} from './api-structural-markdown';
import { getEditorExtensions, getEditorView } from './editor-state';
import { clearRecentUserEditSpan } from './recent-edit-span';
import { type MovedRange, removedSpans, withoutRedoEventsTouching } from './redo-branch';
import { computeRefinedChanges } from './text-diff';
import { withAppOrigin } from './typewriter-plugin';
import { deleteRegistryEntry, getRegistry, setRegistryEntry, setUndoDescriptor } from './undo-coordinator';

// === The reply ===

export interface MarkdownRestoreResult extends MarkdownStructuralResult {
  /** The hull of the change in the post-op document (see the header). ok only. */
  replaced?: MovedRange;
  /** The `<!-- @sid:ID -->` markers at the start of a line of the request's `text`, in order. ok only. */
  insertedLeaderIds?: string[];
}

// === The plan ===

export interface RestorePlan {
  ok: true;
  changes: ChangeSet;
  /** The number of changed hunks (for the trace). */
  hunks: number;
  /** The span whose redo events the undo's carry leaves out (post-op coordinates); null when nothing changed. */
  moved: MovedRange | null;
  /** The hull of the change in the post-op document, reported to Swift. */
  replaced: MovedRange;
  /** The selection after the change (see THE CARET in the header). */
  mapSelection: (selection: EditorSelection) => EditorSelection;
}
export type RestorePlanOutcome = RestorePlan | { ok: false; failure: MarkdownRestoreResult };

function refusal(reason: MarkdownStructuralFailure, detail: string): RestorePlanOutcome {
  return { ok: false, failure: { ok: false, reason, detail } };
}

/** How many newlines end the document (the trailing empty lines). */
function trailingNewlineCount(doc: Text): number {
  let count = 0;
  for (let n = doc.lines; n > 1; n--) {
    if (doc.line(n).length !== 0) break;
    count++;
  }
  return count;
}

/** The selection after a replacement made of the hunks of `changes`: a caret inside a hunk goes to the hunk's start; a selection that
 * overlaps a hunk collapses to its head; any other selection keeps both ends and its direction. */
function mapThroughReplacement(changes: ChangeSet, selection: EditorSelection): EditorSelection {
  const hunks: MovedRange[] = [];
  changes.iterChangedRanges((fromA, toA) => {
    hunks.push({ from: fromA, to: toA });
  });
  const overlapsHunk = (from: number, to: number): boolean => hunks.some((hunk) => from < hunk.to && to > hunk.from);
  const ranges = selection.ranges.map((range) => {
    if (range.empty || overlapsHunk(range.from, range.to))
      return EditorSelection.cursor(changes.mapPos(range.head, -1));
    const from = changes.mapPos(range.from, 1);
    const to = changes.mapPos(range.to, -1);
    return range.anchor <= range.head ? EditorSelection.range(from, to) : EditorSelection.range(to, from);
  });
  return EditorSelection.create(ranges, selection.mainIndex);
}

/** The plan of a change made of refined hunks (replace and whole): hull, reported range, selection mapping. */
function replacementPlan(changes: ChangeSet, at: number): RestorePlan {
  let hullFrom = Number.POSITIVE_INFINITY;
  let hullTo = -1;
  let hunks = 0;
  changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    hullFrom = Math.min(hullFrom, fromB);
    hullTo = Math.max(hullTo, toB);
    hunks++;
  });
  const hull = hullTo >= 0 ? { from: hullFrom, to: hullTo } : null;
  return {
    ok: true,
    changes,
    hunks,
    moved: hull,
    replaced: hull ?? { from: at, to: at },
    mapSelection: (selection) => mapThroughReplacement(changes, selection),
  };
}

/** The refined change set turning `doc[from, to)` into `replacement`, as one ChangeSet in the document's offsets. */
function refinedChanges(doc: Text, from: number, to: number, replacement: string): ChangeSet {
  const slice = from === 0 && to === doc.length ? doc.toString() : doc.sliceString(from, to);
  const specs = computeRefinedChanges(slice, replacement).map((change) => ({
    from: from + change.from,
    to: from + change.to,
    insert: change.insert,
  }));
  return ChangeSet.of(specs, doc.length);
}

/** The plan of a pure insertion of `insert` at `at`; `endsDocument` is true when it goes in at the end of the document. */
function insertionPlan(doc: Text, at: number, insert: string, endsDocument: boolean): RestorePlan {
  const changes = ChangeSet.of({ from: at, insert }, doc.length);
  // THE CARET (the Duplicate's mapping). Where the text ends the document, anything from the end of the text before it to the end of the
  // document (the trailing newlines) stays at the end of that text; in the middle everything after the insertion point moves with it.
  const place = (pos: number, assoc: -1 | 1): number => (endsDocument && pos >= at ? at : changes.mapPos(pos, assoc));
  const mapSelection = (selection: EditorSelection): EditorSelection => {
    const ranges = selection.ranges.map((range) => {
      if (range.empty) return EditorSelection.cursor(place(range.head, endsDocument ? -1 : 1));
      if (!endsDocument && range.from < at && range.to > at) return EditorSelection.cursor(place(range.head, 1));
      const from = place(range.from, 1);
      const to = place(range.to, -1);
      return range.anchor <= range.head ? EditorSelection.range(from, to) : EditorSelection.range(to, from);
    });
    return EditorSelection.create(ranges, selection.mainIndex);
  };
  const replaced = { from: at, to: at + insert.length };
  return {
    ok: true,
    changes,
    hunks: 1,
    // Behind the `\n\n` in front of the text when it ends the document (typing appended to the end of the text before it sits at `at`).
    moved: { from: endsDocument && at > 0 ? at + 2 : at, to: replaced.to },
    replaced,
    mapSelection,
  };
}

/** Matches the leaders, computes the range and builds the one change set. Pure: reads `doc`, changes nothing. */
export function planRestore(doc: Text, request: MarkdownRestoreRequest): RestorePlanOutcome {
  const { mode, text, leaders } = request;

  // whole: nothing to locate, no leader check.
  if (mode === 'whole') return replacementPlan(refinedChanges(doc, 0, doc.length, text), 0);

  let rootIdx = -1;
  if (request.rootId !== null) {
    const rootId = request.rootId;
    rootIdx = leaders.findIndex((leader) => leader.id === rootId);
    if (rootIdx < 0) return refusal('leadersMismatch', 'rootMissing');
    if (leaders[rootIdx].managed !== undefined) return refusal('badRequest', 'rootIsManaged');
  } else if (mode === 'section') {
    return refusal('badRequest', 'rootId');
  }

  const scan = scanDocument(doc, request.stopLine);
  const mismatchDetail = leaderMismatchDetail(scan, leaders);
  if (mismatchDetail !== null) return refusal('leadersMismatch', mismatchDetail);

  // The end of the flat range: the next leader of ANY level (an anchor), or the first managed leader (no anchor); the end of the
  // document otherwise. A stop line ends it too, whichever comes first.
  const start = rootIdx >= 0 ? scan.candidates[rootIdx].from : 0;
  let end = doc.length;
  if (rootIdx >= 0) {
    const next = scan.candidates[rootIdx + 1];
    if (next) end = next.from;
  } else {
    const firstManaged = leaders.findIndex((leader) => leader.managed !== undefined);
    if (firstManaged >= 0) end = scan.candidates[firstManaged].from;
  }
  if (request.stopLine) {
    const hit = scan.stopHits.find((from) => rootIdx < 0 || from > start);
    if (hit === undefined) return refusal('leadersMismatch', 'stopLineMissing');
    end = Math.min(end, hit);
  }
  const endsDocument = end === doc.length;

  if (mode === 'section') {
    if (end <= start) return refusal('leadersMismatch', 'emptyRange');
    // A leader or stop line follows: the blank line in front of it is part of the replaced range. At the end of the document the
    // range's trailing newlines stay, so the document keeps its ending.
    const replaceTo = endsDocument ? end - trailingNewlineCount(doc) : end;
    const replacement = endsDocument ? text : `${text}\n\n`;
    return replacementPlan(refinedChanges(doc, start, replaceTo, replacement), start);
  }

  // insertAfter
  if (!endsDocument) return insertionPlan(doc, end, `${text}\n\n`, false);
  const at = doc.length - trailingNewlineCount(doc);
  return insertionPlan(doc, at, at === 0 ? text : `\n\n${text}`, true);
}

// === The click ===

/** The `<!-- @sid:ID -->` markers at the start of a line of `text`, in order. */
function markersOf(text: string): string[] {
  const ids: string[] = [];
  for (const match of text.matchAll(/^<!-- @sid:([0-9a-fA-F-]+) -->/gm)) ids.push(match[1]);
  return ids;
}

/** Plans the command, trims the redo list, records the entry, dispatches once. Nothing is recorded or dispatched on a refusal. */
function runRestore(view: EditorView, request: MarkdownRestoreRequest): MarkdownRestoreResult {
  const started = performance.now();
  const registry = getRegistry();

  // 1. Plan first. A refusal (or any failure) returns here: nothing is recorded and nothing is dispatched.
  let plan: RestorePlanOutcome;
  try {
    plan = planRestore(view.state.doc, request);
  } catch (error) {
    trace(`markdown-restore plan threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'badRequest', detail: 'planThrew' };
  }
  if (!plan.ok) return plan.failure;

  // 1b. A redo event that is already waiting (typing taken back with Cmd-Z before the restore) and lies inside a span this removes would
  // be mapped to the removal point by the dispatch below and a later Cmd-Shift-Z would type it there, glued to the text that follows
  // (" hello## 3.2"). Such events leave the redo list first, as in the delete (api-structural-markdown.ts step 1b). An insertion
  // removes nothing: no-op. Before `preRaw` and the checkpoint, so the entry's pre-op state is the trimmed one.
  const trimmed = withoutRedoEventsTouching(view.state, removedSpans(plan.changes), getEditorExtensions());
  if (trimmed) {
    try {
      installState(view, trimmed.state, { label: 'restore-trim', keepScroll: true });
      trace(`markdown-restore redo list trimmed dropped=${trimmed.dropped}`);
    } catch (error) {
      trace(`markdown-restore redo trim threw: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  // 2. Record the entry BEFORE the dispatch, mid-op: the dispatch below is a sync-origin change, and the saved copies must not follow the
  // page's own change. The checkpoint is the pre-op state with its text history, isolated so typing after a swap-back does not merge
  // into the typing before the command.
  const preDoc = view.state.doc;
  const preRaw = preDoc.toString();
  const existing = registry.get(request.opId);
  const selection: EditorSelection = plan.mapSelection(view.state.selection);
  const checkpoint = view.state.update({ annotations: isolateHistory.of('full') }).state;
  setRegistryEntry(request.opId, {
    checkpoint,
    preOpDoc: preDoc,
    postOpDoc: preDoc, // placeholder until the dispatch has landed
    midOp: true,
    markdown: {
      kind: 'restore',
      request,
      opChanges: plan.changes,
      moved: plan.moved,
      postSelection: selection,
    },
  });

  // 3. One dispatch: the change and the selection in ONE transaction, with no scrollIntoView. addToHistory:false maps both history
  // branches through the change; isolateHistory('full') closes the typing group on both sides of the command.
  let dispatched = false;
  try {
    withAppOrigin(() =>
      view.dispatch({
        changes: plan.changes,
        selection,
        annotations: [Transaction.addToHistory.of(false), isolateHistory.of('full')],
      })
    );
    dispatched = true;
    // Typing that ended inside the changed text within the last 2.5 s left a tracked "recent edit" span: the app's own rewrite of the
    // restored text that follows (the settle's footnote renumber, anchors) would be taken for competing with the typing.
    clearRecentUserEditSpan();
  } catch (error) {
    if (existing) setRegistryEntry(request.opId, { ...existing, midOp: false });
    else deleteRegistryEntry(request.opId);
    trace(`markdown-restore dispatch threw: ${error instanceof Error ? error.message : String(error)}`);
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

  trace(
    `markdown-restore mode=${request.mode} hunks=${plan.hunks} replaced=${plan.replaced.to - plan.replaced.from} ms=${Math.round(performance.now() - started)}`
  );
  return {
    ok: true,
    preRaw,
    postRaw: view.state.doc.toString(),
    replaced: plan.replaced,
    insertedLeaderIds: markersOf(request.text),
  };
}

/** window.FinalFinal.markdownStructuralRestore: the click. See the header for the contract. Never throws. */
export function markdownStructuralRestore(json: string | object): MarkdownRestoreResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const parsed = parseRequest(json, 'restore');
  if ('failure' in parsed) return parsed.failure;
  const result = runRestore(view, parsed.request);
  // Swift pushes this same value only after the writer's last write and the job's reservation; the page sets it now, so a Cmd-Z in that
  // gap finds this restore on top. A refusal sets nothing.
  if (result.ok) setUndoDescriptor({ undoTopOpId: parsed.request.opId });
  return result;
}
