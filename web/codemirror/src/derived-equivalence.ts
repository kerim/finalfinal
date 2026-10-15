// "Equal modulo what the app regenerates" -- the fallback comparison for structural undo routing.
// CodeMirror (Markdown mode) mirror of web/milkdown/src/derived-equivalence.ts; read that header for the
// full reasoning. In short: Cmd-Z routes to a structural undo (section delete / duplicate / reorder /
// version restore) only when the live document equals the one saved right after the operation. If the user
// typed first and the app's own rewrites (footnote renumber, Notes and bibliography rebuild) landed after,
// then the user undid the typing, the live text is the saved text plus those rewrites. This comparison is
// consulted ONLY after exact equality has failed, only at Cmd-Z / Cmd-Shift-Z time, and answers "different"
// whenever in doubt: the worst outcome is Cmd-Z undoing typing before it restores the section, never a
// restore that drops the user's words.
//
// Works on the text. What it ignores (the app regenerates it after a structural swap):
//   * section anchors `<!-- @sid:UUID -->` (the Markdown form of heading ids);
//   * the bibliography, from `<!-- ::auto-bibliography:: -->` (on the bibliography heading's own line)
//     through `<!-- ::auto-bibliography-end:: -->`. With NO end marker nothing is cut: the region is
//     compared exactly like any other text (cutting to the end of the text would hide whatever the user
//     typed after the bibliography);
//   * footnote labels: references `[^N]` are blanked to `[^]`; definitions (`[^N]: text`, plus indented
//     continuation lines) are removed from the body and compared by the reference that points at them, in
//     reference order. A label defined twice makes the text ambiguous: never equivalent;
//   * a definition no body reference points to (an "orphan": the deleted section's footnote, which the next
//     Notes rebuild deletes), when the other text has none. When BOTH texts have orphans their texts are
//     compared as a multiset, because text typed into an orphan is the user's;
//   * the Notes heading (a heading whose next non-blank line is a definition) when none of the definitions
//     in its run is referenced: Swift removes it when no footnote remains;
//   * runs of three or more newlines (one paragraph break) and trailing whitespace at the very END of the
//     whole text. Trailing whitespace is NEVER trimmed per line: two trailing spaces are a Markdown hard
//     line break and a trailing space is ordinary typing.
// Everything else is compared exactly. The projection of a document is cached in a WeakMap (Text is
// immutable).
//
// The real Markdown-mode text is the Swift-assembled document with the hidden markers injected
// (`BlockParser.assembleMarkdownForEditor`, then `SectionSyncService.injectSectionAnchors` and
// `injectBibliographyMarker`): blocks separated by a blank line, every definition on its own line with a
// blank line between, every heading line prefixed by its anchor, and the bibliography heading line starting
// with the opening marker glued in front of the anchor
// (`<!-- ::auto-bibliography:: --><!-- @sid:UUID --># Bibliography`). The anchors are removed first, so the
// opening marker is then glued to the `#`, and everything from it through the end marker is cut.
//
// `explainTextDifference` is the same comparison returning WHY it said "different" (null when
// equivalent): the routing logs it on a refused Cmd-Z so the next real-app failure explains itself. The
// reason NEVER carries document text (no typed words, heading text or footnote text: docs/guides/
// debug-logging.md); it names line numbers, columns, counts and lengths only.
// `textsEquivalentIgnoringDerived` (the boolean the routing uses) is defined on top of it.

import type { Text } from '@codemirror/state';

const ANCHOR = /<!-- @sid:[0-9a-fA-F-]+ -->/g;
const BIBLIOGRAPHY_START = '<!-- ::auto-bibliography:: -->';
const BIBLIOGRAPHY_END = '<!-- ::auto-bibliography-end:: -->';
const DEFINITION = /^\[\^([^\]\s]+)\]:[ \t]?(.*)$/;
const CONTINUATION = /^(?: {2,}|\t)\S/;
const HEADING = /^#{1,6}\s/;
const REFERENCE = /\[\^([^\]\s]+)\](?!:)/g;

