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
import { releaseTypingPushes } from './typing-push-hold';
import {
  buildOver,
  docAtPress,
  formatTypingSincePressLine,
  type PressDoc,
  type ReplayInput,
  swapWithReplay,
  type TypingDecision,
} from './typing-rebase';
import {
  decideLiveRouting,
  deleteRegistryEntry,
  getInFlightPress,
  getRegistry,
  getTypingCollector,
  noteTypingReplayed,
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
  | 'unplaceable'
  | 'swapThrew';

export interface MarkdownStructuralResult {
  ok: boolean;
  reason?: MarkdownStructuralFailure;
  detail?: string;
  preRaw?: string;
  postRaw?: string;
  /** Phase 4c job 2: set (true) when the swap put the typing done while the press waited back on top of the undone/redone document.
   * Then `preRaw` is the document AT THE PRESS (the typing is not sent as a batch of its own; the replay is its only carrier) and `postRaw`
   * is the swapped-in text BEFORE the replay (the writer baseline). Swift ends the redo branch on seeing it. */
  typingReplayed?: boolean;
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

/** How a Version History restore reaches the document (api-structural-markdown-restore.ts): the whole document, the flat range of one
 * section, or an insertion after a section (or, without an anchor, in front of Notes and Bibliography). */
export type MarkdownRestoreMode = 'whole' | 'section' | 'insertAfter';

/** The request of an editor-first Markdown RESTORE (api-structural-markdown-restore.ts): the delete's leader fields, a `mode` and the
 * `text` that goes in. */
export interface MarkdownRestoreRequest {
  kind: 'restore';
  opId: string;
  mode: MarkdownRestoreMode;
  /** section: the target heading; insertAfter: the anchor leader (null = none); whole: null. */
  rootId: string | null;
  leaders: MarkdownLeader[];
  stopLine?: string | null;
  /** Always null; accepted for parity with the delete's request and never read. */
  endLeaderId?: string | null;
  /** What goes in, with the `<!-- @sid:ID -->` markers of its leader rows already in it. */
  text: string;
}

/** What an editor-first Markdown RESTORE stores. Like the reorder and the duplicate it has no quick re-run: its redo is the composed redo
 * (`composedRedo` below), which lands exactly on the settled post-op document, so the ids inside the restored text come back. */
export interface MarkdownRestoreEntryExtras {
  kind: 'restore';
  request: MarkdownRestoreRequest;
  /** The ONE change set the click applied: refined hunks (section, whole) or a pure insertion. */
  opChanges: ChangeSet;
  /** The hull of the change in the POST-op document; null when nothing changed. The undo carry drops the redo events that touch it
   * (redo-branch.ts); the set-aside / put-back brings typing done inside the restored text back after the redo. */
  moved: MovedRange | null;
  /** The selection the click left in the post-op document. The composed redo puts it back. */
  postSelection: EditorSelection;
}

/** What an editor-first Markdown command stores on its registry entry (`UndoRegistryEntry.markdown`), tagged by `kind`. */
export type MarkdownEntryExtras =
  | MarkdownDeleteEntryExtras
  | MarkdownReorderEntryExtras
  | MarkdownDuplicateEntryExtras
  | MarkdownRestoreEntryExtras;

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

/** The restore's fields (api-structural-markdown-restore.ts "THE JSON CONTRACT"); `raw.kind` and `opId` are already checked. `mode` is one
 * of the three, `text` a string (possibly empty), `rootId` a non-empty string or null (required for a section, ignored for `whole`). */
function parseRestoreFields(
  raw: Record<string, unknown>,
  opId: string
): { request: MarkdownRestoreRequest } | { failure: MarkdownStructuralResult } {
  const bad = (detail: string): { failure: MarkdownStructuralResult } => ({
    failure: { ok: false, reason: 'badRequest', detail },
  });
  const modeRaw = raw.mode;
  const mode: MarkdownRestoreMode | null =
    modeRaw === 'whole' || modeRaw === 'section' || modeRaw === 'insertAfter' ? modeRaw : null;
  if (mode === null) return bad('mode');
  if (typeof raw.text !== 'string') return bad('text');
  const rootId = raw.rootId;
  if (rootId !== undefined && rootId !== null && (typeof rootId !== 'string' || rootId === '')) return bad('rootId');
  if (mode === 'section' && typeof rootId !== 'string') return bad('rootId');
  if (!Array.isArray(raw.leaders)) return bad('leaders');
  const parsedLeaders = parseLeaders(raw.leaders);
  if ('badIndex' in parsedLeaders) return bad(`leader ${parsedLeaders.badIndex}`);
  const stopLine = raw.stopLine;
  if (stopLine !== undefined && stopLine !== null && typeof stopLine !== 'string') return bad('stopLine');
  const endLeaderId = raw.endLeaderId;
  if (endLeaderId !== undefined && endLeaderId !== null && typeof endLeaderId !== 'string') return bad('endLeaderId');
  return {
    request: {
      kind: 'restore',
      opId,
      mode,
      rootId: mode === 'whole' || typeof rootId !== 'string' ? null : rootId,
      leaders: parsedLeaders.leaders,
      stopLine: stopLine as string | null | undefined,
      endLeaderId: endLeaderId as string | null | undefined,
      text: raw.text,
    },
  };
}

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
  kind: 'restore'
): { request: MarkdownRestoreRequest } | { failure: MarkdownStructuralResult };
export function parseRequest(
  input: unknown,
  kind: 'delete' | 'duplicate' | 'restore' = 'delete'
):
  | { request: MarkdownStructuralRequest | MarkdownDuplicateRequest | MarkdownRestoreRequest }
  | { failure: MarkdownStructuralResult } {
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
  if (kind === 'restore') return parseRestoreFields(raw, raw.opId);
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

/** The ranges of text the user's typing since a press INSERTED, in the LIVE document: the changes composed, one range per typed run that
 * left text behind. A pure deletion (a Backspace) inserts nothing, so it has no range: text it took out of the span the redo is about to
 * remove is not text the redo can take with it (the same rule as Rich Text's `typedRangesInLive`). For the quick redo's check that no typed
 * text lies inside the text the re-run removes. */
function typedRangesInLive(steps: ReadonlyArray<{ changes: ChangeSet }>): MovedRange[] {
  if (steps.length === 0) return [];
  let total = steps[0].changes;
  for (let i = 1; i < steps.length; i++) total = total.compose(steps[i].changes);
  const ranges: MovedRange[] = [];
  total.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    if (toB > fromB) ranges.push({ from: fromB, to: toB });
  });
  return ranges;
}

