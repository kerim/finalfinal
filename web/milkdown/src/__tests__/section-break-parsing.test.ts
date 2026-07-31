// @vitest-environment jsdom
// Section-break marker parsing tests.
//
// Regression coverage for a data-loss bug: section-break-plugin.ts's remark
// plugin originally converted ANY mdast 'html' node matching
// '<!-- ::break:: -->' into a section_break node (group: 'block'), with no
// check that the node was actually in block position. When the marker
// appears mid-paragraph (e.g. "...prose, <!-- ::break:: --> more prose...")
// CommonMark parses it as an INLINE html node nested inside the paragraph's
// own children — converting that to a block-only node broke the paragraph's
// ProseMirror content model, and ParserState.closeNode() silently dropped
// the WHOLE paragraph (all the real prose on both sides of the marker, not
// just the marker itself).
//
// The fix's user-decided behavior (2026-07-31): a mid-paragraph marker must
// split the paragraph exactly as if the user had placed their cursor there
// and typed the /break slash command — a real section_break between two
// resulting paragraphs, dropping either side if it has no content, mirroring
// applyBreakCommand()'s own four branches (see slash-commands.ts).
//
// Uses a real Milkdown Editor instance (not just the isolated regex/AST
// logic) because the failure only manifests when the full parse pipeline
// (remark -> mdast -> ProseMirror doc) actually tries to build the node.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { sectionBreakPlugin } from '../section-break-plugin';

