// @vitest-environment jsdom
// Footnote definition content preservation tests.
//
// Regression coverage for a data-loss bug (board task t-f3f0c244): footnote
// definitions had their citations and annotations stripped out. Both are
// normal, expected content inside a footnote and the loss was real database
// loss (WYSIWYG/Milkdown only; CodeMirror keeps a raw text buffer).
//
// footnote-plugin.ts's remark pass 1 used to flatten a GFM
// `footnoteDefinition` into `paragraph[footnote_def, text(" " + extractText)]`,
// and extractTextFromChildren() keeps only `type === 'text'` values -- so any
// `citation` / `annotation` (and emphasis/link/inlineCode) node in the
// definition's paragraph was discarded before the document ever reached
// ProseMirror, and therefore before it was serialized back to the database.
//
// These tests drive a real Milkdown Editor (rootCtx/defaultValueCtx,
// editorViewCtx to read the doc), with the same plugin registration order
// main.ts uses: annotation -> citation -> footnote -> commonmark -> gfm. That
// order matters: pass 1 must run AFTER citation and annotation have converted
// their text/html nodes, which is what makes the spliced-through atoms
// available in the first place.
//
// Serialization is asserted through BOTH serializers, because they are not the
// same code: getMarkdown() is Milkdown's stock serializer (what a WYSIWYG
// round-trip uses), while nodeToMarkdownFragment() (block-sync-plugin.ts,
// reached via getMarkdownFragment / getBlockChanges) is the hand-written one
// the app actually writes blocks to the database with. The reported data loss
// happened on the DATABASE path, so that is the one that must be pinned.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { annotationPlugin } from '../annotation-plugin';
import { nodeToMarkdownFragment } from '../block-sync-plugin';
import { citationPlugin } from '../citation-plugin';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin, renumberFootnotes } from '../footnote-plugin';

async function makeEditor(markdown: string): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  return Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(annotationPlugin)
    .use(citationPlugin)
    .use(footnotePlugin)
    .use(commonmark)
    .use(gfm)
    .create();
}

/** All nodes of a given ProseMirror type name, in document order. */
function collectNodes(doc: Node, typeName: string): Node[] {
  const found: Node[] = [];
  doc.descendants((node) => {
    if (node.type.name === typeName) found.push(node);
    return true;
  });
  return found;
}

/**
 * The one paragraph holding a footnote definition -- identified structurally
 * (first child is the `footnote_def` atom), not by document position, so the
 * test still reads correctly if other blocks surround it.
 */
function findDefParagraph(doc: Node): Node | null {
  let found: Node | null = null;
  doc.descendants((node) => {
    if (found) return false;
    if (node.type.name === 'paragraph' && node.childCount > 0 && node.child(0).type.name === 'footnote_def') {
      found = node;
      return false;
    }
    return true;
  });
  return found;
}

function childTypeNames(paragraph: Node): string[] {
  const names: string[] = [];
  paragraph.forEach((child) => {
    names.push(child.type.name);
  });
  return names;
}

