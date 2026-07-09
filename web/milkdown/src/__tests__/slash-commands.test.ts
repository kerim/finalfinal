// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { Schema } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { citationPlugin } from '../citation-plugin';
import { footnotePlugin, getFootnoteDefinitions, insertFootnoteWithDelete } from '../footnote-plugin';
import { sectionBreakPlugin } from '../section-break-plugin';
import { applyBreakCommand, applyHeadingCommand, computeSlashCmdStart } from '../slash-commands';

// Minimal schema: doc > paragraph > (citation atom | text). Mirrors the
// essential shape of the real citation node (inline, atom, leaf — no content)
// without pulling in the full Milkdown plugin machinery.
const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    text: { group: 'inline' },
    citation: {
      group: 'inline',
      inline: true,
      atom: true,
      selectable: true,
      attrs: { citekeys: { default: '' } },
      toDOM: () => ['span', { class: 'ff-citation' }, '[?]'],
    },
  },
  marks: {},
});

/** doc > paragraph > [citation atom, text(trailingText)] */
function docWithAtomThenText(trailingText: string) {
  const citation = schema.nodes.citation!.create({ citekeys: 'smith2023' });
  return schema.node('doc', null, [schema.node('paragraph', null, [citation, schema.text(trailingText)])]);
}

/** doc > paragraph > [text(trailingText)] — no atom */
function docTextOnly(trailingText: string) {
  return schema.node('doc', null, [schema.node('paragraph', null, [schema.text(trailingText)])]);
}

describe('computeSlashCmdStart', () => {
  it('finds the "/" correctly when a prior inline atom (citation) precedes the text — regression for the reported bug', () => {
    // Paragraph: [citation][ 'regulation"/cite' ], cursor placed right after "/cite".
    // Without the leafText fix, the atom contributed 0 characters to the scanned
    // string, so lastIndexOf('/') undercounted by 1 and cmdStart landed one
    // position too early — eating the trailing '"' when the slash text was deleted.
    const text = 'regulation"/cite';
    const doc = docWithAtomThenText(text);

    const lineStart = 1; // start of paragraph content
    const atomSize = 1; // atom/leaf nodes occupy exactly one document position
    const from = lineStart + atomSize + text.length; // cursor right after "/cite"
    const slashIndexInText = text.lastIndexOf('/');
    const expectedCmdStart = lineStart + atomSize + slashIndexInText;

    const cmdStart = computeSlashCmdStart(doc, from);

    expect(cmdStart).toBe(expectedCmdStart);
    // The position must land exactly on the "/", not one character earlier.
    expect(doc.textBetween(cmdStart, cmdStart + 1)).toBe('/');
    // The character immediately before it — the closing quote from "regulation\"" —
    // must be left untouched by the computed deletion boundary.
    expect(doc.textBetween(cmdStart - 1, cmdStart)).toBe('"');
  });

  it('control: with no prior atom, the same text still resolves the "/" correctly', () => {
    // Guards the common/simple path against regressions from the leafText change.
    const text = 'regulation"/cite';
    const doc = docTextOnly(text);

    const lineStart = 1;
    const from = lineStart + text.length;
    const slashIndexInText = text.lastIndexOf('/');
    const expectedCmdStart = lineStart + slashIndexInText;

    const cmdStart = computeSlashCmdStart(doc, from);

    expect(cmdStart).toBe(expectedCmdStart);
    expect(doc.textBetween(cmdStart, cmdStart + 1)).toBe('/');
    expect(doc.textBetween(cmdStart - 1, cmdStart)).toBe('"');
  });

  it('returns -1 when there is no "/" before the cursor', () => {
    const doc = docTextOnly('no slash here');
    const from = 1 + 'no slash here'.length;
    expect(computeSlashCmdStart(doc, from)).toBe(-1);
  });

  it('accounts for multiple prior atoms, each contributing exactly one position', () => {
    const citation = schema.nodes.citation!.create({ citekeys: 'a' });
    const text = 'x"/cite';
    const doc = schema.node('doc', null, [schema.node('paragraph', null, [citation, citation, schema.text(text)])]);

    const lineStart = 1;
    const atomsSize = 2; // two atoms, one position each
    const from = lineStart + atomsSize + text.length;
    const slashIndexInText = text.lastIndexOf('/');
    const expectedCmdStart = lineStart + atomsSize + slashIndexInText;

    const cmdStart = computeSlashCmdStart(doc, from);

    expect(cmdStart).toBe(expectedCmdStart);
    expect(doc.textBetween(cmdStart, cmdStart + 1)).toBe('/');
  });
});

