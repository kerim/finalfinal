// @vitest-environment jsdom
// The boundary-garble regression tests below (describe block at the bottom of
// this file) drive a real Milkdown Editor (commonmark + gfm + annotationPlugin),
// not hand-written strings matched against the bare regex — mirrors
// annotation-collapsed-click.test.ts's approach for its own subsystem. That's
// deliberate: the bug they pin only reproduces once real markdown goes through
// remark's HTML-block parsing (see annotation-plugin.ts's repair pass), which
// a standalone `.match()` call against annotationRegex can't exercise.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { annotationPlugin, annotationRegex, createAnnotationMarkdown, taskCheckboxRegex } from '../annotation-plugin';

describe('annotationRegex', () => {
  it('matches task annotation with unchecked checkbox', () => {
    const input = '<!-- ::task:: [ ] Review introduction -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
    expect(match![2]).toBe('[ ] Review introduction');
  });

  it('matches task annotation with checked checkbox', () => {
    const input = '<!-- ::task:: [x] Done item -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
    expect(match![2]).toBe('[x] Done item');
  });

  it('matches comment annotation', () => {
    const input = '<!-- ::comment:: Needs expanded discussion -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('comment');
    expect(match![2]).toBe('Needs expanded discussion');
  });

  it('matches reference annotation', () => {
    const input = '<!-- ::reference:: See also Smith 2023 -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('reference');
    expect(match![2]).toBe('See also Smith 2023');
  });

  it('matches annotation with empty content', () => {
    const input = '<!-- ::comment:: -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('comment');
    expect(match![2]).toBe('');
  });

  it('does not match regular HTML comments', () => {
    const input = '<!-- Just a regular comment -->';
    const match = input.match(annotationRegex);
    expect(match).toBeNull();
  });

  it('does not match malformed annotations', () => {
    const input = '<!-- ::notclosed text -->';
    const match = input.match(annotationRegex);
    expect(match).toBeNull();
  });

  it('handles extra whitespace', () => {
    const input = '<!--  ::task::  [ ] Spacey  -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
  });
});

describe('taskCheckboxRegex', () => {
  it('matches unchecked checkbox [ ]', () => {
    const match = '[ ] Review this'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe(' ');
    expect(match![2]).toBe('Review this');
  });

  it('matches checked checkbox [x]', () => {
    const match = '[x] Done'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('x');
    expect(match![2]).toBe('Done');
  });

  it('matches uppercase [X]', () => {
    const match = '[X] Also done'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('X');
  });

  it('does not match non-checkbox text', () => {
    const match = 'Just some text'.match(taskCheckboxRegex);
    expect(match).toBeNull();
  });
});

describe('createAnnotationMarkdown', () => {
  it('creates task markdown with empty checkbox', () => {
    const result = createAnnotationMarkdown('task', 'Do something');
    expect(result).toBe('<!-- ::task:: [ ] Do something -->');
  });

  it('creates comment markdown', () => {
    const result = createAnnotationMarkdown('comment', 'A note');
    expect(result).toBe('<!-- ::comment:: A note -->');
  });

  it('creates reference markdown', () => {
    const result = createAnnotationMarkdown('reference', 'See paper');
    expect(result).toBe('<!-- ::reference:: See paper -->');
  });

  it('creates task with empty text', () => {
    const result = createAnnotationMarkdown('task');
    expect(result).toBe('<!-- ::task:: [ ]  -->');
  });
});

