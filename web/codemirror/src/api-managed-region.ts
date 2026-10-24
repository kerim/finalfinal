// Region-scoped replace of the machine-managed Notes / bibliography text in MARKDOWN mode (t-4a8fd8af, O28, W11).
//
// After a structural command the footnote resync and the bibliography rebuild produce new Notes and bibliography text from the
// database. In Markdown mode the app used to push the WHOLE document into the editor for that (`content = result.markdown;
// updateSourceContentIfNeeded()`), which overwrites whatever the user typed since the rows were read, and replaces the whole text in
// one go. Here Swift sends only the region's new text plus what it believes the region currently holds (`expectedOld`), and the page
//   * finds the region itself (below),
//   * applies ONE transaction, marked sync-origin (`addToHistory: false`, so the user's own text history, the structural entries'
//     saved copies and the caret all follow it the way they follow any derived push), but ONLY IF the region in the live text still
//     equals `expectedOld`;
//   * otherwise changes nothing and says why, so Swift takes its existing stale path (re-post once the pending write has applied).
// It never touches text outside the region, and never moves the caret out of where it was: the selection is mapped through the change.
//
// THE JSON CONTRACT
//   interface MarkdownManagedRegionRequest {
//     region: 'notes' | 'bibliography';
//     headingLine?: string | null;   // 'notes' only: the Notes heading's line, trimmed, hidden markers removed ("## Notes"; the user's
//                                    // own title when it was renamed). 'bibliography' ignores it (its markers locate it).
//     expectedOld: string;           // the region as the database rows have it now, in the form described under NORMAL FORM
//     newText: string;               // the region's new text, same form. '' removes the region (heading included).
//   }
//   interface MarkdownManagedRegionResult {
//     ok: boolean;
//     changed?: boolean;             // ok only: false when the region already held newText (nothing was dispatched)
//     reason?: 'badRequest' | 'noEditor' | 'noRegion' | 'regionChanged' | 'dispatchThrew';
//     detail?: string;               // counts and names only, never document text
//     postRaw?: string;              // ok only: the raw document (anchors and markers included) after the call (O30: Swift adopts it)
//   }
// `markdownReplaceManagedRegion` takes the request as a JSON string or an already parsed object.
//
// THE REGIONS (stable markers the page can find)
//   * 'bibliography': from the line that holds the bibliography opening marker `<!-- ::auto-bibliography:: -->` (glued to the heading
//     line, or alone on its own line) through the end of the line that holds the end marker `<!-- ::auto-bibliography-end:: -->`.
//     The end marker is written after the LAST bibliography block wherever it falls (BlockParser.assembleMarkdownForEditor), so it is
//     always there. No opening marker or no end marker -> `noRegion`.
//   * 'notes': from the line of the Notes heading (found by `headingLine` among the document's leader lines, the line rule of
//     api-structural-markdown.ts) to the start of the next leader line, or the standalone bibliography opening marker line, or the end
//     of the document. When several leader lines equal `headingLine`, the first whose text equals `expectedOld` is the region. No such
//     heading -> `noRegion`; headings found but none holding `expectedOld` -> `regionChanged`.
//   A region that does not exist yet (the first footnote, the first citation) cannot be CREATED here: `noRegion`; Swift takes its
//   existing whole-text path for that case.
//
// NORMAL FORM (what `expectedOld`, `newText` and the comparison use): the text with every hidden marker removed (section anchors, the
// bibliography opening and end markers), whitespace-only lines emptied, runs of blank lines collapsed to one, and trimmed at both ends.
// One more rule, applied to BOTH sides so they compare in one form: a footnote definition line (`[^N]:`) starts a new block in
// BlockParser, so a blank line is put in front of one that follows another line directly (see `normalizeRegionText`).
// So Swift sends plain rows-joined text; the page keeps the region's own frame when it writes: the heading's leading markers (anchor,
// and for the bibliography the opening marker in its glued or standalone shape) and the end marker line are put back around `newText`.

import { Transaction } from '@codemirror/state';
import { stripAnchors } from './anchor-plugin';
import {
  ATX_HEADING,
  BIBLIOGRAPHY_END_MARKER,
  BIBLIOGRAPHY_START_MARKER,
  type DocumentScan,
  leadingHiddenOf,
  scanDocument,
  stripLeadingHidden,
} from './api-structural-markdown';
import { getEditorView } from './editor-state';
import { withAppOrigin } from './typewriter-plugin';

export interface MarkdownManagedRegionRequest {
  region: 'notes' | 'bibliography';
  headingLine?: string | null;
  expectedOld: string;
  newText: string;
}