// ----------------------------------------------------------------------------
// Regression: /footnote in a paragraph with a prior inline atom must not
// duplicate the footnote reference or its label — reported after manually
// verifying the computeSlashCmdStart fix's own recommended test scenario
// (a paragraph with a prior citation/footnote atom, then a different slash
// command). Uses a real Milkdown editor (footnotePlugin) so insertFootnoteWithDelete
// runs against real footnote_ref node types and real transaction/position
// machinery — the minimal fake Schema above can't provide footnoteRefNode.type(ctx).
//
// Note: this cannot reproduce the "[^1]: / [^1]:" duplicate *definition block*
// symptom the user saw, because insertFootnoteWithDelete never creates a
// footnote_def node or a "# Notes" block — those are synthesized entirely on
// the Swift side (FootnoteSyncService.swift) from the `label` this function
// posts via footnoteInserted, and pushed back into the editor as markdown.
// What this guards is the one thing this session's fix could plausibly have
// broken: that the web layer computes a correct, unique cmdStart/label and
// inserts exactly one footnote_ref when a prior atom precedes the command.
// ----------------------------------------------------------------------------
describe('insertFootnoteWithDelete — prior inline atom in the same paragraph', () => {
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
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(footnotePlugin)
      .create();
    editor = e;
    return e;
  }

  it('inserts exactly one new footnote_ref, with a unique label, when a prior footnote atom precedes it in the same paragraph', async () => {
    // Paragraph: [footnote_ref label=1] "some text /footnote" — mirrors the
    // reported repro: a prior inline atom, then a different slash command
    // typed later in the same paragraph.
    const e = await makeEditor('[^1] some text /footnote');
    const view = e.ctx.get(editorViewCtx);

    // Place the cursor at the end of the document (end of "/footnote").
    const endPos = view.state.doc.content.size;
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(endPos), -1)));

    const from = view.state.selection.from;
    const cmdStart = computeSlashCmdStart(view.state.doc, from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    const newLabel = insertFootnoteWithDelete(view, e, cmdStart, from);

    // Exactly one NEW footnote_ref was inserted (total two: the original + the new one).
    let refCount = 0;
    const labels: string[] = [];
    view.state.doc.descendants((node) => {
      if (node.type.name === 'footnote_ref') {
        refCount++;
        labels.push(node.attrs.label);
      }
    });
    expect(refCount).toBe(2);
    // Labels must be unique — no collision between the prior atom and the new one.
    expect(new Set(labels).size).toBe(2);
    expect(labels).toContain('1');
    expect(newLabel).not.toBeNull();
    expect(labels).toContain(newLabel);

    // The prior atom's text neighbor ("some text") must survive untouched —
    // this is the same character-eating failure mode the computeSlashCmdStart
    // fix addressed for /cite; footnote insertion must not regress it either.
    const markdown = e.action(getMarkdown());
    expect(markdown).toContain('some text');
    expect(markdown).not.toMatch(/text\[\^/); // the space before the new ref must survive

    // The JS-side footnote definitions registry (source of what gets posted to
    // Swift for the "# Notes" section) must have exactly one entry per label,
    // with no duplicate/collided key for the newly inserted footnote.
    const defs = getFootnoteDefinitions();
    const newLabelEntries = [...defs.keys()].filter((k) => k === newLabel);
    expect(newLabelEntries).toHaveLength(1);
  });
});