// ============================================================
// Boundary-garble regression tests (real remark/unified pipeline)
//
// Root cause: CommonMark's HTML-block rule (type 2, `<!-- -->`) ends AT the
// line containing the closing '-->' — not at the next blank line. So a line
// like `<!-- ::task:: [ ] a --> Some prose. <!-- ::task:: [ ] b -->` parses
// as ONE mdast 'html' node whose value is the ENTIRE line: leading comment,
// visible prose, and trailing comment together. annotation-plugin.ts's old
// code only recognized a node as an annotation when its WHOLE value matched
// `^<!--...-->$`, so that whole line — prose and all — was swallowed as the
// text of one giant, uneditable annotation atom.
//
// These tests parse real markdown through a live Milkdown Editor (not just
// `.match()` against hand-written strings) so they actually exercise
// annotation-plugin.ts's repair pass, not just the underlying regex.
// ============================================================
describe('leading/trailing annotation boundary garble (real editor pipeline)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // annotationPlugin MUST be registered before commonmark/gfm to intercept
      // the `<!-- ::type:: ... -->` HTML comments — mirrors main.ts's ordering.
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  function getMarkdownOutput(): string {
    if (!editor) throw new Error('editor not created');
    return editor.action(getMarkdown());
  }

  /** Flatten a paragraph's direct children into a simple, assertable shape. */
  function paragraphParts(view: EditorView): Array<{ type: string; text?: string; attrs?: any }> {
    const doc = view.state.doc;
    expect(doc.childCount).toBe(1);
    const paragraph = doc.firstChild!;
    expect(paragraph.type.name).toBe('paragraph');

    const parts: Array<{ type: string; text?: string; attrs?: any }> = [];
    paragraph.forEach((child) => {
      parts.push({
        type: child.type.name,
        text: child.isText ? (child.text ?? '') : undefined,
        attrs: child.isText ? undefined : child.attrs,
      });
    });
    return parts;
  }

  it('(a) leading AND trailing annotation around prose render as three separate pieces, not one garbled atom', async () => {
    const view = await makeEditor(
      '<!-- ::task:: [ ] re-write this paragraph later --> This operational mechanism is central to the argument. <!-- ::task:: [ ] cite -->'
    );
    const parts = paragraphParts(view);

    // Must NOT collapse to a single atom: leading annotation, prose, trailing annotation.
    expect(parts.length).toBeGreaterThan(1);

    const annotations = parts.filter((p) => p.type === 'annotation');
    expect(annotations).toHaveLength(2);

    expect(annotations[0].attrs.type).toBe('task');
    expect(annotations[0].attrs.isCompleted).toBe(false);
    expect(annotations[0].attrs.text).toBe('re-write this paragraph later');

    expect(annotations[1].attrs.type).toBe('task');
    expect(annotations[1].attrs.text).toBe('cite');

    // Neither annotation's text may contain leftover raw markup — that's
    // exactly what the garble looked like before the fix.
    for (const a of annotations) {
      expect(a.attrs.text).not.toContain('-->');
      expect(a.attrs.text).not.toContain('<!--');
    }

    // The prose between them must survive as real, editable text content.
    const proseText = parts
      .filter((p) => p.type === 'text')
      .map((p) => p.text)
      .join('');
    expect(proseText).toContain('This operational mechanism is central to the argument.');
  });

  it('(b) leading-only annotation (no trailing one) still separates from the prose that follows it', async () => {
    const view = await makeEditor('<!-- ::comment:: check this claim --> The second paragraph continues here.');
    const parts = paragraphParts(view);

    expect(parts.length).toBeGreaterThan(1);

    const annotations = parts.filter((p) => p.type === 'annotation');
    expect(annotations).toHaveLength(1);
    expect(annotations[0].attrs.type).toBe('comment');
    expect(annotations[0].attrs.text).toBe('check this claim');
    expect(annotations[0].attrs.text).not.toContain('-->');

    const proseText = parts
      .filter((p) => p.type === 'text')
      .map((p) => p.text)
      .join('');
    expect(proseText).toContain('The second paragraph continues here.');
    // No leftover raw comment markup leaking into the visible prose.
    expect(proseText).not.toContain('<!--');
    expect(proseText).not.toContain('-->');
  });

  it('(c) whitespace after a peeled annotation survives a markdown round-trip (not welded to the prose)', async () => {
    await makeEditor(
      '<!-- ::task:: [ ] re-write this paragraph later --> This operational mechanism is central to the argument. <!-- ::task:: [ ] cite -->'
    );
    const md = getMarkdownOutput();

    // The space right after the leading annotation's '-->' must be preserved —
    // dropping it welds the annotation and prose together on serialization
    // (`-->This operational...`), which is exactly the whitespace bug this pins.
    expect(md).not.toContain('-->This operational');
    expect(md).toMatch(/-->\s+This operational mechanism is central to the argument\./);
  });

  it('(d) two consecutive leading annotations followed by prose are BOTH extracted (guards against a single-peel fix)', async () => {
    const view = await makeEditor('<!-- ::comment:: a --> <!-- ::task:: [ ] b --> prose continues here.');
    const parts = paragraphParts(view);

    const annotations = parts.filter((p) => p.type === 'annotation');
    // A fix that only peels ONE leading annotation would leave the second
    // one embedded (garbled) in either the first annotation's text or the
    // following prose — this must come back as exactly two clean annotations.
    expect(annotations).toHaveLength(2);
    expect(annotations[0].attrs.type).toBe('comment');
    expect(annotations[0].attrs.text).toBe('a');
    expect(annotations[1].attrs.type).toBe('task');
    expect(annotations[1].attrs.text).toBe('b');

    for (const a of annotations) {
      expect(a.attrs.text).not.toContain('-->');
      expect(a.attrs.text).not.toContain('<!--');
      expect(a.attrs.text).not.toContain('::task::');
      expect(a.attrs.text).not.toContain('::comment::');
    }

    const proseText = parts
      .filter((p) => p.type === 'text')
      .map((p) => p.text)
      .join('');
    expect(proseText).toContain('prose continues here.');
    expect(proseText).not.toContain('<!--');
  });

  it('regression guard: a standalone annotation (whole line, nothing else) still renders exactly as before', async () => {
    const view = await makeEditor('<!-- ::task:: [ ] standalone task -->');
    const parts = paragraphParts(view);

    expect(parts).toHaveLength(1);
    expect(parts[0].type).toBe('annotation');
    expect(parts[0].attrs.type).toBe('task');
    expect(parts[0].attrs.text).toBe('standalone task');
  });

  it('(e) emphasis/strong markers inside the reparsed remainder are not corrupted on save', async () => {
    await makeEditor('<!-- ::comment:: x --> **bold** tail');
    const md = getMarkdownOutput();

    // Before the position-rebase fix, milkdown's built-in remarkMarker
    // transformer read `file.value.charAt(node.position.start.offset)`
    // against the WHOLE document using an offset that was only valid
    // relative to the re-parsed REMAINDER substring, so it recovered the
    // wrong marker character. Measured on the unfixed code: this exact
    // input saved as `<!-- ::comment:: x --> <<bold<< tail`.
    expect(md).not.toContain('<<bold<<');
    expect(md).toMatch(/\*\*bold\*\*/);
  });

  it('(f) emphasis/strong stays stable across a DOUBLE round-trip (a single round-trip would not catch escalating corruption)', async () => {
    await makeEditor('<!-- ::comment:: x --> **bold** tail');
    const firstRoundtrip = getMarkdownOutput();
    expect(firstRoundtrip).toMatch(/\*\*bold\*\*/);

    // Feed round 1's saved markdown back through a fresh editor and save
    // again. On the unfixed code, round 1 already corrupts `**bold**` into
    // `<<bold<<`, and round 2 corrupts it FURTHER (into `<\<bold<<`) because
    // the bad `<<`/`<` characters shift the offsets again -- a single
    // round-trip alone would look "done" while still hiding that escalation.
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    await makeEditor(firstRoundtrip);
    const secondRoundtrip = getMarkdownOutput();

    expect(secondRoundtrip).toBe(firstRoundtrip);
    expect(secondRoundtrip).toMatch(/\*\*bold\*\*/);
    expect(secondRoundtrip).not.toContain('<<bold<<');
  });

  it('(g) a remainder that reparses as a non-paragraph block (heading) leaves the line at least as safe as before the repair pass existed', async () => {
    // `# Heading with **bold** and <!-- ::break:: -->` parses standalone as
    // a HEADING, not a paragraph -- exactly the shape must-fix 2 covers.
    // The repair pass must bail out of touching this html node entirely
    // rather than reaching for a lossy text/stringify fallback, which would
    // escape both the emphasis markers AND the second HTML-comment-like
    // marker into literal backslash-escaped text.
    const input = '<!-- ::comment:: a --> # Heading with **bold** and <!-- ::break:: -->';
    await makeEditor(input);
    const md = getMarkdownOutput();

    // Must NOT have escaped the emphasis markers into literal asterisks.
    expect(md).not.toContain('\\*\\*bold\\*\\*');
    // Must NOT have escaped the second HTML-comment-like marker -- this is
    // the "destroys a working section-break marker" failure mode from the
    // must-fix description.
    expect(md).not.toContain('\\<!-- ::break:: -->');
    expect(md).toContain('<!-- ::break:: -->');

    // Round-trips byte-for-byte (aside from getMarkdown()'s own trailing
    // newline), same as the pre-repair-pass behavior for this shape
    // (visually still one garbled annotation, but nothing lost).
    expect(md.trimEnd()).toBe(input);
  });
});

