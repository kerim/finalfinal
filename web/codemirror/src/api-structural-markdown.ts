// Editor-first structural commands in MARKDOWN mode -- the page half (t-4a8fd8af, slice 1, delete only).
//
// Today a Delete Section in Markdown mode is the old body: the database is changed first, and the editor then receives the
// DB-assembled text as a `setContent` push, so anything typed in between is lost. Here the EDITOR changes first, in one
// synchronous JavaScript task, and the database catches up afterwards through a queued job on the Swift side. Rich Text does
// the same (web/milkdown/src/api-section-delete.ts, api-section-undo.ts); this is the CodeMirror counterpart, working on text.
//
// Two window.FinalFinal entry points:
//
//   markdownStructuralEditorFirst(request)   the click: removes the section (and the footnote texts only it used) from the
//                                            document, records the registry entry, returns the raw text before and after.
//   markdownStructuralSwap(opId, direction)  the undo/redo turn of an entry: the undo swaps the pre-op EditorState back in
//                                            (with its own text history); the redo re-runs the command on the document as it is
//                                            now, or, for an entry the old body recorded, swaps the saved post-op text in.
//
// ---------------------------------------------------------------------------------------------------------------------------
// THE JSON CONTRACT (Swift builds `MarkdownStructuralRequest`; the page returns `MarkdownStructuralResult`)
// ---------------------------------------------------------------------------------------------------------------------------
// The page does not know the database. Swift sends the document's LEADERS (headings and section breaks) as the database holds
// them, in document order, and the page checks them against the live text before it touches anything:
//
//   interface MarkdownLeader {
//     id: string;                              // the leader row's block id
//     line: string;                            // the first line of the row's markdown, trimmed, with leading hidden markers
//                                              // removed (the page strips them again, so either form is accepted):
//                                              // "## Methods", "<!-- ::break:: -->"
//     level: number;                           // heading level 1-6; a section break is level 1
//     managed?: 'notes' | 'bibliography';      // set on the Notes / Bibliography heading rows (database isNotes / isBibliography)
//   }
//   interface MarkdownStructuralRequest {
//     kind: 'delete';                          // any other kind answers { ok:false, reason:'unsupportedKind' } (a Duplicate is
//                                              // its own entry point, api-structural-markdown-duplicate.ts)
//     opId: string;                            // the structural entry's id (also the registry key)
//     rootId: string;                          // the leader whose section is removed
//     leaders: MarkdownLeader[];               // EVERY leader of the document, in sort order, Notes and Bibliography included
//     stopLine?: string | null;                // the trimmed first line of the first Notes/Bibliography row (leader or not,
//                                              // e.g. "<!-- ::auto-bibliography:: -->") after the root; null/absent when none
//     endLeaderId?: string | null;             // the first later leader with level <= the root's level (null: none); a
//                                              // consistency check only -- the page derives the end from `leaders` itself
//   }
//   interface MarkdownStructuralResult {
//     ok: boolean;
//     reason?: 'badRequest' | 'unsupportedKind' | 'noEditor' | 'leadersMismatch' | 'dispatchThrew'      // the click
//            | 'noEntry' | 'midOp' | 'changed' | 'swapThrew';                                             // the swap
//     detail?: string;                         // counts and indexes only, never document text
//     preRaw?: string;                         // the raw document (anchors and markers included) before the call   -- ok only
//     postRaw?: string;                        // ... and after it                                                   -- ok only
//   }
//
// `markdownStructuralEditorFirst` takes the request as a JSON STRING (or an already parsed object).
// `markdownStructuralSwap(opId, direction, requestJson?)`: the optional third argument is a fresh request for a QUICK REDO (the
// leaders as the database holds them now); without it the redo re-runs the request stored with the entry.
//
// THE LEADER MATCH (a mismatch changes nothing, records nothing and dispatches nothing -- Swift flushes the typing and retries once):
//   * the line rule: strip, in a loop, any leading `<!-- @sid:... -->`, the bibliography opening marker and its end marker, then trim.
//     A line is a leader CANDIDATE when what is left is an ATX heading (`#{1,6}` then ONE Unicode white-space character, the way
//     BlockParser's ICU `^(#{1,6})\s+` reads it: U+3000 and NBSP count) or exactly the section-break marker.
//     Fenced code (``` only: BlockParser's splitter has no tilde fence, so a `~~~` line is ordinary text) and `$$` blocks are skipped,
//     the way the splitter skips them. The page must count EXACTLY what BlockParser counts: any difference is a leadersMismatch.
//   * every candidate must equal the next expected leader's line, and the counts must match exactly.
// THE RANGE (Database+SectionOps.swift resolveSectionSubtree):
//   * it starts at the start of the root leader's line;
//   * it runs through every following leader whose level is greater than the root's (a section break is level 1);
//   * it stops at the first Notes/Bibliography leader, at the line `stopLine` names, at the first leader whose level is not
//     greater, or at the end of the document -- whichever comes first.
// THE FOOTNOTES (O12): a footnote definition (`[^L]:` and its indented continuation lines, inside the Notes region found by its
//   leader) whose label is referenced ONLY inside the removed range goes with it, so the editor already holds what the footnote
//   resync will produce (no orphan, hence no duplicate label after the renumber). A label also referenced outside the range is
//   kept. If the Notes region cannot be found the definitions are left alone and the delete goes ahead.
//
// THE ENTRY: `registry.set(opId, { checkpoint, preOpDoc, postOpDoc, midOp, markdown })`. It is recorded BEFORE the dispatch with
//   `midOp: true` (so the page's own change does not advance the saved copies, B-2); `finally` clears `midOp` and sets `postOpDoc`
//   to the document the dispatch produced. A throwing dispatch removes the entry. The checkpoint is the pre-op state with its text
//   history, already isolated (see below).
// THE DESCRIPTOR: when the click succeeds it also sets `{ undoTopOpId: opId }` itself (`setUndoDescriptor`), because Swift's push of
//   the same value comes later (docs/architecture/unified-undo.md, "The registry/descriptor bridge protocol"). A refused click sets
//   nothing; the quick redo (`runDelete` via the swap) sets nothing.
// THE HISTORY: the dispatch is `addToHistory: false` with `isolateHistory('full')`, so typing before the command and typing after it
//   never merge into one undo step. `addToHistory: false` maps BOTH history branches through the removal. In the DONE branch an event
//   inside the removed range maps away (the removed text has nothing left to undo; Rich Text's delete does the same,
//   quick-undo-redo-history.test.ts QU19). In the REDO branch an INSERTION inside the removed range survives at the removal point, the
//   start of the next heading line, so the click first takes such events out of the redo list (`withoutRedoEventsTouching`, step 1b).

