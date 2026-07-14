/**
 * Shared image caption/alt attribute helpers.
 *
 * Current format: `![caption](media/x.png){alt="..." width=N%}` — bracket
 * text is the visible CAPTION, and the `alt="..."` attribute (emitted
 * UNCONDITIONALLY, even empty) carries the real accessibility alt text,
 * separately. Its mere PRESENCE — not whether it's non-empty — self-marks a
 * fragment as this current format; its absence self-marks a fragment as a
 * pre-fix document, where bracket text is (as before) the alt, and any
 * caption lives in a preceding `<!-- caption: ... -->` comment.
 *
 * Shared between the Milkdown WYSIWYG editor (`milkdown/src/image-plugin.ts`)
 * and the CodeMirror source-mode editor (`codemirror/src/image-preview-plugin.ts`,
 * `codemirror/src/image-caption-popup.ts`, `codemirror/src/api.ts`) so both
 * surfaces read/write the exact same self-marking format and escaping
 * scheme — a document edited in either editor must see the same caption/alt
 * data consistently.
 */

/** Matches one recognized Pandoc-style attribute token inside a `{...}`
 * block: `alt="..."` (with backslash-escaped quotes inside the value) or
 * `width=N%`. */
export const ATTR_TOKEN_SOURCE = String.raw`alt="(?:[^"\\]|\\.)*"|width=\d+%`;

/** True if `raw` (untrimmed) is a `{...}` block containing only recognized
 * attribute tokens — combined, alone, or in either order — distinguishing a
 * real Pandoc attribute block from unrelated trailing text. */
export function isRecognizedAttrBlock(raw: string): boolean {
  const re = new RegExp(`^\\{\\s*(?:(?:${ATTR_TOKEN_SOURCE})\\s*)*\\}$`);
  return re.test(raw.trim());
}

/** Extracts the `width=N%` value from an attribute block's text, or `null`. */
export function extractWidthAttrValue(attrsText: string): number | null {
  const match = attrsText.match(/width=(\d+)%/);
  return match ? parseInt(match[1], 10) : null;
}

/** Extracts the `alt="..."` value from an attribute block's text, or `null`
 * if no `alt=` key is present at all (the self-marking "old format" signal —
 * distinct from an empty string, which means "new format, empty alt"). */
export function extractAltAttrValue(attrsText: string): string | null {
  const match = attrsText.match(/alt="((?:[^"\\]|\\.)*)"/);
  return match ? unescapeOnce(match[1]) : null;
}

/**
 * Escapes a value for embedding as the quoted value of a Pandoc-style
 * `alt="..."` attribute.
 *
 * Only ONE layer of backslash-escaping is applied here (`\` → `\\`, `"` →
 * `\"` — exactly what a human would type by hand). See
 * `milkdown/src/image-plugin.ts`'s toMarkdown for why exactly one layer is
 * correct for the Milkdown pipeline (mdast-util-to-markdown's own
 * round-trip-safety escaping cancels out against remark-parse's automatic
 * unescaping on read). The CodeMirror source-mode editor writes/reads this
 * same text directly (no mdast serializer in between), so the same single
 * escape layer applies there too.
 */
export function escapeAltAttr(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

/** Reverses one layer of backslash-escaping (`\X` → `X` for any `X`) — used
 * to reverse escapeAltAttr's single manual layer. */
export function unescapeOnce(text: string): string {
  return text.replace(/\\(.)/g, '$1');
}