export type MarkdownManagedRegionFailure = 'badRequest' | 'noEditor' | 'noRegion' | 'regionChanged' | 'dispatchThrew';

export interface MarkdownManagedRegionResult {
  ok: boolean;
  changed?: boolean;
  reason?: MarkdownManagedRegionFailure;
  detail?: string;
  postRaw?: string;
}

/**
 * The normal form of a region's text (see the header), the SAME form on both sides of the comparison. Swift builds `expectedOld` by
 * parsing the text into blocks and joining the block fragments with a blank line (MarkdownManagedRegions.snapshot). The page
 * reproduces the one block split that matters in a Notes region: a footnote definition line (`[^N]:`) always starts a new block in
 * BlockParser's splitter (`footnoteDefStartPattern`, digits only), blank line before it or not. So a definition that follows another
 * line directly gets the blank line the join would have put there; a region whose definitions are hand-typed one per line then
 * compares equal to the rows' text. Every other shape (indented continuation paragraphs, ordinary paragraphs) is one block in
 * Swift and is left as it stands here.
 */
export function normalizeRegionText(text: string): string {
  return stripAnchors(text)
    .replace(/\r\n/g, '\n')
    .replace(/\n[ \t]+(?=\n)/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
    .replace(/([^\n])\n(?=\[\^\d+\]:)/g, '$1\n\n');
}

function parseRequest(
  input: unknown
): { request: MarkdownManagedRegionRequest } | { failure: MarkdownManagedRegionResult } {
  let raw: unknown = input;
  if (typeof input === 'string') {
    try {
      raw = JSON.parse(input);
    } catch {
      return { failure: { ok: false, reason: 'badRequest', detail: 'unparsable json' } };
    }
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { failure: { ok: false, reason: 'badRequest', detail: 'not an object' } };
  }
  const r = raw as Record<string, unknown>;
  if (r.region !== 'notes' && r.region !== 'bibliography') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'region' } };
  }
  if (typeof r.expectedOld !== 'string') return { failure: { ok: false, reason: 'badRequest', detail: 'expectedOld' } };
  if (typeof r.newText !== 'string') return { failure: { ok: false, reason: 'badRequest', detail: 'newText' } };
  if (r.headingLine !== undefined && r.headingLine !== null && typeof r.headingLine !== 'string') {
    return { failure: { ok: false, reason: 'badRequest', detail: 'headingLine' } };
  }
  return {
    request: {
      region: r.region,
      headingLine: r.headingLine as string | null | undefined,
      expectedOld: r.expectedOld,
      newText: r.newText,
    },
  };
}

/** A located region: the span to replace and the frame to keep. */
interface Located {
  /** Start of the region's first line. */
  from: number;
  /** End of the region's content (no trailing blank lines). */
  contentEnd: number;
  /** End of the region including the blank lines up to the next block (what removing the region takes). */
  removeEnd: number;
  /** The text a replacement keeps in front of the new first line (anchor, bibliography opening marker). */
  lead: string;
  /** True for a bibliography whose opening marker is alone on its line (the heading follows on a later line). */
  standaloneMarker: boolean;
  /** The leading markers of the heading line inside a standalone-marker bibliography (its anchor). */
  headingLead: string;
}

type Outcome = { located: Located } | { failure: MarkdownManagedRegionResult };

/** Offset of the start of the first non-blank line at or after `offset` (the document end when none). */
function nextBlockStart(doc: import('@codemirror/state').Text, offset: number): number {
  let line = doc.lineAt(Math.min(offset, doc.length));
  if (line.from < offset) {
    if (line.number >= doc.lines) return doc.length;
    line = doc.line(line.number + 1);
  }
  for (;;) {
    if (line.text.trim() !== '') return line.from;
    if (line.number >= doc.lines) return doc.length;
    line = doc.line(line.number + 1);
  }
}