// ============================================================
// Indented leading annotation (must-fix 3): CommonMark's HTML-block rule
// tolerates up to 3 leading spaces of indentation (4+ spaces makes it
// indented code instead) -- a real leading annotation can legally sit at
// 0-3 spaces and still land as one root-level 'html' node. Before
// must-fix 3, splitLeadingAnnotations's matching was anchored `^<!--` with
// no whitespace tolerance, so an indented leading annotation reproduced the
// ORIGINAL reported whole-line garble completely unfixed.
// ============================================================
describe('indented leading annotation (real editor pipeline)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  function paragraphParts(view: EditorView): Array<{ type: string; text?: string; attrs?: any }> {
    const doc = view.state.doc;
    expect(doc.childCount).toBe(1);
    const paragraph = doc.firstChild!;
    expect(paragraph.type.name).toBe('paragraph');

    const parts: Array<{ type: string; text?: string; attrs?: any }> = [];
    paragraph.forEach((child) => {
      parts.push({
        type: child.type.name,
        text: child.isText ? (child.text ?? '') : undefined,
        attrs: child.isText ? undefined : child.attrs,
      });
    });
    return parts;
  }

  it('3 leading spaces before a leading+trailing annotation pair still separates cleanly (still a legal CommonMark HTML block)', async () => {
    const view = await makeEditor('   <!-- ::task:: [ ] a --> prose <!-- ::task:: [ ] b -->');
    const parts = paragraphParts(view);

    const annotations = parts.filter((p) => p.type === 'annotation');
    expect(annotations).toHaveLength(2);
    expect(annotations[0].attrs.type).toBe('task');
    expect(annotations[0].attrs.text).toBe('a');
    expect(annotations[1].attrs.type).toBe('task');
    expect(annotations[1].attrs.text).toBe('b');

    for (const a of annotations) {
      expect(a.attrs.text).not.toContain('-->');
      expect(a.attrs.text).not.toContain('<!--');
    }

    const proseText = parts
      .filter((p) => p.type === 'text')
      .map((p) => p.text)
      .join('');
    expect(proseText).toContain('prose');
    expect(proseText).not.toContain('<!--');
  });

  it('1 leading space before a single leading annotation still separates from the prose that follows it', async () => {
    const view = await makeEditor(' <!-- ::comment:: check this --> The prose continues.');
    const parts = paragraphParts(view);

    const annotations = parts.filter((p) => p.type === 'annotation');
    expect(annotations).toHaveLength(1);
    expect(annotations[0].attrs.type).toBe('comment');
    expect(annotations[0].attrs.text).toBe('check this');

    const proseText = parts
      .filter((p) => p.type === 'text')
      .map((p) => p.text)
      .join('');
    expect(proseText).toContain('The prose continues.');
    expect(proseText).not.toContain('<!--');
  });
});
