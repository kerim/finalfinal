// The serializer-escape cleanup, in a module of its own so both `api-content.ts` (the whole-document save) and
// `block-sync-plugin.ts` (the per-block save) can import it without an import cycle (block-sync-plugin.ts is imported by
// api-content.ts). `api-content.ts` re-exports it, so existing imports keep working.

/**
 * Serializer-escape cleanup shared by `getContent()`, the `preserveUserBlocks` merge push
 * (`pushPreservingUserBlocks`) and the per-block save text (`blockMarkdownFragment`, block-sync-plugin.ts) -- single source
 * of truth so the texts can never drift apart the way a hand-copied subset did before this fix (round-3 review, #13).
 * `sourceEnabled` mirrors `getContent()`'s own branching: the backtick unescape applies outside Source mode, the
 * double-`##`-prefix fix only inside it. `pushPreservingUserBlocks` always passes `false` -- `preserveUserBlocks` is
 * Rich-Text-only (WYSIWYG), never reached from Markdown/CodeMirror mode; see `setContentWithBlockIds`'s
 * `preserveUserBlocks` doc comment for why that's out of scope for this task.
 */
export function cleanupSerializedMarkdown(markdown: string, sourceEnabled: boolean): string {
  // Unescape heading syntax that ProseMirror's serializer escapes in paragraphs.
  let result = markdown.replace(/^\\(#{1,6}\s)/gm, '$1');
  // Unescape footnote definition brackets escaped by ProseMirror's serializer.
  result = result.replace(/^\\(\[\^\d+\]:)/gm, '$1');
  if (!sourceEnabled) {
    // Unescape backticks that ProseMirror's serializer escapes in text nodes. Safe: ProseMirror
    // does not escape inside code_block nodes, only inline text. Global (not line-anchored) is
    // correct because escaped backticks only appear in inline text.
    result = result.replace(/\\`/g, '`');
  } else {
    // Fix double ## prefixes in source mode: "## ## Heading" → "## Heading"
    result = result.replace(/^(#{1,6}) \1 /gm, '$1 ');
  }
  return result;
}
