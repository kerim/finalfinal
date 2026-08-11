// Pre-parse normalization guarding against remark-math's "swallow to EOF"
// tokenizer behavior on malformed display-math fences.
//
// Root cause: remark-math's block-math tokenizer only recognizes a fence
// line that is EXACTLY `$$` (whitespace aside) as an opener/closer. A `$$`
// glued onto other text on the same line — e.g. text pasted from outside the
// app in the shape `$$x &= y \\` ... `\end{aligned}$$` — either fails to open
// a fence cleanly or, once one HAS opened, is never recognized as the
// closer. Parsing then swallows every line after it verbatim, including
// blank lines and any following paragraphs, all the way to the end of the
// string being parsed. This is a vendored-library property (remark-math /
// micromark-extension-math) — not something this app forks — so the fix
// operates one level up: rewrite the malformed shape into one the tokenizer
// already parses correctly, before the text ever reaches it.
//
// This is the mirror image of the fix in math-plugin.ts's toMarkdown/
// parseMarkdown: that fix stops the APP's own serializer from producing the
// glued shape; this one defends against the glued shape arriving from
// OUTSIDE the app (external paste, or any other caller of setContent()).

/**
 * Rewrites a glued `$$` display-math fence — open, close, or both — onto its
 * own line, so remark-math's tokenizer sees a well-formed fence instead of
 * swallowing everything after it to EOF.
 *
 * A fully self-contained one-liner (`$$latex$$`, both open AND close glued
 * on the SAME line, with nothing else on the line) is ALSO split onto three
 * lines (`$$` / latex / `$$`) when it holds exactly one `$$...$$` run.
 * remark-math's block-math tokenizer only recognizes a fence line that is
 * EXACTLY `$$` as an opener/closer — left glued, a one-liner like
 * `$$\begin{aligned}...\end{aligned}$$` is classified as INLINE math (a
 * 2-`$`-fenced code-span-style token), not display math, even though it's
 * the entire content of its paragraph and the app's own serializer would
 * always emit it as a display block. Splitting the fences onto their own
 * lines here makes it classify identically to that canonical multi-line
 * form. A line carrying MORE than one `$$...$$` run (e.g. `$$a$$ + $$b$$`)
 * is deliberately left untouched — remark-math already parses that
 * correctly as two independent inline-math spans, and merging them would
 * swallow the literal `$$` delimiters and the text between the runs into a
 * single, wrong LaTeX body.
 *
 * Skips content inside fenced code blocks (```), mirroring the same guard in
 * Swift's `RawBlockSplitter` (`BlockParser+Splitting.swift`), so `$$`-shaped
 * text shown as a literal example inside a code block is never rewritten.
 * Also skips any line indented 4 or more spaces, or by a single leading tab
 * — markdown's own threshold for an INDENTED code block — so `    $$x = y$$`
 * and `\t$$x = y$$` both stay literal code content instead of being
 * rewritten into a math fence.
 *
 * A line that both starts AND ends with `$$` while already inside an open
 * fence (i.e., not the very first line) is deliberately left as ordinary
 * fence content rather than treated as a close — mirroring the "prefix xor
 * suffix" rule used for the same shape on the Swift side.
 */
