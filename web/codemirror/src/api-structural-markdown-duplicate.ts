// Editor-first DUPLICATE SECTION in MARKDOWN mode -- the page half (t-4a8fd8af, Phase 4b, Markdown slice 3, round B).
//
// A Duplicate Section in Markdown mode used to be the old body: the database copied the rows first and the editor then received the
// DB-assembled text as a `setContent` push, so anything typed in between was lost and the card click landed far from the copy. Here the
// EDITOR changes first, in one synchronous JavaScript task and ONE transaction: it inserts the copy right after the section. A queued
// job on the Swift side makes the database agree afterwards (`SectionDuplicateJob`, the one Rich Text uses). Rich Text does the same
// (web/milkdown/src/api-section-duplicate.ts); this is the CodeMirror counterpart, working on text.
//
// ONE window.FinalFinal entry point:  markdownStructuralDuplicate(request)   (the click; takes a JSON string or a parsed object)
// The undo and redo of the entry are `markdownStructuralSwap(opId, 'undo' | 'redo')` (api-structural-markdown.ts), unchanged in shape:
// the undo swaps the pre-op state back in, the redo is the COMPOSED redo (`composedRedo`: the recorded insertion, then the small difference
// to the settled post-op document), so the same copy ids come back.
//
// THE COPY IDS. Swift mints the id of every copied leader BEFORE it calls the page (`copyIds`), and the page writes each one into the
// copy's `<!-- @sid:NEW -->` marker; the queued job gives the copy rows the same ids. So the Outline card of the copy, the page and the
// rows agree from the moment of the click, and nothing pushes the whole document back.
//
// ---------------------------------------------------------------------------------------------------------------------------
// THE JSON CONTRACT (Swift builds `MarkdownDuplicateRequest`; the page returns `MarkdownDuplicateResult`)
// ---------------------------------------------------------------------------------------------------------------------------
// The request is the delete's (api-structural-markdown.ts `MarkdownStructuralRequest`: `opId`, `rootId`, `leaders`, `stopLine`,
// `endLeaderId`, checked against the live text exactly as the delete checks them) with `kind: 'duplicate'` and one more field:
//
//   copyIds: Array<{ source: string; new: string }>
//        // one pair per leader of the section's subtree: the root and every deeper leader up to the end of the range, in document
//        // order (`MarkdownLeaderMap.removedLeaderIds(rootId:)` on the Swift side). `source` is that leader row's id and must equal the
//        // k-th leader of the range; `new` is the id its copy gets. Both are strings of hex digits and dashes (`/^[0-9a-fA-F-]+$/`):
//        // the id goes into the text inside a comment, so nothing else is accepted.
//
// The reply is `MarkdownStructuralResult` (`ok`, `reason`, `detail`, `preRaw`, `postRaw`, exactly as for the delete) plus, when ok:
//
//   inserted:        { from: number; to: number }     // what the click inserted, in the POST-op document (the blank-line separator
//                                                     // included): postRaw.slice(from, to)
//   insertedLeaders: Array<{ id: string; kind: 'heading' | 'section_break'; level: number; title: string }>
//        // the copy's leaders in document order: the new id, the kind, the level the original leader row has, and the title as the rows
//        // will hold it for a heading (the heading text after the `#` run, as the page sees it -- markdown is not interpreted; the root's
//        // gets " copy"); '' for a section break. Swift's overlay prefers the rows' own text and uses this list as the cross-check.
//
// FAILURES (nothing is changed, recorded or dispatched; the undo descriptor is not touched):
//   badRequest      the JSON is malformed, `copyIds` is missing or holds an id outside `/^[0-9a-fA-F-]+$/`, the root is the Notes or
//                   Bibliography heading (`detail: 'rootIsManaged'`), or `copyIds` does not match the range (`detail: 'copyIds count=N
//                   range=M'` / `'copyIds source K'`)
//   unsupportedKind `kind` is not 'duplicate'
//   noEditor        no editor is mounted
//   leadersMismatch the leaders do not match the live text (Swift flushes the typing and retries once), or the range cannot be found
//                   (`rootMissing`, `stopLineMissing`, `emptyRange`, `endLeader`)
//   dispatchThrew   CodeMirror refused the transaction (the registry entry is removed again)
//
// THE RANGE (the delete's rule, planDelete in api-structural-markdown.ts; kept as its own copy so the delete's code stays untouched):
//   from the start of the root leader's line to the first later leader that is Notes/Bibliography or whose level is not deeper than the
//   root's, or the line `stopLine` names, whichever comes first; the end of the document otherwise.
// THE COPY TEXT. The range's text with EVERY copied leader line rewritten: any leading `<!-- @sid:... -->` marker is taken off and
//   `<!-- @sid:NEW -->` goes in front. The root line also gets " copy" at its end, but only when the root is a heading (a section-break
//   root, `<!-- ::break:: -->`, gets none): byte for byte what the database does to the copy row (`duplicateSections`). Everything else
//   (footnote references, images, body lines) is copied as it stands.
// WHERE IT GOES. At the end of the range, so the copy follows the section it copies (a Duplicate of a Duplicate puts the new copy right
//   after the ORIGINAL it was made from, in front of the earlier copy, because the earlier copy's heading ends the range). A range that
//   ends at the end of the document goes in before the document's trailing newlines, with a blank line in front, so the copy is
//   separated from the original by one blank line and the document keeps its ending: the text is what the rows assemble to
//   (blocks joined by a blank line). The other ends of the range are blank-line separated already (a leader follows).
// THE CARET. The selection is mapped through the insertion so the caret stays with the text it was in: a caret at the start of the next
//   chapter's heading (the insertion point) stays at that heading, a caret inside the section stays in the original. At the end of the
//   document the insertion point is where the original ends, and every position from there to the end of the document (the original's
//   last line end and the trailing newlines) stays at the end of the original, so the next typing lands in the original. A selection
//   that straddles the insertion point in the middle of the document would swell to hold the copy and collapses to its head; any other
//   selection keeps its ends (a selection ending exactly at the end of the section stays in the original, one starting at the next
//   heading goes with it) and its direction.
//
// THE ENTRY: `registry.set(opId, { checkpoint, preOpDoc, postOpDoc, midOp, markdown: { kind: 'duplicate', request, opChanges, moved,
//   postSelection } })`, recorded BEFORE the dispatch with `midOp: true` (the page's own change must not advance the saved copies);
//   `finally` clears `midOp` and sets `postOpDoc`. A throwing dispatch removes the entry. The checkpoint is the pre-op state with its text
//   history, already isolated.
// THE DESCRIPTOR: on success the page sets `{ undoTopOpId: opId }` itself (Swift's push comes later); a refusal sets nothing.
// THE HISTORY: one ChangeSet, `addToHistory: false` and `isolateHistory('full')`, so typing before and after the command never merges
//   into one undo step. A pure insertion removes nothing, so unlike the delete and the reorder the click has no redo list to trim first
//   (an event waiting at the insertion point lands after the copy, with the text it was typed in front of).
//   `moved` (the span whose redo events the undo's carry leaves out) is the inserted text; for a copy at the end of the document it
//   starts behind the `\n\n` in front of the copy, so typing appended to the end of the original (which sits at the insertion point) is
//   carried with the original and not dropped as if it were inside the copy. The click also forgets the recent-edit span
//   (recent-edit-span.ts): typing that ended at the insertion point must not make the app's own rewrite of the copy an undo step.