// ----------------------------------------------------------------------------
// Regression: /break used cursor position (`from`), not the "/" position
// (`cmdStart`), to decide "replace whole paragraph vs. delete-and-insert" —
// so "Some notes /break" with the cursor at paragraph end wrongly matched the
// whole-paragraph-replace branch and deleted "Some notes". These tests assert
// document STRUCTURE/ORDER (child count, node types, order), not just text
// containment, since the bug was about a whole paragraph disappearing.
// ----------------------------------------------------------------------------
describe('applyBreakCommand', () => {
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
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(sectionBreakPlugin)
      .create();
    editor = e;
    return e;
  }

  /** Position right after `cmdLabel` in a single-paragraph doc's markdown text. */
  function cmdEndPos(markdown: string, cmdLabel: string): number {
    return 1 + markdown.indexOf(cmdLabel) + cmdLabel.length;
  }

  it('content before only: "Some notes /break" -> paragraph "Some notes" then section break', async () => {
    const markdown = 'Some notes /break';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);

    // Cursor at the end of the document (end of "/break").
    const endPos = view.state.doc.content.size;
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(endPos), -1)));
    const from = view.state.selection.from;
    const cmdStart = computeSlashCmdStart(view.state.doc, from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    applyBreakCommand(view, e.ctx, cmdStart, from);

    const doc = view.state.doc;
    expect(doc.childCount).toBe(2);
    expect(doc.child(0).type.name).toBe('paragraph');
    expect(doc.child(0).textContent.trim()).toBe('Some notes');
    expect(doc.child(1).type.name).toBe('section_break');
  });

  it('content after only: "/break more notes" -> section break then paragraph "more notes"', async () => {
    const markdown = '/break more notes';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);

    // Cursor placed right after "/break" (not doc end).
    const from = cmdEndPos(markdown, '/break');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from)));
    const cmdStart = computeSlashCmdStart(view.state.doc, view.state.selection.from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    applyBreakCommand(view, e.ctx, cmdStart, view.state.selection.from);

    const doc = view.state.doc;
    expect(doc.childCount).toBe(2);
    expect(doc.child(0).type.name).toBe('section_break');
    expect(doc.child(1).type.name).toBe('paragraph');
    expect(doc.child(1).textContent.trim()).toBe('more notes');
  });

  it('content both sides: "Some notes /break here" -> paragraph "Some notes", section break, paragraph "here", in that order', async () => {
    const markdown = 'Some notes /break here';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);

    // Cursor placed right after "/break" (not doc end).
    const from = cmdEndPos(markdown, '/break');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from)));
    const cmdStart = computeSlashCmdStart(view.state.doc, view.state.selection.from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    applyBreakCommand(view, e.ctx, cmdStart, view.state.selection.from);

    const doc = view.state.doc;
    expect(doc.childCount).toBe(3);
    expect(doc.child(0).type.name).toBe('paragraph');
    expect(doc.child(0).textContent.trim()).toBe('Some notes');
    expect(doc.child(1).type.name).toBe('section_break');
    expect(doc.child(2).type.name).toBe('paragraph');
    expect(doc.child(2).textContent.trim()).toBe('here');
  });

  it('control: bare "/break" still replaces the whole paragraph with a single section break', async () => {
    const markdown = '/break';
    const e = await makeEditor(markdown);
    const view = e.ctx.get(editorViewCtx);

    const endPos = view.state.doc.content.size;
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(endPos), -1)));
    const from = view.state.selection.from;
    const cmdStart = computeSlashCmdStart(view.state.doc, from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    applyBreakCommand(view, e.ctx, cmdStart, from);

    const doc = view.state.doc;
    expect(doc.childCount).toBe(1);
    expect(doc.child(0).type.name).toBe('section_break');
  });
});

// ----------------------------------------------------------------------------
// Regression: /h1-/h6 rebuilt the heading node from a plain string
// (schema.text(combinedText)), which can never carry atom nodes (citations,
// footnotes, etc.) — so any atom in the source paragraph was silently
// discarded. applyHeadingCommand uses setBlockType instead, which changes
// only the node type/attrs and preserves all child content.
// ----------------------------------------------------------------------------
describe('applyHeadingCommand', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, '');
      })
      .use(commonmark)
      .use(gfm)
      .use(citationPlugin)
      .create();
    editor = e;
    return e;
  }

  it('preserves a citation atom when converting a paragraph to a heading', async () => {
    const e = await makeEditor();
    const view = e.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    // Build doc > paragraph > [citation atom, text(" some notes /h1")] directly
    // via the real schema, then replace the editor's initial (empty) content.
    const trailingText = ' some notes /h1';
    const citation = schema.nodes.citation!.create({ citekeys: 'smith2023' });
    const paragraph = schema.nodes.paragraph!.create(null, [citation, schema.text(trailingText)]);
    const replaceTr = view.state.tr.replaceWith(0, view.state.doc.content.size, paragraph);
    view.dispatch(replaceTr);

    // cmdStart/from computed the same way the citation-atom regression tests
    // for computeSlashCmdStart do: atom occupies exactly one position.
    const lineStart = 1;
    const atomSize = 1;
    const from = lineStart + atomSize + trailingText.length;
    const cmdStart = computeSlashCmdStart(view.state.doc, from);
    expect(cmdStart).toBeGreaterThanOrEqual(0);

    applyHeadingCommand(view, cmdStart, from, 1);

    const doc = view.state.doc;
    expect(doc.childCount).toBe(1);
    const heading = doc.firstChild!;
    expect(heading.type.name).toBe('heading');
    expect(heading.attrs.level).toBe(1);

    // The citation atom must still be the first inline child, with its attrs intact.
    const firstInline = heading.firstChild!;
    expect(firstInline).toBeDefined();
    expect(firstInline!.type.name).toBe('citation');
    expect(firstInline!.attrs.citekeys).toBe('smith2023');

    // The remaining text must still be present.
    let combinedText = '';
    heading.descendants((node) => {
      if (node.isText) combinedText += node.text;
    });
    expect(combinedText).toContain('some notes');
  });
});