/** Whether any typed (inserted, so non-empty) range overlaps a removed span. */
function typingTouchesRemoval(typed: ReadonlyArray<MovedRange>, removed: ReadonlyArray<MovedRange>): boolean {
  return removed.some((span) => typed.some((range) => range.from < span.to && range.to > span.from));
}

/**
 * Runs the command on the document as it is now: plans it, records the entry, dispatches once. When an entry of the same opId already
 * exists (a quick REDO is a re-run under the same opId) a throwing dispatch puts it back instead of deleting it.
 */
function runDelete(
  view: EditorView,
  request: MarkdownStructuralRequest,
  typedRanges: ReadonlyArray<MovedRange> = []
): MarkdownStructuralResult {
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

  // 1a. Typing done since the press that lies inside the text this removes would be removed with it (the quick redo runs on the live
  // document). Refused before anything is recorded or dispatched; the typing stays. The ranges are in the coordinates of `doc`.
  if (typedRanges.length > 0 && typingTouchesRemoval(typedRanges, removedSpans(plan.changes))) {
    return { ok: false, reason: 'unplaceable', detail: 'typingInRemovedSection' };
  }

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
  // The text whose redo events the carry leaves out: the dragged chapter (reorder), the inserted copy (duplicate) or the changed span of
  // a restore (the hull of its change; null when nothing changed).
  const moved =
    entry.markdown?.kind === 'reorder' || entry.markdown?.kind === 'duplicate' || entry.markdown?.kind === 'restore'
      ? entry.markdown.moved
      : null;
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
  /** Which caller installs: 'swap' | 'put-back' | 'renumber-keep' | 'drag-trim' | 'delete-trim' | 'restore-trim'. Only for the trace. */
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
 * that keeps a waiting redo list (api.ts, 'renumber-keep'), and the three clicks that first trim the redo list, the reorder
 * ('drag-trim', api-structural-markdown-reorder.ts), the Delete ('delete-trim') and the restore ('restore-trim',
 * api-structural-markdown-restore.ts).
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
 * The redo of a REORDER, DUPLICATE or RESTORE entry (decision (a), judge ruling M10): the recorded change is applied to the checkpoint document
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
  if (extras?.kind !== 'reorder' && extras?.kind !== 'duplicate' && extras?.kind !== 'restore') return null;
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
 * The undo or redo of `entry` when the user TYPED while the press waited (Phase 4c, job 2; typing-rebase.ts). The routing has already
 * found the document at the press equal to the saved copy. The typing is rebased onto the swap target and tried on a throwaway state first
 * (`buildReplayDryRun`); only a change that cannot be placed refuses, BEFORE anything on the screen has changed (`unplaceable`). Otherwise
 * the target is installed, `postRaw` is read (the swapped-in text, the writer baseline), the typing is replayed on top and the page checks the
 * document is the dry run's; a throw or a mismatch puts the state from before back.
 *
 * `preRaw` is the document AT THE PRESS, so Swift's typing batch up to the swap (`prepareStructuralClick`) finds nothing new: the replay is
 * the typing's only carrier (Swift's step-8 flush reads the live page text behind the job).
 */
