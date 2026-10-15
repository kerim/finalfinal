// "Equal modulo what the app regenerates" -- the fallback comparison for structural undo routing.
//
// Cmd-Z after a section delete / duplicate / reorder / version restore routes to the structural undo only
// when the live document equals the document saved right after the operation (undo-coordinator.ts's
// decideRouting; docs/architecture/unified-undo.md, routing section). Automatic rewrites that land right
// after the operation are absorbed into the saved copy as they happen, so the common case is exact. This
// comparison covers the case they cannot: the user typed first, THEN the app's own rewrites landed (the
// footnote renumber, the Notes and bibliography rebuild), and the user then undid the typing. The live
// document is now the saved copy plus those rewrites: not equal, yet nothing the user wrote differs.
//
// It is consulted ONLY after exact equality has failed, and only at Cmd-Z / Cmd-Shift-Z time -- never on a
// keystroke. A structural undo swaps to the pre-operation checkpoint, which drops whatever differs from
// the saved copy, so "equivalent" must mean: every difference is something the app regenerates after such a
// swap. Anything else -- the typed word, an edit to a footnote that is still referenced, a moved or deleted
// reference, text after the bibliography -- makes the documents different, Cmd-Z undoes the typing first,
// and the user's words are never dropped. Where in doubt this answers "different": the worst outcome is a
// Cmd-Z that undoes typing before it restores the section, never a restore that loses typing.
//
// The document is projected (top-level children, one pass):
//   * Bibliography: skipped between a recognised START and the `auto_bibliography_end` marker (both
//     included). Two real shapes exist, and BOTH must be recognised:
//       1. The opening marker `auto_bibliography` node ... the end marker. This is the shape a document has
//          when it carries the standalone `<!-- ::auto-bibliography:: -->` block (legacy / imported text).
//       2. NO opening marker: the shape of every bibliography the app itself generates. Swift's
//          `BibliographySyncService` writes the bibliography as `# <header name>` plus one paragraph per
//          entry and deliberately WITHOUT the opening marker ("marker is injected only for CodeMirror
//          source mode"), and `BlockParser.assembleMarkdownForEditor` appends the END marker right after
//          the last bibliography block. The editor's document therefore reads `... # Bibliography, entries,
//          <end marker>`. Its start is the heading that opens the run: the NEAREST heading before the end
//          marker, accepted only when it is a level 1 or 2 heading titled exactly "Bibliography" or
//          "References" (the two titles Swift's `BlockParser.isBibliographyHeading` always accepts; the
//          editor does not know a user's custom header name) and at least one node sits between it and the
//          end marker. That mirrors Swift's own tier-2 rule (BibliographyOpeningSelector: the last title
//          candidate before the terminator, no heading in its run, non-empty run).
//     With NO end marker nothing is skipped (compared exactly, like any other body text: skipping to the
//     end of the document would hide whatever the user typed after the bibliography), and an end marker
//     whose start is not recognised (a custom header name, a subsection heading inside the run, an empty
//     run) skips nothing either: exact comparison, never a wrong restore.
//   * Footnote definition paragraphs (a paragraph starting with a `footnote_def` atom) leave the body.
//     Their text is kept by label and compared through the references that point at them, in reference
//     order. A label defined twice makes the document ambiguous: never equivalent.
//   * A heading directly followed by a definition paragraph (the Notes heading) stays in the body only
//     when some definition in its run is referenced from the body; Swift removes it when no footnote
//     remains.
//   * Definitions no body reference points to ("orphans": the deleted section's footnotes, which the next
//     Notes rebuild deletes) are ignored when the other document has none; when BOTH documents have
//     orphans their texts are compared as a multiset, because text typed into an orphan is the user's.
//   * Everything else is body, compared with Node.eq after blanking what the app regenerates: heading `id`
//     (a slug), `footnote_ref` `label` (renumbered) and the `blockId` node attribute. Only figure (image)
//     nodes carry that attribute (api-content.ts rewrites it to the database id when Swift pushes ids);
//     the block ids of every other node live in module state (block-id-plugin.ts), not in the document,
//     so there is nothing to blank for them.
// The projection of a document is cached in a WeakMap (nodes are immutable).
//
// `explainDerivedDifference` is the same comparison returning WHY it said "different" (null when
// equivalent): the routing logs it on a refused Cmd-Z so the next real-app failure explains itself. The
// reason NEVER carries document text (no typed words, heading text or footnote text: docs/guides/
// debug-logging.md); it names positions, counts, node types and sizes only. `docsEquivalentIgnoringDerived`
// (the boolean the routing uses) is defined on top of it.

import { Fragment, type Node } from '@milkdown/kit/prose/model';

interface Projection {
  /** The footnote label defined twice, or null. A duplicate makes the document ambiguous: never equivalent. */
  duplicateLabel: string | null;
  /** Top-level body nodes in canonical form. */
  body: Node[];
  /** For each body node, its index among the document's top-level children (for diagnostics). */
  bodyIndex: number[];
  /** For each footnote reference in the body, in document order: its definition's text (null: none). */
  notes: Array<Fragment | null>;
  /** Texts of the definitions no body reference points to. */
  orphans: Fragment[];
  /** One line saying how the bibliography region was recognised (diagnostics only). */
  bibliography: string;
}