interface Projection {
  /** The footnote label defined twice, or null. A duplicate makes the text ambiguous: never equivalent. */
  duplicateLabel: string | null;
  /** The body text with regenerated parts removed or blanked. */
  body: string;
  /** For each footnote reference in the body, in order: its definition's text (null: none). */
  notes: Array<string | null>;
  /** Texts of the definitions no body reference points to. */
  orphans: string[];
  /** One line saying how the bibliography region was recognised (diagnostics only). */
  bibliography: string;
}

type Item = { def: false; line: string } | { def: true; label: string; text: string };

const projections = new WeakMap<Text, Projection>();

function isBlankLine(item: Item): boolean {
  return !item.def && item.line.trim() === '';
}

/** Cuts every bibliography region that has an end marker; a start marker with no end marker after it is
 * left in place (compared exactly). `shape` says what was found, for diagnostics. */
function cutBibliography(text: string): { text: string; shape: string } {
  let out = '';
  let from = 0;
  let cuts = 0;
  let shape = '';
  for (;;) {
    const start = text.indexOf(BIBLIOGRAPHY_START, from);
    if (start < 0) break;
    const end = text.indexOf(BIBLIOGRAPHY_END, start + BIBLIOGRAPHY_START.length);
    if (end < 0) {
      shape = 'opening marker has no end marker (compared exactly)';
      break;
    }
    out += text.slice(from, start);
    from = end + BIBLIOGRAPHY_END.length;
    cuts++;
  }
  const rest = text.slice(from);
  if (shape === '' && cuts === 0 && rest.includes(BIBLIOGRAPHY_END)) {
    shape = 'end marker without an opening marker before it (compared exactly)';
  }
  if (shape === '') shape = cuts === 0 ? 'none' : `${cuts} region(s) cut (opening marker .. end marker)`;
  return { text: out + rest, shape };
}

function toItems(lines: string[]): Item[] {
  const items: Item[] = [];
  for (const line of lines) {
    const match = DEFINITION.exec(line);
    if (match) {
      items.push({ def: true, label: match[1], text: match[2] });
      continue;
    }
    const last = items[items.length - 1];
    if (last?.def && CONTINUATION.test(line)) {
      last.text += `\n${line}`;
      continue;
    }
    items.push({ def: false, line });
  }
  return items;
}

function buildProjection(text: string): Projection {
  const cut = cutBibliography(text.replace(ANCHOR, ''));
  const items = toItems(cut.text.split('\n'));

  const defs = new Map<string, string>();
  const refs: string[] = [];
  let duplicateLabel: string | null = null;
  for (const item of items) {
    if (item.def) {
      if (defs.has(item.label) && duplicateLabel === null) duplicateLabel = item.label;
      defs.set(item.label, item.text);
    } else {
      for (const match of item.line.matchAll(REFERENCE)) refs.push(match[1]);
    }
  }
  const referenced = new Set(refs);

  /** A heading whose next non-blank line is a definition, and no definition in its run is referenced. */
  const isUnreferencedNotesHeading = (index: number): boolean => {
    const item = items[index];
    if (item.def || !HEADING.test(item.line)) return false;
    let next = index + 1;
    while (next < items.length && isBlankLine(items[next])) next++;
    if (next >= items.length || !items[next].def) return false;
    for (let j = index + 1; j < items.length; j++) {
      const other = items[j];
      if (!other.def && (HEADING.test(other.line) || other.line.includes(BIBLIOGRAPHY_START))) break;
      if (other.def && referenced.has(other.label)) return false;
    }
    return true;
  };

  const kept: string[] = [];
  items.forEach((item, index) => {
    if (item.def || isUnreferencedNotesHeading(index)) return;
    kept.push(item.line.replace(REFERENCE, '[^]'));
  });
  const body = kept
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trimEnd();

  const notes = refs.map((label) => defs.get(label) ?? null);
  const orphans: string[] = [];
  for (const [label, definition] of defs) {
    if (!referenced.has(label)) orphans.push(definition);
  }
  return { duplicateLabel, body, notes, orphans, bibliography: cut.shape };
}

