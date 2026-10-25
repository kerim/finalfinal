// The footnote renumber of a structural settle, with the Notes definitions sorted in the SAME change set (t-4a8fd8af, Phase 4b,
// Markdown slice 2, the cure for the review finding V1).
//
// A Markdown drag moves a footnoted chapter, and the settle then renumbers the references (and the definitions) in place:
// `renumberFootnotes` (api.ts) relabels every `[^old]` to `[^new]` where it stands. The definitions in the Notes region keep their
// POSITIONS, so after the relabel they read, for example, 1..18, 28..36, 19..27, 37..54. The sorted Notes arrive later, from the
// database, through the Notes rebuild (`markdownReplaceManagedRegion`). A Save Version or a Cmd-W that runs before that rebuild writes
// the page's text into the rows, and the unsorted Notes are then what is saved. Here the relabel of a settle sorts the definitions as
// well, in the one transaction, so the page never holds relabelled-but-unsorted Notes.
//
// The sort is deliberately narrow. It happens only when Swift supplied the Notes heading line together with the settle flag
// (`setStructuralSettleOpId(opId, notesHeadingLine)`), and it falls back to RELABEL ONLY (the plain change list, exactly what the
// renumber has always done) whenever the region is not exactly "the heading, then footnote definition blocks":
//   * the heading line is not found among the document's leader lines, or is found more than once (which region is the managed one?);
//   * the region holds anything that is not a definition block -- a definition is a `[^N]:` line plus its continuation lines (indented
//     two spaces or a tab, or one blank line followed by a four-space paragraph, the way BlockParser keeps a footnote going); blank
//     lines between definitions are fine;
//   * a label is not a plain whole number after the relabel.
// The sort is stable and by the NEW number. The blank lines between the definitions stay where they are (the gaps keep their places,
// the blocks swap), so the region keeps its shape.

import type { Text } from '@codemirror/state';
import {
  FOOTNOTE_CONTINUATION,
  FOOTNOTE_DEFINITION,
  scanDocument,
  stripLeadingHidden,
} from './api-structural-markdown';

export interface LabelChange {
  from: number;
  to: number;
  insert: string;
}

interface DefinitionBlock {
  /** Offset of the block's first character inside the region text. */
  start: number;
  /** Offset just past the block's last character inside the region text. */
  end: number;
  label: string;
}

/** The Notes region's span: from its heading line to the content end (no trailing blank lines), or null when it cannot be found. */
function locateNotesRegion(doc: Text, headingLine: string): { from: number; contentEnd: number } | null {
  const heading = stripLeadingHidden(headingLine);
  if (heading === '') return null;
  const scan = scanDocument(doc, null);
  const hits = scan.candidates.filter((candidate) => candidate.text === heading);
  if (hits.length !== 1) return null;
  const heading0 = hits[0];
  const index = scan.candidates.indexOf(heading0);
  let end = scan.candidates[index + 1]?.from ?? doc.length;
  const marker = scan.bibliographyMarkerLines.find((from) => from > heading0.from);
  if (marker !== undefined) end = Math.min(end, marker);
  const text = doc.sliceString(heading0.from, end);
  return { from: heading0.from, contentEnd: heading0.from + text.replace(/\s+$/, '').length };
}

/** The definition blocks of a region text (heading line first), or null when it holds anything else. */
function parseDefinitionBlocks(region: string): DefinitionBlock[] | null {
  const lines = region.split('\n');
  const lineStart: number[] = [];
  let offset = 0;
  for (const line of lines) {
    lineStart.push(offset);
    offset += line.length + 1;
  }
  const blocks: DefinitionBlock[] = [];
  let i = 1; // line 0 is the heading
  while (i < lines.length) {
    if (lines[i].trim() === '') {
      i++;
      continue;
    }
    const match = FOOTNOTE_DEFINITION.exec(lines[i]);
    if (!match) return null;
    let last = i;
    for (;;) {
      while (last + 1 < lines.length && FOOTNOTE_CONTINUATION.test(lines[last + 1])) last++;
      // One blank line and then a four-space paragraph: the same footnote goes on (BlockParser+Splitting `isFootnoteContinuation`).
      if (last + 2 < lines.length && lines[last + 1].trim() === '' && lines[last + 2].startsWith('    ')) {
        last += 2;
        continue;
      }
      break;
    }
    blocks.push({ start: lineStart[i], end: lineStart[last] + lines[last].length, label: match[1] });
    i = last + 1;
  }
  return blocks;
}

/** `region` with its definition blocks stably sorted by number, the gaps between them left where they are; null when not sortable. */
function sortDefinitions(region: string): string | null {
  const blocks = parseDefinitionBlocks(region);
  if (blocks === null || blocks.length === 0) return null;
  if (!blocks.every((block) => /^\d+$/.test(block.label))) return null;
  const order = blocks
    .map((_, index) => index)
    .sort((a, b) => Number(blocks[a].label) - Number(blocks[b].label) || a - b);
  let out = region.slice(0, blocks[0].start);
  order.forEach((blockIndex, slot) => {
    out += region.slice(blocks[blockIndex].start, blocks[blockIndex].end);
    if (slot + 1 < blocks.length) out += region.slice(blocks[slot].end, blocks[slot + 1].start);
  });
  return out + region.slice(blocks[blocks.length - 1].end);
}

/**
 * The change list of a settle's renumber with the Notes sorted: `labelChanges` (ascending, non-overlapping, in `doc` coordinates, the
 * relabels `renumberFootnotes` found) outside the Notes region, and ONE replacement of the region with its relabelled, sorted text.
 * Returns null when the sort does not apply (see the header); the caller then dispatches `labelChanges` as they are.
 */
export function renumberWithSortedNotes(
  doc: Text,
  labelChanges: readonly LabelChange[],
  notesHeadingLine: string
): LabelChange[] | null {
  const region = locateNotesRegion(doc, notesHeadingLine);
  if (region === null) return null;
  const inside = labelChanges.filter((change) => change.from >= region.from && change.to <= region.contentEnd);
  const outside = labelChanges.filter((change) => change.to <= region.from || change.from >= region.contentEnd);
  if (inside.length + outside.length !== labelChanges.length) return null; // a relabel straddles the region's edge
  if (inside.length === 0) return null; // nothing was relabelled in the Notes: nothing to sort

  const original = doc.sliceString(region.from, region.contentEnd);
  let relabelled = original;
  for (const change of [...inside].sort((a, b) => b.from - a.from)) {
    relabelled =
      relabelled.slice(0, change.from - region.from) + change.insert + relabelled.slice(change.to - region.from);
  }
  const sorted = sortDefinitions(relabelled);
  if (sorted === null) return null;
  return [...outside, { from: region.from, to: region.contentEnd, insert: sorted }].sort((a, b) => a.from - b.from);
}