export function normalizeMathFences(text: string): string {
  const lines = text.split('\n');
  const out: string[] = [];
  let inCodeBlock = false;
  let awaitingClose = false;

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      out.push(line);
      continue;
    }
    if (inCodeBlock) {
      out.push(line);
      continue;
    }

    const hasOpenPrefix = trimmed.startsWith('$$');
    const hasCloseSuffix = trimmed.endsWith('$$');
    // Matches micromark's own math-flow "meta" state exactly: it bails (`nok`) the
    // instant it sees ANY further `$` character while scanning the rest of the opening
    // line, so a line only opens a real display-math fence when there is NO other `$`
    // anywhere after the leading `$$` — not merely "doesn't end with $$". Without this,
    // a line like `$$E = mc^2$$ is the famous equation.` (a legitimate embedded closing
    // `$$` followed by trailing prose) or `$$a + $b$ c` (two separate `$`-delimited
    // runs) gets misclassified as a glued opener and split into a genuinely unclosed
    // fence — corrupting input that micromark itself would have safely parsed as an
    // ordinary paragraph with inline math.
    const remainderAfterOpenPrefix = hasOpenPrefix ? trimmed.slice(2) : '';
    const isGluedOpener = hasOpenPrefix && !remainderAfterOpenPrefix.includes('$');
    // Markdown's own indented-code-block rule (4+ leading spaces, OR a
    // single leading tab) turns a line into literal INDENTED CODE BLOCK
    // content, not a paragraph — e.g. "    $$x = y$$" or "\t$$x = y$$" both
    // parse as code("$$x = y$$"), never as math. Content in that shape must
    // never be rewritten by this normalizer, mirroring the ``` fence skip
    // above but for the indentation-flavored "this is code, don't touch it"
    // case.
    const isIndentedCodeLine = /^(?: {4,}|\t)/.test(line);

    if (!awaitingClose) {
      const isSelfContainedOneLiner = hasOpenPrefix && hasCloseSuffix && trimmed.length > 4;
      // Safe to promote to the canonical multi-line display shape only when the line
      // holds exactly ONE $$...$$ run — i.e. no further "$$" appears between the
      // opening and closing fence. See the doc comment above for why a multi-run line
      // (e.g. "$$a$$ + $$b$$") must be left alone instead.
      const innerContent = isSelfContainedOneLiner ? trimmed.slice(2, -2) : '';
      const isSingleMathRun = isSelfContainedOneLiner && !innerContent.includes('$$');

      if (trimmed === '$$') {
        awaitingClose = true;
        out.push(line);
      } else if (isSingleMathRun && !isIndentedCodeLine) {
        // "$$latex$$" (the WHOLE line, nothing else) -> "$$" / "latex" / "$$"
        // Preserve the line's leading indentation/prefix (e.g. a list item's
        // continuation indent) on ALL THREE emitted lines, not just the
        // opener — otherwise the content and closer lines de-indent enough
        // to escape the list/blockquote context they were nested in.
        const idx = line.indexOf('$$');
        const closeIdx = line.lastIndexOf('$$');
        const prefix = line.slice(0, idx);
        out.push(line.slice(0, idx + 2));
        out.push(prefix + line.slice(idx + 2, closeIdx));
        out.push(prefix + line.slice(closeIdx));
      } else if (isSelfContainedOneLiner) {
        out.push(line);
      } else if (isGluedOpener && !isIndentedCodeLine) {
        // Glued open: "$$content" -> "$$" / "content"
        // Preserve the line's leading indentation/prefix (e.g. a list
        // item's continuation indent) on BOTH emitted lines, not just the
        // opener — mirroring the one-liner fix above — otherwise the
        // content line de-indents enough to escape the list/blockquote
        // context it was nested in.
        const idx = line.indexOf('$$');
        const prefix = line.slice(0, idx);
        out.push(line.slice(0, idx + 2));
        out.push(prefix + line.slice(idx + 2));
        awaitingClose = true;
      } else {
        out.push(line);
      }
      continue;
    }

    // Inside an open fence, looking for its close.
    if (trimmed === '$$') {
      awaitingClose = false;
      out.push(line);
    } else if (hasCloseSuffix && !hasOpenPrefix) {
      // Glued close: "content$$" -> "content" / "$$"
      // Preserve the line's leading indentation on the closer line too —
      // same reasoning as the glued-open fix above — otherwise the closer
      // de-indents enough to escape the list/blockquote context the
      // fenced content was nested in. Unlike the opener case, the `$$`
      // sits at the END of the line here, so the prefix must come from the
      // line's own leading whitespace rather than "everything before $$".
      const idx = line.lastIndexOf('$$');
      const prefix = line.match(/^[ \t]*/)![0];
      out.push(line.slice(0, idx));
      out.push(prefix + line.slice(idx));
      awaitingClose = false;
    } else {
      out.push(line);
    }
  }

  return out.join('\n');
}