function project(doc: Text): Projection {
  let projection = projections.get(doc);
  if (projection === undefined) {
    projection = buildProjection(doc.toString());
    projections.set(doc, projection);
  }
  return projection;
}

/** `text` as a diagnostic: its length only, never the text (docs/guides/debug-logging.md). */
function lengthOf(text: string | null | undefined): string {
  if (text === null || text === undefined) return 'nothing';
  return `(${text.length} chars)`;
}

/** The first line of `a` and `b` (the projected bodies) that differs, and the first column where the two
 * lines differ, as a diagnostic: positions and lengths only, never the text. */
function describeBodyDifference(a: string, b: string): string {
  const x = a.split('\n');
  const y = b.split('\n');
  const shared = Math.min(x.length, y.length);
  let at = shared;
  for (let i = 0; i < shared; i++) {
    if (x[i] !== y[i]) {
      at = i;
      break;
    }
  }
  const lineA = x[at];
  const lineB = y[at];
  let column = 0;
  if (lineA !== undefined && lineB !== undefined) {
    while (column < lineA.length && column < lineB.length && lineA[column] === lineB[column]) column++;
  }
  return (
    `line ${at + 1} of the projected body (a has ${x.length} lines, b ${y.length}), first difference at column ${column}: ` +
    `a=${lengthOf(lineA)} b=${lengthOf(lineB)}`
  );
}

/** Orphan definitions: ignored when one text has none (the next Notes rebuild deletes them there); when
 * both have some, their texts must match as a multiset (text typed into an orphan is the user's).
 * Returns null when equivalent, else a reason. */
function orphansDifference(a: string[], b: string[]): string | null {
  if (a.length === 0 || b.length === 0) return null;
  if (a.length !== b.length) return `orphan definitions differ: a has ${a.length}, b has ${b.length}`;
  const sortedA = [...a].sort();
  const sortedB = [...b].sort();
  const at = sortedA.findIndex((text, i) => text !== sortedB[i]);
  return at < 0
    ? null
    : `orphan definitions differ: a has ${lengthOf(sortedA[at])} where b has ${lengthOf(sortedB[at])}`;
}

/** Why `a` and `b` are NOT equivalent modulo what the app regenerates, as one short line; null when they
 * are equivalent (see the file header). `a` is the live text and `b` the saved copy in the routing's use.
 * Not reflexive for an ambiguous text (a footnote label defined twice): callers test exact equality first. */
export function explainTextDifference(a: Text, b: Text): string | null {
  const pa = project(a);
  const pb = project(b);
  if (pa.duplicateLabel !== null) return 'a footnote label is defined twice in a';
  if (pb.duplicateLabel !== null) return 'a footnote label is defined twice in b';
  if (pa.body !== pb.body) {
    return (
      `body differs at ${describeBodyDifference(pa.body, pb.body)}; ` +
      `bibliography a: ${pa.bibliography} | b: ${pb.bibliography}`
    );
  }
  if (pa.notes.length !== pb.notes.length) return `reference count differs: a=${pa.notes.length} b=${pb.notes.length}`;
  for (let i = 0; i < pa.notes.length; i++) {
    if (pa.notes[i] !== pb.notes[i]) {
      return `footnote text differs at reference ${i} of ${pa.notes.length}: a=${lengthOf(pa.notes[i])} b=${lengthOf(pb.notes[i])}`;
    }
  }
  return orphansDifference(pa.orphans, pb.orphans);
}

/** True when `a` and `b` differ only in what the app regenerates (see the file header). */
export function textsEquivalentIgnoringDerived(a: Text, b: Text): boolean {
  return explainTextDifference(a, b) === null;
}