function swapWithTypingReplay(
  view: EditorView,
  entry: UndoRegistryEntry,
  opId: string,
  direction: 'undo' | 'redo',
  press: number,
  atPress: PressDoc
): MarkdownStructuralResult {
  const live = view.state;
  const d0 = atPress.doc;
  const extras = entry.markdown;
  let targetState: EditorState;
  let target: Text;
  if (direction === 'undo') {
    targetState = buildSwappedState(entry, live, 0); // typing ended the live redo branch: nothing to carry from it
    target = entry.checkpoint.doc;
  } else {
    // The redo lands on the saved post-op document (`composedRedo` and the saved-copy swap both do); here it is a history-neutral change
    // from the live text to that document, on top of the live state.
    target = entry.postOpDoc;
    const toTarget = ChangeSet.of(computeRefinedChanges(live.doc.toString(), target.toString()), live.doc.length);
    targetState = live.update({
      changes: toTarget,
      annotations: [Transaction.addToHistory.of(false), isolateHistory.of('full')],
    }).state;
  }
  const over = buildOver({
    direction,
    d0,
    target,
    checkpointDoc: entry.checkpoint.doc,
    opChanges: extras?.opChanges,
    moved: extras?.kind === 'reorder' ? extras.moved : null,
  });
  if (over === null) return { ok: false, reason: 'unplaceable', detail: 'noOver' };

  const input: ReplayInput = { targetState, over, steps: atPress.steps, liveSelection: live.selection };
  let postRaw = '';
  const result = swapWithReplay(
    view,
    input,
    (state) =>
      installState(view, state, { label: state === live ? 'swap-put-back' : 'swap', keepScroll: direction === 'redo' }),
    () => {
      postRaw = view.state.doc.toString();
    }
  );
  if (!result.ok) return { ok: false, reason: 'unplaceable', detail: result.reason };

  getTypingCollector().adoptReplay(press, result.rebasedSteps ?? []);
  noteTypingReplayed();
  clearSetAsideRedo(opId); // the redo steps set aside at an earlier undo belong to a document that now has typing on top (amendment 6)
  return { ok: true, preRaw: d0.toString(), postRaw, typingReplayed: true };
}

/** The press and entry whose first (retriable) `leadersMismatch` refusal was answered without a trace line. */
let retriedMismatch: { press: number; opId: string } | null = null;