import { isolateHistory } from '@codemirror/commands';
import { ChangeSet, EditorSelection, type Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import {
  ATX_HEADING,
  leaderMismatchDetail,
  type MarkdownDuplicateRequest,
  type MarkdownStructuralFailure,
  type MarkdownStructuralResult,
  parseRequest,
  scanDocument,
  trace,
} from './api-structural-markdown';
import { getEditorView } from './editor-state';
import { clearRecentUserEditSpan } from './recent-edit-span';
import type { MovedRange } from './redo-branch';
import { withAppOrigin } from './typewriter-plugin';
import { deleteRegistryEntry, getRegistry, setRegistryEntry, setUndoDescriptor } from './undo-coordinator';

// === The reply ===

export interface MarkdownInsertedLeader {
  id: string;
  kind: 'heading' | 'section_break';
  level: number;
  title: string;
}

export interface MarkdownDuplicateResult extends MarkdownStructuralResult {
  /** What was inserted (separator included), in the post-op document. ok only. */
  inserted?: MovedRange;
  /** The copy's leaders in document order. ok only. */
  insertedLeaders?: MarkdownInsertedLeader[];
}

// === The plan ===

/** A leading section anchor with the blanks around it: the part of a leader line that the copy replaces. */
const LEADING_ANCHORS = /^\s*(?:<!-- @sid:[0-9a-fA-F-]+ -->\s*)*/;

interface DuplicatePlan {
  ok: true;
  changes: ChangeSet;
  /** The inserted text and where it starts, in the pre-op document (= in the post-op document, nothing before it moves). */
  inserted: MovedRange;
  /** The text whose redo events the undo's carry leaves out (redo-branch.ts): the inserted text, except that for a copy at the end of the
   * document it starts behind the `\n\n` in front of the copy, so typing appended to the end of the ORIGINAL stays in the carry. */
  moved: MovedRange;
  /** The selection after the insertion (see THE CARET in the header). */
  mapSelection: (selection: EditorSelection) => EditorSelection;
  leaders: MarkdownInsertedLeader[];
}
type PlanOutcome = DuplicatePlan | { ok: false; failure: MarkdownDuplicateResult };

function refusal(reason: MarkdownStructuralFailure, detail: string): PlanOutcome {
  return { ok: false, failure: { ok: false, reason, detail } };
}

/** Matches the leaders, computes the range, checks `copyIds` against it and builds the one change set. Pure: reads `doc`, changes nothing. */
function planDuplicate(doc: Text, request: MarkdownDuplicateRequest): PlanOutcome {
  const { leaders, copyIds } = request;
  const rootIdx = leaders.findIndex((leader) => leader.id === request.rootId);
  if (rootIdx < 0) return refusal('leadersMismatch', 'rootMissing');
  const root = leaders[rootIdx];
  if (root.managed !== undefined) return refusal('badRequest', 'rootIsManaged');

  const scan = scanDocument(doc, request.stopLine);
  const mismatchDetail = leaderMismatchDetail(scan, leaders);
  if (mismatchDetail !== null) return refusal('leadersMismatch', mismatchDetail);

  // The first later leader that ends the section: a Notes/Bibliography leader whatever its level, or one whose level is not deeper.
  let stopIdx = -1;
  for (let j = rootIdx + 1; j < leaders.length; j++) {
    if (leaders[j].managed !== undefined || leaders[j].level <= root.level) {
      stopIdx = j;
      break;
    }
  }
  if (request.endLeaderId !== undefined) {
    const endIdx = leaders.findIndex((leader, j) => j > rootIdx && leader.level <= root.level);
    const expected = endIdx >= 0 ? leaders[endIdx].id : null;
    if (expected !== request.endLeaderId) return refusal('leadersMismatch', 'endLeader');
  }

  const start = scan.candidates[rootIdx].from;
  let end = stopIdx >= 0 ? scan.candidates[stopIdx].from : doc.length;
  if (request.stopLine) {
    const hit = scan.stopHits.find((from) => from > start);
    if (hit === undefined) return refusal('leadersMismatch', 'stopLineMissing');
    end = Math.min(end, hit);
  }
  if (end <= start) return refusal('leadersMismatch', 'emptyRange');

  // The leaders inside the range, root first. `copyIds` must name exactly these, in this order.
  let count = 0;
  while (rootIdx + count < scan.candidates.length && scan.candidates[rootIdx + count].from < end) count++;
  if (copyIds.length !== count) return refusal('badRequest', `copyIds count=${copyIds.length} range=${count}`);
  for (let k = 0; k < count; k++) {
    if (copyIds[k].source !== leaders[rootIdx + k].id) return refusal('badRequest', `copyIds source ${k}`);
  }

  // The copy text: the range, every copied leader line rewritten.
  let copyText = '';
  let cursor = start;
  const inserted: MarkdownInsertedLeader[] = [];
  for (let k = 0; k < count; k++) {
    const candidate = scan.candidates[rootIdx + k];
    const line = doc.lineAt(candidate.from);
    const isHeading = ATX_HEADING.test(candidate.text);
    let rest = line.text.replace(LEADING_ANCHORS, '');
    if (k === 0 && isHeading) rest = `${rest.trimEnd()} copy`;
    copyText += `${doc.sliceString(cursor, line.from)}<!-- @sid:${copyIds[k].new} -->${rest}`;
    cursor = line.to;
    const title = isHeading ? candidate.text.replace(/^#{1,6}/, '').trim() : '';
    inserted.push({
      id: copyIds[k].new,
      kind: isHeading ? 'heading' : 'section_break',
      level: leaders[rootIdx + k].level,
      title: k === 0 && isHeading ? `${title} copy` : title,
    });
  }
  copyText += doc.sliceString(cursor, end);

  // Where it goes. Before a following leader or stop line the range ends in the blank line that separates it, and the copy ends in the
  // same one. A range that runs to the end of the document goes in before the document's trailing newlines, behind a blank line.
  let at = end;
  let insert = copyText;
  if (end === doc.length) {
    const trailing = /\n*$/.exec(copyText)?.[0].length ?? 0;
    at = end - trailing;
    insert = `\n\n${copyText.slice(0, copyText.length - trailing)}`;
  }
  const changes = ChangeSet.of({ from: at, insert }, doc.length);
  const endsDocument = end === doc.length;
  // THE CARET. Where the copy ends the document, anything from the end of the original's last line to the end of the document (the
  // trailing newlines) stays at the end of the original; a copy in the middle moves everything after the insertion point with it.
  const place = (pos: number, assoc: -1 | 1): number => (endsDocument && pos >= at ? at : changes.mapPos(pos, assoc));
  const mapSelection = (selection: EditorSelection): EditorSelection => {
    const ranges = selection.ranges.map((range) => {
      // A caret at the insertion point stays with the text that follows (the next chapter's heading), or with the original at the end.
      if (range.empty) return EditorSelection.cursor(place(range.head, endsDocument ? -1 : 1));
      // A selection that straddles the insertion point would swell to hold the copy: it collapses to its head instead.
      if (!endsDocument && range.from < at && range.to > at) return EditorSelection.cursor(place(range.head, 1));
      const from = place(range.from, 1);
      const to = place(range.to, -1);
      return range.anchor <= range.head ? EditorSelection.range(from, to) : EditorSelection.range(to, from);
    });
    return EditorSelection.create(ranges, selection.mainIndex);
  };
  return {
    ok: true,
    changes,
    inserted: { from: at, to: at + insert.length },
    moved: { from: endsDocument ? at + 2 : at, to: at + insert.length },
    mapSelection,
    leaders: inserted,
  };
}

// === The click ===

/** Plans the command, records the entry, dispatches once. Nothing is recorded or dispatched on a refusal. */
function runDuplicate(view: EditorView, request: MarkdownDuplicateRequest): MarkdownDuplicateResult {
  const registry = getRegistry();
  const doc = view.state.doc;

  // 1. Plan first. A refusal (or any failure) returns here: nothing is recorded and nothing is dispatched.
  let plan: PlanOutcome;
  try {
    plan = planDuplicate(doc, request);
  } catch (error) {
    trace(`markdown-duplicate plan threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'badRequest', detail: 'planThrew' };
  }
  if (!plan.ok) return plan.failure;

  // 2. Record the entry BEFORE the dispatch, mid-op, so the page's own change does not advance the saved copies. The checkpoint is the
  // pre-op state with its text history, isolated so typing after a swap-back does not merge into the typing before the command.
  const preRaw = doc.toString();
  const existing = registry.get(request.opId);
  const selection: EditorSelection = plan.mapSelection(view.state.selection);
  const checkpoint = view.state.update({ annotations: isolateHistory.of('full') }).state;
  setRegistryEntry(request.opId, {
    checkpoint,
    preOpDoc: view.state.doc,
    postOpDoc: doc, // placeholder until the dispatch has landed
    midOp: true,
    markdown: {
      kind: 'duplicate',
      request,
      opChanges: plan.changes,
      moved: plan.moved,
      postSelection: selection,
    },
  });

  // 3. One dispatch: the insertion and the selection in ONE transaction. addToHistory:false maps both history branches through the
  // insertion; isolateHistory('full') closes the typing group on both sides of the command.
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
    // Typing that ended at the insertion point within the last 2.5 s left a tracked "recent edit" span whose end the insertion has just
    // pushed past the copy (recent-edit-span.ts maps the end forward): the app's own rewrite of the copy that follows (the settle's
    // footnote renumber, anchors) would be taken for competing with the typing and become an undo step of its own.
    clearRecentUserEditSpan();
  } catch (error) {
    if (existing) setRegistryEntry(request.opId, { ...existing, midOp: false });
    else deleteRegistryEntry(request.opId);
    trace(`markdown-duplicate dispatch threw: ${error instanceof Error ? error.message : String(error)}`);
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

  trace(`markdown-duplicate leaders=${plan.leaders.length} inserted=${plan.inserted.to - plan.inserted.from}`);
  return {
    ok: true,
    preRaw,
    postRaw: view.state.doc.toString(),
    inserted: plan.inserted,
    insertedLeaders: plan.leaders,
  };
}

/** window.FinalFinal.markdownStructuralDuplicate: the click. See the header for the contract. Never throws. */
export function markdownStructuralDuplicate(json: string | object): MarkdownDuplicateResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const parsed = parseRequest(json, 'duplicate');
  if ('failure' in parsed) return parsed.failure;
  const result = runDuplicate(view, parsed.request);
  // Swift pushes this same value only after the writer's last write and the job's reservation; the page sets it now, so a Cmd-Z in that
  // gap finds this duplicate on top. A refusal sets nothing.
  if (result.ok) setUndoDescriptor({ undoTopOpId: parsed.request.opId });
  return result;
}