function locateNotes(
  doc: import('@codemirror/state').Text,
  scan: DocumentScan,
  request: MarkdownManagedRegionRequest
): Outcome {
  const heading = request.headingLine ? stripLeadingHidden(request.headingLine) : '';
  if (heading === '') return { failure: { ok: false, reason: 'noRegion', detail: 'noHeadingLine' } };
  const expected = normalizeRegionText(request.expectedOld);
  let found = 0;
  for (let i = 0; i < scan.candidates.length; i++) {
    const candidate = scan.candidates[i];
    if (candidate.text !== heading) continue;
    found++;
    let end = scan.candidates[i + 1]?.from ?? doc.length;
    const marker = scan.bibliographyMarkerLines.find((from) => from > candidate.from);
    if (marker !== undefined) end = Math.min(end, marker);
    const text = doc.sliceString(candidate.from, end);
    if (normalizeRegionText(text) !== expected) continue;
    const firstLine = doc.lineAt(candidate.from).text;
    return {
      located: {
        from: candidate.from,
        contentEnd: candidate.from + text.replace(/\s+$/, '').length,
        removeEnd: end,
        lead: leadingHiddenOf(firstLine),
        standaloneMarker: false,
        headingLead: '',
      },
    };
  }
  if (found === 0) return { failure: { ok: false, reason: 'noRegion', detail: 'noHeading' } };
  return { failure: { ok: false, reason: 'regionChanged', detail: `headings=${found}` } };
}

function locateBibliography(
  doc: import('@codemirror/state').Text,
  scan: DocumentScan,
  request: MarkdownManagedRegionRequest
): Outcome {
  const start = scan.bibliographyStarts[0];
  if (start === undefined) return { failure: { ok: false, reason: 'noRegion', detail: 'noOpeningMarker' } };
  const endLineFrom = scan.bibliographyEnds.find((from) => from >= start);
  if (endLineFrom === undefined) return { failure: { ok: false, reason: 'noRegion', detail: 'noEndMarker' } };
  const end = doc.lineAt(endLineFrom).to;
  const text = doc.sliceString(start, end);
  if (normalizeRegionText(text) !== normalizeRegionText(request.expectedOld)) {
    return { failure: { ok: false, reason: 'regionChanged', detail: 'bibliography' } };
  }
  const firstLine = doc.lineAt(start).text;
  const lead = leadingHiddenOf(firstLine);
  const standaloneMarker = firstLine.slice(lead.length).trim() === '';
  let headingLead = '';
  if (standaloneMarker) {
    const heading = scan.candidates.find((candidate) => candidate.from > start && candidate.from < end);
    if (heading) headingLead = leadingHiddenOf(doc.lineAt(heading.from).text);
  }
  return {
    located: {
      from: start,
      contentEnd: end,
      removeEnd: nextBlockStart(doc, end),
      lead,
      standaloneMarker,
      headingLead,
    },
  };
}

/** The text that goes in for `newText`, keeping the region's own frame. */
function renderRegion(request: MarkdownManagedRegionRequest, located: Located): string {
  const body = request.newText.trim();
  if (request.region === 'notes') return located.lead + body;
  const startsWithHeading = ATX_HEADING.test(body);
  let opening: string;
  if (located.standaloneMarker) {
    opening = `${BIBLIOGRAPHY_START_MARKER}\n\n${startsWithHeading ? located.headingLead : ''}`;
  } else {
    // glued: the opening marker (and the heading's anchor) sit in front of the heading itself
    opening = startsWithHeading ? located.lead : `${BIBLIOGRAPHY_START_MARKER}\n\n`;
  }
  return `${opening}${body}\n\n${BIBLIOGRAPHY_END_MARKER}`;
}

/** window.FinalFinal.markdownReplaceManagedRegion. See the header for the contract. Never throws. */
export function markdownReplaceManagedRegion(json: string | object): MarkdownManagedRegionResult {
  const view = getEditorView();
  if (!view) return { ok: false, reason: 'noEditor' };
  const parsed = parseRequest(json);
  if ('failure' in parsed) return parsed.failure;
  const { request } = parsed;

  const doc = view.state.doc;
  const scan = scanDocument(doc, null);
  const outcome = request.region === 'notes' ? locateNotes(doc, scan, request) : locateBibliography(doc, scan, request);
  if ('failure' in outcome) return outcome.failure;
  const { located } = outcome;

  const removing = normalizeRegionText(request.newText) === '';
  const insert = removing ? '' : renderRegion(request, located);
  const to = removing ? located.removeEnd : located.contentEnd;
  if (!removing && doc.sliceString(located.from, to) === insert) {
    return { ok: true, changed: false, postRaw: doc.toString() };
  }
  try {
    // ONE transaction, sync-origin: outside the text history, saved copies follow it (maybeAdvanceRegistryOnSyncOriginTx), and the
    // selection is mapped through the change, so a caret in the body stays where it was.
    withAppOrigin(() =>
      view.dispatch({
        changes: { from: located.from, to, insert },
        annotations: Transaction.addToHistory.of(false),
      })
    );
  } catch {
    return { ok: false, reason: 'dispatchThrew' };
  }
  return { ok: true, changed: true, postRaw: view.state.doc.toString() };
}
