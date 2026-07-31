// Section Break Plugin for Milkdown
// Renders as § in editor, serializes to <!-- ::break:: --> in markdown

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

// An mdast 'html' node is only genuinely block-level when it's a direct
// child of one of these container types. The 'root'/'blockquote'/'listItem'
// trio mirrors @milkdown/preset-commonmark's own remarkHtmlTransformer (its
// internal BLOCK_CONTAINER_TYPES), which uses the identical set to decide
// whether an html node needs wrapping in a paragraph before ProseMirror's
// block content model can hold it. We reuse the same test here for the
// opposite purpose: deciding whether it's safe to promote the node to
// section_break (a block-only node) at all.
//
// 'footnoteDefinition' is added on top of that trio because this editor also
// loads @milkdown/preset-gfm (see main.ts), whose footnote_definition node
// has content: 'block+' — a legitimate block container the commonmark
// preset's own constant doesn't know about, since gfm is a separate preset.
// Without it, a marker on its own line inside a footnote definition's body
// (a real, block-level position) would be wrongly left as an inline atom,
// which breaks footnote_definition's block-only content model the same way
// leaving out root/blockquote/listItem would. Confirmed via a real
// Editor.make() repro: omitting this entry reproduces the exact
// "Cannot create node for footnote_definition" failure the marker fix as a
// whole exists to prevent, just one container type over.
//
// CommonMark parses '<!-- ::break:: -->' on its own line as a block-level
// html node (parent 'root'/'blockquote'/'listItem'/'footnoteDefinition'),
// but the SAME text appearing mid-sentence (e.g. "...prose, <!-- ::break::
// --> more prose...") parses as an INLINE html node nested inside a
// paragraph's own children.
//
// User-decided behavior for this mid-paragraph case (2026-07-31): it must
// behave EXACTLY as if the user had placed their cursor at that point in the
// live WYSIWYG editor and typed the /break slash command — i.e. split the
// paragraph in two at the marker, with a real section_break block between
// them, not leave the marker as inert visible text. See
// applyBreakCommand()'s doc comment in slash-commands.ts for the
// before/after/both/neither branching this mirrors at parse time instead of
// insert time.
const BLOCK_HTML_CONTAINER_TYPES = new Set(['root', 'blockquote', 'listItem', 'footnoteDefinition']);

/** mdast node shape, loosened for the untyped tree-walking this file already does elsewhere. */
type MdastNode = { type: string; children?: MdastNode[]; value?: string; position?: unknown; [key: string]: unknown };

/**
 * Whether an mdast inline-children array has any real content, mirroring
 * applyBreakCommand's hasBefore/hasAfter check (a run of pure whitespace, or
 * no nodes at all, counts as "no content") — this keeps parse-time splitting
 * producing the identical paragraph-count branching /break's own
 * neither/before-only/after-only/both logic already uses at insert time.
 */
function mdastInlineChildrenHaveContent(children: MdastNode[]): boolean {
  const text = children.map((c) => (typeof c.value === 'string' ? c.value : '')).join('');
  if (text.trim().length > 0) return true;
  // A non-text inline atom (citation, image, footnote reference, ...) counts
  // as content even though it contributes no plain-text value.
  return children.some((c) => c.type !== 'text');
}

/**
 * Drops a leading run of spaces/tabs from the first text child (if any),
 * removing that child entirely if it becomes empty. A literal leading space
 * at the start of a markdown paragraph isn't syntactically significant
 * (most parsers wouldn't preserve it on a round-trip), so a correct
 * serializer has to escape it as `&#x20;` to survive — but that escape
 * sequence then sits in the document as ugly, literal, editable text for
 * the user. Since this space is just the separator that was between the
 * marker and the following prose, not meaningful content, trimming it here
 * avoids the escape entirely. Only spaces/tabs are touched, never newlines.
 */
function trimLeadingInlineWhitespace(children: MdastNode[]): MdastNode[] {
  if (children.length === 0) return children;
  const [first, ...rest] = children;
  if (first.type !== 'text' || typeof first.value !== 'string') return children;
  const trimmed = first.value.replace(/^[ \t]+/, '');
  if (trimmed === first.value) return children;
  return trimmed === '' ? rest : [{ ...first, value: trimmed }, ...rest];
}

/** Trailing-side mirror of trimLeadingInlineWhitespace — same rationale, same &#x20; escape this avoids, applied to the LAST text child instead of the first. */
function trimTrailingInlineWhitespace(children: MdastNode[]): MdastNode[] {
  if (children.length === 0) return children;
  const last = children[children.length - 1];
  if (last.type !== 'text' || typeof last.value !== 'string') return children;
  const trimmed = last.value.replace(/[ \t]+$/, '');
  if (trimmed === last.value) return children;
  return trimmed === '' ? children.slice(0, -1) : [...children.slice(0, -1), { ...last, value: trimmed }];
}