const projections = new WeakMap<Node, Projection>();

/** The titles `BlockParser.isBibliographyHeading` always accepts (Swift also accepts the user's configured
 * and earlier names, which this editor does not know: such a document is compared exactly). */
const BIBLIOGRAPHY_TITLES = new Set(['Bibliography', 'References']);

function isDefinitionParagraph(node: Node): boolean {
  return node.type.name === 'paragraph' && node.firstChild?.type.name === 'footnote_def';
}

/** The attributes of `node` with everything the app regenerates blanked, or null when nothing changes. */
function blankedAttrs(node: Node): Record<string, unknown> | null {
  const { attrs } = node;
  const name = node.type.name;
  const blank: string[] = [];
  if (name === 'heading' && attrs.id) blank.push('id');
  if (name === 'footnote_ref' && attrs.label) blank.push('label');
  if (attrs.blockId) blank.push('blockId');
  if (blank.length === 0) return null;
  const next: Record<string, unknown> = { ...attrs };
  for (const key of blank) next[key] = '';
  return next;
}

/** `node` with regenerated attributes blanked, rebuilt only where something changed (shares the rest). */
function canonical(node: Node): Node {
  const attrs = blankedAttrs(node);
  let content = node.content;
  if (node.childCount > 0) {
    const kids: Node[] = [];
    let changed = false;
    for (let i = 0; i < node.childCount; i++) {
      const child = node.child(i);
      const next = canonical(child);
      if (next !== child) changed = true;
      kids.push(next);
    }
    if (changed) content = Fragment.fromArray(kids);
  }
  if (attrs === null && content === node.content) return node;
  return node.type.create(attrs ?? node.attrs, content, node.marks);
}

/** True when some definition in the run that follows the heading at `headingIndex` (up to the next heading
 * or bibliography marker) is referenced from the body. */
function notesRunIsReferenced(
  children: Node[],
  isDef: boolean[],
  headingIndex: number,
  referenced: Set<string>
): boolean {
  for (let j = headingIndex + 1; j < children.length; j++) {
    const name = children[j].type.name;
    if (name === 'heading' || name === 'auto_bibliography' || name === 'auto_bibliography_end') break;
    if (isDef[j] && referenced.has(String(children[j].firstChild?.attrs.label))) return true;
  }
  return false;
}

/** A node as a short, single-line diagnostic: type (and heading level) and the size of its content. Never
 * its text (docs/guides/debug-logging.md). */
function describeNode(node: Node | undefined): string {
  if (node === undefined) return 'nothing';
  const level = node.type.name === 'heading' ? String(node.attrs.level) : '';
  return `${node.type.name}${level}(size=${node.content.size})`;
}

/** A footnote definition's text as a diagnostic: its size only, never the text. */
function describeFragment(fragment: Fragment | null | undefined): string {
  if (fragment === null || fragment === undefined) return 'no definition';
  return `(size=${fragment.size})`;
}

/** Marks the bibliography regions as skipped and says how each was (or was not) recognised. */
function findBibliography(children: Node[]): { skipped: boolean[]; shape: string } {
  const skipped: boolean[] = children.map(() => false);
  const notes: string[] = [];

  // Shape 1: opening marker ... end marker. An opening marker with no end marker after it is not skipped.
  for (let i = 0; i < children.length; i++) {
    if (children[i].type.name !== 'auto_bibliography') continue;
    let end = -1;
    for (let j = i + 1; j < children.length; j++) {
      if (children[j].type.name === 'auto_bibliography_end') {
        end = j;
        break;
      }
    }
    if (end < 0) {
      notes.push(`opening marker at child ${i} has no end marker`);
      continue;
    }
    for (let k = i; k <= end; k++) skipped[k] = true;
    notes.push(`children ${i}..${end} skipped (opening marker .. end marker)`);
    i = end;
  }

  // Shape 2: no opening marker. The nearest heading before an end marker opens the run when it is a
  // level 1 or 2 heading titled Bibliography / References and the run is not empty.
  for (let e = 0; e < children.length; e++) {
    if (children[e].type.name !== 'auto_bibliography_end' || skipped[e]) continue;
    let h = e - 1;
    while (h >= 0 && children[h].type.name !== 'heading') h--;
    if (h < 0) {
      notes.push(`end marker at child ${e} not bounded: no heading before it`);
      continue;
    }
    const heading = children[h];
    const titleOk = BIBLIOGRAPHY_TITLES.has(heading.textContent.trim());
    const level = Number(heading.attrs.level);
    if (!titleOk || !(level === 1 || level === 2)) {
      notes.push(
        `end marker at child ${e} not bounded: nearest heading before it is ${describeNode(heading)} (child ${h}), ` +
          `not a level 1-2 Bibliography/References heading (titleMatches=${titleOk} level=${level})`
      );
      continue;
    }
    if (e - h < 2) {
      notes.push(
        `end marker at child ${e} not bounded: nothing between it and the level ${level} Bibliography/References heading (child ${h})`
      );
      continue;
    }
    for (let k = h; k <= e; k++) skipped[k] = true;
    notes.push(`children ${h}..${e} skipped (level ${level} Bibliography/References heading .. end marker)`);
  }

  return { skipped, shape: notes.length === 0 ? 'none' : notes.join('; ') };
}