import { historyField, isolateHistory, redoDepth } from '@codemirror/commands';
import { getSearchQuery, type SearchQuery, setSearchQuery } from '@codemirror/search';
import { ChangeSet, type EditorSelection, type EditorState, type Text, Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import type { MarkdownReorderRequest } from './api-structural-markdown-reorder';
import { getEditorExtensions, getEditorView } from './editor-state';
import { readImageMeta, setImageMeta } from './image-preview-plugin';
import { installLineHeightFix } from './line-height-fix';
import { clearRecentUserEditSpan } from './recent-edit-span';
import {
  carryRedoBranch,
  clearSetAsideRedo,
  type MovedRange,
  putBackRedo,
  removedSpans,
  setAsideRedo,
  withoutRedoEventsTouching,
} from './redo-branch';
import { resetSpellcheckAfterStateSwap } from './spellcheck-plugin';
import { computeRefinedChanges } from './text-diff';
import { withAppOrigin } from './typewriter-plugin';
import {
  decideLiveRouting,
  deleteRegistryEntry,
  getRegistry,
  setRegistryEntry,
  setUndoDescriptor,
  type UndoRegistryEntry,
} from './undo-coordinator';

// === The contract (see the header) ===

export interface MarkdownLeader {
  id: string;
  line: string;
  level: number;
  managed?: 'notes' | 'bibliography';
}

export interface MarkdownStructuralRequest {
  kind: 'delete';
  opId: string;
  rootId: string;
  leaders: MarkdownLeader[];
  stopLine?: string | null;
  endLeaderId?: string | null;
}

export type MarkdownStructuralFailure =
  | 'badRequest'
  | 'unsupportedKind'
  | 'noEditor'
  | 'leadersMismatch'
  | 'dispatchThrew'
  | 'noEntry'
  | 'midOp'
  | 'changed'
  | 'swapThrew';

export interface MarkdownStructuralResult {
  ok: boolean;
  reason?: MarkdownStructuralFailure;
  detail?: string;
  preRaw?: string;
  postRaw?: string;
}

/** What an editor-first Markdown DELETE stores on its registry entry (`UndoRegistryEntry.markdown`). */
export interface MarkdownDeleteEntryExtras {
  kind: 'delete';
  /** The request the command ran. The quick redo re-runs it (unless Swift passes a fresher one). */
  request: MarkdownStructuralRequest;
  /** The change set the command applied (pre-op document to post-op document). Round 2b's redo carry maps the redo branch with it. */
  opChanges: ChangeSet;
}

/** What an editor-first Markdown REORDER stores (api-structural-markdown-reorder.ts). It has no quick re-run: its redo is the composed
 * redo (`composedRedo` below). */
export interface MarkdownReorderEntryExtras {
  kind: 'reorder';
  request: MarkdownReorderRequest;
  /** The ONE change set the move applied (pre-op document to post-op document): the move, the separators and the level rewrites. */
  opChanges: ChangeSet;
  /** The moved text (the run, with the blank line that follows it) in the POST-op document; null when nothing moved (a level-only
   * drop). The undo carry drops the redo events that touch it (redo-branch.ts). */
  moved: MovedRange | null;
  /** The selection the move left in the post-op document (the caret goes with its text). The composed redo puts it back. */
  postSelection: EditorSelection;
}

/** One leader of the copied subtree: the id the source leader row has and the id its copy gets (Swift mints it before the call). */
export interface MarkdownCopyId {
  source: string;
  new: string;
}

/** The request of an editor-first Markdown DUPLICATE (api-structural-markdown-duplicate.ts): the delete's fields plus `copyIds`. */
export interface MarkdownDuplicateRequest extends Omit<MarkdownStructuralRequest, 'kind'> {
  kind: 'duplicate';
  /** One pair per leader of the section's subtree (the root and every deeper leader up to the end of the range), in document order. */
  copyIds: MarkdownCopyId[];
}

/** What an editor-first Markdown DUPLICATE stores. Like the reorder it has no quick re-run: its redo is the composed redo
 * (`composedRedo` below), which lands exactly on the settled post-op document, so the same copy ids come back. */
export interface MarkdownDuplicateEntryExtras {
  kind: 'duplicate';
  request: MarkdownDuplicateRequest;
  /** The ONE change set the click applied: a pure insertion (the copy and its blank-line separator). */
  opChanges: ChangeSet;
  /** The inserted text in the POST-op document. The undo carry drops the redo events that touch it (redo-branch.ts): an event typed
   * inside the copy would otherwise land, after the undo has removed the copy, at the start of the next chapter's heading line. */
  moved: MovedRange;
  /** The selection the click left in the post-op document (the caret stays with its text). The composed redo puts it back. */
  postSelection: EditorSelection;
}

/** What an editor-first Markdown command stores on its registry entry (`UndoRegistryEntry.markdown`), tagged by `kind`. */
export type MarkdownEntryExtras = MarkdownDeleteEntryExtras | MarkdownReorderEntryExtras | MarkdownDuplicateEntryExtras;

// === Diagnostics ===

/** A diagnostic must never break the operation it observes. Counts, ids and timings only, never document text. */
export function trace(message: string): void {
  try {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[STRUCT-TRACE] ${message}`,
    });
  } catch {
    // Swallowed on purpose: see the comment above.
  }
}

// === The line rule and the scan ===

const SECTION_BREAK_MARKER = '<!-- ::break:: -->';
export const BIBLIOGRAPHY_START_MARKER = '<!-- ::auto-bibliography:: -->';
export const BIBLIOGRAPHY_END_MARKER = '<!-- ::auto-bibliography-end:: -->';
const LEADING_HIDDEN =
  /^(?:<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->)\s*/;
// BlockParser reads a heading as ICU `^(#{1,6})\s+` (BlockParser+Classification.swift). ICU's `\s` is the Unicode White_Space property:
// U+0009-000D, U+0020, U+0085, U+00A0, U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F, U+3000 (measured with
// NSRegularExpression on this machine; U+FEFF and U+180E are NOT white space to ICU). JavaScript's `\s` differs from that in two
// places (it has U+FEFF, it lacks U+0085), so the class is spelled out instead of using `\s`.
export const ATX_HEADING = /^#{1,6}[\t\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/;
const FOOTNOTE_REFERENCE = /\[\^([^\]\s]+)\](?!:)/g;
export const FOOTNOTE_DEFINITION = /^\[\^([^\]\s]+)\]:/;
export const FOOTNOTE_CONTINUATION = /^(?: {2,}|\t)\S/;

/** `line` with every leading hidden marker (section anchor, bibliography opening or end marker) removed, then trimmed. */
export function stripLeadingHidden(line: string): string {
  let rest = line.trimStart();
  for (;;) {
    const match = LEADING_HIDDEN.exec(rest);
    if (!match) break;
    rest = rest.slice(match[0].length);
  }
  return rest.trim();
}

/** The leading hidden markers (section anchor, bibliography opening/end marker, and the blanks between them) of `line`, exactly as
 * they stand in the text; `stripLeadingHidden(line)` is what follows them, trimmed. */
export function leadingHiddenOf(line: string): string {
  let rest = line;
  let consumed = 0;
  const blanks = /^\s*/.exec(rest);
  if (blanks) {
    consumed += blanks[0].length;
    rest = rest.slice(blanks[0].length);
  }
  for (;;) {
    const match = LEADING_HIDDEN.exec(rest);
    if (!match) break;
    consumed += match[0].length;
    rest = rest.slice(match[0].length);
  }
  return line.slice(0, consumed);
}

/** BlockParser.mathDisplayFenceLineRole, ported: whether a trimmed line opens a `$$` fence, and whether it is one-line math. */
function mathFenceRole(trimmed: string): { isOpener: boolean; isSingleLine: boolean } {
  const hasOpenPrefix = trimmed.startsWith('$$');
  const hasCloseSuffix = trimmed.endsWith('$$');
  const isSingleLine = hasOpenPrefix && hasCloseSuffix && trimmed.length > 4;
  const opensGluedOnly = hasOpenPrefix && !trimmed.slice(2).includes('$');
  return { isOpener: trimmed === '$$' || isSingleLine || opensGluedOnly, isSingleLine };
}

export interface LeaderCandidate {
  /** Offset of the start of the line. */
  from: number;
  /** 1-based line number. */
  lineNo: number;
  /** The line with its leading hidden markers removed. */
  text: string;
}

export interface DocumentScan {
  candidates: LeaderCandidate[];
  /** Line-start offsets of every line (outside fences) that `stopLine` names, in document order. */
  stopHits: number[];
  /** Line-start offsets of every standalone bibliography opening marker line (outside fences), in document order. */
  bibliographyMarkerLines: number[];
  /** Line-start offsets of every line (outside fences) that holds the bibliography opening marker, standalone or glued to a heading. */
  bibliographyStarts: number[];
  /** Line-start offsets of every line (outside fences) that holds the bibliography end marker. */
  bibliographyEnds: number[];
}

/** One pass over the document: the leader candidates (the line rule) and the lines `stopLine` names. */
export function scanDocument(doc: Text, stopLine: string | null | undefined): DocumentScan {
  const candidates: LeaderCandidate[] = [];
  const stopHits: number[] = [];
  const bibliographyMarkerLines: number[] = [];
  const bibliographyStarts: number[] = [];
  const bibliographyEnds: number[] = [];
  const stopRaw = stopLine ? stopLine.trim() : '';
  const stopStripped = stopLine ? stripLeadingHidden(stopLine) : '';

  let fence: string | null = null;
  let inMath = false;
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const text = line.text;

    if (fence !== null) {
      if (text.startsWith(fence)) fence = null;
      continue;
    }
    const trimmed = text.trim();
    if (inMath) {
      if (trimmed === '$$' || (trimmed.endsWith('$$') && !trimmed.startsWith('$$'))) inMath = false;
      continue;
    }
    if (text.startsWith('```')) {
      fence = '```';
      continue;
    }
    if (trimmed.startsWith('$$')) {
      const role = mathFenceRole(trimmed);
      if (role.isOpener) {
        if (!role.isSingleLine) inMath = true;
        continue;
      }
    }

    const stripped = stripLeadingHidden(text);
    if (ATX_HEADING.test(stripped) || stripped === SECTION_BREAK_MARKER) {
      candidates.push({ from: line.from, lineNo: n, text: stripped });
    }
    if (stopRaw !== '' && (trimmed === stopRaw || (stopStripped !== '' && stripped === stopStripped))) {
      stopHits.push(line.from);
    }
    if (trimmed.startsWith(BIBLIOGRAPHY_START_MARKER) && stripped === '') {
      bibliographyMarkerLines.push(line.from);
    }
    if (text.includes(BIBLIOGRAPHY_START_MARKER)) bibliographyStarts.push(line.from);
    if (text.includes(BIBLIOGRAPHY_END_MARKER)) bibliographyEnds.push(line.from);
  }
  return { candidates, stopHits, bibliographyMarkerLines, bibliographyStarts, bibliographyEnds };
}

// === Request parsing ===

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** The leaders of a request, each checked for shape; `badIndex` names the first one that is malformed. Shared with the reorder request. */
export function parseLeaders(items: unknown[]): { leaders: MarkdownLeader[] } | { badIndex: number } {
  const leaders: MarkdownLeader[] = [];
  for (const [index, item] of items.entries()) {
    const valid =
      isRecord(item) &&
      typeof item.id === 'string' &&
      typeof item.line === 'string' &&
      typeof item.level === 'number' &&
      Number.isInteger(item.level) &&
      item.level >= 1 &&
      item.level <= 6 &&
      (item.managed === undefined || item.managed === 'notes' || item.managed === 'bibliography');
    if (!valid) return { badIndex: index };
    const leader = item as unknown as MarkdownLeader;
    leaders.push({ id: leader.id, line: leader.line, level: leader.level, managed: leader.managed });
  }
  return { leaders };
}

/**
 * THE LEADER MATCH: null when the live candidates equal `leaders` one for one (same count, same line text), otherwise the detail of
 * the first difference (counts and indexes only, never document text). A mismatch changes nothing: Swift flushes the typing and retries.
 */
export function leaderMismatchDetail(scan: DocumentScan, leaders: MarkdownLeader[]): string | null {
  if (scan.candidates.length !== leaders.length) {
    return `leaderCount editor=${scan.candidates.length} database=${leaders.length}`;
  }
  for (let i = 0; i < leaders.length; i++) {
    if (scan.candidates[i].text !== stripLeadingHidden(leaders[i].line)) return `leaderLine index=${i}`;
  }
  return null;
}

/** A copy id is written into the text as `<!-- @sid:ID -->`, so it must be a UUID's alphabet and nothing that could end the comment. */
const COPY_ID = /^[0-9a-fA-F-]+$/;

/** The request of kind `kind` (the delete's by default), or the failure to answer. Never throws. */
export function parseRequest(
  input: unknown,
  kind?: 'delete'
): { request: MarkdownStructuralRequest } | { failure: MarkdownStructuralResult };
export function parseRequest(
  input: unknown,
  kind: 'duplicate'
): { request: MarkdownDuplicateRequest } | { failure: MarkdownStructuralResult };
export function parseRequest(
  input: unknown,
  kind: 'delete' | 'duplicate' = 'delete'
): { request: MarkdownStructuralRequest | MarkdownDuplicateRequest } | { failure: MarkdownStructuralResult } {
  let raw: unknown = input;
  if (typeof input === 'string') {
    try {
      raw = JSON.parse(input);
    } catch {
      return { failure: { ok: false, reason: 'badRequest', detail: 'unparsable json' } };
    }
  }
  if (!isRecord(raw)) return { failure: { ok: false, reason: 'badRequest', detail: 'not an object' } };
  if (raw.kind !== kind) {
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
  const leaders = parsedLeaders.leaders;
  const stopLine = raw.stopLine;
  if (stopLine !== undefined && stopLine !== null && typeof stopLine !== 'string') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'stopLine' } };
  }
  const endLeaderId = raw.endLeaderId;
  if (endLeaderId !== undefined && endLeaderId !== null && typeof endLeaderId !== 'string') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'endLeaderId' } };
  }
  const common = {
    opId: raw.opId,
    rootId: raw.rootId,
    leaders,
    stopLine: stopLine as string | null | undefined,
    endLeaderId: endLeaderId as string | null | undefined,
  };
  if (kind === 'delete') return { request: { kind: 'delete', ...common } };

  if (!Array.isArray(raw.copyIds)) return { failure: { ok: false, reason: 'badRequest', detail: 'copyIds' } };
  const copyIds: MarkdownCopyId[] = [];
  for (const [index, item] of raw.copyIds.entries()) {
    const valid =
      isRecord(item) &&
      typeof item.source === 'string' &&
      typeof item.new === 'string' &&
      COPY_ID.test(item.source) &&
      COPY_ID.test(item.new);
    if (!valid) return { failure: { ok: false, reason: 'badRequest', detail: `copyIds ${index}` } };
    const pair = item as unknown as MarkdownCopyId;
    copyIds.push({ source: pair.source, new: pair.new });
  }
  return { request: { kind: 'duplicate', ...common, copyIds } };
}

