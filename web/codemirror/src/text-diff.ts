/**
 * Smallest single contiguous {from, to, insert} change that turns `oldText` into
 * `newText`, or null when they are identical.
 *
 * Why: CodeMirror maps every selection position inside a replaced range to the
 * START of the replacement, so a whole-document replace (from: 0, to: len)
 * silently teleports the cursor -- and therefore the scroll anchor -- to position
 * 0 on every derived-content push (e.g. a bibliography-section resync). Confining
 * the change to the span that actually differs lets CodeMirror's own position
 * mapping leave everything above it untouched. Same reasoning as the block-level
 * diff already shipped for Milkdown in web/milkdown/src/api-content.ts (commit
 * ee20ab1); CodeMirror's document is flat text, so one contiguous middle span is
 * sufficient -- no per-block LCS/DP table needed.
 *
 * Offsets are UTF-16 code units (CodeMirror's position space). Both boundaries
 * are nudged so they never land between a high and low surrogate -- splitting a
 * pair would corrupt an astral-plane character such as an emoji.
 */
export function computeMinimalChange(
  oldText: string,
  newText: string
): { from: number; to: number; insert: string } | null {
  if (oldText === newText) return null;

  const isHighSurrogate = (c: number) => c >= 0xd800 && c <= 0xdbff;
  const isLowSurrogate = (c: number) => c >= 0xdc00 && c <= 0xdfff;

  const oldLen = oldText.length;
  const newLen = newText.length;
  const maxCommon = Math.min(oldLen, newLen);

  let prefix = 0;
  while (prefix < maxCommon && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) prefix++;
  if (prefix > 0 && isHighSurrogate(oldText.charCodeAt(prefix - 1))) prefix--;

  let suffix = 0;
  const maxSuffix = maxCommon - prefix; // never overlaps the prefix
  while (suffix < maxSuffix && oldText.charCodeAt(oldLen - 1 - suffix) === newText.charCodeAt(newLen - 1 - suffix))
    suffix++;
  if (suffix > 0 && isLowSurrogate(oldText.charCodeAt(oldLen - suffix))) suffix--;

  return { from: prefix, to: oldLen - suffix, insert: newText.slice(prefix, newLen - suffix) };
}
