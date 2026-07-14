/**
 * Shared image markdown line parser for CodeMirror 6.
 *
 * Parses a raw line of document text for an image markdown fragment
 * (`![...](media/...){...}`), using the same self-marking format/escaping
 * scheme as the Milkdown editor (see `../../shared/image-caption-attrs`) —
 * bracket text is the caption when an `alt="..."` attribute is present
 * (even empty), and is the (legacy) alt text otherwise.
 *
 * Kept as its own leaf module (no imports from `image-preview-plugin.ts` or
 * `image-caption-popup.ts`) so both of those can import it without creating
 * a circular dependency between them.
 */

import { ATTR_TOKEN_SOURCE, extractAltAttrValue, extractWidthAttrValue } from '../../shared/image-caption-attrs';

/** Matches image markdown: `![caption-or-alt](media/filename.ext){alt="..." width=N%}`.
 * Group 1 is the bracket text (caption in the new format, alt in the legacy
 * format); group 2 is the media src; group 3, when present, is the full
 * recognized `{...}` attribute block. */
const IMAGE_REGEX = new RegExp(
  `!\\[([^\\]]*)\\]\\((media\\/[^)]+)\\)(\\s*\\{\\s*(?:(?:${ATTR_TOKEN_SOURCE})\\s*)*\\})?`
);

/** Result of parsing a line of text for an image markdown fragment.
 * `matchIndex`/`matchLength` locate the full matched fragment within the
 * line's text (for callers that need to replace it in place, e.g. the
 * caption popup's commitEdit). */
export interface ParsedImageLine {
  src: string;
  /** Bracket text as literally written. Caller decides caption vs. alt via
   * `altAttrValue`: non-null means new format (bracket text = caption);
   * null means legacy format (bracket text = alt). */
  bracketText: string;
  /** The `alt="..."` attribute value, or null if absent (legacy format
   * self-marking signal — see `../../shared/image-caption-attrs`). */
  altAttrValue: string | null;
  width: number | null;
  matchIndex: number;
  matchLength: number;
}

/** Parses a single line of document text for an image markdown fragment.
 * Returns null if the line has no image. */
export function parseImageLine(lineText: string): ParsedImageLine | null {
  const match = IMAGE_REGEX.exec(lineText);
  if (!match) return null;
  const attrsBlock = match[3] ?? '';
  return {
    src: match[2],
    bracketText: match[1],
    altAttrValue: extractAltAttrValue(attrsBlock),
    width: extractWidthAttrValue(attrsBlock),
    matchIndex: match.index,
    matchLength: match[0].length,
  };
}