// === The range and the change set ===

type RangeOutcome = { ok: true; changes: ChangeSet } | { ok: false; failure: MarkdownStructuralResult };

function mismatch(detail: string): RangeOutcome {
  return { ok: false, failure: { ok: false, reason: 'leadersMismatch', detail } };
}

/** The footnote labels referenced (not defined) in `text`. */
function referencedLabels(text: string): Set<string> {
  const labels = new Set<string>();
  for (const match of text.matchAll(FOOTNOTE_REFERENCE)) labels.add(match[1]);
  return labels;
}

/**
 * The ranges of the Notes definitions to remove together with the section: every definition (its line, its indented continuation
 * lines and the blank lines after it) whose label is in `orphans`, inside the Notes region. Empty when there is no region.
 */
function orphanDefinitionRanges(
  doc: Text,
  scan: DocumentScan,
  notesIdx: number,
  orphans: Set<string>,
  rangeEnd: number
): Array<{ from: number; to: number }> {
  if (notesIdx < 0 || orphans.size === 0) return [];
  const notes = scan.candidates[notesIdx];
  // The region runs from the Notes leader to the next leader, or to a standalone bibliography opening marker line, or to the end.
  let regionEnd = doc.length + 1;
  const next = scan.candidates[notesIdx + 1];
  if (next) regionEnd = next.from;
  for (const markerFrom of scan.bibliographyMarkerLines) {
    if (markerFrom > notes.from) {
      regionEnd = Math.min(regionEnd, markerFrom);
      break;
    }
  }
  if (notes.from < rangeEnd) return []; // the Notes region must lie behind the removed range; anything else is not the shape we know

  const ranges: Array<{ from: number; to: number }> = [];
  let n = notes.lineNo + 1;
  while (n <= doc.lines) {
    const line = doc.line(n);
    if (line.from >= regionEnd) break;
    const match = FOOTNOTE_DEFINITION.exec(line.text);
    if (!match || !orphans.has(match[1])) {
      n++;
      continue;
    }
    let last = n;
    const within = (k: number): boolean => k <= doc.lines && doc.line(k).from < regionEnd;
    for (;;) {
      while (within(last + 1) && FOOTNOTE_CONTINUATION.test(doc.line(last + 1).text)) last++;
      // BlockParser's splitter keeps a definition going across ONE blank line when the very next line starts with four spaces
      // (`isFootnoteContinuation`, BlockParser+Splitting.swift): a second paragraph of the same footnote. Two blank lines, or a
      // next line that is not four-space indented (a tab included), end the definition there.
      if (within(last + 2) && doc.line(last + 1).text.trim() === '' && doc.line(last + 2).text.startsWith('    ')) {
        last += 2;
        continue;
      }
      break;
    }
    while (last + 1 <= doc.lines && doc.line(last + 1).from < regionEnd && doc.line(last + 1).text.trim() === '') {
      last++;
    }
    const to = last + 1 <= doc.lines ? doc.line(last + 1).from : doc.length;
    ranges.push({ from: line.from, to });
    n = last + 1;
  }
  return ranges;
}