/**
 * window.FinalFinal.markdownStructuralSwap: the undo/redo turn of the registry entry `opId`. Never throws.
 *
 * It re-checks first that the document AS IT WAS AT THE PRESS still equals the entry's saved copy (modulo what the app regenerates) --
 * the same routing function and comparison the key press used (`decideLiveRouting`, with the typing and the automatic changes made since
 * the press taken out of the live document: typing-rebase.ts `docAtPress`), asked again because Swift reserves its writer ticket
 * between the press and this turn and the user can type in those milliseconds. The call passes its own opId, so the latch the press
 * raised does not swallow it. If the answer is not "structural, for this opId" nothing has changed and `{ ok:false, reason:'changed' }`
 * comes back. Typing made since the press is put back on top of the swapped-in text (`swapWithTypingReplay`), except in the quick redo
 * of a Delete, which runs on the live document. It writes ONE `typing-since-press` trace line per press, at the final decision. The
 * swap never deletes the entry.
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

  // Phase 4c job 2: the press this swap answers, and the ONE trace line it writes whatever the outcome (typing-rebase.ts).
  const press = getInFlightPress();
  const collector = getTypingCollector();
  const stepsSince = press > 0 ? collector.stepsSince(press).length : 0;
  const traceDecision = (decision: TypingDecision): void => {
    trace(formatTypingSincePressLine(press, stepsSince, decision));
  };
  // A refusal changes nothing; the typing the press held back is released first (judge D1/D2): Swift answers `failed` next.
  const refuse = (decision: TypingDecision, result: MarkdownStructuralResult): MarkdownStructuralResult => {
    traceDecision(decision);
    releaseTypingPushes('send');
    return result;
  };
  if (!entry) return refuse('noEntry', { ok: false, reason: 'noEntry' });
  if (entry.midOp) return refuse('midOp', { ok: false, reason: 'midOp' });

  // The routing compares the document AS IT WAS AT THE PRESS with the saved copy (undo-coordinator.ts `documentAtPress`).
  const decision = decideLiveRouting(view, direction, opId);
  if (decision.action !== 'structural' || decision.opId !== opId) {
    return refuse('changed', { ok: false, reason: 'changed', detail: `decision=${decision.action}` });
  }
  const atPress: PressDoc | null = press > 0 ? docAtPress(view.state.doc, collector, press) : null;
  const typedSincePress = atPress !== null && atPress.decision === 'rebased';

  // A quick redo re-runs the command on the document as it stands, under the same opId. It brings its own midOp handling. Only a DELETE
  // has a quick re-run; a reorder entry (api-structural-markdown-reorder.ts), a duplicate entry (api-structural-markdown-duplicate.ts) and
  // a restore entry (api-structural-markdown-restore.ts) go on to the shared midOp-guarded block below, where their composed redo runs
  // beside the saved-copy swap (an early return here would let its own dispatch advance `preOpDoc`). The depth the put-back needs is read
  // there BEFORE the redo's own dispatch (unified-undo.md, "must read depthBeforeRedo BEFORE any quick re-run returns").
  if (direction === 'redo' && entry.markdown?.kind === 'delete') {
    let request = entry.markdown.request;
    if (requestJson !== undefined) {
      const parsed = parseRequest(requestJson);
      if ('failure' in parsed) return refuse('changed', parsed.failure);
      if (parsed.request.opId !== opId)
        return refuse('changed', { ok: false, reason: 'badRequest', detail: 'opIdDiffers' });
      request = parsed.request;
    }
    // Phase 4c job 2, round 2b: the quick redo re-runs the delete on the LIVE document, so typing done while the press waited is already
    // in it and is NOT replayed. The routing has found the document at the press equal to what the entry expects. What the re-run removes
    // is decided on the live text; typing that lies inside the text it removes would go with it, so that one case is refused BEFORE
    // anything changes (`unplaceable`, the typing kept, the existing notice): see `runDelete`.
    const typedRanges = typedSincePress && atPress !== null ? typedRangesInLive(atPress.steps) : [];
    const rerun = runDelete(view, request, typedRanges);
    if (!rerun.ok) {
      // `leadersMismatch` is the one refusal Swift RETRIES (it flushes and asks again, once): the first one writes no trace line and keeps
      // the typing push held, so the press has ONE line, at its final decision (F21). If the retry also fails, that is the final one.
      if (rerun.reason === 'leadersMismatch' && !(retriedMismatch?.press === press && retriedMismatch.opId === opId)) {
        retriedMismatch = { press, opId };
        return rerun;
      }
      return refuse(rerun.reason === 'unplaceable' ? 'unplaceable' : 'changed', rerun);
    }
    traceDecision(typedSincePress ? 'rebased' : 'matched');
    if (!typedSincePress) return rerun;
    // The reply's `preRaw` is the live text (typing included), which Swift's typing batch up to the press saves: the held push is not sent.
    noteTypingReplayed();
    return { ...rerun, typingReplayed: true };
  }

  registry.set(opId, { ...entry, midOp: true });
  try {
    if (typedSincePress && atPress !== null) {
      const replayed = swapWithTypingReplay(view, entry, opId, direction, press, atPress);
      traceDecision(replayed.ok ? 'rebased' : 'unplaceable');
      if (!replayed.ok) releaseTypingPushes('send'); // D1/D2: put back, the held typing is released (sent) before the refusal is answered
      return replayed;
    }
    traceDecision('matched');
    if (direction === 'undo') {
      const swapped = swapUndo(view, entry, opId);
      // `setState` replaced the document under the records the presses held behind this one made (automatic changes only: typing would
      // have been replayed). They are written for the old document; a later press must not build its base from them.
      if (swapped.ok && press > 0) collector.adoptReplay(press, []);
      return swapped;
    }
    // The redo list as it stands BEFORE the redo's own dispatch: the put-back needs it unchanged since the undo (redo-branch.ts).
    const depthBeforeRedo = redoDepth(view.state);
    let redone = composedRedo(view, entry);
    if (redone === null) {
      if (
        entry.markdown?.kind === 'reorder' ||
        entry.markdown?.kind === 'duplicate' ||
        entry.markdown?.kind === 'restore'
      )
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
