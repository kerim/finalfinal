// @vitest-environment jsdom
// Math equation parsing / serialization tests
// Uses a real Milkdown editor instance to verify the actual serializer path,
// including the 'html' node type used to avoid $ → \$ escaping.

import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { phase1CanClaim } from '../block-id-plugin';
import { mathPlugin } from '../math-plugin';

// ============================================================
// Real round-trip tests (live Milkdown editor in jsdom)
// These guard the 'html' node path that prevents $ → \$ escaping.
// ============================================================

describe('math round-trip via real Milkdown serializer', () => {
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
      .use(mathPlugin)
      .create();
    editor = e;
    return e;
  }

  it('inline $x^2$ round-trips unchanged', async () => {
    const e = await makeEditor('See $x^2$ for proof.');
    const result = e.action(getMarkdown());
    // The dollar signs must survive serialization intact
    expect(result).toContain('$x^2$');
    // Regression: must NOT be escaped to \$x^2\$
    expect(result).not.toContain('\\$x^2\\$');
    expect(result).not.toMatch(/\\\$[^$]*\\\$/);
  });

  it('display $$\\int_0^1 x\\,dx$$ round-trips unchanged', async () => {
    // remark-math parses display math only when $$ is on its own paragraph line
    const e = await makeEditor('$$\n\\int_0^1 x\\,dx\n$$');
    const result = e.action(getMarkdown());
    // Must preserve the $$ delimiters and the LaTeX body
    expect(result).toContain('$$');
    expect(result).toContain('\\int_0^1');
    // Regression: $$ must NOT become \$\$
    expect(result).not.toContain('\\$\\$');
  });

  it('inline dollar signs are NOT escaped to \\$ (proves html node path)', async () => {
    // This test would REGRESS if math_inline used a 'text' node type instead of 'html'.
    // A 'text' node triggers the standard markdown-it escaper, which turns $ into \$.
    // The 'html' node type is a raw passthrough — it cannot escape anything.
    const e = await makeEditor('$a + b = c$');
    const result = e.action(getMarkdown());
    // Must contain unescaped $, not \$
    expect(result).toMatch(/\$[^\\]/); // $ followed by a non-backslash char
    expect(result).not.toContain('\\$');
  });

  it('display dollar signs are NOT escaped to \\$\\$ (proves html node path)', async () => {
    // Same regression guard for math_display: if it used 'text', $$ → \$\$
    // Use block-level syntax (own line) so remark-math creates a math node
    const e = await makeEditor('$$\nE = mc^2\n$$');
    const result = e.action(getMarkdown());
    expect(result).toContain('$$');
    expect(result).not.toContain('\\$\\$');
  });
});

// ============================================================
// block-ID stability guard (structural assertion, pure-logic)
// ============================================================

describe('block-ID stability guard (structural assertion)', () => {
  it('math_display is included in BLOCK_TYPES and ATOMIC_BLOCK_TYPES', () => {
    // If math_display is NOT in these sets, block IDs will not be assigned
    // → silent data loss on next sync. Verified by importing phase1CanClaim
    // which uses ATOMIC_BLOCK_TYPES internally.

    // math_display should be atomic: a cross-type claim (e.g., paragraph→math_display)
    // must be rejected.
    const canClaim = phase1CanClaim(
      'math_display', // newType
      'paragraph', // existingType (different)
      'some-id', // existingId
      new Set(), // claimed (empty)
      false, // structureChanged (irrelevant on this path)
      'irrelevant-old-text', // oldText (placeholder, unread when structureChanged is false)
      'irrelevant-new-text' // newText (placeholder, unread when structureChanged is false)
    );
    // atomic types reject cross-type claims
    expect(canClaim).toBe(false);
  });

  it('same-type math_display claim is allowed', () => {
    const canClaim = phase1CanClaim(
      'math_display',
      'math_display',
      'some-id',
      new Set(),
      false,
      'irrelevant-old-text',
      'irrelevant-new-text'
    );
    expect(canClaim).toBe(true);
  });
});