/** Matches the leaders, computes the range and the orphan definitions, builds the one change set. Pure: reads `doc`, changes nothing. */
function planDelete(doc: Text, request: MarkdownStructuralRequest): RangeOutcome {
  const { leaders } = request;
  const rootIdx = leaders.findIndex((leader) => leader.id === request.rootId);
  if (rootIdx < 0) return mismatch('rootMissing');
  const root = leaders[rootIdx];
  if (root.managed !== undefined)
    return { ok: false, failure: { ok: false, reason: 'badRequest', detail: 'rootIsManaged' } };

  const scan = scanDocument(doc, request.stopLine);
  const mismatchDetail = leaderMismatchDetail(scan, leaders);
  if (mismatchDetail !== null) return mismatch(mismatchDetail);

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
    if (expected !== request.endLeaderId) return mismatch('endLeader');
  }

  const start = scan.candidates[rootIdx].from;
  let end = stopIdx >= 0 ? scan.candidates[stopIdx].from : doc.length;
  if (request.stopLine) {
    const hit = scan.stopHits.find((from) => from > start);
    if (hit === undefined) return mismatch('stopLineMissing');
    end = Math.min(end, hit);
  }
  if (end <= start) return mismatch('emptyRange');

  // O12: the Notes definitions only this section used. Skipped, never refused, when the Notes region cannot be found.
  const notesIdx = leaders.findIndex((leader) => leader.managed === 'notes');
  const text = doc.toString();
  const insideLabels = referencedLabels(text.slice(start, end));
  const outsideLabels = referencedLabels(text.slice(0, start) + text.slice(end));
  const orphans = new Set([...insideLabels].filter((label) => !outsideLabels.has(label)));
  const definitionRanges = orphanDefinitionRanges(doc, scan, notesIdx, orphans, end);

  const specs = [{ from: start, to: end }, ...definitionRanges];
  return { ok: true, changes: ChangeSet.of(specs, doc.length) };
}

