// Regression tripwire for the "word wrap breaks lines at roughly half the page
// width while actively editing" bug.
//
// Root cause: `.milkdown p, .ProseMirror p` had `text-wrap: pretty`, which
// makes WebKit optimize line breaks across the WHOLE paragraph to avoid a
// short orphan last line. For a paragraph that has JUST wrapped onto a second
// line, WebKit only has that one break to work with, so it was observed in
// WebKit as of 2026-07 to render as two roughly half-width lines instead of
// filling the first line greedily -- this looked like wrapping far too early,
// and "self-corrected" once the paragraph grew long enough for the optimizer
// to have more slack to distribute. Confirmed in real WebKit (both the early
// break and the self-correction) before removing the property; see
// milkdown/src/styles.css for the full explanation left in place of the
// removed declaration.
//
// This test is a TRIPWIRE, not a real wrapping test: it only pins the CSS
// source so a future edit can't silently reintroduce `pretty` line-breaking
// on paragraphs. It intentionally does NOT attempt to assert on actual
// rendered line breaks -- jsdom (this suite's environment) has no real layout
// engine and cannot verify actual wrapping; that limitation is already
// documented by this project's other tests (e.g.
// annotation-edit-popup-width.test.ts, hover-tooltip.test.ts). Verifying the
// real wrapping behavior requires real WebKit, which is what Step 1 of this
// fix did manually, not something a jsdom unit test can do.
//
// Checks three things per CSS source file (see CSS_FILES below):
//
// 1. CSS comments are stripped before either assertion runs. Matching against
//    raw file content (including comments) let this very tripwire pass even
//    with the real declaration deleted, because the match landed on the
//    explanatory prose in this file's own header comment instead of live CSS.
// 2. The "pretty" check is a regex tied specifically to the `text-wrap` and
//    `text-wrap-style` properties (not a bare substring match for the word
//    "pretty" anywhere in the file), and it catches the longhand
//    (`text-wrap-style: pretty`) and shorthand (`text-wrap: wrap pretty`)
//    respellings, not just the exact original spelling.
// 3. All CSS source files that end up governing paragraph/heading text in
//    either editor are checked, not just milkdown/src/styles.css -- both
//    milkdown/src/styles.css and codemirror/src/styles.css `@import` the
//    shared web/shared/typography.css, and `text-wrap` is an inherited
//    property, so adding `text-wrap: pretty` to a shared selector there would
//    reproduce the bug while a single-file tripwire stayed green.
//
// Deliberately untouched and out of scope for this fix: `text-wrap: balance`
// on headings (h1-h6) in milkdown/src/styles.css. Whether headings have the
// same underlying wrapping issue as paragraphs did has not been investigated
// -- this tripwire does not assert anything about why leaving it is safe, it
// only confirms the declaration is still present so it isn't accidentally
// dropped as a side effect of some future edit.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Every CSS source file that can affect paragraph/heading text-wrap in either
// editor: the two editor stylesheets plus the shared typography stylesheet
// both of them `@import`.
const CSS_FILES: Record<string, string> = {
  'milkdown/src/styles.css': join(__dirname, '..', 'styles.css'),
  'shared/typography.css': join(__dirname, '..', '..', '..', 'shared', 'typography.css'),
  'codemirror/src/styles.css': join(__dirname, '..', '..', '..', 'codemirror', 'src', 'styles.css'),
};

/** Strip `/* ... *\/` CSS comments so matches can't land on explanatory prose. */
function stripCssComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, '');
}

/**
 * Find `text-wrap` / `text-wrap-style` declarations whose value includes
 * `pretty` as a token -- catches `text-wrap: pretty`, the longhand
 * `text-wrap-style: pretty`, and the shorthand `text-wrap: wrap pretty` (or
 * `pretty wrap`), without false-positiving on the word "pretty" appearing
 * unrelated to either property.
 */
function findPrettyTextWrapDeclarations(css: string): string[] {
  const declarationPattern = /\btext-wrap(-style)?\s*:\s*([^;{}]+)/gi;
  const matches: string[] = [];
  let match: RegExpExecArray | null;
  while ((match = declarationPattern.exec(css)) !== null) {
    const value = match[2];
    if (/\bpretty\b/i.test(value)) {
      matches.push(match[0].trim());
    }
  }
  return matches;
}

describe('paragraph text-wrap regression tripwire', () => {
  for (const [label, path] of Object.entries(CSS_FILES)) {
    it(`does not reintroduce pretty text-wrapping in ${label}`, () => {
      const css = stripCssComments(readFileSync(path, 'utf-8'));
      const prettyDeclarations = findPrettyTextWrapDeclarations(css);
      expect(prettyDeclarations).toEqual([]);
    });
  }

  it('leaves text-wrap: balance on headings alone in milkdown/src/styles.css', () => {
    const css = stripCssComments(readFileSync(CSS_FILES['milkdown/src/styles.css'], 'utf-8'));
    expect(css).toContain('text-wrap: balance');
  });
});
