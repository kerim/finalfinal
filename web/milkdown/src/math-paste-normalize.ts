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
 * on the SAME line) is left untouched: remark-math already parses that shape
 * safely today (as inline math, not a runaway block) — there is nothing to
 * repair.
 *
 * Skips content inside fenced code blocks (```), mirroring the same guard in
 * Swift's `RawBlockSplitter` (`BlockParser+Splitting.swift`), so `$$`-shaped
 * text shown as a literal example inside a code block is never rewritten.
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

    if (!awaitingClose) {
      const isSelfContainedOneLiner = hasOpenPrefix && hasCloseSuffix && trimmed.length > 4;
      if (trimmed === '$$') {
        awaitingClose = true;
        out.push(line);
      } else if (isSelfContainedOneLiner) {
        out.push(line);
      } else if (isGluedOpener) {
        // Glued open: "$$content" -> "$$" / "content"
        const idx = line.indexOf('$$');
        out.push(line.slice(0, idx + 2));
        out.push(line.slice(idx + 2));
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
      const idx = line.lastIndexOf('$$');
      out.push(line.slice(0, idx));
      out.push(line.slice(idx));
      awaitingClose = false;
    } else {
      out.push(line);
    }
  }

  return out.join('\n');
}