function buildProjection(doc: Node): Projection {
  const children: Node[] = [];
  doc.forEach((child) => {
    children.push(child);
  });

  const { skipped, shape } = findBibliography(children);

  // Definitions (by label) and, in document order, the labels of the references in the body.
  const isDef: boolean[] = children.map((child, i) => !skipped[i] && isDefinitionParagraph(child));
  const defs = new Map<string, Fragment>();
  const refs: string[] = [];
  let duplicateLabel: string | null = null;
  children.forEach((child, i) => {
    if (skipped[i]) return;
    if (isDef[i]) {
      const marker = child.firstChild as Node;
      const label = String(marker.attrs.label);
      if (defs.has(label) && duplicateLabel === null) duplicateLabel = label;
      defs.set(label, child.content.cut(marker.nodeSize));
      return;
    }
    child.descendants((n) => {
      if (n.type.name === 'footnote_ref') refs.push(String(n.attrs.label));
    });
  });
  const referenced = new Set(refs);

  const body: Node[] = [];
  const bodyIndex: number[] = [];
  children.forEach((child, i) => {
    if (skipped[i] || isDef[i]) return;
    if (child.type.name === 'heading' && isDef[i + 1] && !notesRunIsReferenced(children, isDef, i, referenced)) return;
    body.push(canonical(child));
    bodyIndex.push(i);
  });

  const notes = refs.map((label) => defs.get(label) ?? null);
  const orphans: Fragment[] = [];
  for (const [label, text] of defs) {
    if (!referenced.has(label)) orphans.push(text);
  }
  return { duplicateLabel, body, bodyIndex, notes, orphans, bibliography: shape };
}

function project(doc: Node): Projection {
  let projection = projections.get(doc);
  if (projection === undefined) {
    projection = buildProjection(doc);
    projections.set(doc, projection);
  }
  return projection;
}

/** Orphan definitions: ignored when one document has none (the next Notes rebuild deletes them there);
 * when both have some, their texts must match as a multiset (text typed into an orphan is the user's).
 * Returns null when equivalent, else a reason. */
function orphansDifference(a: Fragment[], b: Fragment[]): string | null {
  if (a.length === 0 || b.length === 0) return null;
  if (a.length !== b.length) return `orphan definitions differ: a has ${a.length}, b has ${b.length}`;
  const rest = [...b];
  for (const text of a) {
    const at = rest.findIndex((other) => other.eq(text));
    if (at < 0) {
      return `orphan definitions differ: an orphan of a ${describeFragment(text)} has no equal text among b's ${b.length}`;
    }
    rest.splice(at, 1);
  }
  return null;
}

/** Why `a` and `b` are NOT equivalent modulo what the app regenerates, as one short line; null when they
 * are equivalent (see the file header). `a` is the live document and `b` the saved copy in the routing's
 * use. Not reflexive for an ambiguous document (a footnote label defined twice): callers test exact
 * equality first. */
export function explainDerivedDifference(a: Node, b: Node): string | null {
  const pa = project(a);
  const pb = project(b);
  if (pa.duplicateLabel !== null) return 'a footnote label is defined twice in a';
  if (pb.duplicateLabel !== null) return 'a footnote label is defined twice in b';

  const shared = Math.min(pa.body.length, pb.body.length);
  let at = -1;
  for (let i = 0; i < shared; i++) {
    if (!pa.body[i].eq(pb.body[i])) {
      at = i;
      break;
    }
  }
  if (at < 0 && pa.body.length !== pb.body.length) at = shared;
  if (at >= 0) {
    return (
      `body differs at body node ${at} (a child ${pa.bodyIndex[at] ?? 'end'}, b child ${pb.bodyIndex[at] ?? 'end'}): ` +
      `a=${describeNode(pa.body[at])} b=${describeNode(pb.body[at])}; body nodes a=${pa.body.length} b=${pb.body.length}; ` +
      `bibliography a: ${pa.bibliography} | b: ${pb.bibliography}`
    );
  }

  if (pa.notes.length !== pb.notes.length) return `reference count differs: a=${pa.notes.length} b=${pb.notes.length}`;
  for (let i = 0; i < pa.notes.length; i++) {
    const x = pa.notes[i];
    const y = pb.notes[i];
    const same = x === null || y === null ? x === y : x.eq(y);
    if (!same) {
      return `footnote text differs at reference ${i} of ${pa.notes.length}: a=${describeFragment(x)} b=${describeFragment(y)}`;
    }
  }
  return orphansDifference(pa.orphans, pb.orphans);
}

/** True when `a` and `b` differ only in what the app regenerates (see the file header). */
export function docsEquivalentIgnoringDerived(a: Node, b: Node): boolean {
  return explainDerivedDifference(a, b) === null;
}