/**
 * Split `paragraph` (found at `paragraphIndex` in `grandparent.children`) at
 * `markerIndex` into up to two paragraphs with a bare section_break between
 * them, dropping either half if it has no real content — matching
 * applyBreakCommand's four branches exactly, except that the whitespace
 * immediately touching the marker on either side is trimmed (see
 * trimLeadingInlineWhitespace/trimTrailingInlineWhitespace) rather than kept
 * verbatim the way applyBreakCommand's own live-insertion path does — that
 * whitespace is separator, not content, and keeping it produces a visible
 * `&#x20;` escape in the saved markdown for no benefit. Splices
 * grandparent.children in place; does not touch paragraph/child node
 * identity beyond that, so no position rebasing is needed (unlike
 * annotation-plugin.ts's repair pass, nothing here is re-parsed through a
 * fresh processor — the existing, already-correctly-positioned child nodes
 * are only redistributed between two paragraph wrappers).
 */
function splitParagraphAtMarker(
  grandparent: MdastNode,
  paragraphIndex: number,
  paragraph: MdastNode,
  markerIndex: number
): void {
  const children = paragraph.children ?? [];
  const beforeChildren = trimTrailingInlineWhitespace(children.slice(0, markerIndex));
  const afterChildren = trimLeadingInlineWhitespace(children.slice(markerIndex + 1));

  const hasBefore = mdastInlineChildrenHaveContent(beforeChildren);
  const hasAfter = mdastInlineChildrenHaveContent(afterChildren);

  const replacement: MdastNode[] = [];
  if (hasBefore) replacement.push({ ...paragraph, position: undefined, children: beforeChildren });
  replacement.push({ type: 'sectionBreak' });
  if (hasAfter) replacement.push({ ...paragraph, position: undefined, children: afterChildren });

  grandparent.children?.splice(paragraphIndex, 1, ...replacement);
}

// Remark plugin to convert HTML comments to section_break nodes
// Uses unist-util-visit for proper tree traversal
// This runs during the initial parse phase, before HTML filtering
const remarkPlugin = $remark('section-break', () => () => (tree: Root) => {
  // Two passes: structural splicing (inserting/removing tree nodes) during
  // unist-util-visit's own traversal is unsafe, so the first pass only
  // collects which paragraphs need splitting, and the second pass performs
  // the splice via a second, targeted visit per paragraph (paragraphs
  // containing a stray marker are rare, so re-walking for each one is cheap
  // and avoids the bookkeeping cost of tracking grandparent+index for every
  // candidate up front).
  const paragraphsToSplit: Array<{ paragraph: MdastNode; markerIndex: number }> = [];

  visit(tree, 'html', (node: any, index: number | undefined, parent: any) => {
    if (node.value?.trim() !== '<!-- ::break:: -->') return;

    if (parent && BLOCK_HTML_CONTAINER_TYPES.has(parent.type)) {
      // Already block-level: convert directly to the real node type.
      node.type = 'sectionBreak';
      delete node.value;
      return;
    }

    // Mid-paragraph: schedule a split. Scoped to a 'paragraph' parent only —
    // matches /break's own scope (a slash command run with the cursor inside
    // a paragraph); other inline-content containers this app's schema
    // allows (e.g. a table cell) aren't expected to hold a legitimate
    // section break at all, so a marker found there is left as inert text,
    // same as before.
    if (parent && parent.type === 'paragraph' && typeof index === 'number') {
      paragraphsToSplit.push({ paragraph: parent, markerIndex: index });
    }
  });

  for (const { paragraph, markerIndex } of paragraphsToSplit) {
    visit(
      tree,
      (n: any) => n === paragraph,
      (_node: any, index: number | undefined, parent: any) => {
        if (!parent || typeof index !== 'number') return;
        splitParagraphAtMarker(parent, index, paragraph, markerIndex);
      }
    );
  }
});

// Define the section_break node
const sectionBreakNode = $node('section_break', () => ({
  group: 'block',
  atom: false, // Changed from true to allow single-press deletion
  selectable: true,
  draggable: false,

  parseDOM: [
    {
      tag: 'div.section-break',
    },
  ],

  toDOM: (_node: Node) => [
    'div',
    { class: 'section-break', contenteditable: 'false' },
    '\u00A7', // § character
  ],

  parseMarkdown: {
    match: (node: any) => node.type === 'sectionBreak',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'section_break',
    runner: (state: any, _node: Node) => {
      // Output as HTML comment
      state.addNode('html', undefined, '<!-- ::break:: -->');
    },
  },
}));

// Export the plugin array
export const sectionBreakPlugin: MilkdownPlugin[] = [remarkPlugin, sectionBreakNode].flat();

// Export the node for use in slash commands
export { sectionBreakNode };