describe('footnote definition content preservation (real Milkdown editor)', () => {
  const editors: Editor[] = [];

  afterEach(async () => {
    setEditorInstance(null);
    while (editors.length > 0) {
      const e = editors.pop();
      if (e) await e.destroy();
    }
  });

  async function make(markdown: string): Promise<Editor> {
    const e = await makeEditor(markdown);
    editors.push(e);
    return e;
  }

  it('keeps a citation node inside a footnote definition, in the doc, in getMarkdown(), and in the database fragment', async () => {
    const e = await make('[^1]: See [@smith2020].');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    const paragraph = findDefParagraph(doc);
    expect(paragraph).not.toBeNull();
    if (!paragraph) return;

    // The definition is still exactly one paragraph, still starts with the
    // footnote_def atom followed by a text node beginning with one space.
    expect(doc.childCount).toBe(1);
    expect(childTypeNames(paragraph as Node)[0]).toBe('footnote_def');
    expect((paragraph as Node).child(1).type.name).toBe('text');
    expect((paragraph as Node).child(1).text?.startsWith(' ')).toBe(true);

    // The citation survives.
    expect(collectNodes(doc, 'citation')).toHaveLength(1);
    expect(collectNodes(doc, 'citation')[0].attrs.citekeys).toBe('smith2020');

    // Atoms contribute '' to textContent, so the paragraph's textContent is
    // exactly what the old flattening produced.
    expect((paragraph as Node).textContent).toBe(' See .');

    const saved = e.action(getMarkdown());
    expect(saved).toContain('[@smith2020]');

    // The real persistence path (see the header note): the app writes blocks to
    // the database through nodeToMarkdownFragment, NOT through getMarkdown().
    // It has an explicit `citation` case, so the citation survives here too.
    // Observed fragment: '[^1]: See [@smith2020].'
    const fragment = nodeToMarkdownFragment(paragraph as Node);
    expect(fragment).toContain('smith2020');
    expect(fragment).toContain('[@smith2020]');
  });

  it('keeps an annotation node inside a footnote definition, in the doc, in getMarkdown(), and in the database fragment', async () => {
    const e = await make('[^1]: See <!-- ::comment:: a note --> here.');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    const paragraph = findDefParagraph(doc);
    expect(paragraph).not.toBeNull();
    if (!paragraph) return;

    expect(collectNodes(doc, 'annotation')).toHaveLength(1);
    expect(collectNodes(doc, 'annotation')[0].attrs.text).toBe('a note');
    expect((paragraph as Node).textContent).toBe(' See  here.');

    const saved = e.action(getMarkdown());
    expect(saved).toContain('<!-- ::comment:: a note -->');

    // The real persistence path -- see the citation test above. It has an
    // explicit `annotation` case, so this survives too. Observed fragment:
    // '[^1]: See <!-- ::comment:: a note --> here.'
    const fragment = nodeToMarkdownFragment(paragraph as Node);
    expect(fragment).toContain('a note');
    expect(fragment).toContain('<!-- ::comment::');
  });

  it('keeps a citation and an annotation together inside one footnote definition', async () => {
    const e = await make('[^1]: See [@smith2020] <!-- ::comment:: check this --> here.');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    expect(collectNodes(doc, 'citation')).toHaveLength(1);
    expect(collectNodes(doc, 'annotation')).toHaveLength(1);

    const saved = e.action(getMarkdown());
    expect(saved).toContain('[@smith2020]');
    expect(saved).toContain('<!-- ::comment:: check this -->');

    // Both survive the database serializer together, in one fragment.
    // Observed: '[^1]: See [@smith2020] <!-- ::comment:: check this --> here.'
    const paragraph = findDefParagraph(doc);
    expect(paragraph).not.toBeNull();
    if (!paragraph) return;

    const fragment = nodeToMarkdownFragment(paragraph as Node);
    expect(fragment).toContain('smith2020');
    expect(fragment).toContain('<!-- ::comment::');
    expect(fragment).toContain('check this');
  });

  it('round-trips: serialize -> parse -> serialize is idempotent and both node types survive the second parse', async () => {
    const first = await make('[^1]: See [@smith2020] <!-- ::comment:: check this --> here.');
    const firstMarkdown = first.action(getMarkdown());

    // A genuinely fresh editor consuming the first editor's own output.
    const second = await make(firstMarkdown);
    const secondDoc = second.ctx.get(editorViewCtx).state.doc;

    expect(collectNodes(secondDoc, 'citation')).toHaveLength(1);
    expect(collectNodes(secondDoc, 'annotation')).toHaveLength(1);

    const secondMarkdown = second.action(getMarkdown());
    expect(secondMarkdown).toBe(firstMarkdown);
  });

  it('keeps the definition at exactly one paragraph when the source definition has two paragraphs', async () => {
    // GFM: a blank line indented inside the definition makes a second
    // paragraph inside the same footnoteDefinition. Today (and after the
    // fix) the definition collapses to exactly one paragraph block.
    const e = await make('[^1]: First para [@smith2020].\n\n    Second para.');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    const paragraphs = collectNodes(doc, 'paragraph');
    expect(paragraphs).toHaveLength(1);
    const paragraph = paragraphs[0];
    expect(paragraph.child(0).type.name).toBe('footnote_def');
    // Both paragraphs' content is present in the single collapsed paragraph.
    expect(paragraph.textContent).toContain('First para');
    expect(paragraph.textContent).toContain('Second para');
    expect(collectNodes(doc, 'citation')).toHaveLength(1);
  });

  it('renumberFootnotes changes the definition label and leaves the citation in place', async () => {
    const e = await make('[^1]: See [@smith2020].');
    setEditorInstance(e);

    const before = e.ctx.get(editorViewCtx).state.doc;
    expect(collectNodes(before, 'citation')).toHaveLength(1);

    renumberFootnotes({ '1': '2' });

    const after = e.ctx.get(editorViewCtx).state.doc;
    const paragraphs = collectNodes(after, 'paragraph');
    expect(paragraphs[0].child(0).type.name).toBe('footnote_def');
    expect(paragraphs[0].child(0).attrs.label).toBe('2');
    expect(collectNodes(after, 'citation')).toHaveLength(1);
    expect(collectNodes(after, 'citation')[0].attrs.citekeys).toBe('smith2020');
  });

  it('passes through emphasis and links in a definition instead of flattening them to plain text', async () => {
    // Wider than the two node types the bug names: the splice passes through
    // ALL of the definition paragraph's inline children, so emphasis/strong/
    // links/inline code survive too (previously flattened to plain text).
    const e = await make('[^1]: See *emphasised* and [a link](https://example.com) here.');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    // emphasis and link are ProseMirror MARKS, not node types, so they can
    // only be observed on the text nodes carrying them -- collectNodes() could
    // never see them.
    const markNames = new Set<string>();
    const linkHrefs: string[] = [];
    doc.descendants((node) => {
      for (const mark of node.marks) {
        markNames.add(mark.type.name);
        if (mark.type.name === 'link') linkHrefs.push(mark.attrs.href as string);
      }
      return true;
    });

    expect(markNames.has('emphasis')).toBe(true);
    expect(markNames.has('link')).toBe(true);
    expect(linkHrefs).toContain('https://example.com');

    const saved = e.action(getMarkdown());
    expect(saved).toContain('*emphasised*');
    expect(saved).toContain('[a link](https://example.com)');
  });

  it('keeps a plain (non-annotation) HTML comment as an html node in the doc, while the database serializer drops it', async () => {
    const e = await make('[^1]: See <!-- plain comment --> here.');
    const doc = e.ctx.get(editorViewCtx).state.doc;

    const paragraph = findDefParagraph(doc);
    expect(paragraph).not.toBeNull();
    if (!paragraph) return;

    // A real requirement of the fix: the plain comment's `html` node must
    // survive the footnote-definition splice as a node in the doc (before the
    // fix, the flattening removed it along with everything else non-text).
    expect(childTypeNames(paragraph as Node)).toEqual(['footnote_def', 'text', 'html', 'text']);

    // Milkdown's stock serializer keeps it...
    const saved = e.action(getMarkdown());
    expect(saved).toContain('plain comment');

    // ...but the DATABASE serializer drops it. nodeToMarkdownFragment's inline
    // dispatch has explicit cases for citation/annotation (and the other inline
    // atoms) but none for `html`, so an html child falls through to the generic
    // fallback, which pushes child.textContent -- and Milkdown's html node is
    // `atom: true` with its text in attrs.value, so that is ''. Observed
    // fragment: '[^1]: See  here.' (note the doubled space where the comment
    // used to be). So the "survives" claim above is scoped to getMarkdown()
    // ONLY; it does NOT hold for the path that writes blocks to the database.
    // Recorded, not required: a plain HTML comment is not a fix target (the fix
    // is about citation/annotation nodes) and this serializer gap is deferred.
    // This assertion pins today's behaviour so the two serializers' divergence
    // is visible rather than implied.
    const fragment = nodeToMarkdownFragment(paragraph as Node);
    expect(fragment).not.toContain('plain comment');
  });
});