describe('section-break marker parsing (real Milkdown editor)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    // sectionBreakPlugin must be registered BEFORE commonmark/gfm, matching
    // main.ts's real plugin order ("sectionBreak/annotation must be before
    // commonmark to intercept HTML comments before they get filtered out").
    // Registering it after commonmark (as some other tests in this codebase
    // do, since they insert section breaks programmatically and never
    // re-parse the raw marker text) would let commonmark's own
    // remarkHtmlTransformer pre-wrap the block-level html node into a
    // paragraph first, changing what our plugin's block-position guard sees.
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(sectionBreakPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e;
  }

  it('marker mid-paragraph splits it in two around a real section break, exactly like typing /break there (bug repro + user-decided fix)', async () => {
    const markdown =
      "FINAL FINAL works fine out-of-the-box, <!-- ::break:: --> but there are a couple of features I'd like to add.";

    // Must not throw during parse (this is what silently dropped the paragraph before the first version of the fix).
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    // Split into paragraph / section_break / paragraph - matching applyBreakCommand's
    // "content on both sides" branch exactly, not left as one inert paragraph.
    expect(doc.childCount).toBe(3);
    expect(doc.child(0).type.name).toBe('paragraph');
    expect(doc.child(0).textContent).toBe('FINAL FINAL works fine out-of-the-box,');
    expect(doc.child(1).type.name).toBe('section_break');
    expect(doc.child(2).type.name).toBe('paragraph');
    expect(doc.child(2).textContent).toBe("but there are a couple of features I'd like to add.");
  });

  it('marker mid-paragraph does not leave an &#x20; escaped-space artifact in the saved markdown (regression guard)', async () => {
    // The whitespace immediately touching the marker on either side is
    // separator, not content, and must be trimmed rather than kept verbatim
    // in the split paragraphs. A kept leading/trailing space on a paragraph
    // isn't syntactically significant in markdown, so a correct serializer
    // has to escape it as &#x20; to survive a round-trip - which then shows
    // up as ugly, literal, editable text in the user's saved document. This
    // pins that the fix trims the separator whitespace instead of hitting
    // that escape at all.
    const markdown =
      "FINAL FINAL works fine out-of-the-box, <!-- ::break:: --> but there are a couple of features I'd like to add.";
    const e = await makeEditor(markdown);
    const saved = e.action(getMarkdown());

    expect(saved).not.toContain('&#x20;');
    expect(saved).toContain(
      'FINAL FINAL works fine out-of-the-box,\n\n<!-- ::break:: -->\n\nbut there are a couple of features'
    );
  });

  it('marker mid-paragraph with only leading content drops the empty trailing paragraph (applyBreakCommand "only before" branch)', async () => {
    const markdown = 'FINAL FINAL works fine out-of-the-box, <!-- ::break:: -->';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    expect(doc.childCount).toBe(2);
    expect(doc.child(0).type.name).toBe('paragraph');
    expect(doc.child(0).textContent).toBe('FINAL FINAL works fine out-of-the-box,');
    expect(doc.child(1).type.name).toBe('section_break');
  });

  // Note: there is no markdown-text equivalent of applyBreakCommand's "only
  // after" branch (marker with nothing before it, but real content after,
  // while still being genuinely INLINE). CommonMark's HTML block type-2 rule
  // means a line that STARTS with '<!--' is always block-level (and can even
  // interrupt an in-progress paragraph) - the only way this plugin ever sees
  // the marker as an inline mdast node is when something else precedes it on
  // the same physical line, which means "before" is never empty in a
  // genuinely inline match. splitParagraphAtMarker's hasAfter-only branch
  // exists for symmetry with applyBreakCommand's four cases and is exercised
  // indirectly by every other test's hasBefore/hasAfter combination, but this
  // specific shape isn't independently reachable via markdown text alone.

  it('marker on its own line directly above a paragraph (no blank line) still works (regression guard)', async () => {
    const markdown = '<!-- ::break:: -->\nSecond section text.';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    expect(doc.childCount).toBe(2);
    expect(doc.child(0).type.name).toBe('section_break');
    expect(doc.child(1).type.name).toBe('paragraph');
    expect(doc.child(1).textContent).toBe('Second section text.');
  });

  it('marker alone on its own line still converts to a section break (baseline case)', async () => {
    const markdown = '<!-- ::break:: -->';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    expect(doc.childCount).toBe(1);
    expect(doc.child(0).type.name).toBe('section_break');
  });

  it('marker on its own line inside a footnote definition still works (regression guard for footnoteDefinition block-container gap)', async () => {
    // gfm's own footnote parsing produces an mdast 'footnoteDefinition' node
    // with content: 'block+' in the ProseMirror schema - a legitimate block
    // container this plugin's own remark pass runs BEFORE main.ts's
    // footnotePlugin converts it into something else (sectionBreakPlugin is
    // registered before footnotePlugin - see main.ts). Omitting
    // 'footnoteDefinition' from BLOCK_HTML_CONTAINER_TYPES reproduces the
    // exact same "Cannot create node for footnote_definition" failure this
    // whole fix exists to prevent, just one container type over - confirmed
    // during review.
    const markdown = '[^1]: Footnote body here.\n\n    <!-- ::break:: -->\n\n    More footnote prose.';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    let footnoteDef: ReturnType<typeof doc.child> | null = null;
    doc.descendants((node) => {
      if (node.type.name === 'footnote_definition') footnoteDef = node;
    });
    expect(footnoteDef).not.toBeNull();
    if (!footnoteDef) return;

    expect((footnoteDef as any).childCount).toBe(3);
    expect((footnoteDef as any).child(0).type.name).toBe('paragraph');
    expect((footnoteDef as any).child(0).textContent).toContain('Footnote body here.');
    expect((footnoteDef as any).child(1).type.name).toBe('section_break');
    expect((footnoteDef as any).child(2).type.name).toBe('paragraph');
    expect((footnoteDef as any).child(2).textContent).toContain('More footnote prose.');
  });

  it('marker between two paragraphs (blank lines on both sides) still works', async () => {
    const markdown = 'First section text.\n\n<!-- ::break:: -->\n\nSecond section text.';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);
    const doc = view.state.doc;

    expect(doc.childCount).toBe(3);
    expect(doc.child(0).type.name).toBe('paragraph');
    expect(doc.child(0).textContent).toBe('First section text.');
    expect(doc.child(1).type.name).toBe('section_break');
    expect(doc.child(2).type.name).toBe('paragraph');
    expect(doc.child(2).textContent).toBe('Second section text.');
  });
});