// === The click ===

/**
 * Runs the command on the document as it is now: plans it, records the entry, dispatches once. When an entry of the same opId already
 * exists (a quick REDO is a re-run under the same opId) a throwing dispatch puts it back instead of deleting it.
 */
function runDelete(view: EditorView, request: MarkdownStructuralRequest): MarkdownStructuralResult {
  const registry = getRegistry();
  const doc = view.state.doc;

  // 1. Plan first. A mismatch (or any failure) returns here: nothing is recorded and nothing is dispatched (O8).
  let plan: RangeOutcome;
  try {
    plan = planDelete(doc, request);
  } catch (error) {
    trace(`markdown-delete plan threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'badRequest', detail: 'planThrew' };
  }
  if (!plan.ok) return plan.failure;

  // 1b. A redo event that is already waiting (typing taken back with Cmd-Z before the Delete) and lies inside the section this removes
  // would be mapped to the removal point by the dispatch below -- the start of the next chapter's heading line -- and a later
  // Cmd-Shift-Z would type it there. Such events leave the redo list first (the first one and every later one, as in the reorder
  // click, api-structural-markdown-reorder.ts). The quick redo re-runs this too; there nothing in the carried list lies in the range.
  const trimmed = withoutRedoEventsTouching(view.state, removedSpans(plan.changes), getEditorExtensions());
  if (trimmed) {
    try {
      installState(view, trimmed.state, { label: 'delete-trim', keepScroll: true });
      trace(`markdown-delete redo list trimmed dropped=${trimmed.dropped}`);
    } catch (error) {
      trace(`markdown-delete redo trim threw: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  // 2. Record the entry BEFORE the dispatch, mid-op, as beginStructuralOp does: the dispatch below is a sync-origin change, and the
  // saved copies must not follow the page's own change (B-2). The checkpoint is the pre-op state with its text history, isolated
  // so typing after a swap-back does not merge into the typing before the command.
  const preRaw = doc.toString();
  const existing = registry.get(request.opId);
  const checkpoint = view.state.update({ annotations: isolateHistory.of('full') }).state;
  setRegistryEntry(request.opId, {
    checkpoint,
    preOpDoc: view.state.doc, // the state after the trim of step 1b (equal text; the routing compares with .eq)
    postOpDoc: doc, // placeholder until the dispatch has landed
    midOp: true,
    markdown: { kind: 'delete', request, opChanges: plan.changes },
  });

  // 3. One dispatch. addToHistory:false maps both history branches through the removal: a DONE event inside the removed range maps away
  // (Rich Text's delete does the same, QU19), a REDO insertion inside it would survive at the removal point (hence step 1b above);
  // isolateHistory('full') closes the typing group on both sides of the command.
  let dispatched = false;
  try {
    withAppOrigin(() =>
      view.dispatch({
        changes: plan.changes,
        annotations: [Transaction.addToHistory.of(false), isolateHistory.of('full')],
      })
    );
    dispatched = true;
  } catch (error) {
    if (existing) setRegistryEntry(request.opId, { ...existing, midOp: false });
    else deleteRegistryEntry(request.opId);
    trace(`markdown-delete dispatch threw: ${error instanceof Error ? error.message : String(error)}`);
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

  return { ok: true, preRaw, postRaw: view.state.doc.toString() };
}

/** window.FinalFinal.markdownStructuralEditorFirst: the click. See the header for the contract. Never throws. */
export function markdownStructuralEditorFirst(json: string | object): MarkdownStructuralResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const parsed = parseRequest(json);
  if ('failure' in parsed) return parsed.failure;
  const result = runDelete(view, parsed.request);
  // Swift pushes this same value only after the writer's last write and the job's reservation (over a second on a long book), so the
  // page sets it now: a Cmd-Z in that gap finds this delete on top. Not in runDelete: the quick redo runs that too and must not touch it.
  if (result.ok) setUndoDescriptor({ undoTopOpId: parsed.request.opId });
  return result;
}

// === The undo / redo turn ===

/** A carried-over piece of the live state that a wholesale state swap would otherwise lose, and how to put it back (O5). */
interface CarriedState {
  name: string;
  /** Read from the LIVE state, before the swap. */
  capture(state: EditorState): unknown;
  /** Put back on the swapped-in view. */
  reapply(view: EditorView, captured: unknown): void;
}

/**
 * Everything the swap must re-apply. There are no CodeMirror Compartments in this editor's extension set (the plan assumed some):
 * the settings live either in module state, which a state swap does not touch, or in a StateField, which the swapped-in state
 * brings back at the VALUE it had when the checkpoint was taken. What really needs help:
 *   * the image widths (a StateField, pushed by Swift as images are resized after the checkpoint);
 *   * the spellcheck results (module state, but their positions belong to the document just replaced);
 *   * the line-height patch (installed on the view's DocView, which `setState` replaces);
 *   * the search query (a library StateField that the new state initialises empty, while api.ts keeps its own module copy of the query:
 *     without this, Find Next / Find Previous after an install would find nothing).
 */
const CARRIED_STATE: CarriedState[] = [
  // First: it patches the view's NEW DocView, which every dispatch below measures with.
  { name: 'lineHeightFix', capture: () => null, reapply: (view) => installLineHeightFix(view) },
  {
    name: 'imageMeta',
    capture: (state) => readImageMeta(state),
    reapply: (_view, captured) => setImageMeta(captured as Array<{ src: string; width: number }>),
  },
  { name: 'spellcheck', capture: () => null, reapply: () => resetSpellcheckAfterStateSwap() },
  // The span the user last typed in was never remapped through the swap (a swap has no transaction): left alone, a Swift-derived
  // `setContent` landing in the next 2.5 s can be classed as overlapping the typing and become its own undo step (L-1).
  { name: 'recentEditSpan', capture: () => null, reapply: () => clearRecentUserEditSpan() },
  {
    name: 'searchQuery',
    capture: (state) => getSearchQuery(state),
    reapply: (view, captured) => {
      const query = captured as SearchQuery;
      if (query.search !== '') view.dispatch({ effects: setSearchQuery.of(query) });
    },
  },
];

/**
 * The state the undo installs (O24): the pre-op checkpoint with its own text history -- and the LIVE redo branch carried across,
 * mapped onto the checkpoint document (redo-branch.ts), so what the user typed after the command and then took back can still be
 * redone. A carry that cannot be built falls back to the plain checkpoint (the redo branch is lost, nothing else), with a trace line.
 */
function buildSwappedState(entry: UndoRegistryEntry, live: EditorState, setAsideCount: number): EditorState {
  // The text whose redo events the carry leaves out: the dragged chapter (reorder) or the inserted copy (duplicate).
  const moved =
    entry.markdown?.kind === 'reorder' || entry.markdown?.kind === 'duplicate' ? entry.markdown.moved : null;
  const carry = carryRedoBranch(live, entry.checkpoint, entry.markdown?.opChanges, getEditorExtensions(), moved);
  if (carry === null) return entry.checkpoint;
  if (!carry.carried) {
    trace(`markdown-swap redo carry skipped: ${carry.reason} setAside=${setAsideCount}`);
    return entry.checkpoint;
  }
  trace(`markdown-swap redo carry events=${carry.events} dropped=${carry.dropped} setAside=${setAsideCount}`);
  return carry.state;
}

export interface InstallOptions {
  /** Which caller installs: 'swap' | 'put-back' | 'renumber-keep' | 'drag-trim' | 'delete-trim'. Only for the trace. */
  label: string;
  /** Keep the scroll position instead of scrolling the caret into view. For installs that keep the document. */
  keepScroll?: boolean;
}

/**
 * Puts `state` on the view in place of the current one, the way every swap here does: the wholesale `setState` (CodeMirror refuses it
 * during an update, and it throws before it changes anything), then the carried pieces of the old state that a swap would lose
 * (`CARRIED_STATE`), then the scroll. From the `setState` on nothing below may turn the swap into a failure.
 *
 * Every state install is EVERYDAY with benign effects: the height map is re-estimated, spellcheck underlines are reset and re-requested,
 * the status bar's selection count and the floating toolbar are cleared until the next selection change, and the typewriter reserve is
 * rebuilt. Callers (named in the trace by `label`): the structural undo ('swap'), the redo's put-back ('put-back'), the footnote renumber
 * that keeps a waiting redo list (api.ts, 'renumber-keep'), and the two clicks that first trim the redo list, the reorder
 * ('drag-trim', api-structural-markdown-reorder.ts) and the Delete ('delete-trim').
 *
 * The scroll. The swaps bring back another document (or the checkpoint's view of it), so they scroll the caret into view ('nearest').
 * An install that KEEPS the document (`keepScroll`: the put-back, the renumber-keep, the two trims) must not move the page: it takes
 * `scrollSnapshot()` before the `setState` (which rebuilds the DocView and loses the scroll position) and dispatches it afterwards. The
 * renumber-keep is triggered by Swift's timer, not by the user, who may have scrolled away to look at the copy.
 *
 * Measured in the real app (VM, books of six and twelve chapters; a user who had scrolled away from the caret presses Cmd-Shift-Z to redo
 * a Duplicate): with the put-back install the page ends about 130 pt (about 6 lines) from where it was, and stays there; without the
 * put-back the structural redo alone moves the page off the screen, because the redo restores the selection and CodeMirror scrolls it
 * into view. So the install already keeps the page much closer than the redo does. Two attempts to remove the remaining 130 pt were
 * measured and dropped: a correction that puts a reference line a third of the way down the page back where it was made it worse (the
 * lines between the reference and the text being read keep changing height after the install), and parsing the new state up to the end
 * of the old viewport before the install changed nothing. An install with nothing else moving (the renumber-keep, triggered by Swift's
 * timer) has not been measured in the real app: the renumber is too rarely on time for the test to meet it.
 */
export function installState(view: EditorView, state: EditorState, options: InstallOptions): void {
  const { label, keepScroll = false } = options;
  const captured = CARRIED_STATE.map((item) => ({ item, value: item.capture(view.state) }));
  let scroll: ReturnType<EditorView['scrollSnapshot']> | null = null;
  if (keepScroll) {
    try {
      scroll = view.scrollSnapshot();
    } catch (error) {
      trace(
        `markdown-install[${label}] scroll snapshot threw: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  // The only step that can throw, and it throws before it changes anything (CodeMirror refuses a swap during an update).
  view.setState(state);

  for (const { item, value } of captured) {
    try {
      item.reapply(view, value);
    } catch (error) {
      trace(
        `markdown-install[${label}] re-apply ${item.name} threw: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }
  try {
    view.dispatch({
      effects: scroll ?? EditorView.scrollIntoView(view.state.selection.main.head, { y: 'nearest', yMargin: 50 }),
    });
  } catch (error) {
    trace(`markdown-install[${label}] scroll threw: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function swapUndo(view: EditorView, entry: UndoRegistryEntry, opId: string): MarkdownStructuralResult {
  const live = view.state;
  const preRaw = live.doc.toString();
  // The live redo branch is also kept aside untouched (not for a delete: its quick redo re-runs the command and a delete loses no
  // typing); `putBackRedo` brings it back after the redo has landed. A record is always replaced or removed, never left from an
  // earlier undo of the same opId (C1).
  const setAside =
    entry.markdown?.kind !== 'delete' && redoDepth(live) > 0
      ? { undone: live.toJSON({ history: historyField }).history.undone as unknown[], doc: live.doc }
      : null;
  if (!setAside) clearSetAsideRedo(opId);

  installState(view, buildSwappedState(entry, live, setAside ? redoDepth(live) : 0), { label: 'swap' });

  if (setAside) {
    setAsideRedo(opId, { ...setAside, depthAfterUndo: redoDepth(view.state) }, getRegistry().keys());
  }
  return { ok: true, preRaw, postRaw: view.state.doc.toString() };
}

/** The slow redo of an entry the OLD body recorded, and the fall-back of the composed redo: the saved post-op text goes in as a refined
 * diff (`computeRefinedChanges`, no 500-line bound: a book with two automatic rewrites far apart is not one giant replaced span, which
 * would take the caret and the history events inside it to its edge), outside the text history. */
function swapRedoFromSavedCopy(view: EditorView, entry: UndoRegistryEntry): MarkdownStructuralResult {
  const preRaw = view.state.doc.toString();
  const changes = computeRefinedChanges(preRaw, entry.postOpDoc.toString());
  if (changes.length > 0) {
    withAppOrigin(() => view.dispatch({ changes, annotations: Transaction.addToHistory.of(false) }));
  }
  return { ok: true, preRaw, postRaw: view.state.doc.toString() };
}

/**
 * The redo of a REORDER or DUPLICATE entry (decision (a), judge ruling M10): the recorded change is applied to the checkpoint document
 * and then the small difference to the SETTLED post-op document (`entry.postOpDoc`, which has followed the rebuild's anchors and the
 * footnote renumber since the click) is composed onto it, as ONE change outside the text history. The redo therefore lands exactly on
 * `postOpDoc` (so a Cmd-Z pressed at once is still routed structural, and the footnotes are never seen out of order; for a duplicate it
 * carries the click's `<!-- @sid:NEW -->` markers, so the same copy ids come back), and the history is mapped through the real change,
 * not through a line diff that would treat a shorter chapter's text as removed and re-inserted. The caret also goes back with its text
 * (a caret at the start of the next chapter's heading is there again after the redo; the saved-copy swap would leave it in front of
 * the copy). Measured for a duplicate (structural-markdown-duplicate.test.ts WD10): the text history comes out the same on both routes.
 *
 * Only for a live document equal to the CHECKPOINT document, the one `opChanges` was built on. Returns null otherwise (the document
 * changed since: an automatic rewrite moved `preOpDoc`, the user typed), and the caller uses the saved-copy swap.
 * Runs inside the midOp-guarded block of `markdownStructuralSwap`: its own dispatch is a sync-origin change and must not advance the
 * entry's saved copies (`maybeAdvanceRegistryOnSyncOriginTx` skips while any entry is mid-op).
 */
function composedRedo(view: EditorView, entry: UndoRegistryEntry): MarkdownStructuralResult | null {
  const extras = entry.markdown;
  if (extras?.kind !== 'reorder' && extras?.kind !== 'duplicate') return null;
  if (!view.state.doc.eq(entry.checkpoint.doc)) return null;
  const preRaw = view.state.doc.toString();
  const moved = extras.opChanges.apply(entry.checkpoint.doc).toString();
  const settle = ChangeSet.of(computeRefinedChanges(moved, entry.postOpDoc.toString()), extras.opChanges.newLength);
  const changes = settle.empty ? extras.opChanges : extras.opChanges.compose(settle);
  // The caret goes with its text, as it did at the click -- unless the user moved it since the Cmd-Z (the swap-back left the
  // checkpoint's selection in place), in which case their caret is simply mapped through the change.
  const selection = view.state.selection.eq(entry.checkpoint.selection) ? extras.postSelection.map(settle) : undefined;
  // isolateHistory('full'), as for the click: typing after the redo never joins typing from before the command.
  withAppOrigin(() =>
    view.dispatch({
      changes,
      selection,
      annotations: [Transaction.addToHistory.of(false), isolateHistory.of('full')],
    })
  );
  return { ok: true, preRaw, postRaw: view.state.doc.toString() };
}

/**
 * After the redo has landed: puts the redo steps the undo set aside back, so the next Cmd-Shift-Z brings back what was typed inside the
 * copied / restored / dragged text (redo-branch.ts `putBackRedo`). The document is not touched. A refusal or a failure leaves the
 * carried list the redo found, with a trace line, and never turns the (already done) redo into a failure.
 */
function putBackSetAsideRedo(view: EditorView, opId: string, depthBeforeRedo: number): void {
  const started = performance.now();
  try {
    const back = putBackRedo(view, opId, depthBeforeRedo, getEditorExtensions());
    if (back === null) return;
    if (!back.carried) {
      trace(`markdown-swap redo put-back skipped: ${back.reason}`);
      return;
    }
    installState(view, back.state, { label: 'put-back', keepScroll: true });
    trace(
      `markdown-swap redo put-back events=${back.events} dropped=${back.dropped} ms=${Math.round(performance.now() - started)}`
    );
  } catch (error) {
    trace(`markdown-swap redo put-back threw: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * window.FinalFinal.markdownStructuralSwap: the undo/redo turn of the registry entry `opId`. Never throws.
 *
 * It re-checks first that the live document still equals the entry's saved copy -- the same routing function and comparison the key
 * press used (`decideLiveRouting`), asked again because Swift reserves its writer ticket between the press and this turn and the user
 * can type in those milliseconds. The call passes its own opId, so the latch the press raised does not swallow it. If the answer is not
 * "structural, for this opId" nothing has changed and `{ ok:false, reason:'changed' }` comes back. The swap never deletes the entry.
 */
export function markdownStructuralSwap(
  opId: string,
  direction: 'undo' | 'redo',
  requestJson?: string | object
): MarkdownStructuralResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const registry = getRegistry();
  const entry = registry.get(opId);
  if (!entry) return { ok: false, reason: 'noEntry' };
  if (entry.midOp) return { ok: false, reason: 'midOp' };

  const decision = decideLiveRouting(view, direction, opId);
  if (decision.action !== 'structural' || decision.opId !== opId) {
    return { ok: false, reason: 'changed', detail: `decision=${decision.action}` };
  }

  // A quick redo re-runs the command on the document as it stands, under the same opId. It brings its own midOp handling. Only a DELETE
  // has a quick re-run; a reorder entry (api-structural-markdown-reorder.ts) and a duplicate entry (api-structural-markdown-duplicate.ts)
  // go on to the shared midOp-guarded block below, where their composed redo runs beside the saved-copy swap (an early return here would
  // let its own dispatch advance `preOpDoc`).
  if (direction === 'redo' && entry.markdown?.kind === 'delete') {
    let request = entry.markdown.request;
    if (requestJson !== undefined) {
      const parsed = parseRequest(requestJson);
      if ('failure' in parsed) return parsed.failure;
      if (parsed.request.opId !== opId) return { ok: false, reason: 'badRequest', detail: 'opIdDiffers' };
      request = parsed.request;
    }
    return runDelete(view, request);
  }

  registry.set(opId, { ...entry, midOp: true });
  try {
    if (direction === 'undo') return swapUndo(view, entry, opId);
    // The redo list as it stands BEFORE the redo's own dispatch: the put-back needs it unchanged since the undo (redo-branch.ts).
    const depthBeforeRedo = redoDepth(view.state);
    let redone = composedRedo(view, entry);
    if (redone === null) {
      if (entry.markdown?.kind === 'reorder' || entry.markdown?.kind === 'duplicate')
        trace(`markdown-swap ${entry.markdown.kind} redo: the document is not the checkpoint, saved-copy swap`);
      redone = swapRedoFromSavedCopy(view, entry);
    }
    putBackSetAsideRedo(view, opId, depthBeforeRedo);
    return redone;
  } catch (error) {
    trace(`markdown-swap ${direction} threw: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: 'swapThrew' };
  } finally {
    const current = registry.get(opId);
    if (current) registry.set(opId, { ...current, midOp: false });
  }
}
